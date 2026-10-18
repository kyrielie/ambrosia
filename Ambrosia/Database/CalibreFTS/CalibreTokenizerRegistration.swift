// SPDX-License-Identifier: GPL-3.0-only
import SQLite

/// Registers the `calibre` FTS5 tokenizer on a SQLite.swift connection.
///
/// `books_fts` in Calibre's `full-text-search.db` is declared with
/// `tokenize = 'calibre remove_diacritics 2'`, which SQLite cannot resolve unless the
/// tokenizer is registered on the connection that opens the table.
enum CalibreTokenizerRegistration {

    /// Call immediately after opening the connection and before any statement that
    /// touches an FTS table; the tokenizer is resolved when the table is first opened.
    /// Registering twice on one connection is allowed.
    static func register(on conn: Connection) throws {
        let status = calibre_fts5_register(conn.handle, 0)
        guard status == SQLITE_OK else { throw FTSSearchError.tokenizerUnavailable }
    }
}
