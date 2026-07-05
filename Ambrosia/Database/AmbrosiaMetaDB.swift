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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
        try migrateSeriesPlaceholdersToKeyedIfNeeded(db: db)
        try dedupeSeriesCacheIfNeeded(db: db)
        try createAO3TagSynonyms(db: db)
        try bootstrapSystemCollections(db: db)
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

    private static func createAO3Metadata(db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS ao3_metadata (
            calibre_id INTEGER PRIMARY KEY,
            story_url TEXT,
            ao3_work_id TEXT,
            ao3_author_username TEXT,
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
            extracted_at TEXT NOT NULL
        );

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

    private static func migrateSeriesPlaceholdersToKeyedIfNeeded(db: Connection) throws {
        let version = (try? db.scalar("PRAGMA user_version")) as? Int64 ?? 0
        guard version < seriesPlaceholdersKeyedMigrationVersion else { return }
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

    private static func dedupeSeriesCacheIfNeeded(db: Connection) throws {
        let version = (try? db.scalar("PRAGMA user_version")) as? Int64 ?? 0
        guard version < dedupeSeriesCacheMigrationVersion else { return }
        try db.transaction {
            try db.run("""
                DELETE FROM series_cache
                WHERE ao3_series_id IS NULL
                  AND calibre_id IN (
                      SELECT calibre_id FROM series_cache WHERE ao3_series_id IS NOT NULL
                  )
                """)
            try db.run("PRAGMA user_version = \(dedupeSeriesCacheMigrationVersion)")
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
        let placeholders = calibreIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT calibre_id, story_url, ao3_work_id, ao3_author_username, kudos_count, word_count,
               chapter_current, chapter_total, is_complete, language, published_date, updated_date,
               fandoms_json, relationships_json, characters_json, additional_tags_json, category_json,
               ao3_collections_json, series_json, extracted_at
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

        var result: [Int: AO3MetadataRecord] = [:]
        for row in try prepare(sql, calibreIDs.map { $0 as Binding? }) {
            guard let id = row.int(at: 0),
                  let extractedAt = row[safe: 19] as? String else { continue }
            result[id] = AO3MetadataRecord(
                storyURL: row[safe: 1] as? String,
                workID: row[safe: 2] as? String,
                authorUsername: row[safe: 3] as? String,
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
                extractedAt: extractedAt
            )
        }
        return result
    }

    func insert(_ metadata: AO3MetadataRecord, calibreID: Int) throws {
        let encoder = JSONEncoder()
        func json(_ values: [String]) -> String {
            guard let data = try? encoder.encode(values) else { return "[]" }
            return String(data: data, encoding: .utf8) ?? "[]"
        }
        let seriesData = (try? encoder.encode(metadata.series)) ?? Data("[]".utf8)
        let seriesJSON = String(data: seriesData, encoding: .utf8) ?? "[]"

        try transaction {
            try run(
                """
                INSERT OR REPLACE INTO ao3_metadata
                (calibre_id, story_url, ao3_work_id, ao3_author_username, kudos_count, word_count,
                 chapter_current, chapter_total, is_complete, language, published_date, updated_date,
                 fandoms_json, relationships_json, characters_json, additional_tags_json, category_json,
                 ao3_collections_json, series_json, extracted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    calibreID,
                    metadata.storyURL,
                    metadata.workID,
                    metadata.authorUsername,
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
    }

    func insert(_ diagnostic: AO3ExtractionDiagnostic) throws {
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
    func insertBatch(_ records: [(AO3MetadataRecord, Int)], diagnostics: [AO3ExtractionDiagnostic]) throws {
        try transaction {
            for (metadata, calibreID) in records {
                try insert(metadata, calibreID: calibreID)
            }
            for diagnostic in diagnostics {
                try insert(diagnostic)
            }
        }
    }

    func clearAO3Metadata() throws {
        try transaction {
            try run("DELETE FROM ao3_metadata")
            try run("DELETE FROM ao3_extraction_diagnostics")
            try run("DELETE FROM series_cache")
        }
    }

    func seriesEntries(for calibreIDs: [Int]) throws -> [SeriesCacheEntry] {
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

    func singletonNonLeadingSeriesEntries(for calibreIDs: [Int]) throws -> [Int: SingletonSeriesWarning] {
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
        var result: [Int: SingletonSeriesWarning] = [:]
        for row in try prepare(sql, calibreIDs.map { $0 as Binding? }) {
            guard let calibreID = row.int(at: 0),
                  result[calibreID] == nil,
                  let seriesKey = row[safe: 1] as? String,
                  let seriesName = row[safe: 2] as? String,
                  let seriesIndex = row.int(at: 3) else { continue }
            result[calibreID] = SingletonSeriesWarning(seriesKey: seriesKey, seriesName: seriesName, seriesIndex: seriesIndex, title: "")
        }
        return result
    }

    func placeholders(for seriesKeys: [String]) throws -> [String: [SeriesPlaceholder]] {
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
    }

    func setAnthology(seriesName: String, isAnthology: Bool) throws {
        try run(
            "UPDATE series_cache SET is_anthology = ? WHERE series_name = ?",
            [isAnthology ? 1 : 0, seriesName]
        )
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
