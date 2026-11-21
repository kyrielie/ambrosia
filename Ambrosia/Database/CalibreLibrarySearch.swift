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
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Tier 1 & 2: Substring matches from SQLite ordered by frequency
        let needle = trimmed.lowercased()
        let sql = """
            SELECT t.name, COUNT(btl.book) AS freq
            FROM tags t
            JOIN books_tags_link btl ON btl.tag = t.id
            WHERE LOWER(t.name) LIKE ?
            GROUP BY t.id
            ORDER BY freq DESC
            LIMIT ?
            """
        let rows = (try? db.prepare(sql, ["%\(needle)%" as Binding?, limit as Binding?]).map { $0 }) ?? []
        var results = rows.compactMap { $0[0] as? String }

        // Tier 3: Fuzzy / Acronym fallback if exact substring search produces fewer results than limit
        if results.count < limit && needle.count >= 2 {
            let existing = Set(results)
            let candidateSql = """
                SELECT t.name, COUNT(btl.book) AS freq
                FROM tags t
                JOIN books_tags_link btl ON btl.tag = t.id
                GROUP BY t.id
                ORDER BY freq DESC
                LIMIT 250
                """
            let candidateRows = (try? db.prepare(candidateSql).map { $0 }) ?? []
            var fuzzyCandidates: [(name: String, score: Double)] = []

            for row in candidateRows {
                guard let name = row[0] as? String, !existing.contains(name) else { continue }
                let freq = (row[1] as? Int64).map(Int.init) ?? 1
                let lowerName = name.lowercased()
                let words = lowerName.split(separator: " ").map(String.init)

                var matchedScore: Double = 0

                // Check acronym (e.g. "au" -> "alternate universe")
                if words.count > 1 {
                    let initials = String(words.compactMap { $0.first })
                    if initials == needle || initials.hasPrefix(needle) {
                        matchedScore = 90
                    }
                }

                // Check Damerau-Levenshtein distance against whole tag or individual words
                if matchedScore == 0 {
                    let wholeDist = Self.damerauLevenshtein(needle, lowerName, maxDistance: 2)
                    if wholeDist <= 2 {
                        matchedScore = Double(3 - wholeDist) * 30
                    } else {
                        for word in words where word.count >= 3 {
                            let dist = Self.damerauLevenshtein(needle, word, maxDistance: 2)
                            if dist <= 2 {
                                matchedScore = max(matchedScore, Double(3 - dist) * 25)
                            }
                        }
                    }
                }

                if matchedScore > 0 {
                    let totalScore = matchedScore + log(Double(max(1, freq))) * 5.0
                    fuzzyCandidates.append((name, totalScore))
                }
            }

            fuzzyCandidates.sort { $0.score > $1.score }
            for candidate in fuzzyCandidates {
                if results.count >= limit { break }
                results.append(candidate.name)
            }
        }

        return results
    }

    private static func damerauLevenshtein(_ s1: String, _ s2: String, maxDistance: Int = 2) -> Int {
        let sourceChars = Array(s1)
        let targetChars = Array(s2)
        let sourceLength = sourceChars.count
        let targetLength = targetChars.count

        if abs(sourceLength - targetLength) > maxDistance { return maxDistance + 1 }
        if sourceLength == 0 { return targetLength }
        if targetLength == 0 { return sourceLength }

        var distanceMatrix = Array(repeating: Array(repeating: 0, count: targetLength + 1), count: sourceLength + 1)
        for rowIdx in 0...sourceLength { distanceMatrix[rowIdx][0] = rowIdx }
        for colIdx in 0...targetLength { distanceMatrix[0][colIdx] = colIdx }

        for rowIdx in 1...sourceLength {
            var minInRow = Int.max
            for colIdx in 1...targetLength {
                let cost = sourceChars[rowIdx - 1] == targetChars[colIdx - 1] ? 0 : 1
                var val = min(
                    distanceMatrix[rowIdx - 1][colIdx] + 1,
                    distanceMatrix[rowIdx][colIdx - 1] + 1,
                    distanceMatrix[rowIdx - 1][colIdx - 1] + cost
                )
                if rowIdx > 1 && colIdx > 1 &&
                    sourceChars[rowIdx - 1] == targetChars[colIdx - 2] &&
                    sourceChars[rowIdx - 2] == targetChars[colIdx - 1] {
                    val = min(val, distanceMatrix[rowIdx - 2][colIdx - 2] + 1)
                }
                distanceMatrix[rowIdx][colIdx] = val
                minInRow = min(minInRow, val)
            }
            if minInRow > maxDistance {
                return maxDistance + 1
            }
        }
        return distanceMatrix[sourceLength][targetLength]
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
