import XCTest
import SQLite
@testable import Ambrosia

/// Characterization tests for `AmbrosiaMetaDB.topFacets`, `topFacetsUnconstrained`,
/// `topRatingFacets`, `topRatingFacetsUnconstrained`, and `canonicalize`.
///
/// These tests pin the baseline behavior before any facet optimizations or canonical
/// deduplications are introduced, ensuring that legacy fallback paths and raw queries
/// remain identical and well-characterized.
final class FacetCharacterizationTests: XCTestCase {

    private var metaDB: AmbrosiaMetaDB?
    private var tempDir: URL?
    private var seedDBPath: String?
    private var savedIsEnabled: Bool?
    private var savedDatabasePath: String?

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FacetCharacterizationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        metaDB = try AmbrosiaMetaDB(libraryURL: dir)

        savedIsEnabled = AO3TagSeedDatabaseConfig.shared.isEnabled
        savedDatabasePath = AO3TagSeedDatabaseConfig.shared.databasePath
    }

    override func tearDownWithError() throws {
        if let savedIsEnabled {
            AO3TagSeedDatabaseConfig.shared.isEnabled = savedIsEnabled
        }
        if let savedDatabasePath {
            AO3TagSeedDatabaseConfig.shared.databasePath = savedDatabasePath
        } else {
            AO3TagSeedDatabaseConfig.shared.databasePath = nil
        }
        if let seedDBPath {
            try? FileManager.default.removeItem(atPath: seedDBPath)
        }
        seedDBPath = nil
        metaDB = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    // MARK: - Helpers

    private func insertTestMetadata(
        id: Int,
        fandoms: [String] = [],
        relationships: [String] = [],
        characters: [String] = [],
        additionalTags: [String] = [],
        rating: String? = nil
    ) async throws {
        guard let db = metaDB else {
            XCTFail("metaDB was not initialized")
            return
        }
        let record = AO3MetadataRecord(
            storyURL: nil,
            workID: nil,
            authors: [],
            kudosCount: 100,
            wordCount: 1000,
            chapterCurrent: 1,
            chapterTotal: 1,
            isComplete: true,
            language: "English",
            publishedDate: nil,
            updatedDate: nil,
            fandoms: fandoms,
            relationships: relationships,
            characters: characters,
            additionalTags: additionalTags,
            categories: ["M/M"],
            ao3Collections: [],
            series: [],
            rating: rating,
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )
        try await db.insertBatch([(record, id)], diagnostics: [])
    }

    private func enableSyntheticSeed(canonical: String, synonyms: [String], tagType: String = "relationship") async throws {
        let seedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FacetSeed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: seedRoot, withIntermediateDirectories: true)
        let dbPath = seedRoot.appendingPathComponent("seed.db").path
        seedDBPath = dbPath
        let seedConn = try Connection(dbPath)
        try seedConn.execute("""
            CREATE TABLE canonical_tags (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                tag_type TEXT NOT NULL DEFAULT 'unknown',
                last_fetched TEXT
            );
            CREATE TABLE tag_synonyms (
                synonym TEXT NOT NULL,
                canonical_id INTEGER NOT NULL,
                PRIMARY KEY (synonym)
            );
            CREATE TABLE tag_parent_links (
                child_id INTEGER NOT NULL,
                parent_id INTEGER NOT NULL,
                PRIMARY KEY (child_id, parent_id)
            );
            CREATE TABLE tag_subtag_sections (
                child_id INTEGER NOT NULL,
                parent_id INTEGER NOT NULL,
                section TEXT NOT NULL,
                PRIMARY KEY (child_id, parent_id)
            );
            """)

        try seedConn.run(
            "INSERT INTO canonical_tags(name, tag_type, last_fetched) VALUES (?, ?, NULL)",
            [canonical as Binding?, tagType as Binding?]
        )
        let idRow = try seedConn.prepare("SELECT id FROM canonical_tags WHERE name = ?", [canonical as Binding?]).map { $0 }
        guard let canonicalID = (idRow.first?[0] as? Int64) ?? (idRow.first?[0] as? Int).map(Int64.init) else {
            XCTFail("Failed to read back inserted canonical id")
            return
        }

        for syn in synonyms {
            try seedConn.run(
                "INSERT INTO tag_synonyms(synonym, canonical_id) VALUES (?, ?)",
                [syn as Binding?, canonicalID as Binding?]
            )
        }

        await MainActor.run {
            AO3TagSeedDatabaseConfig.shared.databasePath = dbPath
            AO3TagSeedDatabaseConfig.shared.isEnabled = true
        }
    }

    // MARK: - Unconstrained Facet Tests

    func testTopFacetsUnconstrainedBasicAggregation() async throws {
        guard let db = metaDB else { return }

        try await insertTestMetadata(
            id: 1,
            fandoms: ["Marvel", "Avengers"],
            relationships: ["Thor/Loki"],
            characters: ["Thor", "Loki"],
            additionalTags: ["Fluff", "Angst"]
        )
        try await insertTestMetadata(
            id: 2,
            fandoms: ["Marvel"],
            relationships: ["Thor/Loki"],
            characters: ["Thor"],
            additionalTags: ["Fluff"]
        )
        try await insertTestMetadata(
            id: 3,
            fandoms: ["DC"],
            relationships: ["Clark Kent/Bruce Wayne"],
            characters: ["Clark Kent", "Bruce Wayne"],
            additionalTags: ["Slow Burn"]
        )

        // Fandom facets
        let fandomFacets = await db.topFacetsUnconstrained(for: .fandom, limit: 10)
        let fandomMap = Dictionary(uniqueKeysWithValues: fandomFacets.map { ($0.name, $0.count) })
        XCTAssertEqual(fandomMap["Marvel"], 2)
        XCTAssertEqual(fandomMap["Avengers"], 1)
        XCTAssertEqual(fandomMap["DC"], 1)

        // Relationship facets
        let relFacets = await db.topFacetsUnconstrained(for: .relationship, limit: 10)
        let relMap = Dictionary(uniqueKeysWithValues: relFacets.map { ($0.name, $0.count) })
        XCTAssertEqual(relMap["Thor/Loki"], 2)
        XCTAssertEqual(relMap["Clark Kent/Bruce Wayne"], 1)

        // Freeform (additional tags) facets
        let freeformFacets = await db.topFacetsUnconstrained(for: .freeform, limit: 10)
        let freeformMap = Dictionary(uniqueKeysWithValues: freeformFacets.map { ($0.name, $0.count) })
        XCTAssertEqual(freeformMap["Fluff"], 2)
        XCTAssertEqual(freeformMap["Angst"], 1)
        XCTAssertEqual(freeformMap["Slow Burn"], 1)
    }

    // MARK: - Scoped Facet Tests

    func testTopFacetsScopedMatchesUnconstrainedWhenCoveringAllIDs() async throws {
        guard let db = metaDB else { return }

        try await insertTestMetadata(id: 1, fandoms: ["Marvel"], additionalTags: ["Fluff"])
        try await insertTestMetadata(id: 2, fandoms: ["Marvel"], additionalTags: ["Angst"])
        try await insertTestMetadata(id: 3, fandoms: ["DC"], additionalTags: ["Fluff"])

        let unconstrained = await db.topFacetsUnconstrained(for: .freeform, limit: 10)
        let scopedAll = await db.topFacets(for: .freeform, scopedTo: [1, 2, 3], limit: 10)

        XCTAssertEqual(unconstrained.map(\.name), scopedAll.map(\.name))
        XCTAssertEqual(unconstrained.map(\.count), scopedAll.map(\.count))
    }

    func testTopFacetsScopedNarrowsCorrectly() async throws {
        guard let db = metaDB else { return }

        try await insertTestMetadata(id: 1, fandoms: ["Marvel"], additionalTags: ["Fluff", "Action"])
        try await insertTestMetadata(id: 2, fandoms: ["Marvel"], additionalTags: ["Fluff", "Drama"])
        try await insertTestMetadata(id: 3, fandoms: ["DC"], additionalTags: ["Fluff", "Comedy"])

        // Scoping only to IDs [1, 2] should exclude book 3
        let scoped = await db.topFacets(for: .freeform, scopedTo: [1, 2], limit: 10)
        let map = Dictionary(uniqueKeysWithValues: scoped.map { ($0.name, $0.count) })
        XCTAssertEqual(map["Fluff"], 2)
        XCTAssertEqual(map["Action"], 1)
        XCTAssertEqual(map["Drama"], 1)
        XCTAssertNil(map["Comedy"])
    }

    func testTopFacetsScopedEmptyIDsReturnsEmpty() async throws {
        guard let db = metaDB else { return }

        try await insertTestMetadata(id: 1, fandoms: ["Marvel"])
        let scoped = await db.topFacets(for: .fandom, scopedTo: [], limit: 10)
        XCTAssertTrue(scoped.isEmpty)
    }

    func testTopFacetsHonorsLimit() async throws {
        guard let db = metaDB else { return }

        try await insertTestMetadata(id: 1, additionalTags: ["TagA", "TagB", "TagC", "TagD"])
        let limited = await db.topFacetsUnconstrained(for: .freeform, limit: 2)
        XCTAssertEqual(limited.count, 2)
    }

    // MARK: - Rating Facet Tests

    func testTopRatingFacetsUnconstrainedAndScoped() async throws {
        guard let db = metaDB else { return }

        try await insertTestMetadata(id: 1, rating: "Explicit")
        try await insertTestMetadata(id: 2, rating: "Explicit")
        try await insertTestMetadata(id: 3, rating: "Teen And Up Audiences")
        try await insertTestMetadata(id: 4, rating: nil)

        let unconstrained = await db.topRatingFacetsUnconstrained()
        let unconstrainedMap = Dictionary(uniqueKeysWithValues: unconstrained.map { ($0.name, $0.count) })
        XCTAssertEqual(unconstrainedMap["Explicit"], 2)
        XCTAssertEqual(unconstrainedMap["Teen And Up Audiences"], 1)
        XCTAssertNil(unconstrainedMap[""])

        let scoped = await db.topRatingFacets(scopedTo: [2, 3])
        let scopedMap = Dictionary(uniqueKeysWithValues: scoped.map { ($0.name, $0.count) })
        XCTAssertEqual(scopedMap["Explicit"], 1)
        XCTAssertEqual(scopedMap["Teen And Up Audiences"], 1)

        let emptyScoped = await db.topRatingFacets(scopedTo: [])
        XCTAssertTrue(emptyScoped.isEmpty)
    }

    // MARK: - Canonicalize Behavior and Defect Characterization

    func testCanonicalizeSeedDisabledReturnsInputSorted() async throws {
        guard let db = metaDB else { return }

        await MainActor.run {
            AO3TagSeedDatabaseConfig.shared.isEnabled = false
        }

        let raw: [(name: String, count: Int)] = [
            ("TagMinor", 2),
            ("TagMajor", 10),
            ("TagMiddle", 5)
        ]
        let result = await db.canonicalize(raw)
        XCTAssertEqual(result.map(\.name), ["TagMajor", "TagMiddle", "TagMinor"])
        XCTAssertEqual(result.map(\.count), [10, 5, 2])
    }

    /// Characterizes the known count inflation defect:
    /// When a book carries two synonyms of the same canonical tag, `json_each` produces
    /// one raw row for each synonym, and `canonicalize` sums them, causing the facet badge
    /// count to be 2 for a single book.
    func testCanonicalizeSynonymInflationDefectCharacterized() async throws {
        guard let db = metaDB else { return }

        let canonical = "James \"Bucky\" Barnes/Steve Rogers"
        let synonyms = ["Stucky", "Steve Rogers/Bucky Barnes"]
        try await enableSyntheticSeed(canonical: canonical, synonyms: synonyms)

        // Single book with both synonyms on it
        try await insertTestMetadata(id: 1, relationships: ["Stucky", "Steve Rogers/Bucky Barnes"])

        let raw = await db.topFacets(for: .relationship, scopedTo: [1], limit: 10)
        XCTAssertEqual(raw.count, 2)
        let rawNames = Set(raw.map(\.name))
        XCTAssertTrue(rawNames.contains("Stucky"))
        XCTAssertTrue(rawNames.contains("Steve Rogers/Bucky Barnes"))

        // Legacy canonicalize sums the counts of synonyms
        let canonicalized = await db.canonicalize(raw)
        XCTAssertEqual(canonicalized.count, 1)
        XCTAssertEqual(canonicalized.first?.name, canonical)
        // DOCUMENTED INFLATION: count is 2 even though only 1 book matches
        XCTAssertEqual(canonicalized.first?.count, 2)
    }

    /// Characterizes the raw LIMIT-before-merge defect:
    /// When `LIMIT ?` is executed in SQL on raw tag names, synonyms split across lower raw
    /// counts are cut off before `canonicalize` sums them.
    func testCanonicalizeLimitBeforeMergeDefectCharacterized() async throws {
        guard let db = metaDB else { return }

        let canonical = "Tony Stark/Peter Parker"
        let synonyms = ["Starker", "Peter Parker & Tony Stark"]
        try await enableSyntheticSeed(canonical: canonical, synonyms: synonyms)

        // Book 1 and 2 have "Thor/Loki" (raw count = 2)
        try await insertTestMetadata(id: 1, relationships: ["Thor/Loki"])
        try await insertTestMetadata(id: 2, relationships: ["Thor/Loki"])

        // Book 3 has "Starker" (raw count = 1)
        try await insertTestMetadata(id: 3, relationships: ["Starker"])
        // Book 4 has "Peter Parker & Tony Stark" (raw count = 1)
        try await insertTestMetadata(id: 4, relationships: ["Peter Parker & Tony Stark"])

        // If limit is 1, raw SQL returns only "Thor/Loki" (count 2),
        // completely cutting off both Starker (1) and Peter Parker & Tony Stark (1).
        let rawLimit1 = await db.topFacetsUnconstrained(for: .relationship, limit: 1)
        XCTAssertEqual(rawLimit1.count, 1)
        XCTAssertEqual(rawLimit1.first?.name, "Thor/Loki")

        let mergedLimit1 = await db.canonicalize(rawLimit1)
        XCTAssertEqual(mergedLimit1.count, 1)
        XCTAssertEqual(mergedLimit1.first?.name, "Thor/Loki")
        // Canonical Tony Stark/Peter Parker has 0 rows because it was cut off before merge!
        XCTAssertFalse(mergedLimit1.contains { $0.name == canonical })

        // If limit is 5, both synonyms survive raw cut and get merged into count 2
        let rawLimit5 = await db.topFacetsUnconstrained(for: .relationship, limit: 5)
        let mergedLimit5 = await db.canonicalize(rawLimit5)
        let canonicalEntry = mergedLimit5.first { $0.name == canonical }
        XCTAssertNotNil(canonicalEntry)
        XCTAssertEqual(canonicalEntry?.count, 2)
    }
}
