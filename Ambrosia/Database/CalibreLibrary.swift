import SQLite
import Foundation

// MARK: - Sort field

enum SortField: String, CaseIterable, Identifiable {
    case title, author, wordCount, kudos, published, lastOpened, series
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title:      return "Title"
        case .author:     return "Author"
        case .wordCount:  return "Word Count"
        case .kudos:      return "Kudos"
        case .published:  return "Published"
        case .lastOpened: return "Last Opened"
        case .series:     return "Series"
        }
    }
}

// MARK: - CalibreLibrary

/// Read-only query layer over Calibre's metadata.db.
/// All queries are synchronous — SQLite on a local file returns in <1ms.
/// One instance per open library; replaced wholesale when the user switches libraries.
final class CalibreLibrary {

    let root: URL                   // absolute path to the Calibre library folder
    internal let db: Connection

    // Cached column expressions
    private let booksTable   = Table("books")
    private let idCol        = Expression<Int>("id")
    private let titleCol     = Expression<String>("title")
    private let pathCol      = Expression<String>("path")
    private let pubdateCol   = Expression<String?>("pubdate")
    private let seriesIdxCol = Expression<Double?>("series_index")

    init(root: URL) throws {
        self.root = root
        let dbPath = root.appendingPathComponent("metadata.db").path
        db = try Connection(dbPath, readonly: true)
    }

    // MARK: - Count

    /// Total books. Called once on open and refreshed after debounced search.
    func bookCount() -> Int {
        let rows = (try? db.prepare("SELECT COUNT(*) FROM books").map { $0 }) ?? []
        return (rows.first?.first as? Int64).map(Int.init) ?? 0
    }

    func allBookIDs() -> [Int] {
        let rows = (try? db.prepare("SELECT id FROM books ORDER BY id").map { $0 }) ?? []
        return rows.compactMap { row in
            if let value = row.first as? Int64 { return Int(value) }
            return row.first as? Int
        }
    }

    func allCalibreSeriesEntries() -> [SeriesCacheEntry] {
        let sql = """
        SELECT b.id, s.name, b.series_index
        FROM books b
        JOIN books_series_link bsl ON bsl.book = b.id
        JOIN series s ON s.id = bsl.series
        WHERE s.name IS NOT NULL AND TRIM(s.name) != ''
        ORDER BY s.name, b.series_index
        """
        let rows = (try? db.prepare(sql).map { $0 }) ?? []
        return rows.compactMap { row in
            guard let idBind = row[0] as? Int64,
                  let name = row[1] as? String else { return nil }
            let index: Int
            if let raw = row[2] as? Double {
                index = Int(raw.rounded())
            } else if let raw = row[2] as? Int64 {
                index = Int(raw)
            } else {
                index = 1
            }
            return SeriesCacheEntry(
                calibreID: Int(idBind),
                seriesName: name,
                seriesIndex: index,
                ao3SeriesID: nil,
                isAnthology: false
            )
        }
    }

    func anthologyBookIDs() -> Set<Int> {
        let rows = (try? db.prepare(
            """
            SELECT book
            FROM comments
            WHERE LOWER(LTRIM(text)) LIKE 'anthology%'
            """
        ).map { $0 }) ?? []
        return Set(rows.compactMap { row in
            if let value = row[0] as? Int64 { return Int(value) }
            return row[0] as? Int
        })
    }

    func ao3PublisherBookIDs() -> Set<Int> {
        let sql = """
        SELECT bpl.book
        FROM books_publishers_link bpl
        JOIN publishers p ON p.id = bpl.publisher
        WHERE TRIM(p.name) = 'Archive of Our Own'
        """
        let rows = (try? db.prepare(sql).map { $0 }) ?? []
        return Set(rows.compactMap { row in
            if let value = row[0] as? Int64 { return Int(value) }
            return row[0] as? Int
        })
    }

    // MARK: - Book list (pageSize + 1 rows — caller checks for next page)

    /// Fetch `limit` rows starting at `offset` using a structured SearchQuery.
    /// Pass `limit = pageSize + 1` to detect next page without a COUNT query.
    func books(
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: []),
        filter: FilterExpression? = nil
    ) -> [CalibreBook] {
        do {
            let rows = try _fetchBooks(offset: offset, limit: limit,
                                       sort: sort, ascending: ascending,
                                       query: query)
            let ids = rows.map(\.id)
            let authorsMap  = try _authors(for: ids)
            let tagsMap     = try _tags(for: ids)
            let commentsMap = try _comments(for: ids)
            return rows.map { book in
                var b = book
                b.authors = authorsMap[book.id] ?? []
                b.tags    = tagsMap[book.id] ?? []
                b.comment = commentsMap[book.id]
                return b
            }
        } catch {
            print("[CalibreLibrary] books error: \(error)")
            return []
        }
    }

    /// Fetch from an explicit ID set with optional additional SearchQuery filtering.
    func books(
        ids: [Int]?,
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
    ) -> [CalibreBook] {
        do {
            let rows = try _fetchBooksQueryIDs(
                ids: ids, offset: offset, limit: limit,
                sort: sort, ascending: ascending, query: query)
            let fetchedIDs = rows.map(\.id)
            let authorsMap  = try _authors(for: fetchedIDs)
            let tagsMap     = try _tags(for: fetchedIDs)
            let commentsMap = try _comments(for: fetchedIDs)
            return rows.map { book in
                var b = book
                b.authors = authorsMap[book.id] ?? []
                b.tags    = tagsMap[book.id] ?? []
                b.comment = commentsMap[book.id]
                return b
            }
        } catch {
            print("[CalibreLibrary] books(ids:query:) error: \(error)")
            return []
        }
    }

    func booksForIDs(_ ids: [Int]) -> [CalibreBook] {
        guard !ids.isEmpty else { return [] }
        do {
            let rows = try _fetchBooksQueryIDs(
                ids: ids,
                offset: 0,
                limit: max(ids.count, 1),
                sort: .title,
                ascending: true,
                query: SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
            )
            let fetchedIDs = rows.map(\.id)
            let authorsMap = try _authors(for: fetchedIDs)
            let tagsMap = try _tags(for: fetchedIDs)
            let commentsMap = try _comments(for: fetchedIDs)
            return rows.map { book in
                var b = book
                b.authors = authorsMap[book.id] ?? []
                b.tags = tagsMap[book.id] ?? []
                b.comment = commentsMap[book.id]
                return b
            }
        } catch {
            print("[CalibreLibrary] booksForIDs error: \(error)")
            return []
        }
    }

    // MARK: - Private fetch helpers

    private func _fetchBooks(
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery
    ) throws -> [CalibreBook] {
        let direction = ascending ? "ASC" : "DESC"
        let orderBy   = orderByClause(sort: sort, direction: direction)

        let (qClause, qArgs) = whereClause(for: query)
        let where_ = qClause.isEmpty ? "" : "WHERE \(qClause)"

        let sql = """
            SELECT DISTINCT b.id, b.title, b.path, b.pubdate, s.name, b.series_index, p.name
            FROM books b
            LEFT JOIN books_authors_link bal ON bal.book = b.id
            LEFT JOIN authors a ON a.id = bal.author
            LEFT JOIN books_series_link bsl ON bsl.book = b.id
            LEFT JOIN series s ON s.id = bsl.series
            LEFT JOIN books_publishers_link bpl ON bpl.book = b.id
            LEFT JOIN publishers p ON p.id = bpl.publisher
            \(where_)
            GROUP BY b.id
            ORDER BY \(orderBy)
            LIMIT ? OFFSET ?
            """
        var args: [Binding?] = qArgs
        args.append(contentsOf: [limit as Binding?, offset as Binding?])
        return try _mapBookRows(db.prepare(sql, args).map { $0 })
    }

    private func _fetchBooksQueryIDs(
        ids: [Int]?,
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery
    ) throws -> [CalibreBook] {
        let direction = ascending ? "ASC" : "DESC"
        let orderBy   = orderByClause(sort: sort, direction: direction)

        var conditions: [String] = []
        var args: [Binding?]     = []

        if let idList = ids, !idList.isEmpty {
            let ph = idList.map { _ in "?" }.joined(separator: ",")
            conditions.append("b.id IN (\(ph))")
            args.append(contentsOf: idList.map { $0 as Binding? })
        }

        let (qClause, qArgs) = whereClause(for: query)
        if !qClause.isEmpty {
            conditions.append(qClause)
            args.append(contentsOf: qArgs)
        }

        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
            SELECT DISTINCT b.id, b.title, b.path, b.pubdate, s.name, b.series_index, p.name
            FROM books b
            LEFT JOIN books_authors_link bal ON bal.book = b.id
            LEFT JOIN authors a ON a.id = bal.author
            LEFT JOIN books_series_link bsl ON bsl.book = b.id
            LEFT JOIN series s ON s.id = bsl.series
            LEFT JOIN books_publishers_link bpl ON bpl.book = b.id
            LEFT JOIN publishers p ON p.id = bpl.publisher
            \(where_)
            GROUP BY b.id
            ORDER BY \(orderBy)
            LIMIT ? OFFSET ?
            """
        args.append(contentsOf: [limit as Binding?, offset as Binding?])
        return try _mapBookRows(db.prepare(sql, args).map { $0 })
    }

    internal func orderByClause(sort: SortField, direction: String) -> String {
        switch sort {
        case .title:      return "b.title \(direction)"
        case .author:     return "MIN(a.sort) \(direction), b.title ASC"
        case .wordCount:  return "COALESCE(b.custom_column_wordcount, 0) \(direction)"
        case .kudos:      return "COALESCE(b.custom_column_kudos, 0) \(direction)"
        case .published:  return "b.pubdate \(direction)"
        case .lastOpened: return "b.title \(direction)"
        case .series:     return "s.name \(direction), b.series_index ASC"
        }
    }

    private func _mapBookRows(_ rows: [[Binding?]]) throws -> [CalibreBook] {
        rows.compactMap { row -> CalibreBook? in
            guard let idBind    = row[0] as? Int64,
                  let titleBind = row[1] as? String,
                  let pathBind  = row[2] as? String else { return nil }
            return CalibreBook(
                id:            Int(idBind),
                title:         titleBind,
                series:        row[4] as? String,
                seriesIndex:   row[5] as? Double,
                wordCount:     nil,
                kudos:         nil,
                publishedDate: (row[3] as? String).flatMap(parseDate),
                publisher:     row[6] as? String,
                relativePath:  pathBind
            )
        }
    }

    // MARK: - Bulk JOIN queries (one per data type per page)

    internal func _authors(for ids: [Int]) throws -> [Int: [String]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT bal.book, a.name FROM books_authors_link bal
            JOIN authors a ON a.id = bal.author
            WHERE bal.book IN (\(placeholders))
            ORDER BY bal.book, a.sort
            """
        let args = ids.map { $0 as Binding? }
        var result: [Int: [String]] = [:]
        for row in try db.prepare(sql, args).map({ $0 }) {
            guard let cidBind = row[0] as? Int64,
                  let name   = row[1] as? String else { continue }
            let cid = Int(cidBind)
            result[cid, default: []].append(name)
        }
        return result
    }

    internal func _tags(for ids: [Int]) throws -> [Int: [String]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT btl.book, t.name FROM books_tags_link btl
            JOIN tags t ON t.id = btl.tag
            WHERE btl.book IN (\(placeholders))
            ORDER BY btl.book, t.name
            """
        let args = ids.map { $0 as Binding? }
        var result: [Int: [String]] = [:]
        for row in try db.prepare(sql, args).map({ $0 }) {
            guard let cidBind = row[0] as? Int64,
                  let name   = row[1] as? String else { continue }
            let cid = Int(cidBind)
            result[cid, default: []].append(name)
        }
        return result
    }

    internal func _comments(for ids: [Int]) throws -> [Int: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT book, text FROM comments WHERE book IN (\(placeholders))"
        let args = ids.map { $0 as Binding? }
        var result: [Int: String] = [:]
        for row in try db.prepare(sql, args).map({ $0 }) {
            guard let cidBind = row[0] as? Int64,
                  let text   = row[1] as? String else { continue }
            result[Int(cidBind)] = text
        }
        return result
    }

    // MARK: - EPUB path

    func epubURL(calibreID: Int) -> URL? {
        guard let row = try? db.pluck(
            booksTable.select(pathCol).filter(idCol == calibreID)
        ) else { return nil }
        let folder = root.appendingPathComponent(row[pathCol])
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.pathExtension.lowercased() == "epub" }
    }

    // MARK: - Date parsing

    internal func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string)
    }
}

// MARK: - Fuzzy search helper

extension CalibreLibrary {
    static func fuzzyTitleCondition(for query: String) -> (String, [Binding?]) {
        let words = query
            .lowercased()
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 2 }

        guard !words.isEmpty else { return ("1=1", []) }

        var clauses: [String] = []
        var args: [Binding?]  = []

        for word in words {
            if word.count >= 5 {
                let trigrams = Self.trigrams(for: word)
                let trigramClauses = trigrams.map { _ in "LOWER(b.title) LIKE ?" }
                    .joined(separator: " OR ")
                let exactClause = "LOWER(b.title) LIKE ?"
                clauses.append("(\(exactClause) OR \(trigramClauses))")
                args.append("%\(word)%" as Binding?)
                for t in trigrams { args.append("%\(t)%" as Binding?) }
            } else {
                clauses.append("LOWER(b.title) LIKE ?")
                args.append("%\(word)%" as Binding?)
            }
        }

        return (clauses.joined(separator: " AND "), args)
    }

    private static func trigrams(for word: String) -> [String] {
        let chars = Array(word)
        guard chars.count >= 3 else { return [word] }
        return (0...(chars.count - 3)).map { String(chars[$0..<$0+3]) }
    }
}
