import SQLite
import Foundation

// MARK: - Search query integration

extension CalibreLibrary {

    // MARK: - WHERE clause builder for SearchQuery

    /// Translates a `SearchQuery` into a SQL WHERE fragment and binding args.
    /// Caller is responsible for prepending "WHERE " when the clause is non-empty.
    func whereClause(for query: SearchQuery) -> (String, [Binding?]) {
        var clauses: [String] = []
        var args: [Binding?]  = []

        // FTS-matched IDs take priority over plain terms
        if let ftsIDs = query.ftsMatchedIDs {
            if ftsIDs.isEmpty {
                clauses.append("0 = 1")
            } else {
                let ph = ftsIDs.map { _ in "?" }.joined(separator: ",")
                clauses.append("b.id IN (\(ph))")
                args.append(contentsOf: ftsIDs.map { $0 as Binding? })
            }
        } else if !query.plainTerms.isEmpty {
            let joined = query.plainTerms.joined(separator: " ")
            let (fuzzyClause, fuzzyArgs) = CalibreLibrary.fuzzyTitleCondition(for: joined)
            clauses.append(fuzzyClause)
            args.append(contentsOf: fuzzyArgs)
        }

        for term in query.tagTerms {
            let expandedTerms = query.expandedTagTerms[term] ?? [term]
            if expandedTerms.count <= 1 {
                clauses.append("""
                EXISTS (
                    SELECT 1 FROM books_tags_link btl2
                    JOIN tags t2 ON t2.id = btl2.tag
                    WHERE btl2.book = b.id AND LOWER(t2.name) LIKE ?
                )
                """)
                args.append("%\((expandedTerms.first ?? term).lowercased())%" as Binding?)
            } else {
                let conditions = expandedTerms.map { _ in "LOWER(t2.name) LIKE ?" }.joined(separator: " OR ")
                clauses.append("""
                EXISTS (
                    SELECT 1 FROM books_tags_link btl2
                    JOIN tags t2 ON t2.id = btl2.tag
                    WHERE btl2.book = b.id AND (\(conditions))
                )
                """)
                args.append(contentsOf: expandedTerms.map { "%\($0.lowercased())%" as Binding? })
            }
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

        for term in query.seriesTerms {
            clauses.append("""
                EXISTS (
                    SELECT 1 FROM books_series_link bsl2
                    JOIN series s2 ON s2.id = bsl2.series
                    WHERE bsl2.book = b.id AND LOWER(s2.name) LIKE ?
                )
                """)
            args.append("%\(term.lowercased())%" as Binding?)
        }

        if clauses.isEmpty { return ("", []) }
        return (clauses.joined(separator: " AND "), args)
    }

    // MARK: - Count queries using SearchQuery

    func bookCount(query: SearchQuery) -> Int {
        do {
            let count = try _bookCount(query: query)
            clearSearchError()
            return count
        } catch {
            let message = "bookCount(query:) error: \(error)"
            print("[CalibreLibrary] \(message)")
            recordSearchError(message)
            return 0
        }
    }

    private func _bookCount(query: SearchQuery) throws -> Int {
        let (qClause, qArgs) = whereClause(for: query)
        let where_ = qClause.isEmpty ? "" : "WHERE \(qClause)"
        let sql = """
            SELECT COUNT(DISTINCT b.id)
            FROM books b
            LEFT JOIN books_authors_link bal ON bal.book = b.id
            LEFT JOIN authors a ON a.id = bal.author
            LEFT JOIN books_series_link bsl ON bsl.book = b.id
            LEFT JOIN series s ON s.id = bsl.series
            \(where_)
            """
        let rows = try db.prepare(sql, qArgs).map { $0 }
        return (rows.first?.first as? Int64).map(Int.init) ?? 0
    }

    // MARK: - Autocomplete suggestion queries

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

    func titleSuggestions(prefix: String, limit: Int = 8) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let sql = "SELECT title FROM books WHERE LOWER(title) LIKE ? ORDER BY title LIMIT ?"
        let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                           limit as Binding?]).map { $0 }) ?? []
        return rows.compactMap { $0[0] as? String }
    }

    func seriesSuggestions(prefix: String, limit: Int = 8) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let sql = "SELECT name FROM series WHERE LOWER(name) LIKE ? ORDER BY name LIMIT ?"
        let rows = (try? db.prepare(sql, ["%\(prefix.lowercased())%" as Binding?,
                                           limit as Binding?]).map { $0 }) ?? []
        return rows.compactMap { $0[0] as? String }
    }

}
