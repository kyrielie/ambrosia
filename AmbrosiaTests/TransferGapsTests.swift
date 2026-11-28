import Foundation
import SQLite
import SwiftSoup
import Testing
@testable import Ambrosia

@Suite("Transfer Gaps & Nectar EPUB Round-Trip Tests")
struct TransferGapsTests {

    @Test("JSONFeedBuilder serializes ao3Language, collections, kudos, additionalTags, and isRestricted")
    func testJSONFeedExtensionFields() throws {
        let book = CalibreBook(
            id: 101,
            title: "Test Work",
            wordCount: 5000,
            relativePath: "Writer/Test Work (101)",
            authors: ["Writer"],
            tags: ["Alternate Universe", "Teen And Up Audiences"],
            comment: "Summary text"
        )
        let ao3 = AO3MetadataRecord(
            storyURL: "https://archiveofourown.org/works/99999",
            workID: "99999",
            authors: [],
            kudosCount: 412,
            wordCount: 5000,
            chapterCurrent: 2,
            chapterTotal: 2,
            isComplete: true,
            language: "English",
            publishedDate: "2025-01-01",
            updatedDate: "2025-01-05",
            fandoms: ["Original Work"],
            relationships: ["A/B"],
            characters: ["A", "B"],
            additionalTags: ["Slow Burn", "Found Family"],
            categories: ["F/F"],
            ao3Collections: ["Winter Exchange", "Favorites"],
            series: [],
            rating: "Teen And Up Audiences",
            warnings: ["No Archive Warnings Apply"],
            extractedAt: "2025-01-06T00:00:00Z",
            isRestricted: true
        )

        let item = JSONFeedBuilder.buildJSONFeedItem(
            book: book,
            ao3: ao3,
            seriesEntries: [],
            contentHTML: "<p>Body</p>"
        )
        guard let ext = item.ambrosiaExtension else {
            Issue.record("Expected ambrosiaExtension")
            return
        }
        #expect(ext.ao3Language == "English")
        #expect(ext.collections == ["Winter Exchange", "Favorites"])
        #expect(ext.kudos == 412)
        #expect(ext.additionalTags == ["Slow Burn", "Found Family"])
        #expect(ext.isRestricted == true)
    }

    @Test("TransferDatabaseBuilder defaults to wire_version 1 and emits v2 columns when requested")
    func testTransferDatabaseWireVersions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let row = TransferDatabaseBuilder.Row(
            calibreID: 1,
            ao3WorkID: "123",
            isAnthology: false,
            ao3SeriesID: nil,
            seriesName: nil,
            url: "https://archiveofourown.org/works/123",
            title: "Work",
            contentHTML: "<p>Hi</p>",
            summary: nil,
            datePublished: nil,
            dateModified: nil,
            authorsJSON: "[]",
            tagsJSON: "[\"Slow Burn\"]",
            wordCount: 1000,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            fandomsJSON: "[]",
            relationshipsJSON: "[]",
            charactersJSON: "[]",
            ratingsJSON: "[]",
            warningsJSON: "[]",
            categoriesJSON: "[]",
            seriesJSON: "[]",
            isReadLater: false,
            isLiked: false,
            isFinished: false,
            readingProgress: nil,
            ao3Language: "English",
            collectionsJSON: "[\"Col 1\"]",
            kudos: 88,
            additionalTagsJSON: "[\"Slow Burn\"]",
            isRestricted: true
        )
        let manifest = TransferDatabaseBuilder.ManifestRow(
            walkID: "walk-1",
            pageNumber: 1,
            hasMore: false,
            pageRowCount: 1,
            expectedTotalRowCount: 1
        )

        let v1URL = tempDir.appendingPathComponent("v1.sqlite")
        try TransferDatabaseBuilder.build(rows: [row], manifest: manifest, wireVersion: 1, at: v1URL)
        let v1Conn = try Connection(v1URL.path, readonly: true)
        let v1Version = try v1Conn.scalar("PRAGMA user_version") as? Int64
        #expect(v1Version == 1)

        let v2URL = tempDir.appendingPathComponent("v2.sqlite")
        try TransferDatabaseBuilder.build(rows: [row], manifest: manifest, wireVersion: 2, at: v2URL)
        let v2Conn = try Connection(v2URL.path, readonly: true)
        let v2Version = try v2Conn.scalar("PRAGMA user_version") as? Int64
        #expect(v2Version == 2)
        let kudosVal = try v2Conn.scalar("SELECT kudos FROM items LIMIT 1") as? Int64
        let langVal = try v2Conn.scalar("SELECT ao3_language FROM items LIMIT 1") as? String
        let restrictedVal = try v2Conn.scalar("SELECT is_restricted FROM items LIMIT 1") as? Int64
        #expect(kudosVal == 88)
        #expect(langVal == "English")
        #expect(restrictedVal == 1)
    }

    @Test("NectarEPUBParser extracts tags, stats-block, series, byline, and restricted flag")
    func testNectarEPUBParser() throws {
        let html = """
        <html><body>
        <section id="preface" epub:type="preface">
            <p class="byline"><a rel="author" href="/users/testauthor">testauthor</a></p>
            <dl class="tags-dl">
                <dt>Rating:</dt><dd>Mature</dd>
                <dt>Fandoms:</dt><dd>Fandom A, Fandom B</dd>
                <dt>Additional Tags:</dt><dd><a href="/tags/1">Angst</a>, <a href="/tags/2">Hurt/Comfort</a></dd>
                <dt>Collections:</dt><dd>Autumn Fest</dd>
                <dt>Language:</dt><dd>English</dd>
                <dt>Series:</dt><dd>Part #2 of <a href="/series/555">Test Series</a></dd>
            </dl>
            <div class="stats-block">
                Published: 2025-02-01 Completed: 2025-02-10 Words: 12,345 Chapters: 3/3 Kudos: 987 🔒 Restricted
            </div>
        </section>
        </body></html>
        """
        let doc = try SwiftSoup.parse(html)
        let parsed = NectarEPUBParser.parse(document: doc)
        guard case .ao3(let record) = parsed else {
            Issue.record("Expected NectarEPUBParser to return .ao3 record")
            return
        }
        #expect(record.authors.first?.username == "testauthor")
        #expect(record.rating == "Mature")
        #expect(record.fandoms == ["Fandom A", "Fandom B"])
        #expect(record.additionalTags == ["Angst", "Hurt/Comfort"])
        #expect(record.ao3Collections == ["Autumn Fest"])
        #expect(record.language == "English")
        #expect(record.series.first?.index == 2)
        #expect(record.series.first?.ao3ID == "555")
        #expect(record.wordCount == 12345)
        #expect(record.kudosCount == 987)
        #expect(record.isComplete == true)
        #expect(record.isRestricted == true)
    }
}
