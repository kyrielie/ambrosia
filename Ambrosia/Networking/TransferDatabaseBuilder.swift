import Foundation
import SQLite
import SwiftData

// MARK: - TransferDatabaseBuilder
//
// Phase 2a of the feed-transfer-compression plan. Builds a from-scratch,
// throwaway SQLite database matching the Wire Contract's `items` schema
// (shared verbatim with the Nectar-side plan — see
// ambrosia-implementation-plan.md) for one `.sqlite` feed request.
//
// Deliberately NOT `AmbrosiaMetaDB`'s own `Connection` — a fresh, independent
// `Connection` against a fresh temp file, per Phase 2a: "keep them decoupled
// so either can evolve independently." Single write-then-close lifecycle, no
// concurrent readers, so (unlike `AmbrosiaMetaDB`) there is no read/write
// connection split here — see docs/ambrosia-feed-transfer-phase0-findings.md.
enum TransferDatabaseBuilder {

    /// Bump this — and the identical constant in the Nectar codebase, in the
    /// same release — any time the wire schema changes. Nectar hard-fails on
    /// a mismatch (see its plan for that half); this is the one number that
    /// must never drift between the two codebases independently.
    static let wireFormatVersion: Int32 = 1

    struct Row {
        let calibreID: Int
        let ao3WorkID: String?
        let isAnthology: Bool
        let ao3SeriesID: String?
        let seriesName: String?

        let url: String?
        let title: String?
        let contentHTML: String
        let summary: String?
        let datePublished: String?
        let dateModified: String?
        let authorsJSON: String
        let tagsJSON: String

        let wordCount: Int?
        let chapterCurrent: Int?
        let chapterTotal: Int?
        let isComplete: Bool?
        let fandomsJSON: String
        let relationshipsJSON: String
        let charactersJSON: String
        let ratingsJSON: String
        let warningsJSON: String
        let categoriesJSON: String
        let seriesJSON: String

        let isReadLater: Bool
        let isLiked: Bool
        let isFinished: Bool
        let readingProgress: Double?
    }

    enum BuildError: Error {
        case connectionFailed(Error)
    }

    /// Builds the transfer DB at `fileURL` (caller-owned temp path) and
    /// returns once every row is written and `PRAGMA user_version` is
    /// stamped. `fileURL` must not already exist.
    static func build(rows: [Row], at fileURL: URL) throws {
        let db: Connection
        do {
            db = try Connection(fileURL.path)
        } catch {
            throw BuildError.connectionFailed(error)
        }

        try db.execute("""
        CREATE TABLE items (
            id                  TEXT PRIMARY KEY,
            ao3_work_id         TEXT,
            is_anthology        INTEGER NOT NULL DEFAULT 0,
            ao3_series_id       TEXT,
            series_name         TEXT,

            url                 TEXT,
            title               TEXT,
            content_html        TEXT NOT NULL,
            summary             TEXT,
            date_published      TEXT,
            date_modified       TEXT,
            authors_json        TEXT,
            tags_json           TEXT,

            word_count          INTEGER,
            chapter_current     INTEGER,
            chapter_total       INTEGER,
            is_complete         INTEGER,
            fandoms_json        TEXT,
            relationships_json  TEXT,
            characters_json     TEXT,
            ratings_json        TEXT,
            warnings_json       TEXT,
            categories_json     TEXT,
            series_json         TEXT,

            is_read_later       INTEGER NOT NULL DEFAULT 0,
            is_liked            INTEGER NOT NULL DEFAULT 0,
            is_finished         INTEGER NOT NULL DEFAULT 0,
            reading_progress    REAL
        );
        """)

        let insertSQL = """
        INSERT INTO items (
            id, ao3_work_id, is_anthology, ao3_series_id, series_name,
            url, title, content_html, summary, date_published, date_modified, authors_json, tags_json,
            word_count, chapter_current, chapter_total, is_complete,
            fandoms_json, relationships_json, characters_json, ratings_json, warnings_json, categories_json, series_json,
            is_read_later, is_liked, is_finished, reading_progress
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        try db.transaction {
            for row in rows {
                try db.run(insertSQL, [
                    "ambrosia-book-\(row.calibreID)",
                    row.ao3WorkID,
                    row.isAnthology ? 1 : 0,
                    row.ao3SeriesID,
                    row.seriesName,

                    row.url,
                    row.title,
                    row.contentHTML,
                    row.summary,
                    row.datePublished,
                    row.dateModified,
                    row.authorsJSON,
                    row.tagsJSON,

                    row.wordCount,
                    row.chapterCurrent,
                    row.chapterTotal,
                    row.isComplete.map { $0 ? 1 : 0 },
                    row.fandomsJSON,
                    row.relationshipsJSON,
                    row.charactersJSON,
                    row.ratingsJSON,
                    row.warningsJSON,
                    row.categoriesJSON,
                    row.seriesJSON,

                    row.isReadLater ? 1 : 0,
                    row.isLiked ? 1 : 0,
                    row.isFinished ? 1 : 0,
                    row.readingProgress,
                ])
            }
        }

        // Stamped last, after every row is committed — a reader that opens
        // this file mid-write (shouldn't happen given the temp-file-then-serve
        // flow, but cheap to order defensively) sees either the pre-existing
        // default user_version or the fully-populated table, never a
        // half-written table claiming to be the current wire version.
        try db.execute("PRAGMA user_version = \(wireFormatVersion)")
    }
}
