import XCTest
import SwiftSoup
import ZIPFoundation
@testable import Ambrosia

/// Coverage for the extraction-only read path: `EPUBParser.rawXHTML(for:archive:)`,
/// `EPUBParser.parse(skipTOC:)` and the `Document` overloads of
/// `AO3MetadataExtractor.extract` / `parseAuthors`.
final class ExtractionRawReadTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func add(_ archive: Archive, _ path: String, _ text: String) throws {
        let data = Data(text.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: .none) { pos, size in
            data.subdata(in: Int(pos)..<(Int(pos) + size))
        }
    }

    private static let titlePage = """
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>
    <h1>Some Title</h1>
    <div class="byline">by <a rel="author" href="https://archiveofourown.org/users/janedoe/pseuds/janedoe">janedoe</a></div>
    </body></html>
    """

    /// Each call writes a new file, so a test can build more than one EPUB.
    private func makeEPUB() throws -> URL {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)
        try add(archive, "mimetype", "application/epub+zip")
        try add(archive, "META-INF/container.xml", """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
        try add(archive, "content.opf", """
        <?xml version="1.0" encoding="utf-8"?>
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Synthetic</dc:title><dc:creator>Test Author</dc:creator>
          </metadata>
          <manifest>
            <item id="c0" href="split_000.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="split_001.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c0"/><itemref idref="c1"/></spine>
        </package>
        """)
        try add(archive, "split_000.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Preface</p></body></html>")
        try add(archive, "split_001.xhtml", Self.titlePage)
        return url
    }

    func testRawXHTMLKeepsBylineWrapperAndAuthorsParse() throws {
        var parser = EPUBParser(epubURL: try makeEPUB())
        try parser.parse(skipTOC: true)
        XCTAssertEqual(parser.spine.count, 2)
        let archive = try parser.openArchive()
        let raw = try parser.rawXHTML(for: parser.spine[1], archive: archive)
        XCTAssertTrue(raw.contains("class=\"byline\""))

        let fromString = AO3MetadataExtractor.parseAuthors(from: raw)
        let fromDocument = AO3MetadataExtractor.parseAuthors(from: try SwiftSoup.parse(raw))
        XCTAssertEqual(fromString.map(\.username), ["janedoe"])
        XCTAssertEqual(fromString.map(\.username), fromDocument.map(\.username))
        XCTAssertEqual(fromString.map(\.profileURL), fromDocument.map(\.profileURL))
    }

    func testSkipTOCLeavesSpineIntactAndTOCEmpty() throws {
        var skipped = EPUBParser(epubURL: try makeEPUB())
        try skipped.parse(skipTOC: true)
        var full = EPUBParser(epubURL: try makeEPUB())
        try full.parse()
        XCTAssertTrue(skipped.toc.isEmpty)
        XCTAssertEqual(skipped.spine.map(\.href), full.spine.map(\.href))
        XCTAssertEqual(skipped.title, full.title)
        XCTAssertEqual(skipped.opfCreators, full.opfCreators)
    }

    func testRawXHTMLThrowsForMissingSpineEntry() throws {
        var parser = EPUBParser(epubURL: try makeEPUB())
        try parser.parse(skipTOC: true)
        let archive = try parser.openArchive()
        let ghost = EPUBParser.SpineItem(index: 9, href: "nope.xhtml", mediaType: "application/xhtml+xml", id: "ghost")
        XCTAssertThrowsError(try parser.rawXHTML(for: ghost, archive: archive))
    }

    /// Equivalence gate for the raw-read switch. The old path ran the extractor on
    /// reader-sanitised HTML; with the layout that leaves the preface intact
    /// (`.ao3EPUB`) it must give the same record as the raw read.
    func testRawPrefaceExtractionMatchesSanitisedExtractionOnSamples() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dir = repoRoot.appendingPathComponent("samples/prefaces")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xhtml" }) ?? []
        try XCTSkipIf(files.isEmpty, "samples/prefaces not available")

        for file in files {
            let raw = try String(contentsOf: file, encoding: .utf8)
            let sanitised = EPUBParser.sanitise(raw, userCSS: "", spineIndex: 0, ao3Order: .ao3EPUB)
            var old = AO3MetadataExtractor.extract(from: sanitised)
            var new = AO3MetadataExtractor.extract(from: try SwiftSoup.parse(raw))
            old?.extractedAt = ""
            new?.extractedAt = ""
            XCTAssertEqual(old, new, "Mismatch for \(file.lastPathComponent)")
        }
    }
}
