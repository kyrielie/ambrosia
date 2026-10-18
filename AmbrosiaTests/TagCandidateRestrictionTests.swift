import XCTest
@testable import Ambrosia

/// Covers plan PR H: `TagRuleStrategy`, `AndGroupOrdering`, the `restrictedTo`
/// / `candidates` plumbing, and end-to-end `FilterBuilder` results with tag
/// rules whose evaluation order and restriction depend on the running set.
///
/// Fixture facts: books 769 and 61360 both carry the Calibre tag
/// "Harry Potter"; 5259 is another book in the fixture.
final class TagCandidateRestrictionTests: XCTestCase {

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
            .appendingPathComponent("TagCandidateRestrictionTests-\(UUID().uuidString)")
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

    private func rule(_ op: FilterOperator, _ value: String, field: FilterField = .tag) -> FilterRule {
        FilterRule(field: field, op: op, value: value)
    }

    // MARK: - TagRuleStrategy (pure)

    func testStrategyNeverRestrictsEqualityOrRatingRange() {
        let candidates: Set<Int> = [1, 2]
        for op in [FilterOperator.equals, .notEquals, .ratingAtMost, .ratingAtLeast] {
            XCTAssertEqual(TagRuleStrategy.choose(op: op, candidates: candidates, coveredCount: 1_000), .unrestricted,
                           "op=\(op.rawValue)")
        }
    }

    func testStrategyRestrictsScanningOperatorsAtOrBelowOneInTen() {
        let candidates = Set(1...10)
        for op in [FilterOperator.contains, .startsWith, .notContains] {
            XCTAssertEqual(TagRuleStrategy.choose(op: op, candidates: candidates, coveredCount: 100),
                           .restricted(candidates), "op=\(op.rawValue) at exactly 10 percent")
            XCTAssertEqual(TagRuleStrategy.choose(op: op, candidates: candidates, coveredCount: 99),
                           .unrestricted, "op=\(op.rawValue) just above 10 percent")
        }
    }

    func testStrategyUnrestrictedWithoutCandidatesOrCoverage() {
        XCTAssertEqual(TagRuleStrategy.choose(op: .contains, candidates: nil, coveredCount: 1_000), .unrestricted)
        XCTAssertEqual(TagRuleStrategy.choose(op: .contains, candidates: [1], coveredCount: 0), .unrestricted)
    }

    // MARK: - AndGroupOrdering (pure)

    func testOrderingPutsEqualsThenRangeThenContainsThenNegated() {
        let rules = [
            rule(.notContains, "d"), rule(.contains, "c"), rule(.ratingAtLeast, "Mature", field: .rating),
            rule(.equals, "a"), rule(.startsWith, "e")
        ]
        let ordered = AndGroupOrdering.order(rules) { _ in nil }
        XCTAssertEqual(ordered.map(\.value), ["a", "Mature", "c", "e", "d"])
    }

    func testOrderingIsStableWithinAClass() {
        let rules = [rule(.contains, "x"), rule(.contains, "y"), rule(.contains, "z")]
        XCTAssertEqual(AndGroupOrdering.order(rules) { _ in nil }.map(\.value), ["x", "y", "z"])
    }

    func testOrderingPutsKnownSetsFirstSmallestFirst() {
        let rules = [rule(.equals, "a"), rule(.contains, "big"), rule(.notContains, "small")]
        let sizes = ["big": 500, "small": 5]
        let ordered = AndGroupOrdering.order(rules) { sizes[$0.value] }
        XCTAssertEqual(ordered.map(\.value), ["small", "big", "a"])
    }

    func testOrderingKeepsEveryRule() {
        let rules = (0..<20).map { rule([.contains, .equals, .notEquals, .startsWith][$0 % 4], "v\($0)") }
        let ordered = AndGroupOrdering.order(rules) { _ in nil }
        XCTAssertEqual(Set(ordered.map(\.value)), Set(rules.map(\.value)))
        XCTAssertEqual(ordered.count, rules.count)
    }

    // MARK: - Restricted tagFamilyMatchIDs

    func testRestrictedResultAgreesWithGlobalInsideCandidates() async throws {
        try await insertTag(769, "Harry Potter")
        try await coverAllBooks(except: [61360])
        let coverage = try await currentCoverage()
        let candidates: Set<Int> = [769, 61360, 5259]

        for op in [FilterOperator.contains, .startsWith, .notContains, .equals, .notEquals] {
            let global = await library.tagFamilyMatchIDs(
                field: .tag, op: op, value: "Harry Potter", tagExpansions: [:], metaDB: metaDB, coverage: coverage
            )
            let restricted = await library.tagFamilyMatchIDs(
                field: .tag, op: op, value: "Harry Potter", tagExpansions: [:], metaDB: metaDB,
                coverage: coverage, candidates: candidates
            )
            XCTAssertEqual(restricted.intersection(candidates), global.intersection(candidates),
                           "op=\(op.rawValue)")
        }
    }

    func testRestrictedResultStaysInsideCandidatesForScanningOperators() async throws {
        try await insertTag(769, "Harry Potter")
        try await insertTag(5259, "Harry Potter")
        try await coverAllBooks(except: [61360])
        let coverage = try await currentCoverage()
        let candidates: Set<Int> = [769, 61360]
        let restricted = await library.tagFamilyMatchIDs(
            field: .tag, op: .contains, value: "Harry Potter", tagExpansions: [:], metaDB: metaDB,
            coverage: coverage, candidates: candidates
        )
        XCTAssertEqual(restricted, [769, 61360], "5259 matches globally but is outside the candidates")
    }

    func testEmptyCandidatesGiveAnEmptyResult() async throws {
        try await insertTag(769, "Harry Potter")
        try await coverAllBooks(except: [61360])
        let coverage = try await currentCoverage()
        let restricted = await library.tagFamilyMatchIDs(
            field: .tag, op: .contains, value: "Harry Potter", tagExpansions: [:], metaDB: metaDB,
            coverage: coverage, candidates: []
        )
        XCTAssertTrue(restricted.isEmpty)
    }

    func testCandidatesAreIgnoredWithoutCoverage() async throws {
        try await insertTag(769, "Harry Potter")
        let withHint = await library.tagFamilyMatchIDs(
            field: .tag, op: .contains, value: "Harry Potter", tagExpansions: [:], metaDB: metaDB,
            candidates: [769]
        )
        let plain = await library.tagFamilyMatchIDs(
            field: .tag, op: .contains, value: "Harry Potter", tagExpansions: [:], metaDB: metaDB
        )
        XCTAssertEqual(withHint, plain)
    }

    // MARK: - End to end through FilterBuilder

    private func builder() -> FilterBuilder {
        FilterBuilder(library: library, ftsLibrary: nil, metaDB: metaDB, tagExpansions: [:])
    }

    /// AND of a selective rule and a negated rule. 61360 is the only book with
    /// no `book_tags` rows, so it alone has the Calibre tag without the marker.
    func testAndGroupOfContainsAndNotContainsMatchesHandComputedSet() async throws {
        try await insertTag(769, "Harry Potter")
        try await coverAllBooks(except: [61360])
        let forward = await builder().matchingIDs(
            rules: [rule(.contains, "Harry Potter"), rule(.notContains, "coverage-marker")], conjunction: .and
        )
        XCTAssertEqual(forward.calibreIDs, [61360])
        let reversed = await builder().matchingIDs(
            rules: [rule(.notContains, "coverage-marker"), rule(.contains, "Harry Potter")], conjunction: .and
        )
        XCTAssertEqual(reversed.calibreIDs, forward.calibreIDs, "rule order must not change the result")
    }

    /// `contains X` AND `not contains X` share one memoized global set and
    /// must still cancel out.
    func testContainsAndNotContainsOfSameValueIsEmpty() async throws {
        try await insertTag(769, "Harry Potter")
        try await coverAllBooks(except: [61360])
        let result = await builder().matchingIDs(
            rules: [rule(.contains, "Harry Potter"), rule(.notContains, "Harry Potter")], conjunction: .and
        )
        XCTAssertTrue(result.calibreIDs.isEmpty)
    }

    func testOrGroupUnionsTagRules() async throws {
        try await insertTag(769, "Harry Potter")
        try await insertTag(5259, "Marker One")
        try await coverAllBooks(except: [61360])
        let result = await builder().matchingIDs(
            rules: [rule(.equals, "Marker One"), rule(.equals, "Harry Potter")], conjunction: .or
        )
        // 769 via book_tags; 5259 via book_tags; 61360 is uncovered and carries
        // the Calibre tag "Harry Potter", so the fallback finds it.
        XCTAssertEqual(result.calibreIDs, [769, 5259, 61360])
    }
}
