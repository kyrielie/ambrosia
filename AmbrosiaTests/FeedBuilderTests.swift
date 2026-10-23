import XCTest
@testable import Ambrosia

final class FeedBuilderTests: XCTestCase {

    // MARK: - OPMLFeedBuilder Tests

    func testOPMLFeedBuilderBuildsValidOPML() {
        let collections = [
            CollectionRow(id: "col-1", name: "Favorites", kind: "manual", isSystem: false, createdAt: "2024-01-01", sortOrder: 0),
            CollectionRow(id: "col-2", name: "To Read & Review", kind: "manual", isSystem: false, createdAt: "2024-01-02", sortOrder: 1)
        ]
        let snapshot = CurrentSearchSnapshot(
            calibreIDs: [1, 2],
            publishedAt: "2024-01-01T00:00:00Z",
            label: "Search: Drama & Mystery"
        )

        let opml = OPMLFeedBuilder.buildOPML(
            collections: collections,
            dailyEnabled: true,
            searchSnapshot: snapshot,
            baseURL: "http://192.168.1.100:8765"
        )

        XCTAssertTrue(opml.contains("<opml version=\"2.0\">"))
        XCTAssertTrue(opml.contains("<title>Ambrosia Library Feeds</title>"))
        XCTAssertTrue(opml.contains("title=\"Favorites\""))
        XCTAssertTrue(opml.contains("xmlUrl=\"http://192.168.1.100:8765/feed/collection/col-1.xml\""))
        XCTAssertTrue(opml.contains("title=\"To Read &amp; Review\""))
        XCTAssertTrue(opml.contains("title=\"Daily Story\""))
        XCTAssertTrue(opml.contains("xmlUrl=\"http://192.168.1.100:8765/feed/random-daily.xml\""))
        XCTAssertTrue(opml.contains("title=\"Search: Search: Drama &amp; Mystery\""))
        XCTAssertTrue(opml.contains("</opml>"))
    }

    func testOPMLFeedBuilderEmptyFeedComment() {
        let opml = OPMLFeedBuilder.buildOPML(
            collections: [],
            dailyEnabled: false,
            searchSnapshot: nil,
            baseURL: "http://localhost:8765"
        )

        XCTAssertTrue(opml.contains("<!-- No collections or search snapshot to export. -->"))
    }

    // MARK: - RSSFeedBuilder Tests

    func testRSSFeedBuilderBuildsChannelAndItem() {
        let book = CalibreBook(
            id: 42,
            title: "Pride & Prejudice & Zombies",
            series: "Zombies Series",
            seriesIndex: 1.0,
            wordCount: 12000,
            kudos: 500,
            publishedDate: Date(timeIntervalSince1970: 1600000000),
            publisher: "Calibre",
            relativePath: "Jane/Zombies (42)",
            authors: ["Jane Austen", "Seth Grahame-Smith"],
            tags: ["Horror", "Classics"],
            comment: "<p>A classic tale of the undead.</p>"
        )

        let ao3 = AO3MetadataRecord(
            storyURL: "https://archiveofourown.org/works/4242",
            workID: "4242",
            authors: [AO3AuthorEntry(username: "Jane Austen", pseud: nil, profileURL: nil, source: .byline)],
            kudosCount: 500,
            wordCount: 12000,
            chapterCurrent: 5,
            chapterTotal: 10,
            isComplete: false,
            language: "en",
            publishedDate: "2020-09-13T12:00:00Z",
            updatedDate: "2020-09-14T12:00:00Z",
            fandoms: ["Pride and Prejudice"],
            relationships: ["Elizabeth/Darcy"],
            characters: ["Elizabeth Bennet", "Fitzwilliam Darcy"],
            additionalTags: ["Zombies"],
            categories: ["F/M"],
            ao3Collections: [],
            series: [],
            rating: "Teen And Up Audiences",
            warnings: ["Graphic Depictions Of Violence"],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        let itemXML = RSSFeedBuilder.buildRSSItem(
            book: book,
            ao3: ao3,
            seriesEntries: [],
            contentEncoded: "<div>Chapter 1 content with &lt;entities&gt;</div>"
        )

        XCTAssertTrue(itemXML.contains("<title>Pride &amp; Prejudice &amp; Zombies</title>"))
        XCTAssertTrue(itemXML.contains("<guid isPermaLink=\"false\">ambrosia-book-42</guid>"))
        XCTAssertTrue(itemXML.contains("<link>https://archiveofourown.org/works/4242</link>"))
        XCTAssertTrue(itemXML.contains("<author>Jane Austen, Seth Grahame-Smith</author>"))
        XCTAssertTrue(itemXML.contains("<ambrosia:workID>4242</ambrosia:workID>"))
        XCTAssertTrue(itemXML.contains("<content:encoded><![CDATA[<div>Chapter 1 content with &lt;entities&gt;</div>]]></content:encoded>"))

        let feedXML = RSSFeedBuilder.buildFeed(
            title: "Custom Reading Feed",
            feedDescription: "Fics & Stories",
            items: [itemXML]
        )

        XCTAssertTrue(feedXML.contains("<title>Custom Reading Feed</title>"))
        XCTAssertTrue(feedXML.contains("<description>Fics &amp; Stories</description>"))
        XCTAssertTrue(feedXML.contains("<generator>Ambrosia</generator>"))
        XCTAssertTrue(feedXML.contains("</channel>"))
        XCTAssertTrue(feedXML.contains("</rss>"))
    }

    func testRSSFeedBuilderEmptyFeed() {
        let emptyXML = RSSFeedBuilder.buildEmptyFeed(title: "Empty Feed", message: "No items found")
        XCTAssertTrue(emptyXML.contains("<title>Empty Feed</title>"))
        XCTAssertTrue(emptyXML.contains("<description>No items found</description>"))
        XCTAssertFalse(emptyXML.contains("<item>"))
    }

    // MARK: - JSONFeedBuilder Tests

    func testJSONFeedBuilderBuildsValidDocumentAndItem() throws {
        let book = CalibreBook(
            id: 101,
            title: "Galactic Voyage",
            series: nil,
            seriesIndex: nil,
            wordCount: 85000,
            kudos: 1200,
            publishedDate: Date(timeIntervalSince1970: 1700000000),
            publisher: nil,
            relativePath: "SciFi/Galactic (101)",
            authors: ["Captain Cosmos"],
            tags: ["Explicit", "Science Fiction", "Space Opera"],
            comment: "<p>A deep space adventure.</p>"
        )

        let ao3 = AO3MetadataRecord(
            storyURL: "https://archiveofourown.org/works/10101",
            workID: "10101",
            authors: [AO3AuthorEntry(username: "Captain Cosmos", pseud: nil, profileURL: "https://archiveofourown.org/users/cosmos", source: .byline)],
            kudosCount: 1200,
            wordCount: 85000,
            chapterCurrent: 20,
            chapterTotal: 20,
            isComplete: true,
            language: "en",
            publishedDate: "2023-11-14T22:13:20Z",
            updatedDate: "2023-11-15T01:00:00Z",
            fandoms: ["Cosmos Fandom"],
            relationships: [],
            characters: ["Navigator"],
            additionalTags: ["First Contact"],
            categories: [],
            ao3Collections: [],
            series: [AO3MetadataRecord.SeriesEntry(name: "Cosmic Saga", index: 1, ao3ID: "999")],
            rating: "Explicit",
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )

        let item = JSONFeedBuilder.buildJSONFeedItem(
            book: book,
            ao3: ao3,
            seriesEntries: [],
            contentHTML: "<h1>Prologue</h1><p>The starship hummed.</p>"
        )

        XCTAssertEqual(item.id, "ambrosia-book-101")
        XCTAssertEqual(item.title, "Galactic Voyage")
        XCTAssertEqual(item.url, "https://archiveofourown.org/works/10101")
        XCTAssertEqual(item.authors?.first?.name, "Captain Cosmos")
        XCTAssertEqual(item.authors?.first?.url, "https://archiveofourown.org/users/cosmos")
        XCTAssertEqual(item.contentHTML, "<h1>Prologue</h1><p>The starship hummed.</p>")
        XCTAssertEqual(item.summary, "A deep space adventure.")
        XCTAssertEqual(item.ambrosiaExtension?.wordCount, 85000)
        XCTAssertEqual(item.ambrosiaExtension?.isComplete, true)
        XCTAssertEqual(item.ambrosiaExtension?.ao3WorkID, "10101")
        XCTAssertEqual(item.ambrosiaExtension?.ratings, ["Explicit"])

        let document = JSONFeedBuilder.buildJSONFeedDocument(
            title: "Sci-Fi JSON Feed",
            feedDescription: "Latest Space Operas",
            feedURL: "http://localhost:8765/feed/scifi.json",
            nextURL: "http://localhost:8765/feed/scifi.json?page=2",
            items: [item]
        )

        let data = try XCTUnwrap(JSONFeedBuilder.encode(document))
        let decoded = try JSONDecoder().decode(JSONFeedDocument.self, from: data)

        XCTAssertEqual(decoded.version, "https://jsonfeed.org/version/1.1")
        XCTAssertEqual(decoded.title, "Sci-Fi JSON Feed")
        XCTAssertEqual(decoded.feedURL, "http://localhost:8765/feed/scifi.json")
        XCTAssertEqual(decoded.nextURL, "http://localhost:8765/feed/scifi.json?page=2")
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertEqual(decoded.items.first?.id, "ambrosia-book-101")
        XCTAssertEqual(decoded.items.first?.ambrosiaExtension?.ratings, ["Explicit"])
    }

    func testJSONFeedBuilderEmptyFeedData() throws {
        let data = JSONFeedBuilder.buildEmptyJSONFeed(
            title: "Empty JSON",
            feedDescription: "No items",
            feedURL: "http://localhost:8765/feed/empty.json"
        )
        let decoded = try JSONDecoder().decode(JSONFeedDocument.self, from: data)
        XCTAssertEqual(decoded.title, "Empty JSON")
        XCTAssertTrue(decoded.items.isEmpty)
    }
}
