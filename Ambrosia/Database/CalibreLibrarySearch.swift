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
        if let ftsIDs = query.ftsMatchedIDs, !ftsIDs.isEmpty {
            let ph = ftsIDs.map { _ in "?" }.joined(separator: ",")
            clauses.append("b.id IN (\(ph))")
            args.append(contentsOf: ftsIDs.map { $0 as Binding? })
        } else if !query.plainTerms.isEmpty {
            let joined = query.plainTerms.joined(separator: " ")
            let (fuzzyClause, fuzzyArgs) = CalibreLibrary.fuzzyTitleCondition(for: joined)
            clauses.append(fuzzyClause)
            args.append(contentsOf: fuzzyArgs)
        }

        for term in query.tagTerms {
            let expandedTerms = expandedAO3TagTerms(for: term)
            if expandedTerms.count <= 1 {
                clauses.append("""
                EXISTS (
                    SELECT 1 FROM books_tags_link btl2
                    JOIN tags t2 ON t2.id = btl2.tag
                    WHERE btl2.book = b.id AND LOWER(t2.name) LIKE ?
                )
                """)
                args.append("%\(term.lowercased())%" as Binding?)
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
            return try _bookCount(query: query)
        } catch {
            print("[CalibreLibrary] bookCount(query:) error: \(error)")
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

    private func expandedAO3TagTerms(for term: String) -> [String] {
        guard AO3TagSeedDatabaseConfig.shared.isEnabled,
              AO3TagSeedDatabaseConfig.shared.validDatabaseURLIfEnabled() != nil,
              let libraryURL = LibraryRegistry.shared.activeURL else { return [term] }
        do {
            let hash = Ambrosia.libraryHash(for: libraryURL)
            let metaURL = try AmbrosiaMetaDB.librariesBaseDirectory()
                .appendingPathComponent(hash)
                .appendingPathComponent("ambrosia_meta.db")
            guard FileManager.default.fileExists(atPath: metaURL.path) else { return [term] }
            let meta = try Connection(metaURL.path, readonly: true)
            let sql = """
            WITH RECURSIVE
            roots(id) AS (
                SELECT id FROM canonical_tags WHERE LOWER(name) = LOWER(?)
                UNION
                SELECT canonical_id FROM tag_synonyms WHERE LOWER(synonym) = LOWER(?)
            ),
            descendants(id) AS (
                SELECT id FROM roots
                UNION
                SELECT l.child_id
                FROM tag_parent_links l
                JOIN descendants d ON d.id = l.parent_id
            )
            SELECT name FROM canonical_tags WHERE id IN (SELECT id FROM descendants)
            UNION
            SELECT synonym
            FROM tag_synonyms
            WHERE canonical_id IN (SELECT id FROM descendants)
            """
            let rows = try meta.prepare(sql, [term as Binding?, term as Binding?]).map { $0 }
            var seen = Set<String>()
            var terms = [term]
            seen.insert(term.lowercased())
            for row in rows {
                guard let value = row[0] as? String else { continue }
                let key = value.lowercased()
                if seen.insert(key).inserted {
                    terms.append(value)
                }
            }
            return terms
        } catch {
            return [term]
        }
    }
}
