import XCTest
@testable import Ambrosia

/// The key correctness property of plan PR I: evaluating a delta rule with the
/// base result as `candidateIDs`, then intersecting with the base, equals a full
/// evaluation of the combined expression. Covers positive and negated tag
/// operators, equals (never restricted), an SQL rule, and a collection rule.
final class IncrementalEquivalenceTests: XCTestCase {

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
        if let libraryRoot { try? FileManager.default.removeItem(at: libraryRoot) }
        library = nil
        libraryRoot = nil
    }

    private var library: CalibreLibrary { Self.library }
    private var metaDB: AmbrosiaMetaDB!
    private var allIDs: [Int] = []

    override func setUp() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalEquivalenceTests-\(UUID().uuidString)")
        metaDB = try AmbrosiaMetaDB(libraryURL: url)
        allIDs = await library.allCalibreIDs()
        // Deterministic spread of tags over the fixture: every book gets a
        // coverage marker; books alternate between two tag families.
        for (index, id) in allIDs.enumerated() {
            try await insert(id, "coverage-marker")
            if index % 2 == 0 { try await insert(id, "Fluff") }
            if index % 3 == 0 { try await insert(id, "Angst") }
            if index % 5 == 0 { try await insert(id, "Fluff and Angst") }
        }
    }

    override func tearDown() async throws {
        metaDB = nil
    }

    private func insert(_ id: Int, _ name: String) async throws {
        try await metaDB.run(
            "INSERT OR REPLACE INTO book_tags (calibre_id, tag_name, tag_type) VALUES (?, ?, ?)",
            [id, name, "freeform"]
        )
    }

    private func builder() -> FilterBuilder {
        FilterBuilder(library: library, metaDB: metaDB)
    }

    private func andExpression(_ rules: [FilterRule]) -> FilterExpression {
        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: rules, conjunction: .and)]
        expr.groupConjunction = .and
        return expr
    }

    /// Full evaluation of base + delta versus narrowing the base result.
    private func assertNarrowedEqualsFull(
        base baseRules: [FilterRule], delta: FilterRule,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let full = await builder().matchingIDs(expression: andExpression(baseRules + [delta]))
        let base = await builder().matchingIDs(expression: andExpression(baseRules))
        let deltaSet = await builder().matchingIDs(
            expression: IncrementalFilterPlanner.deltaExpression(for: delta),
            candidateIDs: Set(base.calibreIDs)
        )
        let deltaMembers = Set(deltaSet.calibreIDs)
        let narrowed = base.calibreIDs.filter { deltaMembers.contains($0) }
        XCTAssertEqual(narrowed, full.calibreIDs,
                       "delta \(delta.field.rawValue) \(delta.op.rawValue) \(delta.value)",
                       file: file, line: line)
    }

    func testNarrowingByPositiveAndNegatedTagOperators() async {
        let base = [FilterRule(field: .tag, op: .contains, value: "Fluff")]
        for op in [FilterOperator.contains, .notContains, .equals, .notEquals, .startsWith] {
            await assertNarrowedEqualsFull(base: base, delta: FilterRule(field: .tag, op: op, value: "Angst"))
        }
    }

    func testNarrowingFromASmallBaseUsesRestrictedPathWithSameResult() async {
        // "Fluff and Angst" is on every fifth book: a small base, so a following
        // `contains` qualifies for the restricted strategy when the library is large
        // enough, and takes the unrestricted path otherwise. Either way the result
        // must equal the full evaluation.
        let base = [FilterRule(field: .tag, op: .equals, value: "Fluff and Angst")]
        for op in [FilterOperator.contains, .notContains, .startsWith] {
            await assertNarrowedEqualsFull(base: base, delta: FilterRule(field: .tag, op: op, value: "Fluff"))
        }
    }

    func testNarrowingBySQLRule() async {
        let base = [FilterRule(field: .tag, op: .contains, value: "Fluff")]
        await assertNarrowedEqualsFull(base: base, delta: FilterRule(field: .title, op: .contains, value: "a"))
        await assertNarrowedEqualsFull(base: base, delta: FilterRule(field: .title, op: .notContains, value: "a"))
    }

    func testNarrowingByCollectionRule() async {
        let members = Set(allIDs.prefix(allIDs.count / 2))
        let delta = FilterRule(field: .collection, op: .equals, value: "Favorites")
        let base = [FilterRule(field: .tag, op: .contains, value: "Fluff")]
        let collectionMap = ["Favorites": members]

        let full = await builder().matchingIDs(expression: andExpression(base + [delta]),
                                               collectionMap: collectionMap)
        let baseResult = await builder().matchingIDs(expression: andExpression(base),
                                                     collectionMap: collectionMap)
        let deltaResult = await builder().matchingIDs(
            expression: IncrementalFilterPlanner.deltaExpression(for: delta),
            collectionMap: collectionMap,
            candidateIDs: Set(baseResult.calibreIDs)
        )
        let deltaSet = Set(deltaResult.calibreIDs)
        XCTAssertEqual(baseResult.calibreIDs.filter { deltaSet.contains($0) }, full.calibreIDs)
    }

    func testCandidatesNeverLeakIDsOutsideTheCandidateSet() async {
        let candidates = Set(allIDs.prefix(3))
        let result = await builder().matchingIDs(
            expression: IncrementalFilterPlanner.deltaExpression(
                for: FilterRule(field: .tag, op: .notContains, value: "nonexistent-tag")
            ),
            candidateIDs: candidates
        )
        XCTAssertEqual(Set(result.calibreIDs), candidates)
    }

    func testEmptyCandidatesGiveEmptyResult() async {
        let result = await builder().matchingIDs(
            expression: IncrementalFilterPlanner.deltaExpression(
                for: FilterRule(field: .tag, op: .contains, value: "Fluff")
            ),
            candidateIDs: []
        )
        XCTAssertTrue(result.calibreIDs.isEmpty)
    }

    func testResultWithoutCandidatesIsUnchanged() async {
        let rules = [FilterRule(field: .tag, op: .contains, value: "Fluff"),
                     FilterRule(field: .tag, op: .notContains, value: "Angst")]
        let plain = await builder().matchingIDs(expression: andExpression(rules))
        let withNilCandidates = await builder().matchingIDs(expression: andExpression(rules), candidateIDs: nil)
        XCTAssertEqual(plain.calibreIDs, withNilCandidates.calibreIDs)
    }

    // MARK: - FilterEvaluator

    private func evaluator() -> FilterEvaluator {
        FilterEvaluator(library: library, ftsLibrary: nil, metaDB: metaDB, collectionStore: nil)
    }

    func testEvaluatorWithCandidatesMatchesBuilderNarrowing() async {
        let baseRules = [FilterRule(field: .tag, op: .contains, value: "Fluff")]
        let delta = FilterRule(field: .tag, op: .notContains, value: "Angst")
        let full = await evaluator().evaluate(expression: andExpression(baseRules + [delta]), fulltextMap: [:])
        let base = await evaluator().evaluate(expression: andExpression(baseRules), fulltextMap: [:])
        let narrowedDelta = await evaluator().evaluate(
            expression: IncrementalFilterPlanner.deltaExpression(for: delta),
            fulltextMap: [:],
            candidates: Set(base?.result.calibreIDs ?? [])
        )
        let members = Set(narrowedDelta?.result.calibreIDs ?? [])
        let narrowed = (base?.result.calibreIDs ?? []).filter { members.contains($0) }
        XCTAssertNotNil(full)
        XCTAssertEqual(narrowed, full?.result.calibreIDs)
        XCTAssertTrue(members.isSubset(of: Set(base?.result.calibreIDs ?? [])))
    }

    func testEvaluatorReturnsNilWhenCancelled() async {
        let evaluator = evaluator()
        let expression = andExpression([FilterRule(field: .tag, op: .contains, value: "Fluff")])
        let task = Task { () -> FilterEvaluator.Output? in
            while !Task.isCancelled { await Task.yield() }
            return await evaluator.evaluate(expression: expression, fulltextMap: [:])
        }
        task.cancel()
        let output = await task.value
        XCTAssertNil(output)
    }

    func testEnvironmentSignatureReflectsColumnConfigurationShape() {
        let signature = FilterEvaluator.environmentSignature
        XCTAssertTrue(signature.contains(".wc"))
        XCTAssertTrue(signature.contains(".ku"))
    }
}
