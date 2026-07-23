import CryptoKit
import Foundation
import SQLite

struct ReadingHistoryEntry: Identifiable, Hashable, Sendable {
    let id: Int64
    let calibreID: Int
    let sessionStart: Date
    let sessionEnd: Date
    let wordsRead: Int?
    let percentStart: Double?
    let percentEnd: Double?
    let fandoms: [String]
    let categories: [String]
}

enum MetaDBError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Could not locate the Application Support directory."
        }
    }
}

func libraryHash(for libraryURL: URL) -> String {
    let resolved = libraryURL.resolvingSymlinksInPath().path
    let digest = SHA256.hash(data: Data(resolved.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

actor AmbrosiaMetaDB {
    let libraryHash: String
    let databaseURL: URL
    /// Write connection — holds the WAL writer lock during transactions.
    private let db: Connection
    /// Read-only connection — under WAL mode SQLite allows concurrent reads
    /// even while a write transaction is in progress, so collection/filter
    /// queries are never queued behind AO3 extraction inserts.
    private let readDB: Connection

    // MARK: - Per-ID / per-key caches
    //
    // AmbrosiaMetaDB is the sole owner of ambrosia_meta.db reads and writes
    // (Invariant 10); these caches live here rather than in a view-level
    // cache so both LibraryRootView and EmailLibraryViewController share a
    // single source of truth. Keyed per-row (by calibreID, or by series
    // key), not by the requested ID *set* — callers' page-ID-set and
    // all-series-ID-set requests overlap heavily but are rarely identical,
    // so a set-keyed cache (like CalibreLibrary.PageCacheKey) would rarely
    // hit. Every write site that touches ao3_metadata,
    // ao3_extraction_diagnostics, series_cache, or series_placeholders must
    // evict the corresponding entries below.
    private var ao3MetadataCache: [Int: AO3MetadataRecord] = [:]
    private var ao3DiagnosticsCache: [Int: AO3ExtractionDiagnostic] = [:]
    private var seriesEntriesCache: [Int: [SeriesCacheEntry]] = [:]
    private var seriesEntriesByKeyCache: [String: [SeriesCacheEntry]] = [:]
    private var singletonWarningsCache: [Int: [SingletonSeriesWarning]] = [:]
    private var placeholdersCache: [String: [SeriesPlaceholder]] = [:]

    init(libraryURL: URL) throws {
        self.libraryHash = Ambrosia.libraryHash(for: libraryURL)
        let dir = try Self.databaseDirectory(for: libraryHash)
        self.databaseURL = dir.appendingPathComponent("ambrosia_meta.db")
        let writePath = databaseURL.path
        self.db = try Connection(writePath)
        self.readDB = try Connection(writePath, readonly: true)
        // WAL mode: readers never block writers and writers never block readers.
        // Must be set on the write connection before migrations run.
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try Self.runMigrations(db: db)
    }

    static func librariesBaseDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MetaDBError.applicationSupportUnavailable
        }
        let dir = support.appendingPathComponent("Ambrosia").appendingPathComponent("libraries")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func databaseDirectory(for hash: String) throws -> URL {
        let dir = try librariesBaseDirectory().appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func runMigrations(db: Connection) throws {
        try db.execute("PRAGMA foreign_keys = ON")
        try createCollections(db: db)
        try createAnnotations(db: db)
        try createReadingHistory(db: db)
        try createAO3Metadata(db: db)
        try createSchemaMigrations(db: db)
        try bridgeLegacyUserVersionMigrations(db: db)
        try migrateSeriesPlaceholdersToKeyedIfNeeded(db: db)
        try dedupeSeriesCacheIfNeeded(db: db)
        try dropAO3AuthorUsernameIfNeeded(db: db)
        try createAO3TagSynonyms(db: db)
        try bootstrapSystemCollections(db: db)
    }

    // MARK: - Migration tracking (Finding 13)
    //
    // The two migrations below predate this table and were gated solely on
    // PRAGMA user_version — a single global ordinal with no per-migration
    // name record. That means a future migration must know the current
    // highest version number *and* be appended after these two in
    // runMigrations' call order, with nothing enforcing either constraint.
    // schema_migrations replaces that with name-based membership checks, so
    // new migrations can be added in any order without an ordinal to track.
    // bridgeLegacyUserVersionMigrations backfills this table for installs
    // that already ran the two user_version-gated migrations, so they are
    // not re-run under the new check.

    private static func createSchemaMigrations(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            name        TEXT PRIMARY KEY,
            applied_at  TEXT NOT NULL
        );
        """)
    }

    private static func hasAppliedMigration(_ name: String, db: Connection) -> Bool {
        let count = (try? db.scalar("SELECT COUNT(*) FROM schema_migrations WHERE name = ?", name)) as? Int64 ?? 0
        return count > 0
    }

    private static func markMigrationApplied(_ name: String, db: Connection) throws {
        try db.run(
            "INSERT OR IGNORE INTO schema_migrations (name, applied_at) VALUES (?, ?)",
            name, ISO8601DateFormatter().string(from: Date())
        )
    }

    private static func bridgeLegacyUserVersionMigrations(db: Connection) throws {
        let version = (try? db.scalar("PRAGMA user_version")) as? Int64 ?? 0
        if version >= seriesPlaceholdersKeyedMigrationVersion {
            try markMigrationApplied(migrationNameSeriesPlaceholdersToKeyed, db: db)
        }
        if version >= dedupeSeriesCacheMigrationVersion {
            try markMigrationApplied(migrationNameDedupeSeriesCache, db: db)
        }
    }

    private static func createCollections(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS collections (
            id          TEXT    PRIMARY KEY,
            name        TEXT    NOT NULL,
            kind        TEXT    NOT NULL DEFAULT 'manual',
            is_system   INTEGER NOT NULL DEFAULT 0,
            created_at  TEXT    NOT NULL,
            sort_order  INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS collection_members (
            collection_id  TEXT    NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            calibre_id     INTEGER NOT NULL,
            added_at       TEXT    NOT NULL,
            PRIMARY KEY (collection_id, calibre_id)
        );

        CREATE INDEX IF NOT EXISTS idx_collection_members_calibre
            ON collection_members(calibre_id);
        """)
    }

    private static func createAnnotations(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS annotations (
            id            TEXT    PRIMARY KEY,
            calibre_id    INTEGER NOT NULL,
            spine_index   INTEGER NOT NULL,
            start_char    INTEGER NOT NULL,
            end_char      INTEGER NOT NULL,
            selected_text TEXT    NOT NULL DEFAULT '',
            note          TEXT,
            color_hex     TEXT,
            created_at    TEXT    NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_annotations_calibre
            ON annotations(calibre_id);

        CREATE INDEX IF NOT EXISTS idx_annotations_position
            ON annotations(calibre_id, spine_index, start_char);
        """)
    }

    private static func createReadingHistory(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS reading_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            calibre_id INTEGER NOT NULL,
            session_start TEXT NOT NULL,
            session_end TEXT NOT NULL,
            words_read INTEGER,
            percent_start REAL,
            percent_end REAL
        );

        CREATE INDEX IF NOT EXISTS idx_reading_history_calibre
            ON reading_history(calibre_id);

        CREATE INDEX IF NOT EXISTS idx_reading_history_start
            ON reading_history(session_start);

        CREATE TABLE IF NOT EXISTS book_opens (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            calibre_id INTEGER NOT NULL,
            opened_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_book_opens_calibre
            ON book_opens(calibre_id);

        CREATE INDEX IF NOT EXISTS idx_book_opens_time
            ON book_opens(opened_at);
        """)
    }

    private static func bootstrapSystemCollections(db: Connection) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT OR IGNORE INTO collections (id, name, kind, is_system, created_at, sort_order)
        VALUES (?, ?, ?, 1, ?, ?)
        """
        for row in SystemCollectionID.bootstrapRows {
            try db.run(sql, row.id, row.name, row.kind, now, row.sortOrder)
        }
    }

    /// Checks whether `column` already exists on `table`, so additive
    /// migrations can be made idempotent instead of relying on `try?` to
    /// swallow the "duplicate column name" error on every launch.
    private static func columnExists(_ table: String, _ column: String, db: Connection) throws -> Bool {
        let rows = try db.prepare("PRAGMA table_info(\(table))").map { $0 }
        return rows.contains { ($0[1] as? String) == column }
    }

    private static func createAO3Metadata(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS ao3_metadata (
            calibre_id INTEGER PRIMARY KEY,
            story_url TEXT,
            ao3_work_id TEXT,
            authors_json TEXT,
            author_names_json TEXT,
            kudos_count INTEGER,
            word_count INTEGER,
            chapter_current INTEGER,
            chapter_total INTEGER,
            is_complete INTEGER NOT NULL DEFAULT 0,
            language TEXT,
            published_date TEXT,
            updated_date TEXT,
            fandoms_json TEXT,
            relationships_json TEXT,
            characters_json TEXT,
            additional_tags_json TEXT,
            category_json TEXT,
            ao3_collections_json TEXT,
            series_json TEXT,
            rating TEXT,
            warnings_json TEXT,
            extracted_at TEXT NOT NULL
        );
        """)
        // Additive columns for libraries whose ao3_metadata table predates rating/
        // warnings extraction. CREATE TABLE IF NOT EXISTS above only applies to
        // brand-new tables, so existing tables need these added explicitly.
        if try !columnExists("ao3_metadata", "rating", db: db) {
            try db.run("ALTER TABLE ao3_metadata ADD COLUMN rating TEXT")
        }
        if try !columnExists("ao3_metadata", "warnings_json", db: db) {
            try db.run("ALTER TABLE ao3_metadata ADD COLUMN warnings_json TEXT")
        }
        if try !columnExists("ao3_metadata", "authors_json", db: db) {
            try db.run("ALTER TABLE ao3_metadata ADD COLUMN authors_json TEXT")
        }
        // author_names_json is a flat [String] of display names (pseud, falling
        // back to username), kept alongside the structured authors_json. The
        // generic facet aggregation (AmbrosiaMetaDB.topFacets/
        // topFacetsUnconstrained) runs `json_each` expecting a scalar-string
        // array, same shape as fandoms_json/warnings_json/etc. — authors_json's
        // array-of-objects shape isn't that, so AO3FacetField.author points at
        // this denormalized column instead. authors_json remains the source of
        // truth for anything that needs the structured entry (profile URL,
        // pseud/username, source tier).
        if try !columnExists("ao3_metadata", "author_names_json", db: db) {
            try db.run("ALTER TABLE ao3_metadata ADD COLUMN author_names_json TEXT")
        }
        try db.execute("""
        CREATE TABLE IF NOT EXISTS series_cache (
            calibre_id INTEGER NOT NULL,
            series_name TEXT NOT NULL,
            series_index INTEGER NOT NULL,
            ao3_series_id TEXT,
            is_anthology INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (calibre_id, series_name)
        );

        CREATE INDEX IF NOT EXISTS idx_series_cache_name ON series_cache(series_name);
        CREATE INDEX IF NOT EXISTS idx_series_cache_calibre ON series_cache(calibre_id);

        CREATE TABLE IF NOT EXISTS series_placeholders (
            series_name TEXT NOT NULL,
            series_key TEXT NOT NULL,
            part_index INTEGER NOT NULL,
            note TEXT,
            PRIMARY KEY (series_key, part_index)
        );

        CREATE TABLE IF NOT EXISTS ao3_extraction_diagnostics (
            calibre_id INTEGER PRIMARY KEY,
            status TEXT NOT NULL,
            reason TEXT NOT NULL,
            epub_path TEXT,
            epub_filename TEXT,
            spine_items_checked INTEGER,
            attempted_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_series_cache_key
            ON series_cache(COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name));

        CREATE INDEX IF NOT EXISTS idx_ao3_extraction_diagnostics_status
            ON ao3_extraction_diagnostics(status);

        """)
    }

    /// One-time migration: the original `series_placeholders` table predates
    /// the `series_key` column. This rekeys it onto `series_key` as the
    /// primary key component instead of bare `series_name`. Gated on
    /// `PRAGMA user_version` so the destructive DROP + RENAME runs exactly
    /// once instead of on every cold start, and wrapped in a transaction so
    /// a crash mid-migration cannot leave the database without the table.
    private static let seriesPlaceholdersKeyedMigrationVersion: Int64 = 1
    private static let migrationNameSeriesPlaceholdersToKeyed = "2025_series_placeholders_keyed"

    private static func migrateSeriesPlaceholdersToKeyedIfNeeded(db: Connection) throws {
        guard !hasAppliedMigration(migrationNameSeriesPlaceholdersToKeyed, db: db) else { return }
        try db.transaction {
            _ = try? db.run("ALTER TABLE series_placeholders ADD COLUMN series_key TEXT")
            try db.run("UPDATE series_placeholders SET series_key = 'calibre:' || series_name WHERE series_key IS NULL OR series_key = ''")
            try db.execute("""
            CREATE TABLE IF NOT EXISTS series_placeholders_keyed (
                series_key TEXT NOT NULL,
                series_name TEXT NOT NULL,
                part_index INTEGER NOT NULL,
                note TEXT,
                PRIMARY KEY (series_key, part_index)
            );

            INSERT OR IGNORE INTO series_placeholders_keyed (series_key, series_name, part_index, note)
            SELECT series_key, series_name, part_index, note
            FROM series_placeholders
            WHERE series_key IS NOT NULL AND series_key != '';

            DROP TABLE series_placeholders;
            ALTER TABLE series_placeholders_keyed RENAME TO series_placeholders;

            CREATE INDEX IF NOT EXISTS idx_series_placeholders_key ON series_placeholders(series_key);
            """)
            try db.run("PRAGMA user_version = \(seriesPlaceholdersKeyedMigrationVersion)")
            try markMigrationApplied(migrationNameSeriesPlaceholdersToKeyed, db: db)
        }
    }

    /// One-time data repair: prior to the `insertCalibreSeriesFallback` fix
    /// above, a book could accumulate both a real AO3-derived `series_cache`
    /// row and a spurious Calibre-fallback row under an unrelated series_key.
    /// The spurious row pulls the book into whatever Calibre series shares
    /// that name across the whole library, which can be a huge, meaningless
    /// group. This deletes any Calibre-fallback row (`ao3_series_id IS NULL`)
    /// for a `calibre_id` that also has a genuine AO3 row (`ao3_series_id IS
    /// NOT NULL`), leaving only the genuine AO3 series membership. Gated on
    /// `PRAGMA user_version` per Invariant 11 so it runs exactly once.
    private static let dedupeSeriesCacheMigrationVersion: Int64 = 2
    private static let migrationNameDedupeSeriesCache = "2025_dedupe_series_cache"

    private static func dedupeSeriesCacheIfNeeded(db: Connection) throws {
        guard !hasAppliedMigration(migrationNameDedupeSeriesCache, db: db) else { return }
        try db.transaction {
            try db.run("""
                DELETE FROM series_cache
                WHERE ao3_series_id IS NULL
                  AND calibre_id IN (
                      SELECT calibre_id FROM series_cache WHERE ao3_series_id IS NOT NULL
                  )
                """)
            try db.run("PRAGMA user_version = \(dedupeSeriesCacheMigrationVersion)")
            try markMigrationApplied(migrationNameDedupeSeriesCache, db: db)
        }
    }

    /// One-time schema migration: `ao3_author_username` was a dead scalar
    /// column — the old extractor never populated it (always nil in every
    /// extracted record). `AO3MetadataRecord.authors` replaces it with a
    /// structured, potentially multi-author array stored as `authors_json`
    /// (added additively in `createAO3Metadata` above, mirroring
    /// `fandoms_json`/`relationships_json`). This drops the old column,
    /// since nothing depends on it holding real data today. Gated on
    /// `schema_migrations` per Invariant 11 so the DROP COLUMN runs exactly
    /// once and a crash mid-migration can't strand the table.
    private static let migrationNameDropAO3AuthorUsername = "2025_drop_ao3_author_username"

    private static func dropAO3AuthorUsernameIfNeeded(db: Connection) throws {
        guard !hasAppliedMigration(migrationNameDropAO3AuthorUsername, db: db) else { return }
        try db.transaction {
            if try columnExists("ao3_metadata", "ao3_author_username", db: db) {
                try db.run("ALTER TABLE ao3_metadata DROP COLUMN ao3_author_username")
            }
            try markMigrationApplied(migrationNameDropAO3AuthorUsername, db: db)
        }
    }

    private static func createAO3TagSynonyms(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS canonical_tags (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            tag_type TEXT NOT NULL,
            last_fetched TEXT
        );

        CREATE TABLE IF NOT EXISTS tag_synonyms (
            synonym TEXT NOT NULL,
            canonical_id INTEGER NOT NULL REFERENCES canonical_tags(id) ON DELETE CASCADE,
            PRIMARY KEY (synonym)
        );

        CREATE INDEX IF NOT EXISTS idx_tag_synonyms_canonical
            ON tag_synonyms(canonical_id);

        CREATE TABLE IF NOT EXISTS tag_parent_links (
            child_id INTEGER NOT NULL REFERENCES canonical_tags(id),
            parent_id INTEGER NOT NULL REFERENCES canonical_tags(id),
            PRIMARY KEY (child_id, parent_id)
        );

        CREATE INDEX IF NOT EXISTS idx_tag_parent_links_child
            ON tag_parent_links(child_id);

        CREATE INDEX IF NOT EXISTS idx_tag_parent_links_parent
            ON tag_parent_links(parent_id);

        CREATE TABLE IF NOT EXISTS tag_subtag_sections (
            child_id INTEGER NOT NULL REFERENCES canonical_tags(id),
            parent_id INTEGER NOT NULL REFERENCES canonical_tags(id),
            section TEXT,
            PRIMARY KEY (child_id, parent_id)
        );
        """)
    }

    private var tagSeedLoadedKey: String {
        "tagSeedLoaded_\(libraryHash)"
    }

    func importConfiguredAO3TagSeedsIfNeeded() throws {
        guard let seedURL = AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled() else { return }
        let sourceIdentity = try AO3TagSeedDatabaseConfig.identity(for: seedURL)
        let previousIdentity = UserDefaults.standard.string(forKey: tagSeedLoadedKey)
        guard previousIdentity != sourceIdentity else { return }
        if let previousIdentity, previousIdentity != sourceIdentity {
            try clearAO3TagSynonymCache()
        }
        try AO3TagSeedDatabaseConfig.validate(url: seedURL)

        var seedComponents = URLComponents(url: seedURL, resolvingAgainstBaseURL: false)
        seedComponents?.queryItems = [
            URLQueryItem(name: "mode", value: "ro"),
            URLQueryItem(name: "immutable", value: "1")
        ]
        let seedURI = seedComponents?.url?.absoluteString ?? seedURL.absoluteString
        let escapedURI = seedURI.replacingOccurrences(of: "'", with: "''")
        try db.transaction(.deferred) {
            try db.execute("ATTACH DATABASE '\(escapedURI)' AS ao3_seed")
            defer { try? db.execute("DETACH DATABASE ao3_seed") }

            try db.execute("""
            INSERT OR IGNORE INTO canonical_tags(name, tag_type, last_fetched)
            SELECT name, tag_type, NULL
            FROM ao3_seed.canonical_tags;

            INSERT OR IGNORE INTO tag_synonyms(synonym, canonical_id)
            SELECT s.synonym, c.id
            FROM ao3_seed.tag_synonyms s
            JOIN ao3_seed.canonical_tags sc ON sc.id = s.canonical_id
            JOIN canonical_tags c ON c.name = sc.name;

            INSERT OR IGNORE INTO tag_parent_links(child_id, parent_id)
            SELECT child.id, parent.id
            FROM ao3_seed.tag_parent_links l
            JOIN ao3_seed.canonical_tags seed_child ON seed_child.id = l.child_id
            JOIN ao3_seed.canonical_tags seed_parent ON seed_parent.id = l.parent_id
            JOIN canonical_tags child ON child.name = seed_child.name
            JOIN canonical_tags parent ON parent.name = seed_parent.name;

            INSERT OR IGNORE INTO tag_subtag_sections(child_id, parent_id, section)
            SELECT child.id, parent.id, s.section
            FROM ao3_seed.tag_subtag_sections s
            JOIN ao3_seed.canonical_tags seed_child ON seed_child.id = s.child_id
            JOIN ao3_seed.canonical_tags seed_parent ON seed_parent.id = s.parent_id
            JOIN canonical_tags child ON child.name = seed_child.name
            JOIN canonical_tags parent ON parent.name = seed_parent.name;
            """)
        }
        UserDefaults.standard.set(sourceIdentity, forKey: tagSeedLoadedKey)
    }

    func clearAO3TagSynonymCache() throws {
        try db.transaction(.deferred) {
            try db.execute("""
            DELETE FROM tag_subtag_sections;
            DELETE FROM tag_parent_links;
            DELETE FROM tag_synonyms;
            DELETE FROM canonical_tags;
            """)
        }
        UserDefaults.standard.removeObject(forKey: tagSeedLoadedKey)
    }

    func clearAO3TagSynonymCacheAndReloadSeeds() throws {
        try clearAO3TagSynonymCache()
        try importConfiguredAO3TagSeedsIfNeeded()
    }

    func ao3TagSeedCounts() throws -> AO3TagSeedDatabaseConfig.Counts {
        func count(_ table: String) throws -> Int {
            let value = try db.scalar("SELECT COUNT(*) FROM \(table)")
            if let int64 = value as? Int64 { return Int(int64) }
            if let int = value as? Int { return int }
            return 0
        }
        return AO3TagSeedDatabaseConfig.Counts(
            canonicalTags: try count("canonical_tags"),
            synonyms: try count("tag_synonyms"),
            hierarchyEdges: try count("tag_parent_links"),
            subtagSections: try count("tag_subtag_sections")
        )
    }

    func run(_ sql: String, _ bindings: [Binding?] = []) throws {
        try db.run(sql, bindings)
    }

    func prepare(_ sql: String, _ bindings: [Binding?] = []) throws -> [[Binding?]] {
        try readDB.prepare(sql, bindings).map { $0 }
    }

    func scalar(_ sql: String, _ bindings: [Binding?] = []) throws -> Binding? {
        try readDB.scalar(sql, bindings)
    }

    func transaction(_ block: () throws -> Void) throws {
        try db.transaction(.deferred, block: block)
    }

    /// Variant that passes `self` into the block so callers (e.g. CollectionStore)
    /// can issue writes inside a transaction without extra actor hops.
    /// The closure is isolated to `self` so it may call actor-isolated methods directly.
    func transaction(_ block: (isolated AmbrosiaMetaDB) throws -> Void) throws {
        try db.transaction(.deferred) { try block(self) }
    }

    func annotations(for calibreID: Int, spineIndex: Int? = nil) throws -> [Annotation] {
        let iso = ISO8601DateFormatter()
        let sql: String
        let args: [Binding?]
        if let spineIndex {
            sql = """
            SELECT id, spine_index, start_char, end_char, selected_text, note, color_hex, created_at
            FROM annotations
            WHERE calibre_id = ? AND spine_index = ?
            ORDER BY start_char
            """
            args = [calibreID, spineIndex]
        } else {
            sql = """
            SELECT id, spine_index, start_char, end_char, selected_text, note, color_hex, created_at
            FROM annotations
            WHERE calibre_id = ?
            ORDER BY spine_index, start_char
            """
            args = [calibreID]
        }

        return try prepare(sql, args).compactMap { row in
            guard let idString = row[safe: 0] as? String,
                  let id = UUID(uuidString: idString),
                  let spine = row.int(at: 1),
                  let start = row.int(at: 2),
                  let end = row.int(at: 3),
                  let selectedText = row[safe: 4] as? String,
                  let created = row[safe: 7] as? String else { return nil }
            return Annotation(
                id: id,
                spineIndex: spine,
                startChar: start,
                endChar: end,
                selectedText: selectedText,
                note: row[safe: 5] as? String,
                colorHex: (row[safe: 6] as? String) ?? "#FFD60A",
                createdDate: iso.date(from: created) ?? Date()
            )
        }
    }

    func insertAnnotation(_ annotation: Annotation, calibreID: Int) throws {
        try run(
            """
            INSERT OR REPLACE INTO annotations
            (id, calibre_id, spine_index, start_char, end_char, selected_text, note, color_hex, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                annotation.id.uuidString,
                calibreID,
                annotation.spineIndex,
                annotation.startChar,
                annotation.endChar,
                annotation.selectedText,
                annotation.note,
                annotation.colorHex,
                ISO8601DateFormatter().string(from: annotation.createdDate),
            ]
        )
        try run(
            "INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
            [SystemCollectionID.hasAnnotations, calibreID, ISO8601DateFormatter().string(from: Date())]
        )
    }

    func deleteAnnotation(id: UUID, calibreID: Int) throws {
        try run("DELETE FROM annotations WHERE id = ?", [id.uuidString])
        let count = try scalar("SELECT COUNT(*) FROM annotations WHERE calibre_id = ?", [calibreID])
        let remaining = (count as? Int64).map(Int.init) ?? (count as? Int) ?? 0
        if remaining == 0 {
            try run(
                "DELETE FROM collection_members WHERE collection_id = ? AND calibre_id = ?",
                [SystemCollectionID.hasAnnotations, calibreID]
            )
        }
    }

    // MARK: - Reading session write path (incomplete — no callers)
    //
    // These three methods manage `reading_history` and `book_opens` row lifecycle.
    // The schema and query logic are complete. The call sites in `ReaderWindowController`
    // have not been wired up. See "Not Yet Built" in ambrosia_architecture.md.
    // Do not delete; do not treat as live code.

    func closeZombieReadingSessions(calibreID: Int, endedAt: Date = Date()) throws {
        let end = ISO8601DateFormatter().string(from: endedAt)
        try run(
            """
            UPDATE reading_history
            SET session_end = ?
            WHERE calibre_id = ? AND session_end = session_start
            """,
            [end, calibreID]
        )
    }

    func startReadingSession(calibreID: Int, percentStart: Double?, startedAt: Date = Date()) throws -> Int64 {
        let now = ISO8601DateFormatter().string(from: startedAt)
        try transaction {
            try run("INSERT INTO book_opens (calibre_id, opened_at) VALUES (?, ?)", [calibreID, now])
            try run(
                """
                INSERT INTO reading_history
                (calibre_id, session_start, session_end, words_read, percent_start, percent_end)
                VALUES (?, ?, ?, NULL, ?, ?)
                """,
                [calibreID, now, now, percentStart, percentStart]
            )
        }
        let value = try scalar("SELECT last_insert_rowid()")
        if let int64 = value as? Int64 { return int64 }
        if let int = value as? Int { return Int64(int) }
        return 0
    }

    func updateReadingSession(id: Int64, calibreID: Int, percentEnd: Double?, endedAt: Date = Date()) throws {
        let end = ISO8601DateFormatter().string(from: endedAt)
        var wordsRead: Int?
        if let percentEnd {
            let row = try prepare(
                """
                SELECT rh.percent_start, am.word_count
                FROM reading_history rh
                LEFT JOIN ao3_metadata am ON am.calibre_id = rh.calibre_id
                WHERE rh.id = ? AND rh.calibre_id = ?
                """,
                [id, calibreID]
            ).first
            let percentStart = row?.double(at: 0) ?? percentEnd
            if let wordCount = row?.int(at: 1), wordCount > 0 {
                wordsRead = max(0, Int((percentEnd - percentStart) * Double(wordCount)))
            }
        }

        try run(
            """
            UPDATE reading_history
            SET session_end = ?, percent_end = ?, words_read = ?
            WHERE id = ? AND calibre_id = ?
            """,
            [end, percentEnd, wordsRead, id, calibreID]
        )
    }

    func completedBooksCount(start: Date, end: Date, threshold: Double = 0.98) throws -> Int {
        let iso = ISO8601DateFormatter()
        let startString = iso.string(from: start)
        let endString = iso.string(from: end)
        let count = try scalar(
            """
            SELECT COUNT(DISTINCT calibre_id)
            FROM reading_history
            WHERE session_end >= ?
              AND session_end <= ?
              AND percent_end >= ?
            """,
            [startString, endString, threshold]
        )
        if let value = count as? Int64 { return Int(value) }
        if let value = count as? Int { return value }
        return 0
    }

    func recentReadingHistory(limit: Int = 200) throws -> [ReadingHistoryEntry] {
        let rows = try prepare(
            """
            SELECT rh.id, rh.calibre_id, rh.session_start, rh.session_end,
                   rh.words_read, rh.percent_start, rh.percent_end,
                   am.fandoms_json, am.category_json
            FROM reading_history rh
            LEFT JOIN ao3_metadata am ON am.calibre_id = rh.calibre_id
            ORDER BY rh.session_start DESC, rh.id DESC
            LIMIT ?
            """,
            [limit]
        )
        let iso = ISO8601DateFormatter()
        let decoder = JSONDecoder()
        func decodeStrings(_ value: Binding?) -> [String] {
            guard let string = value as? String,
                  let data = string.data(using: .utf8) else { return [] }
            return (try? decoder.decode([String].self, from: data)) ?? []
        }
        return rows.compactMap { row in
            guard let id = row.int64(at: 0),
                  let calibreID = row.int(at: 1),
                  let startString = row[safe: 2] as? String,
                  let endString = row[safe: 3] as? String,
                  let start = iso.date(from: startString),
                  let end = iso.date(from: endString) else { return nil }
            return ReadingHistoryEntry(
                id: id,
                calibreID: calibreID,
                sessionStart: start,
                sessionEnd: end,
                wordsRead: row.int(at: 4),
                percentStart: row.double(at: 5),
                percentEnd: row.double(at: 6),
                fandoms: decodeStrings(row.binding(at: 7)),
                categories: decodeStrings(row.binding(at: 8))
            )
        }
    }

    // MARK: - Activity feed queries

    /// Returns up to `limit` annotations across all books, newest first.
    /// Uses readDB (read-only connection) — no contention with write actor.
    func recentAnnotations(limit: Int = 250) throws -> [(annotation: Annotation, calibreID: Int)] {
        let iso = ISO8601DateFormatter()
        let rows = try prepare(
            """
            SELECT id, calibre_id, spine_index, start_char, end_char,
                   selected_text, note, color_hex, created_at
            FROM annotations
            ORDER BY created_at DESC, rowid DESC
            LIMIT ?
            """,
            [limit as Binding?]
        )
        return rows.compactMap { row in
            guard let idString  = row[safe: 0] as? String,
                  let id        = UUID(uuidString: idString),
                  let calibreID = row.int(at: 1),
                  let spine     = row.int(at: 2),
                  let start     = row.int(at: 3),
                  let end       = row.int(at: 4),
                  let text      = row[safe: 5] as? String,
                  let dateStr   = row[safe: 8] as? String,
                  let created   = iso.date(from: dateStr)
            else { return nil }

            var annotation = Annotation(
                spineIndex:   spine,
                startChar:    start,
                endChar:      end,
                selectedText: text,
                colorHex:     (row[safe: 7] as? String) ?? "#FFD60A"
            )
            annotation.id          = id
            annotation.note        = row[safe: 6] as? String
            annotation.createdDate = created
            return (annotation, calibreID)
        }
    }

    /// Returns up to `limit` collection membership events, newest first.
    /// Uses the existing `added_at` column on `collection_members`.
    /// Excludes automated collections whose membership is app-managed, not user-driven:
    ///   • "Series or Merged"  (00000000-…-0007)
    ///   • "In Progress"       (00000000-…-0005) — duplicates reading session data
    func recentCollectionActivity(limit: Int = 250) throws -> [CollectionActivityEntry] {
        let iso = ISO8601DateFormatter()
        let rows = try prepare(
            """
            SELECT cm.collection_id, c.name, c.kind, c.is_system, cm.calibre_id, cm.added_at
            FROM collection_members cm
            JOIN collections c ON c.id = cm.collection_id
            WHERE cm.collection_id NOT IN (
                '00000000-0000-0000-0000-000000000007',
                '00000000-0000-0000-0000-000000000005'
            )
            ORDER BY cm.added_at DESC, cm.rowid DESC
            LIMIT ?
            """,
            [limit as Binding?]
        )
        return rows.compactMap { row in
            guard let collectionID = row[safe: 0] as? String,
                  let name         = row[safe: 1] as? String,
                  let kind         = row[safe: 2] as? String,
                  let calibreID    = row.int(at: 4),
                  let dateStr      = row[safe: 5] as? String,
                  let date         = iso.date(from: dateStr)
            else { return nil }

            let isSystem: Bool
            if let v64 = row[safe: 3] as? Int64 { isSystem = v64 != 0 }
            else if let v = row[safe: 3] as? Int { isSystem = v != 0 }
            else { isSystem = false }

            return CollectionActivityEntry(
                id:             "\(collectionID)-\(calibreID)",
                collectionID:   collectionID,
                collectionName: name,
                kind:           kind,
                calibreID:      calibreID,
                addedAt:        date,
                isSystem:       isSystem
            )
        }
    }

    func existingAO3MetadataIDs() throws -> Set<Int> {
        let rows = try prepare("SELECT calibre_id FROM ao3_metadata")
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    func attemptedAO3ExtractionIDs() throws -> Set<Int> {
        let rows = try prepare("SELECT calibre_id FROM ao3_extraction_diagnostics")
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    func ao3CompletionStatusIDs(_ status: AO3CompletionStatus) throws -> Set<Int> {
        let predicate: String
        switch status {
        case .complete:
            predicate = """
            chapter_current IS NOT NULL
              AND chapter_total IS NOT NULL
              AND chapter_current = chapter_total
            """
        case .workInProgress:
            predicate = """
            chapter_current IS NOT NULL
              AND (chapter_total IS NULL OR chapter_current != chapter_total)
            """
        }
        let rows = try prepare("SELECT calibre_id FROM ao3_metadata WHERE \(predicate)")
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    func ao3ExtractionDiagnostics(for calibreIDs: [Int]) throws -> [Int: AO3ExtractionDiagnostic] {
        guard !calibreIDs.isEmpty else { return [:] }
        let missing = calibreIDs.filter { ao3DiagnosticsCache[$0] == nil }
        if !missing.isEmpty {
            let fetched = try fetchAO3ExtractionDiagnostics(for: missing)
            for (id, diagnostic) in fetched { ao3DiagnosticsCache[id] = diagnostic }
        }
        var result: [Int: AO3ExtractionDiagnostic] = [:]
        for id in calibreIDs {
            if let cached = ao3DiagnosticsCache[id] { result[id] = cached }
        }
        return result
    }

    private func fetchAO3ExtractionDiagnostics(for calibreIDs: [Int]) throws -> [Int: AO3ExtractionDiagnostic] {
        guard !calibreIDs.isEmpty else { return [:] }
        let placeholders = calibreIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT calibre_id, status, reason, epub_path, epub_filename, spine_items_checked, attempted_at
        FROM ao3_extraction_diagnostics
        WHERE calibre_id IN (\(placeholders))
        """
        var result: [Int: AO3ExtractionDiagnostic] = [:]
        for row in try prepare(sql, calibreIDs.map { $0 as Binding? }) {
            guard let id = row.int(at: 0),
                  let status = row[safe: 1] as? String,
                  let reason = row[safe: 2] as? String,
                  let attemptedAt = row[safe: 6] as? String else { continue }
            result[id] = AO3ExtractionDiagnostic(
                calibreID: id,
                status: status,
                reason: reason,
                epubPath: row[safe: 3] as? String,
                epubFilename: row[safe: 4] as? String,
                spineItemsChecked: row.int(at: 5),
                attemptedAt: attemptedAt
            )
        }
        return result
    }

    func ao3Metadata(for calibreIDs: [Int]) throws -> [Int: AO3MetadataRecord] {
        guard !calibreIDs.isEmpty else { return [:] }
        let missing = calibreIDs.filter { ao3MetadataCache[$0] == nil }
        if !missing.isEmpty {
            let fetched = try fetchAO3Metadata(for: missing)
            for (id, record) in fetched { ao3MetadataCache[id] = record }
        }
        var result: [Int: AO3MetadataRecord] = [:]
        for id in calibreIDs {
            if let cached = ao3MetadataCache[id] { result[id] = cached }
        }
        return result
    }

    private func fetchAO3Metadata(for calibreIDs: [Int]) throws -> [Int: AO3MetadataRecord] {
        guard !calibreIDs.isEmpty else { return [:] }
        let placeholders = calibreIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT calibre_id, story_url, ao3_work_id, authors_json, kudos_count, word_count,
               chapter_current, chapter_total, is_complete, language, published_date, updated_date,
               fandoms_json, relationships_json, characters_json, additional_tags_json, category_json,
               ao3_collections_json, series_json, rating, warnings_json, extracted_at
        FROM ao3_metadata
        WHERE calibre_id IN (\(placeholders))
        """
        let decoder = JSONDecoder()
        func decodeStrings(_ value: Binding?) -> [String] {
            guard let string = value as? String, let data = string.data(using: .utf8) else { return [] }
            return (try? decoder.decode([String].self, from: data)) ?? []
        }
        func decodeSeries(_ value: Binding?) -> [AO3MetadataRecord.SeriesEntry] {
            guard let string = value as? String, let data = string.data(using: .utf8) else { return [] }
            return (try? decoder.decode([AO3MetadataRecord.SeriesEntry].self, from: data)) ?? []
        }
        func decodeAuthors(_ value: Binding?) -> [AO3AuthorEntry] {
            guard let string = value as? String, let data = string.data(using: .utf8) else { return [] }
            return (try? decoder.decode([AO3AuthorEntry].self, from: data)) ?? []
        }

        var result: [Int: AO3MetadataRecord] = [:]
        for row in try prepare(sql, calibreIDs.map { $0 as Binding? }) {
            guard let id = row.int(at: 0),
                  let extractedAt = row[safe: 21] as? String else { continue }
            result[id] = AO3MetadataRecord(
                storyURL: row[safe: 1] as? String,
                workID: row[safe: 2] as? String,
                authors: decodeAuthors(row.binding(at: 3)),
                kudosCount: row.int(at: 4),
                wordCount: row.int(at: 5),
                chapterCurrent: row.int(at: 6),
                chapterTotal: row.int(at: 7),
                isComplete: (row.int(at: 8) ?? 0) != 0,
                language: row[safe: 9] as? String,
                publishedDate: row[safe: 10] as? String,
                updatedDate: row[safe: 11] as? String,
                fandoms: decodeStrings(row.binding(at: 12)),
                relationships: decodeStrings(row.binding(at: 13)),
                characters: decodeStrings(row.binding(at: 14)),
                additionalTags: decodeStrings(row.binding(at: 15)),
                categories: decodeStrings(row.binding(at: 16)),
                ao3Collections: decodeStrings(row.binding(at: 17)),
                series: decodeSeries(row.binding(at: 18)),
                rating: row[safe: 19] as? String,
                warnings: decodeStrings(row.binding(at: 20)),
                extractedAt: extractedAt
            )
        }
        return result
    }

    func insert(_ metadata: AO3MetadataRecord, calibreID: Int) throws {
        try transaction {
            try writeAO3Metadata(metadata, calibreID: calibreID)
        }
        invalidateAO3MetadataCaches(for: calibreID)
    }

    /// Writes one book's `ao3_metadata` row and its `series_cache` rows
    /// without opening its own transaction. `insert(_:calibreID:)` wraps this
    /// in a transaction for standalone callers; `insertBatch` calls it
    /// directly inside its own single transaction. Previously
    /// `insert(_:calibreID:)` always opened `transaction { }` itself, so
    /// `insertBatch` was nesting one transaction per row inside its outer
    /// transaction — if any row in a batch failed, the whole nested/outer
    /// transaction could roll back and, combined with `flushBatch`'s `try?`
    /// on the call site, silently drop that batch's results with no retry.
    private func writeAO3Metadata(_ metadata: AO3MetadataRecord, calibreID: Int) throws {
        let encoder = JSONEncoder()
        func json(_ values: [String]) -> String {
            guard let data = try? encoder.encode(values) else { return "[]" }
            return String(data: data, encoding: .utf8) ?? "[]"
        }
        let seriesData = (try? encoder.encode(metadata.series)) ?? Data("[]".utf8)
        let seriesJSON = String(data: seriesData, encoding: .utf8) ?? "[]"
        let authorsData = (try? encoder.encode(metadata.authors)) ?? Data("[]".utf8)
        let authorsJSON = String(data: authorsData, encoding: .utf8) ?? "[]"
        let authorNames = metadata.authors.map { $0.pseud ?? $0.username }
        let authorNamesJSON = json(authorNames)

        try run(
            """
            INSERT OR REPLACE INTO ao3_metadata
            (calibre_id, story_url, ao3_work_id, authors_json, author_names_json, kudos_count, word_count,
             chapter_current, chapter_total, is_complete, language, published_date, updated_date,
             fandoms_json, relationships_json, characters_json, additional_tags_json, category_json,
             ao3_collections_json, series_json, rating, warnings_json, extracted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                calibreID,
                metadata.storyURL,
                metadata.workID,
                authorsJSON,
                authorNamesJSON,
                metadata.kudosCount,
                metadata.wordCount,
                metadata.chapterCurrent,
                metadata.chapterTotal,
                metadata.isComplete ? 1 : 0,
                metadata.language,
                metadata.publishedDate,
                metadata.updatedDate,
                json(metadata.fandoms),
                json(metadata.relationships),
                json(metadata.characters),
                json(metadata.additionalTags),
                json(metadata.categories),
                json(metadata.ao3Collections),
                seriesJSON,
                metadata.rating,
                json(metadata.warnings),
                metadata.extractedAt,
            ]
        )

        try run("DELETE FROM series_cache WHERE calibre_id = ?", [calibreID])
        for entry in metadata.series where !entry.name.isEmpty {
            try run(
                """
                INSERT OR REPLACE INTO series_cache
                (calibre_id, series_name, series_index, ao3_series_id, is_anthology)
                VALUES (?, ?, ?, ?, 0)
                """,
                [calibreID, entry.name, entry.index, entry.ao3ID]
            )
        }
    }

    private func invalidateAO3MetadataCaches(for calibreID: Int) {
        ao3MetadataCache[calibreID] = nil
        // series_cache rows for this calibreID were replaced wholesale above
        // (by-key and singleton-warning entries derived from them may now be
        // stale for series this book participates in), so drop all series
        // caches rather than try to reconstruct exactly which keys changed.
        seriesEntriesCache[calibreID] = nil
        seriesEntriesByKeyCache.removeAll()
        singletonWarningsCache.removeAll()
    }

    func insert(_ diagnostic: AO3ExtractionDiagnostic) throws {
        try writeAO3Diagnostic(diagnostic)
        ao3DiagnosticsCache[diagnostic.calibreID] = nil
    }

    /// Writes one `ao3_extraction_diagnostics` row without opening its own
    /// transaction — see `writeAO3Metadata` for why this matters inside
    /// `insertBatch`.
    private func writeAO3Diagnostic(_ diagnostic: AO3ExtractionDiagnostic) throws {
        try run(
            """
            INSERT OR REPLACE INTO ao3_extraction_diagnostics
            (calibre_id, status, reason, epub_path, epub_filename, spine_items_checked, attempted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                diagnostic.calibreID,
                diagnostic.status,
                diagnostic.reason,
                diagnostic.epubPath,
                diagnostic.epubFilename,
                diagnostic.spineItemsChecked,
                diagnostic.attemptedAt,
            ]
        )
    }

    /// Flush a batch of extraction results in a single transaction.
    ///
    /// Called from the AO3 extraction loop every N books. Grouping writes into one
    /// transaction means the actor is only acquired once per batch rather than once
    /// per book, so read queries (e.g. collection membership for filter results) can
    /// cut in between batches instead of waiting for thousands of individual inserts.
    ///
    /// Uses the non-transactional `writeAO3Metadata`/`writeAO3Diagnostic` helpers
    /// rather than `insert(_:calibreID:)`/`insert(_:)` — those each open their own
    /// `transaction { }`, which used to nest a transaction per row inside this
    /// function's outer transaction.
    func insertBatch(_ records: [(AO3MetadataRecord, Int)], diagnostics: [AO3ExtractionDiagnostic]) throws {
        try transaction {
            for (metadata, calibreID) in records {
                try writeAO3Metadata(metadata, calibreID: calibreID)
            }
            for diagnostic in diagnostics {
                try writeAO3Diagnostic(diagnostic)
            }
        }
        for (_, calibreID) in records {
            invalidateAO3MetadataCaches(for: calibreID)
        }
        for diagnostic in diagnostics {
            ao3DiagnosticsCache[diagnostic.calibreID] = nil
        }
    }

    func clearAO3Metadata() throws {
        try transaction {
            try run("DELETE FROM ao3_metadata")
            try run("DELETE FROM ao3_extraction_diagnostics")
            try run("DELETE FROM series_cache")
        }
        ao3MetadataCache.removeAll()
        ao3DiagnosticsCache.removeAll()
        seriesEntriesCache.removeAll()
        seriesEntriesByKeyCache.removeAll()
        singletonWarningsCache.removeAll()
    }

    func seriesEntries(for calibreIDs: [Int]) throws -> [SeriesCacheEntry] {
        guard !calibreIDs.isEmpty else { return [] }
        let missing = calibreIDs.filter { seriesEntriesCache[$0] == nil }
        if !missing.isEmpty {
            let fetched = try fetchSeriesEntries(for: missing)
            // Every requested ID gets a cache entry, even ones with no rows,
            // so a book with no series membership isn't re-queried on every call.
            var byID: [Int: [SeriesCacheEntry]] = Dictionary(grouping: fetched, by: { $0.calibreID })
            for id in missing where byID[id] == nil { byID[id] = [] }
            for (id, entries) in byID { seriesEntriesCache[id] = entries }
        }
        var result: [SeriesCacheEntry] = []
        for id in calibreIDs {
            result.append(contentsOf: seriesEntriesCache[id] ?? [])
        }
        return result.sorted { $0.seriesName != $1.seriesName ? $0.seriesName < $1.seriesName : $0.seriesIndex < $1.seriesIndex }
    }

    private func fetchSeriesEntries(for calibreIDs: [Int]) throws -> [SeriesCacheEntry] {
        guard !calibreIDs.isEmpty else { return [] }
        let placeholders = calibreIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT calibre_id, series_name, series_index, ao3_series_id, is_anthology
        FROM series_cache
        WHERE calibre_id IN (\(placeholders))
        ORDER BY series_name, series_index
        """
        return try prepare(sql, calibreIDs.map { $0 as Binding? }).compactMap { row in
            guard let calibreID = row.int(at: 0),
                  let seriesName = row[safe: 1] as? String,
                  let seriesIndex = row.int(at: 2) else { return nil }
            return SeriesCacheEntry(
                calibreID: calibreID,
                seriesName: seriesName,
                seriesIndex: seriesIndex,
                ao3SeriesID: row[safe: 3] as? String,
                isAnthology: (row.int(at: 4) ?? 0) != 0
            )
        }
    }

    func seriesEntries(keys: [String]) throws -> [SeriesCacheEntry] {
        guard !keys.isEmpty else { return [] }
        let missing = keys.filter { seriesEntriesByKeyCache[$0] == nil }
        if !missing.isEmpty {
            let fetched = try fetchSeriesEntries(keys: missing)
            var byKey: [String: [SeriesCacheEntry]] = [:]
            for entry in fetched {
                byKey[entry.seriesKey, default: []].append(entry)
            }
            for key in missing where byKey[key] == nil { byKey[key] = [] }
            for (key, entries) in byKey { seriesEntriesByKeyCache[key] = entries }
        }
        var result: [SeriesCacheEntry] = []
        for key in keys {
            result.append(contentsOf: seriesEntriesByKeyCache[key] ?? [])
        }
        return result.sorted { $0.seriesName != $1.seriesName ? $0.seriesName < $1.seriesName : $0.seriesIndex < $1.seriesIndex }
    }

    private func fetchSeriesEntries(keys: [String]) throws -> [SeriesCacheEntry] {
        guard !keys.isEmpty else { return [] }
        let placeholders = keys.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT calibre_id, series_name, series_index, ao3_series_id, is_anthology
        FROM series_cache
        WHERE COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name) IN (\(placeholders))
        ORDER BY series_name, series_index
        """
        return try prepare(sql, keys.map { $0 as Binding? }).compactMap { row in
            guard let calibreID = row.int(at: 0),
                  let seriesName = row[safe: 1] as? String,
                  let seriesIndex = row.int(at: 2) else { return nil }
            return SeriesCacheEntry(
                calibreID: calibreID,
                seriesName: seriesName,
                seriesIndex: seriesIndex,
                ao3SeriesID: row[safe: 3] as? String,
                isAnthology: (row.int(at: 4) ?? 0) != 0
            )
        }
    }

    /// Expands a raw set of matched calibre IDs to include every member of any
    /// qualifying series touched by the match. "Qualifying" mirrors
    /// `neverLeadsSeriesIDs()`/`leadsAtLeastOneSeriesIDs()`: more than one
    /// member and not anthology-flagged — a match against a singleton or an
    /// anthology series is left as-is.
    ///
    /// This is series-grouping's Phase 1 fix: today a search hit on a
    /// non-leading member (e.g. book 3 of a series) never pulls in the
    /// series leader, so `LibraryVisibilityPolicy`'s existing
    /// `seriesOrMergedIDs` deny-list strips the only matched row and the
    /// whole series silently disappears from grouped results. Unioning the
    /// full member set into the matched IDs before that filter runs means
    /// the leader survives the deny-list check as it would for any other
    /// query, restoring the series row.
    ///
    /// Returns the union of `calibreIDs` and every expansion; never removes
    /// an ID that was passed in, including ones that don't belong to any
    /// series.
    func expandedSeriesMemberIDs(for calibreIDs: [Int]) throws -> Set<Int> {
        guard !calibreIDs.isEmpty else { return [] }
        let placeholders = calibreIDs.map { _ in "?" }.joined(separator: ",")
        let args = calibreIDs.map { $0 as Binding? }
        let sql = """
        WITH keyed AS (
            SELECT calibre_id,
                   COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name) AS series_key,
                   is_anthology
            FROM series_cache
        ),
        matched_keys AS (
            SELECT DISTINCT series_key FROM keyed WHERE calibre_id IN (\(placeholders))
        ),
        qualifying_keys AS (
            SELECT series_key
            FROM keyed
            GROUP BY series_key
            HAVING COUNT(*) > 1 AND MAX(is_anthology) = 0
        )
        SELECT calibre_id
        FROM keyed
        WHERE series_key IN (SELECT series_key FROM matched_keys)
          AND series_key IN (SELECT series_key FROM qualifying_keys)
        """
        let rows = try prepare(sql, args)
        var result = Set(calibreIDs)
        result.formUnion(rows.compactMap { $0.int(at: 0) })
        return result
    }

    /// Maps each of `calibreIDs` that belongs to a qualifying series (>1
    /// member, non-anthology — the same rule as `expandedSeriesMemberIDs`/
    /// `neverLeadsSeriesIDs`) to that series' display name. IDs that don't
    /// belong to a qualifying series are simply absent from the result —
    /// callers fall back to the book's own title as the sort key for those.
    ///
    /// Used by `CalibreLibrary.groupAwareTitleSortedPage` so that, once
    /// series grouping has collapsed a series down to one representative
    /// row, that row sorts alongside other titles by the *series'* name
    /// rather than by the leading book's own (often differently-worded)
    /// title — e.g. so "Some Series, Book 1" sorts under "Some Series" next
    /// to other "S"-titled entries, not wherever "Some Series, Book 1"
    /// alphabetizes on its own.
    func qualifyingSeriesNames(for calibreIDs: [Int]) throws -> [Int: String] {
        guard !calibreIDs.isEmpty else { return [:] }
        let placeholders = calibreIDs.map { _ in "?" }.joined(separator: ",")
        let args = calibreIDs.map { $0 as Binding? }
        let sql = """
        WITH keyed AS (
            SELECT calibre_id, series_name,
                   COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name) AS series_key,
                   is_anthology
            FROM series_cache
        ),
        qualifying_keys AS (
            SELECT series_key
            FROM keyed
            GROUP BY series_key
            HAVING COUNT(*) > 1 AND MAX(is_anthology) = 0
        )
        SELECT calibre_id, series_name
        FROM keyed
        WHERE calibre_id IN (\(placeholders))
          AND series_key IN (SELECT series_key FROM qualifying_keys)
        """
        let rows = try prepare(sql, args)
        var result: [Int: String] = [:]
        for row in rows {
            guard let calibreID = row.int(at: 0), let seriesName = row[safe: 1] as? String else { continue }
            result[calibreID] = seriesName
        }
        return result
    }

    /// Returns every orphaned/non-leading singleton series membership per book, keyed by
    /// calibreID. A book that is a solo, non-leading member of more than one series (e.g.
    /// orphaned #3 of series B and orphaned #5 of series C) gets one entry per series here —
    /// this is intentionally one-to-many. Do not reintroduce a "first match wins" guard;
    /// that was the root cause of silently dropping all but one orphaned membership per book.
    func singletonNonLeadingSeriesEntries(for calibreIDs: [Int]) throws -> [Int: [SingletonSeriesWarning]] {
        guard !calibreIDs.isEmpty else { return [:] }
        let missing = calibreIDs.filter { singletonWarningsCache[$0] == nil }
        if !missing.isEmpty {
            let fetched = try fetchSingletonNonLeadingSeriesEntries(for: missing)
            for id in missing { singletonWarningsCache[id] = fetched[id] ?? [] }
        }
        var result: [Int: [SingletonSeriesWarning]] = [:]
        for id in calibreIDs {
            if let cached = singletonWarningsCache[id], !cached.isEmpty { result[id] = cached }
        }
        return result
    }

    private func fetchSingletonNonLeadingSeriesEntries(for calibreIDs: [Int]) throws -> [Int: [SingletonSeriesWarning]] {
        guard !calibreIDs.isEmpty else { return [:] }
        let placeholders = calibreIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        WITH counted AS (
            SELECT calibre_id, series_name, series_index, is_anthology,
                   COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name) AS series_key,
                   COUNT(*) OVER (
                       PARTITION BY COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name)
                   ) AS series_count,
                   MAX(is_anthology) OVER (
                       PARTITION BY COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name)
                   ) AS anthology
            FROM series_cache
        )
        SELECT calibre_id, series_key, series_name, series_index
        FROM counted
        WHERE calibre_id IN (\(placeholders))
          AND series_count = 1
          AND anthology = 0
          AND is_anthology = 0
          AND series_index > 1
        ORDER BY calibre_id, series_name
        """
        var result: [Int: [SingletonSeriesWarning]] = [:]
        for row in try prepare(sql, calibreIDs.map { $0 as Binding? }) {
            guard let calibreID = row.int(at: 0),
                  let seriesKey = row[safe: 1] as? String,
                  let seriesName = row[safe: 2] as? String,
                  let seriesIndex = row.int(at: 3) else { continue }
            result[calibreID, default: []].append(
                SingletonSeriesWarning(seriesKey: seriesKey, seriesName: seriesName, seriesIndex: seriesIndex, title: "")
            )
        }
        return result
    }

    func placeholders(for seriesKeys: [String]) throws -> [String: [SeriesPlaceholder]] {
        guard !seriesKeys.isEmpty else { return [:] }
        let missing = seriesKeys.filter { placeholdersCache[$0] == nil }
        if !missing.isEmpty {
            let fetched = try fetchPlaceholders(for: missing)
            for key in missing { placeholdersCache[key] = fetched[key] ?? [] }
        }
        var result: [String: [SeriesPlaceholder]] = [:]
        for key in seriesKeys {
            if let cached = placeholdersCache[key], !cached.isEmpty { result[key] = cached }
        }
        return result
    }

    private func fetchPlaceholders(for seriesKeys: [String]) throws -> [String: [SeriesPlaceholder]] {
        guard !seriesKeys.isEmpty else { return [:] }
        let placeholders = seriesKeys.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT series_key, series_name, part_index, note
        FROM series_placeholders
        WHERE series_key IN (\(placeholders))
        ORDER BY series_key, part_index
        """
        var result: [String: [SeriesPlaceholder]] = [:]
        for row in try prepare(sql, seriesKeys.map { $0 as Binding? }) {
            guard let seriesKey = row[safe: 0] as? String,
                  let seriesName = row[safe: 1] as? String,
                  let partIndex = row.int(at: 2) else { continue }
            result[seriesKey, default: []].append(
                SeriesPlaceholder(seriesKey: seriesKey, seriesName: seriesName, partIndex: partIndex, note: row[safe: 3] as? String)
            )
        }
        return result
    }

    func upsertPlaceholder(seriesKey: String, seriesName: String, partIndex: Int, note: String?) throws {
        try run(
            """
            INSERT OR REPLACE INTO series_placeholders (series_name, series_key, part_index, note)
            VALUES (?, ?, ?, ?)
            """,
            [seriesName, seriesKey, partIndex, note]
        )
        placeholdersCache[seriesKey] = nil
    }

    func setAnthology(seriesName: String, isAnthology: Bool) throws {
        try run(
            "UPDATE series_cache SET is_anthology = ? WHERE series_name = ?",
            [isAnthology ? 1 : 0, seriesName]
        )
        // Keyed by series_name, which can span many calibreIDs and series
        // keys — no cheap way to compute exactly which cache entries are
        // affected, so drop all series-derived caches.
        seriesEntriesCache.removeAll()
        seriesEntriesByKeyCache.removeAll()
        singletonWarningsCache.removeAll()
    }

    /// Inserts Calibre-derived series fallback entries, but only for books that
    /// have no `series_cache` row at all yet. `INSERT OR IGNORE` alone is not
    /// sufficient here: the table's primary key is `(calibre_id, series_name)`,
    /// and a Calibre series name is almost never identical to the AO3-extracted
    /// series name for the same book, so a plain `INSERT OR IGNORE` does not
    /// collide with an existing AO3 row — it silently adds a second, spurious
    /// row for that `calibre_id` under an unrelated `series_key`. That row then
    /// pulls the book into whatever (often much larger, cross-author) group
    /// shares that Calibre series name, breaking series-or-merged stripping
    /// and grouped display for every book affected. The `WHERE NOT EXISTS`
    /// guard below ensures Calibre fallback data is only ever written for a
    /// book that has no series_cache membership yet (i.e. AO3 extraction
    /// either hasn't run for it or found no series).
    func insertCalibreSeriesFallback(_ entries: [SeriesCacheEntry]) throws {
        guard !entries.isEmpty else { return }
        try transaction {
            for entry in entries {
                try run(
                    """
                    INSERT INTO series_cache
                    (calibre_id, series_name, series_index, ao3_series_id, is_anthology)
                    SELECT ?, ?, ?, ?, ?
                    WHERE NOT EXISTS (
                        SELECT 1 FROM series_cache WHERE calibre_id = ?
                    )
                    """,
                    [
                        entry.calibreID,
                        entry.seriesName,
                        entry.seriesIndex,
                        entry.ao3SeriesID,
                        entry.isAnthology ? 1 : 0,
                        entry.calibreID,
                    ]
                )
            }
        }
        // WHERE NOT EXISTS means only calibreIDs with no prior series_cache
        // row are actually written; conservatively evict all of them along
        // with the by-key/singleton caches they can affect.
        for entry in entries { seriesEntriesCache[entry.calibreID] = nil }
        seriesEntriesByKeyCache.removeAll()
        singletonWarningsCache.removeAll()
    }

    /// Books that do not lead *any* series they belong to. Used to populate
    /// the "Series or Merged" strip set.
    ///
    /// This must be based on whether a book leads at least one of its series,
    /// not on a single series_key in isolation: a book that leads Series A but
    /// is a non-leading member of Series B needs to remain visible (it anchors
    /// A's grouped row), so it must not appear here just because it is rn > 1
    /// within B's partition. The `leadership` CTE collapses each book down to
    /// its best (lowest) rn across every series it qualifies in before this
    /// function decides whether to strip it.
    func neverLeadsSeriesIDs() throws -> Set<Int> {
        // Diagnostic: raw series_cache composition before collapsing, to catch
        // pathological cases (e.g. a single series_key absorbing most of the library,
        // which would indicate a COALESCE key collision rather than real series data).
        #if DEBUG
        let diagSQL = """
        SELECT COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name) AS series_key,
               COUNT(*) AS member_count
        FROM series_cache
        GROUP BY series_key
        ORDER BY member_count DESC
        LIMIT 5
        """
        let totalRows: Int? = (try? prepare("SELECT COUNT(*) FROM series_cache").first)?.int(at: 0)
        let distinctKeys: Int? = (try? prepare("""
            SELECT COUNT(DISTINCT COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name))
            FROM series_cache
            """).first)?.int(at: 0)
        let topSeries = (try? prepare(diagSQL).map { row -> (String, Int) in
            let key = (row[safe: 0] as? String) ?? "?"
            let count = row.int(at: 1) ?? 0
            return (key, count)
        }) ?? []
        LibraryFilterDebug.log("neverLeadsSeriesIDs.diagnostic", [
            "seriesCacheTotalRows": totalRows ?? -1,
            "distinctSeriesKeys": distinctKeys ?? -1,
            "top5SeriesByMemberCount": topSeries.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
        ])
        #endif
        let sql = """
        \(Self.seriesLeadershipCTE)
        SELECT calibre_id FROM leadership WHERE best_rn > 1
        """
        let rows = try prepare(sql)
        let result = Set(rows.compactMap { $0.int(at: 0) })
        LibraryFilterDebug.log("neverLeadsSeriesIDs.result", [
            "neverLeadsCount": result.count
        ])
        return result
    }

    /// Books that lead at least one of the series they belong to. Used by the
    /// explicit "Series or Merged" filter rule. Complementary to
    /// `neverLeadsSeriesIDs()` by construction — every qualifying book is in
    /// exactly one of the two sets, never both.
    func leadsAtLeastOneSeriesIDs() throws -> Set<Int> {
        let sql = """
        \(Self.seriesLeadershipCTE)
        SELECT calibre_id FROM leadership WHERE best_rn = 1
        """
        let rows = try prepare(sql)
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    /// Shared leadership computation for `neverLeadsSeriesIDs()` and
    /// `leadsAtLeastOneSeriesIDs()`. `ordered` ranks every series_cache row
    /// within its series_key partition (excluding anthology-flagged series and
    /// singleton "series" of one book). `qualifying` keeps only rows that
    /// belong to a real multi-member, non-anthology series. `leadership`
    /// collapses each calibre_id down to its single best (lowest) rn across
    /// every series it qualifies in, so a book's overall leadership status is
    /// decided once, consistently, regardless of how many series it belongs
    /// to. The tie-break (`series_index ASC, calibre_id ASC`) must match the
    /// in-memory sort used when building `SeriesGroup.works` in
    /// `LibraryRootView.rebuildItems` exactly, or the two layers can disagree
    /// about which book is the leader of a given series.
    private static let seriesLeadershipCTE = """
    WITH ordered AS (
        SELECT calibre_id,
               COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name) AS series_key,
               ROW_NUMBER() OVER (
                   PARTITION BY COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name)
                   ORDER BY series_index ASC, calibre_id ASC
               ) AS rn,
               COUNT(*) OVER (
                   PARTITION BY COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name)
               ) AS series_count,
               MAX(is_anthology) OVER (
                   PARTITION BY COALESCE('ao3:' || NULLIF(ao3_series_id, ''), 'calibre:' || series_name)
               ) AS anthology
        FROM series_cache
    ),
    qualifying AS (
        SELECT calibre_id, rn FROM ordered WHERE series_count > 1 AND anthology = 0
    ),
    leadership AS (
        SELECT calibre_id, MIN(rn) AS best_rn FROM qualifying GROUP BY calibre_id
    )
    """

    // MARK: - Bulk AO3 metadata reads
    //
    // These three methods are the sole owners of cross-database AO3 metadata
    // reads (Invariant 10). `CalibreLibrary` previously opened its own
    // read-only `Connection` to this same file to serve these queries; that
    // connection has been removed. `LibrarySession` calls these on the actor
    // and pushes the results into `CalibreLibrary`'s in-memory caches via
    // `updateAO3MetaCaches`.

    func allAO3WordCounts() -> [Int: Int] {
        let sql = "SELECT calibre_id, word_count FROM ao3_metadata WHERE word_count IS NOT NULL"
        guard let rows = try? readDB.prepare(sql).map({ $0 }) else { return [:] }
        var result: [Int: Int] = [:]
        for row in rows {
            if let idBind = row[0] as? Int64, let wc = row[1] as? Int64 {
                result[Int(idBind)] = Int(wc)
            }
        }
        return result
    }

    /// §2.2a: mirrors allAO3WordCounts() exactly, for the kudos fallback cache.
    func allAO3Kudos() -> [Int: Int] {
        let sql = "SELECT calibre_id, kudos_count FROM ao3_metadata WHERE kudos_count IS NOT NULL"
        guard let rows = try? readDB.prepare(sql).map({ $0 }) else { return [:] }
        var result: [Int: Int] = [:]
        for row in rows {
            if let idBind = row[0] as? Int64, let kc = row[1] as? Int64 {
                result[Int(idBind)] = Int(kc)
            }
        }
        return result
    }

    func allAO3Dates() -> [Int: (published: String?, updated: String?)] {
        let sql = "SELECT calibre_id, published_date, updated_date FROM ao3_metadata"
        guard let rows = try? readDB.prepare(sql).map({ $0 }) else { return [:] }
        var result: [Int: (published: String?, updated: String?)] = [:]
        for row in rows {
            guard let id = (row[0] as? Int64).map(Int.init) else { continue }
            result[id] = (row[1] as? String, row[2] as? String)
        }
        return result
    }

    /// Bulk-fetches every calibre_id -> ao3_work_id mapping with a non-null,
    /// non-empty work id. Used by `DuplicateBookDetector` to find calibre
    /// rows that share the same AO3 work (see `LibrarySession.refreshAO3MetaCaches()`).
    func allAO3WorkIDs() -> [Int: String] {
        let sql = """
        SELECT calibre_id, ao3_work_id
        FROM ao3_metadata
        WHERE ao3_work_id IS NOT NULL AND ao3_work_id != ''
        """
        guard let rows = try? readDB.prepare(sql).map({ $0 }) else { return [:] }
        var result: [Int: String] = [:]
        for row in rows {
            guard let id = (row[0] as? Int64).map(Int.init), let workID = row[1] as? String else { continue }
            result[id] = workID
        }
        return result
    }

    // MARK: - AO3-style filter popup facet querying
    //
    // Mirrors AO3's own ES terms-aggregation-over-filtered_query behavior
    // (`WorkQuery#aggregations`): the "(count)" numbers next to each checkbox
    // are scoped to whatever the current search/filter (base toolbar filter
    // plus the popup's own in-progress selections) already narrows to, not
    // the whole library. Uses SQLite's JSON1 `json_each` against
    // `ao3_metadata`'s existing JSON columns — no schema migration.

    /// Top-N tag values by number of matching books, scoped to `ids`.
    func topFacets(for field: AO3FacetField, scopedTo ids: [Int], limit: Int = 10) -> [(name: String, count: Int)] {
        guard !ids.isEmpty else { return [] }
        let idPlaceholders = ids.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT je.value AS name, COUNT(*) AS cnt
            FROM ao3_metadata, json_each(ao3_metadata.\(field.jsonColumn)) AS je
            WHERE ao3_metadata.calibre_id IN (\(idPlaceholders))
            GROUP BY je.value
            ORDER BY cnt DESC
            LIMIT ?
            """
        let bindings: [Binding?] = ids.map { $0 as Binding? } + [limit as Binding?]
        guard let rows = try? readDB.prepare(sql, bindings).map({ $0 }) else { return [] }
        return rows.compactMap { row in
            guard let name = row[0] as? String else { return nil }
            let count = (row[1] as? Int64).map(Int.init) ?? (row[1] as? Int) ?? 0
            return (name, count)
        }
    }

    /// Same as `topFacets(for:scopedTo:limit:)`, but with no `WHERE`/`IN`
    /// clause at all. Used when the scope is genuinely "the whole library" --
    /// no active drawer/search filter AND no popup selection for any field.
    /// The ID-list form can't express that safely once the library exceeds
    /// SQLite's bound-parameter limit (`SQLITE_MAX_VARIABLE_NUMBER`, 999 by
    /// default): binding one placeholder per book silently fails past that
    /// many books (the `try?` above swallows the error and returns `[]`),
    /// so "no filter active" -- the single most common way to open the
    /// AO3-style filter popup -- was the exact case most likely to render
    /// every facet section empty on any real-sized library.
    func topFacetsUnconstrained(for field: AO3FacetField, limit: Int = 10) -> [(name: String, count: Int)] {
        let sql = """
            SELECT je.value AS name, COUNT(*) AS cnt
            FROM ao3_metadata, json_each(ao3_metadata.\(field.jsonColumn)) AS je
            GROUP BY je.value
            ORDER BY cnt DESC
            LIMIT ?
            """
        guard let rows = try? readDB.prepare(sql, [limit as Binding?]).map({ $0 }) else { return [] }
        return rows.compactMap { row in
            guard let name = row[0] as? String else { return nil }
            let count = (row[1] as? Int64).map(Int.init) ?? (row[1] as? Int) ?? 0
            return (name, count)
        }
    }

    /// Rating facet — `rating` is a single TEXT column, so this is a plain
    /// `GROUP BY`, not a `json_each` aggregation.
    func topRatingFacets(scopedTo ids: [Int]) -> [(name: String, count: Int)] {
        guard !ids.isEmpty else { return [] }
        let idPlaceholders = ids.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT rating, COUNT(*) AS cnt
            FROM ao3_metadata
            WHERE calibre_id IN (\(idPlaceholders)) AND rating IS NOT NULL
            GROUP BY rating
            ORDER BY cnt DESC
            """
        let bindings: [Binding?] = ids.map { $0 as Binding? }
        guard let rows = try? readDB.prepare(sql, bindings).map({ $0 }) else { return [] }
        return rows.compactMap { row in
            guard let name = row[0] as? String else { return nil }
            let count = (row[1] as? Int64).map(Int.init) ?? (row[1] as? Int) ?? 0
            return (name, count)
        }
    }

    /// Unconstrained counterpart to `topRatingFacets(scopedTo:)` -- see
    /// `topFacetsUnconstrained(for:limit:)` for why this needs to exist as a
    /// separate query rather than an ID-list form called with "all IDs."
    func topRatingFacetsUnconstrained() -> [(name: String, count: Int)] {
        let sql = """
            SELECT rating, COUNT(*) AS cnt
            FROM ao3_metadata
            WHERE rating IS NOT NULL
            GROUP BY rating
            ORDER BY cnt DESC
            """
        guard let rows = try? readDB.prepare(sql).map({ $0 }) else { return [] }
        return rows.compactMap { row in
            guard let name = row[0] as? String else { return nil }
            let count = (row[1] as? Int64).map(Int.init) ?? (row[1] as? Int) ?? 0
            return (name, count)
        }
    }

    /// Re-groups raw facet rows by canonical name when the AO3 tag seed
    /// database is enabled, summing counts for names that canonicalize to
    /// the same tag. No-ops (returns input unchanged, re-sorted) when the
    /// seed DB is disabled or unconfigured, matching `canonicalTerm`'s own
    /// guard.
    func canonicalize(_ rawFacets: [(name: String, count: Int)]) -> [(name: String, count: Int)] {
        guard AO3TagSeedDatabaseConfig.shared.isEnabled,
              AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled() != nil else {
            return rawFacets.sorted { $0.count > $1.count }
        }
        var merged: [String: Int] = [:]
        for (name, count) in rawFacets {
            let canonical = canonicalTerm(for: name)
            merged[canonical, default: 0] += count
        }
        return merged.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    func allCrossoverBookIDs() -> Set<Int> {
        let sql = """
        SELECT calibre_id
        FROM ao3_metadata
        WHERE json_array_length(fandoms_json) > 1
        """
        let rows = (try? readDB.prepare(sql).map { $0 }) ?? []
        return Set(rows.compactMap { row in
            if let v = row[0] as? Int64 { return Int(v) }
            return row[0] as? Int
        })
    }

    // MARK: - Tag synonym resolution
    //
    // These replace `AO3TagSearchResolver`, which previously opened an independent
    // `Connection` to this file on every call (Invariant 10). Callers that need
    // synchronous behaviour (e.g. the search-as-you-type WHERE clause) should
    // pre-resolve terms with `await` before building the query.

    /// Returns the canonical tag name for `term` if a synonym mapping exists,
    /// otherwise returns `term` unchanged.
    func canonicalTerm(for term: String) -> String {
        guard AO3TagSeedDatabaseConfig.shared.isEnabled,
              AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled() != nil else { return term }
        let sql = """
            SELECT c.name
            FROM tag_synonyms s
            JOIN canonical_tags c ON c.id = s.canonical_id
            WHERE LOWER(s.synonym) = LOWER(?)
            LIMIT 1
            """
        if let row = (try? readDB.prepare(sql, [term as Binding?]).map { $0 })?.first,
           let canonical = row[0] as? String {
            return canonical
        }
        return term
    }

    /// Returns `term` plus all known synonyms. Returns `[term]` when no mapping exists
    /// or when AO3 tag seeds are disabled.
    func expandedTerms(for term: String) -> [String] {
        guard AO3TagSeedDatabaseConfig.shared.isEnabled,
              AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled() != nil else { return [term] }
        let sql = """
            WITH root(id, name) AS (
                SELECT id, name FROM canonical_tags WHERE LOWER(name) = LOWER(?)
                UNION
                SELECT c.id, c.name
                FROM tag_synonyms s
                JOIN canonical_tags c ON c.id = s.canonical_id
                WHERE LOWER(s.synonym) = LOWER(?)
            )
            SELECT name FROM root
            UNION
            SELECT synonym
            FROM tag_synonyms
            WHERE canonical_id IN (SELECT id FROM root)
            """
        guard let rows = try? readDB.prepare(sql, [term as Binding?, term as Binding?]).map({ $0 }) else {
            return [term]
        }
        var seen = Set<String>()
        var terms: [String] = []
        for row in rows {
            guard let value = row[0] as? String else { continue }
            if seen.insert(value.lowercased()).inserted { terms.append(value) }
        }
        return terms.isEmpty ? [term] : terms
    }

    /// Batched form of `expandedTerms(for:)`. Returns a dictionary keyed by each
    /// input term (lowercase-preserving the original casing as given) mapping to
    /// its expanded term list, using the same root/synonym join shape as the
    /// single-term version but resolved in two queries total instead of one
    /// query per tag. Falls back to `[term]` per-term when no mapping exists or
    /// when AO3 tag seeds are disabled, matching `expandedTerms(for:)`.
    func expandedTermsBatch(for tags: [String]) -> [String: [String]] {
        guard !tags.isEmpty else { return [:] }
        guard AO3TagSeedDatabaseConfig.shared.isEnabled,
              AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled() != nil else {
            return Dictionary(uniqueKeysWithValues: tags.map { ($0, [$0]) })
        }

        let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
        let lowerBindings: [Binding?] = tags.map { $0.lowercased() as Binding? }

        // Step 1: find each input term's root canonical id, either because the
        // term IS a canonical name, or because it's a known synonym of one.
        let rootSQL = """
            SELECT LOWER(name) AS matched_term, id, name
            FROM canonical_tags
            WHERE LOWER(name) IN (\(placeholders))
            UNION ALL
            SELECT LOWER(s.synonym) AS matched_term, c.id, c.name
            FROM tag_synonyms s
            JOIN canonical_tags c ON c.id = s.canonical_id
            WHERE LOWER(s.synonym) IN (\(placeholders))
            """
        guard let rootRows = try? readDB.prepare(rootSQL, lowerBindings + lowerBindings).map({ $0 }) else {
            return Dictionary(uniqueKeysWithValues: tags.map { ($0, [$0]) })
        }

        // matched_term (lowercased input) -> set of root canonical ids
        var rootIDsByMatchedTerm: [String: Set<Int64>] = [:]
        // root canonical id -> canonical name
        var canonicalNameByRootID: [Int64: String] = [:]
        for row in rootRows {
            guard let matchedTerm = row[0] as? String,
                  let rootID = row.int64(at: 1),
                  let canonicalName = row[2] as? String else { continue }
            rootIDsByMatchedTerm[matchedTerm, default: []].insert(rootID)
            canonicalNameByRootID[rootID] = canonicalName
        }

        let allRootIDs = Array(Set(canonicalNameByRootID.keys))
        var synonymsByRootID: [Int64: [String]] = [:]
        if !allRootIDs.isEmpty {
            let idPlaceholders = allRootIDs.map { _ in "?" }.joined(separator: ", ")
            let synonymSQL = """
                SELECT canonical_id, synonym
                FROM tag_synonyms
                WHERE canonical_id IN (\(idPlaceholders))
                """
            let idBindings: [Binding?] = allRootIDs.map { $0 as Binding? }
            if let synonymRows = try? readDB.prepare(synonymSQL, idBindings).map({ $0 }) {
                for row in synonymRows {
                    guard let rootID = row.int64(at: 0), let synonym = row[1] as? String else { continue }
                    synonymsByRootID[rootID, default: []].append(synonym)
                }
            }
        }

        var result: [String: [String]] = [:]
        for tag in tags {
            let matchedTerm = tag.lowercased()
            guard let rootIDs = rootIDsByMatchedTerm[matchedTerm], !rootIDs.isEmpty else {
                result[tag] = [tag]
                continue
            }
            var seen = Set<String>()
            var terms: [String] = []
            for rootID in rootIDs {
                if let name = canonicalNameByRootID[rootID], seen.insert(name.lowercased()).inserted {
                    terms.append(name)
                }
                for synonym in synonymsByRootID[rootID] ?? [] {
                    if seen.insert(synonym.lowercased()).inserted { terms.append(synonym) }
                }
            }
            result[tag] = terms.isEmpty ? [tag] : terms
        }
        return result
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Array where Element == Binding? {
    func int(at index: Int) -> Int? {
        if let value = self[safe: index] as? Int64 { return Int(value) }
        return self[safe: index] as? Int
    }

    func int64(at index: Int) -> Int64? {
        if let value = self[safe: index] as? Int64 { return value }
        if let value = self[safe: index] as? Int { return Int64(value) }
        return nil
    }

    func double(at index: Int) -> Double? {
        if let value = self[safe: index] as? Double { return value }
        if let value = self[safe: index] as? Int64 { return Double(value) }
        if let value = self[safe: index] as? Int { return Double(value) }
        return nil
    }

    func binding(at index: Int) -> Binding? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
