// SPDX-License-Identifier: GPL-3.0-only
import SQLite3
import XCTest
import ZIPFoundation
@testable import Ambrosia

final class LowRiskReaderAndMaintenanceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmbrosiaLowRiskTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testPaginationJSHighlightColorsIncludeImportantTextContrast() {
        let script = PaginationJS.script
        XCTAssertTrue(script.contains("color:#111111 !important;"))
    }

    func testFullOPFParserDetectsFixedLayoutMetadata() {
        let fixedOPF = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Fixed Book</dc:title>
            <meta property="rendition:layout">pre-paginated</meta>
          </metadata>
          <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """
        let fixedParser = FullOPFParser()
        let fixedXML = XMLParser(data: Data(fixedOPF.utf8))
        fixedXML.delegate = fixedParser
        XCTAssertTrue(fixedXML.parse())
        XCTAssertTrue(fixedParser.isFixedLayout)

        let reflowOPF = fixedOPF.replacingOccurrences(of: "pre-paginated", with: "reflowable")
        let reflowParser = FullOPFParser()
        let reflowXML = XMLParser(data: Data(reflowOPF.utf8))
        reflowXML.delegate = reflowParser
        XCTAssertTrue(reflowXML.parse())
        XCTAssertFalse(reflowParser.isFixedLayout)
    }

    func testFTSOccurrenceExtractorRespectsWordBoundariesAndSkipsZeroWidth() {
        let ranges = FTSOccurrenceExtractor.findTermRanges(in: "love lovely glove", terms: ["love"])
        XCTAssertEqual(ranges.count, 1)
        if let first = ranges.first {
            XCTAssertEqual(String("love lovely glove"[first]), "love")
        }

        let emptyRanges = FTSOccurrenceExtractor.findTermRanges(in: "hello world", terms: [""])
        XCTAssertTrue(emptyRanges.isEmpty)
    }

    func testCleanupOrphanedExtractionDirectoriesRemovesOnlyOlderThanCutoff() throws {
        let staleDir = tempRoot.appendingPathComponent("101", isDirectory: true)
        let freshDir = tempRoot.appendingPathComponent("102", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)

        let staleDate = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleDir.path)

        let cutoff = Date(timeIntervalSinceNow: -60)
        AppDelegate.cleanupOrphanedExtractionDirectories(olderThan: cutoff, in: tempRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshDir.path))
    }

    func testSQLiteFileMaintenanceCorruptionDetectionAndPassageDatabaseAutoReset() throws {
        XCTAssertTrue(SQLiteFileMaintenance.isCorruptionErrorCode(SQLITE_CORRUPT))
        XCTAssertTrue(SQLiteFileMaintenance.isCorruptionErrorCode(SQLITE_NOTADB))
        XCTAssertTrue(SQLiteFileMaintenance.isCorruptionErrorCode(SQLITE_CORRUPT | (1 << 8)))
        XCTAssertFalse(SQLiteFileMaintenance.isCorruptionErrorCode(SQLITE_OK))
        XCTAssertFalse(SQLiteFileMaintenance.isCorruptionErrorCode(SQLITE_BUSY))

        let dbURL = tempRoot.appendingPathComponent("corrupt_passages.db")
        let walURL = tempRoot.appendingPathComponent("corrupt_passages.db-wal")
        let shmURL = tempRoot.appendingPathComponent("corrupt_passages.db-shm")
        try Data("not a sqlite database".utf8).write(to: dbURL)
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        let db = PassageDatabase(databaseURL: dbURL)
        XCTAssertNil(db)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path))
    }

    func testExtractImagesIncludesAVIF() throws {
        let epubURL = tempRoot.appendingPathComponent("sample.epub")
        let archive = try Archive(url: epubURL, accessMode: .create)
        let payload = Data([0x00, 0x00, 0x00, 0x1C])
        try archive.addEntry(
            with: "OEBPS/images/cover.avif",
            type: .file,
            uncompressedSize: Int64(payload.count),
            provider: { position, size in
                payload.subdata(in: Int(position)..<(Int(position) + size))
            }
        )

        let calibreID = Int.random(in: 900_000...999_999)
        let extractedRoot = try EPUBParser.extractImages(from: epubURL, calibreID: calibreID)
        defer { try? FileManager.default.removeItem(at: extractedRoot) }

        let extractedAVIF = extractedRoot.appendingPathComponent("OEBPS/images/cover.avif")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedAVIF.path))
    }
}
