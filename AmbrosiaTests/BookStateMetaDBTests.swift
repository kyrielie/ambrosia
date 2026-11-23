import XCTest
import SQLite
@testable import Ambrosia

final class BookStateMetaDBTests: XCTestCase {

    private var libraryURL: URL!
    private var metaDB: AmbrosiaMetaDB!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookStateMetaDBTests-\(UUID().uuidString)")
        metaDB = try AmbrosiaMetaDB(libraryURL: libraryURL)
    }

    override func tearDownWithError() throws {
        libraryURL = nil
        metaDB = nil
    }

    func testInitialBookStateReturnsDefaultRecord() async throws {
        let state = await metaDB.bookState(for: 101)
        XCTAssertEqual(state.calibreID, 101)
        XCTAssertEqual(state.lastSpineIndex, 0)
        XCTAssertEqual(state.lastCharacterOffset, 0)
        XCTAssertEqual(state.lastScrollOffset, 0.0)
        XCTAssertEqual(state.totalReadPercent, 0.0)
        XCTAssertFalse(state.isRead)
        XCTAssertFalse(state.hasBeenOpened)
        XCTAssertEqual(state.totalReadingTimeSeconds, 0.0)
    }

    func testUpdateReadingPosition() async throws {
        try await metaDB.updateReadingPosition(
            calibreID: 202,
            spineIndex: 5,
            characterOffset: 1500,
            scrollOffset: 0.75,
            readPercent: 0.62
        )

        let state = await metaDB.bookState(for: 202)
        XCTAssertEqual(state.calibreID, 202)
        XCTAssertEqual(state.lastSpineIndex, 5)
        XCTAssertEqual(state.lastCharacterOffset, 1500)
        XCTAssertEqual(state.lastScrollOffset, 0.75)
        XCTAssertEqual(state.totalReadPercent, 0.62)
        XCTAssertTrue(state.hasBeenOpened)
    }

    func testMarkBookOpenedAndReadingTime() async throws {
        try await metaDB.markBookOpened(calibreID: 303)
        let state1 = await metaDB.bookState(for: 303)
        XCTAssertTrue(state1.hasBeenOpened)
        XCTAssertEqual(state1.totalReadingTimeSeconds, 0.0)

        try await metaDB.addReadingTime(calibreID: 303, seconds: 120.5)
        let state2 = await metaDB.bookState(for: 303)
        XCTAssertEqual(state2.totalReadingTimeSeconds, 120.5)

        try await metaDB.addReadingTime(calibreID: 303, seconds: 60.0)
        let state3 = await metaDB.bookState(for: 303)
        XCTAssertEqual(state3.totalReadingTimeSeconds, 180.5)
    }

    func testMarkBookReadAndResetProgress() async throws {
        try await metaDB.updateReadingPosition(
            calibreID: 404,
            spineIndex: 2,
            characterOffset: 100,
            scrollOffset: 0.2,
            readPercent: 0.2
        )

        try await metaDB.markBookRead(calibreID: 404)
        let readState = await metaDB.bookState(for: 404)
        XCTAssertTrue(readState.isRead)
        XCTAssertEqual(readState.totalReadPercent, 1.0)

        try await metaDB.resetReadingProgress(calibreID: 404)
        let resetState = await metaDB.bookState(for: 404)
        XCTAssertFalse(resetState.isRead)
        XCTAssertEqual(resetState.totalReadPercent, 0.0)
        XCTAssertEqual(resetState.lastSpineIndex, 0)
        XCTAssertEqual(resetState.lastCharacterOffset, 0)
        XCTAssertEqual(resetState.lastScrollOffset, 0.0)
    }

    func testBatchBookStates() async throws {
        try await metaDB.updateReadingPosition(calibreID: 10, spineIndex: 1, characterOffset: 0, scrollOffset: 0.1, readPercent: 0.1)
        try await metaDB.updateReadingPosition(calibreID: 20, spineIndex: 2, characterOffset: 0, scrollOffset: 0.2, readPercent: 0.2)

        let batch = await metaDB.bookStates(for: [10, 20, 30])
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(batch[10]?.lastSpineIndex, 1)
        XCTAssertEqual(batch[20]?.lastSpineIndex, 2)
        XCTAssertEqual(batch[30]?.lastSpineIndex, 0)
    }

    func testReadingGoalsLifecycle() async throws {
        let initial = await metaDB.currentReadingGoal()
        XCTAssertNil(initial)

        let start = Date()
        let end = start.addingTimeInterval(86400 * 365)
        try await metaDB.saveReadingGoal(targetBooksCount: 35, periodStart: start, periodEnd: end)

        let current = await metaDB.currentReadingGoal()
        XCTAssertNotNil(current)
        XCTAssertEqual(current?.targetBooksCount, 35)

        if let id = current?.id {
            try await metaDB.deleteReadingGoal(id: id)
            let afterDelete = await metaDB.currentReadingGoal()
            XCTAssertNil(afterDelete)
        }
    }

    func testMultiLibraryIsolation() async throws {
        let libraryURLA = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiLibA-\(UUID().uuidString)")
        let libraryURLB = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiLibB-\(UUID().uuidString)")

        let metaDBA = try AmbrosiaMetaDB(libraryURL: libraryURLA)
        let metaDBB = try AmbrosiaMetaDB(libraryURL: libraryURLB)

        // Same calibre ID (500) in both libraries, but different progress
        try await metaDBA.updateReadingPosition(calibreID: 500, spineIndex: 2, characterOffset: 50, scrollOffset: 0.25, readPercent: 0.3)
        try await metaDBB.updateReadingPosition(calibreID: 500, spineIndex: 8, characterOffset: 990, scrollOffset: 0.88, readPercent: 0.95)

        let stateA = await metaDBA.bookState(for: 500)
        let stateB = await metaDBB.bookState(for: 500)

        XCTAssertEqual(stateA.lastSpineIndex, 2)
        XCTAssertEqual(stateA.totalReadPercent, 0.3)

        XCTAssertEqual(stateB.lastSpineIndex, 8)
        XCTAssertEqual(stateB.totalReadPercent, 0.95)
    }

    func testAllAO3DiagnosticsAndFiltering() async throws {
        let diag1 = AO3ExtractionDiagnostic(
            calibreID: 10,
            status: "failed",
            reason: "XML parse error",
            epubPath: "/path/to/10.epub",
            epubFilename: "10.epub",
            spineItemsChecked: 1,
            attemptedAt: "2026-01-01T00:00:00Z"
        )
        let diag2 = AO3ExtractionDiagnostic(
            calibreID: 20,
            status: "skipped",
            reason: "no dl.tags AO3 preface metadata in first 5 spine items",
            epubPath: "/path/to/20.epub",
            epubFilename: "20.epub",
            spineItemsChecked: 5,
            attemptedAt: "2026-01-01T00:01:00Z"
        )

        try await metaDB.insert(diag1)
        try await metaDB.insert(diag2)

        let all = try await metaDB.allAO3Diagnostics(failedOnly: false)
        XCTAssertEqual(all.count, 2)

        let failures = try await metaDB.allAO3Diagnostics(failedOnly: true)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.calibreID, 10)
    }
}
