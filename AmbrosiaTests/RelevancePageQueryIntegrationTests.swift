// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

final class RelevancePageQueryIntegrationTests: XCTestCase {

    private var libraryRoot: URL?
    private var library: CalibreLibrary?
    private var metaDB: AmbrosiaMetaDB?

    override func setUpWithError() throws {
        let root = try CalibreTestFixture.makeTempLibraryRoot()
        libraryRoot = root
        library = try CalibreLibrary(root: root)
        metaDB = try AmbrosiaMetaDB(libraryURL: root)
    }

    override func tearDownWithError() throws {
        library = nil
        metaDB = nil
        if let root = libraryRoot {
            try? FileManager.default.removeItem(at: root)
        }
        libraryRoot = nil
    }

    private func seedAO3Metadata() async throws {
        guard let metaDB else { return }

        // Book 769: "The Sleeping Beauty Curse"
        // Target pairing at index 0 (first-listed)
        let rec769 = AO3MetadataRecord(
            storyURL: nil, workID: nil, authors: [], kudosCount: nil, wordCount: 1500,
            chapterCurrent: 1, chapterTotal: 1, isComplete: true, language: "English",
            publishedDate: nil, updatedDate: nil, fandoms: ["Marvel"],
            relationships: ["Tony Stark/Steve Rogers"],
            characters: ["Tony Stark", "Steve Rogers"],
            additionalTags: ["Fluff"], categories: ["M/M"], ao3Collections: [],
            series: [], rating: "General", warnings: [], extractedAt: "2024-01-01T00:00:00Z"
        )

        // Book 3095: "Check, Please!..."
        // Target pairing at index 1 (secondary pairing)
        let rec3095 = AO3MetadataRecord(
            storyURL: nil, workID: nil, authors: [], kudosCount: nil, wordCount: 2500,
            chapterCurrent: 1, chapterTotal: 1, isComplete: true, language: "English",
            publishedDate: nil, updatedDate: nil, fandoms: ["Marvel"],
            relationships: ["Thor/Loki", "Tony Stark/Steve Rogers"],
            characters: ["Thor", "Loki", "Tony Stark", "Steve Rogers"],
            additionalTags: ["Angst"], categories: ["M/M"], ao3Collections: [],
            series: [], rating: "Mature", warnings: [], extractedAt: "2024-01-01T00:00:00Z"
        )

        try await metaDB.insertBatch([(rec769, 769), (rec3095, 3095)], diagnostics: [])
    }

    func testTagEqualsRuleOrdersFirstListedAheadOfLater() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        let targets = TagRelevanceTargets(exact: ["Tony Stark/Steve Rogers"], contains: [])
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])

        let pageQuery = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [3095, 769],
            metaDB: metaDB,
            relevanceTargets: targets
        )

        let (page, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, pageQuery)
        XCTAssertEqual(page.map(\.id), [769, 3095])
    }

    func testRelevanceRecomputedWhenTargetsChangeWithSameRestrictIDs() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let targetsA = TagRelevanceTargets(exact: ["Tony Stark/Steve Rogers"], contains: [])
        let targetsB = TagRelevanceTargets(exact: ["Thor/Loki"], contains: [])

        let queryA = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [3095, 769],
            metaDB: metaDB,
            relevanceTargets: targetsA
        )
        let (pageA, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, queryA)
        XCTAssertEqual(pageA.map(\.id), [769, 3095])

        let queryB = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [3095, 769],
            metaDB: metaDB,
            relevanceTargets: targetsB
        )
        let (pageB, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, queryB)
        XCTAssertEqual(pageB.map(\.id), [3095, 769])
    }

    func testRelevanceRecomputedAfterExtractionFlush() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let targets = TagRelevanceTargets(exact: ["Tony Stark/Steve Rogers"], contains: [])

        let query = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [3095, 769],
            metaDB: metaDB,
            relevanceTargets: targets
        )
        let (page1, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, query)
        XCTAssertEqual(page1.map(\.id), [769, 3095])

        // Swap tag order in book 3095 so it becomes index 0, and make 769 index 1
        let updated3095 = AO3MetadataRecord(
            storyURL: nil, workID: nil, authors: [], kudosCount: nil, wordCount: 2500,
            chapterCurrent: 1, chapterTotal: 1, isComplete: true, language: "English",
            publishedDate: nil, updatedDate: nil, fandoms: ["Marvel"],
            relationships: ["Tony Stark/Steve Rogers", "Thor/Loki"],
            characters: ["Thor", "Loki", "Tony Stark", "Steve Rogers"],
            additionalTags: ["Angst"], categories: ["M/M"], ao3Collections: [],
            series: [], rating: "Mature", warnings: [], extractedAt: "2024-01-02T00:00:00Z"
        )
        let updated769 = AO3MetadataRecord(
            storyURL: nil, workID: nil, authors: [], kudosCount: nil, wordCount: 1500,
            chapterCurrent: 1, chapterTotal: 1, isComplete: true, language: "English",
            publishedDate: nil, updatedDate: nil, fandoms: ["Marvel"],
            relationships: ["Other/Ship", "Tony Stark/Steve Rogers"],
            characters: ["Tony Stark", "Steve Rogers"],
            additionalTags: ["Fluff"], categories: ["M/M"], ao3Collections: [],
            series: [], rating: "General", warnings: [], extractedAt: "2024-01-02T00:00:00Z"
        )
        try await metaDB.insertBatch([(updated3095, 3095), (updated769, 769)], diagnostics: [])

        // Extraction flush: updateAO3MetaCaches clears query caches and invalidates sorted IDs
        await library.updateAO3MetaCaches(
            wordCounts: [769: 1500, 3095: 2500],
            kudos: [:],
            dates: [:],
            crossoverIDs: [],
            workIDs: [:]
        )

        let (page2, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, query)
        XCTAssertEqual(page2.map(\.id), [3095, 769])
    }

    func testNegatedTagRuleDoesNotRankExcludedTag() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        var expr = FilterExpression()
        expr.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .notEquals, value: "Tony Stark/Steve Rogers")
            ])
        ]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let targets = TagRelevanceTargets.make(expression: expr, query: emptyQuery, expansions: [:])

        XCTAssertTrue(targets.isEmpty)

        let pageQuery = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [769, 3095],
            metaDB: metaDB,
            relevanceTargets: targets
        )

        // Without positive targets, falls back to title order: "Check, Please!..." (3095) < "The Sleeping Beauty Curse" (769)
        let (page, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, pageQuery)
        XCTAssertEqual(page.map(\.id), [3095, 769])
    }

    func testSynonymTargetRanksViaExpansion() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        var expr = FilterExpression()
        expr.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .equals, value: "Steve/Tony")
            ])
        ]
        let expansions = ["Steve/Tony": ["Tony Stark/Steve Rogers"]]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let targets = TagRelevanceTargets.make(expression: expr, query: emptyQuery, expansions: expansions)

        let pageQuery = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [3095, 769],
            metaDB: metaDB,
            relevanceTargets: targets
        )

        let (page, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, pageQuery)
        XCTAssertEqual(page.map(\.id), [769, 3095])
    }

    func testAscendingFlipsPositionOrder() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        let targets = TagRelevanceTargets(exact: ["Tony Stark/Steve Rogers"], contains: [])
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])

        let pageQuery = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [3095, 769],
            metaDB: metaDB,
            relevanceTargets: targets
        )

        let (page, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: true, pageQuery)
        // Ascending inverts the primary position order (index 1 precedes index 0)
        XCTAssertEqual(page.map(\.id), [3095, 769])
    }

    func testFTSOnlyResultsOrderedByTagPosition() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        let targets = TagRelevanceTargets(exact: ["Tony Stark/Steve Rogers"], contains: [])
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])

        let pageQuery = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [3095, 769],
            metaDB: metaDB,
            rankedIDs: [3095, 769],
            relevanceTargets: targets,
            rankedIDsAreOrdered: false // FTS IDs are unranked
        )

        let (page, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, pageQuery)
        // Tag position orders the FTS results: 769 (index 0) beats 3095 (index 1)
        XCTAssertEqual(page.map(\.id), [769, 3095])
    }

    func testFTSOnlyWithoutTargetsIsTitleOrder() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])

        let pageQuery = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [769, 3095],
            metaDB: metaDB,
            rankedIDs: [769, 3095],
            relevanceTargets: .init(),
            rankedIDsAreOrdered: false
        )

        let (page, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, pageQuery)
        // With no tag targets and unranked FTS, falls back to title order: 3095 < 769
        XCTAssertEqual(page.map(\.id), [3095, 769])
    }

    func testSemanticRanksNotOverriddenByTagPosition() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        let targets = TagRelevanceTargets(exact: ["Tony Stark/Steve Rogers"], contains: [])
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])

        let pageQuery = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [3095, 769],
            metaDB: metaDB,
            rankedIDs: [3095, 769], // Semantic hit 3095 rank 0, 769 rank 1
            relevanceTargets: targets,
            rankedIDsAreOrdered: true
        )

        let (page, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, pageQuery)
        // Semantic rank is strictly primary: 3095 stays first even though 769 has better tag position
        XCTAssertEqual(page.map(\.id), [3095, 769])
    }

    func testEmptyPositionMapFallsBackToTitleOrder() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        let targets = TagRelevanceTargets(exact: ["Nonexistent Tag"], contains: [])
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])

        let pageQuery = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [769, 3095],
            metaDB: metaDB,
            relevanceTargets: targets
        )

        let (page, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, pageQuery)
        // No books matched tag -> posMap empty -> title order (3095 < 769)
        XCTAssertEqual(page.map(\.id), [3095, 769])
    }

    func testDuplicateRankedIDsDoNotCrash() async throws {
        try await seedAO3Metadata()
        guard let library, let metaDB else { return }

        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])

        let pageQuery = CalibreLibrary.PageQuery(
            query: emptyQuery,
            filter: nil,
            restrictIDs: [3095, 769],
            metaDB: metaDB,
            rankedIDs: [769, 769, 3095], // Duplicate ID
            rankedIDsAreOrdered: true
        )

        let (page, _) = await library.relevanceSortedPage(offset: 0, limit: 10, ascending: false, pageQuery)
        XCTAssertEqual(page.map(\.id), [769, 3095])
    }
}
