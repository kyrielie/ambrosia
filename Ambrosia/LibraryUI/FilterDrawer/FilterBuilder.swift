import Foundation
import SwiftData
import SQLite

// MARK: - Library filter debug logging

enum LibraryFilterDebug {
    static func now() -> CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }

    static func log(_ event: String, _ fields: @autoclosure () -> [String: CustomStringConvertible?] = [:]) {
        #if DEBUG
        let detail = fields()
            .compactMap { key, value -> String? in
                guard let value else { return nil }
                return "\(key)=\(value)"
            }
            .joined(separator: " ")
        if detail.isEmpty {
            print("[LibraryFilter] \(event)")
        } else {
            print("[LibraryFilter] \(event) \(detail)")
        }
        #endif
    }

    static func elapsedMS(since start: CFAbsoluteTime) -> String {
        String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    static func summary(expression: FilterExpression) -> String {
        expression.groups
            .flatMap(\.completeRules)
            .map { "\($0.field.rawValue).\($0.op.rawValue)=\($0.value)" }
            .joined(separator: ",")
    }

    static func summary(query: SearchQuery) -> String {
        [
            query.tagTerms.isEmpty ? nil : "tag:\(query.tagTerms.joined(separator: "|"))",
            query.authorTerms.isEmpty ? nil : "author:\(query.authorTerms.joined(separator: "|"))",
            query.titleTerms.isEmpty ? nil : "title:\(query.titleTerms.joined(separator: "|"))",
            query.seriesTerms.isEmpty ? nil : "series:\(query.seriesTerms.joined(separator: "|"))",
            query.plainTerms.isEmpty ? nil : "plain:\(query.plainTerms.joined(separator: "|"))",
            query.fulltextPhrase.map { "fulltext:\($0)" },
            query.ftsMatchedIDs.map { "ftsIDs:\($0.count)" }
        ]
        .compactMap { $0 }
        .joined(separator: ",")
    }
}

// MARK: - Human-readable filter summary
//
// Used for user-facing labels (feed titles, published-search display) where
// LibraryFilterDebug.summary's "field.op=value" dump reads as raw internal
// state, not something a feed reader's title bar should show.
enum FilterSummary {
    /// Feed titles shouldn't run unbounded with many rules -- clip and mark truncated.
    private static let maxLength = 80

    static func humanReadable(expression: FilterExpression) -> String {
        let groupSummaries = expression.groups.compactMap { group -> String? in
            let ruleSummaries = group.completeRules.map { rule -> String in
                if rule.op.label.contains("rating") {
                    // "min rating Explicit" reads better than "Rating min rating Explicit".
                    return "\(rule.op.label) \(rule.value)"
                }
                return "\(rule.field.label) \(rule.op.label) \(rule.value)"
            }
            guard !ruleSummaries.isEmpty else { return nil }
            let joiner = group.conjunction == .and ? " and " : " or "
            return ruleSummaries.joined(separator: joiner)
        }
        guard !groupSummaries.isEmpty else { return "All books" }
        let joiner = expression.groupConjunction == .and ? " and " : " or "
        let full = groupSummaries.joined(separator: joiner)
        guard full.count > maxLength else { return full }
        let clipped = full.prefix(maxLength).trimmingCharacters(in: .whitespaces)
        return "\(clipped)…"
    }
}

// MARK: - FilterResult

struct FilterResult {
    let calibreIDs: [Int]
    let totalCount: Int?
    let isSQLBacked: Bool

    init(calibreIDs: [Int], totalCount: Int? = nil, isSQLBacked: Bool = false) {
        self.calibreIDs = calibreIDs
        self.totalCount = totalCount
        self.isSQLBacked = isSQLBacked
    }

    var reloadToken: String {
        "\(isSQLBacked)-\(calibreIDs)"
    }
}

struct PendingFullTextSearch: Equatable {
    enum Source: Equatable {
        case searchText
        case filterExpression
    }

    let token: UUID
    let phrase: String
    let source: Source
}

extension FilterExpression {
    var isSQLPageable: Bool {
        let completeRules = groups.flatMap(\.completeRules)
        guard !completeRules.isEmpty else { return false }
        return completeRules.allSatisfy { rule in
            switch rule.field {
            case .collection, .isLiked, .status, .fulltext, .crossover:
                return false
            default:
                return true
            }
        }
    }

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

    /// Pre-resolved synonym expansions for tag rule values, keyed by raw value.
    /// Populated async by the call site via `AmbrosiaMetaDB.expandedTerms(for:)`
    /// before the `Task.detached` is launched (Invariant 10).
    let tagExpansions: [String: [String]]

    init(library: CalibreLibrary, ftsLibrary: CalibreFTSLibrary? = nil,
         tagExpansions: [String: [String]] = [:]) {
        self.library = library
        self.ftsLibrary = ftsLibrary
        self.tagExpansions = tagExpansions
    }

    /// Actor isolation on `CalibreLibrary`/`CalibreFTSLibrary` provides serialization
    /// (and off-main execution, since neither is `@MainActor`-isolated) for every
    /// query this makes — no manual `Task.detached` dispatch needed anymore.
    func matchingIDs(
        expression: FilterExpression,
        likedIDs: Set<Int>,
        collectionMap: [String: Set<Int>] = [:],
        statusMap: [AO3CompletionStatus: Set<Int>] = [:],
        fulltextMap: [String: Set<Int>] = [:],
        crossoverMap: Set<Int> = [],
        wordCountFallbackMap: [Int: Int]? = nil
    ) async -> FilterResult {
        await matchingIDsSync(
            expression:           expression,
            likedIDs:             likedIDs,
            collectionMap:        collectionMap,
            statusMap:            statusMap,
            fulltextMap:          fulltextMap,
            crossoverMap:         crossoverMap,
            wordCountFallbackMap: wordCountFallbackMap
        )
    }

    /// Evaluate a full FilterExpression (multiple groups joined by groupConjunction).
    private func matchingIDsSync(expression: FilterExpression,
                     likedIDs: Set<Int>,
                     collectionMap: [String: Set<Int>] = [:],
                     statusMap: [AO3CompletionStatus: Set<Int>] = [:],
                     fulltextMap: [String: Set<Int>] = [:],
                     crossoverMap: Set<Int> = [],
                     wordCountFallbackMap: [Int: Int]? = nil) async -> FilterResult {
        let start = LibraryFilterDebug.now()
        LibraryFilterDebug.log("matchingIDs.start", [
            "mode": "explicitIDs",
            "rules": LibraryFilterDebug.summary(expression: expression)
        ])
        let completeGroups = expression.groups.filter(\.isComplete)
        guard !completeGroups.isEmpty else {
            let result = FilterResult(calibreIDs: [], totalCount: await library.bookCount())
            LibraryFilterDebug.log("matchingIDs.end", [
                "mode": "explicitIDs",
                "ids": result.calibreIDs.count,
                "count": result.totalCount,
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: start)
            ])
            return result
        }

        let fulltextGroups: [(rules: [FilterRule], conjunction: FilterConjunction)] = completeGroups.compactMap { group in
            let rules = group.completeRules.filter { $0.field == .fulltext }
            guard !rules.isEmpty else { return nil }
            return (rules, group.conjunction)
        }
        let nonFulltextGroups = completeGroups.compactMap { group -> FilterGroup? in
            let rules = group.completeRules.filter { $0.field != .fulltext }
            guard !rules.isEmpty else { return nil }
            return FilterGroup(rules: rules, conjunction: group.conjunction)
        }

        var groupResults: [Set<Int>] = []
        for group in nonFulltextGroups {
            let ids = await matchingIDsForGroup(group,
                                    likedIDs: likedIDs,
                                    collectionMap: collectionMap,
                                    statusMap: statusMap,
                                    crossoverMap: crossoverMap,
                                    wordCountFallbackMap: wordCountFallbackMap)
            groupResults.append(Set(ids))
        }

        var finalIDSet: Set<Int>
        if groupResults.isEmpty {
            finalIDSet = Set(await library.allCalibreIDs())
        } else {
            switch expression.groupConjunction {
            case .or:
                finalIDSet = groupResults.reduce(Set<Int>()) { $0.union($1) }
            case .and:
                guard let first = groupResults.first else { finalIDSet = []; break }
                finalIDSet = groupResults.dropFirst().reduce(first) { $0.intersection($1) }
            }
        }

        if !fulltextGroups.isEmpty {
            finalIDSet = await applyFulltextGroupsAsGlobalRefinement(
                fulltextGroups,
                groupConjunction: expression.groupConjunction,
                to: finalIDSet,
                fulltextMap: fulltextMap
            )
        }

        let finalIDs = Array(finalIDSet).sorted()
        let result = FilterResult(calibreIDs: finalIDs, totalCount: finalIDs.count)
        LibraryFilterDebug.log("matchingIDs.end", [
            "mode": "explicitIDs",
            "ids": finalIDs.count,
            "count": result.totalCount,
            "elapsedMS": LibraryFilterDebug.elapsedMS(since: start)
        ])
        return result
    }

    private func matchingIDsForGroup(_ group: FilterGroup,
                                     likedIDs: Set<Int>,
                                     collectionMap: [String: Set<Int>],
                                     statusMap: [AO3CompletionStatus: Set<Int>],
                                     crossoverMap: Set<Int> = [],
                                     wordCountFallbackMap: [Int: Int]? = nil) async -> [Int] {
        let complete = group.completeRules
        guard !complete.isEmpty else { return await library.allCalibreIDs() }

        // Partition into SQL-evaluated vs in-memory-evaluated rules.
        // §6: .crossover is in-memory (backed by ao3_metadata fandoms).
        // §2a: .wordCountGT/.wordCountLT are SQL when custom column configured,
        //      in-memory via wordCountFallbackMap when not.
        let sqlRules        = complete.filter {
            $0.field != .isLiked && $0.field != .collection &&
            $0.field != .status && $0.field != .fulltext && $0.field != .crossover
        }
        let likedRules      = complete.filter { $0.field == .isLiked }
        let collectionRules = complete.filter { $0.field == .collection }
        let statusRules     = complete.filter { $0.field == .status }
        let crossoverRules  = complete.filter { $0.field == .crossover }  // §6

        // SQL rules: pass word-count rules through SQL if custom column is available;
        // signal nil back (by returning nil from sqlFragment) when not — handle below.
        var ids: [Int]
        if sqlRules.isEmpty {
            ids = await library.allCalibreIDs()
        } else {
            ids = await library.calibreIDs(matchingRules: sqlRules,
                                     conjunction: group.conjunction,
                                     wordCountFallbackMap: wordCountFallbackMap,
                                     tagExpansions: tagExpansions)
        }

        // Apply isLiked in-memory
        if !likedRules.isEmpty {
            ids = ids.filter { likedIDs.contains($0) }
        }

        // Apply collection rules in-memory
        if !collectionRules.isEmpty {
            var idSet = Set(ids)
            if group.conjunction == .and {
                for rule in collectionRules {
                    let memberIDs = collectionMap[rule.value] ?? []
                    switch rule.op {
                    case .equals:    idSet = idSet.intersection(memberIDs)
                    case .notEquals: idSet = idSet.subtracting(memberIDs)
                    default:         break
                    }
                }
            } else {
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

        // Apply status rules in-memory (§5: uses renamed AO3CompletionStatus cases)
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

        // §6: Apply crossover rules in-memory (crossoverMap = Set<Int> of IDs with fandoms.count > 1)
        if !crossoverRules.isEmpty {
            var idSet = Set(ids)
            for rule in crossoverRules {
                let wantsCrossover = rule.value == "true"
                idSet = wantsCrossover ? idSet.intersection(crossoverMap)
                                       : idSet.subtracting(crossoverMap)
            }
            ids = Array(idSet).sorted()
        }

        return ids
    }

    private func applyFulltextGroupsAsGlobalRefinement(
        _ groups: [(rules: [FilterRule], conjunction: FilterConjunction)],
        groupConjunction: FilterConjunction,
        to candidateIDs: Set<Int>,
        fulltextMap: [String: Set<Int>]
    ) async -> Set<Int> {
        var fulltextCache: [String: Set<Int>] = [:]

        func cachedFulltextIDs(for rule: FilterRule) async -> Set<Int> {
            let phrase = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if let cached = fulltextCache[key] { return cached }
            let result: Set<Int>
            if let mapped = fulltextMap[key] {
                result = mapped
            } else {
                result = await fulltextIDs(for: rule)
            }
            fulltextCache[key] = result
            return result
        }

        func apply(_ rule: FilterRule, to ids: Set<Int>) async -> Set<Int> {
            let memberIDs = await cachedFulltextIDs(for: rule)
            let before = ids.count
            let result: Set<Int>
            switch rule.op {
            case .contains:    result = ids.intersection(memberIDs)
            case .notContains: result = ids.subtracting(memberIDs)
            default:           result = ids
            }
            LibraryFilterDebug.log("fulltext.globalRefinement.rule", [
                "op": rule.op.rawValue,
                "value": rule.value,
                "before": before,
                "fulltextIDs": memberIDs.count,
                "after": result.count
            ])
            return result
        }

        func evaluateGroup(_ group: (rules: [FilterRule], conjunction: FilterConjunction)) async -> Set<Int> {
            switch group.conjunction {
            case .and:
                var acc = candidateIDs
                for rule in group.rules {
                    acc = await apply(rule, to: acc)
                }
                return acc
            case .or:
                var union = Set<Int>()
                for rule in group.rules {
                    union.formUnion(await apply(rule, to: candidateIDs))
                }
                return union
            }
        }

        LibraryFilterDebug.log("fulltext.globalRefinement.start", [
            "candidateIDs": candidateIDs.count,
            "rules": groups.flatMap(\.rules).map { "\($0.op.rawValue)=\($0.value)" }.joined(separator: ",")
        ])

        var groupResults: [Set<Int>] = []
        for group in groups {
            groupResults.append(await evaluateGroup(group))
        }

        switch groupConjunction {
        case .or:
            return groupResults.reduce(Set<Int>()) { $0.union($1) }
        case .and:
            guard let first = groupResults.first else { return candidateIDs }
            return groupResults.dropFirst().reduce(first) { $0.intersection($1) }
        }
    }

    private func fulltextIDs(for rule: FilterRule) async -> Set<Int> {
        let phrase = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, let ftsLibrary else { return [] }
        let limit = max(await library.bookCount(), 1)
        return Set(await ftsLibrary.search(query: phrase, limit: limit) ?? [])
    }

    // Legacy single-group entry point — used by quick tag/author taps
    func matchingIDs(rules: [FilterRule], conjunction: FilterConjunction,
                     likedIDs: Set<Int>,
                     collectionMap: [String: Set<Int>] = [:],
                     statusMap: [AO3CompletionStatus: Set<Int>] = [:]) async -> FilterResult {
        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: rules, conjunction: conjunction)]
        return await matchingIDs(expression: expr, likedIDs: likedIDs, collectionMap: collectionMap, statusMap: statusMap)
    }
}

// MARK: - CalibreLibrary SQL filter extension

extension CalibreLibrary {

    func allCalibreIDs() -> [Int] {
        let sql = "SELECT id FROM books ORDER BY id"
        guard let rows = try? db_prepare(sql, []) else { return [] }
        return rows.compactMap { row in (row[0] as? Int64).map(Int.init) }
    }

    // bulkCustomColumnInts moved to CalibreLibrary.swift — this is CalibreLibrary's
    // data, not a filter concern. See "Custom column discovery" section there.

    func calibreIDs(matchingRules rules: [FilterRule], conjunction: FilterConjunction,
                    wordCountFallbackMap: [Int: Int]? = nil,
                    tagExpansions: [String: [String]] = [:]) -> [Int] {
        guard !rules.isEmpty else { return allCalibreIDs() }

        // §2a: Separate out word-count rules that need in-memory fallback.
        // sqlFragment(for:) returns nil for wordCountGT/LT when no custom column is
        // configured — those rules are handled below against wordCountFallbackMap.
        var clauses: [String] = []
        var args: [Binding?]  = []
        var wordCountFallbackRules: [FilterRule] = []

        for rule in rules {
            if rule.field == .wordCountGT || rule.field == .wordCountLT {
                if let (clause, ruleArgs) = sqlFragment(for: rule, tagExpansions: tagExpansions) {
                    clauses.append(clause)
                    args.append(contentsOf: ruleArgs)
                } else {
                    // No custom column — collect for in-memory fallback
                    wordCountFallbackRules.append(rule)
                }
            } else if let (clause, ruleArgs) = sqlFragment(for: rule, tagExpansions: tagExpansions) {
                clauses.append(clause)
                args.append(contentsOf: ruleArgs)
            }
        }

        let needsTagJoin     = rules.contains { [.tag, .rating, .warning, .category].contains($0.field) }
        let needsCommentJoin = rules.contains { $0.field == .comment }

        var joins: [String] = []
        if needsTagJoin {
            joins.append("LEFT JOIN books_tags_link btl ON btl.book = b.id")
            joins.append("LEFT JOIN tags t ON t.id = btl.tag")
        }
        if needsCommentJoin {
            joins.append("LEFT JOIN comments c ON c.book = b.id")
        }

        var ids: [Int]
        if clauses.isEmpty {
            ids = allCalibreIDs()
        } else {
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
            ids = rows.compactMap { row in (row[0] as? Int64).map(Int.init) }
        }

        // §2a: Apply word-count fallback in-memory when no custom column is configured.
        if !wordCountFallbackRules.isEmpty, let fallbackMap = wordCountFallbackMap {
            var idSet = Set(ids)
            for rule in wordCountFallbackRules {
                guard let threshold = rule.numericValue else { continue }
                switch rule.field {
                case .wordCountGT:
                    idSet = idSet.filter { id in (fallbackMap[id] ?? 0) > threshold }
                case .wordCountLT:
                    idSet = idSet.filter { id in
                        guard let wc = fallbackMap[id] else { return false }
                        return wc < threshold
                    }
                default: break
                }
            }
            ids = Array(idSet).sorted()
        }

        return ids
    }

    func sqlFilterClause(for expression: FilterExpression,
                         tagExpansions: [String: [String]] = [:]) -> (String, [Binding?])? {
        guard expression.isSQLPageable else { return nil }
        let completeGroups = expression.groups.filter(\.isComplete)
        var groupClauses: [String] = []
        var args: [Binding?] = []

        for group in completeGroups {
            var clauses: [String] = []
            for rule in group.completeRules {
                guard let (clause, ruleArgs) = sqlFragment(for: rule, tagExpansions: tagExpansions) else { continue }
                clauses.append(clause)
                args.append(contentsOf: ruleArgs)
            }
            if !clauses.isEmpty {
                let op = group.conjunction == .and ? " AND " : " OR "
                groupClauses.append("(\(clauses.joined(separator: op)))")
            }
        }

        guard !groupClauses.isEmpty else { return nil }
        let op = expression.groupConjunction == .and ? " AND " : " OR "
        return (groupClauses.joined(separator: op), args)
    }

    func bookCount(query: SearchQuery, filter: FilterExpression?,
                   filterTagExpansions: [String: [String]] = [:]) -> Int {
        // §Phase3: this count is SQL-level only (query + filter), not
        // visibility-filtered — it never took a visibility parameter before
        // this cache existed, so visibilityVersion is fixed at 0 here rather
        // than threaded in from callers, matching its actual semantics
        // instead of over-invalidating on every like/skip toggle.
        let cacheKey = CountCacheKey(
            querySignature: LibraryFilterDebug.summary(query: query),
            filterSignature: filter.map { LibraryFilterDebug.summary(expression: $0) } ?? "",
            tagExpansionsDigest: tagExpansionsDigest(filterTagExpansions),
            visibilityVersion: 0
        )
        if let cached = countCache[cacheKey] { return cached }
        let start = LibraryFilterDebug.now()
        LibraryFilterDebug.log("count.start", [
            "mode": "sqlPagedDeferredCount",
            "query": LibraryFilterDebug.summary(query: query),
            "filter": filter.map { LibraryFilterDebug.summary(expression: $0) }
        ])
        do {
            let count = try _bookCount(query: query, filter: filter, filterTagExpansions: filterTagExpansions)
            LibraryFilterDebug.log("count.end", [
                "mode": "sqlPagedDeferredCount",
                "count": count,
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: start)
            ])
            clearSearchError()
            countCache.set(count, for: cacheKey)
            return count
        } catch {
            let message = "bookCount(query:filter:) error: \(error)"
            #if DEBUG
            print("[CalibreLibrary] \(message)")
            #endif
            recordSearchError(message)
            return 0
        }
    }

    private func _bookCount(query: SearchQuery, filter: FilterExpression?,
                            filterTagExpansions: [String: [String]] = [:]) throws -> Int {
        var conditions: [String] = []
        var args: [Binding?] = []

        let (qClause, qArgs) = whereClause(for: query)
        if !qClause.isEmpty {
            conditions.append(qClause)
            args.append(contentsOf: qArgs)
        }
        if let filter, let (fClause, fArgs) = sqlFilterClause(for: filter, tagExpansions: filterTagExpansions) {
            conditions.append(fClause)
            args.append(contentsOf: fArgs)
        }

        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        // §perf: Only join `comments` when the filter references it.
        let needsCommentJoin = filter?.groups.flatMap(\.completeRules)
            .contains { $0.field == .comment } == true
        let commentJoin = needsCommentJoin ? "LEFT JOIN comments c ON c.book = b.id" : ""
        let sql = """
            SELECT COUNT(DISTINCT b.id)
            FROM books b
            \(commentJoin)
            \(where_)
            """
        let rows = try db.prepare(sql, args).map { $0 }
        return (rows.first?.first as? Int64).map(Int.init) ?? 0
    }

    // MARK: - SQL fragment builder

    // swiftlint:disable cyclomatic_complexity
    private func sqlFragment(for rule: FilterRule,
                             tagExpansions: [String: [String]] = [:]) -> (String, [Binding?])? {
        let v = rule.value.trimmingCharacters(in: .whitespaces)

        switch rule.field {

        case .title:
            return textFragment(column: "b.title", op: rule.op, value: v)

        case .series:
            return seriesFragment(op: rule.op, value: v)

        case .comment:
            return textFragment(column: "c.text", op: rule.op, value: v,
                                nullClause: "c.text IS NULL")

        case .authorName:
            return authorFragment(op: rule.op, value: v)

        case .tag:
            return expandedTagFragment(op: rule.op, value: v, tagExpansions: tagExpansions)
        case .rating:
            return ao3TagFragment(op: rule.op, value: v)
        case .warning:
            return ao3TagFragment(op: rule.op, value: v)
        case .category:
            return ao3TagFragment(op: rule.op, value: v)

        case .wordCountGT:
            guard let n = rule.numericValue else { return nil }
            // §2a: Returns nil when no custom column is configured — caller handles fallback.
            guard let sql = wordCountSQL(sqlOp: ">") else { return nil }
            return (sql, [n as Binding?])

        case .wordCountLT:
            guard let n = rule.numericValue else { return nil }
            guard let sql = wordCountSQL(sqlOp: "<") else { return nil }
            return (sql, [n as Binding?])

        case .kudosGT:
            guard let n = rule.numericValue else { return nil }
            return (kudosSQL(sqlOp: ">"), [n as Binding?])

        case .kudosLT:
            guard let n = rule.numericValue else { return nil }
            return (kudosSQL(sqlOp: "<"), [n as Binding?])

        case .isLiked, .crossover:
            // Evaluated in-memory; never produce a SQL fragment.
            return nil

        case .collection, .status, .fulltext:
            return nil
        }
    }

    // MARK: - Fragment helpers

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
            return ("\(column) = ?", [value])
        }
    }

    private func expandedTagFragment(op: FilterOperator, value: String,
                                     tagExpansions: [String: [String]]) -> (String, [Binding?])? {
        let terms = tagExpansions[value] ?? [value]
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

    /// §8: Rewritten from NOT IN subquery to correlated NOT EXISTS.
    ///
    /// The old shape:
    ///   b.id NOT IN (SELECT book FROM books_tags_link btl2 JOIN tags t2 ... WHERE ...)
    /// Forces SQLite to materialise the entire matching-book set and anti-join against
    /// all of `books`. Leading-wildcard LIKE cannot use any index, so this is a full
    /// scan of `tags` per evaluation — doubly expensive for synonyms.
    ///
    /// The new shape:
    ///   NOT EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ... WHERE btl2.book = b.id AND ...)
    /// Correlates on `btl2.book = b.id` so SQLite can use the index on
    /// `books_tags_link(book)` to seek directly to each book's tag rows. This mirrors
    /// the EXISTS shape already used for positive tag matching in CalibreLibrarySearch.swift.
    private func tagMembershipFragment(matcher: String,
                                       args: [Binding?],
                                       negated: Bool) -> (String, [Binding?])? {
        guard !matcher.isEmpty else { return nil }
        if negated {
            return (
                "NOT EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND (\(matcher)))",
                args
            )
        }
        return (
            "EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND (\(matcher)))",
            args
        )
    }

    /// §8: All negative ao3TagFragment branches use correlated NOT EXISTS, matching
    /// the pattern established for general tags in tagMembershipFragment. This avoids
    /// materialising the full matching-book set for the anti-join.
    private func ao3TagFragment(op: FilterOperator, value: String) -> (String, [Binding?])? {
        switch op {
        case .equals:
            return (
                "EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND t2.name = ?)",
                [value]
            )
        case .notEquals:
            return (
                "NOT EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND t2.name = ?)",
                [value]
            )
        case .contains:
            return (
                "EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND t2.name LIKE ?)",
                ["%\(value)%"]
            )
        case .notContains:
            return (
                "NOT EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND t2.name LIKE ?)",
                ["%\(value)%"]
            )
        case .startsWith:
            return (
                "EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND t2.name LIKE ?)",
                ["\(value)%"]
            )

        case .ratingAtMost:
            guard let rating = AO3Rating(rawValue: value) else {
                return ao3TagFragment(op: .equals, value: value)
            }
            let higher = rating.higherRatings
            if higher.isEmpty {
                return ("1 = 1", [])
            }
            let placeholders = higher.map { _ in "?" }.joined(separator: ", ")
            let args: [Binding?] = higher.map { $0.rawValue as Binding? }
            return (
                "NOT EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND t2.name IN (\(placeholders)))",
                args
            )

        case .ratingAtLeast:
            guard let rating = AO3Rating(rawValue: value) else {
                return ao3TagFragment(op: .equals, value: value)
            }
            guard let myLevel = rating.level else {
                return ao3TagFragment(op: .equals, value: value)
            }
            let qualified = AO3Rating.allCases.filter { ($0.level ?? 0) >= myLevel }
            if qualified.isEmpty { return ("0 = 1", []) }
            let placeholders = qualified.map { _ in "?" }.joined(separator: ", ")
            let args: [Binding?] = qualified.map { $0.rawValue as Binding? }
            return (
                "EXISTS (SELECT 1 FROM books_tags_link btl2 JOIN tags t2 ON t2.id = btl2.tag WHERE btl2.book = b.id AND t2.name IN (\(placeholders)))",
                args
            )
        }
    }

    /// §Phase2: authorName is multi-valued per book (books_authors_link is a
    /// many-to-many join). A correlated EXISTS/NOT EXISTS subquery, evaluated
    /// independently per rule, is required so that two ANDed authorName rules
    /// (e.g. "contains Smith" AND "contains Jones") can each match a different
    /// author row on the same book. A single outer LEFT JOIN alias cannot do
    /// this — every rule would be forced to test the exact same joined row.
    private func authorFragment(op: FilterOperator, value: String) -> (String, [Binding?])? {
        let matcher: String
        let args: [Binding?]
        let negated: Bool
        switch op {
        case .contains:
            matcher = "LOWER(a2.name) LIKE ?"; args = ["%\(value.lowercased())%"]; negated = false
        case .notContains:
            matcher = "LOWER(a2.name) LIKE ?"; args = ["%\(value.lowercased())%"]; negated = true
        case .equals:
            matcher = "LOWER(a2.name) = ?"; args = [value.lowercased()]; negated = false
        case .notEquals:
            matcher = "LOWER(a2.name) = ?"; args = [value.lowercased()]; negated = true
        case .startsWith:
            matcher = "LOWER(a2.name) LIKE ?"; args = ["\(value.lowercased())%"]; negated = false
        case .ratingAtMost, .ratingAtLeast:
            // Not offered for authorName (see FilterRule.availableOperators); no valid SQL shape.
            return nil
        }
        let sub = """
            SELECT 1 FROM books_authors_link bal2
            JOIN authors a2 ON a2.id = bal2.author
            WHERE bal2.book = b.id AND \(matcher)
            """
        return (negated ? "NOT EXISTS (\(sub))" : "EXISTS (\(sub))", args)
    }

    /// §Phase2: same shape as authorFragment — series is also many-to-many via
    /// books_series_link, so it needs the same correlated-subquery fix. Calibre
    /// books are usually single-series in practice, but the schema (and the old
    /// textFragment(column: "s.name", ...) call this replaces) treats it as
    /// multi-valued, so this stays consistent with that.
    private func seriesFragment(op: FilterOperator, value: String) -> (String, [Binding?])? {
        let matcher: String
        let args: [Binding?]
        let negated: Bool
        switch op {
        case .contains:
            matcher = "LOWER(s2.name) LIKE ?"; args = ["%\(value.lowercased())%"]; negated = false
        case .notContains:
            matcher = "LOWER(s2.name) LIKE ?"; args = ["%\(value.lowercased())%"]; negated = true
        case .equals:
            matcher = "LOWER(s2.name) = ?"; args = [value.lowercased()]; negated = false
        case .notEquals:
            matcher = "LOWER(s2.name) = ?"; args = [value.lowercased()]; negated = true
        case .startsWith:
            matcher = "LOWER(s2.name) LIKE ?"; args = ["\(value.lowercased())%"]; negated = false
        case .ratingAtMost, .ratingAtLeast:
            // Not offered for series (see FilterRule.availableOperators); no valid SQL shape.
            return nil
        }
        let sub = """
            SELECT 1 FROM books_series_link bsl2
            JOIN series s2 ON s2.id = bsl2.series
            WHERE bsl2.book = b.id AND \(matcher)
            """
        return (negated ? "NOT EXISTS (\(sub))" : "EXISTS (\(sub))", args)
    }

    // MARK: - Custom column helpers

    /// §2a: Returns nil when no custom column is configured (caller applies ao3_metadata fallback).
    /// Previously returned "0 = 1" — that silently matched nothing. Now signals the caller
    /// to apply wordCountFallbackMap in-memory instead.
    private func wordCountSQL(sqlOp: String) -> String? {
        let cfg = CustomColumnConfig.shared
        let label = cfg.wordCountLabel
            ?? customColumnTableName(label: "words").map { _ in "words" }
            ?? customColumnTableName(label: "word_count").map { _ in "word_count" }
            ?? customColumnTableName(label: "wordcount").map { _ in "wordcount" }
        guard let tbl = label.flatMap({ customColumnTableName(label: $0) }) else {
            return nil  // signal: no SQL available — caller handles fallback
        }
        return "b.id IN (SELECT book FROM \(tbl) WHERE value \(sqlOp) ?)"
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
