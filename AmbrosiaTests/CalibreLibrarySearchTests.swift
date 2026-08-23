import XCTest
import SQLite
@testable import Ambrosia

/// Coverage for `whereClause(for:)`, `_bookCount`, and the `*Suggestions`
/// functions (`Ambrosia/Database/CalibreLibrarySearch.swift`), against the
/// real bundled Calibre fixture (`CalibreTestFixture`).
///
/// Every count/ordering assertion below was independently verified against
/// the actual fixture data (50 real books) by running the equivalent SQL
/// directly, not guessed -- the fixture is real extracted library data, not
/// synthetic rows with round numbers, so hardcoded expectations here are
/// pinned to what the data actually contains as of this checkout.
///
/// This is also the regression test for the "dead outer join" correction in
/// the test plan: `CalibreLibrarySearch.swift` (141 lines, read in full)
/// contains no `LEFT JOIN` anywhere -- every tag/author/series condition
/// already routes through `MatchingSubqueryBuilder`'s `EXISTS`/`NOT EXISTS`
/// shape. `testBookCountTagAndAuthorCombinedWithAND` pins that current,
/// correct behavior.
final class CalibreLibrarySearchTests: XCTestCase {

    private var library: CalibreLibrary!
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        libraryRoot = try CalibreTestFixture.makeTempLibraryRoot()
        library = try CalibreLibrary(root: libraryRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
        library = nil
        libraryRoot = nil
    }

    private func emptyQuery(
        tagTerms: [String] = [],
        authorTerms: [String] = [],
        titleTerms: [String] = [],
        seriesTerms: [String] = []
    ) -> SearchQuery {
        SearchQuery(tagTerms: tagTerms, authorTerms: authorTerms, titleTerms: titleTerms, seriesTerms: seriesTerms, plainTerms: [])
    }

    // MARK: - whereClause(for:) / _bookCount: ftsMatchedIDs

    func testFtsMatchedIDsPresentAndEmptyProducesZeroEqualsOne() async throws {
        var query = emptyQuery()
        query.ftsMatchedIDs = []
        let count = await library.bookCount(query: query)
        XCTAssertEqual(count, 0)
    }

    func testFtsMatchedIDsPresentAndNonemptyUsesINClause() async throws {
        var query = emptyQuery()
        query.ftsMatchedIDs = [78982] // astolat's "Preservation", verified present in the fixture
        let count = await library.bookCount(query: query)
        XCTAssertEqual(count, 1)
    }

    // MARK: - whereClause(for:) term kinds, via _bookCount

    func testBookCountTagTermRoutesThroughMatchingSubqueryBuilder() async throws {
        let query = emptyQuery(tagTerms: ["fluff"])
        let count = await library.bookCount(query: query)
        XCTAssertEqual(count, 9)
    }

    func testBookCountAuthorTermRoutesThroughMatchingSubqueryBuilder() async throws {
        let query = emptyQuery(authorTerms: ["astolat"])
        let count = await library.bookCount(query: query)
        XCTAssertEqual(count, 1)
    }

    func testBookCountTitleTermUsesPlainLike() async throws {
        let query = emptyQuery(titleTerms: ["winter"])
        let count = await library.bookCount(query: query)
        XCTAssertEqual(count, 1)
    }

    func testBookCountSeriesTermRoutesThroughMatchingSubqueryBuilder() async throws {
        let query = emptyQuery(seriesTerms: ["tumblr"])
        let count = await library.bookCount(query: query)
        XCTAssertEqual(count, 1)
    }

    /// Pins the joined clause using AND (`whereClause`'s
    /// `clauses.joined(separator: " AND ")`), and is the current-correct-
    /// behavior regression test noted in the class doc comment above.
    func testBookCountTagAndAuthorCombinedWithAND() async throws {
        let query = emptyQuery(tagTerms: ["explicit"], authorTerms: ["astolat"])
        let count = await library.bookCount(query: query)
        XCTAssertEqual(count, 1) // astolat's one fixture book is tagged Explicit
    }

    func testBookCountNoTermsReturnsAllBooks() async throws {
        let query = emptyQuery()
        let count = await library.bookCount(query: query)
        XCTAssertEqual(count, 50)
    }

    // MARK: - tagSuggestions

    func testTagSuggestionsPrefixMatchAndFreqOrdering() async throws {
        let suggestions = await library.tagSuggestions(prefix: "ang", limit: 8)
        XCTAssertEqual(suggestions, ["Angst", "Aang (Avatar)", "Fluff and Angst", "Light Angst",
                                      "Hermione Granger", "Triangle Bill Cipher", "Bellatrix Black Lestrange",
                                      "The Gaang (Avatar)"])
    }

    func testTagSuggestionsEmptyPrefixReturnsEmpty() async throws {
        let suggestions = await library.tagSuggestions(prefix: "", limit: 8)
        XCTAssertEqual(suggestions, [])
    }

    // MARK: - authorSuggestions

    func testAuthorSuggestionsPrefixMatch() async throws {
        let suggestions = await library.authorSuggestions(prefix: "ast", limit: 8)
        XCTAssertEqual(suggestions, ["astolat", "EwNasty (BogDing)"])
    }

    func testAuthorSuggestionsEmptyPrefixReturnsEmpty() async throws {
        let suggestions = await library.authorSuggestions(prefix: "", limit: 8)
        XCTAssertEqual(suggestions, [])
    }

    // MARK: - titleSuggestions

    func testTitleSuggestionsPrefixMatchAndLimit() async throws {
        let suggestions = await library.titleSuggestions(prefix: "the", limit: 3)
        XCTAssertEqual(suggestions, [
            "100 Drabble Tumblr Challenge: F8 OF THE DRABBLES",
            "blood in the cut",
            "I wanna see the sun rising anywhere but here"
        ])
    }

    func testTitleSuggestionsEmptyPrefixReturnsEmpty() async throws {
        let suggestions = await library.titleSuggestions(prefix: "", limit: 8)
        XCTAssertEqual(suggestions, [])
    }

    // MARK: - seriesSuggestions

    func testSeriesSuggestionsPrefixMatch() async throws {
        let suggestions = await library.seriesSuggestions(prefix: "the", limit: 8)
        XCTAssertEqual(suggestions, [
            "echo through the stars - Kenfetti Week 2025",
            "In the Lonely Hour",
            "The Breeding Grounds",
            "The Cloudeaters",
            "The White Clouds, Flying",
            "The Write Stuff",
            "These Are Not Actual Stories - Outlines Of Fanfics That I Will Never Write"
        ])
    }

    func testSeriesSuggestionsEmptyPrefixReturnsEmpty() async throws {
        let suggestions = await library.seriesSuggestions(prefix: "", limit: 8)
        XCTAssertEqual(suggestions, [])
    }
}
