import XCTest
import SQLite
@testable import Ambrosia

final class TransferDatabaseBuilderTests: XCTestCase {

    private var tempDBURL: URL!

    override func setUp() {
        super.setUp()
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferDBTests-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        if let url = tempDBURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempDBURL = nil
        super.tearDown()
    }

    func testBuildTransferDatabaseCreatesTablesAndManifest() throws {
        let manifest = TransferDatabaseBuilder.ManifestRow(
            walkID: UUID().uuidString,
            pageNumber: 1,
            hasMore: false,
            pageRowCount: 1,
            expectedTotalRowCount: 1
        )

        let row = TransferDatabaseBuilder.Row(
            calibreID: 101,
            ao3WorkID: "12345",
            isAnthology: false,
            ao3SeriesID: nil,
            seriesName: nil,
            url: "https://archiveofourown.org/works/12345",
            title: "Test Work",
            contentHTML: "<p>Content</p>",
            summary: "Summary",
            datePublished: "2026-01-01",
            dateModified: "2026-01-02",
            authorsJSON: "[\"Author A\"]",
            tagsJSON: "[\"Tag A\"]",
            wordCount: 1500,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            fandomsJSON: "[\"Fandom A\"]",
            relationshipsJSON: "[]",
            charactersJSON: "[]",
            ratingsJSON: "[\"General Audiences\"]",
            warningsJSON: "[]",
            categoriesJSON: "[]",
            seriesJSON: "[]",
            isReadLater: false,
            isLiked: true,
            isFinished: true,
            readingProgress: 1.0
        )

        try TransferDatabaseBuilder.build(rows: [row], manifest: manifest, at: tempDBURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDBURL.path))

        let conn = try Connection(tempDBURL.path, readonly: true)

        // Check user_version
        let userVersion = try conn.scalar("PRAGMA user_version") as? Int64
        XCTAssertEqual(userVersion, Int64(TransferDatabaseBuilder.wireFormatVersion))

        // Check manifest table
        let manifestCount = try conn.scalar("SELECT COUNT(*) FROM transfer_manifest") as? Int64
        XCTAssertEqual(manifestCount, 1)

        let manifestRow = try conn.prepare("SELECT walk_id, page_number, has_more, page_row_count FROM transfer_manifest").makeIterator().next()
        XCTAssertNotNil(manifestRow)
        XCTAssertEqual(manifestRow?[0] as? String, manifest.walkID)
        XCTAssertEqual(manifestRow?[1] as? Int64, 1)
        XCTAssertEqual(manifestRow?[2] as? Int64, 0)
        XCTAssertEqual(manifestRow?[3] as? Int64, 1)

        // Check items table
        let itemsCount = try conn.scalar("SELECT COUNT(*) FROM items") as? Int64
        XCTAssertEqual(itemsCount, 1)

        let itemRow = try conn.prepare("SELECT id, title, word_count, is_liked FROM items").makeIterator().next()
        XCTAssertEqual(itemRow?[0] as? String, "ambrosia-book-101")
        XCTAssertEqual(itemRow?[1] as? String, "Test Work")
        XCTAssertEqual(itemRow?[2] as? Int64, 1500)
        XCTAssertEqual(itemRow?[3] as? Int64, 1)
    }

    func testBuildTransferDatabaseWithEmptyRows() throws {
        let manifest = TransferDatabaseBuilder.ManifestRow(
            walkID: UUID().uuidString,
            pageNumber: 1,
            hasMore: false,
            pageRowCount: 0,
            expectedTotalRowCount: 0
        )

        try TransferDatabaseBuilder.build(rows: [], manifest: manifest, at: tempDBURL)

        let conn = try Connection(tempDBURL.path, readonly: true)
        let itemsCount = try conn.scalar("SELECT COUNT(*) FROM items") as? Int64
        XCTAssertEqual(itemsCount, 0)

        let manifestCount = try conn.scalar("SELECT COUNT(*) FROM transfer_manifest") as? Int64
        XCTAssertEqual(manifestCount, 1)
    }
}
