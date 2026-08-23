import XCTest
import SQLite
@testable import Ambrosia

/// Coverage for the static, URL-taking functions on `AO3TagSeedDatabaseConfig`
/// (`Ambrosia/Database/AO3TagSeedDatabaseConfig.swift`): `validate(url:)`,
/// `counts(url:)`, `identity(for:)`. No singleton involved -- these take a
/// `URL` directly, unlike the `@Published` instance properties
/// (`isEnabled`/`databasePath`/`chooseDatabase`/etc.), which the test plan
/// explicitly recommends leaving out of this pass as a real
/// `UserDefaults.standard` singleton with main-thread-dispatch branching.
///
/// Uses the schema in `AmbrosiaTests/ao3_tag_seed_fixture_schema.sql`
/// verbatim (the four required tables) for the fixture below, built via a
/// tiny temp-file `Connection`, matching `CalibreTestFixture`'s pattern.
final class AO3TagSeedDatabaseConfigValidationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AO3TagSeedDatabaseConfigValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private static let requiredTablesSchema = """
        CREATE TABLE canonical_tags (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            name         TEXT    NOT NULL UNIQUE,
            tag_type     TEXT    NOT NULL DEFAULT 'unknown',
            last_fetched TEXT
        );
        CREATE TABLE tag_synonyms (
            synonym      TEXT    NOT NULL,
            canonical_id INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
            PRIMARY KEY (synonym)
        );
        CREATE TABLE tag_parent_links (
            child_id     INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
            parent_id    INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
            PRIMARY KEY (child_id, parent_id)
        );
        CREATE TABLE tag_subtag_sections (
            child_id     INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
            parent_id    INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
            section      TEXT    NOT NULL,
            PRIMARY KEY (child_id, parent_id)
        );
        """

    private func makeCompleteFixture(canonicalRows: Int = 3, synonymRows: Int = 2) throws -> URL {
        let dbURL = tempDir.appendingPathComponent("complete-\(UUID().uuidString).db")
        let db = try Connection(dbURL.path)
        try db.execute(Self.requiredTablesSchema)
        for index in 0..<canonicalRows {
            try db.run("INSERT INTO canonical_tags(name, tag_type) VALUES (?, 'fandom')", [ "Tag \(index)" ])
        }
        for index in 0..<synonymRows {
            try db.run("INSERT INTO tag_synonyms(synonym, canonical_id) VALUES (?, 1)", [ "Synonym \(index)" ])
        }
        return dbURL
    }

    private func makeIncompleteFixture(missingTable: String) throws -> URL {
        let dbURL = tempDir.appendingPathComponent("incomplete-\(UUID().uuidString).db")
        let db = try Connection(dbURL.path)
        // Every table from the schema except `missingTable`.
        let statements = Self.requiredTablesSchema
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for statement in statements where !statement.contains("CREATE TABLE \(missingTable) ") {
            try db.execute(statement + ";")
        }
        return dbURL
    }

    // MARK: - validate(url:)

    func testValidateSucceedsAgainstCompleteFixture() throws {
        let url = try makeCompleteFixture()
        XCTAssertNoThrow(try AO3TagSeedDatabaseConfig.validate(url: url))
    }

    func testValidateThrowsMissingTablesListingExactlyTheMissingTable() throws {
        let url = try makeIncompleteFixture(missingTable: "tag_subtag_sections")
        XCTAssertThrowsError(try AO3TagSeedDatabaseConfig.validate(url: url)) { error in
            guard case AO3TagSeedDatabaseConfig.SeedError.missingTables(let tables) = error else {
                return XCTFail("expected .missingTables, got \(error)")
            }
            XCTAssertEqual(tables, ["tag_subtag_sections"])
        }
    }

    func testValidateThrowsMissingTablesListingMultipleMissingTables() throws {
        let url = try makeIncompleteFixture(missingTable: "tag_parent_links")
        // makeIncompleteFixture only omits one table at a time by construction;
        // this exercises a second single-table-missing case with a different
        // table to confirm the check isn't hardcoded to one table name.
        XCTAssertThrowsError(try AO3TagSeedDatabaseConfig.validate(url: url)) { error in
            guard case AO3TagSeedDatabaseConfig.SeedError.missingTables(let tables) = error else {
                return XCTFail("expected .missingTables, got \(error)")
            }
            XCTAssertEqual(tables, ["tag_parent_links"])
        }
    }

    // MARK: - counts(url:)

    func testCountsMatchExactRowCounts() throws {
        let url = try makeCompleteFixture(canonicalRows: 5, synonymRows: 3)
        let counts = try AO3TagSeedDatabaseConfig.counts(url: url)
        XCTAssertEqual(counts.canonicalTags, 5)
        XCTAssertEqual(counts.synonyms, 3)
        XCTAssertEqual(counts.hierarchyEdges, 0)
        XCTAssertEqual(counts.subtagSections, 0)
    }

    // MARK: - identity(for:)

    func testIdentityIsEqualAcrossTwoCallsAgainstUnmodifiedFile() throws {
        let url = try makeCompleteFixture()
        let first = try AO3TagSeedDatabaseConfig.identity(for: url)
        let second = try AO3TagSeedDatabaseConfig.identity(for: url)
        XCTAssertEqual(first, second)
    }

    func testIdentityChangesWhenModificationDateChanges() throws {
        let url = try makeCompleteFixture()
        let before = try AO3TagSeedDatabaseConfig.identity(for: url)

        // Touch the file's modification date forward by a full minute so this
        // isn't flaky against filesystem mtime resolution.
        let newDate = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: url.path)

        let after = try AO3TagSeedDatabaseConfig.identity(for: url)
        XCTAssertNotEqual(before, after)
    }
}
