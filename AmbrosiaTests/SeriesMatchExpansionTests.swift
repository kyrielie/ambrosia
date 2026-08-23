import XCTest
@testable import Ambrosia

// Covers only `SeriesMatchExpansion.ratingConstraint(in:)`: a pure function
// over `FilterExpression` with no actor or SQLite dependency, so it's
// testable without the CalibreLibraryFixtureTests-style `.sql`-backed
// fixtures that `expand(...)` itself would need (bulkRatingTags/
// seriesEntries both hit real Calibre/Ambrosia databases). Those fixture
// files (calibre_fixture_schema.sql / calibre_fixture_data.sql, per
// CalibreTestFixture.swift's doc comment) aren't present in this checkout,
// so a full `expand(...)` integration test — matched IDs in, disqualified
// series' IDs excluded from the result — is not included here rather than
// guessed at.
final class SeriesMatchExpansionTests: XCTestCase {

    private func expression(_ rules: [FilterRule]) -> FilterExpression {
        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: rules)]
        return expr
    }

    // MARK: - .ratingAtMost -> .ceiling

    func test_ratingAtMost_mapsToCeiling_atThatLevel() {
        let filter = expression([FilterRule(field: .rating, op: .ratingAtMost, value: "Teen And Up Audiences")])
        XCTAssertEqual(SeriesMatchExpansion.ratingConstraint(in: filter), .ceiling(level: 2))
    }

    // MARK: - .equals -> .exact

    func test_equals_mapsToExact_atThatLevel() {
        let filter = expression([FilterRule(field: .rating, op: .equals, value: "General Audiences")])
        XCTAssertEqual(SeriesMatchExpansion.ratingConstraint(in: filter), .exact(level: 1))
    }

    // MARK: - Ambiguous / unsupported shapes fall back to nil (pre-fix behavior)

    func test_noFilter_returnsNil() {
        XCTAssertNil(SeriesMatchExpansion.ratingConstraint(in: nil))
    }

    func test_noRatingRule_returnsNil() {
        let filter = expression([FilterRule(field: .tag, op: .contains, value: "Fantasy")])
        XCTAssertNil(SeriesMatchExpansion.ratingConstraint(in: filter))
    }

    func test_multipleRatingRules_returnsNil() {
        var expr = FilterExpression()
        expr.groups = [
            FilterGroup(rules: [FilterRule(field: .rating, op: .ratingAtMost, value: "Mature")]),
            FilterGroup(rules: [FilterRule(field: .rating, op: .equals, value: "Explicit")])
        ]
        XCTAssertNil(SeriesMatchExpansion.ratingConstraint(in: expr), "more than one .rating rule anywhere in the expression is ambiguous")
    }

    func test_notEquals_returnsNil() {
        let filter = expression([FilterRule(field: .rating, op: .notEquals, value: "Explicit")])
        XCTAssertNil(SeriesMatchExpansion.ratingConstraint(in: filter), "excluding one rating doesn't pin down a single ceiling/exact level")
    }

    func test_ratingAtLeast_returnsNil() {
        let filter = expression([FilterRule(field: .rating, op: .ratingAtLeast, value: "Mature")])
        XCTAssertNil(SeriesMatchExpansion.ratingConstraint(in: filter), "a floor has no natural expansion-time ceiling/exact mapping")
    }

    func test_unrecognizedRatingValue_returnsNil() {
        let filter = expression([FilterRule(field: .rating, op: .ratingAtMost, value: "Not A Real Rating")])
        XCTAssertNil(SeriesMatchExpansion.ratingConstraint(in: filter))
    }

    // MARK: - Real popup output (AO3FilterPopupState.buildExpression)

    func test_popupIncludedRating_isEquals_mapsToExact() {
        // AO3FilterPopupState.buildExpression emits FilterRule(.rating, .equals, ...)
        // for a single "included rating" selection — confirm that shape resolves
        // to .exact, not .ceiling, per the confirmed design (an equals-Teen search
        // must exclude a General Audiences companion work, not just an Explicit one).
        let filter = expression([FilterRule(field: .rating, op: .equals, value: "Teen And Up Audiences")])
        XCTAssertEqual(SeriesMatchExpansion.ratingConstraint(in: filter), .exact(level: 2))
    }
}
