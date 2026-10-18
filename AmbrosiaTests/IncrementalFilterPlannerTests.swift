import XCTest
@testable import Ambrosia

/// Pure tests for `IncrementalFilterPlanner` (plan PR I, section 4 eligibility).
final class IncrementalFilterPlannerTests: XCTestCase {

    private func tag(_ value: String, _ op: FilterOperator = .contains) -> FilterRule {
        FilterRule(field: .tag, op: op, value: value)
    }

    private func expression(groups: [FilterGroup], groupConjunction: FilterConjunction = .and) -> FilterExpression {
        var expr = FilterExpression()
        expr.groups = groups
        expr.groupConjunction = groupConjunction
        return expr
    }

    func testAddingOneAndTagToASingleGroupYieldsOneSplitPerRule() {
        let first = tag("A"), second = tag("B")
        let expr = expression(groups: [FilterGroup(rules: [first, second], conjunction: .and)])
        let splits = IncrementalFilterPlanner.splits(of: expr)
        XCTAssertEqual(splits.count, 2)
        let deltas = Set(splits.map(\.delta.value))
        XCTAssertEqual(deltas, ["A", "B"])
        for split in splits {
            XCTAssertEqual(split.base.groups[0].completeRules.count, 1)
            XCTAssertFalse(split.base.groups[0].rules.contains { $0.id == split.delta.id })
        }
    }

    func testSingleRuleExpressionHasNoSplit() {
        let expr = expression(groups: [FilterGroup(rules: [tag("A")], conjunction: .and)])
        XCTAssertTrue(IncrementalFilterPlanner.splits(of: expr).isEmpty,
                      "an empty base is the whole library and is never cached")
    }

    func testEmptyAndIncompleteExpressionsHaveNoSplit() {
        XCTAssertTrue(IncrementalFilterPlanner.splits(of: FilterExpression()).isEmpty)
        let incomplete = FilterRule(field: .tag, op: .contains, value: "")
        let expr = expression(groups: [FilterGroup(rules: [incomplete, incomplete], conjunction: .and)])
        XCTAssertTrue(IncrementalFilterPlanner.splits(of: expr).isEmpty)
    }

    func testIncompleteRulesAreIgnored() {
        let first = tag("A"), second = tag("B")
        let blank = FilterRule(field: .tag, op: .contains, value: "")
        let expr = expression(groups: [FilterGroup(rules: [first, blank, second], conjunction: .and)])
        let splits = IncrementalFilterPlanner.splits(of: expr)
        XCTAssertEqual(Set(splits.map(\.delta.value)), ["A", "B"])
    }

    func testORGroupYieldsNoSplit() {
        let expr = expression(groups: [FilterGroup(rules: [tag("A"), tag("B")], conjunction: .or)])
        XCTAssertTrue(IncrementalFilterPlanner.splits(of: expr).isEmpty)
    }

    func testTopLevelORYieldsNoSplitWithTwoCompleteGroups() {
        let g1 = FilterGroup(rules: [tag("A"), tag("B")], conjunction: .and)
        let g2 = FilterGroup(rules: [tag("C")], conjunction: .and)
        let expr = expression(groups: [g1, g2], groupConjunction: .or)
        XCTAssertTrue(IncrementalFilterPlanner.splits(of: expr).isEmpty)
    }

    func testTopLevelORIsFineWithASingleCompleteGroup() {
        // The default expression has groupConjunction .or with one group.
        let expr = expression(groups: [FilterGroup(rules: [tag("A"), tag("B")], conjunction: .and)],
                           groupConjunction: .or)
        XCTAssertEqual(IncrementalFilterPlanner.splits(of: expr).count, 2)
    }

    func testTopLevelANDWithTwoANDGroupsSplitsEachGroupWithTwoRules() {
        let g1 = FilterGroup(rules: [tag("A"), tag("B")], conjunction: .and)
        let g2 = FilterGroup(rules: [tag("C"), tag("D")], conjunction: .and)
        let expr = expression(groups: [g1, g2], groupConjunction: .and)
        let splits = IncrementalFilterPlanner.splits(of: expr)
        XCTAssertEqual(Set(splits.map(\.delta.value)), ["A", "B", "C", "D"])
    }

    func testGroupThatWouldBecomeEmptyIsNotSplit() {
        let g1 = FilterGroup(rules: [tag("A"), tag("B")], conjunction: .and)
        let g2 = FilterGroup(rules: [tag("C")], conjunction: .and)
        let expr = expression(groups: [g1, g2], groupConjunction: .and)
        let deltas = Set(IncrementalFilterPlanner.splits(of: expr).map(\.delta.value))
        XCTAssertEqual(deltas, ["A", "B"], "removing C would change the group layout of the base")
    }

    func testORGroupMembersAreNotSplitWhileANDGroupMembersAre() {
        let andGroup = FilterGroup(rules: [tag("A"), tag("B")], conjunction: .and)
        let orGroup = FilterGroup(rules: [tag("C"), tag("D")], conjunction: .or)
        let expr = expression(groups: [andGroup, orGroup], groupConjunction: .and)
        let deltas = Set(IncrementalFilterPlanner.splits(of: expr).map(\.delta.value))
        XCTAssertEqual(deltas, ["A", "B"])
    }

    func testBaseCacheKeyMatchesAnExpressionBuiltWithoutTheRule() {
        let first = tag("A"), second = tag("B")
        let full = expression(groups: [FilterGroup(rules: [first, second], conjunction: .and)])
        let onlyA = expression(groups: [FilterGroup(rules: [first], conjunction: .and)])
        guard let split = IncrementalFilterPlanner.splits(of: full).first(where: { $0.delta.value == "B" }) else {
            return XCTFail("missing split")
        }
        XCTAssertEqual(FilterResultCacheKey(expression: split.base, membershipVersion: 3, visibilitySignature: "s"),
                       FilterResultCacheKey(expression: onlyA, membershipVersion: 3, visibilitySignature: "s"))
    }

    func testDeltaExpressionIsASingleANDGroup() {
        let rule = tag("A")
        let delta = IncrementalFilterPlanner.deltaExpression(for: rule)
        XCTAssertEqual(delta.groups.count, 1)
        XCTAssertEqual(delta.groups[0].conjunction, .and)
        XCTAssertEqual(delta.groups[0].completeRules.map(\.value), ["A"])
        XCTAssertEqual(delta.groupConjunction, .and)
    }
}
