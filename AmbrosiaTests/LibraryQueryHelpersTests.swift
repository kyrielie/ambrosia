import XCTest
@testable import Ambrosia

// Covers the plan.md Finding 2 extraction (LibraryQueryHelpers) that plan2's
// Finding 10 flagged as newly cheap-to-test now that it's pure functions with
// no actor/DB dependency. Only the fields each function actually reads are
// populated on the CalibreBook fixtures below — everything else uses
// CalibreBook's real (non-optional) fields with placeholder values, since
// CalibreBook has no synthesized default init for a partial fixture.
final class LibraryQueryHelpersTests: XCTestCase {

    private func makeBook(
        id: Int,
        publisher: String? = nil,
        comment: String? = nil
    ) -> CalibreBook {
        CalibreBook(
            id: id,
            title: "Book \(id)",
            series: nil,
            seriesIndex: nil,
            wordCount: nil,
            kudos: nil,
            publishedDate: nil,
            publisher: publisher,
            relativePath: "Author/Book \(id)",
            authors: [],
            tags: [],
            comment: comment
        )
    }

    // MARK: - visibleIDs

    func testVisibleIDsHidesSkippedUnlessShowSkippedIsOn() {
        let result = LibraryQueryHelpers.visibleIDs(
            [1, 2, 3],
            showSkippedCollection: false,
            shouldGroupSeriesRows: false,
            skippedIDs: [2],
            seriesOrMergedIDs: [],
            hideNonAO3PublisherBooks: false,
            ao3PublisherIDs: []
        )
        XCTAssertEqual(result, [1, 3])
    }

    func testVisibleIDsShowsSkippedWhenFlagIsOn() {
        let result = LibraryQueryHelpers.visibleIDs(
            [1, 2, 3],
            showSkippedCollection: true,
            shouldGroupSeriesRows: false,
            skippedIDs: [2],
            seriesOrMergedIDs: [],
            hideNonAO3PublisherBooks: false,
            ao3PublisherIDs: []
        )
        XCTAssertEqual(result, [1, 2, 3])
    }

    func testVisibleIDsSuppressesSeriesMembersOnlyWhenGroupingIsOn() {
        // Without grouping, a series member must still show as a standalone
        // row -- this is the multi-series-membership case called out in
        // LibraryQueryHelpers' own doc comment.
        let ungrouped = LibraryQueryHelpers.visibleIDs(
            [1, 2], showSkippedCollection: false, shouldGroupSeriesRows: false,
            skippedIDs: [], seriesOrMergedIDs: [2],
            hideNonAO3PublisherBooks: false, ao3PublisherIDs: []
        )
        XCTAssertEqual(ungrouped, [1, 2])

        let grouped = LibraryQueryHelpers.visibleIDs(
            [1, 2], showSkippedCollection: false, shouldGroupSeriesRows: true,
            skippedIDs: [], seriesOrMergedIDs: [2],
            hideNonAO3PublisherBooks: false, ao3PublisherIDs: []
        )
        XCTAssertEqual(grouped, [1])
    }

    func testVisibleIDsHidesNonAO3PublisherBooksWhenFlagIsOn() {
        let result = LibraryQueryHelpers.visibleIDs(
            [1, 2], showSkippedCollection: false, shouldGroupSeriesRows: false,
            skippedIDs: [], seriesOrMergedIDs: [],
            hideNonAO3PublisherBooks: true, ao3PublisherIDs: [1]
        )
        XCTAssertEqual(result, [1])
    }

    func testVisibleIDsOnEmptyInputReturnsEmpty() {
        let result = LibraryQueryHelpers.visibleIDs(
            [], showSkippedCollection: false, shouldGroupSeriesRows: false,
            skippedIDs: [], seriesOrMergedIDs: [],
            hideNonAO3PublisherBooks: false, ao3PublisherIDs: []
        )
        XCTAssertEqual(result, [])
    }

    // MARK: - visibleBooks

    func testVisibleBooksExcludesAnthologyDescriptionsRegardlessOfOtherFlags() {
        let anthology = makeBook(id: 1, comment: "Anthology of short works.")
        let normal = makeBook(id: 2, comment: "A perfectly normal fic.")
        let result = LibraryQueryHelpers.visibleBooks(
            [anthology, normal], showSkippedCollection: true, shouldGroupSeriesRows: false,
            skippedIDs: [], seriesOrMergedIDs: [], hideNonAO3PublisherBooks: false
        )
        XCTAssertEqual(result.map(\.id), [2])
    }

    func testVisibleBooksHidesNonAO3PublisherBooksWhenFlagIsOn() {
        let ao3Book = makeBook(id: 1, publisher: "Archive of Our Own")
        let otherBook = makeBook(id: 2, publisher: "Some Other Publisher")
        let result = LibraryQueryHelpers.visibleBooks(
            [ao3Book, otherBook], showSkippedCollection: true, shouldGroupSeriesRows: false,
            skippedIDs: [], seriesOrMergedIDs: [], hideNonAO3PublisherBooks: true
        )
        XCTAssertEqual(result.map(\.id), [1])
    }

    // MARK: - intersect

    func testIntersectReturnsUnchangedWhenOptionalIDsIsNil() {
        XCTAssertEqual(LibraryQueryHelpers.intersect([1, 2, 3], with: nil), [1, 2, 3])
    }

    func testIntersectFiltersDownToAllowedSet() {
        XCTAssertEqual(LibraryQueryHelpers.intersect([1, 2, 3], with: [2, 3, 4]), [2, 3])
    }

    func testIntersectWithEmptyOptionalIDsReturnsEmpty() {
        // Distinguishes "no restriction" (nil) from "restricted to nothing" ([]),
        // per the doc comment's "no additional restriction" semantics.
        XCTAssertEqual(LibraryQueryHelpers.intersect([1, 2, 3], with: []), [])
    }

    // MARK: - addOrReplaceRule

    func testAddOrReplaceRuleAppendsToEmptyExpression() {
        var expression = FilterExpression()
        expression.groups[0].rules = []
        let rule = FilterRule(field: .tag, op: .contains, value: "Fluff")
        LibraryQueryHelpers.addOrReplaceRule(rule, in: &expression)
        XCTAssertEqual(expression.groups[0].rules.count, 1)
        XCTAssertEqual(expression.groups[0].rules[0].value, "Fluff")
    }

    func testAddOrReplaceRuleReplacesExistingSingleValueField() {
        var expression = FilterExpression()
        expression.groups[0].rules = [FilterRule(field: .authorName, op: .equals, value: "Old Author")]
        let rule = FilterRule(field: .authorName, op: .equals, value: "New Author")
        LibraryQueryHelpers.addOrReplaceRule(rule, in: &expression)
        XCTAssertEqual(expression.groups[0].rules.count, 1)
        XCTAssertEqual(expression.groups[0].rules[0].value, "New Author")
    }

    func testAddOrReplaceRuleStacksNonSingleValueFields() {
        var expression = FilterExpression()
        expression.groups[0].rules = [FilterRule(field: .tag, op: .contains, value: "Fluff")]
        let rule = FilterRule(field: .tag, op: .contains, value: "Angst")
        LibraryQueryHelpers.addOrReplaceRule(rule, in: &expression)
        XCTAssertEqual(expression.groups[0].rules.count, 2)
    }

    func testAddOrReplaceRuleSkipsExactDuplicate() {
        var expression = FilterExpression()
        let rule = FilterRule(field: .tag, op: .contains, value: "Fluff")
        expression.groups[0].rules = [rule]
        LibraryQueryHelpers.addOrReplaceRule(rule, in: &expression)
        XCTAssertEqual(expression.groups[0].rules.count, 1)
    }
}
