import XCTest
import ZIPFoundation
@testable import Ambrosia

final class AO3EPUB3ExportTests: XCTestCase {

    func testLanguageMap() {
        XCTAssertEqual(AO3LanguageMap.bcp47Tag(for: nil), "en")
        XCTAssertEqual(AO3LanguageMap.bcp47Tag(for: ""), "en")
        XCTAssertEqual(AO3LanguageMap.bcp47Tag(for: "en"), "en")
        XCTAssertEqual(AO3LanguageMap.bcp47Tag(for: "es"), "es")
        XCTAssertEqual(AO3LanguageMap.bcp47Tag(for: "div"), "dv")
        XCTAssertEqual(AO3LanguageMap.bcp47Tag(for: "sla"), "cu")
        XCTAssertEqual(AO3LanguageMap.bcp47Tag(for: "sun"), "su")
        XCTAssertEqual(AO3LanguageMap.bcp47Tag(for: "tir"), "ti")
        XCTAssertEqual(AO3LanguageMap.bcp47Tag(for: "qnv"), "art-x-navi")
    }

    func testPackageOPFConstruction() {
        let authors = [
            AO3AuthorEntry(username: "janedoe", pseud: "Jane D.", profileURL: "https://archiveofourown.org/users/janedoe", source: .byline)
        ]
        let metadata = AO3MetadataRecord(
            storyURL: "https://archiveofourown.org/works/9999",
            workID: "9999",
            authors: authors,
            kudosCount: 50,
            wordCount: 12000,
            chapterCurrent: 2,
            chapterTotal: 2,
            isComplete: true,
            language: "en",
            publishedDate: "2024-01-15",
            updatedDate: "2024-01-20",
            fandoms: ["Doctor Who"],
            relationships: ["Ten/Rose"],
            characters: ["Tenth Doctor", "Rose Tyler"],
            additionalTags: ["Fluff", "Time Travel"],
            categories: ["F/M"],
            ao3Collections: [],
            series: [],
            rating: "General Audiences",
            warnings: ["No Archive Warnings Apply"],
            extractedAt: "2024-01-21"
        )
        let chapters = [
            AO3EPUB3Builder.ChapterItem(id: "chapter_1", title: "Chapter 1: The Beginning", htmlBody: "<p>First paragraph.</p>"),
            AO3EPUB3Builder.ChapterItem(id: "chapter_2", title: "Chapter 2: The Return", htmlBody: "<p>Second paragraph.</p>")
        ]

        let opf = AO3EPUB3Builder.buildPackageOPF(options: AO3EPUB3Builder.PackageOPFOptions(
            title: "TARDIS Adventures",
            workID: "9999",
            authors: authors,
            metadata: metadata,
            language: "en",
            chapters: chapters
        ))

        XCTAssertTrue(opf.contains("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"url\">"))
        XCTAssertTrue(opf.contains("<dc:identifier id=\"url\">https://archiveofourown.org/works/9999</dc:identifier>"))
        XCTAssertTrue(opf.contains("<dc:creator id=\"pseud_0\">Jane D.</dc:creator>"))
        XCTAssertTrue(opf.contains("<meta refines=\"#pseud_0\" property=\"file-as\">janedoe</meta>"))
        XCTAssertTrue(opf.contains("<meta refines=\"#pseud_0\" property=\"role\" scheme=\"marc:relators\">aut</meta>"))
        XCTAssertTrue(opf.contains("<dc:subject>Rating -- General Audiences</dc:subject>"))
        XCTAssertTrue(opf.contains("<dc:subject>Archive Warning -- No Archive Warnings Apply</dc:subject>"))
        XCTAssertTrue(opf.contains("<dc:subject>Fandom -- Doctor Who</dc:subject>"))
        XCTAssertTrue(opf.contains("<dc:subject>Relationship -- Ten/Rose</dc:subject>"))
        XCTAssertTrue(opf.contains("<dc:subject>Additional Tags -- Fluff</dc:subject>"))
        XCTAssertTrue(opf.contains("<item id=\"toc\" href=\"toc.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"))
        XCTAssertTrue(opf.contains("<itemref idref=\"chapter_1\"/>"))
        XCTAssertTrue(opf.contains("<itemref idref=\"chapter_2\"/>"))
    }

    func testEPUB3NormalizationCreatesCompliantContainer() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Build a synthetic raw EPUB 2
        let rawEPUBURL = tempDir.appendingPathComponent("raw.epub")
        guard let rawArchive = Archive(url: rawEPUBURL, accessMode: .create) else {
            XCTFail("Could not create raw archive")
            return
        }

        let mimetypeData = Data("application/epub+zip".utf8)
        try rawArchive.addEntry(with: "mimetype", type: .file, uncompressedSize: UInt32(mimetypeData.count), compressionMethod: .none) { pos, size in
            mimetypeData.subdata(in: pos..<(pos + size))
        }

        let containerData = Data("""
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8)
        try rawArchive.addEntry(
            with: "META-INF/container.xml",
            type: .file,
            uncompressedSize: UInt32(containerData.count),
            compressionMethod: .none
        ) { pos, size in
            containerData.subdata(in: pos..<(pos + size))
        }

        let opfData = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Synthetic Fanfic</dc:title>
            <dc:creator>Test Author</dc:creator>
          </metadata>
          <manifest>
            <item id="chapter1" href="split_001.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="chapter1"/>
          </spine>
        </package>
        """.utf8)
        try rawArchive.addEntry(with: "content.opf", type: .file, uncompressedSize: UInt32(opfData.count), compressionMethod: .none) { pos, size in
            opfData.subdata(in: pos..<(pos + size))
        }

        let chapterData = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter 1</title></head>
        <body>
          <h2>Chapter 1</h2>
          <p>It was a dark and stormy night.</p>
        </body>
        </html>
        """.utf8)
        try rawArchive.addEntry(with: "split_001.xhtml", type: .file, uncompressedSize: UInt32(chapterData.count), compressionMethod: .none) { pos, size in
            chapterData.subdata(in: pos..<(pos + size))
        }

        // Target normalized EPUB 3
        let targetEPUBURL = tempDir.appendingPathComponent("normalized.epub")

        try AO3EPUB3Normalizer.normalize(
            sourceEPUB: rawEPUBURL,
            destinationEPUB: targetEPUBURL,
            metadata: nil,
            bookTitle: "Synthetic Fanfic",
            authors: ["Test Author"]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetEPUBURL.path))

        // Verify container structure
        guard let normalizedArchive = Archive(url: targetEPUBURL, accessMode: .read) else {
            XCTFail("Failed to open normalized EPUB")
            return
        }

        // Check entry 1 is mimetype with uncompressed storage
        var entries: [Entry] = []
        for entry in normalizedArchive {
            entries.append(entry)
        }

        XCTAssertGreaterThanOrEqual(entries.count, 6)
        XCTAssertEqual(entries[0].path, "mimetype")
        XCTAssertEqual(entries[0].compressedSize, entries[0].uncompressedSize)

        // Verify required EPUB 3 items exist
        let paths = Set(entries.map(\.path))
        XCTAssertTrue(paths.contains("META-INF/container.xml"))
        XCTAssertTrue(paths.contains("OEBPS/package.opf"))
        XCTAssertTrue(paths.contains("OEBPS/toc.xhtml"))
        XCTAssertTrue(paths.contains("OEBPS/imprint.xhtml"))
        XCTAssertTrue(paths.contains("OEBPS/stylesheet.css"))
        XCTAssertTrue(paths.contains("OEBPS/chapter_1.xhtml"))
    }
}
