// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

final class SortedIDsCacheTests: XCTestCase {

    private var libraryRoot: URL!
    private var library: CalibreLibrary!

    override func setUpWithError() throws {
        try super.setUpWithError()
        libraryRoot = try CalibreTestFixture.makeTempLibraryRoot()
        library = try CalibreLibrary(root: libraryRoot)
    }

    override func tearDownWithError() throws {
        library = nil
        if let root = libraryRoot {
            try? FileManager.default.removeItem(at: root)
        }
        libraryRoot = nil
        try super.tearDownWithError()
    }

    func testPage1ThenPage2ReusesSortedIDsComputeCount() async {
        let prevWordCountLabel = CustomColumnConfig.shared.wordCountLabel
        let prevKudosLabel = CustomColumnConfig.shared.kudosLabel
        CustomColumnConfig.shared.wordCountLabel = nil
        CustomColumnConfig.shared.kudosLabel = nil
        defer {
            CustomColumnConfig.shared.wordCountLabel = prevWordCountLabel
            CustomColumnConfig.shared.kudosLabel = prevKudosLabel
        }

        let candidateIDs = [769, 3095, 5259, 7905, 8449]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let pageQuery = CalibreLibrary.PageQuery(query: emptyQuery, restrictIDs: candidateIDs)

        // Seed AO3 caches
        await library.updateAO3MetaCaches(
            wordCounts: [769: 12000, 3095: 8500, 5259: 45000, 7905: 3200, 8449: 15000],
            kudos: [769: 300, 3095: 150, 5259: 800, 7905: 90, 8449: 450],
            dates: [:],
            crossoverIDs: [],
            workIDs: [:]
        )

        // --- Word Count ---
        let c0 = await library.sortedIDsComputeCount
        let (wcPage1, hasMore1) = await library.wordCountSortedPage(offset: 0, limit: 2, ascending: false, pageQuery)
        XCTAssertEqual(wcPage1.count, 2)
        XCTAssertTrue(hasMore1)
        let c1 = await library.sortedIDsComputeCount
        XCTAssertEqual(c1, c0 + 1, "Page 1 of word count must compute sorted IDs once")

        let (wcPage2, _) = await library.wordCountSortedPage(offset: 2, limit: 2, ascending: false, pageQuery)
        XCTAssertEqual(wcPage2.count, 2)
        let c2 = await library.sortedIDsComputeCount
        XCTAssertEqual(c2, c1, "Page 2 of word count must reuse sorted IDs cache without recomputing")

        // --- Kudos ---
        let (kPage1, _) = await library.kudosSortedPage(offset: 0, limit: 2, ascending: false, pageQuery)
        XCTAssertEqual(kPage1.count, 2)
        let c3 = await library.sortedIDsComputeCount
        XCTAssertEqual(c3, c2 + 1, "Page 1 of kudos must compute sorted IDs once")

        let (kPage2, _) = await library.kudosSortedPage(offset: 2, limit: 2, ascending: false, pageQuery)
        XCTAssertEqual(kPage2.count, 2)
        let c4 = await library.sortedIDsComputeCount
        XCTAssertEqual(c4, c3, "Page 2 of kudos must reuse sorted IDs cache without recomputing")

        // --- Random ---
        let (rPage1, _) = await library.randomSortedPage(offset: 0, limit: 2, pageQuery)
        XCTAssertEqual(rPage1.count, 2)
        let c5 = await library.sortedIDsComputeCount
        XCTAssertEqual(c5, c4 + 1, "Page 1 of random must compute sorted IDs once")

        let (rPage2, _) = await library.randomSortedPage(offset: 2, limit: 2, pageQuery)
        XCTAssertEqual(rPage2.count, 2)
        let c6 = await library.sortedIDsComputeCount
        XCTAssertEqual(c6, c5, "Page 2 of random must reuse sorted IDs cache without recomputing")

        // --- Relevance ---
        let rankedQuery = CalibreLibrary.PageQuery(
            query: emptyQuery,
            restrictIDs: candidateIDs,
            rankedIDs: [5259, 8449, 769, 3095, 7905]
        )
        let (relPage1, _) = await library.relevanceSortedPage(offset: 0, limit: 2, ascending: false, rankedQuery)
        XCTAssertEqual(relPage1.count, 2)
        let c7 = await library.sortedIDsComputeCount
        XCTAssertEqual(c7, c6 + 1, "Page 1 of relevance must compute sorted IDs once")

        let (relPage2, _) = await library.relevanceSortedPage(offset: 2, limit: 2, ascending: false, rankedQuery)
        XCTAssertEqual(relPage2.count, 2)
        let c8 = await library.sortedIDsComputeCount
        XCTAssertEqual(c8, c7, "Page 2 of relevance must reuse sorted IDs cache without recomputing")
    }

    func testCacheBustOnDirectionFilterAndSeed() async {
        let prevWordCountLabel = CustomColumnConfig.shared.wordCountLabel
        CustomColumnConfig.shared.wordCountLabel = nil
        defer { CustomColumnConfig.shared.wordCountLabel = prevWordCountLabel }

        let candidateIDs = [769, 3095, 5259]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let pageQuery = CalibreLibrary.PageQuery(query: emptyQuery, restrictIDs: candidateIDs)

        await library.updateAO3MetaCaches(
            wordCounts: [769: 1000, 3095: 2000, 5259: 3000],
            kudos: [:],
            dates: [:],
            crossoverIDs: [],
            workIDs: [:]
        )

        // 1. Direction change on word count triggers recompute
        let c0 = await library.sortedIDsComputeCount
        _ = await library.wordCountSortedPage(offset: 0, limit: 2, ascending: false, pageQuery)
        let c1 = await library.sortedIDsComputeCount
        XCTAssertEqual(c1, c0 + 1)

        _ = await library.wordCountSortedPage(offset: 0, limit: 2, ascending: true, pageQuery)
        let c2 = await library.sortedIDsComputeCount
        XCTAssertEqual(c2, c1 + 1, "Toggling ascending must recompute sorted IDs")

        // 2. Changing random seed for numeric sort does NOT recompute (seed zeroing)
        await library.reshuffleRandom()
        _ = await library.wordCountSortedPage(offset: 0, limit: 2, ascending: true, pageQuery)
        let c3 = await library.sortedIDsComputeCount
        XCTAssertEqual(c3, c2, "Changing randomSeed must not bust numeric sort cache")

        // 3. Changing random seed for random sort DOES recompute
        _ = await library.randomSortedPage(offset: 0, limit: 2, pageQuery)
        let c4 = await library.sortedIDsComputeCount
        XCTAssertEqual(c4, c3 + 1)

        await library.reshuffleRandom()
        _ = await library.randomSortedPage(offset: 0, limit: 2, pageQuery)
        let c5 = await library.sortedIDsComputeCount
        XCTAssertEqual(c5, c4 + 1, "Changing randomSeed must recompute random sort cache")
    }

    func testQueryDigestCollisionResistance() {
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])

        // 1. Same-size ftsMatchedIDs with different contents
        var qFts1 = emptyQuery
        qFts1.ftsMatchedIDs = [1, 2, 3]
        var qFts2 = emptyQuery
        qFts2.ftsMatchedIDs = [1, 2, 4]
        let dFts1 = QueryDigestBuilder.digest(query: qFts1)
        let dFts2 = QueryDigestBuilder.digest(query: qFts2)
        XCTAssertNotEqual(dFts1, dFts2, "Different ftsMatchedIDs content must produce different digests")

        // 2. Scoped mode differences (.exact vs .word)
        let qModeExact = SearchQuery(
            tagTerms: ["Angst"],
            authorTerms: [],
            titleTerms: [],
            plainTerms: [],
            scopedTagTerms: [SearchTerm(mode: .exact, value: "Angst")]
        )
        let qModeWord = SearchQuery(
            tagTerms: ["Angst"],
            authorTerms: [],
            titleTerms: [],
            plainTerms: [],
            scopedTagTerms: [SearchTerm(mode: .word, value: "Angst")]
        )
        let dExact = QueryDigestBuilder.digest(query: qModeExact)
        let dWord = QueryDigestBuilder.digest(query: qModeWord)
        XCTAssertNotEqual(dExact, dWord, "Different match modes on identical term must produce different digests")

        // 3. Expanded tag terms differences
        var qExp1 = emptyQuery
        qExp1.expandedTagTerms = ["hurt": ["comfort"]]
        var qExp2 = emptyQuery
        qExp2.expandedTagTerms = ["hurt": ["angst"]]
        let dExp1 = QueryDigestBuilder.digest(query: qExp1)
        let dExp2 = QueryDigestBuilder.digest(query: qExp2)
        XCTAssertNotEqual(dExp1, dExp2, "Different expanded tag terms must produce different digests")

        // 4. RestrictIDs differences
        let dRest1 = QueryDigestBuilder.digest(query: emptyQuery, restrictIDs: [10, 20])
        let dRest2 = QueryDigestBuilder.digest(query: emptyQuery, restrictIDs: [10, 30])
        XCTAssertNotEqual(dRest1, dRest2, "Different restrictIDs must produce different digests")

        // 5. RankedIDs differences
        let dRank1 = QueryDigestBuilder.digest(query: emptyQuery, rankedIDs: [10, 20])
        let dRank2 = QueryDigestBuilder.digest(query: emptyQuery, rankedIDs: [20, 10])
        XCTAssertNotEqual(dRank1, dRank2, "Different rankedIDs ordering must produce different digests")
    }

    func testClearQueryCachesAndMetaUpdateForcesRecompute() async {
        let prevWordCountLabel = CustomColumnConfig.shared.wordCountLabel
        CustomColumnConfig.shared.wordCountLabel = nil
        defer { CustomColumnConfig.shared.wordCountLabel = prevWordCountLabel }

        let candidateIDs = [769, 3095]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let pageQuery = CalibreLibrary.PageQuery(query: emptyQuery, restrictIDs: candidateIDs)

        await library.updateAO3MetaCaches(
            wordCounts: [769: 1000, 3095: 2000],
            kudos: [:],
            dates: [:],
            crossoverIDs: [],
            workIDs: [:]
        )

        let c0 = await library.sortedIDsComputeCount
        _ = await library.wordCountSortedPage(offset: 0, limit: 2, ascending: false, pageQuery)
        let c1 = await library.sortedIDsComputeCount
        XCTAssertEqual(c1, c0 + 1)

        // Clear query caches
        await library.clearQueryCaches()
        _ = await library.wordCountSortedPage(offset: 0, limit: 2, ascending: false, pageQuery)
        let c2 = await library.sortedIDsComputeCount
        XCTAssertEqual(c2, c1 + 1, "clearQueryCaches must force a recompute")

        // Update AO3 metadata caches
        await library.updateAO3MetaCaches(
            wordCounts: [769: 5000, 3095: 6000],
            kudos: [:],
            dates: [:],
            crossoverIDs: [],
            workIDs: [:]
        )
        _ = await library.wordCountSortedPage(offset: 0, limit: 2, ascending: false, pageQuery)
        let c3 = await library.sortedIDsComputeCount
        XCTAssertEqual(c3, c2 + 1, "updateAO3MetaCaches must force a recompute")
    }

    func testD4TieBreakingNumericSort() async {
        let prevWordCountLabel = CustomColumnConfig.shared.wordCountLabel
        CustomColumnConfig.shared.wordCountLabel = nil
        defer { CustomColumnConfig.shared.wordCountLabel = prevWordCountLabel }

        // Fixture books:
        // 3095: "Check, Please! 12 Days of Christmas 2016"
        // 769:  "The Sleeping Beauty Curse"
        // 5259: "blood in the cut"
        // 8449: "The Last Chills of Winter"
        // 7905: "variations on an aggravating theme"
        let candidateIDs = [769, 3095, 5259, 7905, 8449]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let pageQuery = CalibreLibrary.PageQuery(query: emptyQuery, restrictIDs: candidateIDs)

        // 769, 3095, 5259 have equal counts (5000).
        // 7905, 8449 have nil counts.
        await library.updateAO3MetaCaches(
            wordCounts: [769: 5000, 3095: 5000, 5259: 5000],
            kudos: [:],
            dates: [:],
            crossoverIDs: [],
            workIDs: [:]
        )

        // --- Descending Sort ---
        let (descPage, _) = await library.wordCountSortedPage(offset: 0, limit: 5, ascending: false, pageQuery)
        let descIDs = descPage.map(\.id)
        // Non-nils (769, 3095, 5259) come first, ordered by title NOCASE ASC:
        // "blood in the cut" (5259) < "Check, Please!..." (3095) < "The Sleeping..." (769)
        XCTAssertEqual(Array(descIDs[0..<3]), [5259, 3095, 769])
        // Nils (7905, 8449) come last in both directions, ordered by title NOCASE ASC:
        // "The Last Chills of Winter" (8449) < "variations on an aggravating theme" (7905)
        XCTAssertEqual(Array(descIDs[3..<5]), [8449, 7905])

        // --- Ascending Sort ---
        let (ascPage, _) = await library.wordCountSortedPage(offset: 0, limit: 5, ascending: true, pageQuery)
        let ascIDs = ascPage.map(\.id)
        // Non-nils still come before nils, tied counts ordered by title NOCASE ASC:
        XCTAssertEqual(Array(ascIDs[0..<3]), [5259, 3095, 769])
        // Nils still sort last, ordered by title NOCASE ASC:
        XCTAssertEqual(Array(ascIDs[3..<5]), [8449, 7905])
    }

    func testRelevanceFallbackD6() async {
        let candidateIDs = [5259, 769, 3095]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let pageQuery = CalibreLibrary.PageQuery(query: emptyQuery, restrictIDs: candidateIDs, rankedIDs: nil)

        let (page, _) = await library.relevanceSortedPage(offset: 0, limit: 3, ascending: false, pageQuery)
        // With rankedIDs nil/empty, relevance falls through to allIDs
        // allIDs comes from fetchAllMatchingIDs which orders by title ASC, then ID ASC:
        // 5259 ("blood in the cut"), 3095 ("Check, Please!..."), 769 ("The Sleeping...")
        XCTAssertEqual(page.map(\.id), [5259, 3095, 769])
    }

    func testPrunedColdPathDeterministicOrder() async {
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let matchedIDs = await library.fetchAllMatchingIDs(query: emptyQuery, filter: nil, restrictIDs: [769, 3095, 5259])
        XCTAssertEqual(matchedIDs, [5259, 3095, 769], "Pruned fetchAllMatchingIDs must maintain deterministic title then ID order")
    }
}
