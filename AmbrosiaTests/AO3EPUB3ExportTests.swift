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

        XCTAssertTrue(opf.contains("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"pub-id\">"))
        XCTAssertTrue(opf.contains("<dc:identifier id=\"pub-id\">https://archiveofourown.org/works/9999</dc:identifier>"))
        XCTAssertTrue(opf.contains("<dc:creator id=\"pseud_0\">Jane D.</dc:creator>"))
        XCTAssertTrue(opf.contains("<meta refines=\"#pseud_0\" property=\"file-as\">janedoe</meta>"))
        XCTAssertTrue(opf.contains("<meta refines=\"#pseud_0\" property=\"role\" scheme=\"marc:relators\">aut</meta>"))
        XCTAssertTrue(opf.contains("<dc:subject>General Audiences</dc:subject>"))
        XCTAssertTrue(opf.contains("<dc:subject>No Archive Warnings Apply</dc:subject>"))
        XCTAssertTrue(opf.contains("<dc:subject>Doctor Who</dc:subject>"))
        XCTAssertTrue(opf.contains("<dc:subject>Ten/Rose</dc:subject>"))
        XCTAssertTrue(opf.contains("<dc:subject>Fluff</dc:subject>"))
        XCTAssertTrue(opf.contains("<item id=\"toc\" href=\"toc.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"))
        XCTAssertTrue(opf.contains("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"))
        XCTAssertTrue(opf.contains("<item id=\"page_styles\" href=\"css/page_styles.css\" media-type=\"text/css\"/>"))
        XCTAssertTrue(opf.contains("<item id=\"chapter_1\" href=\"text/chapter_1.xhtml\" media-type=\"application/xhtml+xml\"/>"))
        XCTAssertTrue(opf.contains("<itemref idref=\"chapter_1\"/>"))
        XCTAssertTrue(opf.contains("<itemref idref=\"chapter_2\"/>"))
    }

    func testPackageOPFSeriesInjection() {
        let opf = AO3EPUB3Builder.buildPackageOPF(options: AO3EPUB3Builder.PackageOPFOptions(
            title: "Series Book",
            primarySeries: (name: "Epic Trilogy", index: 2)
        ))

        XCTAssertTrue(opf.contains("<meta name=\"calibre:series\" content=\"Epic Trilogy\"/>"))
        XCTAssertTrue(opf.contains("<meta name=\"calibre:series_index\" content=\"2\"/>"))
        XCTAssertTrue(opf.contains("<meta property=\"belongs-to-collection\" id=\"series_01\">Epic Trilogy</meta>"))
        XCTAssertTrue(opf.contains("<meta refines=\"#series_01\" property=\"group-position\">2</meta>"))
    }

    func testExportFilenameStandaloneNoZeroPrefix() {
        let book = CalibreBook(
            id: 42,
            title: "Standalone Story",
            relativePath: "Author A/Standalone Story (42)",
            authors: ["Author A"]
        )

        // Standalone work with seriesIndexPrefix == nil must NOT have "00 - "
        let nilAO3: AO3MetadataRecord? = nil
        let nilPrefix: Int? = nil
        let filename = book.exportFilename(ao3: nilAO3, seriesIndexPrefix: nilPrefix)
        XCTAssertEqual(filename, "Standalone Story-42.epub")
        XCTAssertFalse(filename.hasPrefix("00 - "))

        // Series work with seriesIndexPrefix == 1 gets zero-padded prefix
        let seriesFilename = book.exportFilename(ao3: nilAO3, seriesIndexPrefix: 1)
        XCTAssertEqual(seriesFilename, "01 - Standalone Story-42.epub")
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
        XCTAssertTrue(paths.contains("EPUB/content.opf"))
        XCTAssertTrue(paths.contains("EPUB/toc.xhtml"))
        XCTAssertTrue(paths.contains("EPUB/toc.ncx"))
        XCTAssertTrue(paths.contains("EPUB/text/imprint.xhtml"))
        XCTAssertTrue(paths.contains("EPUB/css/stylesheet.css"))
        XCTAssertTrue(paths.contains("EPUB/css/page_styles.css"))
        XCTAssertTrue(paths.contains("EPUB/text/chapter_1.xhtml"))

        // Verify container.xml points to EPUB/content.opf
        var extractedContainerData = Data()
        if let containerEntry = entries.first(where: { $0.path == "META-INF/container.xml" }) {
            _ = try? normalizedArchive.extract(containerEntry) { chunk in extractedContainerData.append(chunk) }
        }
        let containerStr = String(data: extractedContainerData, encoding: .utf8) ?? ""
        XCTAssertTrue(containerStr.contains("full-path=\"EPUB/content.opf\""))
    }

    func testEPUB3NormalizationPreservesOriginalAO3PrefaceAndHyperlinksWithoutDuplicate() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rawEPUBURL = tempDir.appendingPathComponent("raw_ao3.epub")
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
            <dc:title>AO3 Fanfic</dc:title>
            <dc:creator>Jane Doe</dc:creator>
          </metadata>
          <manifest>
            <item id="preface" href="split_000.xhtml" media-type="application/xhtml+xml"/>
            <item id="chapter1" href="split_001.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="preface"/>
            <itemref idref="chapter1"/>
          </spine>
        </package>
        """.utf8)
        try rawArchive.addEntry(
            with: "content.opf",
            type: .file,
            uncompressedSize: UInt32(opfData.count),
            compressionMethod: .none
        ) { pos, size in
            opfData.subdata(in: pos..<(pos + size))
        }

        let prefaceData = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Preface</title></head>
        <body class="calibre">
          <div id="preface" class="calibre1">
            <h2 class="toc-heading" id="calibre_toc_2">Preface</h2>
            <p class="message">
              <b>AO3 Fanfic</b><br/>
              Posted originally on the <a href="https://archiveofourown.org/">Archive of Our Own</a> at <a href="https://archiveofourown.org/works/12345">http://archiveofourown.org/works/12345</a>.
            </p>
            <div class="calibre1">
              <dl class="tags">
                <dt class="calibre3">Rating:</dt>
                <dd class="calibre4"><a href="https://archiveofourown.org/tags/Teen%20And%20Up%20Audiences">Teen And Up Audiences</a></dd>
                <dt class="calibre3">Fandom:</dt>
                <dd class="calibre4"><a href="https://archiveofourown.org/tags/Marvel">Marvel</a></dd>
              </dl>
            </div>
          </div>
        </body>
        </html>
        """.utf8)
        try rawArchive.addEntry(
            with: "split_000.xhtml",
            type: .file,
            uncompressedSize: UInt32(prefaceData.count),
            compressionMethod: .none
        ) { pos, size in
            prefaceData.subdata(in: pos..<(pos + size))
        }

        let chapterData = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter 1</title></head>
        <body>
          <h2>Chapter 1: The Adventure Begins</h2>
          <p>The story begins right here.</p>
        </body>
        </html>
        """.utf8)
        try rawArchive.addEntry(
            with: "split_001.xhtml",
            type: .file,
            uncompressedSize: UInt32(chapterData.count),
            compressionMethod: .none
        ) { pos, size in
            chapterData.subdata(in: pos..<(pos + size))
        }

        // Target normalized EPUB 3
        let targetEPUBURL = tempDir.appendingPathComponent("normalized_ao3.epub")

        try AO3EPUB3Normalizer.normalize(
            sourceEPUB: rawEPUBURL,
            destinationEPUB: targetEPUBURL,
            metadata: nil,
            bookTitle: "AO3 Fanfic",
            authors: ["Jane Doe"]
        )

        guard let normalizedArchive = Archive(url: targetEPUBURL, accessMode: .read) else {
            XCTFail("Failed to open normalized EPUB")
            return
        }

        var entryMap: [String: Entry] = [:]
        for entry in normalizedArchive {
            entryMap[entry.path] = entry
        }

        // 1. preface.xhtml must exist and imprint.xhtml must NOT exist
        XCTAssertTrue(entryMap.keys.contains("EPUB/text/preface.xhtml"), "Must emit preface.xhtml for AO3 work with preface")
        XCTAssertFalse(entryMap.keys.contains("EPUB/text/imprint.xhtml"), "Must not duplicate with synthetic imprint.xhtml")

        // 2. preface.xhtml must preserve original hyperlinks and avoid double "Preface" headings
        var prefaceEntryData = Data()
        if let entry = entryMap["EPUB/text/preface.xhtml"] {
            _ = try? normalizedArchive.extract(entry) { chunk in
                prefaceEntryData.append(chunk)
            }
        }
        let prefaceHTML = String(data: prefaceEntryData, encoding: .utf8) ?? ""
        XCTAssertTrue(prefaceHTML.contains("https://archiveofourown.org/tags/Teen%20And%20Up%20Audiences"), "Preserves tag hyperlinks")
        XCTAssertTrue(prefaceHTML.contains("https://archiveofourown.org/tags/Marvel"), "Preserves fandom hyperlinks")
        XCTAssertTrue(prefaceHTML.contains("https://archiveofourown.org/works/12345"), "Preserves work link")

        // Count occurrences of <h2>
        let h2Count = prefaceHTML.components(separatedBy: "<h2").count - 1
        XCTAssertEqual(h2Count, 1, "Must have exactly one <h2> heading, not two stacked Preface headings")
        let prefaceIdCount = prefaceHTML.components(separatedBy: "id=\"preface\"").count - 1
        XCTAssertEqual(prefaceIdCount, 1, "Must have exactly one id='preface' without duplicate outer section IDs")

        // 3. chapter_1.xhtml must be the first real chapter, not the preface
        var chapter1EntryData = Data()
        if let entry = entryMap["EPUB/text/chapter_1.xhtml"] {
            _ = try? normalizedArchive.extract(entry) { chunk in
                chapter1EntryData.append(chunk)
            }
        }
        let chapter1HTML = String(data: chapter1EntryData, encoding: .utf8) ?? ""
        XCTAssertTrue(chapter1HTML.contains("The Adventure Begins"), "chapter_1.xhtml is Chapter 1")
        XCTAssertFalse(chapter1HTML.contains("id=\"preface\""), "chapter_1.xhtml does not contain the preface")

        // 4. toc.xhtml must reference text/preface.xhtml and not list Preface as chapter 1
        var tocEntryData = Data()
        if let entry = entryMap["EPUB/toc.xhtml"] {
            _ = try? normalizedArchive.extract(entry) { chunk in
                tocEntryData.append(chunk)
            }
        }
        let tocHTML = String(data: tocEntryData, encoding: .utf8) ?? ""
        XCTAssertTrue(tocHTML.contains("href=\"text/preface.xhtml\""), "TOC references text/preface.xhtml")
        XCTAssertFalse(tocHTML.contains("href=\"text/imprint.xhtml\""), "TOC does not reference text/imprint.xhtml")
        XCTAssertFalse(tocHTML.contains("<li><a href=\"text/chapter_1.xhtml\">Preface</a></li>"), "TOC does not mislabel chapter 1 as Preface")
        XCTAssertFalse(tocHTML.contains("href=\"text/chapter_1.xhtml\">Preface</a>"), "TOC does not mislabel chapter 1 as Preface")
    }

    func testEPUB3NormalizationDeduplicatesHeadingsAndRewritesInternalLinks() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rawEPUBURL = tempDir.appendingPathComponent("raw_links.epub")
        guard let rawArchive = Archive(url: rawEPUBURL, accessMode: .create) else {
            XCTFail("Could not create raw archive")
            return
        }

        let mimetypeData = Data("application/epub+zip".utf8)
        try rawArchive.addEntry(
            with: "mimetype",
            type: .file,
            uncompressedSize: UInt32(mimetypeData.count),
            compressionMethod: .none
        ) { pos, size in
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
            <dc:title>Linked Work</dc:title>
          </metadata>
          <manifest>
            <item id="c1" href="split_001.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="split_002.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """.utf8)
        try rawArchive.addEntry(
            with: "content.opf",
            type: .file,
            uncompressedSize: UInt32(opfData.count),
            compressionMethod: .none
        ) { pos, size in
            opfData.subdata(in: pos..<(pos + size))
        }

        let chap1Data = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html>
        <body>
          <h2 id="top_anchor">Chapter 1: The First Chapter</h2>
          <p>Intro with link to <a href="split_002.xhtml#work_endnotes">(See end of work notes)</a></p>
          <p>Local footnote <a href="#local_fn">1</a></p>
          <p id="local_fn">Footnote text</p>
        </body>
        </html>
        """.utf8)
        try rawArchive.addEntry(
            with: "split_001.xhtml",
            type: .file,
            uncompressedSize: UInt32(chap1Data.count),
            compressionMethod: .none
        ) { pos, size in
            chap1Data.subdata(in: pos..<(pos + size))
        }

        let chap2Data = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html>
        <body>
          <h2>Chapter 2: The Finale</h2>
          <p>Conclusion referencing <a href="#top_anchor">beginning</a>.</p>
          <div id="work_endnotes"><p>End notes here.</p></div>
        </body>
        </html>
        """.utf8)
        try rawArchive.addEntry(
            with: "split_002.xhtml",
            type: .file,
            uncompressedSize: UInt32(chap2Data.count),
            compressionMethod: .none
        ) { pos, size in
            chap2Data.subdata(in: pos..<(pos + size))
        }

        let normalizedEPUBURL = tempDir.appendingPathComponent("normalized.epub")
        try AO3EPUB3Normalizer.normalize(
            sourceEPUB: rawEPUBURL,
            destinationEPUB: normalizedEPUBURL,
            metadata: nil,
            bookTitle: "Linked Work",
            authors: ["Jane Doe"]
        )

        guard let normalizedArchive = Archive(url: normalizedEPUBURL, accessMode: .read) else {
            XCTFail("Could not read normalized archive")
            return
        }

        var entryMap: [String: Entry] = [:]
        for entry in normalizedArchive {
            entryMap[entry.path] = entry
        }

        // 1. Verify chapter 1 heading is not duplicated
        var c1Data = Data()
        if let entry = entryMap["EPUB/text/chapter_1.xhtml"] {
            _ = try? normalizedArchive.extract(entry) { chunk in c1Data.append(chunk) }
        }
        let c1HTML = String(data: c1Data, encoding: .utf8) ?? ""
        let c1H2Count = c1HTML.components(separatedBy: "<h2").count - 1
        XCTAssertEqual(c1H2Count, 1, "Chapter 1 should only have 1 <h2> heading")
        XCTAssertTrue(c1HTML.contains("<h2>Chapter 1: The First Chapter</h2>"))

        // 2. Verify relative split link rewritten to chapter_2.xhtml#work_endnotes
        XCTAssertTrue(c1HTML.contains("href=\"chapter_2.xhtml#work_endnotes\""), "Rewrote cross-file link to chapter_2")
        // Local link in chapter 1 remains local
        XCTAssertTrue(c1HTML.contains("href=\"#local_fn\""), "Preserved local anchor link")

        // 3. Verify cross-file bare anchor in chapter 2 rewritten to chapter_1.xhtml#top_anchor
        var c2Data = Data()
        if let entry = entryMap["EPUB/text/chapter_2.xhtml"] {
            _ = try? normalizedArchive.extract(entry) { chunk in c2Data.append(chunk) }
        }
        let c2HTML = String(data: c2Data, encoding: .utf8) ?? ""
        let c2H2Count = c2HTML.components(separatedBy: "<h2").count - 1
        XCTAssertEqual(c2H2Count, 1, "Chapter 2 should only have 1 <h2> heading")
        XCTAssertTrue(c2HTML.contains("href=\"chapter_1.xhtml#top_anchor\""), "Rewrote bare fragment to chapter_1.xhtml")
    }

    func testEPUB3NormalizationImageRewritingAndNoCoverTagging() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rawEPUBURL = tempDir.appendingPathComponent("raw_img.epub")
        guard let rawArchive = try? Archive(url: rawEPUBURL, accessMode: .create, pathEncoding: nil) else {
            XCTFail("Could not create raw archive")
            return
        }

        let mimetypeData = Data("application/epub+zip".utf8)
        try rawArchive.addEntry(
            with: "mimetype",
            type: .file,
            uncompressedSize: Int64(mimetypeData.count),
            compressionMethod: .none
        ) { pos, size in
            mimetypeData.subdata(in: Int(pos)..<(Int(pos) + size))
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
            uncompressedSize: Int64(containerData.count),
            compressionMethod: .none
        ) { pos, size in
            containerData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        let opfData = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Image Test</dc:title>
          </metadata>
          <manifest>
            <item id="preface" href="split_000.xhtml" media-type="application/xhtml+xml"/>
            <item id="chapter1" href="split_001.xhtml" media-type="application/xhtml+xml"/>
            <item id="art" href="images/illustration.png" media-type="image/png"/>
            <item id="cover" href="images/cover_art.jpg" media-type="image/jpeg"/>
          </manifest>
          <spine>
            <itemref idref="preface"/>
            <itemref idref="chapter1"/>
          </spine>
        </package>
        """.utf8)
        try rawArchive.addEntry(
            with: "content.opf",
            type: .file,
            uncompressedSize: Int64(opfData.count),
            compressionMethod: .none
        ) { pos, size in
            opfData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        let prefaceData = Data("""
        <div id="preface"><p class="message"><a href="https://archiveofourown.org/works/99999">Story</a></p><dl class="tags"></dl></div>
        """.utf8)
        try rawArchive.addEntry(
            with: "split_000.xhtml",
            type: .file,
            uncompressedSize: Int64(prefaceData.count),
            compressionMethod: .none
        ) { pos, size in
            prefaceData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        let chapterData = Data("""
        <div class="userstuff"><p>Text</p><img src="images/illustration.png" alt="art"/><img src="cover_art.jpg" alt="cover"/></div>
        """.utf8)
        try rawArchive.addEntry(
            with: "split_001.xhtml",
            type: .file,
            uncompressedSize: Int64(chapterData.count),
            compressionMethod: .none
        ) { pos, size in
            chapterData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        let dummyImgData = Data([0x89, 0x50, 0x4E, 0x47])
        try rawArchive.addEntry(
            with: "images/illustration.png",
            type: .file,
            uncompressedSize: Int64(dummyImgData.count),
            compressionMethod: .none
        ) { pos, size in
            dummyImgData.subdata(in: Int(pos)..<(Int(pos) + size))
        }
        try rawArchive.addEntry(
            with: "images/cover_art.jpg",
            type: .file,
            uncompressedSize: Int64(dummyImgData.count),
            compressionMethod: .none
        ) { pos, size in
            dummyImgData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        let normalizedEPUBURL = tempDir.appendingPathComponent("normalized_img.epub")
        try AO3EPUB3Normalizer.normalize(
            sourceEPUB: rawEPUBURL,
            destinationEPUB: normalizedEPUBURL,
            metadata: nil
        )

        guard let normalizedArchive = try? Archive(url: normalizedEPUBURL, accessMode: .read, pathEncoding: nil) else {
            XCTFail("Failed to read normalized archive")
            return
        }

        var entryMap: [String: Entry] = [:]
        for entry in normalizedArchive {
            entryMap[entry.path] = entry
        }

        // Verify images stored under EPUB/images/
        XCTAssertNotNil(entryMap["EPUB/images/illustration.png"])
        XCTAssertNotNil(entryMap["EPUB/images/cover_art.jpg"])

        // Verify chapter HTML rewrites img src to ../images/
        var c1Data = Data()
        if let entry = entryMap["EPUB/text/chapter_1.xhtml"] {
            _ = try? normalizedArchive.extract(entry) { chunk in c1Data.append(chunk) }
        }
        let c1HTML = String(data: c1Data, encoding: .utf8) ?? ""
        XCTAssertTrue(c1HTML.contains("src=\"../images/illustration.png\""))
        XCTAssertTrue(c1HTML.contains("src=\"../images/cover_art.jpg\""))

        // Verify content.opf does NOT tag with properties="cover-image"
        var opfEntryData = Data()
        if let entry = entryMap["EPUB/content.opf"] {
            _ = try? normalizedArchive.extract(entry) { chunk in opfEntryData.append(chunk) }
        }
        let opfHTML = String(data: opfEntryData, encoding: .utf8) ?? ""
        XCTAssertFalse(opfHTML.contains("properties=\"cover-image\""))
    }

    func testAO3OmnibusBuilderGeneratesCompliantEPUB3Layout() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a minimal EPUB for part 1
        let part1EPUBURL = tempDir.appendingPathComponent("part1.epub")
        guard let part1Archive = try? Archive(url: part1EPUBURL, accessMode: .create, pathEncoding: nil) else {
            XCTFail("Failed to create part 1 archive")
            return
        }
        let mimetypeData = Data("application/epub+zip".utf8)
        try part1Archive.addEntry(
            with: "mimetype",
            type: .file,
            uncompressedSize: Int64(mimetypeData.count),
            compressionMethod: .none
        ) { pos, size in
            mimetypeData.subdata(in: Int(pos)..<(Int(pos) + size))
        }
        let containerData = Data("""
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8)
        try part1Archive.addEntry(
            with: "META-INF/container.xml",
            type: .file,
            uncompressedSize: Int64(containerData.count),
            compressionMethod: .none
        ) { pos, size in
            containerData.subdata(in: Int(pos)..<(Int(pos) + size))
        }
        let opfData = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Part 1 Title</dc:title></metadata>
          <manifest><item id="chap1" href="chap1.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="chap1"/></spine>
        </package>
        """.utf8)
        try part1Archive.addEntry(
            with: "content.opf",
            type: .file,
            uncompressedSize: Int64(opfData.count),
            compressionMethod: .none
        ) { pos, size in
            opfData.subdata(in: Int(pos)..<(Int(pos) + size))
        }
        let chapData = Data("<html><body><h1>Part 1</h1><p>Chapter text.</p></body></html>".utf8)
        try part1Archive.addEntry(
            with: "chap1.xhtml",
            type: .file,
            uncompressedSize: Int64(chapData.count),
            compressionMethod: .none
        ) { pos, size in
            chapData.subdata(in: Int(pos)..<(Int(pos) + size))
        }

        let book = CalibreBook(id: 1, title: "Part 1 Story", relativePath: "part1.epub", authors: ["Captain Author"])
        let series = SeriesGroup(
            id: "series:test_omnibus",
            seriesKey: "series:test_omnibus",
            seriesName: "Space Chronicles",
            works: [book],
            allFandoms: ["Sci-Fi"],
            allRelationships: [],
            allCharacters: [],
            allCategories: [],
            allWarnings: [],
            allRatings: [],
            allAdditionalTags: [],
            allTags: [],
            allAuthors: ["Captain Author"],
            allDescriptions: [],
            totalWordCount: 50000,
            chapterCurrentTotal: 1,
            chapterTotalTotal: 1,
            hasUnknownChapterTotal: false,
            earliestPublished: nil,
            latestUpdated: nil,
            workIndices: [1],
            missingIndices: [],
            placeholders: [],
            isComplete: true
        )

        let targetEPUB = tempDir.appendingPathComponent("omnibus_output.epub")
        try AO3OmnibusBuilder.buildOmnibus(
            series: series,
            libraryRoot: tempDir,
            metadataByID: [:],
            incompletePolicy: .includeWithPlaceholders,
            unfinishedPolicy: .tagAsWIP,
            destinationEPUB: targetEPUB
        )

        guard let archive = try? Archive(url: targetEPUB, accessMode: .read, pathEncoding: nil) else {
            XCTFail("Failed to read omnibus archive")
            return
        }

        var entryMap: [String: Entry] = [:]
        for entry in archive {
            entryMap[entry.path] = entry
        }

        // Verify required EPUB/ structure and stylesheets
        XCTAssertNotNil(entryMap["EPUB/css/stylesheet.css"])
        XCTAssertNotNil(entryMap["EPUB/css/page_styles.css"])
        XCTAssertNotNil(entryMap["EPUB/toc.xhtml"])
        XCTAssertNotNil(entryMap["EPUB/text/imprint.xhtml"])
        XCTAssertNotNil(entryMap["EPUB/text/afterword.xhtml"])

        // Verify TOC links
        var tocData = Data()
        if let entry = entryMap["EPUB/toc.xhtml"] {
            _ = try? archive.extract(entry) { chunk in tocData.append(chunk) }
        }
        let tocHTML = String(data: tocData, encoding: .utf8) ?? ""
        XCTAssertTrue(tocHTML.contains("href=\"css/stylesheet.css\""))
        XCTAssertTrue(tocHTML.contains("href=\"text/imprint.xhtml\""))
        XCTAssertTrue(tocHTML.contains("href=\"text/afterword.xhtml\""))

        // Verify Imprint and Afterword stylesheet links
        var imprintData = Data()
        if let entry = entryMap["EPUB/text/imprint.xhtml"] {
            _ = try? archive.extract(entry) { chunk in imprintData.append(chunk) }
        }
        let imprintHTML = String(data: imprintData, encoding: .utf8) ?? ""
        XCTAssertTrue(imprintHTML.contains("href=\"../css/stylesheet.css\""))
        XCTAssertTrue(imprintHTML.contains("href=\"../css/page_styles.css\""))

        var afterwordData = Data()
        if let entry = entryMap["EPUB/text/afterword.xhtml"] {
            _ = try? archive.extract(entry) { chunk in afterwordData.append(chunk) }
        }
        let afterwordHTML = String(data: afterwordData, encoding: .utf8) ?? ""
        XCTAssertTrue(afterwordHTML.contains("href=\"../css/stylesheet.css\""))
        XCTAssertTrue(afterwordHTML.contains("href=\"../css/page_styles.css\""))
    }
}
