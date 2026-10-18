import XCTest
@testable import Ambrosia

final class SeriesSyncCoordinatorTests: XCTestCase {

    func testSingleExpectedCompletionFires() {
        var coordinator = SeriesSyncCoordinator()
        let generation = coordinator.begin(awaiting: 1)
        XCTAssertTrue(coordinator.complete(generation: generation))
    }

    func testOnlyTheLastOfTwoCompletionsFires() {
        var coordinator = SeriesSyncCoordinator()
        let generation = coordinator.begin(awaiting: 2)
        XCTAssertFalse(coordinator.complete(generation: generation))
        XCTAssertTrue(coordinator.complete(generation: generation))
    }

    func testExtraCompletionAfterZeroDoesNotFireAgain() {
        // The open sequence awaits only the series seed; an extra completion
        // (for example a late extraction callback) must never trigger a second sync.
        var coordinator = SeriesSyncCoordinator()
        let generation = coordinator.begin(awaiting: 1)
        XCTAssertTrue(coordinator.complete(generation: generation))
        XCTAssertFalse(coordinator.complete(generation: generation))
    }

    func testSupersededGenerationNeverFiresAndDoesNotCount() {
        var coordinator = SeriesSyncCoordinator()
        let oldGeneration = coordinator.begin(awaiting: 1)
        let newGeneration = coordinator.begin(awaiting: 1)
        XCTAssertNotEqual(oldGeneration, newGeneration)
        XCTAssertFalse(coordinator.isCurrent(oldGeneration))
        XCTAssertTrue(coordinator.isCurrent(newGeneration))
        XCTAssertFalse(coordinator.complete(generation: oldGeneration))
        // The stale completion must not have consumed the new batch's count.
        XCTAssertTrue(coordinator.complete(generation: newGeneration))
    }

    func testCompletionWithoutABatchDoesNothing() {
        var coordinator = SeriesSyncCoordinator()
        XCTAssertFalse(coordinator.complete(generation: 0))
    }

    func testZeroCountBatchNeverFires() {
        var coordinator = SeriesSyncCoordinator()
        let generation = coordinator.begin(awaiting: 0)
        XCTAssertFalse(coordinator.complete(generation: generation))
    }
}
