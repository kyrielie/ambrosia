import XCTest
@testable import Ambrosia

@MainActor
final class DatabaseMaintenanceCoordinatorTests: XCTestCase {

    func testInitialState() {
        let coordinator = DatabaseMaintenanceCoordinator()
        XCTAssertFalse(coordinator.isMaintenanceInProgress)
        XCTAssertFalse(coordinator.isCompacting)
        XCTAssertFalse(coordinator.isIndexingFTS)
        XCTAssertFalse(coordinator.isIndexingSemantic)
        XCTAssertNil(coordinator.currentSummary)
        XCTAssertTrue(coordinator.activeOperations.isEmpty)
    }

    func testBeginAndEndOperation() {
        let coordinator = DatabaseMaintenanceCoordinator()

        let id = coordinator.beginOperation(kind: .compactAndVacuum, detail: "Calibre Library")
        XCTAssertTrue(coordinator.isMaintenanceInProgress)
        XCTAssertTrue(coordinator.isCompacting)
        XCTAssertFalse(coordinator.isIndexingFTS)
        XCTAssertFalse(coordinator.isIndexingSemantic)
        XCTAssertEqual(coordinator.currentSummary, "Compacting and vacuuming databases")

        coordinator.endOperation(id: id)
        XCTAssertFalse(coordinator.isMaintenanceInProgress)
        XCTAssertFalse(coordinator.isCompacting)
        XCTAssertNil(coordinator.currentSummary)
    }

    func testMultipleConcurrentOperations() {
        let coordinator = DatabaseMaintenanceCoordinator()

        let id1 = coordinator.beginOperation(kind: .compactAndVacuum, detail: "Lib1")
        let id2 = coordinator.beginOperation(kind: .indexingFTS, detail: "Lib2")

        XCTAssertTrue(coordinator.isMaintenanceInProgress)
        XCTAssertTrue(coordinator.isCompacting)
        XCTAssertTrue(coordinator.isIndexingFTS)
        XCTAssertFalse(coordinator.isIndexingSemantic)

        guard let summary = coordinator.currentSummary else {
            XCTFail("Expected non-nil currentSummary")
            return
        }
        XCTAssertTrue(summary.contains("Compacting and vacuuming databases"))
        XCTAssertTrue(summary.contains("Indexing full-text search"))

        coordinator.endOperation(id: id1)
        XCTAssertTrue(coordinator.isMaintenanceInProgress)
        XCTAssertFalse(coordinator.isCompacting)
        XCTAssertTrue(coordinator.isIndexingFTS)

        coordinator.endOperation(id: id2)
        XCTAssertFalse(coordinator.isMaintenanceInProgress)
        XCTAssertFalse(coordinator.isIndexingFTS)
        XCTAssertNil(coordinator.currentSummary)
    }

    func testCancelAllTriggersRegisteredCallbacks() {
        let coordinator = DatabaseMaintenanceCoordinator()

        var cancelled1 = false
        var cancelled2 = false

        _ = coordinator.beginOperation(kind: .compactAndVacuum, detail: "Lib1") {
            cancelled1 = true
        }
        _ = coordinator.beginOperation(kind: .indexingFTS, detail: "Lib2") {
            cancelled2 = true
        }

        coordinator.cancelAll()

        XCTAssertTrue(cancelled1)
        XCTAssertTrue(cancelled2)
    }

    func testWithMaintenanceScope() async {
        let coordinator = DatabaseMaintenanceCoordinator()

        await coordinator.withMaintenance(kind: .indexingFTS, detail: "Test") {
            XCTAssertTrue(coordinator.isMaintenanceInProgress)
            XCTAssertTrue(coordinator.isIndexingFTS)
        }

        XCTAssertFalse(coordinator.isMaintenanceInProgress)
        XCTAssertFalse(coordinator.isIndexingFTS)
    }

    func testWithMaintenanceScopeRethrows() async {
        let coordinator = DatabaseMaintenanceCoordinator()

        struct DummyError: Error {}

        do {
            try await coordinator.withMaintenance(kind: .compactAndVacuum, detail: "Test") {
                XCTAssertTrue(coordinator.isMaintenanceInProgress)
                throw DummyError()
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is DummyError)
        }

        XCTAssertFalse(coordinator.isMaintenanceInProgress)
        XCTAssertFalse(coordinator.isCompacting)
    }
}
