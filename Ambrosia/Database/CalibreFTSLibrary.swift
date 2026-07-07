import SQLite
import Foundation

// MARK: - CalibreFTSLibrary (Section I3)

/// Optional read-only connection to Calibre's full-text-search.db.
///
/// Opened lazily via `init?(libraryURL:)` — returns nil if the file doesn't exist
/// or lacks a supported FTS schema. Explicit `fulltext:` callers treat nil as
/// "FTS unavailable" and return no works.
///
/// Invariants:
///   - Opened `readonly: true`. Never written to. No write PRAGMAs ever.
///   - `search(query:)` returns nil on any error — caller preserves explicit
///     fulltext semantics instead of falling back to title search.
///   - Never imported or referenced by anything outside LibrarySession + BookGridItem.
actor CalibreFTSLibrary {

    private let db: Connection
    private let strategy: QueryStrategy

    private enum QueryStrategy {
        case mapped(ftsTable: String, mapTable: String, mapFTSColumn: String, mapBookColumn: String)
        case directColumn(ftsTable: String, bookColumn: String)
        case contentTable(table: String, bookColumn: String, textColumn: String)
    }

    // MARK: - Init

    init?(libraryURL: URL) {
        let ftsURL = libraryURL.appendingPathComponent("full-text-search.db")
        guard FileManager.default.fileExists(atPath: ftsURL.path) else {
            Self.log("missing full-text-search.db at \(ftsURL.path)")
            return nil
        }
        let conn: Connection
        do {
            conn = try Connection(ftsURL.path, readonly: true)
        } catch {
            Self.log("could not open full-text-search.db read-only: \(error)")
            return nil
        }
        guard let strategy = Self.makeStrategy(db: conn) else {
            Self.log("unsupported FTS schema in \(ftsURL.path)")
            return nil
        }
        self.db = conn
        self.strategy = strategy
    }

    // MARK: - Search

    /// Returns Calibre book IDs whose full text matches the query.
    ///
    /// Uses FTS5 MATCH syntax; multi-word queries are treated as exact phrases.
    /// Returns nil on any error — caller should fall back to SQL LIKE search.
    /// Results are capped at `limit` (default 500).
    func search(query: String, limit: Int = 500) -> [Int]? {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else {
            Self.log("empty query after sanitising input")
            return nil
        }

        if case let .contentTable(table, bookColumn, textColumn) = strategy {
            return searchContentTable(
                table: table,
                bookColumn: bookColumn,
                textColumn: textColumn,
                phrase: phrase,
                limit: limit
            )
        }

        let sanitised = "\"\(phrase.replacingOccurrences(of: "\"", with: "\"\""))\""

        let sql: String
        switch strategy {
        case let .mapped(ftsTable, mapTable, mapFTSColumn, mapBookColumn):
            sql = """
                SELECT m.\(Self.quote(mapBookColumn))
                FROM \(Self.quote(mapTable)) m
                JOIN \(Self.quote(ftsTable)) f ON f.rowid = m.\(Self.quote(mapFTSColumn))
                WHERE \(Self.quote(ftsTable)) MATCH ?
                LIMIT ?
                """
        case let .directColumn(ftsTable, bookColumn):
            sql = """
                SELECT \(Self.quote(bookColumn))
                FROM \(Self.quote(ftsTable))
                WHERE \(Self.quote(ftsTable)) MATCH ?
                LIMIT ?
                """
        case .contentTable:
            fatalError("contentTable handled before FTS MATCH query construction")
        }

        do {
            return try db.prepare(sql, [sanitised as Binding?, limit as Binding?])
                .compactMap { row -> Int? in
                guard let v = row[0] else { return nil }
                if let i = v as? Int64 { return Int(i) }
                if let i = v as? Int   { return i }
                return nil
            }
        } catch {
            Self.log("MATCH query failed for strategy \(strategyDescription): \(error)")
            return nil
        }
    }

    private func searchContentTable(
        table: String,
        bookColumn: String,
        textColumn: String,
        phrase: String,
        limit: Int
    ) -> [Int]? {
        let sql = """
            SELECT DISTINCT \(Self.quote(bookColumn))
            FROM \(Self.quote(table))
            WHERE LOWER(\(Self.quote(textColumn))) LIKE ?
            LIMIT ?
            """
        var bindings: [Binding?] = ["%\(phrase.lowercased())%" as Binding?]
        bindings.append(limit as Binding?)

        do {
            return try db.prepare(sql, bindings)
                .compactMap { row -> Int? in
                    guard let v = row[0] else { return nil }
                    if let i = v as? Int64 { return Int(i) }
                    if let i = v as? Int   { return i }
                    return nil
                }
        } catch {
            Self.log("content-table fulltext query failed for strategy \(strategyDescription): \(error)")
            return nil
        }
    }

    private var strategyDescription: String {
        switch strategy {
        case let .mapped(ftsTable, mapTable, mapFTSColumn, mapBookColumn):
            return "mapped fts=\(ftsTable) map=\(mapTable) mapFTSColumn=\(mapFTSColumn) mapBookColumn=\(mapBookColumn)"
        case let .directColumn(ftsTable, bookColumn):
            return "direct fts=\(ftsTable) bookColumn=\(bookColumn)"
        case let .contentTable(table, bookColumn, textColumn):
            return "content table=\(table) bookColumn=\(bookColumn) textColumn=\(textColumn)"
        }
    }

    private static func makeStrategy(db: Connection) -> QueryStrategy? {
        let tables = tableNames(db: db)
        guard !tables.isEmpty else {
            log("full-text-search.db has no tables")
            return nil
        }

        let ftsTables = virtualFTSTables(db: db)
        guard !ftsTables.isEmpty else {
            log("full-text-search.db lacks FTS virtual tables; tables=\(tables.sorted().joined(separator: ","))")
            return nil
        }

        if ftsTables.contains("books_fts"), tables.contains("books_fts_map") {
            let mapColumns = columns(in: "books_fts_map", db: db)
            if let mapFTSColumn = firstAvailable(["id", "fts_id", "rowid"], in: mapColumns),
               let mapBookColumn = firstAvailable(["book", "book_id", "calibre_id"], in: mapColumns) {
                return .mapped(ftsTable: "books_fts", mapTable: "books_fts_map", mapFTSColumn: mapFTSColumn, mapBookColumn: mapBookColumn)
            }
            log("books_fts_map lacks expected columns; columns=\(mapColumns.joined(separator: ","))")
        }

        for table in preferredFTSTables(ftsTables) {
            let tableColumns = columns(in: table, db: db)
            if let bookColumn = firstAvailable(["book", "book_id", "calibre_id"], in: tableColumns) {
                return .directColumn(ftsTable: table, bookColumn: bookColumn)
            }
        }

        if tables.contains("books_text") {
            let textColumns = columns(in: "books_text", db: db)
            if let bookColumn = firstAvailable(["book", "book_id", "calibre_id"], in: textColumns),
               let textColumn = firstAvailable(["searchable_text", "text", "body"], in: textColumns) {
                if ftsTables.contains("books_fts"),
                   ftsTableUsesUnsupportedCalibreTokenizer("books_fts", db: db) {
                    log("books_fts uses unsupported Calibre tokenizer; using books_text searchable text fallback")
                } else {
                    log("using books_text searchable text fallback")
                }
                return .contentTable(table: "books_text", bookColumn: bookColumn, textColumn: textColumn)
            }
            log("books_text lacks expected columns; columns=\(textColumns.joined(separator: ","))")
        }

        return nil
    }

    private static func tableNames(db: Connection) -> Set<String> {
        do {
            let rows = try db.prepare("SELECT name FROM sqlite_master WHERE type='table'").map { $0 }
            return Set(rows.compactMap { $0[0] as? String })
        } catch {
            log("could not inspect sqlite_master tables: \(error)")
            return []
        }
    }

    private static func virtualFTSTables(db: Connection) -> [String] {
        do {
            let rows = try db.prepare("""
                SELECT name, sql
                FROM sqlite_master
                WHERE type='table' AND UPPER(COALESCE(sql, '')) LIKE '%VIRTUAL TABLE%' AND UPPER(COALESCE(sql, '')) LIKE '%FTS%'
                """).map { $0 }
            return rows.compactMap { $0[0] as? String }
        } catch {
            log("could not inspect FTS virtual tables: \(error)")
            return []
        }
    }

    private static func ftsTableUsesUnsupportedCalibreTokenizer(_ table: String, db: Connection) -> Bool {
        do {
            let sql = "SELECT sql FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
            guard let row = try db.prepare(sql, [table as Binding?]).map({ $0 }).first,
                  let ddl = row[0] as? String else { return false }
            return ddl.lowercased().contains("tokenize = 'calibre")
                || ddl.lowercased().contains("tokenize='calibre")
                || ddl.lowercased().contains("tokenize = 'porter calibre")
                || ddl.lowercased().contains("tokenize='porter calibre")
        } catch {
            log("could not inspect tokenizer for \(table): \(error)")
            return false
        }
    }

    private static func columns(in table: String, db: Connection) -> [String] {
        do {
            let rows = try db.prepare("PRAGMA table_info(\(quote(table)))").map { $0 }
            return rows.compactMap { $0[1] as? String }
        } catch {
            log("could not inspect columns for \(table): \(error)")
            return []
        }
    }

    private static func preferredFTSTables(_ tables: [String]) -> [String] {
        tables.sorted { lhs, rhs in
            if lhs == "books_fts" { return true }
            if rhs == "books_fts" { return false }
            return lhs < rhs
        }
    }

    private static func firstAvailable(_ candidates: [String], in columns: [String]) -> String? {
        let byLowercase = Dictionary(uniqueKeysWithValues: columns.map { ($0.lowercased(), $0) })
        return candidates.compactMap { byLowercase[$0] }.first
    }

    private static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func log(_ message: String) {
        #if DEBUG
        print("[CalibreFTSLibrary] \(message)")
        #endif
    }
}
