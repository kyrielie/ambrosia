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

// MARK: - Active filter

/// Represents an optional filter narrowing the book list to a specific author or tag.
enum LibraryFilter: Equatable {
    case none
    case author(String)
    case tag(String)

    var label: String? {
        switch self {
        case .none:          return nil
        case .author(let n): return "Author: \(n)"
        case .tag(let n):    return "Tag: \(n)"
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
        // query_only is a connection-level flag — safe on a readonly connection.
        // Do NOT set journal_mode — that requires a write lock and will fail.
    }

    // MARK: - Count

    /// Total books matching the current search. Called once on open (search=nil)
    /// and debounced on search input. Never called on every page turn.
    func bookCount(search: String? = nil, filter: LibraryFilter = .none) -> Int {
        do {
            return try _bookCount(search: search, filter: filter)
        } catch {
            print("[CalibreLibrary] bookCount error: \(error)")
            return 0
        }
    }

    private func _bookCount(search: String?, filter: LibraryFilter) throws -> Int {
        switch filter {
        case .none:
            if let s = search {
                let rows = try db.prepare("SELECT COUNT(*) FROM books WHERE title LIKE ?", ["%\(s)%" as Binding?]).map { $0 }
                return (rows.first?.first as? Int64).map(Int.init) ?? 0
            } else {
                let rows = try db.prepare("SELECT COUNT(*) FROM books").map { $0 }
                return (rows.first?.first as? Int64).map(Int.init) ?? 0
            }

        case .author(let name):
            let sql = """
                SELECT COUNT(DISTINCT b.id) FROM books b
                JOIN books_authors_link bal ON bal.book = b.id
                JOIN authors a ON a.id = bal.author
                WHERE a.name = ?
                \(search != nil ? "AND b.title LIKE ?" : "")
                """
            let args: [Binding?] = search != nil ? [name as Binding?, "%\(search!)%" as Binding?] : [name as Binding?]
            let rows = try db.prepare(sql, args).map { $0 }
            return (rows.first?.first as? Int64).map(Int.init) ?? 0

        case .tag(let name):
            let sql = """
                SELECT COUNT(DISTINCT b.id) FROM books b
                JOIN books_tags_link btl ON btl.book = b.id
                JOIN tags t ON t.id = btl.tag
                WHERE t.name = ?
                \(search != nil ? "AND b.title LIKE ?" : "")
                """
            let args: [Binding?] = search != nil ? [name as Binding?, "%\(search!)%" as Binding?] : [name as Binding?]
            let rows = try db.prepare(sql, args).map { $0 }
            return (rows.first?.first as? Int64).map(Int.init) ?? 0
        }
    }

    // MARK: - Book list (pageSize + 1 rows — caller checks for next page)

    /// Fetch `limit` rows starting at `offset`. Pass `limit = pageSize + 1` to
    /// detect whether a next page exists without a separate COUNT query.
    func books(
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        search: String? = nil,
        filter: LibraryFilter = .none
    ) -> [CalibreBook] {
        do {
            let rows = try _fetchBooks(offset: offset, limit: limit,
                                       sort: sort, ascending: ascending,
                                       search: search, filter: filter)
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

    // MARK: - Private query helpers

    private func _fetchBooks(
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        search: String?,
        filter: LibraryFilter
    ) throws -> [CalibreBook] {

        let direction = ascending ? "ASC" : "DESC"

        // Build ORDER BY clause. lastOpened sorts by BookState.lastOpenedDate which
        // lives in SwiftData — fall back to title for now; Phase 2 will merge.
        let orderBy: String = {
            switch sort {
            case .title:      return "b.title \(direction)"
            case .author:     return "MIN(a.sort) \(direction), b.title ASC"
            case .wordCount:  return "COALESCE(b.custom_column_wordcount, 0) \(direction)"
            case .kudos:      return "COALESCE(b.custom_column_kudos, 0) \(direction)"
            case .published:  return "b.pubdate \(direction)"
            case .lastOpened: return "b.title \(direction)"   // Phase 2: merge with BookState
            case .series:     return "s.name \(direction), b.series_index ASC"
            }
        }()

        let sql: String
        let args: [Binding?]

        // Build fuzzy search condition
        let (fuzzyClause, fuzzyArgs): (String, [Binding?]) = search.map {
            CalibreLibrary.fuzzyTitleCondition(for: $0)
        } ?? ("", [])

        switch filter {
        case .none:
            let where_ = search != nil ? "WHERE \(fuzzyClause)" : ""
            sql = """
                SELECT DISTINCT b.id, b.title, b.path, b.pubdate, s.name, b.series_index
                FROM books b
                LEFT JOIN books_authors_link bal ON bal.book = b.id
                LEFT JOIN authors a ON a.id = bal.author
                LEFT JOIN books_series_link bsl ON bsl.book = b.id
                LEFT JOIN series s ON s.id = bsl.series
                \(where_)
                GROUP BY b.id
                ORDER BY \(orderBy)
                LIMIT ? OFFSET ?
                """
            args = search != nil
                ? fuzzyArgs + [limit as Binding?, offset as Binding?]
                : [limit as Binding?, offset as Binding?]

        case .author(let name):
            let where_ = search != nil ? "AND \(fuzzyClause)" : ""
            sql = """
                SELECT DISTINCT b.id, b.title, b.path, b.pubdate, s.name, b.series_index
                FROM books b
                JOIN books_authors_link bal ON bal.book = b.id
                JOIN authors a ON a.id = bal.author
                LEFT JOIN books_series_link bsl ON bsl.book = b.id
                LEFT JOIN series s ON s.id = bsl.series
                WHERE a.name = ?
                \(where_)
                GROUP BY b.id
                ORDER BY \(orderBy)
                LIMIT ? OFFSET ?
                """
            args = search != nil
                ? [name as Binding?] + fuzzyArgs + [limit as Binding?, offset as Binding?]
                : [name as Binding?, limit as Binding?, offset as Binding?]

        case .tag(let name):
            let where_ = search != nil ? "AND \(fuzzyClause)" : ""
            sql = """
                SELECT DISTINCT b.id, b.title, b.path, b.pubdate, s.name, b.series_index
                FROM books b
                JOIN books_tags_link btl ON btl.book = b.id
                JOIN tags t ON t.id = btl.tag
                LEFT JOIN books_series_link bsl ON bsl.book = b.id
                LEFT JOIN series s ON s.id = bsl.series
                WHERE t.name = ?
                \(where_)
                GROUP BY b.id
                ORDER BY \(orderBy)
                LIMIT ? OFFSET ?
                """
            args = search != nil
                ? [name as Binding?] + fuzzyArgs + [limit as Binding?, offset as Binding?]
                : [name as Binding?, limit as Binding?, offset as Binding?]
        }

        let rows: [[Binding?]] = try db.prepare(sql, args).map { $0 }
        return rows.compactMap { row -> CalibreBook? in
            guard let idBind    = row[0] as? Int64,
                  let titleBind = row[1] as? String,
                  let pathBind  = row[2] as? String else { return nil }
            return CalibreBook(
                id:           Int(idBind),
                title:        titleBind,
                series:       row[4] as? String,
                seriesIndex:  row[5] as? Double,
                wordCount:    nil,   // custom column — Phase 2
                kudos:        nil,   // custom column — Phase 2
                publishedDate: (row[3] as? String).flatMap(parseDate),
                relativePath: pathBind
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
    /// Expands a user search query into a SQL WHERE clause fragment that handles:
    /// - Multi-word partial matching (each word must appear somewhere in the title)
    /// - Typo tolerance via character-level trigrams for longer words
    ///
    /// Returns (whereClause, args). Caller prepends "WHERE " and appends to query.
    static func fuzzyTitleCondition(for query: String) -> (String, [Binding?]) {
        let words = query
            .lowercased()
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 2 }

        guard !words.isEmpty else { return ("1=1", []) }

        // Each word must appear in the title (AND across words, LIKE within word).
        // For words ≥ 5 chars, also accept trigrams so "poter" matches "potter".
        var clauses: [String] = []
        var args: [Binding?]  = []

        for word in words {
            if word.count >= 5 {
                // Generate trigrams and accept if any trigram matches
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
