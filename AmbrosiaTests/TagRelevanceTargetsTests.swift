// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Ambrosia

final class TagRelevanceTargetsTests: XCTestCase {
    private var emptyQuery: SearchQuery {
        SearchQueryParser.parse("")
    }

    func testEqualsRuleAddsValueAndSynonymsAsExact() {
        var expr = FilterExpression()
        expr.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .equals, value: "Fluff")
            ])
        ]
        let expansions = ["Fluff": ["Fluff and Humor", "Tooth-Rotting Fluff"]]

        let targets = TagRelevanceTargets.make(
            expression: expr,
            query: emptyQuery,
            expansions: expansions
        )

        XCTAssertEqual(targets.exact, ["Fluff", "Fluff and Humor", "Tooth-Rotting Fluff"])
        XCTAssertTrue(targets.contains.isEmpty)
        XCTAssertFalse(targets.isEmpty)
    }

    func testContainsRuleAddsValueAndSynonymsAsContains() {
        var expr = FilterExpression()
        expr.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .contains, value: "Angst")
            ])
        ]
        let expansions = ["Angst": ["Hurt/Comfort", "Angst with a HAPPY ENDING"]]

        let targets = TagRelevanceTargets.make(
            expression: expr,
            query: emptyQuery,
            expansions: expansions
        )

        XCTAssertTrue(targets.exact.isEmpty)
        XCTAssertEqual(targets.contains, ["Angst", "Hurt/Comfort", "Angst with a HAPPY ENDING"])
        XCTAssertFalse(targets.isEmpty)
    }

    func testNotEqualsAndNotContainsContributeNothingIncludingSynonyms() {
        var expr = FilterExpression()
        expr.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .notEquals, value: "Smut"),
                FilterRule(field: .tag, op: .notContains, value: "Non-con")
            ])
        ]
        let expansions = [
            "Smut": ["Porn with Plot"],
            "Non-con": ["Rape"]
        ]

        let targets = TagRelevanceTargets.make(
            expression: expr,
            query: emptyQuery,
            expansions: expansions
        )

        XCTAssertTrue(targets.exact.isEmpty)
        XCTAssertTrue(targets.contains.isEmpty)
        XCTAssertTrue(targets.isEmpty)
    }

    func testStartsWithRegexWordContributeNothing() {
        var expr = FilterExpression()
        expr.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .startsWith, value: "Slow"),
                FilterRule(field: .tag, op: .matchesRegex, value: "^A.*"),
                FilterRule(field: .tag, op: .matchesWord, value: "Hurt")
            ])
        ]

        let targets = TagRelevanceTargets.make(
            expression: expr,
            query: emptyQuery,
            expansions: ["Slow": ["Slow Burn"]]
        )

        XCTAssertTrue(targets.exact.isEmpty)
        XCTAssertTrue(targets.contains.isEmpty)
        XCTAssertTrue(targets.isEmpty)
    }

    func testSearchBarRegexAndWordTermsContributeNothing() {
        let query = SearchQuery(
            tagTerms: [],
            authorTerms: [],
            titleTerms: [],
            plainTerms: [],
            scopedTagTerms: [
                SearchTerm(mode: .regex, value: "Fluff.*"),
                SearchTerm(mode: .word, value: "Angst")
            ]
        )

        let targets = TagRelevanceTargets.make(
            expression: nil,
            query: query,
            expansions: ["Angst": ["Hurt"]]
        )

        XCTAssertTrue(targets.exact.isEmpty)
        XCTAssertTrue(targets.contains.isEmpty)
        XCTAssertTrue(targets.isEmpty)
    }

    func testExcludedTagTermsContributeNothing() {
        var query = emptyQuery
        query.excludedTagTerms = ["Sad Ending", "Major Character Death"]

        let targets = TagRelevanceTargets.make(
            expression: nil,
            query: query,
            expansions: ["Sad Ending": ["Tragedy"]]
        )

        XCTAssertTrue(targets.exact.isEmpty)
        XCTAssertTrue(targets.contains.isEmpty)
        XCTAssertTrue(targets.isEmpty)
    }

    func testRatingWarningCategoryValuesSkipped() {
        var expr = FilterExpression()
        expr.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .equals, value: "Explicit"),
                FilterRule(field: .tag, op: .contains, value: "Graphic Depictions Of Violence"),
                FilterRule(field: .tag, op: .equals, value: "M/M"),
                FilterRule(field: .tag, op: .equals, value: "Valid Regular Tag")
            ])
        ]
        let query = SearchQuery(
            tagTerms: [],
            authorTerms: [],
            titleTerms: [],
            plainTerms: [],
            scopedTagTerms: [
                SearchTerm(mode: .exact, value: "General Audiences"),
                SearchTerm(mode: .contains, value: "M/M"),
                SearchTerm(mode: .contains, value: "F/F"),
                SearchTerm(mode: .exact, value: "Underage Sex")
            ]
        )

        let targets = TagRelevanceTargets.make(
            expression: expr,
            query: query,
            expansions: [:]
        )

        XCTAssertEqual(targets.exact, ["Valid Regular Tag"])
        XCTAssertTrue(targets.contains.isEmpty)
    }

    func testExpansionLookupUsesUntrimmedRuleValue() {
        var expr = FilterExpression()
        expr.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .equals, value: "  Slow Burn  ")
            ])
        ]
        let expansions = [
            "  Slow Burn  ": ["  Mutual Pining  "]
        ]

        let targets = TagRelevanceTargets.make(
            expression: expr,
            query: emptyQuery,
            expansions: expansions
        )

        XCTAssertEqual(targets.exact, ["Slow Burn", "Mutual Pining"])
        XCTAssertTrue(targets.contains.isEmpty)
    }

    func testDedupeCaseInsensitivePreservesOrder() {
        var expr = FilterExpression()
        expr.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .equals, value: "Angst"),
                FilterRule(field: .tag, op: .equals, value: "angst"),
                FilterRule(field: .tag, op: .equals, value: "ANGST"),
                FilterRule(field: .tag, op: .equals, value: "Fluff"),
                FilterRule(field: .tag, op: .equals, value: "angst")
            ])
        ]

        let targets = TagRelevanceTargets.make(
            expression: expr,
            query: emptyQuery,
            expansions: [:]
        )

        XCTAssertEqual(targets.exact, ["Angst", "Fluff"])
    }

    func testRulesInOrGroupsAreIncluded() {
        var expr = FilterExpression()
        expr.groupConjunction = .or
        expr.groups = [
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .equals, value: "Enemies to Lovers")
            ], conjunction: .or),
            FilterGroup(rules: [
                FilterRule(field: .tag, op: .contains, value: "Coffee Shop AU")
            ], conjunction: .or)
        ]

        let targets = TagRelevanceTargets.make(
            expression: expr,
            query: emptyQuery,
            expansions: [:]
        )

        XCTAssertEqual(targets.exact, ["Enemies to Lovers"])
        XCTAssertEqual(targets.contains, ["Coffee Shop AU"])
    }
}
