import Foundation
import SwiftData
import SQLite

// MARK: - FilterResult

struct FilterResult {
    let calibreIDs: [Int]
    let totalCount: Int
}

extension FilterExpression {
    var hasSeriesOrMergedEqualsRule: Bool {
        groups.flatMap(\.rules).contains {
            $0.field == .collection &&
            $0.op == .equals &&
            $0.value == SystemCollectionID.seriesOrMergedName
        }
    }

    var referencesSeriesOrMergedCollection: Bool {
        groups.flatMap(\.rules).contains {
            $0.field == .collection &&
            $0.value == SystemCollectionID.seriesOrMergedName
        }
    }
}

// MARK: - FilterBuilder

struct FilterBuilder {

    let library: CalibreLibrary
    let ftsLibrary: CalibreFTSLibrary?

    init(library: CalibreLibrary, ftsLibrary: CalibreFTSLibrary? = nil) {
        self.library = library
        self.ftsLibrary = ftsLibrary
    }

    /// Evaluate a full FilterExpression (multiple groups joined by groupConjunction).
    ///
    /// - Parameter collectionMap: name → Set<calibreID> for all known Collections.
    ///   Populated from SwiftData by the caller since FilterBuilder has no ModelContext.
    func matchingIDs(expression: FilterExpression,
                     likedIDs: Set<Int>,
                     collectionMap: [String: Set<Int>] = [:],
                     statusMap: [AO3CompletionStatus: Set<Int>] = [:]) -> FilterResult {
        let completeGroups = expression.groups.filter(\.isComplete)
        guard !completeGroups.isEmpty else {
            return FilterResult(calibreIDs: [], totalCount: library.bookCount())
        }

        // Evaluate each group independently, then combine with groupConjunction
        let groupResults: [Set<Int>] = completeGroups.map { group in
            Set(matchingIDsForGroup(group, likedIDs: likedIDs, collectionMap: collectionMap, statusMap: statusMap))
        }

        let finalIDs: [Int]
        switch expression.groupConjunction {
        case .or:
            let union = groupResults.reduce(Set<Int>()) { $0.union($1) }
            finalIDs = Array(union).sorted()
        case .and:
            guard let first = groupResults.first else { finalIDs = []; break }
            let intersection = groupResults.dropFirst().reduce(first) { $0.intersection($1) }
            finalIDs = Array(intersection).sorted()
        }

        return FilterResult(calibreIDs: finalIDs, totalCount: finalIDs.count)
    }

    private func matchingIDsForGroup(_ group: FilterGroup,
                                     likedIDs: Set<Int>,
                                     collectionMap: [String: Set<Int>],
                                     statusMap: [AO3CompletionStatus: Set<Int>]) -> [Int] {
        let complete = group.completeRules
        guard !complete.isEmpty else { return library.allCalibreIDs() }

        // Partition: SQL-evaluated vs app-evaluated (isLiked, collection, AO3 status, fulltext)
        let sqlRules        = complete.filter { $0.field != .isLiked && $0.field != .collection && $0.field != .status && $0.field != .fulltext }
        let likedRules      = complete.filter { $0.field == .isLiked }
        let collectionRules = complete.filter { $0.field == .collection }
        let statusRules     = complete.filter { $0.field == .status }
        let fulltextRules   = complete.filter { $0.field == .fulltext }

        var ids: [Int]
        if sqlRules.isEmpty {
            ids = library.allCalibreIDs()
        } else {
            ids = library.calibreIDs(matchingRules: sqlRules, conjunction: group.conjunction)
        }

        // Apply isLiked in-memory
        if !likedRules.isEmpty {
            ids = ids.filter { likedIDs.contains($0) }
        }

        if !fulltextRules.isEmpty {
            var idSet = Set(ids)
            if group.conjunction == .and {
                for rule in fulltextRules {
                    let memberIDs = fulltextIDs(for: rule)
                    switch rule.op {
                    case .contains:    idSet = idSet.intersection(memberIDs)
                    case .notContains: idSet = idSet.subtracting(memberIDs)
                    default:           break
                    }
                }
            } else {
                var unionIDs = Set<Int>()
                for rule in fulltextRules {
                    let memberIDs = fulltextIDs(for: rule)
                    switch rule.op {
                    case .contains:    unionIDs.formUnion(idSet.intersection(memberIDs))
                    case .notContains: unionIDs.formUnion(idSet.subtracting(memberIDs))
                    default:           break
                    }
                }
                idSet = unionIDs
            }
            ids = Array(idSet).sorted()
        }

        // Apply collection rules in-memory
        // Each collection rule restricts (AND) or excludes (NOT) a set of IDs.
        // Multiple collection rules within a group follow the group's conjunction.
        if !collectionRules.isEmpty {
            var idSet = Set(ids)
            if group.conjunction == .and {
                for rule in collectionRules {
                    let memberIDs = collectionMap[rule.value] ?? []
                    switch rule.op {
                    case .equals:    idSet = idSet.intersection(memberIDs)
                    case .notEquals: idSet = idSet.subtracting(memberIDs)
                    default:         break   // only equals/notEquals are offered in the UI
                    }
                }
            } else {
                // OR: book passes if it satisfies ANY collection rule
                var unionIDs = Set<Int>()
                for rule in collectionRules {
                    let memberIDs = collectionMap[rule.value] ?? []
                    switch rule.op {
                    case .equals:    unionIDs.formUnion(idSet.intersection(memberIDs))
                    case .notEquals: unionIDs.formUnion(idSet.subtracting(memberIDs))
                    default:         break
                    }
                }
                idSet = unionIDs
            }
            ids = Array(idSet).sorted()
        }

        if !statusRules.isEmpty {
            var idSet = Set(ids)
            if group.conjunction == .and {
                for rule in statusRules {
                    guard let status = AO3CompletionStatus(userValue: rule.value) else { continue }
                    let memberIDs = statusMap[status] ?? []
                    switch rule.op {
                    case .equals:    idSet = idSet.intersection(memberIDs)
                    case .notEquals: idSet = idSet.subtracting(memberIDs)
                    default:         break
                    }
                }
            } else {
                var unionIDs = Set<Int>()
                for rule in statusRules {
                    guard let status = AO3CompletionStatus(userValue: rule.value) else { continue }
                    let memberIDs = statusMap[status] ?? []
                    switch rule.op {
                    case .equals:    unionIDs.formUnion(idSet.intersection(memberIDs))
                    case .notEquals: unionIDs.formUnion(idSet.subtracting(memberIDs))
                    default:         break
                    }
                }
                idSet = unionIDs
            }
            ids = Array(idSet).sorted()
        }

        return ids
    }

    private func fulltextIDs(for rule: FilterRule) -> Set<Int> {
        let phrase = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, let ftsLibrary else { return [] }
        return Set(ftsLibrary.search(query: phrase, limit: Int.max) ?? [])
    }

    // Legacy single-group entry point — used by quick tag/author taps
    func matchingIDs(rules: [FilterRule], conjunction: FilterConjunction,
                     likedIDs: Set<Int>,
                     collectionMap: [String: Set<Int>] = [:],
                     statusMap: [AO3CompletionStatus: Set<Int>] = [:]) -> FilterResult {
        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: rules, conjunction: conjunction)]
        return matchingIDs(expression: expr, likedIDs: likedIDs, collectionMap: collectionMap, statusMap: statusMap)
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
            return expandedTagFragment(op: rule.op, value: v)
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

        case .collection, .status, .fulltext:
            // Collection membership is evaluated in-memory against SwiftData.
            // SQL layer never sees this field.
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
        case .ratingAtMost, .ratingAtLeast:
            // These operators only make sense for the .rating field (routed via ao3TagFragment).
            // If reached here, fall back to exact match.
            return ("\(column) = ?", [value])
        }
    }

    private func expandedTagFragment(op: FilterOperator, value: String) -> (String, [Binding?])? {
        let terms = expandedAO3TagTerms(for: value)
        let matcher: String
        let args: [Binding?]

        switch op {
        case .contains:
            matcher = terms.map { _ in "t2.name LIKE ?" }.joined(separator: " OR ")
            args = terms.map { "%\($0)%" as Binding? }
            return tagMembershipFragment(matcher: matcher, args: args, negated: false)
        case .notContains:
            matcher = terms.map { _ in "t2.name LIKE ?" }.joined(separator: " OR ")
            args = terms.map { "%\($0)%" as Binding? }
            return tagMembershipFragment(matcher: matcher, args: args, negated: true)
        case .equals, .ratingAtMost, .ratingAtLeast:
            matcher = terms.map { _ in "t2.name = ?" }.joined(separator: " OR ")
            args = terms.map { $0 as Binding? }
            return tagMembershipFragment(matcher: matcher, args: args, negated: false)
        case .notEquals:
            matcher = terms.map { _ in "t2.name = ?" }.joined(separator: " OR ")
            args = terms.map { $0 as Binding? }
            return tagMembershipFragment(matcher: matcher, args: args, negated: true)
        case .startsWith:
            matcher = terms.map { _ in "t2.name LIKE ?" }.joined(separator: " OR ")
            args = terms.map { "\($0)%" as Binding? }
            return tagMembershipFragment(matcher: matcher, args: args, negated: false)
        }
    }

    private func tagMembershipFragment(matcher: String,
                                       args: [Binding?],
                                       negated: Bool) -> (String, [Binding?])? {
        guard !matcher.isEmpty else { return nil }
        let operatorText = negated ? "NOT IN" : "IN"
        return (
            "b.id \(operatorText) (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE \(matcher))",
            args
        )
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

        case .ratingAtMost:
            // "Show me books rated AT MOST X."
            //
            // A book passes iff it has NO tag with a rating level HIGHER than X.
            // This correctly handles:
            //   - books with a single rating tag at or below X → ✓
            //   - books with multiple rating tags where one is above X → ✗
            //   - books tagged only "Not Rated" → ✓ (no higher tag exists)
            //   - books with no rating tag at all → ✓
            guard let rating = AO3Rating(rawValue: value) else {
                return ao3TagFragment(op: .equals, value: value)
            }
            let higher = rating.higherRatings
            if higher.isEmpty {
                // Explicit is the maximum — ratingAtMost Explicit matches everything
                return ("1 = 1", [])
            }
            // Build: NOT IN (books that have any higher-rated tag)
            let placeholders = higher.map { _ in "?" }.joined(separator: ", ")
            let args: [Binding?] = higher.map { $0.rawValue as Binding? }
            return (
                "b.id NOT IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name IN (\(placeholders)))",
                args
            )

        case .ratingAtLeast:
            // "Show me books rated AT LEAST X."
            //
            // A book passes iff it has AT LEAST ONE tag with a rating level >= X.
            // Books tagged only "Not Rated" do NOT pass (level is nil).
            guard let rating = AO3Rating(rawValue: value) else {
                return ao3TagFragment(op: .equals, value: value)
            }
            guard let myLevel = rating.level else {
                // "Not Rated" as a floor is undefined; fall back to exact match
                return ao3TagFragment(op: .equals, value: value)
            }
            // Collect all ratings at or above this level
            let qualified = AO3Rating.allCases.filter { ($0.level ?? 0) >= myLevel }
            if qualified.isEmpty { return ("0 = 1", []) }
            let placeholders = qualified.map { _ in "?" }.joined(separator: ", ")
            let args: [Binding?] = qualified.map { $0.rawValue as Binding? }
            return (
                "b.id IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE t2.name IN (\(placeholders)))",
                args
            )
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
