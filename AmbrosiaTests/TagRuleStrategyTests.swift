import XCTest
@testable import Ambrosia

/// Covers plan PR H: `TagRuleStrategy.choose` and `AndGroupOrdering`.
/// Both are pure, so no fixture library is needed.
final class TagRuleStrategyTests: XCTestCase {

    private func candidates(_ count: Int) -> Set<Int> { count > 0 ? Set(1...count) : [] }

    // MARK: - TagRuleStrategy.choose

    func testNilCandidatesIsUnrestricted() {
        XCTAssertEqual(TagRuleStrategy.choose(op: .contains, candidates: nil, coveredCount: 1000), .unrestricted)
    }

    func testEqualsAndRatingOpsAreNeverRestricted() {
        let few = candidates(1)
        for op in [FilterOperator.equals, .notEquals, .ratingAtMost, .ratingAtLeast] {
            XCTAssertEqual(TagRuleStrategy.choose(op: op, candidates: few, coveredCount: 1000), .unrestricted,
                           "op \(op.rawValue) must never restrict")
        }
    }

    func testContainsRestrictedAtOrBelowTenPercent() {
        let atThreshold = candidates(100)
        XCTAssertEqual(TagRuleStrategy.choose(op: .contains, candidates: atThreshold, coveredCount: 1000),
                       .restricted(atThreshold))
        let startsWith = candidates(10)
        XCTAssertEqual(TagRuleStrategy.choose(op: .startsWith, candidates: startsWith, coveredCount: 1000),
                       .restricted(startsWith))
    }

    func testContainsUnrestrictedAboveTenPercent() {
        XCTAssertEqual(TagRuleStrategy.choose(op: .contains, candidates: candidates(101), coveredCount: 1000),
                       .unrestricted)
    }

    func testNegatedContainsFollowsPositiveForm() {
        let few = candidates(5)
        XCTAssertEqual(TagRuleStrategy.choose(op: .notContains, candidates: few, coveredCount: 1000),
                       TagRuleStrategy.choose(op: .contains, candidates: few, coveredCount: 1000))
        let many = candidates(500)
        XCTAssertEqual(TagRuleStrategy.choose(op: .notContains, candidates: many, coveredCount: 1000),
                       TagRuleStrategy.choose(op: .contains, candidates: many, coveredCount: 1000))
    }

    func testZeroCoverageIsUnrestricted() {
        XCTAssertEqual(TagRuleStrategy.choose(op: .contains, candidates: candidates(1), coveredCount: 0),
                       .unrestricted)
    }

    // MARK: - AndGroupOrdering

    private func rule(_ op: FilterOperator, _ value: String) -> FilterRule {
        FilterRule(field: .tag, op: op, value: value)
    }

    func testOrderingByCostClassWithStableTies() {
        let rules = [
            rule(.notContains, "n1"),
            rule(.contains, "c1"),
            rule(.equals, "e1"),
            rule(.contains, "c2"),
            rule(.ratingAtMost, "r1"),
            rule(.equals, "e2"),
            rule(.notEquals, "n2")
        ]
        let ordered = AndGroupOrdering.order(rules) { _ in nil }
        XCTAssertEqual(ordered.map(\.value), ["e1", "e2", "r1", "c1", "c2", "n1", "n2"])
    }

    func testKnownSizesComeFirstAscending() {
        let big = rule(.contains, "big")
        let small = rule(.notContains, "small")
        let unknown = rule(.equals, "unknown")
        let sizes: [String: Int] = ["big": 900, "small": 12]
        let ordered = AndGroupOrdering.order([unknown, big, small]) { sizes[$0.value] }
        XCTAssertEqual(ordered.map(\.value), ["small", "big", "unknown"])
    }

    func testKnownSizeTiesKeepInputOrder() {
        let first = rule(.contains, "a")
        let second = rule(.equals, "b")
        let ordered = AndGroupOrdering.order([first, second]) { _ in 5 }
        XCTAssertEqual(ordered.map(\.value), ["a", "b"])
    }

    func testOrderingIsAPermutation() {
        let rules = (0..<20).map { index -> FilterRule in
            let ops: [FilterOperator] = [.contains, .equals, .notContains, .ratingAtLeast, .startsWith, .notEquals]
            return rule(ops[index % ops.count], "v\(index)")
        }
        let ordered = AndGroupOrdering.order(rules) { _ in nil }
        XCTAssertEqual(Set(ordered.map(\.value)), Set(rules.map(\.value)))
        XCTAssertEqual(ordered.count, rules.count)
    }
}
