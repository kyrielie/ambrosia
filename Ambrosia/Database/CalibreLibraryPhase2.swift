import SQLite
import Foundation

// MARK: - Phase 2 extensions to CalibreLibrary

extension CalibreLibrary {

    // MARK: - Books filtered to an explicit ID set (used after FilterBuilder)

    /// Fetch a page of books restricted to the given set of Calibre IDs.
    /// Pass `ids: nil` to mean "all books" (i.e. no active filter).
    func books(
        ids: [Int]?,
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        search: String? = nil
    ) -> [CalibreBook] {
        do {
            let rows = try _fetchBooks(
                ids: ids, offset: offset, limit: limit,
                sort: sort, ascending: ascending, search: search)
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
            print("[CalibreLibrary] books(ids:) error: \(error)")
            return []
        }
    }

    /// Count books within a given ID set (for the footer when a filter is active).
    func bookCount(ids: [Int]) -> Int {
        guard !ids.isEmpty else { return 0 }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT COUNT(*) FROM books WHERE id IN (\(placeholders))"
        let args = ids.map { $0 as Binding? }
        return (try? db.scalar(sql, args) as? Int64).map(Int.init) ?? 0
    }

    private func _fetchBooks(
        ids: [Int]?,
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        search: String?
    ) throws -> [CalibreBook] {
        let direction = ascending ? "ASC" : "DESC"

        let orderBy: String = {
            switch sort {
            case .title:      return "b.title \(direction)"
            case .author:     return "MIN(a.sort) \(direction), b.title ASC"
            case .wordCount:  return "COALESCE(wc.value, 0) \(direction)"
            case .kudos:      return "COALESCE(k.value, 0) \(direction)"
            case .published:  return "b.pubdate \(direction)"
            case .lastOpened: return "b.title \(direction)"
            case .series:     return "s.name \(direction), b.series_index ASC"
            }
        }()

        // Custom column LEFT JOINs (only when sorting by them)
        let wcJoin: String = {
            guard sort == .wordCount, let tbl = customColumnTableName(label: "words")
                    ?? customColumnTableName(label: "word_count")
                    ?? customColumnTableName(label: "wordcount")
            else { return "" }
            return "LEFT JOIN \(tbl) wc ON wc.book = b.id"
        }()
        let kJoin: String = {
            guard sort == .kudos, let tbl = customColumnTableName(label: "kudos")
            else { return "" }
            return "LEFT JOIN \(tbl) k ON k.book = b.id"
        }()

        var conditions: [String] = []
        var args: [Binding?]      = []

        if let idList = ids, !idList.isEmpty {
            let ph = idList.map { _ in "?" }.joined(separator: ",")
            conditions.append("b.id IN (\(ph))")
            args.append(contentsOf: idList.map { $0 as Binding? })
        }
        if let s = search, !s.isEmpty {
            conditions.append("b.title LIKE ?")
            args.append("%\(s)%" as Binding?)
        }

        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
            SELECT DISTINCT b.id, b.title, b.path, b.pubdate, s.name, b.series_index
            FROM books b
            LEFT JOIN books_authors_link bal ON bal.book = b.id
            LEFT JOIN authors a ON a.id = bal.author
            LEFT JOIN books_series_link bsl ON bsl.book = b.id
            LEFT JOIN series s ON s.id = bsl.series
            \(wcJoin)
            \(kJoin)
            \(where_)
            GROUP BY b.id
            ORDER BY \(orderBy)
            LIMIT ? OFFSET ?
            """
        args.append(contentsOf: [limit as Binding?, offset as Binding?])

        let rows: [[Binding?]] = try db.prepare(sql, args).map { $0 }
        return rows.compactMap { row -> CalibreBook? in
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
                relativePath:  pathBind
            )
        }
    }

    // MARK: - Custom column discovery

    struct CustomColumn {
        let id: Int
        let label: String
        let dataType: String
        var tableName: String { "custom_column_\(id)" }
    }

    /// Returns all custom columns defined in the library.
    func customColumns() -> [CustomColumn] {
        let sql = "SELECT id, label, datatype FROM custom_columns"
        guard let rows = try? db.prepare(sql, []).map({ $0 }) else { return [] }
        return rows.compactMap { row -> CustomColumn? in
            guard let id    = (row[0] as? Int64).map(Int.init),
                  let label = row[1] as? String,
                  let dtype = row[2] as? String else { return nil }
            return CustomColumn(id: id, label: label.lowercased(), dataType: dtype)
        }
    }

    /// Returns the table name (e.g. "custom_column_3") for a given column label,
    /// case-insensitively. Returns nil if no matching column exists.
    func customColumnTableName(label: String) -> String? {
        customColumns().first {
            $0.label == label.lowercased()
        }?.tableName
    }

    /// Reads the integer value for a custom column for a single book.
    func customColumnInt(calibreID: Int, columnLabel: String) -> Int? {
        guard let tbl = customColumnTableName(label: columnLabel) else { return nil }
        let sql = "SELECT value FROM \(tbl) WHERE book = ?"
        guard let rows = try? db.prepare(sql, [calibreID as Binding?]).map({ $0 }),
              let first = rows.first,
              let v = first[0] as? Int64 else { return nil }
        return Int(v)
    }

}

