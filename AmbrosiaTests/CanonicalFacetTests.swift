import XCTest
import SQLite
@testable import Ambrosia

/// Tests for canonical facet counts, `tag_canonical_map` synchronization, and
/// zero-inflation deduplication in `AmbrosiaMetaDB.canonicalFacets` and
/// `AO3FilterFacetController`.
final class CanonicalFacetTests: XCTestCase {

    private var metaDB: AmbrosiaMetaDB?
    private var tempDir: URL?
    private var seedDBPath: String?
    private var savedIsEnabled: Bool?
    private var savedDatabasePath: String?

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanonicalFacetTests-\(UUID().uuidString)")
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
        additionalTags: [String] = []
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
            rating: "Mature",
            warnings: [],
            extractedAt: "2024-01-01T00:00:00Z"
        )
        try await db.insertBatch([(record, id)], diagnostics: [])
    }

    private func makeSyntheticSeed(
        canonicals: [(name: String, type: String, synonyms: [String])]
    ) throws -> URL {
        let seedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanonicalFacetSeed-\(UUID().uuidString)")
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

        for item in canonicals {
            try seedConn.run(
                "INSERT INTO canonical_tags(name, tag_type, last_fetched) VALUES (?, ?, NULL)",
                [item.name as Binding?, item.type as Binding?]
            )
            let idRow = try seedConn.prepare("SELECT id FROM canonical_tags WHERE name = ?", [item.name as Binding?]).map { $0 }
            guard let canonicalID = (idRow.first?[0] as? Int64) ?? (idRow.first?[0] as? Int).map(Int64.init) else {
                continue
            }
            for syn in item.synonyms {
                try seedConn.run(
                    "INSERT INTO tag_synonyms(synonym, canonical_id) VALUES (?, ?)",
                    [syn as Binding?, canonicalID as Binding?]
                )
            }
        }
        return URL(fileURLWithPath: dbPath)
    }

    // MARK: - Synchronization Tests

    func testSyncTagCanonicalMapPopulatesSynonymsAndCanonicals() async throws {
        guard let db = metaDB else { return }

        let seedURL = try makeSyntheticSeed(canonicals: [
            ("James \"Bucky\" Barnes/Steve Rogers", "relationship", ["Stucky", "Steve Rogers/Bucky Barnes"]),
            ("The Avengers (Marvel Movies)", "fandom", ["Avengers (Movies)"])
        ])

        try await insertTestMetadata(
            id: 1,
            fandoms: ["Avengers (Movies)"],
            relationships: ["Stucky"]
        )

        let changed = try await db.syncTagCanonicalMapIfNeeded(seedURL: seedURL)
        XCTAssertTrue(changed)

        // Read back tag_canonical_map
        let mapRows = try await db.prepare("SELECT tag_name, canonical_name FROM tag_canonical_map")
        let map = Dictionary(uniqueKeysWithValues: mapRows.compactMap { row -> (String, String)? in
            guard let tag = row[0] as? String, let can = row[1] as? String else { return nil }
            return (tag, can)
        })

        XCTAssertEqual(map["Stucky"], "James \"Bucky\" Barnes/Steve Rogers")
        XCTAssertEqual(map["Avengers (Movies)"], "The Avengers (Marvel Movies)")

        // Re-running without changes is a no-op
        let reRun = try await db.syncTagCanonicalMapIfNeeded(seedURL: seedURL)
        XCTAssertFalse(reRun)
    }

    func testSyncTagCanonicalMapDisabledClearsTable() async throws {
        guard let db = metaDB else { return }

        let seedURL = try makeSyntheticSeed(canonicals: [
            ("Thor/Loki", "relationship", ["Thorki"])
        ])
        try await insertTestMetadata(id: 1, relationships: ["Thorki"])

        _ = try await db.syncTagCanonicalMapIfNeeded(seedURL: seedURL)
        var count = try await db.scalar("SELECT COUNT(*) FROM tag_canonical_map") as? Int64
        XCTAssertEqual(count, 1)

        // Now clear / disable
        _ = try await db.syncTagCanonicalMapIfNeeded(seedURL: nil, explicitIdentity: "off")
        count = try await db.scalar("SELECT COUNT(*) FROM tag_canonical_map") as? Int64
        XCTAssertEqual(count, 0)

        let marker = await db.libraryState(LibraryStateKey.tagCanonicalSeedIdentity)
        XCTAssertEqual(marker, "off")
    }

    // MARK: - Canonical Facets Deduplication Tests

    /// Verifies zero-inflation deduplication:
    /// When a book carries two synonyms of the same canonical tag, `canonicalFacets` counts
    /// the book strictly ONCE.
    func testCanonicalFacetsDeduplicatesMultipleSynonymsOnSingleBook() async throws {
        guard let db = metaDB else { return }

        let canonical = "James \"Bucky\" Barnes/Steve Rogers"
        let seedURL = try makeSyntheticSeed(canonicals: [
            (canonical, "relationship", ["Stucky", "Steve Rogers/Bucky Barnes"])
        ])

        // Book 1 carries BOTH synonyms
        try await insertTestMetadata(
            id: 1,
            relationships: ["Stucky", "Steve Rogers/Bucky Barnes"]
        )

        // Configure shared seed so canonicalFacets self-synchronizes
        await MainActor.run {
            AO3TagSeedDatabaseConfig.shared.databasePath = seedURL.path
            AO3TagSeedDatabaseConfig.shared.isEnabled = true
        }

        let facets = await db.canonicalFacets(for: .relationship, scopedTo: [1], limit: 10)
        XCTAssertEqual(facets.count, 1)
        XCTAssertEqual(facets.first?.name, canonical)
        // ZERO INFLATION: must be exactly 1, not 2!
        XCTAssertEqual(facets.first?.count, 1)
    }

    /// Verifies that Top-N ordering is evaluated AFTER merging:
    /// Synonyms that have smaller individual counts combine to rank higher than a single tag
    /// with a higher raw count.
    func testCanonicalFacetsRanksAfterMerge() async throws {
        guard let db = metaDB else { return }

        let canonicalX = "Tony Stark/Peter Parker"
        let seedURL = try makeSyntheticSeed(canonicals: [
            (canonicalX, "relationship", ["Starker", "Peter Parker & Tony Stark"])
        ])

        await MainActor.run {
            AO3TagSeedDatabaseConfig.shared.databasePath = seedURL.path
            AO3TagSeedDatabaseConfig.shared.isEnabled = true
        }

        // Tag Y has 2 books (raw count = 2)
        try await insertTestMetadata(id: 1, relationships: ["Thor/Loki"])
        try await insertTestMetadata(id: 2, relationships: ["Thor/Loki"])

        // Canonical X has 3 books total across two synonyms:
        // Book 3 has Starker (raw count = 1)
        try await insertTestMetadata(id: 3, relationships: ["Starker"])
        // Book 4 has Peter Parker & Tony Stark (raw count = 1)
        try await insertTestMetadata(id: 4, relationships: ["Peter Parker & Tony Stark"])
        // Book 5 has Starker (raw count = 1)
        try await insertTestMetadata(id: 5, relationships: ["Starker"])

        // With LIMIT 1, Canonical X (merged count 3) must beat Thor/Loki (count 2)!
        let top1 = await db.canonicalFacets(for: .relationship, scopedTo: [1, 2, 3, 4, 5], limit: 1)
        XCTAssertEqual(top1.count, 1)
        XCTAssertEqual(top1.first?.name, canonicalX)
        XCTAssertEqual(top1.first?.count, 3)

        // With LIMIT 2, both appear in correct order
        let top2 = await db.canonicalFacets(for: .relationship, scopedTo: [1, 2, 3, 4, 5], limit: 2)
        XCTAssertEqual(top2.count, 2)
        XCTAssertEqual(top2[0].name, canonicalX)
        XCTAssertEqual(top2[0].count, 3)
        XCTAssertEqual(top2[1].name, "Thor/Loki")
        XCTAssertEqual(top2[1].count, 2)
    }

    func testCanonicalFacetsUnconstrainedMatchesScopedToAll() async throws {
        guard let db = metaDB else { return }

        let canonical = "Steve Rogers/Tony Stark"
        let seedURL = try makeSyntheticSeed(canonicals: [
            (canonical, "relationship", ["Superhusbands", "Steve/Tony"])
        ])

        await MainActor.run {
            AO3TagSeedDatabaseConfig.shared.databasePath = seedURL.path
            AO3TagSeedDatabaseConfig.shared.isEnabled = true
        }

        try await insertTestMetadata(id: 1, relationships: ["Superhusbands"])
        try await insertTestMetadata(id: 2, relationships: ["Steve/Tony"])
        try await insertTestMetadata(id: 3, relationships: ["Thor/Loki"])

        let unconstrained = await db.canonicalFacetsUnconstrained(for: .relationship, limit: 10)
        let scoped = await db.canonicalFacets(for: .relationship, scopedTo: [1, 2, 3], limit: 10)

        XCTAssertEqual(unconstrained.map(\.name), scoped.map(\.name))
        XCTAssertEqual(unconstrained.map(\.count), scoped.map(\.count))
    }

    func testCanonicalFacetsFallbackWhenSeedDisabled() async throws {
        guard let db = metaDB else { return }

        await MainActor.run {
            AO3TagSeedDatabaseConfig.shared.isEnabled = false
        }

        try await insertTestMetadata(id: 1, relationships: ["SynonymA"])
        try await insertTestMetadata(id: 2, relationships: ["SynonymB"])

        let facets = await db.canonicalFacets(for: .relationship, scopedTo: [1, 2], limit: 10)
        let names = Set(facets.map(\.name))
        XCTAssertTrue(names.contains("SynonymA"))
        XCTAssertTrue(names.contains("SynonymB"))
    }
}
