// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

final class OrderedHydrationTests: XCTestCase {

    private static var libraryRoot: URL?
    private static var library: CalibreLibrary?

    // swiftlint:disable:next static_over_final_class
    override class func setUp() {
        super.setUp()
        do {
            let root = try CalibreTestFixture.makeTempLibraryRoot()
            libraryRoot = root
            library = try CalibreLibrary(root: root)
        } catch {
            XCTFail("Failed to initialize test fixture: \(error)")
        }
    }

    // swiftlint:disable:next static_over_final_class
    override class func tearDown() {
        library = nil
        if let root = libraryRoot {
            try? FileManager.default.removeItem(at: root)
        }
        libraryRoot = nil
        super.tearDown()
    }

    private var library: CalibreLibrary {
        guard let lib = Self.library else {
            fatalError("CalibreLibrary fixture not initialized")
        }
        return lib
    }

    func testOrderedBooksPreservesExactInputSequence() async {
        let requestedIDs = [5259, 769, 3095]
        let books = await library.orderedBooks(for: requestedIDs)
        XCTAssertEqual(books.map(\.id), requestedIDs)
    }

    func testOrderedBooksDeduplicatesFirstSeen() async {
        let requestedIDs = [5259, 769, 5259, 3095, 769]
        let books = await library.orderedBooks(for: requestedIDs)
        XCTAssertEqual(books.map(\.id), [5259, 769, 3095])
    }

    func testOrderedBooksSilentlyDropsMissingIDs() async {
        let requestedIDs = [5259, 999_999, 769, 888_888]
        let books = await library.orderedBooks(for: requestedIDs)
        XCTAssertEqual(books.map(\.id), [5259, 769])
    }

    func testBooksForIDsMaintainsLegacyTitleOrder() async {
        // IDs: 5259 ("blood in the cut"), 769 ("The Sleeping Beauty Curse"), 3095 ("Check, Please!...")
        // Title sort ascending: "blood in the cut" (5259) < "Check, Please!..." (3095) < "The Sleeping Beauty Curse" (769)
        let requestedIDs = [769, 5259, 3095]
        let books = await library.booksForIDs(requestedIDs)
        XCTAssertEqual(books.map(\.id), [5259, 3095, 769])
    }

    func testRandomSortedPageMatchesSeededShuffleSlice() async {
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let pageQuery = CalibreLibrary.PageQuery(query: emptyQuery)

        let (page1, _) = await library.randomSortedPage(
            offset: 0,
            limit: 10,
            pageQuery
        )
        let (page2, _) = await library.randomSortedPage(
            offset: 0,
            limit: 10,
            pageQuery
        )
        XCTAssertEqual(page1.map(\.id), page2.map(\.id))
        XCTAssertEqual(page1.count, 10)
    }

    func testWordCountSortedPageOrdersByCountWithinPage() async {
        let previousLabel = CustomColumnConfig.shared.wordCountLabel
        CustomColumnConfig.shared.wordCountLabel = nil
        defer { CustomColumnConfig.shared.wordCountLabel = previousLabel }

        let testWordCounts = [
            769: 15_000,
            3095: 50_000,
            5259: 3_000,
            7905: 80_000,
            8449: 25_000
        ]
        await library.updateAO3MetaCaches(
            wordCounts: testWordCounts,
            kudos: [:],
            dates: [:],
            crossoverIDs: [],
            workIDs: [:]
        )

        let candidateIDs = [769, 3095, 5259, 7905, 8449]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let pageQuery = CalibreLibrary.PageQuery(query: emptyQuery, restrictIDs: candidateIDs)

        let (page, _) = await library.wordCountSortedPage(
            offset: 0,
            limit: 5,
            ascending: false,
            pageQuery
        )

        XCTAssertEqual(page.map(\.id), [7905, 3095, 8449, 769, 5259])
    }

    func testKudosSortedPageOrdersByCountWithinPage() async {
        let previousLabel = CustomColumnConfig.shared.kudosLabel
        CustomColumnConfig.shared.kudosLabel = nil
        defer { CustomColumnConfig.shared.kudosLabel = previousLabel }

        let testKudos = [
            769: 100,
            3095: 500,
            5259: 30,
            7905: 800,
            8449: 250
        ]
        await library.updateAO3MetaCaches(
            wordCounts: [:],
            kudos: testKudos,
            dates: [:],
            crossoverIDs: [],
            workIDs: [:]
        )

        let candidateIDs = [769, 3095, 5259, 7905, 8449]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let pageQuery = CalibreLibrary.PageQuery(query: emptyQuery, restrictIDs: candidateIDs)

        let (page, _) = await library.kudosSortedPage(
            offset: 0,
            limit: 5,
            ascending: false,
            pageQuery
        )

        XCTAssertEqual(page.map(\.id), [7905, 3095, 8449, 769, 5259])
    }

    func testRelevanceSortedPageWithRankedIDsPreservesRankOrder() async {
        let candidateIDs = [769, 3095, 5259, 7905]
        let rankedIDs = [5259, 769, 7905, 3095]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let pageQuery = CalibreLibrary.PageQuery(query: emptyQuery, restrictIDs: candidateIDs, rankedIDs: rankedIDs)

        let (page, _) = await library.relevanceSortedPage(
            offset: 0,
            limit: 4,
            ascending: false,
            pageQuery
        )

        XCTAssertEqual(page.map(\.id), rankedIDs)
    }

    func testRelevanceSortedPageWithNoRankingsFallsThroughToAllIDs() async {
        let candidateIDs = [5259, 769, 3095]
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let pageQuery = CalibreLibrary.PageQuery(query: emptyQuery, restrictIDs: candidateIDs, rankedIDs: nil)

        let (page, _) = await library.relevanceSortedPage(
            offset: 0,
            limit: 3,
            ascending: false,
            pageQuery
        )

        XCTAssertEqual(page.count, 3)
        XCTAssertTrue(Set(page.map(\.id)).isSubset(of: Set(candidateIDs)))
    }

    func testToolbarStateNumericSortDirectionSaveAndRestore() {
        let toolbarState = LibraryToolbarState()
        toolbarState.sortField = .title
        toolbarState.ascending = true

        toolbarState.sortField = .wordCount
        XCTAssertFalse(toolbarState.ascending)

        toolbarState.sortField = .title
        XCTAssertTrue(toolbarState.ascending)

        toolbarState.sortField = .kudos
        XCTAssertFalse(toolbarState.ascending)
        toolbarState.ascending = true

        toolbarState.sortField = .author
        XCTAssertTrue(toolbarState.ascending)
    }
}
