// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite

public enum CalibreFTSWriter {

    public struct FTSProgress: Sendable {
        public let current: Int
        public let total: Int
        public let currentTitle: String
    }

    public static let ddl = """
        CREATE TABLE IF NOT EXISTS dirtied_formats (
            id INTEGER PRIMARY KEY,
            book INTEGER NOT NULL,
            format TEXT NOT NULL COLLATE NOCASE,
            in_progress INTEGER NOT NULL DEFAULT FALSE,
            UNIQUE(book, format)
        );

        CREATE TABLE IF NOT EXISTS books_text (
            id INTEGER PRIMARY KEY,
            book INTEGER NOT NULL,
            timestamp REAL NOT NULL,
            format TEXT NOT NULL COLLATE NOCASE,
            format_hash TEXT NOT NULL COLLATE NOCASE,
            format_size INTEGER NOT NULL DEFAULT 0,
            searchable_text TEXT NOT NULL DEFAULT '',
            text_size INTEGER NOT NULL DEFAULT 0,
            text_hash TEXT NOT NULL COLLATE NOCASE DEFAULT '',
            err_msg TEXT DEFAULT '',
            UNIQUE(book, format)
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS books_fts USING fts5(
            searchable_text,
            content = 'books_text',
            content_rowid = 'id',
            tokenize = 'calibre remove_diacritics 2'
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS books_fts_stemmed USING fts5(
            searchable_text,
            content = 'books_text',
            content_rowid = 'id',
            tokenize = 'porter calibre remove_diacritics 2'
        );

        CREATE TRIGGER IF NOT EXISTS books_fts_insert_trg AFTER INSERT ON books_text
        BEGIN
            INSERT INTO books_fts(rowid, searchable_text) VALUES (NEW.id, NEW.searchable_text);
            INSERT INTO books_fts_stemmed(rowid, searchable_text) VALUES (NEW.id, NEW.searchable_text);
            DELETE FROM dirtied_formats WHERE book=NEW.book AND format=NEW.format;
        END;

        CREATE TRIGGER IF NOT EXISTS books_fts_delete_trg AFTER DELETE ON books_text
        BEGIN
            INSERT INTO books_fts(books_fts, rowid, searchable_text) VALUES('delete', OLD.id, OLD.searchable_text);
            INSERT INTO books_fts_stemmed(books_fts_stemmed, rowid, searchable_text) VALUES('delete', OLD.id, OLD.searchable_text);
        END;

        CREATE TRIGGER IF NOT EXISTS books_fts_update_trg AFTER UPDATE ON books_text
        BEGIN
            INSERT INTO books_fts(books_fts, rowid, searchable_text) VALUES('delete', OLD.id, OLD.searchable_text);
            INSERT INTO books_fts(rowid, searchable_text) VALUES (NEW.id, NEW.searchable_text);
            INSERT INTO books_fts_stemmed(books_fts_stemmed, rowid, searchable_text) VALUES('delete', OLD.id, OLD.searchable_text);
            INSERT INTO books_fts_stemmed(rowid, searchable_text) VALUES (NEW.id, NEW.searchable_text);
            DELETE FROM dirtied_formats WHERE book=NEW.book AND format=NEW.format;
        END;

        PRAGMA user_version = 1;
        """

    /// Initializes `full-text-search.db` and indexes EPUB text for all books in `metadata.db`.
    @discardableResult
    public static func indexLibrary(
        at rootURL: URL,
        batchSize: Int = 10,
        progress: ((FTSProgress) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> Int {
        let ftsURL = rootURL.appendingPathComponent("full-text-search.db")
        let ftsConn = try Connection(ftsURL.path)
        try CalibreTokenizerRegistration.register(on: ftsConn)

        try ftsConn.execute("PRAGMA journal_mode = WAL;")
        try ftsConn.execute("PRAGMA synchronous = NORMAL;")
        try ftsConn.execute(ddl)

        // Read books from metadata.db to resolve path -> book ID
        let metaURL = rootURL.appendingPathComponent("metadata.db")
        let metaConn = try Connection(metaURL.path, readonly: true)

        var pathToID: [String: Int64] = [:]
        var idToTitle: [Int64: String] = [:]
        if let rows = try? metaConn.prepare("SELECT id, path, title FROM books") {
            for row in rows {
                if let id = row[0] as? Int64, let path = row[1] as? String {
                    pathToID[path] = id
                    idToTitle[id] = row[2] as? String ?? "Untitled"
                }
            }
        }

        // Check which books already have text in books_text
        var indexedBookIDs = Set<Int64>()
        if let rows = try? ftsConn.prepare("SELECT book FROM books_text WHERE format = 'EPUB'") {
            for row in rows {
                if let bookID = row[0] as? Int64 {
                    indexedBookIDs.insert(bookID)
                }
            }
        }

        // Filter to unindexed books
        let unindexed = pathToID.compactMap { path, bookID -> (id: Int64, path: String, title: String)? in
            guard !indexedBookIDs.contains(bookID) else { return nil }
            return (id: bookID, path: path, title: idToTitle[bookID] ?? "Untitled")
        }.sorted { $0.id < $1.id }

        guard !unindexed.isEmpty else { return 0 }

        var indexedCount = 0
        let total = unindexed.count
        let now = Date().timeIntervalSince1970

        var batchIndex = 0
        while batchIndex < total {
            if isCancelled?() == true { break }

            let chunkEnd = min(batchIndex + batchSize, total)
            let chunk = unindexed[batchIndex..<chunkEnd]

            try ftsConn.transaction {
                for item in chunk {
                    if isCancelled?() == true { break }

                    autoreleasepool {
                        let bookFileURL: URL
                        let pathURL = rootURL.appendingPathComponent(item.path)
                        if FileManager.default.fileExists(atPath: pathURL.path) && pathURL.pathExtension.lowercased() == "epub" {
                            bookFileURL = pathURL
                        } else {
                            let contents = (try? FileManager.default.contentsOfDirectory(at: pathURL, includingPropertiesForKeys: nil)) ?? []
                            guard let found = contents.first(where: { $0.pathExtension.lowercased() == "epub" }) else {
                                return
                            }
                            bookFileURL = found
                        }

                        var parser = EPUBParser(epubURL: bookFileURL)
                        guard (try? parser.parse()) != nil else { return }

                        var textParts: [String] = []
                        for item in parser.spine {
                            if let plain = try? parser.plainText(for: item), !plain.isEmpty {
                                textParts.append(plain)
                            }
                        }

                        let fullText = textParts.joined(separator: "\n\n")
                        let textSize = Int64(fullText.utf8.count)
                        let formatSize = (try? FileManager.default.attributesOfItem(atPath: bookFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0

                        _ = try? ftsConn.run(
                            """
                            INSERT OR REPLACE INTO books_text
                            (book, timestamp, format, format_hash, format_size, searchable_text, text_size, text_hash, err_msg)
                            VALUES (?, ?, 'EPUB', '', ?, ?, ?, '', '')
                            """,
                            item.id, now, formatSize, fullText, textSize
                        )

                        indexedCount += 1
                        progress?(FTSProgress(
                            current: indexedCount,
                            total: total,
                            currentTitle: item.title
                        ))
                    }
                }
            }

            batchIndex = chunkEnd
        }

        if indexedCount > 0 {
            _ = try? ftsConn.run("INSERT INTO books_fts(books_fts) VALUES('optimize');")
            _ = try? ftsConn.run("INSERT INTO books_fts_stemmed(books_fts_stemmed) VALUES('optimize');")
            _ = try? ftsConn.run("PRAGMA wal_checkpoint(TRUNCATE);")
        }

        return indexedCount
    }

    /// Compresses and merges FTS5 segment trees, truncates WAL logs, and vacuums the database.
    /// Returns the number of bytes reclaimed on disk and the resulting total FTS file size.
    @discardableResult
    public static func compactAndVacuum(libraryURL: URL) throws -> (bytesReclaimed: Int64, ftsAfter: Int64) {
        let ftsURL = libraryURL.appendingPathComponent("full-text-search.db")
        guard FileManager.default.fileExists(atPath: ftsURL.path) else {
            return (0, 0)
        }
        let ftsBefore = databaseFilesSize(baseFileURL: ftsURL)
        let ftsConn = try Connection(ftsURL.path)
        try CalibreTokenizerRegistration.register(on: ftsConn)

        _ = try? ftsConn.run("INSERT INTO books_fts(books_fts) VALUES('optimize');")
        _ = try? ftsConn.run("INSERT INTO books_fts_stemmed(books_fts_stemmed) VALUES('optimize');")
        _ = try? ftsConn.run("PRAGMA wal_checkpoint(TRUNCATE);")
        _ = try? ftsConn.run("VACUUM;")
        _ = try? ftsConn.run("PRAGMA wal_checkpoint(TRUNCATE);")

        let ftsAfter = databaseFilesSize(baseFileURL: ftsURL)
        let reclaimed = max(0, ftsBefore - ftsAfter)
        return (bytesReclaimed: reclaimed, ftsAfter: ftsAfter)
    }

    private static func databaseFilesSize(baseFileURL: URL) -> Int64 {
        var total: Int64 = 0
        let paths = [
            baseFileURL,
            baseFileURL.deletingPathExtension().appendingPathExtension("db-wal"),
            baseFileURL.deletingPathExtension().appendingPathExtension("db-shm")
        ]
        let fm = FileManager.default
        for path in paths {
            if let attrs = try? fm.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}
