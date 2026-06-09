import SQLite
import Foundation

// MARK: - Search query integration (Section I1 + I2)

extension CalibreLibrary {

    // MARK: - WHERE clause builder for SearchQuery

    /// Translates a `SearchQuery` into a SQL WHERE fragment and binding args.
    /// Caller is responsible for prepending "WHERE " when the clause is non-empty.
    func whereClause(for query: SearchQuery) -> (String, [Binding?]) {
        var clauses: [String] = []
        var args: [Binding?]  = []

        // FTS-matched IDs take priority over plain terms
        if let ftsIDs = query.ftsMatchedIDs, !ftsIDs.isEmpty {
            let ph = ftsIDs.map { _ in "?" }.joined(separator: ",")
            clauses.append("b.id IN (\(ph))")
            args.append(contentsOf: ftsIDs.map { $0 as Binding? })
        } else if !query.plainTerms.isEmpty {
            // Fall back to fuzzy SQL LIKE for plain terms
            let joined = query.plainTerms.joined(separator: " ")
            let (fuzzyClause, fuzzyArgs) = CalibreLibrary.fuzzyTitleCondition(for: joined)
            clauses.append(fuzzyClause)
            args.append(contentsOf: fuzzyArgs)
        }

        for term in query.tagTerms {
            clauses.append("""
                EXISTS (
                    SELECT 1 FROM books_tags_link btl2
                    JOIN tags t2 ON t2.id = btl2.tag
                    WHERE btl2.book = b.id AND LOWER(t2.name) LIKE ?
                )
                """)
            args.append("%\(term.lowercased())%" as Binding?)
        }

        for term in query.authorTerms {
            clauses.append("""
                EXISTS (
                    SELECT 1 FROM books_authors_link bal2
                    JOIN authors a2 ON a2.id = bal2.author
                    WHERE bal2.book = b.id AND LOWER(a2.name) LIKE ?
                )
                """)
            args.append("%\(term.lowercased())%" as Binding?)
        }

        for term in query.titleTerms {
            clauses.append("LOWER(b.title) LIKE ?")
            args.append("%\(term.lowercased())%" as Binding?)
        }

        if clauses.isEmpty { return ("", []) }
        return (clauses.joined(separator: " AND "), args)
    }

    // MARK: - SearchQuery-based fetch (main overload)

    /// Fetch a page of books using a structured `SearchQuery`.
    /// This is the preferred path from I1 onwards; the `search: String?` overload
    /// remains for backwards compatibility and wraps via `SearchQueryParser.parse`.
    func books(
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery,
        filter: LibraryFilter = .none
    ) -> [CalibreBook] {
        do {
            let rows = try _fetchBooksQuery(
                offset: offset, limit: limit,
                sort: sort, ascending: ascending,
                query: query, filter: filter)
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
            print("[CalibreLibrary] books(query:) error: \(error)")
            return []
        }
    }

    /// Fetch a page of books from an explicit ID set using a `SearchQuery` for further filtering.
    func books(
        ids: [Int]?,
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery
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

    // MARK: - Private fetch helpers

    private func _fetchBooksQuery(
        offset: Int,
        limit: Int,
        sort: SortField,
        ascending: Bool,
        query: SearchQuery,
        filter: LibraryFilter
    ) throws -> [CalibreBook] {
        let direction = ascending ? "ASC" : "DESC"
        let orderBy   = orderByClause(sort: sort, direction: direction)

        let (qClause, qArgs) = whereClause(for: query)

        var conditions: [String] = []
        var args: [Binding?]     = []

        switch filter {
        case .none:
            break
        case .author(let name):
            // Author filter handled via JOIN; inject condition
            conditions.append("a.name = ?")
            args.append(name as Binding?)
        case .tag(let name):
            conditions.append("""
                EXISTS (
                    SELECT 1 FROM books_tags_link btl_f
                    JOIN tags t_f ON t_f.id = btl_f.tag
                    WHERE btl_f.book = b.id AND t_f.name = ?
                )
                """)
            args.append(name as Binding?)
        }

        if !qClause.isEmpty {
            conditions.append(qClause)
            args.append(contentsOf: qArgs)
        }

        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let authorJoin: String
        if case .author = filter {
            authorJoin = "JOIN books_authors_link bal ON bal.book = b.id JOIN authors a ON a.id = bal.author"
        } else {
            authorJoin = "LEFT JOIN books_authors_link bal ON bal.book = b.id LEFT JOIN authors a ON a.id = bal.author"
        }

        let sql = """
            SELECT DISTINCT b.id, b.title, b.path, b.pubdate, s.name, b.series_index
            FROM books b
            \(authorJoin)
            LEFT JOIN books_series_link bsl ON bsl.book = b.id
            LEFT JOIN series s ON s.id = bsl.series
            \(where_)
            GROUP BY b.id
            ORDER BY \(orderBy)
            LIMIT ? OFFSET ?
            """
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
        args.append(contentsOf: [limit as Binding?, offset as Binding?])
        return try _mapBookRows(db.prepare(sql, args).map { $0 })
    }

    private func orderByClause(sort: SortField, direction: String) -> String {
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
                relativePath:  pathBind
            )
        }
    }

    // MARK: - Autocomplete suggestion queries (Section I2)

    /// Tags whose name contains `prefix`, sorted by frequency (most-used first).
    func tagSuggestions(prefix: String, limit: Int = 8) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let sql = """
            SELECT t.name, COUNT(btl.book) AS freq
            FROM tags t
            JOIN books_tags_link btl ON btl.tag = t.id
            WHERE LOWER(t.name) LIKE ?
            GROUP BY t.id
            ORDER BY freq DESC
            LIMIT ?
            """
        let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                           limit as Binding?]).map { $0 }) ?? []
        return rows.compactMap { $0[0] as? String }
    }

    /// Author names containing `prefix`, sorted alphabetically.
    func authorSuggestions(prefix: String, limit: Int = 8) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let sql = """
            SELECT a.name FROM authors a
            WHERE LOWER(a.name) LIKE ?
            ORDER BY a.sort
            LIMIT ?
            """
        let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                           limit as Binding?]).map { $0 }) ?? []
        return rows.compactMap { $0[0] as? String }
    }

    /// Book titles containing `prefix`, sorted alphabetically.
    func titleSuggestions(prefix: String, limit: Int = 8) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let sql = "SELECT title FROM books WHERE LOWER(title) LIKE ? ORDER BY title LIMIT ?"
        let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                           limit as Binding?]).map { $0 }) ?? []
        return rows.compactMap { $0[0] as? String }
    }
}
