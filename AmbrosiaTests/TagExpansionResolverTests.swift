import XCTest
import SQLite
@testable import Ambrosia

/// Coverage for `TagExpansionResolver` (`Ambrosia/Database/TagExpansionResolver.swift`),
/// against a real, actor-backed `AmbrosiaMetaDB` -- follows
/// `CollectionStoreTests.swift`'s pattern of a unique temp library URL per test.
///
/// `AmbrosiaMetaDB.expandedTermsBatch`/`.expandedTerms` gate on
/// `AO3TagSeedDatabaseConfig.shared.isEnabled`, a real `UserDefaults`-backed
/// singleton (same testability concern flagged for `CustomColumnConfig` in
/// the test plan) -- `setUpWithError`/`tearDownWithError` below save and
/// restore its `isEnabled`/`databasePath` exactly the way the plan proposes
/// for `CustomColumnConfig`, so this doesn't leave the real defaults mutated
/// for later test runs or a developer's own machine.
///
/// Synonym/canonical rows are seeded directly into `AmbrosiaMetaDB`'s own
/// `canonical_tags`/`tag_synonyms` tables via its `run(_:_:)` method, not via
/// the AO3-seed-database `ATTACH`/import path (`importConfiguredAO3TagSeedsIfNeeded`)
/// -- reading `AmbrosiaMetaDB.swift` directly (not chasing the import path
/// down) shows those are exactly the tables `expandedTermsBatch` queries, so
/// this is a legitimate, more direct seeding route for the resolver's own
/// unit tests, independent of whether the AO3-seed-import path itself has
/// separate coverage.
final class TagExpansionResolverTests: XCTestCase {

    private var libraryURL: URL!
    private var metaDB: AmbrosiaMetaDB!
    private var savedIsEnabled: Bool!
    private var savedDatabasePath: String!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagExpansionResolverTests-\(UUID().uuidString)")
        metaDB = try AmbrosiaMetaDB(libraryURL: libraryURL)

        savedIsEnabled = AO3TagSeedDatabaseConfig.shared.isEnabled
        savedDatabasePath = AO3TagSeedDatabaseConfig.shared.databasePath
    }

    override func tearDownWithError() throws {
        AO3TagSeedDatabaseConfig.shared.isEnabled = savedIsEnabled
        AO3TagSeedDatabaseConfig.shared.databasePath = savedDatabasePath
        libraryURL = nil
        metaDB = nil
    }

    /// Enables the singleton and points it at a real, valid (but otherwise
    /// unused) AO3 seed database, so `expandedTermsBatch`'s
    /// `validDatabaseURLIfEnabled() != nil` gate passes and the populated
    /// `canonical_tags`/`tag_synonyms` rows seeded directly into `metaDB`
    /// below are actually queried instead of short-circuited.
    private func enableAO3TagSeeds() async throws {
        let seedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagExpansionResolverTests-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: seedRoot, withIntermediateDirectories: true)
        let seedDBPath = seedRoot.appendingPathComponent("seed.db").path
        let seedDB = try Connection(seedDBPath)
        try seedDB.execute("""
            CREATE TABLE canonical_tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, tag_type TEXT NOT NULL DEFAULT 'unknown', last_fetched TEXT);
            CREATE TABLE tag_synonyms (synonym TEXT NOT NULL, canonical_id INTEGER NOT NULL, PRIMARY KEY (synonym));
            CREATE TABLE tag_parent_links (child_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, PRIMARY KEY (child_id, parent_id));
            CREATE TABLE tag_subtag_sections (child_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, section TEXT NOT NULL, PRIMARY KEY (child_id, parent_id));
            """)
        // AO3TagSeedDatabaseConfig's databasePath/isEnabled are @Published, so
        // Combine requires them to be set on the main thread. async test
        // methods aren't guaranteed to run on the main actor, so hop
        // explicitly rather than writing to the singleton from whatever
        // thread the test happens to be on.
        await MainActor.run {
            AO3TagSeedDatabaseConfig.shared.databasePath = seedDBPath
            AO3TagSeedDatabaseConfig.shared.isEnabled = true
        }
    }

    /// Seeds a canonical tag with two synonyms directly into `metaDB`'s own
    /// tables, bypassing the AO3-seed-import path.
    private func seedCanonicalWithSynonyms(canonical: String, synonyms: [String]) async throws {
        try await metaDB.run(
            "INSERT INTO canonical_tags(name, tag_type, last_fetched) VALUES (?, 'fandom', NULL)",
            [canonical as Binding?]
        )
        let idRow = try await metaDB.prepare("SELECT id FROM canonical_tags WHERE name = ?", [canonical as Binding?])
        guard let canonicalID = idRow.first?.first as? Int64 else {
            XCTFail("failed to read back inserted canonical_tags.id for \(canonical)")
            return
        }
        for synonym in synonyms {
            try await metaDB.run(
                "INSERT INTO tag_synonyms(synonym, canonical_id) VALUES (?, ?)",
                [synonym as Binding?, canonicalID as Binding?]
            )
        }
    }

    // MARK: - filterTagExpansions(for:metaDB:)

    func testFilterTagExpansionsNilMetaDBShortCircuitsToEmpty() async {
        var expression = FilterExpression()
        expression.groups = [FilterGroup(rules: [FilterRule(field: .tag, op: .contains, value: "Fantasy")])]
        let result = await TagExpansionResolver.filterTagExpansions(for: expression, metaDB: nil)
        XCTAssertEqual(result, [:])
    }

    func testFilterTagExpansionsOnlyPassesCompleteTagFieldRuleValues() async throws {
        try await enableAO3TagSeeds()
        try await seedCanonicalWithSynonyms(canonical: "Harry Potter", synonyms: ["HP", "Harry Potter - J. K. Rowling"])

        var expression = FilterExpression()
        expression.groups = [FilterGroup(rules: [
            FilterRule(field: .tag, op: .contains, value: "Harry Potter"),
            FilterRule(field: .authorName, op: .contains, value: "Someone"), // non-.tag: excluded
            FilterRule(field: .tag, op: .contains, value: "") // incomplete: excluded
        ])]

        let result = await TagExpansionResolver.filterTagExpansions(for: expression, metaDB: metaDB)

        XCTAssertEqual(Set(result.keys), ["Harry Potter"])
        XCTAssertEqual(Set(result["Harry Potter"] ?? []), ["Harry Potter", "HP", "Harry Potter - J. K. Rowling"])
    }

    func testFilterTagExpansionsEmptyTagValuesShortCircuitsWithoutQuerying() async throws {
        var expression = FilterExpression()
        expression.groups = [FilterGroup(rules: [FilterRule(field: .authorName, op: .contains, value: "Someone")])]
        let result = await TagExpansionResolver.filterTagExpansions(for: expression, metaDB: metaDB)
        XCTAssertEqual(result, [:])
    }

    // MARK: - resolvedTagExpansions(for:metaDB:)

    func testResolvedTagExpansionsNilMetaDBShortCircuits() async {
        let result = await TagExpansionResolver.resolvedTagExpansions(for: ["Fantasy"], metaDB: nil)
        XCTAssertEqual(result, [:])
    }

    func testResolvedTagExpansionsEmptyTermsShortCircuits() async {
        let result = await TagExpansionResolver.resolvedTagExpansions(for: [], metaDB: metaDB)
        XCTAssertEqual(result, [:])
    }

    func testResolvedTagExpansionsPopulatedTermsAgainstSeededSynonymData() async throws {
        try await enableAO3TagSeeds()
        try await seedCanonicalWithSynonyms(canonical: "Angst", synonyms: ["Light Angst"])

        let result = await TagExpansionResolver.resolvedTagExpansions(for: ["Angst"], metaDB: metaDB)

        XCTAssertEqual(Set(result.keys), ["Angst"])
        XCTAssertEqual(Set(result["Angst"] ?? []), ["Angst", "Light Angst"])
    }
}
