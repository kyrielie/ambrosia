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
        // AnthologyDetector.isAnthology matches only the exact, anchored
        // "Anthology containing:" prefix Calibre's EPUB-merge plugin writes
        // (see HTMLStripper.swift) -- not any comment that merely mentions the
        // word "anthology" -- so the fixture must use that literal prefix.
        let anthology = makeBook(id: 1, comment: "Anthology containing: Short Works One, Short Works Two.")
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
        let originalExpression = expression
        LibraryQueryHelpers.addOrReplaceRule(rule, in: &expression)
        XCTAssertEqual(expression, originalExpression)
    }

    func testHasCompleteRuleMatchesSameValueRegardlessOfOperator() {
        var expression = FilterExpression()
        expression.groups[0].rules = [FilterRule(field: .tag, op: .contains, value: "Fluff")]

        XCTAssertTrue(LibraryQueryHelpers.hasCompleteRule(field: .tag, value: "Fluff", in: expression))
        XCTAssertTrue(LibraryQueryHelpers.hasCompleteRule(field: .tag, value: " fluff ", in: expression))
        XCTAssertFalse(LibraryQueryHelpers.hasCompleteRule(field: .tag, value: "Angst", in: expression))
        XCTAssertFalse(LibraryQueryHelpers.hasCompleteRule(field: .warning, value: "Fluff", in: expression))
    }

    func testTagPillRuleUsesExactMatch() {
        let rule = FilterRuleFactory.tagPillRule(label: "Fluff", field: .tag)

        XCTAssertEqual(rule.field, .tag)
        XCTAssertEqual(rule.op, .equals)
        XCTAssertEqual(rule.value, "Fluff")
    }

    // MARK: - removeRule & toggleNegation

    func testRemoveRuleSingleGroup() {
        var expression = FilterExpression()
        let rule1 = FilterRule(field: .tag, op: .contains, value: "Fluff")
        let rule2 = FilterRule(field: .tag, op: .contains, value: "Angst")
        expression.groups[0].rules = [rule1, rule2]

        let removed = LibraryQueryHelpers.removeRule(id: rule1.id, in: &expression)
        XCTAssertTrue(removed)
        XCTAssertEqual(expression.groups.count, 1)
        XCTAssertEqual(expression.groups[0].rules.count, 1)
        XCTAssertEqual(expression.groups[0].rules[0].id, rule2.id)
    }

    func testRemoveRuleLeavesOneGroupWhenAllRulesRemoved() {
        var expression = FilterExpression()
        let rule = FilterRule(field: .tag, op: .contains, value: "Fluff")
        expression.groups[0].rules = [rule]

        let removed = LibraryQueryHelpers.removeRule(id: rule.id, in: &expression)
        XCTAssertTrue(removed)
        XCTAssertEqual(expression.groups.count, 1)
        XCTAssertTrue(expression.groups[0].rules.isEmpty)
    }

    func testRemoveRulePrunesEmptyGroupsWhenMultipleExist() {
        var expression = FilterExpression()
        let rule1 = FilterRule(field: .tag, op: .contains, value: "Fluff")
        let rule2 = FilterRule(field: .tag, op: .contains, value: "Angst")
        let group1 = FilterGroup(rules: [rule1])
        let group2 = FilterGroup(rules: [rule2])
        expression.groups = [group1, group2]

        let removed = LibraryQueryHelpers.removeRule(id: rule1.id, in: &expression)
        XCTAssertTrue(removed)
        XCTAssertEqual(expression.groups.count, 1)
        XCTAssertEqual(expression.groups[0].rules.count, 1)
        XCTAssertEqual(expression.groups[0].rules[0].id, rule2.id)
    }

    func testRemoveRuleUnknownIDIsNoOp() {
        var expression = FilterExpression()
        let rule = FilterRule(field: .tag, op: .contains, value: "Fluff")
        expression.groups[0].rules = [rule]

        let removed = LibraryQueryHelpers.removeRule(id: UUID(), in: &expression)
        XCTAssertFalse(removed)
        XCTAssertEqual(expression.groups[0].rules.count, 1)
    }

    func testNegatedCounterpartIsInvolutionForAllCases() {
        for op in FilterOperator.allCases {
            if let counterpart = op.negatedCounterpart {
                XCTAssertEqual(
                    counterpart.negatedCounterpart,
                    op,
                    "Counterpart involution failed for \(op)"
                )
            } else {
                XCTAssertTrue(
                    op == .startsWith || op == .matchesWord || op == .matchesRegex || op == .ratingAtMost || op == .ratingAtLeast,
                    "Unexpected nil counterpart for \(op)"
                )
            }
        }
    }

    func testCanToggleNegationPerField() {
        let tagContains = FilterRule(field: .tag, op: .contains, value: "A")
        XCTAssertTrue(tagContains.canToggleNegation)

        let tagStartsWith = FilterRule(field: .tag, op: .startsWith, value: "A")
        XCTAssertFalse(tagStartsWith.canToggleNegation)

        let tagEquals = FilterRule(field: .tag, op: .equals, value: "A")
        XCTAssertTrue(tagEquals.canToggleNegation)

        let warningEquals = FilterRule(field: .warning, op: .equals, value: "A")
        XCTAssertTrue(warningEquals.canToggleNegation)

        let titleEquals = FilterRule(field: .title, op: .equals, value: "A")
        XCTAssertFalse(titleEquals.canToggleNegation)

        let ratingCeiling = FilterRule(field: .rating, op: .ratingAtMost, value: "General")
        XCTAssertFalse(ratingCeiling.canToggleNegation)

        let fulltextContains = FilterRule(field: .fulltext, op: .contains, value: "A")
        XCTAssertTrue(fulltextContains.canToggleNegation)
    }

    func testToggleNegationLeavesOtherRulesUntouched() {
        var expression = FilterExpression()
        let rule1 = FilterRule(field: .tag, op: .contains, value: "Fluff")
        let rule2 = FilterRule(field: .tag, op: .contains, value: "Angst")
        expression.groups[0].rules = [rule1, rule2]

        let toggled = LibraryQueryHelpers.toggleNegation(id: rule1.id, in: &expression)
        XCTAssertTrue(toggled)
        XCTAssertEqual(expression.groups[0].rules[0].op, .notContains)
        XCTAssertEqual(expression.groups[0].rules[1].op, .contains)
    }

    // MARK: - FilterRule operatorLabel & LIKE escaping

    func testEscapeLikePattern() {
        XCTAssertEqual(LibraryQueryHelpers.escapeLikePattern("normal"), "normal")
        XCTAssertEqual(LibraryQueryHelpers.escapeLikePattern("100%"), "100\\%")
        XCTAssertEqual(LibraryQueryHelpers.escapeLikePattern("tag_name"), "tag\\_name")
        XCTAssertEqual(LibraryQueryHelpers.escapeLikePattern("path\\file"), "path\\\\file")
    }

    func testOperatorLabelTagStartsWith() {
        let tagRule = FilterRule(field: .tag, op: .startsWith, value: "angst")
        XCTAssertEqual(tagRule.operatorLabel(.startsWith), "name starts with")
        XCTAssertEqual(tagRule.operatorLabel(.contains), "contains")

        let titleRule = FilterRule(field: .title, op: .startsWith, value: "the")
        XCTAssertEqual(titleRule.operatorLabel(.startsWith), "starts with")
    }

    // MARK: - Pass 5: Rule Conversion, Variants & DisplayLabel Tests

    func testConvertTagRuleToFirstRelationshipKeepsOpAndValue() {
        var expr = FilterExpression()
        let tagRule = FilterRule(field: .tag, op: .equals, value: "Thor/Loki")
        expr.groups[0].rules = [tagRule]

        let converted = LibraryQueryHelpers.convertTagRule(id: tagRule.id, to: .firstRelationship, in: &expr)
        XCTAssertTrue(converted)
        XCTAssertEqual(expr.groups[0].rules[0].field, .firstRelationship)
        XCTAssertEqual(expr.groups[0].rules[0].op, .equals)
        XCTAssertEqual(expr.groups[0].rules[0].value, "Thor/Loki")
        XCTAssertNil(expr.groups[0].rules[0].limit)
        XCTAssertNil(expr.groups[0].rules[0].matchVariants)
    }

    func testConvertBackDropsLimitAndVariants() {
        var expr = FilterExpression()
        var posRule = FilterRule(field: .firstRelationship, op: .equals, value: "Thor/Loki")
        posRule.limit = 3
        posRule.matchVariants = true
        expr.groups[0].rules = [posRule]

        let converted = LibraryQueryHelpers.convertPositionRuleToTag(id: posRule.id, in: &expr)
        XCTAssertTrue(converted)
        XCTAssertEqual(expr.groups[0].rules[0].field, .tag)
        XCTAssertEqual(expr.groups[0].rules[0].op, .equals)
        XCTAssertEqual(expr.groups[0].rules[0].value, "Thor/Loki")
        XCTAssertNil(expr.groups[0].rules[0].limit)
        XCTAssertNil(expr.groups[0].rules[0].matchVariants)
    }

    func testSetVariantsOnNewFields() {
        var expr = FilterExpression()
        let posRule = FilterRule(field: .firstRelationship, op: .equals, value: "Thor/Loki")
        let countRule = FilterRule(field: .relationshipCount, op: .equals, value: "1")
        let tagRule = FilterRule(field: .tag, op: .equals, value: "Fluff")
        expr.groups[0].rules = [posRule, countRule, tagRule]

        XCTAssertTrue(LibraryQueryHelpers.setRuleVariants(id: posRule.id, enabled: true, in: &expr))
        XCTAssertEqual(expr.groups[0].rules[0].matchVariants, true)

        XCTAssertTrue(LibraryQueryHelpers.setRuleVariants(id: countRule.id, enabled: true, in: &expr))
        XCTAssertEqual(expr.groups[0].rules[1].matchVariants, true)

        XCTAssertFalse(LibraryQueryHelpers.setRuleVariants(id: tagRule.id, enabled: true, in: &expr))
        XCTAssertNil(expr.groups[0].rules[2].matchVariants)
    }

    func testToggleNegationWorksOnNewFields() {
        var expr = FilterExpression()
        let posRule = FilterRule(field: .firstRelationship, op: .equals, value: "Thor/Loki")
        let charRule = FilterRule(field: .firstCharacter, op: .equals, value: "Loki")
        let countRule = FilterRule(field: .relationshipCount, op: .equals, value: "1")
        expr.groups[0].rules = [posRule, charRule, countRule]

        XCTAssertTrue(LibraryQueryHelpers.toggleNegation(id: posRule.id, in: &expr))
        XCTAssertEqual(expr.groups[0].rules[0].op, .notEquals)

        XCTAssertTrue(LibraryQueryHelpers.toggleNegation(id: charRule.id, in: &expr))
        XCTAssertEqual(expr.groups[0].rules[1].op, .notEquals)

        XCTAssertTrue(LibraryQueryHelpers.toggleNegation(id: countRule.id, in: &expr))
        XCTAssertEqual(expr.groups[0].rules[2].op, .notEquals)
    }

    func testPillDisplayLabelForLimit() {
        var rule1 = FilterRule(field: .firstRelationship, op: .equals, value: "Thor/Loki")
        XCTAssertEqual(rule1.displayLabel, "First-listed relationship")
        rule1.limit = 2
        XCTAssertEqual(rule1.displayLabel, "Relationship in first 2")
        rule1.matchVariants = true
        XCTAssertEqual(rule1.displayLabel, "Relationship in first 2 (variants)")

        var charRule = FilterRule(field: .firstCharacter, op: .equals, value: "Thor")
        charRule.limit = 1
        XCTAssertEqual(charRule.displayLabel, "First-listed character")
        charRule.limit = 3
        XCTAssertEqual(charRule.displayLabel, "Character in first 3")

        var countRule = FilterRule(field: .relationshipCount, op: .equals, value: "1")
        XCTAssertEqual(countRule.displayLabel, "Relationship count")
        countRule.matchVariants = true
        XCTAssertEqual(countRule.displayLabel, "Relationship count (variants)")
    }
}
