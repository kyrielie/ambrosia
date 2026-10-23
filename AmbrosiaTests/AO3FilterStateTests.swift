import XCTest
@testable import Ambrosia

final class AO3FilterStateTests: XCTestCase {

    func testBidirectionalMappingPreservesPassthroughRules() {
        var baseExpr = FilterExpression()
        var group = FilterGroup(conjunction: .and)
        group.rules.append(FilterRule(field: .title, op: .contains, value: "Secret"))
        group.rules.append(FilterRule(field: .tag, op: .equals, value: "Slow Burn"))
        group.rules.append(FilterRule(field: .authorName, op: .equals, value: "Jane"))
        group.rules.append(FilterRule(field: .wordCountGT, op: .equals, value: "25000"))
        baseExpr.groups = [group]

        // 1. Initialize AO3FilterPopupState from FilterExpression
        let state = AO3FilterPopupState(from: baseExpr, capturedDigest: "digest1")

        XCTAssertTrue(state.includedFreeforms.contains("Slow Burn"))
        XCTAssertTrue(state.includedAuthors.contains("Jane"))
        XCTAssertEqual(state.wordsFrom, 25000)
        XCTAssertEqual(state.passthroughRules.count, 1)
        XCTAssertEqual(state.passthroughRules.first?.field, .title)
        XCTAssertEqual(state.passthroughRules.first?.value, "Secret")

        // 2. Build expression from state and verify all rules including passthrough are present
        let exportedExpr = state.buildExpression()
        let allRules = exportedExpr.groups.flatMap { $0.rules }

        XCTAssertTrue(allRules.contains(where: { $0.field == .title && $0.value == "Secret" }))
        XCTAssertTrue(allRules.contains(where: { $0.field == .tag && $0.value == "Slow Burn" }))
        XCTAssertTrue(allRules.contains(where: { $0.field == .authorName && $0.value == "Jane" }))
        XCTAssertTrue(allRules.contains(where: { $0.field == .wordCountGT && $0.value == "25000" }))
    }

    func testRatingMatchModeTranslation() {
        let state = AO3FilterPopupState(capturedDigest: "digest2")
        state.includedRating = .teenAndUp
        state.ratingMatch = .orHigher

        let expr = state.buildExpression()
        let rules = expr.groups.flatMap { $0.rules }

        let ratingRule = rules.first(where: { $0.field == .rating })
        XCTAssertNotNil(ratingRule)
        XCTAssertEqual(ratingRule?.op, .ratingAtLeast)
        XCTAssertEqual(ratingRule?.value, AO3Rating.teenAndUp.rawValue)

        // Read back into a fresh state
        let recovered = AO3FilterPopupState(from: expr, capturedDigest: "digest3")
        XCTAssertEqual(recovered.includedRating, .teenAndUp)
        XCTAssertEqual(recovered.ratingMatch, .orHigher)
    }

    func testThreeStateCycling() {
        let state = AO3FilterPopupState(capturedDigest: "digest4")

        // Warnings cycling: Clear -> Included -> Excluded -> Clear
        XCTAssertEqual(state.selectionState(for: .graphicViolence), .clear)

        state.cycleWarning(.graphicViolence)
        XCTAssertEqual(state.selectionState(for: .graphicViolence), .included)
        XCTAssertTrue(state.includedWarnings.contains(.graphicViolence))

        state.cycleWarning(.graphicViolence)
        XCTAssertEqual(state.selectionState(for: .graphicViolence), .excluded)
        XCTAssertTrue(state.excludedWarnings.contains(.graphicViolence))

        state.cycleWarning(.graphicViolence)
        XCTAssertEqual(state.selectionState(for: .graphicViolence), .clear)
        XCTAssertFalse(state.includedWarnings.contains(.graphicViolence))
        XCTAssertFalse(state.excludedWarnings.contains(.graphicViolence))

        // Tags cycling
        XCTAssertEqual(state.tagSelectionState("Angst", field: .freeform), .clear)

        state.cycleTag("Angst", field: .freeform)
        XCTAssertEqual(state.tagSelectionState("Angst", field: .freeform), .included)

        state.cycleTag("Angst", field: .freeform)
        XCTAssertEqual(state.tagSelectionState("Angst", field: .freeform), .excluded)

        state.cycleTag("Angst", field: .freeform)
        XCTAssertEqual(state.tagSelectionState("Angst", field: .freeform), .clear)
    }
}
