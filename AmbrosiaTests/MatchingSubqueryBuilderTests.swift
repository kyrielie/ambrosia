import XCTest
import SQLite
@testable import Ambrosia

/// Coverage for `MatchingSubqueryBuilder` (`FilterBuilder.swift:15-99`), the
/// free, non-actor-isolated EXISTS/NOT EXISTS subquery builder shared by the
/// filter drawer and `CalibreLibrarySearch`. See Invariant 24 in
/// `docs/search-and-filter.md` for why the correlation shape (`= b.id`, no
/// outer join) matters -- that's what the correlation-shape assertions below
/// pin.
final class MatchingSubqueryBuilderTests: XCTestCase {

    // MARK: - authorFragment

    func testAuthorFragmentContains() throws {
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.authorFragment(op: .contains, value: "Smith"))
        XCTAssertTrue(sql.hasPrefix("EXISTS ("))
        XCTAssertFalse(sql.contains("NOT EXISTS"))
        XCTAssertTrue(sql.contains("LOWER(a2.name) LIKE ?"))
        XCTAssertEqual(args as? [String], ["%smith%"])
    }

    func testAuthorFragmentNotContains() throws {
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.authorFragment(op: .notContains, value: "Smith"))
        XCTAssertTrue(sql.hasPrefix("NOT EXISTS ("))
        XCTAssertTrue(sql.contains("LOWER(a2.name) LIKE ?"))
        XCTAssertEqual(args as? [String], ["%smith%"])
    }

    func testAuthorFragmentEquals() throws {
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.authorFragment(op: .equals, value: "Smith"))
        XCTAssertTrue(sql.hasPrefix("EXISTS ("))
        XCTAssertTrue(sql.contains("LOWER(a2.name) = ?"))
        XCTAssertEqual(args as? [String], ["smith"])
    }

    func testAuthorFragmentNotEquals() throws {
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.authorFragment(op: .notEquals, value: "Smith"))
        XCTAssertTrue(sql.hasPrefix("NOT EXISTS ("))
        XCTAssertTrue(sql.contains("LOWER(a2.name) = ?"))
        XCTAssertEqual(args as? [String], ["smith"])
    }

    func testAuthorFragmentStartsWith() throws {
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.authorFragment(op: .startsWith, value: "Smith"))
        XCTAssertTrue(sql.hasPrefix("EXISTS ("))
        XCTAssertTrue(sql.contains("LOWER(a2.name) LIKE ?"))
        XCTAssertEqual(args as? [String], ["smith%"])
    }

    func testAuthorFragmentRatingOperatorsReturnNil() {
        XCTAssertNil(MatchingSubqueryBuilder.authorFragment(op: .ratingAtMost, value: "Explicit"))
        XCTAssertNil(MatchingSubqueryBuilder.authorFragment(op: .ratingAtLeast, value: "Explicit"))
    }

    func testAuthorFragmentCorrelationShape() throws {
        let (sql, _) = try XCTUnwrap(MatchingSubqueryBuilder.authorFragment(op: .contains, value: "Smith"))
        XCTAssertTrue(sql.contains("bal2.book = b.id"))
    }

    // MARK: - seriesFragment

    func testSeriesFragmentContains() throws {
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.seriesFragment(op: .contains, value: "Chronicles"))
        XCTAssertTrue(sql.hasPrefix("EXISTS ("))
        XCTAssertTrue(sql.contains("LOWER(s2.name) LIKE ?"))
        XCTAssertEqual(args as? [String], ["%chronicles%"])
    }

    func testSeriesFragmentNotContains() throws {
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.seriesFragment(op: .notContains, value: "Chronicles"))
        XCTAssertTrue(sql.hasPrefix("NOT EXISTS ("))
        XCTAssertTrue(sql.contains("LOWER(s2.name) LIKE ?"))
        XCTAssertEqual(args as? [String], ["%chronicles%"])
    }

    func testSeriesFragmentEquals() throws {
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.seriesFragment(op: .equals, value: "Chronicles"))
        XCTAssertTrue(sql.hasPrefix("EXISTS ("))
        XCTAssertTrue(sql.contains("LOWER(s2.name) = ?"))
        XCTAssertEqual(args as? [String], ["chronicles"])
    }

    func testSeriesFragmentNotEquals() throws {
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.seriesFragment(op: .notEquals, value: "Chronicles"))
        XCTAssertTrue(sql.hasPrefix("NOT EXISTS ("))
        XCTAssertTrue(sql.contains("LOWER(s2.name) = ?"))
        XCTAssertEqual(args as? [String], ["chronicles"])
    }

    func testSeriesFragmentStartsWith() throws {
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.seriesFragment(op: .startsWith, value: "Chronicles"))
        XCTAssertTrue(sql.hasPrefix("EXISTS ("))
        XCTAssertTrue(sql.contains("LOWER(s2.name) LIKE ?"))
        XCTAssertEqual(args as? [String], ["chronicles%"])
    }

    func testSeriesFragmentRatingOperatorsReturnNil() {
        XCTAssertNil(MatchingSubqueryBuilder.seriesFragment(op: .ratingAtMost, value: "Explicit"))
        XCTAssertNil(MatchingSubqueryBuilder.seriesFragment(op: .ratingAtLeast, value: "Explicit"))
    }

    func testSeriesFragmentCorrelationShape() throws {
        let (sql, _) = try XCTUnwrap(MatchingSubqueryBuilder.seriesFragment(op: .contains, value: "Chronicles"))
        XCTAssertTrue(sql.contains("bsl2.book = b.id"))
    }

    // MARK: - tagFragment

    func testTagFragmentNegatedProducesNotExists() throws {
        let (sql, _) = try XCTUnwrap(MatchingSubqueryBuilder.tagFragment(matcher: "t2.name = ?", args: ["Fantasy" as Binding?], negated: true))
        XCTAssertTrue(sql.hasPrefix("NOT EXISTS ("))
    }

    func testTagFragmentNotNegatedProducesExists() throws {
        let (sql, _) = try XCTUnwrap(MatchingSubqueryBuilder.tagFragment(matcher: "t2.name = ?", args: ["Fantasy" as Binding?], negated: false))
        XCTAssertTrue(sql.hasPrefix("EXISTS ("))
        XCTAssertFalse(sql.contains("NOT EXISTS"))
    }

    func testTagFragmentEmptyMatcherReturnsNil() {
        XCTAssertNil(MatchingSubqueryBuilder.tagFragment(matcher: "", args: [], negated: false))
    }

    func testTagFragmentPassesMatcherThroughVerbatim() throws {
        let matcher = "t2.name LIKE ? OR t2.name LIKE ?"
        let (sql, args) = try XCTUnwrap(MatchingSubqueryBuilder.tagFragment(
            matcher: matcher,
            args: ["%a%" as Binding?, "%b%" as Binding?],
            negated: false
        ))
        XCTAssertTrue(sql.contains(matcher))
        XCTAssertEqual(args as? [String], ["%a%", "%b%"])
    }

    func testTagFragmentCorrelationShape() throws {
        let (sql, _) = try XCTUnwrap(MatchingSubqueryBuilder.tagFragment(matcher: "t2.name = ?", args: ["Fantasy" as Binding?], negated: false))
        XCTAssertTrue(sql.contains("btl2.book = b.id"))
    }
}
