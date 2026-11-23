import XCTest
@testable import Ambrosia

final class SeriesGapManifestTests: XCTestCase {

    func testSeriesGapAnalysisWithInfixAndPrefixGaps() {
        let books = [
            CalibreBook(id: 1, title: "Part 2 Title", relativePath: "p2", authors: ["Author One"]),
            CalibreBook(id: 2, title: "Part 4 Title", relativePath: "p4", authors: ["Author One"])
        ]

        let series = SeriesGroup(
            id: "series:1",
            seriesKey: "series:1",
            seriesName: "The Great Saga",
            works: books,
            allFandoms: ["Harry Potter"],
            allRelationships: [],
            allCharacters: [],
            allCategories: [],
            allWarnings: [],
            allRatings: [],
            allAdditionalTags: [],
            allTags: [],
            allAuthors: ["Author One"],
            allDescriptions: [],
            totalWordCount: 50000,
            chapterCurrentTotal: 10,
            chapterTotalTotal: 10,
            hasUnknownChapterTotal: false,
            earliestPublished: nil,
            latestUpdated: nil,
            workIndices: [2, 4],
            missingIndices: [1, 3],
            isComplete: false
        )

        let metadataByID: [Int: AO3MetadataRecord] = [
            1: AO3MetadataRecord(
                storyURL: "https://archiveofourown.org/works/10002",
                workID: "10002",
                authors: [AO3AuthorEntry(username: "author1", pseud: nil, profileURL: nil, source: .byline)],
                kudosCount: 100,
                wordCount: 25000,
                chapterCurrent: 5,
                chapterTotal: 5,
                isComplete: true,
                language: "en",
                publishedDate: "2021-01-01",
                updatedDate: "2021-01-05",
                fandoms: ["Harry Potter"],
                relationships: [],
                characters: [],
                additionalTags: [],
                categories: [],
                ao3Collections: [],
                series: [AO3MetadataRecord.SeriesEntry(name: "The Great Saga", index: 2, ao3ID: "9999")],
                rating: "General Audiences",
                warnings: [],
                extractedAt: "2021-01-06"
            ),
            2: AO3MetadataRecord(
                storyURL: "https://archiveofourown.org/works/10004",
                workID: "10004",
                authors: [AO3AuthorEntry(username: "author1", pseud: nil, profileURL: nil, source: .byline)],
                kudosCount: 120,
                wordCount: 25000,
                chapterCurrent: 5,
                chapterTotal: 5,
                isComplete: true,
                language: "en",
                publishedDate: "2021-02-01",
                updatedDate: "2021-02-05",
                fandoms: ["Harry Potter"],
                relationships: [],
                characters: [],
                additionalTags: [],
                categories: [],
                ao3Collections: [],
                series: [AO3MetadataRecord.SeriesEntry(name: "The Great Saga", index: 4, ao3ID: "9999")],
                rating: "General Audiences",
                warnings: [],
                extractedAt: "2021-02-06"
            )
        ]

        let report = SeriesGapAnalyzer.analyze(series: series, metadataByID: metadataByID)

        XCTAssertEqual(report.seriesName, "The Great Saga")
        XCTAssertEqual(report.ao3SeriesID, "9999")
        XCTAssertEqual(report.presentIndices, [2, 4])
        XCTAssertEqual(report.missingIndices, [1, 3])
        XCTAssertEqual(report.totalKnownParts, 4)
        XCTAssertEqual(report.coverageFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.coveragePercentageString, "50%")
        XCTAssertEqual(report.items.count, 4)

        // Part 1 missing, Part 2 present, Part 3 missing, Part 4 present
        XCTAssertFalse(report.items[0].isPresent)
        XCTAssertEqual(report.items[0].partIndex, 1)
        XCTAssertTrue(report.items[1].isPresent)
        XCTAssertEqual(report.items[1].partIndex, 2)
        XCTAssertFalse(report.items[2].isPresent)
        XCTAssertEqual(report.items[2].partIndex, 3)
        XCTAssertTrue(report.items[3].isPresent)
        XCTAssertEqual(report.items[3].partIndex, 4)
    }

    func testManifestGenerationFormatting() {
        let items: [SeriesGapItem] = [
            SeriesGapItem(partIndex: 1, isPresent: false, title: "Part 1 (Missing)", wordCount: nil, workID: nil, url: URL(string: "https://archiveofourown.org/series/555")),
            SeriesGapItem(partIndex: 2, isPresent: true, title: "Part 2 Story", wordCount: 15000, workID: "888", url: URL(string: "https://archiveofourown.org/works/888")),
            SeriesGapItem(partIndex: 3, isPresent: false, title: "Part 3 (Missing)", wordCount: nil, workID: nil, url: URL(string: "https://archiveofourown.org/series/555"))
        ]

        let report = SeriesGapReport(
            seriesKey: "series:555",
            seriesName: "Magic & Myth",
            ao3SeriesID: "555",
            authors: ["Jane Doe"],
            presentIndices: [2],
            missingIndices: [1, 3],
            totalKnownParts: 3,
            items: items
        )

        // Text Manifest
        let text = SeriesGapManifestBuilder.generateTextManifest(report: report)
        XCTAssertTrue(text.contains("# Series: Magic & Myth by Jane Doe"))
        XCTAssertTrue(text.contains("# Run with: ao3downloader -f Magic___Myth.txt"))
        XCTAssertTrue(text.contains("https://archiveofourown.org/series/555"))

        // HTML Manifest
        let html = SeriesGapManifestBuilder.generateHTMLManifest(report: report)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("Magic &amp; Myth"))
        XCTAssertTrue(html.contains("Jane Doe"))
        XCTAssertTrue(html.contains("1 of 3 Works (33%)"))
        XCTAssertTrue(html.contains("class=\"badge missing\""))
        XCTAssertTrue(html.contains("class=\"badge present\""))
        XCTAssertTrue(html.contains("navigator.clipboard.writeText"))
    }
}
