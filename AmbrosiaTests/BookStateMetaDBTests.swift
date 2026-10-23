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

    func testLegacySwiftDataMigration() throws {
        let sourceDB = try Connection(.inMemory)

        // Simulate legacy SwiftData / CoreData table schema with Apple Reference Date offsets
        try sourceDB.execute("""
            CREATE TABLE ZBOOKSTATE (
                Z_PK INTEGER PRIMARY KEY,
                ZCALIBREID INTEGER,
                ZLASTSPINEINDEX INTEGER,
                ZLASTSCROLLOFFSET FLOAT,
                ZTOTALREADPERCENT FLOAT,
                ZLASTOPENEDDATE FLOAT,
                ZDATEADDED FLOAT,
                ZISREAD INTEGER,
                ZTOTALREADINGTIMESECONDS FLOAT,
                ZLASTCHARACTEROFFSET INTEGER,
                ZELOSCORE FLOAT,
                ZELOMATCHCOUNT INTEGER
            );
        """)

        // Apple Reference Date offset: 1000.0 seconds after Jan 1, 2001
        // Expected Unix timestamp: 1000.0 + 978307200.0 = 978308200.0
        try sourceDB.execute("""
            INSERT INTO ZBOOKSTATE (
                Z_PK, ZCALIBREID, ZLASTSPINEINDEX, ZLASTSCROLLOFFSET,
                ZTOTALREADPERCENT, ZLASTOPENEDDATE, ZDATEADDED, ZISREAD,
                ZTOTALREADINGTIMESECONDS, ZLASTCHARACTEROFFSET, ZELOSCORE, ZELOMATCHCOUNT
            ) VALUES (
                1, 999, 4, 0.42, 0.85, 1000.0, 500.0, 1, 3600.0, 250, 1200.0, 5
            );
        """)

        let targetDB = try Connection(.inMemory)
        try AmbrosiaMetaDB.runMigrations(db: targetDB)
        try AmbrosiaMetaDB.migrateLegacySwiftDataRows(from: sourceDB, to: targetDB)

        var found = false
        let selectQuery = """
            SELECT calibre_id, last_spine_index, last_scroll_offset, total_read_percent,
                   last_opened_date, total_reading_time_seconds, last_character_offset,
                   elo_score, elo_match_count
            FROM book_state WHERE calibre_id = 999
        """
        for row in try targetDB.prepare(selectQuery) {
            found = true
            XCTAssertEqual(row[0] as? Int64, 999)
            XCTAssertEqual(row[1] as? Int64, 4)
            XCTAssertEqual(row[2] as? Double, 0.42)
            XCTAssertEqual(row[3] as? Double, 0.85)
            let openedSec = row[4] as? Double
            XCTAssertEqual(openedSec, 978308200.0)
            XCTAssertEqual(row[5] as? Double, 3600.0)
            XCTAssertEqual(row[6] as? Int64, 250)
            XCTAssertEqual(row[7] as? Double, 1200.0)
            XCTAssertEqual(row[8] as? Int64, 5)
        }
        XCTAssertTrue(found, "Migrated row must exist in book_state table")
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
}
