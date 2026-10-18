import XCTest
import SQLite
@testable import Ambrosia

// The chunked series scan must produce exactly what the single whole-library
// call did, and the fingerprint must reflect the real library.
final class CalibreSeriesChunkTests: XCTestCase {

    private static var library: CalibreLibrary!
    private static var libraryRoot: URL!

    // swiftlint:disable:next static_over_final_class
    override class func setUp() {
        do {
            libraryRoot = try CalibreTestFixture.makeTempLibraryRoot()
            library = try CalibreLibrary(root: libraryRoot)
        } catch {
            XCTFail("Failed to build shared fixture: \(error)")
        }
    }

    // swiftlint:disable:next static_over_final_class
    override class func tearDown() {
        if let libraryRoot { try? FileManager.default.removeItem(at: libraryRoot) }
        library = nil
        libraryRoot = nil
    }

    private var library: CalibreLibrary { Self.library }

    func testWindowedScanEqualsWholeLibraryScan() async {
        let all = await library.allCalibreSeriesEntries()
        XCTAssertFalse(all.isEmpty)
        let maxID = await library.allBookIDs().max() ?? 0
        for windowSize in [1, 7, 5_000] {
            var chunked: [SeriesCacheEntry] = []
            var lower = 0
            while lower < maxID {
                let upper = lower + windowSize
                chunked += await library.calibreSeriesEntries(bookIDsAfter: lower, through: upper)
                lower = upper
            }
            XCTAssertEqual(Set(chunked), Set(all), "window size \(windowSize)")
            XCTAssertEqual(chunked.count, all.count, "no entry may repeat across windows (size \(windowSize))")
        }
    }

    func testWindowIsExclusiveBelowAndInclusiveAbove() async {
        let all = await library.allCalibreSeriesEntries()
        guard let sample = all.first else { return XCTFail("fixture has no series rows") }
        let at = await library.calibreSeriesEntries(bookIDsAfter: sample.calibreID - 1, through: sample.calibreID)
        XCTAssertTrue(at.contains(sample))
        let after = await library.calibreSeriesEntries(bookIDsAfter: sample.calibreID, through: nil)
        XCTAssertFalse(after.contains { $0.calibreID == sample.calibreID })
    }

    func testFingerprintMatchesLibraryAndIsStable() async throws {
        let first = await library.libraryFingerprint()
        let second = await library.libraryFingerprint()
        let fingerprint = try XCTUnwrap(first)
        XCTAssertEqual(fingerprint, second)
        let bookCount = await library.bookCount()
        let maxID = await library.allBookIDs().max() ?? 0
        XCTAssertEqual(fingerprint.bookCount, bookCount)
        XCTAssertEqual(fingerprint.maxBookID, maxID)
        XCTAssertGreaterThan(fingerprint.fileSize, 0)
    }
}

// Each test gets its own library because these tests rewrite or replace the file.
final class CalibreLibraryReopenTests: XCTestCase {

    private var root: URL!
    private var library: CalibreLibrary!

    override func setUpWithError() throws {
        root = try CalibreTestFixture.makeTempLibraryRoot()
        library = try CalibreLibrary(root: root)
    }

    override func tearDownWithError() throws {
        library = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testUntouchedFileDoesNotReopen() async {
        let reopened = await library.reopenIfFileReplaced()
        XCTAssertFalse(reopened)
    }

    func testReplacedFileReopensAndStaysQueryable() async throws {
        let before = await library.bookCount()
        let path = root.appendingPathComponent("metadata.db")
        let copy = root.appendingPathComponent("metadata.copy")
        try FileManager.default.copyItem(at: path, to: copy)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: copy, to: path)

        let reopened = await library.reopenIfFileReplaced()
        XCTAssertTrue(reopened)
        let after = await library.bookCount()
        XCTAssertEqual(before, after)
        let again = await library.reopenIfFileReplaced()
        XCTAssertFalse(again, "identity is recorded, so a second call is a no-op")
    }

    func testInPlaceWriteChangesFingerprintWithoutReopen() async throws {
        let beforeOptional = await library.libraryFingerprint()
        let before = try XCTUnwrap(beforeOptional)
        let writer = try Connection(root.appendingPathComponent("metadata.db").path)
        try writer.execute("UPDATE books SET last_modified = '2099-01-01 00:00:00+00:00' WHERE id = (SELECT MIN(id) FROM books)")

        let reopened = await library.reopenIfFileReplaced()
        XCTAssertFalse(reopened)
        let afterOptional = await library.libraryFingerprint()
        let after = try XCTUnwrap(afterOptional)
        XCTAssertEqual(LibraryChange.classify(known: before, current: after), .content)
    }
}
