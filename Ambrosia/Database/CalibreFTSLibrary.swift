import SQLite
import Foundation

// MARK: - CalibreFTSLibrary (Section I3)

/// Optional read-only connection to Calibre's full-text-search.db.
///
/// Opened lazily via `init?(libraryURL:)` — returns nil if the file doesn't exist
/// or lacks the expected FTS5 tables. Callers never need to check availability;
/// they just call `search(query:)` and handle nil as "no results / fall back to LIKE".
///
/// Invariants:
///   - Opened `readonly: true`. Never written to. No write PRAGMAs ever.
///   - `search(query:)` returns nil on any error — caller always has a LIKE fallback.
///   - Never imported or referenced by anything outside LibrarySession + BookGridItem.
final class CalibreFTSLibrary {

    private let db: Connection

    // MARK: - Init

    init?(libraryURL: URL) {
        let ftsURL = libraryURL.appendingPathComponent("full-text-search.db")
        guard FileManager.default.fileExists(atPath: ftsURL.path),
              let conn = try? Connection(ftsURL.path, readonly: true)
        else { return nil }

        // Validate that the expected FTS5 tables exist
        let tables = (try? conn.prepare(
            "SELECT name FROM sqlite_master WHERE type='table'")
            .map { $0[0] as? String ?? "" }) ?? []

        guard tables.contains("books_fts") && tables.contains("books_fts_map")
        else { return nil }

        self.db = conn
    }

    // MARK: - Search

    /// Returns Calibre book IDs whose full text matches the query.
    ///
    /// Uses FTS5 MATCH syntax; multi-word queries use implicit AND.
    /// Returns nil on any error — caller should fall back to SQL LIKE search.
    /// Results are capped at `limit` (default 500).
    func search(query: String, limit: Int = 500) -> [Int]? {
        // Sanitise query for FTS5 MATCH: strip special chars, quote each word.
        let sanitised = query
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }        // quote each word to prevent FTS5 syntax errors
            .joined(separator: " ")

        guard !sanitised.isEmpty else { return nil }

        let sql = """
            SELECT m.book FROM books_fts_map m
            JOIN books_fts ON books_fts.rowid = m.id
            WHERE books_fts MATCH ?
            LIMIT ?
            """
        return try? db.prepare(sql, [sanitised as Binding?, limit as Binding?])
            .compactMap { row -> Int? in
                guard let v = row[0] else { return nil }
                if let i = v as? Int64 { return Int(i) }
                if let i = v as? Int   { return i }
                return nil
            }
    }
}
