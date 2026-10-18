import XCTest
import SQLite
@testable import Ambrosia

// `library_state` and the series-seed marker rules. The seed marker must be
// dropped by anything that rewrites a book's series_cache rows, because that
// deletes the Calibre fallback row only a re-seed restores.
final class LibraryStateTests: XCTestCase {

    private var libraryURL: URL!
    private var metaDB: AmbrosiaMetaDB!

    private let fingerprint = LibraryFingerprint(fileModified: 1, fileSize: 2, bookCount: 3,
                                                 maxBookID: 4, maxLastModified: "x")

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStateTests-\(UUID().uuidString)")
        metaDB = try AmbrosiaMetaDB(libraryURL: libraryURL)
    }

    override func tearDownWithError() throws {
        libraryURL = nil
        metaDB = nil
    }

    func testMigrationCreatesLibraryStateAndIsIdempotent() throws {
        let db = try Connection(.inMemory)
        try AmbrosiaMetaDB.runMigrations(db: db)
        try AmbrosiaMetaDB.runMigrations(db: db)
        let count = try db.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'library_state'") as? Int64
        XCTAssertEqual(count, 1)
    }

    func testSetGetReplaceRemove() async throws {
        let initial = await metaDB.libraryState("k")
        XCTAssertNil(initial)
        try await metaDB.setLibraryState("k", "one")
        let first = await metaDB.libraryState("k")
        XCTAssertEqual(first, "one")
        try await metaDB.setLibraryState("k", "two")
        let second = await metaDB.libraryState("k")
        XCTAssertEqual(second, "two")
        try await metaDB.removeLibraryState("k")
        let removed = await metaDB.libraryState("k")
        XCTAssertNil(removed)
    }

    func testMarkSeriesSeededRecordsWhenNoRewriteHappened() async throws {
        let count = await metaDB.seriesRewriteCount
        let recorded = try await metaDB.markSeriesSeeded(fingerprint, ifRewriteCountIs: count)
        XCTAssertTrue(recorded)
        let stored = await metaDB.libraryState(LibraryStateKey.seriesSeedFingerprint)
        XCTAssertEqual(LibraryFingerprint.decode(stored), fingerprint)
    }

    func testRewriteDuringSeedPreventsRecording() async throws {
        let count = await metaDB.seriesRewriteCount
        try await metaDB.invalidateSeriesSeedMarker()
        let recorded = try await metaDB.markSeriesSeeded(fingerprint, ifRewriteCountIs: count)
        XCTAssertFalse(recorded)
        let stored = await metaDB.libraryState(LibraryStateKey.seriesSeedFingerprint)
        XCTAssertNil(stored)
    }

    func testInvalidateDropsAnExistingMarker() async throws {
        let count = await metaDB.seriesRewriteCount
        try await metaDB.markSeriesSeeded(fingerprint, ifRewriteCountIs: count)
        try await metaDB.invalidateSeriesSeedMarker()
        let stored = await metaDB.libraryState(LibraryStateKey.seriesSeedFingerprint)
        XCTAssertNil(stored)
    }

    func testClearAO3MetadataDropsBothMarkers() async throws {
        let count = await metaDB.seriesRewriteCount
        try await metaDB.markSeriesSeeded(fingerprint, ifRewriteCountIs: count)
        try await metaDB.setLibraryState(LibraryStateKey.extractionScanFingerprint, fingerprint.encoded())
        try await metaDB.clearAO3Metadata()
        let seed = await metaDB.libraryState(LibraryStateKey.seriesSeedFingerprint)
        let scan = await metaDB.libraryState(LibraryStateKey.extractionScanFingerprint)
        XCTAssertNil(seed)
        XCTAssertNil(scan)
    }
}
