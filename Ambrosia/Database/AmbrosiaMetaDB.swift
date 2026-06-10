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
    private let db: Connection

    init(libraryURL: URL) throws {
        self.libraryHash = Ambrosia.libraryHash(for: libraryURL)
        let dir = try Self.databaseDirectory(for: libraryHash)
        self.databaseURL = dir.appendingPathComponent("ambrosia_meta.db")
        self.db = try Connection(databaseURL.path)
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
        try db.prepare(sql, bindings).map { $0 }
    }

    func scalar(_ sql: String, _ bindings: [Binding?] = []) throws -> Binding? {
        try db.scalar(sql, bindings)
    }

    func transaction(_ block: () throws -> Void) throws {
        try db.transaction(.deferred, block: block)
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

    func existingAO3MetadataIDs() throws -> Set<Int> {
        let rows = try prepare("SELECT calibre_id FROM ao3_metadata")
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    func ao3CompletionStatusIDs(_ status: AO3CompletionStatus) throws -> Set<Int> {
        let predicate: String
        switch status {
        case .finished:
            predicate = """
            chapter_current IS NOT NULL
              AND chapter_total IS NOT NULL
              AND chapter_current = chapter_total
            """
        case .unfinished:
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

    func insertCalibreSeriesFallback(_ entries: [SeriesCacheEntry]) throws {
        guard !entries.isEmpty else { return }
        try transaction {
            for entry in entries {
                try run(
                    """
                    INSERT OR IGNORE INTO series_cache
                    (calibre_id, series_name, series_index, ao3_series_id, is_anthology)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        entry.calibreID,
                        entry.seriesName,
                        entry.seriesIndex,
                        entry.ao3SeriesID,
                        entry.isAnthology ? 1 : 0,
                    ]
                )
            }
        }
    }

    func collapsedSeriesMemberIDs() throws -> Set<Int> {
        let sql = """
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
        )
        SELECT calibre_id
        FROM ordered
        WHERE series_count > 1 AND anthology = 0 AND rn > 1
        """
        let rows = try prepare(sql)
        return Set(rows.compactMap { $0.int(at: 0) })
    }

    func collapsedSeriesRepresentativeIDs() throws -> Set<Int> {
        let sql = """
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
        )
        SELECT calibre_id
        FROM ordered
        WHERE series_count > 1 AND anthology = 0 AND rn = 1
        """
        let rows = try prepare(sql)
        return Set(rows.compactMap { $0.int(at: 0) })
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
