// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite
@testable import Ambrosia

private final class FTSBundleToken {}

/// Builds a Calibre-shaped `full-text-search.db` the way Calibre does: an in-memory
/// connection with the tokenizer registered, the file ATTACHed as `fts_db`, Calibre's
/// verbatim DDL executed (its triggers keep both FTS tables in sync), then rows inserted
/// into `fts_db.books_text`. The `books_fts_stemmed` table wraps SQLite's stock `porter`
/// around our `calibre` tokenizer here; nothing in M3 to M5 queries it.
enum FTSTestFixture {

    struct Document {
        let id: Int
        let book: Int
        let format: String
        let text: String
    }

    enum FixtureError: Error {
        case resourceNotFound(String)
    }

    static let fileName = "full-text-search.db"

    /// Creates a unique temp library folder holding `full-text-search.db`.
    static func makeLibraryRoot(books: [Document], bundle: Bundle = Bundle(for: FTSBundleToken.self)) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia_fts_library_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeLibrary(at: root, books: books, bundle: bundle)
        return root
    }

    /// Writes (or rewrites) `full-text-search.db` inside an existing folder. An existing
    /// file is deleted first, which is what Calibre's re-index does.
    static func writeLibrary(at root: URL, books: [Document], bundle: Bundle = Bundle(for: FTSBundleToken.self)) throws {
        let path = root.appendingPathComponent(fileName).path
        try? FileManager.default.removeItem(atPath: path)
        guard let schemaURL = bundle.url(forResource: "calibre_fts_schema", withExtension: "sql") else {
            throw FixtureError.resourceNotFound("calibre_fts_schema")
        }
        let schema = try String(contentsOf: schemaURL, encoding: .utf8)

        let conn = try Connection(.inMemory)
        try CalibreTokenizerRegistration.register(on: conn)
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        try conn.execute("ATTACH DATABASE '\(escaped)' AS fts_db")
        try conn.execute(schema)
        for doc in books {
            try conn.run(
                """
                INSERT INTO fts_db.books_text (id, book, timestamp, format, format_hash, searchable_text)
                VALUES (?, ?, 0, ?, 'hash', ?)
                """,
                doc.id, doc.book, doc.format, doc.text
            )
        }
    }

    /// Opens a registered, read-only connection on the fixture file, as the app does.
    static func openReader(root: URL) throws -> Connection {
        let conn = try Connection(root.appendingPathComponent(fileName).path, readonly: true)
        try CalibreTokenizerRegistration.register(on: conn)
        return conn
    }
}
