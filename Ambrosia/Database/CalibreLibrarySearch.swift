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
                clauses.append(SQLIDList.clause(column: "b.id"))
                args.append(SQLIDList.binding(ftsIDs))
            }
        } else if !query.plainTerms.isEmpty {
            let joined = query.plainTerms.joined(separator: " ")
            let (fuzzyClause, fuzzyArgs) = CalibreLibrary.fuzzyTitleCondition(for: joined)
            clauses.append(fuzzyClause)
            args.append(contentsOf: fuzzyArgs)
        }

        for (index, term) in query.tagTerms.enumerated() {
            let mode = query.scopedTagTerms.indices.contains(index) ? query.scopedTagTerms[index].mode : .contains
            switch mode {
            case .exact:
                clauses.append("EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND LOWER(t2.name) = ?)")
                args.append(term.lowercased())
            case .regex:
                clauses.append("EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND t2.name REGEXP ?)")
                args.append(term)
            case .word:
                let escaped = NSRegularExpression.escapedPattern(for: term)
                clauses.append("EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND t2.name REGEXP ?)")
                args.append("(?i)\\b\(escaped)\\b")
            case .contains:
                let expandedTerms = query.expandedTagTerms[term] ?? [term]
                let matcher = expandedTerms.map { _ in "LOWER(t2.name) LIKE ?" }.joined(separator: " OR ")
                let termArgs: [Binding?] = expandedTerms.map { "%\($0.lowercased())%" as Binding? }
                if let (clause, fragArgs) = MatchingSubqueryBuilder.tagFragment(matcher: matcher, args: termArgs, negated: false) {
                    clauses.append(clause)
                    args.append(contentsOf: fragArgs)
                }
            }
        }

        for (index, term) in query.authorTerms.enumerated() {
            let mode = query.scopedAuthorTerms.indices.contains(index) ? query.scopedAuthorTerms[index].mode : .contains
            let op: FilterOperator
            switch mode {
            case .exact: op = .equals
            case .regex: op = .matchesRegex
            case .word:  op = .matchesWord
            case .contains: op = .contains
            }
            if let (clause, fragArgs) = MatchingSubqueryBuilder.authorFragment(op: op, value: term) {
                clauses.append(clause)
                args.append(contentsOf: fragArgs)
            }
        }

        for (index, term) in query.titleTerms.enumerated() {
            let mode = query.scopedTitleTerms.indices.contains(index) ? query.scopedTitleTerms[index].mode : .contains
            switch mode {
            case .exact:
                clauses.append("LOWER(b.title) = ?")
                args.append(term.lowercased())
            case .regex:
                clauses.append("b.title REGEXP ?")
                args.append(term)
            case .word:
                let escaped = NSRegularExpression.escapedPattern(for: term)
                clauses.append("b.title REGEXP ?")
                args.append("(?i)\\b\(escaped)\\b")
            case .contains:
                clauses.append("LOWER(b.title) LIKE ?")
                args.append("%\(term.lowercased())%")
            }
        }

        for (index, term) in query.seriesTerms.enumerated() {
            let mode = query.scopedSeriesTerms.indices.contains(index) ? query.scopedSeriesTerms[index].mode : .contains
            let op: FilterOperator
            switch mode {
            case .exact: op = .equals
            case .regex: op = .matchesRegex
            case .word:  op = .matchesWord
            case .contains: op = .contains
            }
            if let (clause, fragArgs) = MatchingSubqueryBuilder.seriesFragment(op: op, value: term) {
                clauses.append(clause)
                args.append(contentsOf: fragArgs)
            }
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
            #if DEBUG
            print("[CalibreLibrary] \(message)")
            #endif
            recordSearchError(message)
            return 0
        }
    }

    private func _bookCount(query: SearchQuery) throws -> Int {
        let (qClause, qArgs) = whereClause(for: query)
        let whereSQL = qClause.isEmpty ? "" : "WHERE \(qClause)"
        let sql = """
            SELECT COUNT(DISTINCT b.id)
            FROM books b
            \(whereSQL)
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
