import Foundation
import SQLite
import XCTest
@testable import Ambrosia

final class LibraryStorageCalculatorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStorageCalculatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    func testBreakdownProportionsWithZeroTotal() {
        let breakdown = LibraryStorageBreakdown(
            epubsSizeBytes: 0,
            calibreDBSizeBytes: 0,
            ftsDBSizeBytes: 0,
            ambrosiaMetaDBSizeBytes: 0
        )

        let props = breakdown.proportions
        XCTAssertEqual(props.epubs, 0)
        XCTAssertEqual(props.calibre, 0)
        XCTAssertEqual(props.fts, 0)
        XCTAssertEqual(props.ambrosia, 0)
        XCTAssertEqual(breakdown.totalSizeBytes, 0)
    }

    func testBreakdownProportionsCalculation() {
        let breakdown = LibraryStorageBreakdown(
            epubsSizeBytes: 500,
            calibreDBSizeBytes: 200,
            ftsDBSizeBytes: 200,
            ambrosiaMetaDBSizeBytes: 100
        )

        XCTAssertEqual(breakdown.totalSizeBytes, 1000)
        let props = breakdown.proportions
        XCTAssertEqual(props.epubs, 0.5, accuracy: 0.001)
        XCTAssertEqual(props.calibre, 0.2, accuracy: 0.001)
        XCTAssertEqual(props.fts, 0.2, accuracy: 0.001)
        XCTAssertEqual(props.ambrosia, 0.1, accuracy: 0.001)
    }

    func testFormattedSizeStrings() {
        let breakdown = LibraryStorageBreakdown(
            epubsSizeBytes: 1024 * 1024 * 10, // 10 MB
            calibreDBSizeBytes: 1024 * 500, // 500 KB
            ftsDBSizeBytes: 0,
            ambrosiaMetaDBSizeBytes: 2048
        )

        XCTAssertFalse(breakdown.formattedTotalSize.isEmpty)
        XCTAssertFalse(breakdown.formattedEpubsSize.isEmpty)
        XCTAssertFalse(breakdown.formattedCalibreDBSize.isEmpty)
        XCTAssertFalse(breakdown.formattedFTSDBSize.isEmpty)
        XCTAssertFalse(breakdown.formattedAmbrosiaMetaDBSize.isEmpty)
    }

    func testCalculateOnSyntheticFolderWithEPUBFiles() async throws {
        let libURL = tempDir.appendingPathComponent("MockLibrary")
        try FileManager.default.createDirectory(at: libURL, withIntermediateDirectories: true)

        // Write a 1000-byte dummy EPUB file
        let epub1 = libURL.appendingPathComponent("Book1.epub")
        let dummyData1 = Data(repeating: 0x41, count: 1000)
        try dummyData1.write(to: epub1)

        // Write a 2000-byte dummy EPUB in a subfolder
        let authorDir = libURL.appendingPathComponent("Author")
        try FileManager.default.createDirectory(at: authorDir, withIntermediateDirectories: true)
        let epub2 = authorDir.appendingPathComponent("Book2.epub")
        let dummyData2 = Data(repeating: 0x42, count: 2000)
        try dummyData2.write(to: epub2)

        // Write non-epub file (should be ignored for EPUB count)
        let txtFile = authorDir.appendingPathComponent("cover.jpg")
        try Data(repeating: 0xFF, count: 500).write(to: txtFile)

        // Write a 500-byte dummy metadata.db
        let dbURL = libURL.appendingPathComponent("metadata.db")
        let dummyDB = Data(repeating: 0x00, count: 500)
        try dummyDB.write(to: dbURL)

        let breakdown = await LibraryStorageCalculator.calculate(for: libURL)

        XCTAssertEqual(breakdown.epubsSizeBytes, 3000)
        XCTAssertEqual(breakdown.calibreDBSizeBytes, 500)
        XCTAssertEqual(breakdown.totalSizeBytes, 3500)
    }

    func testCalculateWithCalibreMetadataEPUBSize() async throws {
        let libURL = tempDir.appendingPathComponent("MockCalibreLibrary")
        try FileManager.default.createDirectory(at: libURL, withIntermediateDirectories: true)

        let dbURL = libURL.appendingPathComponent("metadata.db")
        let db = try Connection(dbURL.path)
        try db.run("CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER, format TEXT, uncompressed_size INTEGER, name TEXT);")
        try db.run("INSERT INTO data (book, format, uncompressed_size, name) VALUES (1, 'EPUB', 88888, 'book1');")
        try db.run("INSERT INTO data (book, format, uncompressed_size, name) VALUES (2, 'PDF', 99999, 'book2');")

        let breakdown = await LibraryStorageCalculator.calculate(for: libURL)

        // When metadata.db has EPUB uncompressed_size in the data table, it should prefer 88888
        XCTAssertEqual(breakdown.epubsSizeBytes, 88888)
        XCTAssertGreaterThan(breakdown.calibreDBSizeBytes, 0)
    }

    func testCombiningMultipleBreakdowns() {
        let b1 = LibraryStorageBreakdown(
            epubsSizeBytes: 100,
            calibreDBSizeBytes: 20,
            ftsDBSizeBytes: 30,
            ambrosiaMetaDBSizeBytes: 10
        )
        let b2 = LibraryStorageBreakdown(
            epubsSizeBytes: 200,
            calibreDBSizeBytes: 40,
            ftsDBSizeBytes: 60,
            ambrosiaMetaDBSizeBytes: 20
        )

        let combined = LibraryStorageBreakdown.combining([b1, b2])

        XCTAssertEqual(combined.epubsSizeBytes, 300)
        XCTAssertEqual(combined.calibreDBSizeBytes, 60)
        XCTAssertEqual(combined.ftsDBSizeBytes, 90)
        XCTAssertEqual(combined.ambrosiaMetaDBSizeBytes, 30)
        XCTAssertEqual(combined.totalSizeBytes, 480)
    }
}
