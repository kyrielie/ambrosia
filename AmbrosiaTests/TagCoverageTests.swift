import XCTest
@testable import Ambrosia

/// Covers the per-call hoisting in `FilterBuilder` (plan PR G): `TagCoverage`,
/// `RuleMatchKey`, and `CalibreLibrary.tagFamilyMatchIDs(coverage:)`.
///
/// The integration tests compare the coverage-aware path against the original
/// path (`coverage: nil`, which still fetches coverage per rule and subtracts)
/// on the shared Calibre fixture, so they pin equivalence rather than
/// hard-coded sets. Fixture facts used: books 769 and 61360 both carry the
/// Calibre tag "Harry Potter" (tag id 18).
final class TagCoverageTests: XCTestCase {

    private static var library: CalibreLibrary!
    private static var libraryRoot: URL!

    // swiftlint:disable:next static_over_final_class
    override class func setUp() {
        do {
            libraryRoot = try CalibreTestFixture.makeTempLibraryRoot()
            library = try CalibreLibrary(root: libraryRoot)
        } catch {
            XCTFail("Failed to build shared fixture: \(error)")
        }
    }

    // swiftlint:disable:next static_over_final_class
    override class func tearDown() {
        if let libraryRoot {
            try? FileManager.default.removeItem(at: libraryRoot)
        }
        library = nil
        libraryRoot = nil
    }

    private var library: CalibreLibrary { Self.library }
    private var metaDB: AmbrosiaMetaDB!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagCoverageTests-\(UUID().uuidString)")
        metaDB = try AmbrosiaMetaDB(libraryURL: url)
    }

    override func tearDownWithError() throws {
        metaDB = nil
    }

    // MARK: - Helpers

    private func insertTag(_ calibreID: Int, _ name: String, type: String = "freeform") async throws {
        try await metaDB.run(
            "INSERT OR REPLACE INTO book_tags (calibre_id, tag_name, tag_type) VALUES (?, ?, ?)",
            [calibreID, name, type]
        )
    }

    /// Gives every book except `excluded` one unrelated `book_tags` row, so it
    /// counts as covered without matching any test term.
    private func coverAllBooks(except excluded: Set<Int>) async throws {
        for id in await library.allCalibreIDs() where !excluded.contains(id) {
            try await insertTag(id, "coverage-marker")
        }
    }

    private func currentCoverage() async throws -> TagCoverage {
        let all = await library.allCalibreIDs()
        let covered = try await metaDB.calibreIDsWithBookTags()
        return TagCoverage(covered: covered, uncovered: Set(all).subtracting(covered), totalCount: all.count)
    }

    private func assertCoverageAwarePathMatchesOriginal(
        op: FilterOperator, value: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Set<Int> {
        let original = await library.tagFamilyMatchIDs(
            field: .tag, op: op, value: value, tagExpansions: [:], metaDB: metaDB
        )
        let coverage = try await currentCoverage()
        let hoisted = await library.tagFamilyMatchIDs(
            field: .tag, op: op, value: value, tagExpansions: [:], metaDB: metaDB, coverage: coverage
        )
        XCTAssertEqual(hoisted, original, "op=\(op.rawValue) value=\(value)", file: file, line: line)
        return hoisted
    }

    // MARK: - TagCoverage

    func testShouldRestrictFallbackAtOrBelowHalf() {
        // uncovered * 2 <= totalCount
        XCTAssertTrue(TagCoverage(covered: [1, 2, 3], uncovered: [4, 5], totalCount: 5).shouldRestrictFallback)
        XCTAssertTrue(TagCoverage(covered: [1, 2], uncovered: [3, 4], totalCount: 4).shouldRestrictFallback)
        XCTAssertTrue(TagCoverage(covered: [1, 2, 3, 4], uncovered: [5], totalCount: 5).shouldRestrictFallback)
    }

    func testShouldNotRestrictFallbackAboveHalf() {
        XCTAssertFalse(TagCoverage(covered: [1, 2], uncovered: [3, 4, 5], totalCount: 5).shouldRestrictFallback)
        XCTAssertFalse(TagCoverage(covered: [1], uncovered: [2, 3, 4], totalCount: 4).shouldRestrictFallback)
    }

    func testShouldRestrictFallbackWhenFullyCovered() {
        XCTAssertTrue(TagCoverage(covered: [1, 2], uncovered: [], totalCount: 2).shouldRestrictFallback)
        XCTAssertTrue(TagCoverage(covered: [], uncovered: [], totalCount: 0).shouldRestrictFallback)
    }

    // MARK: - RuleMatchKey

    func testNegatedAndPositiveOperatorsShareAKey() {
        let positive = FilterRule(field: .tag, op: .contains, value: "Fluff")
        let negated = FilterRule(field: .tag, op: .notContains, value: "Fluff")
        XCTAssertEqual(RuleMatchKey(rule: positive, tagExpansions: [:]),
                       RuleMatchKey(rule: negated, tagExpansions: [:]))
        let equals = FilterRule(field: .tag, op: .equals, value: "Fluff")
        let notEquals = FilterRule(field: .tag, op: .notEquals, value: "Fluff")
        XCTAssertEqual(RuleMatchKey(rule: equals, tagExpansions: [:]),
                       RuleMatchKey(rule: notEquals, tagExpansions: [:]))
    }

    func testKeyDiffersByOperatorFamilyValueAndField() {
        let base = RuleMatchKey(rule: FilterRule(field: .tag, op: .contains, value: "Fluff"), tagExpansions: [:])
        XCTAssertNotEqual(base, RuleMatchKey(rule: FilterRule(field: .tag, op: .equals, value: "Fluff"),
                                             tagExpansions: [:]))
        XCTAssertNotEqual(base, RuleMatchKey(rule: FilterRule(field: .tag, op: .contains, value: "Angst"),
                                             tagExpansions: [:]))
        XCTAssertNotEqual(base, RuleMatchKey(rule: FilterRule(field: .warning, op: .contains, value: "Fluff"),
                                             tagExpansions: [:]))
    }

    func testKeyIncludesTagExpansionsOnlyForTagRules() {
        let tag = FilterRule(field: .tag, op: .contains, value: "Fluff")
        XCTAssertNotEqual(RuleMatchKey(rule: tag, tagExpansions: [:]),
                          RuleMatchKey(rule: tag, tagExpansions: ["Fluff": ["Fluff", "Pure Fluff"]]))
        let warning = FilterRule(field: .warning, op: .contains, value: "Fluff")
        XCTAssertEqual(RuleMatchKey(rule: warning, tagExpansions: [:]),
                       RuleMatchKey(rule: warning, tagExpansions: ["Fluff": ["Fluff", "Pure Fluff"]]))
    }

    // MARK: - Coverage-aware tagFamilyMatchIDs

    /// Almost every book covered: uncovered is tiny, so the restricted
    /// fallback runs. Book 61360 has no `book_tags` rows and must still be
    /// found through the Calibre-side fallback.
    func testRestrictedFallbackMatchesOriginalAndFindsUncoveredBook() async throws {
        try await insertTag(769, "Harry Potter")
        try await coverAllBooks(except: [61360])
        let coverage = try await currentCoverage()
        XCTAssertEqual(coverage.uncovered, [61360])
        XCTAssertTrue(coverage.shouldRestrictFallback)

        for op in [FilterOperator.contains, .equals, .startsWith, .notContains, .notEquals] {
            _ = try await assertCoverageAwarePathMatchesOriginal(op: op, value: "Harry Potter")
        }
        let members = try await assertCoverageAwarePathMatchesOriginal(op: .contains, value: "Harry Potter")
        XCTAssertTrue(members.contains(769), "covered book matched through book_tags")
        XCTAssertTrue(members.contains(61360), "uncovered book matched through the Calibre fallback")
    }

    /// Every book covered: the fallback is skipped. Book 61360 carries the
    /// Calibre tag but is covered by an unrelated row, so book_tags is
    /// authoritative for it and it must NOT match.
    func testFullyCoveredLibrarySkipsFallbackAndMatchesOriginal() async throws {
        try await insertTag(769, "Harry Potter")
        try await coverAllBooks(except: [769])
        let coverage = try await currentCoverage()
        XCTAssertTrue(coverage.uncovered.isEmpty)

        let members = try await assertCoverageAwarePathMatchesOriginal(op: .contains, value: "Harry Potter")
        XCTAssertEqual(members, [769])
        _ = try await assertCoverageAwarePathMatchesOriginal(op: .notContains, value: "Harry Potter")
    }

    /// Few books covered: uncovered is more than half, so the unrestricted
    /// query and subtract form is kept. Results must still agree.
    func testMostlyUncoveredLibraryMatchesOriginal() async throws {
        try await insertTag(769, "Harry Potter")
        let coverage = try await currentCoverage()
        XCTAssertFalse(coverage.shouldRestrictFallback)

        for op in [FilterOperator.contains, .equals, .notContains] {
            _ = try await assertCoverageAwarePathMatchesOriginal(op: op, value: "Harry Potter")
        }
    }

    /// `.ratingAtMost` consumes coverage inside `bookTagMatchIDs`; passing it
    /// in must not change the result.
    func testRatingAtMostUsesSuppliedCoverageWithoutChangingResult() async throws {
        try await insertTag(769, "Teen And Up Audiences", type: "rating")
        try await insertTag(61360, "Explicit", type: "rating")
        try await insertTag(5259, "Mature", type: "rating")
        let withoutCoverage = try await metaDB.bookTagMatchIDs(
            op: .ratingAtMost, terms: ["Mature"], tagType: "rating"
        )
        let covered = try await metaDB.calibreIDsWithBookTags()
        let withCoverage = try await metaDB.bookTagMatchIDs(
            op: .ratingAtMost, terms: ["Mature"], tagType: "rating", coverage: covered
        )
        XCTAssertEqual(withCoverage, withoutCoverage)
        // Covered {769, 61360, 5259} minus books rated above Mature ({61360}).
        XCTAssertEqual(withCoverage, [769, 5259])
    }
}
