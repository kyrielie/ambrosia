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
    // ao3_extraction_diagnostics, or series_cache must
    // evict the corresponding entries below.
    private var ao3MetadataCache: [Int: AO3MetadataRecord] = [:]

    /// Incremented every time `book_tags` is rewritten for a book. `writeBookTags`
    /// is the only writer of that table. Part of the filter-result and rule-match
    /// cache keys, so cached tag results do not survive an extraction pass that
    /// changed the tags they were computed from.
    private(set) var bookTagsRevision: Int = 0
    private var lastSyncedTagCanonicalRevision: Int = -1
    private var ao3DiagnosticsCache: [Int: AO3ExtractionDiagnostic] = [:]
    private var seriesEntriesCache: [Int: [SeriesCacheEntry]] = [:]
    private var seriesEntriesByKeyCache: [String: [SeriesCacheEntry]] = [:]
    private var singletonWarningsCache: [Int: [SingletonSeriesWarning]] = [:]
    private var hasSeriesFlagsCache: Bool?
    /// §7.3 (Phase 6): no reader caches book_index rows yet (§7.4 — the table
    /// isn't wired into any filter/sort/UI surface in this phase), but this
    /// exists now and is invalidated on every write so a future reader can
    /// adopt the same pattern the other per-book caches above use, without a
    /// second migration to add cache invalidation retroactively.
    private var bookIndexCache: [Int: BookIndexRecord] = [:]
    private var bookStateCache: [Int: BookState] = [:]

    init(libraryURL: URL) throws {
        self.libraryHash = Ambrosia.libraryHash(for: libraryURL)
        let dir = try Self.databaseDirectory(for: libraryHash)
        self.databaseURL = dir.appendingPathComponent("ambrosia_meta.db")
        let writePath = databaseURL.path
        self.db = try Connection(writePath)
        self.readDB = try Connection(writePath, readonly: true)
        db.busyTimeout = 5.0
        readDB.busyTimeout = 5.0
        SQLiteRegexRegistration.register(on: db)
        SQLiteRegexRegistration.register(on: readDB)
        // WAL mode: readers never block writers and writers never block readers.
        // Must be set on the write connection before migrations run.
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        // Pass 3 / D2: Enable memory-mapped I/O on ambrosia_meta.db only (256 MB cap).
        try? db.execute("PRAGMA mmap_size = 268435456")
        try? readDB.execute("PRAGMA mmap_size = 268435456")
        #if DEBUG
        if let currentMmapSize = try? db.scalar("PRAGMA mmap_size") as? Int64 {
            print("[AmbrosiaMetaDB] PRAGMA mmap_size = \(currentMmapSize)")
        }
        #endif
        try Self.runMigrations(db: db)
        _ = try? db.run("INSERT OR REPLACE INTO library_state (key, value) VALUES (?, ?)", ["library_path", libraryURL.path])
    }

    public static var baseDirectoryOverride: URL?

    static func librariesBaseDirectory() throws -> URL {
        if let baseDirectoryOverride {
            try FileManager.default.createDirectory(at: baseDirectoryOverride, withIntermediateDirectories: true)
            return baseDirectoryOverride
        }
        if AppEnvironment.isRunningTests {
            let testDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("AmbrosiaTestSupport", isDirectory: true)
                .appendingPathComponent("libraries", isDirectory: true)
            try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
            return testDir
        }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MetaDBError.applicationSupportUnavailable
        }
        let dir = support.appendingPathComponent("Ambrosia").appendingPathComponent("libraries")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func databaseDirectory(for hash: String) throws -> URL {
        let dir = try librariesBaseDirectory().appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Scans the production libraries directory and cleans up any orphaned database directories
    /// that were created by tests or belong to non-existent temporary libraries.
    static func pruneStaleTestDatabases(force: Bool = false) {
        guard !AppEnvironment.isRunningTests || force else { return }
        guard let base = try? librariesBaseDirectory() else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }

        var knownHashes = Set(LibraryIndexManager.shared.entries().map(\.hash))
        for path in LibraryRegistry.shared.knownPaths {
            knownHashes.insert(Ambrosia.libraryHash(for: URL(fileURLWithPath: path)))
        }

        for dir in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let folderName = dir.lastPathComponent
            guard folderName != "index.json" else { continue }

            let isRegistered = knownHashes.contains(folderName)
            let dbFile = dir.appendingPathComponent("ambrosia_meta.db")
            guard fm.fileExists(atPath: dbFile.path) else {
                if !isRegistered {
                    try? fm.removeItem(at: dir)
                }
                continue
            }

            let shouldPrune: Bool = autoreleasepool {
                guard let db = try? Connection(dbFile.path, readonly: true) else {
                    return !isRegistered
                }
                let pathVal = (try? db.scalar("SELECT value FROM library_state WHERE key = 'library_path'")) as? String
                if let pathVal {
                    let libURL = URL(fileURLWithPath: pathVal)
                    if AppEnvironment.isTestLibraryURL(libURL) || !fm.fileExists(atPath: libURL.path) {
                        return true
                    }
                } else if !isRegistered {
                    // Orphaned or test database with no recorded library_path and not in index.json/knownPaths
                    return true
                }

                // Check diagnostics table for any test EPUB paths, safely verifying table existence first
                let hasDiagnostics = (try? db.scalar("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ao3_extraction_diagnostics'")) != nil
                if hasDiagnostics {
                    let epubPath = (try? db.scalar("SELECT epub_path FROM ao3_extraction_diagnostics WHERE epub_path IS NOT NULL LIMIT 1")) as? String
                    if let epubPath, AppEnvironment.isTestLibraryURL(URL(fileURLWithPath: epubPath)) {
                        return true
                    }
                }
                return false
            }

            if shouldPrune {
                try? fm.removeItem(at: dir)
            }
        }
    }

    static func runMigrations(db: Connection) throws {
        try db.execute("PRAGMA foreign_keys = ON")
        try createCollections(db: db)
        try createAnnotations(db: db)
        try createReadingHistory(db: db)
        try createAO3Metadata(db: db)
        try createBookIndex(db: db)
        try createBookAuthors(db: db)
        try createBookTags(db: db)
        try createErrorLog(db: db)
        try createBookState(db: db)
        try createReadingGoals(db: db)
        try createSchemaMigrations(db: db)
        try createLibraryState(db: db)
        try createMaintenanceDismissals(db: db)
        try bootstrapSystemCollections(db: db)
        pruneStaleDiagnostics(db: db)
    }

    // MARK: - Migration tracking
    //
    // `schema_migrations` tracks applied schema migrations.
    // Legacy SwiftData, AO3 author column, and tag seed purge migrations have been retired.

    private static func createSchemaMigrations(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            name        TEXT PRIMARY KEY,
            applied_at  TEXT NOT NULL
        );
        """)
    }

    /// Small key/value table for derived "what have we already scanned" markers
    /// (see `LibraryFingerprint`). Additive and idempotent, so it uses
    /// `CREATE TABLE IF NOT EXISTS` rather than a `schema_migrations` entry.
    /// Safe to delete: a missing marker only means the next launch rescans.
    private static func createLibraryState(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS library_state (
            key    TEXT PRIMARY KEY,
            value  TEXT NOT NULL
        );
        """)
    }

    private static func createMaintenanceDismissals(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS maintenance_dismissals (
            kind         TEXT NOT NULL,
            target_key   TEXT NOT NULL,
            dismissed_at TEXT NOT NULL,
            PRIMARY KEY (kind, target_key)
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
            color_key     TEXT    NOT NULL DEFAULT 'yellow',
            created_at    TEXT    NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_annotations_calibre
            ON annotations(calibre_id);

        CREATE INDEX IF NOT EXISTS idx_annotations_position
            ON annotations(calibre_id, spine_index, start_char);
        """)

        if try !columnExists("annotations", "color_key", db: db) {
            try db.execute("ALTER TABLE annotations ADD COLUMN color_key TEXT NOT NULL DEFAULT 'yellow'")
            try db.execute("""
            UPDATE annotations
            SET color_key = CASE UPPER(COALESCE(color_hex, ''))
                WHEN '#FFD60A' THEN 'yellow'
                WHEN '#FFCC00' THEN 'yellow'
                WHEN '#FF453A' THEN 'red'
                WHEN '#FF3B30' THEN 'red'
                WHEN '#30D158' THEN 'green'
                WHEN '#34C759' THEN 'green'
                WHEN '#0A84FF' THEN 'blue'
                WHEN '#007AFF' THEN 'blue'
                WHEN '#BF5AF2' THEN 'purple'
                WHEN '#AF52DE' THEN 'purple'
                ELSE 'yellow'
            END
            """)
        }

        let newColumns: [(String, String)] = [
            ("spine_href", "TEXT NOT NULL DEFAULT ''"),
            ("quote_prefix", "TEXT NOT NULL DEFAULT ''"),
            ("quote_suffix", "TEXT NOT NULL DEFAULT ''"),
            ("chapter_title", "TEXT"),
            ("needs_reanchor", "INTEGER NOT NULL DEFAULT 0"),
            ("last_reanchored_at", "TEXT"),
            ("orphaned_at", "TEXT"),
            ("has_highlight", "INTEGER NOT NULL DEFAULT 1"),
            ("original_text", "TEXT"),
            ("replacement_text", "TEXT"),
            ("updated_at", "TEXT NOT NULL DEFAULT ''")
        ]
        for (column, definition) in newColumns where try !columnExists("annotations", column, db: db) {
            try db.execute("ALTER TABLE annotations ADD COLUMN \(column) \(definition)")
        }
        try db.execute("UPDATE annotations SET updated_at = created_at WHERE updated_at = ''")

        let ftsExists = try db.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'annotations_fts'"
        ) as? Int64 ?? 0
        if ftsExists == 0 {
            try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS annotations_fts USING fts5(
                selected_text,
                note,
                original_text,
                replacement_text,
                content='annotations',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            );

            CREATE TRIGGER IF NOT EXISTS annotations_ai AFTER INSERT ON annotations BEGIN
                INSERT INTO annotations_fts(rowid, selected_text, note, original_text, replacement_text)
                VALUES (new.rowid, new.selected_text, new.note, new.original_text, new.replacement_text);
            END;

            CREATE TRIGGER IF NOT EXISTS annotations_ad AFTER DELETE ON annotations BEGIN
                INSERT INTO annotations_fts(annotations_fts, rowid, selected_text, note, original_text, replacement_text)
                VALUES ('delete', old.rowid, old.selected_text, old.note, old.original_text, old.replacement_text);
            END;

            CREATE TRIGGER IF NOT EXISTS annotations_au AFTER UPDATE ON annotations BEGIN
                INSERT INTO annotations_fts(annotations_fts, rowid, selected_text, note, original_text, replacement_text)
                VALUES ('delete', old.rowid, old.selected_text, old.note, old.original_text, old.replacement_text);
                INSERT INTO annotations_fts(rowid, selected_text, note, original_text, replacement_text)
                VALUES (new.rowid, new.selected_text, new.note, new.original_text, new.replacement_text);
            END;

            INSERT INTO annotations_fts(annotations_fts) VALUES('rebuild');
            """)
        }
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
            extracted_at TEXT NOT NULL,
            is_restricted INTEGER
        );
        """)
        if try !columnExists("ao3_metadata", "is_restricted", db: db) {
            try db.run("ALTER TABLE ao3_metadata ADD COLUMN is_restricted INTEGER")
        }
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
        CREATE TABLE IF NOT EXISTS series (
            series_id INTEGER PRIMARY KEY AUTOINCREMENT,
            series_key TEXT NOT NULL,
            name TEXT NOT NULL,
            ao3_series_id TEXT,
            calibre_series_id INTEGER,
            name_key TEXT,
            created_at TEXT NOT NULL,
            CHECK (ao3_series_id IS NULL OR ao3_series_id <> ''),
            CHECK (ao3_series_id IS NOT NULL OR calibre_series_id IS NOT NULL OR name_key IS NOT NULL)
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_series_key ON series(series_key);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_series_ao3 ON series(ao3_series_id) WHERE ao3_series_id IS NOT NULL;
        CREATE UNIQUE INDEX IF NOT EXISTS idx_series_calibre ON series(calibre_series_id) WHERE calibre_series_id IS NOT NULL;
        CREATE UNIQUE INDEX IF NOT EXISTS idx_series_name ON series(name_key) WHERE name_key IS NOT NULL;

        CREATE TABLE IF NOT EXISTS series_cache (
            calibre_id INTEGER NOT NULL,
            series_id INTEGER NOT NULL REFERENCES series(series_id),
            series_index INTEGER NOT NULL,
            is_anthology INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (calibre_id, series_id)
        );
        CREATE INDEX IF NOT EXISTS idx_series_cache_series ON series_cache(series_id, series_index);

        CREATE TABLE IF NOT EXISTS series_collection_members (
            collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            series_id INTEGER NOT NULL REFERENCES series(series_id) ON DELETE CASCADE,
            added_at TEXT NOT NULL,
            PRIMARY KEY (collection_id, series_id)
        );
        CREATE TABLE IF NOT EXISTS series_collection_exclusions (
            collection_id TEXT NOT NULL,
            series_id INTEGER NOT NULL,
            calibre_id INTEGER NOT NULL,
            PRIMARY KEY (collection_id, series_id, calibre_id),
            FOREIGN KEY (collection_id, series_id)
                REFERENCES series_collection_members(collection_id, series_id) ON DELETE CASCADE
        );
        DROP VIEW IF EXISTS effective_collection_members;
        CREATE VIEW effective_collection_members AS
        SELECT collection_id, calibre_id, added_at FROM collection_members
        UNION ALL
        SELECT f.collection_id, m.calibre_id, f.added_at
        FROM series_collection_members f
        JOIN series_cache m ON m.series_id = f.series_id
        WHERE NOT EXISTS (
            SELECT 1 FROM series_collection_exclusions x
            WHERE x.collection_id = f.collection_id
              AND x.series_id = f.series_id
              AND x.calibre_id = m.calibre_id
        );

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

        CREATE INDEX IF NOT EXISTS idx_ao3_extraction_diagnostics_status
            ON ao3_extraction_diagnostics(status);

        """)
    }

    /// Resolves stable identity inside the database actor. Existing rows keep
    /// their creation-time key when the display name changes.
    private func resolveSeriesID(name: String, ao3ID: String?, calibreSeriesID: Int?) throws -> Int {
        let cleanedAO3ID = ao3ID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAO3ID = cleanedAO3ID?.isEmpty == false ? cleanedAO3ID : nil
        let nameKey = NormalizedSeriesName.key(name)
        let identityColumn: String
        let identityValue: Binding
        let key: String
        let normalizedName: String?
        if let normalizedAO3ID {
            identityColumn = "ao3_series_id"
            identityValue = normalizedAO3ID
            key = "ao3:\(normalizedAO3ID)"
            normalizedName = nil
        } else if let calibreSeriesID {
            identityColumn = "calibre_series_id"
            identityValue = calibreSeriesID
            key = "calibre:\(calibreSeriesID)"
            normalizedName = nil
        } else {
            identityColumn = "name_key"
            identityValue = nameKey
            key = "calibre-name:\(name.trimmingCharacters(in: .whitespacesAndNewlines))"
            normalizedName = nameKey
        }
        if let row = try db.prepare("SELECT series_id FROM series WHERE \(identityColumn) = ?", [identityValue]).map({ $0 }).first,
           let id = row.int(at: 0) {
            try db.run("UPDATE series SET name = ? WHERE series_id = ?", [name, id])
            return id
        }
        try run("""
            INSERT INTO series (series_key, name, ao3_series_id, calibre_series_id, name_key, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [key, name, normalizedAO3ID, calibreSeriesID, normalizedName,
                  ISO8601DateFormatter().string(from: Date())])
        // Read the inserted row ID from the same write connection. The
        // read-only connection cannot see an uncommitted insert in this
        // transaction.
        guard let id = (try db.scalar("SELECT last_insert_rowid()") as? Int64).map(Int.init) else {
            throw NSError(domain: "AmbrosiaMetaDB", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to resolve series identity for \(name)"])
        }
        return id
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
    /// One-time schema migration: `ao3_author_username` was a dead scalar
    /// column — the old extractor never populated it (always nil in every
    /// extracted record). `AO3MetadataRecord.authors` replaces it with a
    /// structured, potentially multi-author array stored as `authors_json`
    /// (added additively in `createAO3Metadata` above, mirroring
    /// §7.1 (Phase 6): universal per-book index. Every book for which
    /// `EPUBParser.parse()` succeeds gets a row here, AO3 or not — see
    /// LibrarySession.extractOneBook's `.indexed` outcome. `title`/`description`
    /// are captured but intentionally not wired into any filter/sort surface;
    /// title/comment filtering stays Calibre-backed per §7's opening decision.
    private static func createBookIndex(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS book_index (
            calibre_id   INTEGER PRIMARY KEY,
            title        TEXT,
            description  TEXT,
            word_count   INTEGER,
            pub_date     TEXT,
            publisher    TEXT,
            subject      TEXT,
            indexed_at   TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_book_index_wordcount ON book_index(word_count);
        """)
    }

    /// §4.1 (Phase 3): normalizes AO3-sourced author data out of Calibre's
    /// `authors`/`books_authors_link` and into Ambrosia's own table, scoped
    /// to books that reach `.success` in `extractOneBook` -- mirrors
    /// `ao3_metadata`'s own scope, not universal like `book_index` (see
    /// `writeBookAuthors`, called from `insertBatch`). `sort_order` preserves
    /// multi-author ordering; composite primary key on (calibre_id,
    /// sort_order) rather than a surrogate key, following this codebase's
    /// other additive-table convention (`series_cache`, `book_tags`-shaped
    /// tables). No migration needed beyond `CREATE TABLE IF NOT EXISTS`
    /// itself -- brand-new table, not a destructive change (Invariant 11).
    private static func createBookAuthors(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS book_authors (
            calibre_id  INTEGER NOT NULL,
            name        TEXT    NOT NULL,
            source      TEXT    NOT NULL,
            sort_order  INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (calibre_id, sort_order)
        );
        CREATE INDEX IF NOT EXISTS idx_book_authors_name ON book_authors(name);
        CREATE INDEX IF NOT EXISTS idx_book_authors_calibre ON book_authors(calibre_id);
        """)
    }

    /// Phase 4 (§5.2): normalized AO3 tag membership, one row per (book, tag,
    /// type). Sourced from ao3_metadata's already-typed JSON columns at write
    /// time (§5.3): `tag_type` uses AO3FacetField's granularity (fandom/
    /// relationship/character/freeform/rating/warning/category), not the
    /// coarser FilterField.tag "any type" bucket a rule searches against.
    /// Composite primary key on (calibre_id, tag_name, tag_type) rather than
    /// tag_name alone: a freeform tag and a fandom tag could collide on the
    /// exact same string in principle (AO3 doesn't prevent it), and the type
    /// is part of the identity here, not just a label.
    private static func createBookTags(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS book_tags (
            calibre_id  INTEGER NOT NULL,
            tag_name    TEXT    NOT NULL,
            tag_type    TEXT    NOT NULL,
            PRIMARY KEY (calibre_id, tag_name, tag_type)
        );

        CREATE INDEX IF NOT EXISTS idx_book_tags_name ON book_tags(tag_name);
        CREATE INDEX IF NOT EXISTS idx_book_tags_calibre ON book_tags(calibre_id);
        CREATE INDEX IF NOT EXISTS idx_book_tags_type ON book_tags(tag_type, tag_name);

        CREATE TABLE IF NOT EXISTS tag_canonical_map (
            tag_name        TEXT NOT NULL PRIMARY KEY,
            canonical_name  TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_tag_canonical_map_name ON tag_canonical_map(canonical_name);
        """)
    }

    /// `error_log` is the durable counterpart to the `#if DEBUG print`
    /// statements used elsewhere in the app: those are fine for development
    /// but leave no trail once a release build is running in the field. This
    /// gives failures in AO3 extraction, EPUB parsing, and `LocalFeedServer`
    /// routes (none of which had any durable diagnostic trail before this) a
    /// queryable, prunable record, viewable via `ErrorLogView`. Scoped-per-
    /// subsystem diagnostics that already exist (`ao3_extraction_diagnostics`)
    /// are unaffected -- this is a general-purpose complement, not a
    /// replacement. Additive-only (`CREATE TABLE IF NOT EXISTS`), so no
    /// `schema_migrations` gating is needed -- see the migration note in
    /// `docs/metadb-and-migrations.md`.
    private static func createErrorLog(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS error_log (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            occurred_at  TEXT    NOT NULL,
            subsystem    TEXT    NOT NULL,
            operation    TEXT    NOT NULL,
            message      TEXT    NOT NULL,
            file         TEXT,
            line         INTEGER,
            calibre_id   INTEGER
        );

        CREATE INDEX IF NOT EXISTS idx_error_log_occurred_at ON error_log(occurred_at);
        CREATE INDEX IF NOT EXISTS idx_error_log_calibre ON error_log(calibre_id);
        """)
    }

    private static func createBookState(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS book_state (
            calibre_id                  INTEGER PRIMARY KEY NOT NULL,
            last_opened_date            REAL NOT NULL DEFAULT 0,
            total_read_percent          REAL NOT NULL DEFAULT 0.0,
            total_reading_time_seconds  REAL NOT NULL DEFAULT 0.0,
            last_spine_index            INTEGER NOT NULL DEFAULT 0,
            last_character_offset       INTEGER NOT NULL DEFAULT 0,
            last_scroll_offset          REAL NOT NULL DEFAULT 0.0,
            elo_score                   REAL NOT NULL DEFAULT 1000.0,
            elo_match_count             INTEGER NOT NULL DEFAULT 0,
            updated_at                  REAL NOT NULL DEFAULT (strftime('%s', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_book_state_opened ON book_state(last_opened_date DESC);
        CREATE INDEX IF NOT EXISTS idx_book_state_percent ON book_state(total_read_percent);
        """)
    }

    private static func createReadingGoals(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS reading_goals (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            target_books_count  INTEGER NOT NULL,
            period_start        REAL NOT NULL,
            period_end          REAL NOT NULL,
            created_at          REAL NOT NULL DEFAULT (strftime('%s', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_reading_goals_period ON reading_goals(period_start, period_end);
        """)
    }

    /// Maximum number of error log records retained during open-time pruning.
    static let errorLogRetention = 1000

    private static func pruneStaleDiagnostics(db: Connection) {
        _ = try? db.run("""
            DELETE FROM ao3_extraction_diagnostics
            WHERE calibre_id IN (SELECT calibre_id FROM ao3_metadata);
            """)
    }

    func clearAO3TagSynonymCacheAndReloadSeeds() throws {
        AO3TagSeedDatabaseConfig.shared.refreshValidation()
    }

    func ao3TagSeedCounts() throws -> AO3TagSeedDatabaseConfig.Counts {
        if let url = AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled() {
            return try AO3TagSeedDatabaseConfig.counts(url: url)
        }
        return AO3TagSeedDatabaseConfig.Counts(canonicalTags: 0, synonyms: 0, hierarchyEdges: 0, subtagSections: 0)
    }

    /// Synchronizes `tag_canonical_map` with the configured seed database if needed.
    ///
    /// If seeds are disabled or unconfigured, clears the map and sets marker to `"off"`.
    /// If seeds are enabled and valid, synchronizes synonyms and canonicals for all distinct
    /// tag names present in `book_tags`.
    /// Returns true if a re-synchronization was executed, false if already up-to-date.
    @discardableResult
    func syncTagCanonicalMapIfNeeded(seedURL: URL? = nil, explicitIdentity: String? = nil) throws -> Bool {
        let isConfigEnabled = AO3TagSeedDatabaseConfig.shared.isEnabled
        let resolvedURL = seedURL ?? (isConfigEnabled ? AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled() : nil)
        let targetIdentity: String
        if let explicit = explicitIdentity {
            targetIdentity = explicit
        } else if let validURL = resolvedURL {
            targetIdentity = (try? AO3TagSeedDatabaseConfig.identity(for: validURL)) ?? "off"
        } else {
            targetIdentity = "off"
        }

        let currentMarker = libraryState(LibraryStateKey.tagCanonicalSeedIdentity)
        if currentMarker == targetIdentity && lastSyncedTagCanonicalRevision == bookTagsRevision {
            return false
        }

        guard targetIdentity != "off", let validURL = resolvedURL else {
            try run("DELETE FROM tag_canonical_map")
            try setLibraryState(LibraryStateKey.tagCanonicalSeedIdentity, "off")
            lastSyncedTagCanonicalRevision = bookTagsRevision
            return true
        }

        let escapedPath = validURL.path.replacingOccurrences(of: "'", with: "''")
        try db.execute("ATTACH '\(escapedPath)' AS seed_sync;")
        defer {
            _ = try? db.execute("DETACH seed_sync;")
        }

        try db.transaction {
            try db.execute("DELETE FROM tag_canonical_map;")
            try db.execute("CREATE TEMP TABLE IF NOT EXISTS distinct_lib_tags (tag_name TEXT PRIMARY KEY);")
            try db.execute("DELETE FROM distinct_lib_tags;")
            try db.execute("INSERT OR IGNORE INTO distinct_lib_tags SELECT DISTINCT tag_name FROM book_tags;")
            try db.execute("CREATE INDEX IF NOT EXISTS temp.dlt_lower ON distinct_lib_tags(LOWER(tag_name));")

            // 1. Synonyms: map library tag to its canonical name
            try db.execute("""
                INSERT OR REPLACE INTO tag_canonical_map (tag_name, canonical_name)
                SELECT dlt.tag_name, c.name
                FROM distinct_lib_tags dlt
                JOIN seed_sync.tag_synonyms s ON LOWER(s.synonym) = LOWER(dlt.tag_name)
                JOIN seed_sync.canonical_tags c ON c.id = s.canonical_id;
            """)

            // 2. Canonicals: normalize casing to the canonical tag name
            try db.execute("""
                INSERT OR REPLACE INTO tag_canonical_map (tag_name, canonical_name)
                SELECT dlt.tag_name, c.name
                FROM distinct_lib_tags dlt
                JOIN seed_sync.canonical_tags c ON LOWER(c.name) = LOWER(dlt.tag_name);
            """)

            try db.execute("DROP TABLE distinct_lib_tags;")
            try setLibraryState(LibraryStateKey.tagCanonicalSeedIdentity, targetIdentity)
        }

        lastSyncedTagCanonicalRevision = bookTagsRevision
        return true
    }

    func vacuumAndCheckpoint() throws {
        try run("PRAGMA wal_checkpoint(TRUNCATE);")
        try run("VACUUM;")
        try run("PRAGMA wal_checkpoint(TRUNCATE);")
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

    // MARK: - library_state

    func libraryState(_ key: String) -> String? {
        guard let rows = try? readDB.prepare("SELECT value FROM library_state WHERE key = ?", [key]).map({ $0 }),
              let first = rows.first else { return nil }
        return first.first as? String
    }

    func setLibraryState(_ key: String, _ value: String) throws {
        try db.run(
            """
            INSERT INTO library_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [key, value]
        )
    }

    func removeLibraryState(_ key: String) throws {
        try db.run("DELETE FROM library_state WHERE key = ?", [key])
    }

    /// Bumped every time a write rewrites a book's `series_cache` rows. A series
    /// seed that began at count N may only record itself as complete if the count
    /// is still N when it finishes (see `markSeriesSeeded`).
    private(set) var seriesRewriteCount = 0

    /// Called by every write that replaces a book's `series_cache` rows. Drops
    /// the seed marker so the next launch re-seeds the Calibre fallback rows
    /// that rewrite removed.
    func invalidateSeriesSeedMarker() throws {
        seriesRewriteCount &+= 1
        try db.run("DELETE FROM library_state WHERE key = ?", [LibraryStateKey.seriesSeedFingerprint])
    }

    /// Records that the Calibre series seed completed for `fingerprint`, unless a
    /// series-rewriting write landed since the seed started. Runs on the actor
    /// with no suspension, so the check and the write are atomic. Returns whether
    /// it was recorded.
    @discardableResult
    func markSeriesSeeded(_ fingerprint: LibraryFingerprint, ifRewriteCountIs expected: Int) throws -> Bool {
        guard seriesRewriteCount == expected else { return false }
        try setLibraryState(LibraryStateKey.seriesSeedFingerprint, fingerprint.encoded())
        return true
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

    private static func decodeAnnotationColorKey(rawKey: String?, legacyHex: String?) -> AnnotationColor {
        if let rawKey, let key = AnnotationColor(rawValue: rawKey) {
            return key
        }
        return AnnotationColor(legacyHex: legacyHex)
    }

    private static let annotationSelectColumns = """
        id, calibre_id, spine_index, start_char, end_char, selected_text,
        note, color_hex, created_at, color_key,
        spine_href, quote_prefix, quote_suffix, chapter_title,
        needs_reanchor, last_reanchored_at, orphaned_at,
        has_highlight, original_text, replacement_text, updated_at
        """

    private static func decodeAnnotationRow(
        _ row: Statement.Element,
        iso: ISO8601DateFormatter
    ) -> (annotation: Annotation, calibreID: Int)? {
        guard let idString = row[safe: 0] as? String,
              let id = UUID(uuidString: idString),
              let calibreID = row.int(at: 1),
              let spine = row.int(at: 2),
              let start = row.int(at: 3),
              let end = row.int(at: 4),
              let selectedText = row[safe: 5] as? String,
              let createdStr = row[safe: 8] as? String else { return nil }

        let hex = (row[safe: 7] as? String) ?? "#FFD60A"
        let key = decodeAnnotationColorKey(rawKey: row[safe: 9] as? String, legacyHex: hex)
        let createdDate = iso.date(from: createdStr) ?? Date()
        let updatedDate = (row[safe: 20] as? String).flatMap { iso.date(from: $0) } ?? createdDate
        let originalText = row[safe: 18] as? String
        let hasHighlight = (row.int(at: 17) ?? 1) != 0 || originalText == nil

        let annotation = Annotation(
            id: id,
            spineIndex: spine,
            spineHref: (row[safe: 10] as? String) ?? "",
            startChar: start,
            endChar: end,
            selectedText: selectedText,
            quotePrefix: (row[safe: 11] as? String) ?? "",
            quoteSuffix: (row[safe: 12] as? String) ?? "",
            chapterTitle: row[safe: 13] as? String,
            note: row[safe: 6] as? String,
            colorKey: key,
            colorHex: hex,
            hasHighlight: hasHighlight,
            originalText: originalText,
            replacementText: row[safe: 19] as? String,
            needsReanchor: (row.int(at: 14) ?? 0) != 0,
            lastReanchoredAt: (row[safe: 15] as? String).flatMap { iso.date(from: $0) },
            orphanedAt: (row[safe: 16] as? String).flatMap { iso.date(from: $0) },
            createdDate: createdDate,
            updatedAt: updatedDate
        )
        return (annotation, calibreID)
    }

    func annotations(for calibreID: Int, spineIndex: Int? = nil) throws -> [Annotation] {
        let iso = ISO8601DateFormatter()
        let sql: String
        let args: [Binding?]
        if let spineIndex {
            sql = """
            SELECT \(Self.annotationSelectColumns)
            FROM annotations
            WHERE calibre_id = ? AND spine_index = ?
            ORDER BY start_char
            """
            args = [calibreID, spineIndex]
        } else {
            sql = """
            SELECT \(Self.annotationSelectColumns)
            FROM annotations
            WHERE calibre_id = ?
            ORDER BY spine_index, start_char
            """
            args = [calibreID]
        }

        return try prepare(sql, args).compactMap { Self.decodeAnnotationRow($0, iso: iso)?.annotation }
    }

    func insertAnnotation(_ annotation: Annotation, calibreID: Int) throws {
        let iso = ISO8601DateFormatter()
        let effectiveHasHighlight = (annotation.hasHighlight || annotation.originalText == nil) ? 1 : 0
        try run(
            """
            INSERT OR REPLACE INTO annotations (
                id, calibre_id, spine_index, start_char, end_char, selected_text,
                note, color_hex, color_key, created_at,
                spine_href, quote_prefix, quote_suffix, chapter_title,
                needs_reanchor, last_reanchored_at, orphaned_at,
                has_highlight, original_text, replacement_text, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                annotation.colorKey.rawValue,
                iso.string(from: annotation.createdDate),
                annotation.spineHref,
                annotation.quotePrefix,
                annotation.quoteSuffix,
                annotation.chapterTitle,
                annotation.needsReanchor ? 1 : 0,
                annotation.lastReanchoredAt.map { iso.string(from: $0) },
                annotation.orphanedAt.map { iso.string(from: $0) },
                effectiveHasHighlight,
                annotation.originalText,
                annotation.replacementText,
                iso.string(from: annotation.updatedAt)
            ]
        )
        try run(
            "INSERT OR IGNORE INTO collection_members VALUES (?, ?, ?)",
            [SystemCollectionID.hasAnnotations, calibreID, iso.string(from: Date())]
        )
    }

    struct ReanchorUpdate: Sendable {
        let spineIndex: Int
        let spineHref: String
        let startChar: Int
        let endChar: Int
        let quotePrefix: String
        let quoteSuffix: String
        let chapterTitle: String?
    }

    func reanchorAnnotation(id: UUID, update: ReanchorUpdate) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try run(
            """
            UPDATE annotations
            SET spine_index = ?, spine_href = ?, start_char = ?, end_char = ?,
                quote_prefix = ?, quote_suffix = ?, chapter_title = COALESCE(?, chapter_title),
                needs_reanchor = 0, last_reanchored_at = ?, orphaned_at = NULL, updated_at = ?
            WHERE id = ?
            """,
            [
                update.spineIndex, update.spineHref, update.startChar, update.endChar,
                update.quotePrefix, update.quoteSuffix, update.chapterTitle,
                now, now, id.uuidString
            ]
        )
    }

    func markAnnotationOrphaned(id: UUID) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try run(
            "UPDATE annotations SET orphaned_at = COALESCE(orphaned_at, ?), needs_reanchor = 0 WHERE id = ?",
            [now, id.uuidString]
        )
    }

    func markBookAnnotationsNeedsReanchor(calibreID: Int) throws {
        try run("UPDATE annotations SET needs_reanchor = 1 WHERE calibre_id = ?", [calibreID])
    }

    func updateAnnotationAnchorContext(
        id: UUID,
        spineHref: String,
        quotePrefix: String,
        quoteSuffix: String,
        chapterTitle: String?
    ) throws {
        try run(
            """
            UPDATE annotations
            SET spine_href = ?, quote_prefix = ?, quote_suffix = ?,
                chapter_title = COALESCE(?, chapter_title)
            WHERE id = ?
            """,
            [spineHref, quotePrefix, quoteSuffix, chapterTitle, id.uuidString]
        )
    }

    struct AnnotationDetailsUpdate: Sendable {
        let note: String?
        let colorKey: AnnotationColor
        let colorHex: String
        let hasHighlight: Bool
        let originalText: String?
        let replacementText: String?
    }

    func updateAnnotationDetails(id: UUID, update: AnnotationDetailsUpdate) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let effectiveHasHighlight = (update.hasHighlight || update.originalText == nil) ? 1 : 0
        try run(
            """
            UPDATE annotations
            SET note = ?, color_key = ?, color_hex = ?,
                has_highlight = ?, original_text = ?, replacement_text = ?, updated_at = ?
            WHERE id = ?
            """,
            [
                update.note, update.colorKey.rawValue, update.colorHex,
                effectiveHasHighlight, update.originalText, update.replacementText, now, id.uuidString
            ]
        )
    }

    func shiftAnnotationOffsets(
        _ shifts: [(id: UUID, startChar: Int, endChar: Int, quotePrefix: String?, quoteSuffix: String?)]
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        for shift in shifts {
            try run(
                """
                UPDATE annotations
                SET start_char = ?, end_char = ?,
                    quote_prefix = COALESCE(?, quote_prefix),
                    quote_suffix = COALESCE(?, quote_suffix),
                    updated_at = ?
                WHERE id = ?
                """,
                [
                    shift.startChar, shift.endChar,
                    shift.quotePrefix, shift.quoteSuffix,
                    now, shift.id.uuidString
                ]
            )
        }
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
    // have not been wired up. See "Not Yet Built" in docs/not-yet-built.md.
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
        return db.lastInsertRowid
    }

    func updateReadingSession(id: Int64, calibreID: Int, percentEnd: Double?, endedAt: Date = Date()) throws {
        let end = ISO8601DateFormatter().string(from: endedAt)
        var wordsRead: Int?
        if let percentEnd {
            let row = try db.prepare(
                """
                SELECT rh.percent_start, am.word_count
                FROM reading_history rh
                LEFT JOIN ao3_metadata am ON am.calibre_id = rh.calibre_id
                WHERE rh.id = ? AND rh.calibre_id = ?
                """,
                [id, calibreID]
            ).map({ $0 }).first
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

    public func completedBooksCount(start: Date, end: Date, threshold: Double = 0.98) throws -> Int {
        let iso = ISO8601DateFormatter()
        let startString = iso.string(from: start)
        let endString = iso.string(from: end)
        let startEpoch = start.timeIntervalSince1970
        let endEpoch = end.timeIntervalSince1970
        let finishedID = SystemCollectionID.finished
        let count = try scalar(
            """
            SELECT COUNT(DISTINCT calibre_id) FROM (
                SELECT calibre_id
                FROM reading_history
                WHERE session_end >= ?
                  AND session_end <= ?
                  AND percent_end >= ?
                UNION
                SELECT calibre_id
                FROM collection_members
                WHERE collection_id = ?
                  AND added_at >= ?
                  AND added_at <= ?
                UNION
                SELECT calibre_id
                FROM book_state
                WHERE total_read_percent >= ?
                  AND updated_at >= ?
                  AND updated_at <= ?
            )
            """,
            [startString, endString, threshold, finishedID, startString, endString, threshold, startEpoch, endEpoch]
        )
        if let value = count as? Int64 { return Int(value) }
        if let value = count as? Int { return value }
        return 0
    }

    public func readingStatsInsights(start: Date?, end: Date?) throws -> ReadingStatsInsights {
        let iso = ISO8601DateFormatter()
        let decoder = JSONDecoder()

        func decodeStrings(_ string: String?) -> [String] {
            guard let string, let data = string.data(using: .utf8) else { return [] }
            return (try? decoder.decode([String].self, from: data)) ?? []
        }

        var sql = """
        SELECT rh.calibre_id, rh.words_read, rh.session_start, rh.session_end,
               am.fandoms_json, am.relationships_json, am.additional_tags_json
        FROM reading_history rh
        LEFT JOIN ao3_metadata am ON am.calibre_id = rh.calibre_id
        """
        var bindings: [Binding?] = []
        if let start, let end {
            sql += " WHERE rh.session_start >= ? AND rh.session_end <= ?"
            bindings.append(iso.string(from: start))
            bindings.append(iso.string(from: end))
        } else if let start {
            sql += " WHERE rh.session_start >= ?"
            bindings.append(iso.string(from: start))
        } else if let end {
            sql += " WHERE rh.session_end <= ?"
            bindings.append(iso.string(from: end))
        }

        let rows = try prepare(sql, bindings)

        var totalWords = 0
        var totalActiveSeconds = 0.0
        var activeCalibreIDs = Set<Int>()

        var fandomWords: [String: Int] = [:]
        var fandomWorks: [String: Set<Int>] = [:]

        var relWords: [String: Int] = [:]
        var relWorks: [String: Set<Int>] = [:]

        var tagWords: [String: Int] = [:]
        var tagWorks: [String: Set<Int>] = [:]

        for row in rows {
            guard let calibreID = row.int(at: 0) else { continue }
            activeCalibreIDs.insert(calibreID)
            let words = row.int(at: 1) ?? 0
            totalWords += words

            if let sStr = row[safe: 2] as? String,
               let eStr = row[safe: 3] as? String,
               let sDate = iso.date(from: sStr),
               let eDate = iso.date(from: eStr) {
                let duration = max(0, eDate.timeIntervalSince(sDate))
                totalActiveSeconds += min(duration, 14400.0)
            }

            let fandoms = decodeStrings(row[safe: 4] as? String)
            for fandom in fandoms where !fandom.isEmpty {
                fandomWords[fandom, default: 0] += words
                fandomWorks[fandom, default: []].insert(calibreID)
            }

            let rels = decodeStrings(row[safe: 5] as? String)
            for rel in rels where !rel.isEmpty {
                relWords[rel, default: 0] += words
                relWorks[rel, default: []].insert(calibreID)
            }

            let tags = decodeStrings(row[safe: 6] as? String)
            for tag in tags where !tag.isEmpty {
                tagWords[tag, default: 0] += words
                tagWorks[tag, default: []].insert(calibreID)
            }
        }

        let hours = totalActiveSeconds / 3600.0
        let wph = hours > 0 ? Double(totalWords) / hours : 0.0

        let topFandoms = fandomWords
            .map { FandomInsight(name: $0.key, words: $0.value, works: fandomWorks[$0.key]?.count ?? 0) }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.works > $1.works }

        let topRelationships = relWords
            .map {
                RelationshipInsight(
                    name: $0.key,
                    words: $0.value,
                    works: relWorks[$0.key]?.count ?? 0,
                    isRomantic: $0.key.contains("/")
                )
            }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.works > $1.works }

        let topTags = tagWords
            .map { TagInsight(name: $0.key, words: $0.value, works: tagWorks[$0.key]?.count ?? 0) }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.works > $1.works }

        return ReadingStatsInsights(
            topFandoms: Array(topFandoms.prefix(10)),
            topRelationships: Array(topRelationships.prefix(10)),
            topTags: Array(topTags.prefix(15)),
            totalWords: totalWords,
            totalWorks: activeCalibreIDs.count,
            wordsPerHour: wph,
            activeSeconds: totalActiveSeconds
        )
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

    // MARK: - Error log

    /// Records one failure into `error_log`. `file`/`line` default to the
    /// call site via `#fileID`/`#line` -- callers normally omit both.
    func logError(
        subsystem: String,
        operation: String,
        message: String,
        calibreID: Int? = nil,
        file: String = #fileID,
        line: Int = #line
    ) throws {
        try run(
            """
            INSERT INTO error_log (occurred_at, subsystem, operation, message, file, line, calibre_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [ISO8601DateFormatter().string(from: Date()), subsystem, operation, message, file, line, calibreID]
        )
    }

    /// Returns up to `limit` error-log entries, newest first.
    func recentErrors(limit: Int = 200) throws -> [ErrorLogEntry] {
        let rows = try prepare(
            """
            SELECT id, occurred_at, subsystem, operation, message, file, line, calibre_id
            FROM error_log
            ORDER BY occurred_at DESC, id DESC
            LIMIT ?
            """,
            [limit]
        )
        let iso = ISO8601DateFormatter()
        return rows.compactMap { row in
            guard let id = row.int64(at: 0),
                  let occurredAtString = row[safe: 1] as? String,
                  let occurredAt = iso.date(from: occurredAtString),
                  let subsystem = row[safe: 2] as? String,
                  let operation = row[safe: 3] as? String,
                  let message = row[safe: 4] as? String else { return nil }
            return ErrorLogEntry(
                id: id,
                occurredAt: occurredAt,
                subsystem: subsystem,
                operation: operation,
                message: message,
                file: row[safe: 5] as? String,
                line: row.int(at: 6),
                calibreID: row.int(at: 7)
            )
        }
    }

    /// Deletes every row except the `count` most recent, so the table can be
    /// pruned periodically instead of growing unbounded.
    func pruneErrorLog(keeping count: Int) throws {
        try run(
            """
            DELETE FROM error_log
            WHERE id NOT IN (
                SELECT id FROM error_log ORDER BY occurred_at DESC, id DESC LIMIT ?
            )
            """,
            [count]
        )
    }

    func clearErrorLog() throws {
        try run("DELETE FROM error_log")
    }

    // MARK: - Activity feed queries

    /// Returns up to `limit` annotations across all books, newest first.
    /// Uses readDB (read-only connection) — no contention with write actor.
    func recentAnnotations(limit: Int = 250) throws -> [(annotation: Annotation, calibreID: Int)] {
        let iso = ISO8601DateFormatter()
        let rows = try prepare(
            """
            SELECT \(Self.annotationSelectColumns)
            FROM annotations
            ORDER BY created_at DESC, rowid DESC
            LIMIT ?
            """,
            [limit as Binding?]
        )
        return rows.compactMap { Self.decodeAnnotationRow($0, iso: iso) }
    }

    /// Returns every annotation in the library, newest first. Unlike
    /// `recentAnnotations(limit:)` (used for the bounded Activity Feed
    /// stream), this has no LIMIT — it exists for exhaustive export
    /// (`AnnotationExportManager`), where a partial list would silently
    /// drop rows. Uses readDB (read-only connection) — no contention with
    /// the write actor. Same decode logic as `recentAnnotations`.
    func allAnnotations() throws -> [(annotation: Annotation, calibreID: Int)] {
        let iso = ISO8601DateFormatter()
        let rows = try prepare(
            """
            SELECT \(Self.annotationSelectColumns)
            FROM annotations
            ORDER BY created_at DESC, rowid DESC
            """
        )
        return rows.compactMap { Self.decodeAnnotationRow($0, iso: iso) }
    }

    enum AnnotationFilterType: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case highlights = "Highlights"
        case withNotes = "With Notes"
        case textEdits = "Text Edits"
        case bookmarks = "Bookmarks"
        case orphaned = "Orphaned"

        var id: String { rawValue }
    }

    func searchAnnotations(
        query: String,
        scopeCalibreID: Int? = nil,
        scopeSpineIndex: Int? = nil,
        filterType: AnnotationFilterType = .all,
        colorKey: AnnotationColor? = nil
    ) throws -> [(annotation: Annotation, calibreID: Int)] {
        let iso = ISO8601DateFormatter()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var conditions: [String] = []
        var args: [Binding?] = []

        let fromClause: String
        if !trimmed.isEmpty {
            let ftsTokens = trimmed
                .split(whereSeparator: { $0.isWhitespace })
                .map { token -> String in
                    let cleaned = token.replacingOccurrences(of: "\"", with: "")
                    return "\"\(cleaned)\"*"
                }
                .joined(separator: " ")
            fromClause = "FROM annotations a JOIN annotations_fts ON a.rowid = annotations_fts.rowid"
            conditions.append("annotations_fts MATCH ?")
            args.append(ftsTokens)
        } else {
            fromClause = "FROM annotations a"
        }

        if let calibreID = scopeCalibreID {
            conditions.append("a.calibre_id = ?")
            args.append(calibreID)
        }
        if let spineIndex = scopeSpineIndex {
            conditions.append("a.spine_index = ?")
            args.append(spineIndex)
        }
        switch filterType {
        case .all:
            break
        case .highlights:
            conditions.append("a.has_highlight = 1 AND a.start_char != a.end_char")
        case .withNotes:
            conditions.append("a.note IS NOT NULL AND TRIM(a.note) != ''")
        case .textEdits:
            conditions.append("a.original_text IS NOT NULL")
        case .bookmarks:
            conditions.append("a.start_char = a.end_char")
        case .orphaned:
            conditions.append("a.orphaned_at IS NOT NULL")
        }
        if let colorKey {
            conditions.append("a.color_key = ?")
            args.append(colorKey.rawValue)
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let columns = Self.annotationSelectColumns
            .split(separator: ",")
            .map { "a." + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: ", ")

        let sql = """
        SELECT \(columns)
        \(fromClause)
        \(whereClause)
        ORDER BY a.updated_at DESC, a.created_at DESC, a.rowid DESC
        """
        return try prepare(sql, args).compactMap { Self.decodeAnnotationRow($0, iso: iso) }
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
            if let systemFlag64 = row[safe: 3] as? Int64 {
                isSystem = systemFlag64 != 0
            } else if let systemFlag = row[safe: 3] as? Int {
                isSystem = systemFlag != 0
            } else {
                isSystem = false
            }

            return CollectionActivityEntry(
                id: "\(collectionID)-\(calibreID)",
                collectionID: collectionID,
                collectionName: name,
                kind: kind,
                calibreID: calibreID,
                addedAt: date,
                isSystem: isSystem
            )
        }
    }

    func existingAO3MetadataIDs() throws -> Set<Int> {
        let rows = try prepare("SELECT calibre_id FROM ao3_metadata")
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    /// §7.3 (Phase 6): mirrors existingAO3MetadataIDs()'s own shape. Required
    /// as a third exclusion set in startAO3Extraction's `missing` computation
    /// — without it, every non-AO3 book (which writes to book_index but
    /// neither ao3_metadata nor ao3_extraction_diagnostics) gets fully
    /// re-parsed on every library open, forever.
    func existingBookIndexIDs() throws -> Set<Int> {
        let rows = try prepare("SELECT calibre_id FROM book_index")
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    func attemptedAO3ExtractionIDs() throws -> Set<Int> {
        let rows = try prepare("SELECT calibre_id FROM ao3_extraction_diagnostics")
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    /// §4.3 (Phase 3): the book_authors/Calibre-fallback partition's
    /// "covered" side -- every calibre_id with at least one `book_authors`
    /// row. `CalibreLibrary.authorMatchIDs` subtracts this from its
    /// Calibre-side positive matches, so a book with a `book_authors` row
    /// (whose AO3-sourced author name may differ from Calibre's own author
    /// field) is never double-counted via that Calibre field. Mirrors
    /// `existingAO3MetadataIDs()`/`existingBookIndexIDs()`'s own shape.
    func existingBookAuthorsIDs() throws -> Set<Int> {
        let rows = try prepare("SELECT DISTINCT calibre_id FROM book_authors")
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    /// §4.3 (Phase 3): positive-match calibre_ids for an authorName rule
    /// against `book_authors`. Always the *positive* matcher regardless of
    /// the rule's op sign -- `.notContains`/`.notEquals` use the identical
    /// matcher to `.contains`/`.equals`. The caller
    /// (`CalibreLibrary.authorMatchIDs`) applies negation via `.subtracting`
    /// against the full library, the same way `matchingIDsForGroup` already
    /// does for collection/status membership maps -- correct only because
    /// `book_authors` and the Calibre-side fallback query partition the
    /// full calibre_id space cleanly; see the plan's §4.3 for why that's a
    /// named precondition here, not an incidental property.
    func bookAuthorMatchIDs(nameFragment: String, op: FilterOperator) throws -> Set<Int> {
        let value = nameFragment.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return [] }
        let matcher: String
        let arg: Binding?
        switch op {
        case .contains, .notContains:
            matcher = "LOWER(name) LIKE ? ESCAPE '\\'"
            let escaped = LibraryQueryHelpers.escapeLikePattern(value.lowercased())
            arg = "%\(escaped)%"
        case .equals, .notEquals:
            matcher = "LOWER(name) = ?"
            arg = value.lowercased()
        case .startsWith:
            matcher = "LOWER(name) LIKE ? ESCAPE '\\'"
            let escaped = LibraryQueryHelpers.escapeLikePattern(value.lowercased())
            arg = "\(escaped)%"
        case .matchesWord:
            let escaped = NSRegularExpression.escapedPattern(for: value)
            matcher = "name REGEXP ?"
            arg = "(?i)\\b\(escaped)\\b"
        case .matchesRegex:
            matcher = "name REGEXP ?"
            arg = value
        case .ratingAtMost, .ratingAtLeast:
            // Not offered for authorName (see FilterRule.availableOperators); no valid SQL shape.
            return []
        }
        let rows = try prepare("SELECT DISTINCT calibre_id FROM book_authors WHERE \(matcher)", [arg])
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    /// Phase 4 (§5.4): the book_tags/Calibre-fallback partition's "covered"
    /// side -- every calibre_id with at least one `book_tags` row. Mirrors
    /// `existingBookAuthorsIDs()`'s own role for authorName.
    func calibreIDsWithBookTags() throws -> Set<Int> {
        let rows = try prepare("SELECT DISTINCT calibre_id FROM book_tags")
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    /// Phase 4 (§5.4): positive-match calibre_ids for a tag/rating/warning/
    /// category rule against `book_tags`, already normalized to its
    /// positive-match form by the caller (mirrors `bookAuthorMatchIDs`).
    /// `terms` is the already-expanded synonym list for `.tag` rules (so
    /// `TagExpansionResolver` keeps working here, same as it does for the
    /// Calibre-side fallback); for rating/warning/category it's always a
    /// single-element list. `tagType` restricts to one column ("rating"/
    /// "warning"/"category"), or nil to match any type (`.tag`'s "any of
    /// this book's tags" scope).
    /// `coverage`, when non-nil, is a caller-supplied
    /// `calibreIDsWithBookTags()` result. The rating range ops need it, and
    /// without this parameter each such rule re-ran the full
    /// `SELECT DISTINCT calibre_id FROM book_tags` scan.
    /// `restrictedTo`, when non-nil, limits the plain string-match query to
    /// those calibre_ids (one `json_each` binding, see `SQLIDList`). It is a
    /// hint for the contains/startsWith scans only: on synthetic data a
    /// restricted `LIKE '%x%'` over a small id list was far faster than the
    /// unrestricted scan, while a restricted `=` was slower than its index
    /// seek (the caller, `TagRuleStrategy`, never asks for that). The rating
    /// range ops ignore it, so callers must still intersect the result.
    func bookTagMatchIDs(op: FilterOperator, terms: [String], tagType: String?,
                         coverage: Set<Int>? = nil,
                         restrictedTo: [Int]? = nil) throws -> Set<Int> {
        guard !terms.isEmpty else { return [] }

        // ratingAtMost/ratingAtLeast compare against AO3Rating's ordinal
        // hierarchy rather than a simple string match -- mirrors
        // FilterBuilder's own ao3TagFragment logic, just queried directly
        // against this table instead of built as a Calibre SQL fragment.
        if op == .ratingAtMost || op == .ratingAtLeast {
            guard let rating = AO3Rating(rawValue: terms[0]) else {
                return try bookTagMatchIDs(op: .equals, terms: terms, tagType: tagType)
            }
            if op == .ratingAtMost {
                let higher = rating.higherRatings
                if higher.isEmpty { return try coverage ?? calibreIDsWithBookTags() }
                let higherMatches = try bookTagMatchIDs(op: .equals, terms: higher.map(\.rawValue), tagType: tagType)
                return try (coverage ?? calibreIDsWithBookTags()).subtracting(higherMatches)
            } else {
                guard let myLevel = rating.level else {
                    return try bookTagMatchIDs(op: .equals, terms: terms, tagType: tagType)
                }
                let qualified = AO3Rating.allCases.filter { ($0.level ?? 0) >= myLevel }
                if qualified.isEmpty { return [] }
                return try bookTagMatchIDs(op: .equals, terms: qualified.map(\.rawValue), tagType: tagType)
            }
        }

        let matcher: String
        let args: [Binding?]
        switch op {
        case .contains, .notContains:
            matcher = terms.map { _ in "tag_name LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            args = terms.map { "%\(LibraryQueryHelpers.escapeLikePattern($0))%" as Binding? }
        case .startsWith:
            matcher = terms.map { _ in "tag_name LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            args = terms.map { "\(LibraryQueryHelpers.escapeLikePattern($0))%" as Binding? }
        case .equals, .notEquals:
            matcher = terms.map { _ in "tag_name = ?" }.joined(separator: " OR ")
            args = terms.map { $0 as Binding? }
        case .matchesWord:
            let escaped = terms.map { NSRegularExpression.escapedPattern(for: $0) }
            matcher = escaped.map { _ in "tag_name REGEXP ?" }.joined(separator: " OR ")
            args = escaped.map { "(?i)\\b\($0)\\b" as Binding? }
        case .matchesRegex:
            matcher = terms.map { _ in "tag_name REGEXP ?" }.joined(separator: " OR ")
            args = terms.map { $0 as Binding? }
        case .ratingAtMost, .ratingAtLeast:
            fatalError("handled above")
        }

        var allArgs = args
        var sql = "SELECT DISTINCT calibre_id FROM book_tags WHERE (\(matcher))"
        if let tagType {
            sql += " AND tag_type = ?"
            allArgs.append(tagType)
        }
        if let restrictedTo {
            if restrictedTo.isEmpty { return [] }
            sql += " AND " + SQLIDList.clause(column: "calibre_id")
            allArgs.append(SQLIDList.binding(restrictedTo))
        }
        let rows = try prepare(sql, allArgs)
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

    /// Prunes extraction diagnostics for books that have now succeeded extraction (present in `ao3_metadata`).
    func pruneResolvedDiagnostics() throws {
        try run("""
            DELETE FROM ao3_extraction_diagnostics
            WHERE calibre_id IN (SELECT calibre_id FROM ao3_metadata);
            """)
    }

    /// Fetches all stored extraction diagnostics, optionally filtering to failures only.
    func allAO3Diagnostics(failedOnly: Bool = false) throws -> [AO3ExtractionDiagnostic] {
        let condition = failedOnly ? "WHERE status = 'failed' OR reason LIKE '%error%'" : ""
        let sql = """
        SELECT calibre_id, status, reason, epub_path, epub_filename, spine_items_checked, attempted_at
        FROM ao3_extraction_diagnostics
        \(condition)
        ORDER BY calibre_id ASC
        """
        var result: [AO3ExtractionDiagnostic] = []
        for row in try prepare(sql) {
            guard let id = row.int(at: 0),
                  let status = row[safe: 1] as? String,
                  let reason = row[safe: 2] as? String,
                  let attemptedAt = row[safe: 6] as? String else { continue }
            result.append(AO3ExtractionDiagnostic(
                calibreID: id,
                status: status,
                reason: reason,
                epubPath: row[safe: 3] as? String,
                epubFilename: row[safe: 4] as? String,
                spineItemsChecked: row.int(at: 5),
                attemptedAt: attemptedAt
            ))
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
               ao3_collections_json, series_json, rating, warnings_json, extracted_at, is_restricted
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
                extractedAt: extractedAt,
                isRestricted: row.int(at: 22).map { $0 != 0 }
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
             ao3_collections_json, series_json, rating, warnings_json, extracted_at, is_restricted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                metadata.isRestricted.map { $0 ? 1 : 0 }
            ]
        )

        try run("DELETE FROM series_cache WHERE calibre_id = ?", [calibreID])
        try run("DELETE FROM ao3_extraction_diagnostics WHERE calibre_id = ?", [calibreID])
        ao3DiagnosticsCache[calibreID] = nil
        try invalidateSeriesSeedMarker()
        for entry in metadata.series where !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let seriesID = try resolveSeriesID(name: entry.name, ao3ID: entry.ao3ID, calibreSeriesID: nil)
            try run(
                """
                INSERT OR REPLACE INTO series_cache
                (calibre_id, series_id, series_index, is_anthology)
                VALUES (?, ?, ?, 0)
                """,
                [calibreID, seriesID, entry.index]
            )
        }
    }

    /// §4.2 (Phase 3): writes one book's `book_authors` rows, replacing any
    /// existing set for that calibre_id -- called inside `insertBatch`'s
    /// transaction alongside `writeAO3Metadata`, so a partial-batch failure
    /// can't leave `ao3_metadata` and `book_authors` out of sync for the same
    /// book. `name` is `pseud ?? username` -- the same display-name
    /// derivation `author_names_json` above already uses; reused verbatim
    /// rather than re-derived, per the plan's explicit decision (§4.1).
    private func writeBookAuthors(_ authors: [AO3AuthorEntry], calibreID: Int) throws {
        try run("DELETE FROM book_authors WHERE calibre_id = ?", [calibreID])
        for (index, author) in authors.enumerated() {
            try run(
                """
                INSERT OR REPLACE INTO book_authors
                (calibre_id, name, source, sort_order)
                VALUES (?, ?, ?, ?)
                """,
                [calibreID, author.pseud ?? author.username, author.source.rawValue, index]
            )
        }
    }

    /// Phase 4 (§5.3): (calibre_id, tag_name, tag_type) rows for one book,
    /// sourced directly from `AO3MetadataRecord`'s already-typed fields (no
    /// string-matching heuristic at insert time, unlike today's row-render
    /// classification via `AO3TagKind.classify()`). `rating` is a scalar
    /// field on the record rather than an array, so it gets at most one row.
    private func writeBookTags(_ metadata: AO3MetadataRecord, calibreID: Int) throws {
        try run("DELETE FROM book_tags WHERE calibre_id = ?", [calibreID])
        func insertAll(_ names: [String], type: String) throws {
            for name in names where !name.isEmpty {
                try run(
                    "INSERT OR REPLACE INTO book_tags (calibre_id, tag_name, tag_type) VALUES (?, ?, ?)",
                    [calibreID, name, type]
                )
            }
        }
        try insertAll(metadata.fandoms, type: "fandom")
        try insertAll(metadata.relationships, type: "relationship")
        try insertAll(metadata.characters, type: "character")
        try insertAll(metadata.additionalTags, type: "freeform")
        try insertAll(metadata.categories, type: "category")
        try insertAll(metadata.warnings, type: "warning")
        if let rating = metadata.rating, !rating.isEmpty {
            try insertAll([rating], type: "rating")
        }
        bookTagsRevision &+= 1
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
                diagnostic.attemptedAt
            ]
        )
    }

    /// Writes one `book_index` row without opening its own transaction — same
    /// reason as `writeAO3Metadata`/`writeAO3Diagnostic`: `insertBatch` calls
    /// this directly inside its own single transaction (§7.3).
    private func writeBookIndex(_ record: BookIndexRecord, calibreID: Int) throws {
        try run(
            """
            INSERT OR REPLACE INTO book_index
            (calibre_id, title, description, word_count, pub_date, publisher, subject, indexed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                calibreID,
                record.title,
                record.description,
                record.wordCount,
                record.pubDate,
                record.publisher,
                record.subject,
                record.indexedAt
            ]
        )
    }

    private func invalidateBookIndexCaches(for calibreID: Int) {
        bookIndexCache[calibreID] = nil
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
    func insertBatch(_ records: [(AO3MetadataRecord, Int)],
                     diagnostics: [AO3ExtractionDiagnostic],
                     indexed: [(BookIndexRecord, Int)] = []) throws {
        try transaction {
            for (metadata, calibreID) in records {
                try writeAO3Metadata(metadata, calibreID: calibreID)
                try writeBookAuthors(metadata.authors, calibreID: calibreID)
                try writeBookTags(metadata, calibreID: calibreID)
            }
            for diagnostic in diagnostics {
                try writeAO3Diagnostic(diagnostic)
            }
            for (record, calibreID) in indexed {
                try writeBookIndex(record, calibreID: calibreID)
            }
        }
        for (_, calibreID) in records {
            invalidateAO3MetadataCaches(for: calibreID)
        }
        for diagnostic in diagnostics {
            ao3DiagnosticsCache[diagnostic.calibreID] = nil
        }
        for (_, calibreID) in indexed {
            invalidateBookIndexCaches(for: calibreID)
        }
    }

    func clearAO3Metadata() throws {
        try transaction {
            try run("DELETE FROM ao3_metadata")
            try run("DELETE FROM ao3_extraction_diagnostics")
            try run("DELETE FROM series_cache")
            try run("DELETE FROM book_authors")
            try invalidateSeriesSeedMarker()
            try removeLibraryState(LibraryStateKey.extractionScanFingerprint)
        }
        ao3MetadataCache.removeAll()
        ao3DiagnosticsCache.removeAll()
        seriesEntriesCache.removeAll()
        seriesEntriesByKeyCache.removeAll()
        singletonWarningsCache.removeAll()
    }

    func collectUnreferencedSeries() throws {
        try run("""
            DELETE FROM series
            WHERE NOT EXISTS (SELECT 1 FROM series_cache WHERE series_cache.series_id = series.series_id)
              AND NOT EXISTS (SELECT 1 FROM series_collection_members
                              WHERE series_collection_members.series_id = series.series_id)
            """)
        seriesEntriesCache.removeAll()
        seriesEntriesByKeyCache.removeAll()
        singletonWarningsCache.removeAll()
    }

    func hasSeriesFlags() throws -> Bool {
        if let hasSeriesFlagsCache { return hasSeriesFlagsCache }
        let count = (try scalar("SELECT COUNT(*) FROM series_collection_members")) as? Int64 ?? 0
        let result = count > 0
        hasSeriesFlagsCache = result
        return result
    }

    func invalidateSeriesFlagsCache() {
        hasSeriesFlagsCache = nil
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
        SELECT m.calibre_id, s.name, m.series_index, s.ao3_series_id,
               m.is_anthology, s.calibre_series_id, s.series_id, s.series_key
        FROM series_cache m JOIN series s ON s.series_id = m.series_id
        WHERE m.calibre_id IN (\(placeholders))
        ORDER BY s.name, m.series_index
        """
        return try prepare(sql, calibreIDs.map { $0 as Binding? }).compactMap { row in
            guard let calibreID = row.int(at: 0),
                  let seriesName = row[safe: 1] as? String,
                  let seriesIndex = row.int(at: 2) else { return nil }
            return SeriesCacheEntry(
                seriesID: row.int(at: 6),
                calibreID: calibreID,
                seriesName: seriesName,
                seriesIndex: seriesIndex,
                ao3SeriesID: row[safe: 3] as? String,
                isAnthology: (row.int(at: 4) ?? 0) != 0,
                calibreSeriesID: row.int(at: 5),
                seriesKey: row[safe: 7] as? String
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
        SELECT m.calibre_id, s.name, m.series_index, s.ao3_series_id,
               m.is_anthology, s.calibre_series_id, s.series_id, s.series_key
        FROM series_cache m JOIN series s ON s.series_id = m.series_id
        WHERE s.series_key IN (\(placeholders))
        ORDER BY s.name, m.series_index
        """
        return try prepare(sql, keys.map { $0 as Binding? }).compactMap { row in
            guard let calibreID = row.int(at: 0),
                  let seriesName = row[safe: 1] as? String,
                  let seriesIndex = row.int(at: 2) else { return nil }
            return SeriesCacheEntry(
                seriesID: row.int(at: 6),
                calibreID: calibreID,
                seriesName: seriesName,
                seriesIndex: seriesIndex,
                ao3SeriesID: row[safe: 3] as? String,
                isAnthology: (row.int(at: 4) ?? 0) != 0,
                calibreSeriesID: row.int(at: 5),
                seriesKey: row[safe: 7] as? String
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
        let args: [Binding?] = [SQLIDList.binding(calibreIDs)]
        let sql = """
        WITH keyed AS (
            SELECT m.calibre_id, s.series_id, m.is_anthology
            FROM series_cache m JOIN series s ON s.series_id = m.series_id
        ),
        matched_keys AS (
            SELECT DISTINCT series_id FROM keyed WHERE \(SQLIDList.clause(column: "calibre_id"))
        ),
        qualifying_keys AS (
            SELECT series_id
            FROM keyed
            GROUP BY series_id
            HAVING COUNT(*) > 1 AND MAX(is_anthology) = 0
        )
        SELECT calibre_id
        FROM keyed
        WHERE series_id IN (SELECT series_id FROM matched_keys)
          AND series_id IN (SELECT series_id FROM qualifying_keys)
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
        let args: [Binding?] = [SQLIDList.binding(calibreIDs)]
        let sql = """
        WITH keyed AS (
            SELECT m.calibre_id, s.name AS series_name, s.series_key, s.series_id, m.is_anthology
            FROM series_cache m JOIN series s ON s.series_id = m.series_id
        ),
        qualifying_keys AS (
            SELECT series_id
            FROM keyed
            GROUP BY series_id
            HAVING COUNT(*) > 1 AND MAX(is_anthology) = 0
        )
        SELECT calibre_id, series_name
        FROM keyed
        WHERE \(SQLIDList.clause(column: "calibre_id"))
          AND series_id IN (SELECT series_id FROM qualifying_keys)
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
            SELECT m.calibre_id, s.name AS series_name, m.series_index, m.is_anthology,
                   s.series_id,
                   s.series_key AS series_key,
                   COUNT(*) OVER (
                       PARTITION BY s.series_id
                   ) AS series_count,
                   MAX(is_anthology) OVER (
                       PARTITION BY s.series_id
                   ) AS anthology
            FROM series_cache m JOIN series s ON s.series_id = m.series_id
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

    /// Inserts Calibre-derived fallback memberships for books that have no
    /// series membership yet. The guard prevents a Calibre fallback from
    /// adding an unrelated second membership after AO3 extraction.
    func insertCalibreSeriesFallback(_ entries: [SeriesCacheWriteInput]) throws {
        guard !entries.isEmpty else { return }
        try transaction {
            for entry in entries {
                let seriesID = try resolveSeriesID(name: entry.seriesName,
                                                   ao3ID: entry.ao3SeriesID,
                                                   calibreSeriesID: entry.calibreSeriesID)
                try run(
                    """
                    INSERT INTO series_cache
                    (calibre_id, series_id, series_index, is_anthology)
                    SELECT ?, ?, ?, ?
                    WHERE NOT EXISTS (
                        SELECT 1 FROM series_cache WHERE calibre_id = ?
                    )
                    """,
                    [
                        entry.calibreID,
                        seriesID,
                        entry.seriesIndex,
                        entry.isAnthology ? 1 : 0,
                        entry.calibreID
                    ]
                )
            }
        }
        // Both the insert and the backfill above only ever touch rows for
        // calibreIDs present in `entries`; conservatively evict all of them
        // along with the by-key/singleton caches they can affect.
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
        SELECT s.series_key, COUNT(*) AS member_count
        FROM series_cache m JOIN series s ON s.series_id = m.series_id
        GROUP BY s.series_id
        ORDER BY member_count DESC
        LIMIT 5
        """
        let totalRows: Int? = (try? prepare("SELECT COUNT(*) FROM series_cache").first)?.int(at: 0)
        let distinctKeys: Int? = (try? prepare("""
            SELECT COUNT(DISTINCT s.series_id)
            FROM series_cache m JOIN series s ON s.series_id = m.series_id
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
               series_id,
               ROW_NUMBER() OVER (
                   PARTITION BY series_id
                   ORDER BY series_index ASC, calibre_id ASC
               ) AS rn,
               COUNT(*) OVER (
                   PARTITION BY series_id
               ) AS series_count,
               MAX(is_anthology) OVER (
                   PARTITION BY series_id
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
        let sql = """
            SELECT je.value AS name, COUNT(*) AS cnt
            FROM ao3_metadata, json_each(ao3_metadata.\(field.jsonColumn)) AS je
            WHERE \(SQLIDList.clause(column: "ao3_metadata.calibre_id"))
            GROUP BY je.value
            ORDER BY cnt DESC
            LIMIT ?
            """
        let bindings: [Binding?] = [SQLIDList.binding(ids), limit as Binding?]
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
        let sql = """
            SELECT rating, COUNT(*) AS cnt
            FROM ao3_metadata
            WHERE \(SQLIDList.clause(column: "calibre_id")) AND rating IS NOT NULL
            GROUP BY rating
            ORDER BY cnt DESC
            """
        let bindings: [Binding?] = [SQLIDList.binding(ids)]
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

    // MARK: - Canonical Facets (Zero-Inflation Tag Deduplication)

    /// Top-N canonical tag values by distinct book count, scoped to `ids`.
    ///
    /// For tag fields, groups by `COALESCE(tag_canonical_map.canonical_name, book_tags.tag_name)`
    /// and aggregates `COUNT(DISTINCT book_tags.calibre_id)`, ensuring books carrying multiple
    /// synonyms of the same canonical tag are counted strictly once, and top-N ranking is
    /// evaluated after canonical merging.
    /// Falls back to `topFacets(for:scopedTo:limit:)` for author facets or if `tagType` is nil.
    func canonicalFacets(for field: AO3FacetField, scopedTo ids: [Int], limit: Int = 10) -> [(name: String, count: Int)] {
        guard !ids.isEmpty else { return [] }
        guard let tagType = field.tagType else {
            return topFacets(for: field, scopedTo: ids, limit: limit)
        }

        _ = try? syncTagCanonicalMapIfNeeded()

        let sql = """
            SELECT COALESCE(m.canonical_name, bt.tag_name) AS name, COUNT(DISTINCT bt.calibre_id) AS cnt
            FROM json_each(?) j
            JOIN book_tags bt ON bt.calibre_id = j.value AND bt.tag_type = ?
            LEFT JOIN tag_canonical_map m ON m.tag_name = bt.tag_name
            GROUP BY name
            ORDER BY cnt DESC
            LIMIT ?
            """
        let bindings: [Binding?] = [SQLIDList.binding(ids), tagType as Binding?, limit as Binding?]
        guard let rows = try? readDB.prepare(sql, bindings).map({ $0 }) else {
            return topFacets(for: field, scopedTo: ids, limit: limit)
        }
        return rows.compactMap { row in
            guard let name = row[0] as? String else { return nil }
            let count = (row[1] as? Int64).map(Int.init) ?? (row[1] as? Int) ?? 0
            return (name, count)
        }
    }

    /// Unconstrained counterpart to `canonicalFacets(for:scopedTo:limit:)`.
    ///
    /// Scans the entire library for `field`, grouping by canonical tag name and counting distinct
    /// books. Used when no filter or search is active.
    func canonicalFacetsUnconstrained(for field: AO3FacetField, limit: Int = 10) -> [(name: String, count: Int)] {
        guard let tagType = field.tagType else {
            return topFacetsUnconstrained(for: field, limit: limit)
        }

        _ = try? syncTagCanonicalMapIfNeeded()

        let sql = """
            SELECT COALESCE(m.canonical_name, bt.tag_name) AS name, COUNT(DISTINCT bt.calibre_id) AS cnt
            FROM book_tags bt
            LEFT JOIN tag_canonical_map m ON m.tag_name = bt.tag_name
            WHERE bt.tag_type = ?
            GROUP BY name
            ORDER BY cnt DESC
            LIMIT ?
            """
        let bindings: [Binding?] = [tagType as Binding?, limit as Binding?]
        guard let rows = try? readDB.prepare(sql, bindings).map({ $0 }) else {
            return topFacetsUnconstrained(for: field, limit: limit)
        }
        return rows.compactMap { row in
            guard let name = row[0] as? String else { return nil }
            let count = (row[1] as? Int64).map(Int.init) ?? (row[1] as? Int) ?? 0
            return (name, count)
        }
    }

    // MARK: - Tag Position Extraction for Relevance Sorting (JSON Pushdown)

    /// Finds the earliest (lowest index) tag position per book for the given target tags
    /// across relationships (roleRank 0), characters (1), fandoms (2), and freeform tags (3).
    ///
    /// Option 2 (JSON pushdown): Uses SQLite's JSON1 `json_each` over `ao3_metadata` columns
    /// without schema migration. Requires zero extra storage.
    func firstListedPositions(
        exactTargets: [String],
        containsTargets: [String] = [],
        bookIDs: [Int]
    ) -> [Int: TagPosition] {
        guard !bookIDs.isEmpty && (!exactTargets.isEmpty || !containsTargets.isEmpty) else {
            return [:]
        }

        var cteParts: [String] = []
        var allBindings: [Binding?] = []

        cteParts.append("""
            matched_books AS MATERIALIZED (
                SELECT calibre_id, relationships_json, characters_json, fandoms_json, additional_tags_json
                FROM ao3_metadata
                WHERE ao3_metadata.calibre_id IN (SELECT value FROM json_each(?))
            )
        """)
        allBindings.append(SQLIDList.binding(bookIDs))

        var tagClauses: [String] = []
        if !exactTargets.isEmpty {
            cteParts.append("target_exact AS MATERIALIZED (SELECT lower(value) AS tag FROM json_each(?))")
            let json = (try? String(data: JSONSerialization.data(withJSONObject: exactTargets), encoding: .utf8)) ?? "[]"
            allBindings.append(json as Binding?)
            tagClauses.append("lower(je.value) IN (SELECT tag FROM target_exact)")
        }

        if !containsTargets.isEmpty {
            cteParts.append("target_contains AS MATERIALIZED (SELECT lower(value) AS pattern FROM json_each(?))")
            let json = (try? String(data: JSONSerialization.data(withJSONObject: containsTargets), encoding: .utf8)) ?? "[]"
            allBindings.append(json as Binding?)
            tagClauses.append("EXISTS (SELECT 1 FROM target_contains WHERE instr(lower(je.value), pattern) > 0)")
        }

        let tagCondition = tagClauses.joined(separator: " OR ")

        let facets: [(column: String, roleRank: Int)] = [
            ("relationships_json", 0),
            ("characters_json", 1),
            ("fandoms_json", 2),
            ("additional_tags_json", 3)
        ]

        var unionParts: [String] = []
        for facet in facets {
            let part = """
                SELECT calibre_id, \(facet.roleRank) AS role_rank, je.key AS pos
                FROM matched_books, json_each(CASE WHEN json_valid(matched_books.\(facet.column)) THEN matched_books.\(facet.column) ELSE '[]' END) AS je
                WHERE matched_books.\(facet.column) IS NOT NULL
                  AND matched_books.\(facet.column) NOT IN ('', '[]')
                  AND (\(tagCondition))
                """
            unionParts.append(part)
        }

        let fullSQL = """
            WITH \(cteParts.joined(separator: ",\n"))
            SELECT calibre_id, MIN(role_rank * 1000000 + pos) AS best_pos
            FROM (
                \(unionParts.joined(separator: "\nUNION ALL\n"))
            )
            GROUP BY calibre_id
            """

        do {
            var result: [Int: TagPosition] = [:]
            result.reserveCapacity(bookIDs.count)
            for row in try readDB.prepare(fullSQL, allBindings) {
                guard let bookID = (row[0] as? Int64).map(Int.init),
                      let encoded = (row[1] as? Int64).map(Int.init) else { continue }
                let roleRank = encoded / 1_000_000
                let index = encoded % 1_000_000
                result[bookID] = TagPosition(roleRank: roleRank, index: index)
            }
            return result
        } catch {
            _ = try? logError(
                subsystem: "relevance",
                operation: "firstListedPositions",
                message: "Failed to query firstListedPositions: \(error.localizedDescription)"
            )
            return [:]
        }
    }

    /// Convenience overload accepting a single list of target tags (treated as exact tags).
    func firstListedPositions(targets: [String], bookIDs: [Int]) -> [Int: TagPosition] {
        firstListedPositions(exactTargets: targets, containsTargets: [], bookIDs: bookIDs)
    }

    // MARK: - Listed Role Position Evaluation & Coverage

    private struct ListedNameIndexCache {
        var revision: Int
        var level0: [String: Set<String>]
        var level1: [String: Set<String>]
    }

    private var listedNameIndices: [ListedRole: ListedNameIndexCache] = [:]
    private var listedRoleCoverageCache: [ListedRole: (revision: Int, ids: Set<Int>)] = [:]
    private var rawRelationshipCountsCache: (revision: Int, counts: [Int: Int])?
    private var variantRelationshipCountsCache: (revision: Int, counts: [Int: Int])?
    static let relationshipCountDedupeCap = 8

    private func nameIndex(for role: ListedRole) -> (level0: [String: Set<String>], level1: [String: Set<String>]) {
        if let cached = listedNameIndices[role], cached.revision == bookTagsRevision {
            return (cached.level0, cached.level1)
        }
        let sql = "SELECT tag_name FROM book_tags WHERE tag_type = ? GROUP BY tag_name"
        var l0: [String: Set<String>] = [:]
        var l1: [String: Set<String>] = [:]
        if let rows = try? readDB.prepare(sql, [role.dbTagType as Binding?]) {
            for row in rows {
                guard let name = row[0] as? String, !name.isEmpty else { continue }
                let k0 = name.lowercased()
                l0[k0, default: []].insert(name)
                let k1 = TagVariantKey.key(for: name)
                if !k1.isEmpty {
                    l1[k1, default: []].insert(name)
                }
            }
        }
        listedNameIndices[role] = ListedNameIndexCache(revision: bookTagsRevision, level0: l0, level1: l1)
        return (l0, l1)
    }

    func listedPositionMembers(
        role: ListedRole,
        terms: [String],
        limit: Int,
        variants: Bool = false
    ) -> Set<Int> {
        guard !terms.isEmpty && limit >= 1 else { return [] }
        let index = nameIndex(for: role)
        var resolvedNames = Set<String>()
        for term in terms {
            let k0 = term.lowercased()
            if let matches = index.level0[k0] {
                resolvedNames.formUnion(matches)
            }
            if variants {
                let k1 = TagVariantKey.key(for: term)
                if let vMatches = index.level1[k1] {
                    resolvedNames.formUnion(vMatches)
                }
            }
            resolvedNames.insert(term)
        }
        guard !resolvedNames.isEmpty else { return [] }

        let namesJSON = (try? String(data: JSONSerialization.data(withJSONObject: Array(resolvedNames)), encoding: .utf8)) ?? "[]"
        let candidateSQL = """
            SELECT DISTINCT calibre_id FROM book_tags
            WHERE tag_type = ? AND tag_name IN (SELECT value FROM json_each(?))
            """
        guard let candidateRows = try? readDB.prepare(candidateSQL, [role.dbTagType as Binding?, namesJSON as Binding?]) else {
            return []
        }
        var candidateIDs: [Int] = []
        for row in candidateRows {
            if let id = (row[0] as? Int64).map(Int.init) {
                candidateIDs.append(id)
            }
        }
        guard !candidateIDs.isEmpty else { return [] }

        let positionSQL = """
            SELECT m.calibre_id, je.value
            FROM ao3_metadata m,
                 json_each(CASE WHEN json_valid(m.\(role.jsonColumn)) THEN m.\(role.jsonColumn) ELSE '[]' END) je
            WHERE m.calibre_id IN (SELECT value FROM json_each(?))
              AND je.key < ?
            """
        let bindings: [Binding?] = [SQLIDList.binding(candidateIDs), limit as Binding?]
        guard let posRows = try? readDB.prepare(positionSQL, bindings) else {
            return []
        }

        let lowerResolved = Set(resolvedNames.map { $0.lowercased() })
        let variantResolved: Set<String> = variants ? Set(resolvedNames.map { TagVariantKey.key(for: $0) }) : []
        var matchedIDs = Set<Int>()
        for row in posRows {
            guard let bookID = (row[0] as? Int64).map(Int.init),
                  let val = row[1] as? String else { continue }
            if resolvedNames.contains(val) || lowerResolved.contains(val.lowercased()) {
                matchedIDs.insert(bookID)
            } else if variants && variantResolved.contains(TagVariantKey.key(for: val)) {
                matchedIDs.insert(bookID)
            }
        }
        return matchedIDs
    }

    func listedRoleCoverage(role: ListedRole) -> Set<Int> {
        if let cached = listedRoleCoverageCache[role], cached.revision == bookTagsRevision {
            return cached.ids
        }
        let sql = """
            SELECT calibre_id FROM ao3_metadata
            WHERE (CASE WHEN json_valid(\(role.jsonColumn)) THEN json_array_length(\(role.jsonColumn)) ELSE 0 END) > 0
            """
        guard let rows = try? readDB.prepare(sql) else { return [] }
        var ids = Set<Int>()
        for row in rows {
            if let id = (row[0] as? Int64).map(Int.init) {
                ids.insert(id)
            }
        }
        listedRoleCoverageCache[role] = (bookTagsRevision, ids)
        return ids
    }

    /// Evaluates `relationshipCount` filter rules, returning all calibre IDs whose
    /// relationship count equals `value`.
    /// When `variants` is false, uses raw array length.
    /// When `variants` is true, canonicalizes and normalizes relationship tags for works
    /// with at most `relationshipCountDedupeCap` (8) relationships, counting distinct tags.
    func relationshipCountMembers(value: Int, variants: Bool) -> Set<Int> {
        guard value >= 1 else { return [] }
        let counts = variants ? variantRelationshipCounts() : rawRelationshipCounts()
        var result = Set<Int>()
        for (id, count) in counts where count == value {
            result.insert(id)
        }
        return result
    }

    private func rawRelationshipCounts() -> [Int: Int] {
        if let cached = rawRelationshipCountsCache, cached.revision == bookTagsRevision {
            return cached.counts
        }
        let sql = """
            SELECT calibre_id,
                   CASE WHEN json_valid(relationships_json) THEN json_array_length(relationships_json) ELSE 0 END
            FROM ao3_metadata
            """
        guard let rows = try? readDB.prepare(sql) else { return [:] }
        var counts: [Int: Int] = [:]
        for row in rows {
            guard let id = (row[0] as? Int64).map(Int.init),
                  let count = (row[1] as? Int64).map(Int.init) ?? (row[1] as? Int) else { continue }
            if count > 0 {
                counts[id] = count
            }
        }
        rawRelationshipCountsCache = (bookTagsRevision, counts)
        return counts
    }

    private func variantRelationshipCounts() -> [Int: Int] {
        if let cached = variantRelationshipCountsCache, cached.revision == bookTagsRevision {
            return cached.counts
        }
        let rawCounts = rawRelationshipCounts()
        var variantCounts: [Int: Int] = [:]
        variantCounts.reserveCapacity(rawCounts.count)

        for (id, rawCount) in rawCounts where rawCount > Self.relationshipCountDedupeCap {
            variantCounts[id] = rawCount
        }

        let sql = """
            SELECT calibre_id, relationships_json
            FROM ao3_metadata
            WHERE json_valid(relationships_json)
              AND json_array_length(relationships_json) BETWEEN 1 AND ?
            """
        if let rows = try? readDB.prepare(sql, [Self.relationshipCountDedupeCap as Binding?]) {
            var bookTagsList: [(id: Int, tags: [String])] = []
            var allUniqueTags = Set<String>()
            for row in rows {
                guard let id = (row[0] as? Int64).map(Int.init),
                      let jsonString = row[1] as? String,
                      let data = jsonString.data(using: .utf8),
                      let tags = try? JSONSerialization.jsonObject(with: data) as? [String] else { continue }
                bookTagsList.append((id: id, tags: tags))
                for tag in tags {
                    allUniqueTags.insert(tag)
                }
            }

            let canonicalMap = AO3TagSeedDatabaseConfig.shared.canonicalTagsBatch(for: Array(allUniqueTags))
            for item in bookTagsList {
                var distinctKeys = Set<String>()
                for tag in item.tags {
                    let canonical = canonicalMap[tag] ?? tag
                    distinctKeys.insert(TagVariantKey.key(for: canonical))
                }
                variantCounts[item.id] = distinctKeys.count
            }
        }

        variantRelationshipCountsCache = (bookTagsRevision, variantCounts)
        return variantCounts
    }

    /// Returns a mapping of tag_name -> Set<SuggestionTagType> for the given tag names.
    func tagRoles(for names: [String]) -> [String: Set<SuggestionTagType>] {
        guard !names.isEmpty else { return [:] }
        let namesJSON = (try? String(data: JSONSerialization.data(withJSONObject: names), encoding: .utf8)) ?? "[]"
        let sql = """
            SELECT tag_name, tag_type FROM book_tags
            WHERE tag_name IN (SELECT value FROM json_each(?))
            GROUP BY tag_name, tag_type
            """
        guard let rows = try? readDB.prepare(sql, [namesJSON as Binding?]) else { return [:] }
        var result: [String: Set<SuggestionTagType>] = [:]
        for row in rows {
            guard let name = row[0] as? String,
                  let rawType = row[1] as? String else { continue }
            let role = SuggestionTagType.from(rawType: rawType)
            if role != .unknown {
                result[name, default: []].insert(role)
            }
        }
        return result
    }

    /// Convenience lookup for a single tag name's roles.
    func tagRoles(for tagName: String) -> Set<SuggestionTagType> {
        let trimmed = tagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return tagRoles(for: [trimmed])[trimmed] ?? []
    }

    /// Returns a mapping of tag_name -> SuggestionTagType for all tags in book_tags.
    /// Used by SuggestionSnapshotBuilder to layer AO3 tag classifications onto Calibre tags.
    func allTagTypes() -> [String: SuggestionTagType] {
        let sql = "SELECT tag_name, tag_type FROM book_tags GROUP BY tag_name, tag_type"
        guard let rows = try? readDB.prepare(sql).map({ $0 }) else { return [:] }
        var result: [String: SuggestionTagType] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let name = row[0] as? String, let rawType = row[1] as? String else { continue }
            let tagType = SuggestionTagType.from(rawType: rawType)
            if tagType != .unknown {
                result[name] = tagType
            }
        }
        return result
    }

    /// Contextual tag search for autocomplete and tag selection popovers.
    /// Fast indexed lookup over `book_tags` / `book_authors` with fallback to `ao3_metadata`.
    func searchTags(
        query: String,
        field: AO3FacetField,
        fandomContext: [String] = [],
        limit: Int = 20
    ) -> [(name: String, count: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if field == .author {
            let hasBookAuthors = (try? readDB.scalar("SELECT 1 FROM book_authors LIMIT 1") as? Int64) != nil
            if hasBookAuthors {
                var conditions: [String] = []
                var bindings: [Binding?] = []
                if !trimmed.isEmpty {
                    conditions.append("name LIKE ?")
                    bindings.append("%\(trimmed)%")
                }
                if !fandomContext.isEmpty {
                    let placeholders = fandomContext.map { _ in "?" }.joined(separator: ", ")
                    conditions.append("""
                        calibre_id IN (
                            SELECT calibre_id FROM book_tags
                            WHERE tag_type = 'fandom' AND tag_name IN (\(placeholders))
                        )
                    """)
                    bindings.append(contentsOf: fandomContext.map { $0 as Binding? })
                }
                let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
                let sql = """
                    SELECT name, COUNT(*) AS cnt
                    FROM book_authors
                    \(whereClause)
                    GROUP BY name
                    ORDER BY cnt DESC
                    LIMIT ?
                    """
                bindings.append(limit as Binding?)
                if let rows = try? readDB.prepare(sql, bindings).map({ $0 }) {
                    return rows.compactMap { row in
                        guard let name = row[0] as? String else { return nil }
                        let count = (row[1] as? Int64).map(Int.init) ?? (row[1] as? Int) ?? 0
                        return (name, count)
                    }
                }
                return []
            }

            // Fallback to ao3_metadata JSON column ONLY if book_authors table is empty
            let jsonSQL = """
                SELECT je.value AS name, COUNT(*) AS cnt
                FROM ao3_metadata, json_each(ao3_metadata.author_names_json) AS je
                WHERE je.value LIKE ?
                GROUP BY je.value
                ORDER BY cnt DESC
                LIMIT ?
                """
            let jsonBindings: [Binding?] = ["%\(trimmed)%", limit as Binding?]
            guard let rows = try? readDB.prepare(jsonSQL, jsonBindings).map({ $0 }) else { return [] }
            return rows.compactMap { row in
                guard let name = row[0] as? String else { return nil }
                let count = (row[1] as? Int64).map(Int.init) ?? (row[1] as? Int) ?? 0
                return (name, count)
            }
        }

        let hasBookTags = (try? readDB.scalar("SELECT 1 FROM book_tags LIMIT 1") as? Int64) != nil
        if hasBookTags {
            var conditions: [String] = ["bt.tag_type = ?"]
            var bindings: [Binding?] = [field.rawValue]
            if !trimmed.isEmpty {
                let entities = (field == .relationship) ? RelationshipQuery.splitEntities(trimmed) : [trimmed]
                for entity in entities where !entity.isEmpty {
                    let escaped = entity
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "%", with: "\\%")
                        .replacingOccurrences(of: "_", with: "\\_")
                    conditions.append("bt.tag_name LIKE ? ESCAPE '\\'")
                    bindings.append("%\(escaped)%")
                }
            }
            if !fandomContext.isEmpty && field != .fandom {
                let placeholders = fandomContext.map { _ in "?" }.joined(separator: ", ")
                conditions.append("""
                    bt.calibre_id IN (
                        SELECT calibre_id FROM book_tags
                        WHERE tag_type = 'fandom' AND tag_name IN (\(placeholders))
                    )
                """)
                bindings.append(contentsOf: fandomContext.map { $0 as Binding? })
            }
            let whereClause = "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT bt.tag_name, COUNT(*) AS cnt
                FROM book_tags bt
                \(whereClause)
                GROUP BY bt.tag_name
                ORDER BY cnt DESC
                LIMIT ?
                """
            bindings.append(limit as Binding?)
            if let rows = try? readDB.prepare(sql, bindings).map({ $0 }) {
                return rows.compactMap { row in
                    guard let name = row[0] as? String else { return nil }
                    let count = (row[1] as? Int64).map(Int.init) ?? (row[1] as? Int) ?? 0
                    return (name, count)
                }
            }
            return []
        }

        // Fallback to ao3_metadata JSON column ONLY if book_tags is not populated
        let jsonSQL = """
            SELECT je.value AS name, COUNT(*) AS cnt
            FROM ao3_metadata, json_each(ao3_metadata.\(field.jsonColumn)) AS je
            WHERE je.value LIKE ?
            GROUP BY je.value
            ORDER BY cnt DESC
            LIMIT ?
            """
        let jsonBindings: [Binding?] = ["%\(trimmed)%", limit as Binding?]
        guard let rows = try? readDB.prepare(jsonSQL, jsonBindings).map({ $0 }) else { return [] }
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
            if let calibreID64 = row[0] as? Int64 { return Int(calibreID64) }
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
    /// otherwise returns `term` unchanged. Delegated directly to the shared
    /// `AO3TagSeedDatabaseConfig` read-only connection without duplicating seeds per library.
    func canonicalTerm(for term: String) -> String {
        AO3TagSeedDatabaseConfig.shared.canonicalTag(for: term)
    }

    /// Returns `term` plus all known synonyms. Returns `[term]` when no mapping exists
    /// or when AO3 tag seeds are disabled. Delegated directly to the shared
    /// `AO3TagSeedDatabaseConfig` read-only connection.
    func expandedTerms(for term: String) -> [String] {
        AO3TagSeedDatabaseConfig.shared.expandedTerms(for: term)
    }

    /// Batched form of `expandedTerms(for:)`. Returns a dictionary keyed by each
    /// input term mapping to its expanded term list. Delegated directly to the shared
    /// `AO3TagSeedDatabaseConfig` read-only connection.
    func expandedTermsBatch(for tags: [String]) -> [String: [String]] {
        AO3TagSeedDatabaseConfig.shared.expandedTermsBatch(for: tags)
    }

    /// Batched form of `canonicalTerm(for:)`. Returns a dictionary mapping each
    /// input tag to its canonical tag name (or the tag unchanged if unmapped).
    func canonicalTermsBatch(for tags: [String]) -> [String: String] {
        AO3TagSeedDatabaseConfig.shared.canonicalTagsBatch(for: tags)
    }

    // MARK: - Book State (Reading Progress & Position)

    public func bookState(for calibreID: Int) -> BookState {
        if let cached = bookStateCache[calibreID] { return cached }
        let state = fetchBookState(for: calibreID) ?? BookState(calibreID: calibreID)
        bookStateCache[calibreID] = state
        return state
    }

    public func bookStates(for calibreIDs: [Int]) -> [Int: BookState] {
        guard !calibreIDs.isEmpty else { return [:] }
        var result: [Int: BookState] = [:]
        var missingIDs: [Int] = []

        for id in calibreIDs {
            if let cached = bookStateCache[id] {
                result[id] = cached
            } else {
                missingIDs.append(id)
            }
        }

        if !missingIDs.isEmpty {
            let fetched = fetchBookStatesBatch(for: missingIDs)
            for id in missingIDs {
                let state = fetched[id] ?? BookState(calibreID: id)
                bookStateCache[id] = state
                result[id] = state
            }
        }

        return result
    }

    private func fetchBookState(for calibreID: Int) -> BookState? {
        let sql = """
        SELECT calibre_id, last_opened_date, total_read_percent, total_reading_time_seconds,
               last_spine_index, last_character_offset, last_scroll_offset, elo_score, elo_match_count
        FROM book_state WHERE calibre_id = ?
        """
        guard let row = (try? readDB.prepare(sql, [Int64(calibreID) as Binding?]).map({ $0 }))?.first else {
            return nil
        }
        return makeBookState(from: row)
    }

    private func fetchBookStatesBatch(for calibreIDs: [Int]) -> [Int: BookState] {
        var result: [Int: BookState] = [:]
        let chunkSize = 500
        for chunk in stride(from: 0, to: calibreIDs.count, by: chunkSize) {
            let slice = Array(calibreIDs[chunk..<min(chunk + chunkSize, calibreIDs.count)])
            let placeholders = slice.map { _ in "?" }.joined(separator: ",")
            let query = """
            SELECT calibre_id, last_opened_date, total_read_percent, total_reading_time_seconds,
                   last_spine_index, last_character_offset, last_scroll_offset, elo_score, elo_match_count
            FROM book_state WHERE calibre_id IN (\(placeholders))
            """
            let bindings: [Binding?] = slice.map { Int64($0) as Binding? }
            do {
                let rows = try readDB.prepare(query, bindings).map { $0 }
                for row in rows {
                    if let state = makeBookState(from: row) {
                        result[state.calibreID] = state
                    }
                }
            } catch {
                #if DEBUG
                print("[AmbrosiaMetaDB] Failed to batch fetch book states: \(error)")
                #endif
            }
        }
        return result
    }

    private func makeBookState(from row: Statement.Element) -> BookState? {
        guard let cid = row[0] as? Int64 else { return nil }
        let opened = row[1] as? Double ?? 0.0
        let percent = row[2] as? Double ?? 0.0
        let readingTime = row[3] as? Double ?? 0.0
        let spineIndex = row[4] as? Int64 ?? 0
        let charOffset = row[5] as? Int64 ?? 0
        let scrollOffset = row[6] as? Double ?? 0.0
        let eloScore = row[7] as? Double ?? 1000.0
        let eloMatches = row[8] as? Int64 ?? 0

        return BookState(
            calibreID: Int(cid),
            lastOpenedDate: Date(timeIntervalSince1970: opened),
            totalReadPercent: percent,
            totalReadingTimeSeconds: readingTime,
            lastSpineIndex: Int(spineIndex),
            lastCharacterOffset: Int(charOffset),
            lastScrollOffset: scrollOffset,
            eloScore: eloScore,
            eloMatchCount: Int(eloMatches)
        )
    }

    public func updateReadingPosition(
        calibreID: Int,
        spineIndex: Int,
        characterOffset: Int,
        scrollOffset: Double,
        readPercent: Double
    ) throws {
        let stmt = """
        INSERT INTO book_state (
            calibre_id, last_spine_index, last_character_offset, last_scroll_offset,
            total_read_percent, last_opened_date, updated_at
        ) VALUES (?, ?, ?, ?, ?, strftime('%s', 'now'), strftime('%s', 'now'))
        ON CONFLICT(calibre_id) DO UPDATE SET
            last_spine_index = excluded.last_spine_index,
            last_character_offset = excluded.last_character_offset,
            last_scroll_offset = excluded.last_scroll_offset,
            total_read_percent = MAX(book_state.total_read_percent, excluded.total_read_percent),
            last_opened_date = excluded.last_opened_date,
            updated_at = excluded.updated_at;
        """
        try db.run(stmt, calibreID, spineIndex, characterOffset, scrollOffset, readPercent)
        bookStateCache.removeValue(forKey: calibreID)
    }

    public func markBookOpened(calibreID: Int, date: Date = Date()) throws {
        let stmt = """
        INSERT INTO book_state (calibre_id, last_opened_date, updated_at)
        VALUES (?, ?, strftime('%s', 'now'))
        ON CONFLICT(calibre_id) DO UPDATE SET
            last_opened_date = excluded.last_opened_date,
            updated_at = excluded.updated_at;
        """
        try db.run(stmt, calibreID, date.timeIntervalSince1970)
        bookStateCache.removeValue(forKey: calibreID)
    }

    public func addReadingTime(calibreID: Int, seconds: TimeInterval) throws {
        let stmt = """
        INSERT INTO book_state (calibre_id, total_reading_time_seconds, updated_at)
        VALUES (?, ?, strftime('%s', 'now'))
        ON CONFLICT(calibre_id) DO UPDATE SET
            total_reading_time_seconds = book_state.total_reading_time_seconds + excluded.total_reading_time_seconds,
            updated_at = excluded.updated_at;
        """
        try db.run(stmt, calibreID, seconds)
        bookStateCache.removeValue(forKey: calibreID)
    }

    public func markBookRead(calibreID: Int) throws {
        let stmt = """
        INSERT INTO book_state (calibre_id, total_read_percent, updated_at)
        VALUES (?, 1.0, strftime('%s', 'now'))
        ON CONFLICT(calibre_id) DO UPDATE SET
            total_read_percent = 1.0,
            updated_at = excluded.updated_at;
        """
        try db.run(stmt, calibreID)
        bookStateCache.removeValue(forKey: calibreID)
    }

    public func resetReadingProgress(calibreID: Int) throws {
        let stmt = """
        INSERT INTO book_state (
            calibre_id, total_read_percent, last_spine_index, last_character_offset,
            last_scroll_offset, last_opened_date, total_reading_time_seconds, updated_at
        ) VALUES (?, 0.0, 0, 0, 0.0, 0, 0.0, strftime('%s', 'now'))
        ON CONFLICT(calibre_id) DO UPDATE SET
            total_read_percent = 0.0,
            last_spine_index = 0,
            last_character_offset = 0,
            last_scroll_offset = 0.0,
            last_opened_date = 0,
            total_reading_time_seconds = 0.0,
            updated_at = strftime('%s', 'now');
        """
        try db.run(stmt, calibreID)
        bookStateCache.removeValue(forKey: calibreID)
    }

    // MARK: - Duplicate Book State Migration

    /// Transfers all user data (reading progress, reading sessions, highlights,
    /// point annotations, and manual collection memberships) from a superseded
    /// duplicate work to the canonical winner.
    public func transferBookState(fromLoserID loserID: Int, toWinnerID winnerID: Int) throws {
        guard loserID != winnerID else { return }
        try db.transaction {
            let loserState = self.fetchBookState(for: loserID)
            let winnerState = self.fetchBookState(for: winnerID)

            if let loserState {
                let combinedReadingTime = loserState.totalReadingTimeSeconds + (winnerState?.totalReadingTimeSeconds ?? 0)
                let winnerPercent = winnerState?.totalReadPercent ?? 0.0
                let loserPercent = loserState.totalReadPercent
                let maxPercent = max(winnerPercent, loserPercent)

                let preferredPosition: (spine: Int, char: Int, scroll: Double) = {
                    if loserPercent > winnerPercent {
                        return (loserState.lastSpineIndex, loserState.lastCharacterOffset, loserState.lastScrollOffset)
                    } else if let winner = winnerState {
                        return (winner.lastSpineIndex, winner.lastCharacterOffset, winner.lastScrollOffset)
                    } else {
                        return (loserState.lastSpineIndex, loserState.lastCharacterOffset, loserState.lastScrollOffset)
                    }
                }()

                let latestOpenedDate = max(
                    loserState.lastOpenedDate.timeIntervalSince1970,
                    winnerState?.lastOpenedDate.timeIntervalSince1970 ?? 0
                )
                let eloScore = (winnerState != nil && (winnerState?.eloMatchCount ?? 0) > 0)
                    ? (winnerState?.eloScore ?? 1000.0)
                    : loserState.eloScore
                let eloMatches = (winnerState != nil && (winnerState?.eloMatchCount ?? 0) > 0)
                    ? (winnerState?.eloMatchCount ?? 0)
                    : loserState.eloMatchCount

                let upsertWinner = """
                INSERT INTO book_state (
                    calibre_id, last_spine_index, last_character_offset, last_scroll_offset,
                    total_read_percent, last_opened_date, total_reading_time_seconds,
                    elo_score, elo_match_count, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'))
                ON CONFLICT(calibre_id) DO UPDATE SET
                    last_spine_index = excluded.last_spine_index,
                    last_character_offset = excluded.last_character_offset,
                    last_scroll_offset = excluded.last_scroll_offset,
                    total_read_percent = excluded.total_read_percent,
                    last_opened_date = excluded.last_opened_date,
                    total_reading_time_seconds = excluded.total_reading_time_seconds,
                    elo_score = excluded.elo_score,
                    elo_match_count = excluded.elo_match_count,
                    updated_at = excluded.updated_at;
                """
                try db.run(
                    upsertWinner,
                    winnerID,
                    preferredPosition.spine,
                    preferredPosition.char,
                    preferredPosition.scroll,
                    maxPercent,
                    latestOpenedDate,
                    combinedReadingTime,
                    eloScore,
                    eloMatches
                )
            }

            // Migrate annotations
            try db.run("UPDATE annotations SET calibre_id = ? WHERE calibre_id = ?", winnerID, loserID)

            // Migrate reading history
            try db.run("UPDATE reading_history SET calibre_id = ? WHERE calibre_id = ?", winnerID, loserID)

            // Migrate book opens
            try db.run("UPDATE book_opens SET calibre_id = ? WHERE calibre_id = ?", winnerID, loserID)

            // Migrate manual collection memberships without duplicating
            let copyMemberships = """
            INSERT OR IGNORE INTO collection_members (collection_id, calibre_id, added_at)
            SELECT collection_id, ?, added_at
            FROM collection_members
            WHERE calibre_id = ?
            """
            try db.run(copyMemberships, winnerID, loserID)
            try db.run("DELETE FROM collection_members WHERE calibre_id = ?", loserID)

            // Remove loser from book_state
            try db.run("DELETE FROM book_state WHERE calibre_id = ?", loserID)
        }

        bookStateCache.removeValue(forKey: loserID)
        bookStateCache.removeValue(forKey: winnerID)
    }

    // MARK: - Reading Goals

    public func currentReadingGoal() -> ReadingGoal? {
        let now = Date().timeIntervalSince1970
        let query = """
        SELECT id, target_books_count, period_start, period_end
        FROM reading_goals WHERE ? BETWEEN period_start AND period_end
        ORDER BY period_end DESC LIMIT 1
        """
        if let row = (try? readDB.prepare(query, [now as Binding?]).map({ $0 }))?.first {
            return makeReadingGoal(from: row)
        }
        let latestQuery = """
        SELECT id, target_books_count, period_start, period_end
        FROM reading_goals ORDER BY period_end DESC LIMIT 1
        """
        if let row = (try? readDB.prepare(latestQuery).map({ $0 }))?.first {
            return makeReadingGoal(from: row)
        }
        return nil
    }

    private func makeReadingGoal(from row: Statement.Element) -> ReadingGoal? {
        guard let id = row[0] as? Int64,
              let target = row[1] as? Int64 else { return nil }
        let start = row[2] as? Double ?? 0.0
        let end = row[3] as? Double ?? 0.0
        return ReadingGoal(
            id: id,
            targetBooksCount: Int(target),
            periodStart: Date(timeIntervalSince1970: start),
            periodEnd: Date(timeIntervalSince1970: end)
        )
    }

    public func saveReadingGoal(targetBooksCount: Int, periodStart: Date, periodEnd: Date) throws {
        let stmt = """
        INSERT INTO reading_goals (target_books_count, period_start, period_end, created_at)
        VALUES (?, ?, ?, strftime('%s', 'now'));
        """
        try db.run(stmt, targetBooksCount, periodStart.timeIntervalSince1970, periodEnd.timeIntervalSince1970)
    }

    public func deleteReadingGoal(id: Int64) throws {
        try db.run("DELETE FROM reading_goals WHERE id = ?", id)
    }

    public func completedBooksCount(from start: Date, to end: Date) -> Int {
        (try? completedBooksCount(start: start, end: end)) ?? 0
    }

    // MARK: - Library Health & Maintenance Queries

    struct AO3HealthSnapshot: Sendable {
        let calibreID: Int
        let workID: String?
        let wordCount: Int?
        let chapterCurrent: Int?
        let chapterTotal: Int?
        let isComplete: Bool?
        let publishedDate: String?
        let updatedDate: String?
        let series: [AO3MetadataRecord.SeriesEntry]
        let extractedAt: String
    }

    func allAO3HealthSnapshots() -> [AO3HealthSnapshot] {
        let sql = """
            SELECT calibre_id, ao3_work_id, word_count, chapter_current, chapter_total,
                   is_complete, published_date, updated_date, series_json, extracted_at
            FROM ao3_metadata
        """
        guard let rows = try? readDB.prepare(sql) else { return [] }
        let decoder = JSONDecoder()
        var snapshots: [AO3HealthSnapshot] = []
        for row in rows {
            guard let cid = row.int(at: 0) else { continue }
            let seriesJSON = row[8] as? String
            let series: [AO3MetadataRecord.SeriesEntry]
            if let rawJSON = seriesJSON, !rawJSON.isEmpty, rawJSON != "[]", let data = rawJSON.data(using: .utf8) {
                series = (try? decoder.decode([AO3MetadataRecord.SeriesEntry].self, from: data)) ?? []
            } else {
                series = []
            }
            let isComp: Bool? = row.int(at: 5).map { $0 != 0 }
            snapshots.append(AO3HealthSnapshot(
                calibreID: cid,
                workID: row[1] as? String,
                wordCount: row.int(at: 2),
                chapterCurrent: row.int(at: 3),
                chapterTotal: row.int(at: 4),
                isComplete: isComp,
                publishedDate: row[6] as? String,
                updatedDate: row[7] as? String,
                series: series,
                extractedAt: (row[9] as? String) ?? ""
            ))
        }
        return snapshots
    }

    func allAnthologyCacheIDs() -> Set<Int> {
        let sql = "SELECT DISTINCT calibre_id FROM series_cache WHERE is_anthology = 1"
        guard let rows = try? readDB.prepare(sql) else { return [] }
        var ids = Set<Int>()
        for row in rows {
            if let cid = row.int(at: 0) {
                ids.insert(cid)
            }
        }
        return ids
    }

    func allSeriesCacheEntries() -> [SeriesCacheEntry] {
        let sql = """
        SELECT m.calibre_id, s.name, m.series_index, s.ao3_series_id,
               m.is_anthology, s.calibre_series_id, s.series_id, s.series_key
        FROM series_cache m JOIN series s ON s.series_id = m.series_id
        ORDER BY s.name, m.series_index
        """
        guard let rows = try? prepare(sql, []) else { return [] }
        return rows.compactMap { row -> SeriesCacheEntry? in
            guard let calibreID = row.int(at: 0),
                  let seriesName = row[safe: 1] as? String,
                  let seriesIndex = row.int(at: 2) else { return nil }
            return SeriesCacheEntry(
                seriesID: row.int(at: 6),
                calibreID: calibreID,
                seriesName: seriesName,
                seriesIndex: seriesIndex,
                ao3SeriesID: row[safe: 3] as? String,
                isAnthology: (row.int(at: 4) ?? 0) != 0,
                calibreSeriesID: row.int(at: 5),
                seriesKey: row[safe: 7] as? String
            )
        }
    }

    func effectiveCollectionBookIDs(collectionID: String) -> Set<Int> {
        let sql = "SELECT calibre_id FROM effective_collection_members WHERE collection_id = ?"
        guard let rows = try? readDB.prepare(sql, collectionID) else { return [] }
        var ids = Set<Int>()
        for row in rows {
            if let cid = row.int(at: 0) {
                ids.insert(cid)
            }
        }
        return ids
    }

    func dismissMaintenanceItem(kind: String, targetKey: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try db.run(
            """
            INSERT OR REPLACE INTO maintenance_dismissals (kind, target_key, dismissed_at)
            VALUES (?, ?, ?)
            """,
            kind, targetKey, now
        )
    }

    func undismissMaintenanceItem(kind: String, targetKey: String) throws {
        try db.run(
            "DELETE FROM maintenance_dismissals WHERE kind = ? AND target_key = ?",
            kind, targetKey
        )
    }

    func dismissedMaintenanceKeys(kind: String) -> Set<String> {
        let sql = "SELECT target_key FROM maintenance_dismissals WHERE kind = ?"
        guard let rows = try? readDB.prepare(sql, kind) else { return [] }
        var keys = Set<String>()
        for row in rows {
            if let key = row[0] as? String {
                keys.insert(key)
            }
        }
        return keys
    }

    // MARK: - Deletion & Re-Extraction Cleanup

    func annotationCount(for calibreID: Int) -> Int {
        let count = try? readDB.scalar(
            "SELECT COUNT(*) FROM annotations WHERE calibre_id = ?",
            calibreID
        ) as? Int64
        return Int(count ?? 0)
    }

    /// Removes cached AO3 extraction rows for a work whose EPUB was updated in place
    /// so the next background extraction scan re-parses chapter/word counts.
    func invalidateAO3Metadata(for calibreID: Int) throws {
        try db.transaction {
            try db.run("DELETE FROM ao3_metadata WHERE calibre_id = ?", calibreID)
            try db.run("DELETE FROM book_anthology_cache WHERE calibre_id = ?", calibreID)
        }
    }

    /// Purges orphaned derived and user-state rows after book IDs are removed from `metadata.db`.
    func cleanupDeletedBooks(calibreIDs: [Int]) throws {
        let uniqueIDs = Array(Set(calibreIDs))
        guard !uniqueIDs.isEmpty else { return }
        try db.transaction {
            for calibreID in uniqueIDs {
                try db.run("DELETE FROM ao3_metadata WHERE calibre_id = ?", calibreID)
                try db.run("DELETE FROM book_series_cache WHERE calibre_id = ?", calibreID)
                try db.run("DELETE FROM book_anthology_cache WHERE calibre_id = ?", calibreID)
                try db.run("DELETE FROM book_state WHERE calibre_id = ?", calibreID)
                try db.run("DELETE FROM annotations WHERE calibre_id = ?", calibreID)
                try db.run("DELETE FROM reading_history WHERE calibre_id = ?", calibreID)
                try db.run("DELETE FROM book_opens WHERE calibre_id = ?", calibreID)
                try db.run("DELETE FROM collection_members WHERE calibre_id = ?", calibreID)
                try db.run("DELETE FROM maintenance_dismissals WHERE target_key = ?", String(calibreID))
            }
        }
        for calibreID in uniqueIDs {
            bookStateCache.removeValue(forKey: calibreID)
        }
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
