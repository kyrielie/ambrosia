import XCTest
import SQLite
@testable import Ambrosia

/// Coverage for the instance-level, `@Published`-backed side of
/// `AO3TagSeedDatabaseConfig` (`isEnabled`/`databasePath`/`validationStatus`,
/// `chooseDatabase`/`clearDatabase`/`refreshValidation`/
/// `validDatabaseURLIfEnabled`) -- the half the test plan originally
/// recommended skipping as flaky, real-`UserDefaults.standard`-backed
/// singleton state.
///
/// This is `.shared`, the same singleton `TagExpansionResolverTests.swift`
/// mutates, so every test here follows that file's save/restore discipline:
/// `setUpWithError`/`tearDownWithError` snapshot and restore `isEnabled`/
/// `databasePath` so a developer's real configured seed database (or another
/// test's state) is never clobbered.
///
/// All test methods here are deliberately synchronous (not `async`), so
/// XCTest runs them on the main thread by default -- the same reason
/// `TagExpansionResolverTests`' `async` methods needed an explicit
/// `MainActor.run` hop to touch these `@Published` properties safely, this
/// file avoids that hazard entirely by never going through an `async`
/// entry point. `refreshValidation()`'s `didSet`-triggered path publishes
/// `validationStatus` synchronously in that case (see `setValidationStatus`'s
/// `Thread.isMainThread` branch), so assertions immediately after a
/// property set are not racing a background dispatch.
final class AO3TagSeedDatabaseConfigInstanceTests: XCTestCase {

    private var tempDir: URL!
    private var savedIsEnabled: Bool!
    private var savedDatabasePath: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AO3TagSeedDatabaseConfigInstanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        savedIsEnabled = AO3TagSeedDatabaseConfig.shared.isEnabled
        savedDatabasePath = AO3TagSeedDatabaseConfig.shared.databasePath
    }

    override func tearDownWithError() throws {
        AO3TagSeedDatabaseConfig.shared.isEnabled = savedIsEnabled
        AO3TagSeedDatabaseConfig.shared.databasePath = savedDatabasePath
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // Same four-table schema as AO3TagSeedDatabaseConfigValidationTests, kept
    // as an independent copy since that file's version is private to its
    // own type -- both are the required-tables shape validate(url:) checks.
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

    private func makeValidDatabase() throws -> URL {
        let dbURL = tempDir.appendingPathComponent("valid-\(UUID().uuidString).db")
        let db = try Connection(dbURL.path)
        try db.execute(Self.requiredTablesSchema)
        try db.run("INSERT INTO canonical_tags(name, tag_type) VALUES (?, 'fandom')", ["Harry Potter"])
        return dbURL
    }

    private func makeInvalidDatabase() throws -> URL {
        // Missing every required table -- a valid SQLite file, just not a
        // valid seed database.
        let dbURL = tempDir.appendingPathComponent("invalid-\(UUID().uuidString).db")
        let db = try Connection(dbURL.path)
        try db.execute("CREATE TABLE unrelated (id INTEGER PRIMARY KEY);")
        return dbURL
    }

    // MARK: - chooseDatabase(url:) / clearDatabase()

    func testChooseDatabaseSetsPathAndEnablesAndValidates() throws {
        let url = try makeValidDatabase()

        AO3TagSeedDatabaseConfig.shared.chooseDatabase(url: url)

        XCTAssertEqual(AO3TagSeedDatabaseConfig.shared.databasePath, url.path)
        XCTAssertTrue(AO3TagSeedDatabaseConfig.shared.isEnabled)
        guard case .valid(let counts) = AO3TagSeedDatabaseConfig.shared.validationStatus else {
            return XCTFail("expected .valid, got \(AO3TagSeedDatabaseConfig.shared.validationStatus)")
        }
        XCTAssertEqual(counts.canonicalTags, 1)
    }

    func testClearDatabaseResetsPathAndDisablesAndMarksDisabled() throws {
        let url = try makeValidDatabase()
        AO3TagSeedDatabaseConfig.shared.chooseDatabase(url: url)

        AO3TagSeedDatabaseConfig.shared.clearDatabase()

        XCTAssertNil(AO3TagSeedDatabaseConfig.shared.databasePath)
        XCTAssertFalse(AO3TagSeedDatabaseConfig.shared.isEnabled)
        // refreshValidation's `!isEnabled` branch takes priority over the
        // now-also-nil databasePath, so this is .disabled, not .notConfigured.
        XCTAssertEqual(AO3TagSeedDatabaseConfig.shared.validationStatus, .disabled)
    }

    // MARK: - refreshValidation() state machine

    func testRefreshValidationIsDisabledWhenNotEnabled() {
        AO3TagSeedDatabaseConfig.shared.isEnabled = false
        XCTAssertEqual(AO3TagSeedDatabaseConfig.shared.validationStatus, .disabled)
    }

    func testRefreshValidationIsNotConfiguredWhenEnabledWithNoPath() {
        AO3TagSeedDatabaseConfig.shared.databasePath = nil
        AO3TagSeedDatabaseConfig.shared.isEnabled = true
        XCTAssertEqual(AO3TagSeedDatabaseConfig.shared.validationStatus, .notConfigured)
    }

    func testRefreshValidationIsValidWithCountsForAGoodDatabase() throws {
        let url = try makeValidDatabase()
        AO3TagSeedDatabaseConfig.shared.databasePath = url.path
        AO3TagSeedDatabaseConfig.shared.isEnabled = true

        guard case .valid(let counts) = AO3TagSeedDatabaseConfig.shared.validationStatus else {
            return XCTFail("expected .valid, got \(AO3TagSeedDatabaseConfig.shared.validationStatus)")
        }
        XCTAssertEqual(counts.canonicalTags, 1)
        XCTAssertEqual(counts.synonyms, 0)
    }

    func testRefreshValidationIsInvalidWithMessageForABadDatabase() throws {
        let url = try makeInvalidDatabase()
        AO3TagSeedDatabaseConfig.shared.databasePath = url.path
        AO3TagSeedDatabaseConfig.shared.isEnabled = true

        guard case .invalid(let message) = AO3TagSeedDatabaseConfig.shared.validationStatus else {
            return XCTFail("expected .invalid, got \(AO3TagSeedDatabaseConfig.shared.validationStatus)")
        }
        XCTAssertTrue(message.contains("canonical_tags"), "message should name at least one missing table: \(message)")
    }

    // MARK: - validDatabaseURLIfEnabled()

    func testValidDatabaseURLIfEnabledReturnsNilWhenDisabled() throws {
        let url = try makeValidDatabase()
        AO3TagSeedDatabaseConfig.shared.databasePath = url.path
        AO3TagSeedDatabaseConfig.shared.isEnabled = false

        XCTAssertNil(AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled())
    }

    func testValidDatabaseURLIfEnabledReturnsNilWhenNoPathConfigured() {
        AO3TagSeedDatabaseConfig.shared.databasePath = nil
        AO3TagSeedDatabaseConfig.shared.isEnabled = true

        XCTAssertNil(AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled())
    }

    func testValidDatabaseURLIfEnabledReturnsURLForAGoodDatabase() throws {
        let url = try makeValidDatabase()
        AO3TagSeedDatabaseConfig.shared.databasePath = url.path
        AO3TagSeedDatabaseConfig.shared.isEnabled = true

        XCTAssertEqual(AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled(), url)
    }

    func testValidDatabaseURLIfEnabledReturnsNilAndRefreshesStatusForABadDatabase() throws {
        let url = try makeInvalidDatabase()
        AO3TagSeedDatabaseConfig.shared.databasePath = url.path
        AO3TagSeedDatabaseConfig.shared.isEnabled = true

        let result = AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled()

        XCTAssertNil(result)
        guard case .invalid = AO3TagSeedDatabaseConfig.shared.validationStatus else {
            return XCTFail("expected .invalid after refresh, got \(AO3TagSeedDatabaseConfig.shared.validationStatus)")
        }
    }
}
