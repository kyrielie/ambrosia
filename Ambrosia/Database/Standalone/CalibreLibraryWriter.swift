// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite
import ZIPFoundation

public enum CalibreLibraryWriter {

    public struct ImportProgress: Sendable {
        public let current: Int
        public let total: Int
        public let currentTitle: String
    }

    /// Ingests discovered EPUB files into Calibre's `metadata.db`.
    /// Skips files whose `relativePath` already exists in `books.path`.
    @discardableResult
    public static func importEPUBs(
        epubs: [DiscoveredEPUB],
        into rootURL: URL,
        batchSize: Int = 30,
        progress: ((ImportProgress) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> Int {
        let dbURL = rootURL.appendingPathComponent("metadata.db")
        let conn = try Connection(dbURL.path)
        CalibreFunctions.register(on: conn)

        try conn.execute("PRAGMA foreign_keys = ON;")
        try conn.execute("PRAGMA journal_mode = WAL;")
        try conn.execute("PRAGMA synchronous = NORMAL;")

        // Fetch already imported paths to support incremental diffing / rescanning
        var existingPaths = Set<String>()
        if let rows = try? conn.prepare("SELECT path FROM books") {
            for row in rows {
                if let pathStr = row[0] as? String {
                    existingPaths.insert(pathStr)
                }
            }
        }

        let toImport = epubs.filter { !existingPaths.contains($0.relativePath) }
        guard !toImport.isEmpty else { return 0 }

        // In-memory lookup caches to avoid repeated SELECT queries
        var authorCache: [String: Int64] = [:]
        if let rows = try? conn.prepare("SELECT id, name FROM authors") {
            for row in rows {
                if let id = row[0] as? Int64, let name = row[1] as? String {
                    authorCache[name.lowercased()] = id
                }
            }
        }

        var tagCache: [String: Int64] = [:]
        if let rows = try? conn.prepare("SELECT id, name FROM tags") {
            for row in rows {
                if let id = row[0] as? Int64, let name = row[1] as? String {
                    tagCache[name.lowercased()] = id
                }
            }
        }

        var seriesCache: [String: Int64] = [:]
        if let rows = try? conn.prepare("SELECT id, name FROM series") {
            for row in rows {
                if let id = row[0] as? Int64, let name = row[1] as? String {
                    seriesCache[name.lowercased()] = id
                }
            }
        }

        var publisherCache: [String: Int64] = [:]
        if let rows = try? conn.prepare("SELECT id, name FROM publishers") {
            for row in rows {
                if let id = row[0] as? Int64, let name = row[1] as? String {
                    publisherCache[name.lowercased()] = id
                }
            }
        }

        let coversDir = rootURL.appendingPathComponent(".covers")
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]

        var importedCount = 0
        let total = toImport.count

        // Process in transactions of batchSize
        var batchIndex = 0
        while batchIndex < total {
            if isCancelled?() == true { break }

            let chunkEnd = min(batchIndex + batchSize, total)
            let chunk = toImport[batchIndex..<chunkEnd]

            try conn.transaction {
                for epub in chunk {
                    if isCancelled?() == true { break }

                    autoreleasepool {
                        let parsed = parseEPUBMetadata(epub: epub)
                        let nowStr = isoFormatter.string(from: Date())
                        let pubDateStr = parsed.pubDate.map { isoFormatter.string(from: $0) } ?? nowStr
                        let authorSort = CalibreFunctions.authorSort(of: parsed.authors)

                        // 1. Insert book row
                        var bookID: Int64 = 0
                        do {
                            try conn.run(
                                """
                                INSERT INTO books (title, author_sort, timestamp, pubdate,
                                                   series_index, last_modified, path, has_cover)
                                VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                                """,
                                parsed.title,
                                authorSort,
                                nowStr,
                                pubDateStr,
                                parsed.seriesIndex ?? 1.0,
                                nowStr,
                                epub.relativePath
                            )
                            bookID = conn.lastInsertRowid
                        } catch {
                            // If insert fails (e.g. edge case in trigger), skip book
                            return
                        }

                        // 2. Extract and save cover if present
                        if let coverData = parsed.coverData {
                            let coverURL = coversDir.appendingPathComponent("\(bookID).jpg")
                            if (try? coverData.write(to: coverURL)) != nil {
                                _ = try? conn.run("UPDATE books SET has_cover = 1 WHERE id = ?", bookID)
                            }
                        }

                        // 3. Insert data row
                        let fileStem = epub.fileURL.deletingPathExtension().lastPathComponent
                        _ = try? conn.run(
                            "INSERT INTO data (book, format, uncompressed_size, name) VALUES (?, 'EPUB', ?, ?)",
                            bookID, epub.fileSize, fileStem
                        )

                        // 4. Link authors
                        for author in parsed.authors where !author.isEmpty {
                            let aID = getOrCreateAuthor(name: author, conn: conn, cache: &authorCache)
                            if aID > 0 {
                                _ = try? conn.run("INSERT OR IGNORE INTO books_authors_link (book, author) VALUES (?, ?)", bookID, aID)
                            }
                        }

                        // 5. Link series
                        if let sName = parsed.seriesName, !sName.isEmpty {
                            let sID = getOrCreateSeries(name: sName, conn: conn, cache: &seriesCache)
                            if sID > 0 {
                                _ = try? conn.run("INSERT OR IGNORE INTO books_series_link (book, series) VALUES (?, ?)", bookID, sID)
                            }
                        }

                        // 6. Link publisher
                        if let pub = parsed.publisher, !pub.isEmpty {
                            let pID = getOrCreatePublisher(name: pub, conn: conn, cache: &publisherCache)
                            if pID > 0 {
                                _ = try? conn.run("INSERT OR IGNORE INTO books_publishers_link (book, publisher) VALUES (?, ?)", bookID, pID)
                            }
                        }

                        // 7. Link tags
                        for tag in parsed.tags where !tag.isEmpty {
                            let tID = getOrCreateTag(name: tag, conn: conn, cache: &tagCache)
                            if tID > 0 {
                                _ = try? conn.run("INSERT OR IGNORE INTO books_tags_link (book, tag) VALUES (?, ?)", bookID, tID)
                            }
                        }

                        // 8. Comments
                        if let comments = parsed.comments, !comments.isEmpty {
                            _ = try? conn.run("INSERT INTO comments (book, text) VALUES (?, ?)", bookID, comments)
                        }

                        // 9. Identifiers
                        for (type, val) in parsed.identifiers where !val.isEmpty {
                            _ = try? conn.run(
                                "INSERT OR IGNORE INTO identifiers (book, type, val) VALUES (?, ?, ?)",
                                bookID, type, val
                            )
                        }

                        importedCount += 1
                        progress?(ImportProgress(
                            current: importedCount,
                            total: total,
                            currentTitle: parsed.title
                        ))
                    }
                }
            }

            batchIndex = chunkEnd
        }

        return importedCount
    }

    // MARK: - Helper Types & Parsing

    private struct ExtractedMetadata {
        var title: String
        var authors: [String]
        var seriesName: String?
        var seriesIndex: Double?
        var publisher: String?
        var pubDate: Date?
        var comments: String?
        var tags: [String]
        var identifiers: [(type: String, val: String)]
        var coverData: Data?
    }

    private static func parseEPUBMetadata(epub: DiscoveredEPUB) -> ExtractedMetadata {
        var parser = EPUBParser(epubURL: epub.fileURL)
        try? parser.parse()

        var title = parser.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.lowercased() == "unknown" {
            title = epub.fileURL.deletingPathExtension().lastPathComponent
        }

        // Check for AO3 metadata in preface
        var ao3Record: AO3MetadataRecord?
        var prefaceIndex = -1

        for (idx, item) in parser.spine.prefix(5).enumerated() {
            if let html = try? parser.html(for: item, userCSS: "") {
                if let record = AO3MetadataExtractor.extract(from: html) {
                    ao3Record = record
                    prefaceIndex = idx
                    break
                }
            }
        }

        // Try extracting authors from next spine item (byline)
        var ao3Authors: [String] = []
        if let record = ao3Record, prefaceIndex >= 0 {
            let bylineRangeEnd = min(prefaceIndex + 3, parser.spine.count)
            for candidateIndex in (prefaceIndex + 1)..<bylineRangeEnd {
                let candidate = parser.spine[candidateIndex]
                if let chapterHTML = try? parser.html(for: candidate, userCSS: "") {
                    let byline = AO3MetadataExtractor.parseAuthors(from: chapterHTML)
                    if !byline.isEmpty {
                        ao3Authors = byline.map(\.username)
                        break
                    }
                }
            }
            if ao3Authors.isEmpty {
                ao3Authors = record.authors.map(\.username)
            }
        }

        // Fallback authors: OPF dc:creator
        var authors = ao3Authors.filter { !$0.isEmpty }
        if authors.isEmpty {
            authors = parser.opfCreators
                .flatMap { $0.components(separatedBy: ", ") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if authors.isEmpty {
            authors = ["Unknown"]
        }

        // Series
        var seriesName: String?
        var seriesIndex: Double?
        if let firstSeries = ao3Record?.series.first {
            seriesName = firstSeries.name
            seriesIndex = Double(firstSeries.index)
        }

        // Publisher
        let publisher = (ao3Record?.storyURL != nil || ao3Record != nil)
            ? "Archive of Our Own"
            : parser.opfPublisher

        // Date
        var pubDate: Date?
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]
        if let dateStr = ao3Record?.publishedDate ?? parser.opfDate {
            pubDate = isoFormatter.date(from: dateStr)
            if pubDate == nil {
                let ymd = DateFormatter()
                ymd.dateFormat = "yyyy-MM-dd"
                ymd.locale = Locale(identifier: "en_US_POSIX")
                pubDate = ymd.date(from: dateStr)
            }
        }

        // Description / Comments
        let comments = parser.opfDescription

        // Tags: merge OPF subjects + rich AO3 categories/tags
        var tagSet = Set<String>()
        var tags: [String] = []

        func addTag(_ tag: String) {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let lower = trimmed.lowercased()
            if !tagSet.contains(lower) {
                tagSet.insert(lower)
                tags.append(trimmed)
            }
        }

        for subject in parser.opfSubjects { addTag(subject) }
        if let ao3 = ao3Record {
            if let rating = ao3.rating { addTag(rating) }
            for warning in ao3.warnings { addTag(warning) }
            for category in ao3.categories { addTag(category) }
            for fandom in ao3.fandoms { addTag(fandom) }
            for relationship in ao3.relationships { addTag(relationship) }
            for character in ao3.characters { addTag(character) }
            for additionalTag in ao3.additionalTags { addTag(additionalTag) }
        }

        // Identifiers
        var identifiers: [(type: String, val: String)] = []
        if let workID = ao3Record?.workID {
            identifiers.append(("ao3", workID))
        }

        // Cover extraction
        let coverData = extractCover(epubURL: epub.fileURL, parser: parser)

        return ExtractedMetadata(
            title: title,
            authors: authors,
            seriesName: seriesName,
            seriesIndex: seriesIndex,
            publisher: publisher,
            pubDate: pubDate,
            comments: comments,
            tags: tags,
            identifiers: identifiers,
            coverData: coverData
        )
    }

    private static func extractCover(epubURL: URL, parser: EPUBParser) -> Data? {
        guard let archive = try? Archive(url: epubURL, accessMode: .read) else { return nil }

        // 1. Check if manifest has an entry with cover-image property (EPUB3) or id "cover" / "cover-image"
        var candidateHrefs: [String] = []
        // Look through archive entries for common cover names
        let coverFileNames: Set<String> = ["cover.jpg", "cover.jpeg", "cover.png", "titlepage.jpg"]

        for entry in archive {
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            if coverFileNames.contains(name) {
                candidateHrefs.append(entry.path)
            }
        }

        for path in candidateHrefs {
            if let entry = archive[path] {
                var data = Data()
                _ = try? archive.extract(entry) { chunk in
                    data.append(chunk)
                }
                if !data.isEmpty { return data }
            }
        }
        return nil
    }

    // MARK: - ID Lookup Helpers

    private static func getOrCreateAuthor(name: String, conn: Connection, cache: inout [String: Int64]) -> Int64 {
        let key = name.lowercased()
        if let id = cache[key] { return id }
        let sort = CalibreFunctions.authorSort(name)
        _ = try? conn.run("INSERT OR IGNORE INTO authors (name, sort) VALUES (?, ?)", name, sort)
        if let id = (try? conn.scalar("SELECT id FROM authors WHERE name = ? COLLATE NOCASE", name)) as? Int64 {
            cache[key] = id
            return id
        }
        return 0
    }

    private static func getOrCreateSeries(name: String, conn: Connection, cache: inout [String: Int64]) -> Int64 {
        let key = name.lowercased()
        if let id = cache[key] { return id }
        _ = try? conn.run("INSERT OR IGNORE INTO series (name) VALUES (?)", name)
        if let id = (try? conn.scalar("SELECT id FROM series WHERE name = ? COLLATE NOCASE", name)) as? Int64 {
            cache[key] = id
            return id
        }
        return 0
    }

    private static func getOrCreatePublisher(name: String, conn: Connection, cache: inout [String: Int64]) -> Int64 {
        let key = name.lowercased()
        if let id = cache[key] { return id }
        let sort = CalibreFunctions.titleSort(name)
        _ = try? conn.run("INSERT OR IGNORE INTO publishers (name, sort) VALUES (?, ?)", name, sort)
        if let id = (try? conn.scalar("SELECT id FROM publishers WHERE name = ? COLLATE NOCASE", name)) as? Int64 {
            cache[key] = id
            return id
        }
        return 0
    }

    private static func getOrCreateTag(name: String, conn: Connection, cache: inout [String: Int64]) -> Int64 {
        let key = name.lowercased()
        if let id = cache[key] { return id }
        _ = try? conn.run("INSERT OR IGNORE INTO tags (name) VALUES (?)", name)
        if let id = (try? conn.scalar("SELECT id FROM tags WHERE name = ? COLLATE NOCASE", name)) as? Int64 {
            cache[key] = id
            return id
        }
        return 0
    }
}
