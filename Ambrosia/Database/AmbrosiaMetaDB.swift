import CryptoKit
import Foundation
import SQLite

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
        try createAO3Metadata(db: db)
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

    func existingAO3MetadataIDs() throws -> Set<Int> {
        let rows = try prepare("SELECT calibre_id FROM ao3_metadata")
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

    func binding(at index: Int) -> Binding? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
