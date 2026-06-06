import Foundation
import SwiftData
import SQLite

// MARK: - FilterResult

struct FilterResult {
    let calibreIDs: [Int]
    let totalCount: Int
}

// MARK: - FilterBuilder

struct FilterBuilder {

    let library: CalibreLibrary

    /// Evaluate a full FilterExpression (multiple groups joined by groupConjunction).
    func matchingIDs(expression: FilterExpression, likedIDs: Set<Int>) -> FilterResult {
        let completeGroups = expression.groups.filter(\.isComplete)
        guard !completeGroups.isEmpty else {
            return FilterResult(calibreIDs: [], totalCount: library.bookCount())
        }

        // Evaluate each group independently, then combine with groupConjunction
        let groupResults: [Set<Int>] = completeGroups.map { group in
            Set(matchingIDsForGroup(group, likedIDs: likedIDs))
        }

        let finalIDs: [Int]
        switch expression.groupConjunction {
        case .or:
            // Union: book matches if it satisfies ANY group
            let union = groupResults.reduce(Set<Int>()) { $0.union($1) }
            finalIDs = Array(union).sorted()
        case .and:
            // Intersection: book must satisfy ALL groups
            guard let first = groupResults.first else { finalIDs = []; break }
            let intersection = groupResults.dropFirst().reduce(first) { $0.intersection($1) }
            finalIDs = Array(intersection).sorted()
        }

        return FilterResult(calibreIDs: finalIDs, totalCount: finalIDs.count)
    }

    private func matchingIDsForGroup(_ group: FilterGroup, likedIDs: Set<Int>) -> [Int] {
        let complete = group.completeRules
        guard !complete.isEmpty else { return library.allCalibreIDs() }

        let sqlRules = complete.filter { $0.field != .isLiked }
        let appRules = complete.filter { $0.field == .isLiked }

        var ids: [Int]
        if sqlRules.isEmpty {
            ids = library.allCalibreIDs()
        } else {
            ids = library.calibreIDs(matchingRules: sqlRules, conjunction: group.conjunction)
        }

        if !appRules.isEmpty {
            ids = ids.filter { likedIDs.contains($0) }
        }
        return ids
    }

    // Legacy single-group entry point — used by quick tag/author taps
    func matchingIDs(rules: [FilterRule], conjunction: FilterConjunction,
                     likedIDs: Set<Int>) -> FilterResult {
        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: rules, conjunction: conjunction)]
        return matchingIDs(expression: expr, likedIDs: likedIDs)
    }
}

// MARK: - CalibreLibrary SQL filter extension

extension CalibreLibrary {

    func allCalibreIDs() -> [Int] {
        let sql = "SELECT id FROM books ORDER BY id"
        guard let rows = try? db_prepare(sql, []) else { return [] }
        return rows.compactMap { row in (row[0] as? Int64).map(Int.init) }
    }

    func calibreIDs(matchingRules rules: [FilterRule], conjunction: FilterConjunction) -> [Int] {
        guard !rules.isEmpty else { return allCalibreIDs() }

        var clauses: [String] = []
        var args: [Binding?]  = []

        for rule in rules {
            if let (clause, ruleArgs) = sqlFragment(for: rule) {
                clauses.append(clause)
                args.append(contentsOf: ruleArgs)
            }
        }

        guard !clauses.isEmpty else { return allCalibreIDs() }

        // Build JOIN clause — only add joins actually required by the rules
        let needsAuthorJoin  = rules.contains { $0.field == .authorName }
        let needsTagJoin     = rules.contains { [.tag, .rating, .warning, .category].contains($0.field) }
        let needsSeriesJoin  = rules.contains { $0.field == .series }
        let needsCommentJoin = rules.contains { $0.field == .comment }

        var joins: [String] = []
        if needsAuthorJoin {
            joins.append("LEFT JOIN books_authors_link bal ON bal.book = b.id")
            joins.append("LEFT JOIN authors a ON a.id = bal.author")
        }
        if needsTagJoin {
            joins.append("LEFT JOIN books_tags_link btl ON btl.book = b.id")
            joins.append("LEFT JOIN tags t ON t.id = btl.tag")
        }
        if needsSeriesJoin {
            joins.append("LEFT JOIN books_series_link bsl ON bsl.book = b.id")
            joins.append("LEFT JOIN series s ON s.id = bsl.series")
        }
        if needsCommentJoin {
            joins.append("LEFT JOIN comments c ON c.book = b.id")
        }

        let joinClause = joins.joined(separator: "\n")
        let op         = conjunction == .and ? " AND " : " OR "
        let where_     = "WHERE " + clauses.joined(separator: op)

        let sql = """
            SELECT DISTINCT b.id FROM books b
            \(joinClause)
            \(where_)
            ORDER BY b.id
            """

        guard let rows = try? db_prepare(sql, args) else { return [] }
        return rows.compactMap { row in (row[0] as? Int64).map(Int.init) }
    }

    // MARK: - SQL fragment builder

    // swiftlint:disable cyclomatic_complexity
    private func sqlFragment(for rule: FilterRule) -> (String, [Binding?])? {
        let v = rule.value.trimmingCharacters(in: .whitespaces)

        switch rule.field {

        case .title:
            return textFragment(column: "b.title", op: rule.op, value: v)

        case .series:
            // Series name is in the series table — requires needsSeriesJoin = true
            return textFragment(column: "s.name", op: rule.op, value: v,
                                nullClause: "s.name IS NULL")

        case .comment:
            return textFragment(column: "c.text", op: rule.op, value: v,
                                nullClause: "c.text IS NULL")

        case .authorName:
            return textFragment(column: "a.name", op: rule.op, value: v)

        case .tag:
            // Correlated subquery ensures AND works across multi-value tag fields.
            switch rule.op {
            case .contains:
                return ("b.id IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name LIKE ?)", ["%\(v)%"])
            case .notContains:
                return ("b.id NOT IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name LIKE ?)", ["%\(v)%"])
            case .equals:
                return ("b.id IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name = ?)", [v])
            case .notEquals:
                return ("b.id NOT IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name = ?)", [v])
            case .startsWith:
                return ("b.id IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name LIKE ?)", ["\(v)%"])
            }
        case .rating:
            return ao3TagFragment(op: rule.op, value: v)

        case .warning:
            return ao3TagFragment(op: rule.op, value: v)

        case .category:
            return ao3TagFragment(op: rule.op, value: v)

        case .wordCountGT:
            guard let n = rule.numericValue else { return nil }
            return (wordCountSQL(sqlOp: ">"), [n as Binding?])

        case .wordCountLT:
            guard let n = rule.numericValue else { return nil }
            return (wordCountSQL(sqlOp: "<"), [n as Binding?])

        case .kudosGT:
            guard let n = rule.numericValue else { return nil }
            return (kudosSQL(sqlOp: ">"), [n as Binding?])

        case .kudosLT:
            guard let n = rule.numericValue else { return nil }
            return (kudosSQL(sqlOp: "<"), [n as Binding?])

        case .isLiked:
            return nil
        }
    }

    // MARK: - Fragment helpers

    /// Generic text column fragment. Handles all four operators correctly,
    /// including NULL-safe NOT clauses.
    private func textFragment(column: String, op: FilterOperator, value: String,
                              nullClause: String? = nil) -> (String, [Binding?])? {
        let null = nullClause.map { "(\($0) OR " } ?? ""
        let end  = nullClause != nil ? ")" : ""
        switch op {
        case .contains:
            return ("\(column) LIKE ?", ["%\(value)%"])
        case .notContains:
            return ("\(null)\(column) NOT LIKE ?\(end)", ["%\(value)%"])
        case .equals:
            return ("\(column) = ?", [value])
        case .notEquals:
            return ("\(null)\(column) != ?\(end)", [value])
        case .startsWith:
            return ("\(column) LIKE ?", ["\(value)%"])
        }
    }

    /// AO3 metadata (rating/warning/category) — all stored as tags in Calibre.
    /// Uses subquery so AND conjunction works correctly across multi-value fields.
    private func ao3TagFragment(op: FilterOperator, value: String) -> (String, [Binding?])? {
        switch op {
        case .equals:
            return ("b.id IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name = ?)", [value])
        case .notEquals:
            return ("b.id NOT IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name = ?)", [value])
        case .contains:
            return ("b.id IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name LIKE ?)", ["%\(value)%"])
        case .notContains:
            return ("b.id NOT IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name LIKE ?)", ["%\(value)%"])
        case .startsWith:
            return ("b.id IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name LIKE ?)", ["\(value)%"])
        }
    }

    // MARK: - Custom column helpers

    private func wordCountSQL(sqlOp: String) -> String {
        let cfg = CustomColumnConfig.shared
        let label = cfg.wordCountLabel
            ?? customColumnTableName(label: "words").map { _ in "words" }
            ?? customColumnTableName(label: "word_count").map { _ in "word_count" }
            ?? customColumnTableName(label: "wordcount").map { _ in "wordcount" }
        if let tbl = label.flatMap({ customColumnTableName(label: $0) }) {
            return "b.id IN (SELECT book FROM \(tbl) WHERE value \(sqlOp) ?)"
        }
        return "0 = 1"
    }

    private func kudosSQL(sqlOp: String) -> String {
        let label = CustomColumnConfig.shared.kudosLabel ?? "kudos"
        if let tbl = customColumnTableName(label: label) {
            return "b.id IN (SELECT book FROM \(tbl) WHERE value \(sqlOp) ?)"
        }
        return "0 = 1"
    }

    internal func db_prepare(_ sql: String, _ args: [Binding?]) throws -> [[Binding?]] {
        return try db.prepare(sql, args).map { $0 }
    }
}
