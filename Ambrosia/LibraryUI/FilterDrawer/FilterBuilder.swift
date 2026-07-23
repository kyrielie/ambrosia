import Foundation
import SwiftData
import SQLite

// MARK: - Shared tag/author/series EXISTS-subquery builders (§3, Phase 2)

/// Free, non-actor-isolated helper shared by `FilterBuilder` (drawer/popup path)
/// and `CalibreLibrarySearch` (search-bar path, an extension on the `CalibreLibrary`
/// actor). Both surfaces need the identical correlated EXISTS/NOT EXISTS subquery
/// shape for tag/author/series matching; living here as static functions on a
/// value-less enum means neither call site pays for or requires actor isolation,
/// and there is exactly one function body instead of one copy-pasted into two files.
/// See Invariant 24 in ambrosia_architecture.md for why the subquery shape itself
/// (correlated on `book = b.id`, no outer join) matters.
enum MatchingSubqueryBuilder {

    /// authorName is multi-valued per book (books_authors_link is a many-to-many
    /// join). A correlated EXISTS/NOT EXISTS subquery, evaluated independently per
    /// rule, is required so that two ANDed authorName rules (e.g. "contains Smith"
    /// AND "contains Jones") can each match a different author row on the same
    /// book. A single outer LEFT JOIN alias cannot do this — every rule would be
    /// forced to test the exact same joined row.
    static func authorFragment(op: FilterOperator, value: String) -> (String, [Binding?])? {
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

    /// Same shape as authorFragment — series is also many-to-many via
    /// books_series_link, so it needs the same correlated-subquery fix. Calibre
    /// books are usually single-series in practice, but the schema treats it as
    /// multi-valued, so this stays consistent with that.
    static func seriesFragment(op: FilterOperator, value: String) -> (String, [Binding?])? {
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

    /// Shared tag-membership EXISTS/NOT EXISTS shape. Callers supply their own
    /// already-formatted `matcher` (e.g. with or without `LOWER()`, single or
    /// OR-joined multi-term for synonym/multi-token expansion) and matching
    /// `args`; this function only owns the correlated-subquery wrapper, not the
    /// per-caller matching semantics.
    static func tagFragment(matcher: String, args: [Binding?], negated: Bool) -> (String, [Binding?])? {
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
}

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
    /// `LibraryFilterDebug.summary(expression:)` for the filter this
    /// `totalCount` was computed against, if any. Lets a surface being
    /// (re)mounted recognize "this exact filter is already counted" and
    /// skip discarding a known count back to nil — see applyFilterRules()
    /// in LibraryRootView/EmailLibraryViewController.
    let filterSignature: String?

    init(calibreIDs: [Int], totalCount: Int? = nil, isSQLBacked: Bool = false, filterSignature: String? = nil) {
        self.calibreIDs = calibreIDs
        self.totalCount = totalCount
        self.isSQLBacked = isSQLBacked
        self.filterSignature = filterSignature
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
            case .collection, .status, .fulltext, .crossover, .series, .authorName,
                 .tag, .rating, .warning, .category:
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

    /// §4.3 (Phase 3): needed for authorName rules -- `book_authors` lives in
    /// ambrosia_meta.db, a separate connection from `library`'s Calibre
    /// metadata.db (§1's Option A), so matching against it can't ride along
    /// on `library`'s own connection. Optional/nil-defaulted like this
    /// struct's other dependencies; a nil metaDB just means authorName rules
    /// fall back to Calibre-only matching (see `CalibreLibrary.authorMatchIDs`).
    let metaDB: AmbrosiaMetaDB?

    /// Pre-resolved synonym expansions for tag rule values, keyed by raw value.
    /// Populated async by the call site via `AmbrosiaMetaDB.expandedTerms(for:)`
    /// before the `Task.detached` is launched (Invariant 10).
    let tagExpansions: [String: [String]]

    init(library: CalibreLibrary, ftsLibrary: CalibreFTSLibrary? = nil,
         metaDB: AmbrosiaMetaDB? = nil,
         tagExpansions: [String: [String]] = [:]) {
        self.library = library
        self.ftsLibrary = ftsLibrary
        self.metaDB = metaDB
        self.tagExpansions = tagExpansions
    }

    /// Actor isolation on `CalibreLibrary`/`CalibreFTSLibrary` provides serialization
    /// (and off-main execution, since neither is `@MainActor`-isolated) for every
    /// query this makes — no manual `Task.detached` dispatch needed anymore.
    func matchingIDs(
        expression: FilterExpression,
        collectionMap: [String: Set<Int>] = [:],
        statusMap: [AO3CompletionStatus: Set<Int>] = [:],
        fulltextMap: [String: Set<Int>] = [:],
        crossoverMap: Set<Int> = [],
        wordCountFallbackMap: [Int: Int]? = nil,
        kudosFallbackMap: [Int: Int]? = nil,
        seriesNamesMap: [Int: [String]] = [:]
    ) async -> FilterResult {
        await matchingIDsSync(
            expression:           expression,
            collectionMap:        collectionMap,
            statusMap:            statusMap,
            fulltextMap:          fulltextMap,
            crossoverMap:         crossoverMap,
            wordCountFallbackMap: wordCountFallbackMap,
            kudosFallbackMap:     kudosFallbackMap,
            seriesNamesMap:       seriesNamesMap
        )
    }

    /// Evaluate a full FilterExpression (multiple groups joined by groupConjunction).
    private func matchingIDsSync(expression: FilterExpression,
                     collectionMap: [String: Set<Int>] = [:],
                     statusMap: [AO3CompletionStatus: Set<Int>] = [:],
                     fulltextMap: [String: Set<Int>] = [:],
                     crossoverMap: Set<Int> = [],
                     wordCountFallbackMap: [Int: Int]? = nil,
                     kudosFallbackMap: [Int: Int]? = nil,
                     seriesNamesMap: [Int: [String]] = [:]) async -> FilterResult {
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
                                    collectionMap: collectionMap,
                                    statusMap: statusMap,
                                    crossoverMap: crossoverMap,
                                    wordCountFallbackMap: wordCountFallbackMap,
                                    kudosFallbackMap: kudosFallbackMap,
                                    seriesNamesMap: seriesNamesMap)
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
                                     collectionMap: [String: Set<Int>],
                                     statusMap: [AO3CompletionStatus: Set<Int>],
                                     crossoverMap: Set<Int> = [],
                                     wordCountFallbackMap: [Int: Int]? = nil,
                                     kudosFallbackMap: [Int: Int]? = nil,
                                     seriesNamesMap: [Int: [String]] = [:]) async -> [Int] {
        let complete = group.completeRules
        guard !complete.isEmpty else { return await library.allCalibreIDs() }

        // Partition into SQL-evaluated vs in-memory-evaluated rules.
        // §6: .crossover is in-memory (backed by ao3_metadata fandoms).
        // §2a: .wordCountGT/.wordCountLT are SQL when custom column configured,
        //      in-memory via wordCountFallbackMap when not.
        // Phase 5: .series is in-memory (backed by AmbrosiaMetaDB's series_cache
        //      via seriesNamesMap), replacing the direct Calibre books_series_link/
        //      series SQL join — see §6 of the dependency-reduction plan.
        // §4.3 (Phase 3): .authorName is always in-memory now -- book_authors
        //      lives in ambrosia_meta.db, a separate connection metadata.db
        //      SQL can't reach (§1's Option A), unlike word count/kudos which
        //      only fall back to in-memory when unconfigured.
        // Phase 4: .tag/.rating/.warning/.category are in-memory (backed by
        //      AmbrosiaMetaDB's book_tags, unioned with a Calibre-side fallback
        //      for non-AO3 books via CalibreLibrary.tagFamilyMatchIDs) — see
        //      §5 of the dependency-reduction plan. Same dual-source-by-
        //      exclusion shape as .authorName above.
        let sqlRules        = complete.filter {
            $0.field != .collection &&
            $0.field != .status && $0.field != .fulltext && $0.field != .crossover &&
            $0.field != .series &&
            $0.field != .authorName &&
            $0.field != .tag && $0.field != .rating && $0.field != .warning && $0.field != .category
        }
        let collectionRules = complete.filter { $0.field == .collection }
        let statusRules     = complete.filter { $0.field == .status }
        let crossoverRules  = complete.filter { $0.field == .crossover }  // §6
        let seriesRules     = complete.filter { $0.field == .series }     // Phase 5
        let authorRules     = complete.filter { $0.field == .authorName }  // §4.3 (Phase 3)
        let tagFamilyRules  = complete.filter {
            $0.field == .tag || $0.field == .rating || $0.field == .warning || $0.field == .category
        }  // Phase 4

        // SQL rules: pass word-count rules through SQL if custom column is available;
        // signal nil back (by returning nil from sqlFragment) when not — handle below.
        var ids: [Int]
        if sqlRules.isEmpty {
            ids = await library.allCalibreIDs()
        } else {
            ids = await library.calibreIDs(matchingRules: sqlRules,
                                     conjunction: group.conjunction,
                                     wordCountFallbackMap: wordCountFallbackMap,
                                     kudosFallbackMap: kudosFallbackMap,
                                     tagExpansions: tagExpansions)
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
                switch rule.op {
                case .equals:    idSet = idSet.intersection(crossoverMap)
                case .notEquals: idSet = idSet.subtracting(crossoverMap)
                default:         break
                }
            }
            ids = Array(idSet).sorted()
        }

        // Phase 5: apply series rules in-memory against series_cache (via
        // seriesNamesMap, keyed by calibre_id -> that book's series_cache
        // series_name values). series_cache already carries a row — genuine
        // AO3 or Calibre-fallback — for every book, so unlike Phases 3/4 this
        // needs no union with a Calibre-side exclusion query; the map alone
        // is a complete partition of the library.
        if !seriesRules.isEmpty {
            var idSet = Set(ids)
            if group.conjunction == .and {
                for rule in seriesRules {
                    idSet = idSet.filter { id in
                        seriesRuleMatches(rule, names: seriesNamesMap[id] ?? [])
                    }
                }
            } else {
                var unionIDs = Set<Int>()
                for rule in seriesRules {
                    unionIDs.formUnion(idSet.filter { id in
                        seriesRuleMatches(rule, names: seriesNamesMap[id] ?? [])
                    })
                }
                idSet = unionIDs
            }
            ids = Array(idSet).sorted()
        }

        // §4.3 (Phase 3): apply authorName rules in-memory. book_authors lives in
        // ambrosia_meta.db, a separate connection from Calibre's metadata.db, so
        // this can no longer be a single SQL query (§1's Option A) -- each rule's
        // positive match set comes from CalibreLibrary.authorMatchIDs (which
        // itself unions book_authors with a Calibre-side fallback for books
        // book_authors doesn't cover) and is combined the same way collection/
        // status membership maps are above. notContains/notEquals subtract the
        // same positive set contains/equals would intersect with -- correct only
        // because of the book_authors/Calibre-fallback partition invariant
        // documented on CalibreLibrary.authorMatchIDs.
        if !authorRules.isEmpty {
            var idSet = Set(ids)
            if group.conjunction == .and {
                for rule in authorRules {
                    let memberIDs = await library.authorMatchIDs(
                        nameFragment: rule.value.trimmingCharacters(in: .whitespaces),
                        op: rule.op, metaDB: metaDB
                    )
                    switch rule.op {
                    case .contains, .equals, .startsWith: idSet = idSet.intersection(memberIDs)
                    case .notContains, .notEquals:        idSet = idSet.subtracting(memberIDs)
                    case .ratingAtMost, .ratingAtLeast:    break
                    }
                }
            } else {
                var unionIDs = Set<Int>()
                for rule in authorRules {
                    let memberIDs = await library.authorMatchIDs(
                        nameFragment: rule.value.trimmingCharacters(in: .whitespaces),
                        op: rule.op, metaDB: metaDB
                    )
                    switch rule.op {
                    case .contains, .equals, .startsWith: unionIDs.formUnion(idSet.intersection(memberIDs))
                    case .notContains, .notEquals:        unionIDs.formUnion(idSet.subtracting(memberIDs))
                    case .ratingAtMost, .ratingAtLeast:    break
                    }
                }
                idSet = unionIDs
            }
            ids = Array(idSet).sorted()
        }

        // Phase 4 (§5.4): apply tag/rating/warning/category rules in-memory.
        // Same shape as .authorName above: each rule's positive match set
        // comes from CalibreLibrary.tagFamilyMatchIDs (book_tags unioned with
        // a Calibre-side fallback for non-AO3 books), then intersected/
        // subtracted against the running id set. ratingAtMost/ratingAtLeast
        // have no negated counterpart (absolute range checks), so they only
        // ever intersect.
        if !tagFamilyRules.isEmpty {
            var idSet = Set(ids)
            if group.conjunction == .and {
                for rule in tagFamilyRules {
                    let memberIDs = await library.tagFamilyMatchIDs(
                        field: rule.field, op: rule.op, value: rule.value,
                        tagExpansions: tagExpansions, metaDB: metaDB
                    )
                    switch rule.op {
                    case .contains, .equals, .startsWith, .ratingAtMost, .ratingAtLeast:
                        idSet = idSet.intersection(memberIDs)
                    case .notContains, .notEquals:
                        idSet = idSet.subtracting(memberIDs)
                    }
                }
            } else {
                var unionIDs = Set<Int>()
                for rule in tagFamilyRules {
                    let memberIDs = await library.tagFamilyMatchIDs(
                        field: rule.field, op: rule.op, value: rule.value,
                        tagExpansions: tagExpansions, metaDB: metaDB
                    )
                    switch rule.op {
                    case .contains, .equals, .startsWith, .ratingAtMost, .ratingAtLeast:
                        unionIDs.formUnion(idSet.intersection(memberIDs))
                    case .notContains, .notEquals:
                        unionIDs.formUnion(idSet.subtracting(memberIDs))
                    }
                }
                idSet = unionIDs
            }
            ids = Array(idSet).sorted()
        }

        return ids
    }

    /// Phase 5: mirrors `MatchingSubqueryBuilder.seriesFragment`'s op/matcher
    /// semantics (case-insensitive contains/equals/startsWith), but evaluated
    /// against a book's already-fetched `series_cache` names in memory rather
    /// than as a SQL fragment. A book can belong to more than one series
    /// (`names` may have more than one entry), so a rule matches if it matches
    /// any of them — the same "any row for this book" semantics the correlated
    /// EXISTS subquery had.
    private func seriesRuleMatches(_ rule: FilterRule, names: [String]) -> Bool {
        let value = rule.value.trimmingCharacters(in: .whitespaces).lowercased()
        let lowerNames = names.map { $0.lowercased() }
        switch rule.op {
        case .contains:
            return lowerNames.contains { $0.contains(value) }
        case .notContains:
            return !lowerNames.contains { $0.contains(value) }
        case .equals:
            return lowerNames.contains { $0 == value }
        case .notEquals:
            return !lowerNames.contains { $0 == value }
        case .startsWith:
            return lowerNames.contains { $0.hasPrefix(value) }
        case .ratingAtMost, .ratingAtLeast:
            // Not offered for series (see FilterRule.availableOperators), matching
            // MatchingSubqueryBuilder.seriesFragment's own "no valid SQL shape" nil.
            return false
        }
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
                     collectionMap: [String: Set<Int>] = [:],
                     statusMap: [AO3CompletionStatus: Set<Int>] = [:]) async -> FilterResult {
        var expr = FilterExpression()
        expr.groups = [FilterGroup(rules: rules, conjunction: conjunction)]
        return await matchingIDs(expression: expr, collectionMap: collectionMap, statusMap: statusMap)
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
                    kudosFallbackMap: [Int: Int]? = nil,
                    tagExpansions: [String: [String]] = [:]) -> [Int] {
        guard !rules.isEmpty else { return allCalibreIDs() }

        // §2a: Separate out word-count rules that need in-memory fallback.
        // sqlFragment(for:) returns nil for wordCountGT/LT when no custom column is
        // configured — those rules are handled below against wordCountFallbackMap.
        // §2.2c: kudosGT/LT mirrors this exactly, against kudosFallbackMap.
        var clauses: [String] = []
        var args: [Binding?]  = []
        var wordCountFallbackRules: [FilterRule] = []
        var kudosFallbackRules: [FilterRule] = []

        for rule in rules {
            if rule.field == .wordCountGT || rule.field == .wordCountLT {
                if let (clause, ruleArgs) = sqlFragment(for: rule, tagExpansions: tagExpansions) {
                    clauses.append(clause)
                    args.append(contentsOf: ruleArgs)
                } else {
                    // No custom column — collect for in-memory fallback
                    wordCountFallbackRules.append(rule)
                }
            } else if rule.field == .kudosGT || rule.field == .kudosLT {
                if let (clause, ruleArgs) = sqlFragment(for: rule, tagExpansions: tagExpansions) {
                    clauses.append(clause)
                    args.append(contentsOf: ruleArgs)
                } else {
                    // No custom column — collect for in-memory fallback
                    kudosFallbackRules.append(rule)
                }
            } else if let (clause, ruleArgs) = sqlFragment(for: rule, tagExpansions: tagExpansions) {
                clauses.append(clause)
                args.append(contentsOf: ruleArgs)
            }
        }

        // §9: Previously also added a `LEFT JOIN books_tags_link btl / tags t`
        // whenever any rule touched .tag/.rating/.warning/.category. That join
        // is dead weight: every clause for those fields is built by
        // tagMembershipFragment/ao3TagFragment as a self-contained correlated
        // EXISTS/NOT EXISTS subquery aliased btl2/t2 — nothing in this file
        // references the outer t/btl aliases. The outer join fanned every book
        // out to one row per tag (10-20x row multiplication on a 74k-book
        // library) and forced NOT EXISTS to be re-evaluated once per fanned-out
        // row instead of once per book, before SELECT DISTINCT collapsed it
        // back down — this was the dominant cost of exclude/NOT queries, not
        // the correlated-subquery mechanism itself. Removed; see fix plan §1.
        let needsCommentJoin = rules.contains { $0.field == .comment }

        var joins: [String] = []
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

        // §2.2c: Apply kudos fallback in-memory when no custom column is configured.
        if !kudosFallbackRules.isEmpty, let fallbackMap = kudosFallbackMap {
            var idSet = Set(ids)
            for rule in kudosFallbackRules {
                guard let threshold = rule.numericValue else { continue }
                switch rule.field {
                case .kudosGT:
                    idSet = idSet.filter { id in (fallbackMap[id] ?? 0) > threshold }
                case .kudosLT:
                    idSet = idSet.filter { id in
                        guard let kc = fallbackMap[id] else { return false }
                        return kc < threshold
                    }
                default: break
                }
            }
            ids = Array(idSet).sorted()
        }

        return ids
    }

    /// §4.3 (Phase 3): positive match set for an authorName rule, combining
    /// `book_authors` (ambrosia_meta.db, via `metaDB`) with a Calibre-side
    /// fallback for books `book_authors` doesn't cover (non-`.success`
    /// extractions, or no `metaDB` in scope at all). Always returns the
    /// *positive* matcher regardless of the rule's op sign --
    /// `matchingIDsForGroup` applies negation via `.subtracting` against the
    /// full library, the same way it already does for collection/status
    /// membership maps. That's correct here only because `book_authors` and
    /// the Calibre-side fallback query partition the full calibre_id space
    /// cleanly (every book is either covered by a `book_authors` row set or
    /// falls through to the live Calibre query, never both) -- see the plan's
    /// §4.3 for why that partition is a named precondition, not incidental.
    func authorMatchIDs(nameFragment: String, op: FilterOperator, metaDB: AmbrosiaMetaDB?) async -> Set<Int> {
        let positiveOp: FilterOperator
        switch op {
        case .notContains: positiveOp = .contains
        case .notEquals:   positiveOp = .equals
        default:           positiveOp = op
        }

        func calibreMatches(excluding coverage: Set<Int>) -> Set<Int> {
            guard let (fragment, args) = MatchingSubqueryBuilder.authorFragment(op: positiveOp, value: nameFragment) else {
                return []
            }
            let sql = "SELECT b.id FROM books b WHERE \(fragment)"
            guard let rows = try? db_prepare(sql, args) else { return [] }
            let matches = Set(rows.compactMap { row in (row[0] as? Int64).map(Int.init) })
            return coverage.isEmpty ? matches : matches.subtracting(coverage)
        }

        guard let metaDB else {
            // No ambrosia_meta.db handle in scope -- fall back to the
            // pre-Phase-3 Calibre-only behavior rather than matching nothing.
            return calibreMatches(excluding: [])
        }
        let bookAuthorsMatches = (try? await metaDB.bookAuthorMatchIDs(nameFragment: nameFragment, op: positiveOp)) ?? []
        let coverage = (try? await metaDB.existingBookAuthorsIDs()) ?? []
        return bookAuthorsMatches.union(calibreMatches(excluding: coverage))
    }

    /// Phase 4 (§5.4): positive match set for a tag/rating/warning/category
    /// rule, combining `book_tags` (ambrosia_meta.db, via `metaDB`) with a
    /// Calibre-side fallback for books `book_tags` doesn't cover -- the same
    /// dual-source-by-exclusion shape as `authorMatchIDs` just above.
    /// `ratingAtMost`/`ratingAtLeast` have no negated counterpart (they're
    /// absolute range checks, not equality), so they pass through unchanged;
    /// `.notContains`/`.notEquals` are normalized to their positive form here
    /// too, same as authorMatchIDs -- the caller (`matchingIDsForGroup`)
    /// applies negation via `.subtracting` against the full library, correct
    /// only because `book_tags` and the Calibre-side fallback partition the
    /// full calibre_id space cleanly (see `AmbrosiaMetaDB.calibreIDsWithBookTags`).
    func tagFamilyMatchIDs(field: FilterField, op: FilterOperator, value: String,
                           tagExpansions: [String: [String]], metaDB: AmbrosiaMetaDB?) async -> Set<Int> {
        let positiveOp: FilterOperator
        switch op {
        case .notContains: positiveOp = .contains
        case .notEquals:   positiveOp = .equals
        default:           positiveOp = op
        }
        let tagType: String?
        switch field {
        case .rating:   tagType = "rating"
        case .warning:  tagType = "warning"
        case .category: tagType = "category"
        default:        tagType = nil  // .tag matches across all types
        }
        let terms = field == .tag ? (tagExpansions[value] ?? [value]) : [value]

        func calibreMatches(excluding coverage: Set<Int>) -> Set<Int> {
            let fragmentResult: (String, [Binding?])? = field == .tag
                ? expandedTagFragment(op: positiveOp, value: value, tagExpansions: tagExpansions)
                : ao3TagFragment(op: positiveOp, value: value)
            guard let (fragment, args) = fragmentResult else { return [] }
            let sql = "SELECT b.id FROM books b WHERE \(fragment)"
            guard let rows = try? db_prepare(sql, args) else { return [] }
            let matches = Set(rows.compactMap { row in (row[0] as? Int64).map(Int.init) })
            return coverage.isEmpty ? matches : matches.subtracting(coverage)
        }

        guard let metaDB else {
            // No ambrosia_meta.db handle in scope -- fall back to the
            // pre-Phase-4 Calibre-only behavior rather than matching nothing.
            return calibreMatches(excluding: [])
        }
        let bookTagsMatches = (try? await metaDB.bookTagMatchIDs(op: positiveOp, terms: terms, tagType: tagType)) ?? []
        let coverage = (try? await metaDB.calibreIDsWithBookTags()) ?? []
        return bookTagsMatches.union(calibreMatches(excluding: coverage))
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
            // Phase 5: evaluated in-memory against series_cache (via seriesNamesMap)
            // instead of a SQL fragment against Calibre's books_series_link/series.
            // See matchingIDsForGroup. MatchingSubqueryBuilder.seriesFragment still
            // backs the quick search-bar path in CalibreLibrarySearch.swift, which is
            // out of scope here.
            return nil

        case .comment:
            return textFragment(column: "c.text", op: rule.op, value: v,
                                nullClause: "c.text IS NULL")

        case .authorName:
            // §4.3 (Phase 3): no longer SQL against metadata.db -- book_authors
            // lives in ambrosia_meta.db, a separate connection (§1's Option A).
            // Evaluated in-memory via CalibreLibrary.authorMatchIDs; see
            // matchingIDsForGroup and isSQLPageable above.
            return nil

        case .tag:
            // Phase 4 (§5.4): no longer SQL against metadata.db -- book_tags
            // lives in ambrosia_meta.db, a separate connection (§1's Option A).
            // Evaluated in-memory via CalibreLibrary.tagFamilyMatchIDs; see
            // matchingIDsForGroup and isSQLPageable above. expandedTagFragment
            // itself is unchanged and still used internally by
            // tagFamilyMatchIDs for the Calibre-side fallback query.
            return nil
        case .rating:
            return nil
        case .warning:
            return nil
        case .category:
            return nil

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
            // §2b: Returns nil when no custom column is configured — caller handles fallback.
            guard let sql = kudosSQL(sqlOp: ">") else { return nil }
            return (sql, [n as Binding?])

        case .kudosLT:
            guard let n = rule.numericValue else { return nil }
            guard let sql = kudosSQL(sqlOp: "<") else { return nil }
            return (sql, [n as Binding?])

        case .crossover:
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
        MatchingSubqueryBuilder.tagFragment(matcher: matcher, args: args, negated: negated)
    }

    /// §8: All negative ao3TagFragment branches use correlated NOT EXISTS, matching
    /// the pattern established for general tags in tagMembershipFragment. This avoids
    /// materialising the full matching-book set for the anti-join.
    private func ao3TagFragment(op: FilterOperator, value: String) -> (String, [Binding?])? {
        switch op {
        case .equals:
            return MatchingSubqueryBuilder.tagFragment(matcher: "t2.name = ?", args: [value], negated: false)
        case .notEquals:
            return MatchingSubqueryBuilder.tagFragment(matcher: "t2.name = ?", args: [value], negated: true)
        case .contains:
            return MatchingSubqueryBuilder.tagFragment(matcher: "t2.name LIKE ?", args: ["%\(value)%"], negated: false)
        case .notContains:
            return MatchingSubqueryBuilder.tagFragment(matcher: "t2.name LIKE ?", args: ["%\(value)%"], negated: true)
        case .startsWith:
            return MatchingSubqueryBuilder.tagFragment(matcher: "t2.name LIKE ?", args: ["\(value)%"], negated: false)

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
            return MatchingSubqueryBuilder.tagFragment(matcher: "t2.name IN (\(placeholders))", args: args, negated: true)

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
            return MatchingSubqueryBuilder.tagFragment(matcher: "t2.name IN (\(placeholders))", args: args, negated: false)
        }
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

    /// §2b: Returns nil when no custom column is configured (caller applies ao3KudosFallbackMap in-memory).
    /// Previously returned "0 = 1" — that silently matched nothing. Now signals the caller
    /// to apply the kudos fallback in-memory instead.
    private func kudosSQL(sqlOp: String) -> String? {
        let label = CustomColumnConfig.shared.kudosLabel ?? "kudos"
        guard let tbl = customColumnTableName(label: label) else { return nil }
        return "b.id IN (SELECT book FROM \(tbl) WHERE value \(sqlOp) ?)"
    }

    internal func db_prepare(_ sql: String, _ args: [Binding?]) throws -> [[Binding?]] {
        return try db.prepare(sql, args).map { $0 }
    }
}
