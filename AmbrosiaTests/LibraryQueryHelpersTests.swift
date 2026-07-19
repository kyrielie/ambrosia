import XCTest
@testable import Ambrosia

// Covers the plan.md Finding 2 extraction (LibraryQueryHelpers) that plan2's
// Finding 10 flagged as newly cheap-to-test now that it's pure functions with
// no actor/DB dependency. Only the fields each function actually reads are
// populated on the CalibreBook fixtures below — everything else uses
// CalibreBook's real (non-optional) fields with placeholder values, since
// CalibreBook has no synthesized default init for a partial fixture.
//
// visibleIDs/visibleBooks were retired from LibraryQueryHelpers in favor of
// LibraryVisibilityPolicy.filter(_:) (see that type's doc comment); the
// tests below exercise the same behavior through the policy type.
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

    private func makePolicy(
        showSkippedCollection: Bool = true,
        shouldGroupSeriesRows: Bool = false,
        hideNonAO3PublisherBooks: Bool = false,
        hideAnthologyBooks: Bool = false,
        hideDuplicateBooks: Bool = false,
        skippedIDs: Set<Int> = [],
        seriesOrMergedIDs: Set<Int> = [],
        ao3PublisherIDs: Set<Int> = [],
        anthologyIDs: Set<Int> = [],
        duplicateLoserIDs: Set<Int> = []
    ) -> LibraryVisibilityPolicy {
        LibraryVisibilityPolicy(
            showSkippedCollection: showSkippedCollection,
            shouldGroupSeriesRows: shouldGroupSeriesRows,
            hideNonAO3PublisherBooks: hideNonAO3PublisherBooks,
            hideAnthologyBooks: hideAnthologyBooks,
            hideDuplicateBooks: hideDuplicateBooks,
            skippedIDs: skippedIDs,
            seriesOrMergedIDs: seriesOrMergedIDs,
            ao3PublisherIDs: ao3PublisherIDs,
            anthologyIDs: anthologyIDs,
            duplicateLoserIDs: duplicateLoserIDs
        )
    }

    // MARK: - visibleIDs (via LibraryVisibilityPolicy.filter(_: [Int]))

    func testVisibleIDsHidesSkippedUnlessShowSkippedIsOn() {
        let policy = makePolicy(showSkippedCollection: false, skippedIDs: [2])
        XCTAssertEqual(policy.filter([1, 2, 3]), [1, 3])
    }

    func testVisibleIDsShowsSkippedWhenFlagIsOn() {
        let policy = makePolicy(showSkippedCollection: true, skippedIDs: [2])
        XCTAssertEqual(policy.filter([1, 2, 3]), [1, 2, 3])
    }

    func testVisibleIDsSuppressesSeriesMembersOnlyWhenGroupingIsOn() {
        // Without grouping, a series member must still show as a standalone
        // row -- this is the multi-series-membership case called out in
        // LibraryVisibilityPolicy's own doc comment.
        let ungrouped = makePolicy(shouldGroupSeriesRows: false, seriesOrMergedIDs: [2])
        XCTAssertEqual(ungrouped.filter([1, 2]), [1, 2])

        let grouped = makePolicy(shouldGroupSeriesRows: true, seriesOrMergedIDs: [2])
        XCTAssertEqual(grouped.filter([1, 2]), [1])
    }

    func testVisibleIDsHidesNonAO3PublisherBooksWhenFlagIsOn() {
        let policy = makePolicy(hideNonAO3PublisherBooks: true, ao3PublisherIDs: [1])
        XCTAssertEqual(policy.filter([1, 2]), [1])
    }

    func testVisibleIDsOnEmptyInputReturnsEmpty() {
        let policy = makePolicy()
        XCTAssertEqual(policy.filter([] as [Int]), [])
    }

    // MARK: - visibleBooks (via LibraryVisibilityPolicy.filter(_: [CalibreBook]))

    func testVisibleBooksExcludesAnthologyDescriptionsRegardlessOfOtherFlags() {
        let anthology = makeBook(id: 1, comment: "Anthology of short works.")
        let normal = makeBook(id: 2, comment: "A perfectly normal fic.")
        let policy = makePolicy(showSkippedCollection: true, hideAnthologyBooks: true)
        let result = policy.filter([anthology, normal])
        XCTAssertEqual(result.map(\.id), [2])
    }

    func testVisibleBooksHidesNonAO3PublisherBooksWhenFlagIsOn() {
        let ao3Book = makeBook(id: 1, publisher: "Archive of Our Own")
        let otherBook = makeBook(id: 2, publisher: "Some Other Publisher")
        let policy = makePolicy(showSkippedCollection: true, hideNonAO3PublisherBooks: true)
        let result = policy.filter([ao3Book, otherBook])
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

    func testAddOrReplaceRuleReplacesExistingCollectionField() {
        // Regression test: picking a second collection from CollectionsView
        // used to append a second .collection rule into the same AND'd
        // group, which could only match books that were members of both
        // collections simultaneously -- silently producing an empty result
        // set. .collection must behave as a single-value field, same as
        // .authorName and .series.
        var expression = FilterExpression()
        expression.groups[0].rules = [FilterRule(field: .collection, op: .equals, value: "A")]
        let rule = FilterRule(field: .collection, op: .equals, value: "B")
        LibraryQueryHelpers.addOrReplaceRule(rule, in: &expression)
        XCTAssertEqual(expression.groups[0].rules.count, 1)
        XCTAssertEqual(expression.groups[0].rules[0].value, "B")
    }

    func testAddOrReplaceRuleSkipsExactDuplicate() {
        var expression = FilterExpression()
        let rule = FilterRule(field: .tag, op: .contains, value: "Fluff")
        expression.groups[0].rules = [rule]
        LibraryQueryHelpers.addOrReplaceRule(rule, in: &expression)
        XCTAssertEqual(expression.groups[0].rules.count, 1)
    }
}
