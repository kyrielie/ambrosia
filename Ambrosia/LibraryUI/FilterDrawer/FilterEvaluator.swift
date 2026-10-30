import Foundation

/// Kill switch for narrowing a new filter from a cached base result
/// (plan PR I). Read once per apply.
///
/// Default: on in debug builds, off in release builds, until gate G3 of the
/// plan (narrowing equals full compute in the UI) has been run by hand.
/// Override with `defaults write <bundle id> incrementalFilterEvaluation -bool YES|NO`.
enum IncrementalFilterFlag {
    static let defaultsKey = "incrementalFilterEvaluation"

    static var isEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Bool { return stored }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

/// Evaluates a `FilterExpression` into an explicit-ID `FilterResult`, with an
/// optional candidate set. Shared by the list surface (and, in a separate
/// commit, email) so the map-building, two-pass word-count and kudos handling
/// exists once.
///
/// Holds only actor references and plain values, never `LibrarySession`, so it
/// can run off the main actor without capturing view state. Callers supply the
/// cached `fulltext:` lookup as a prebuilt snapshot (`fulltextMap`) because that
/// cache lives on the main-actor session. Visibility filtering is NOT done here;
/// it is the caller's job, because only the full-compute path applies it (a
/// narrowed result inherits it from its base).
///
/// Cancellation is cooperative: between phases the evaluator checks
/// `Task.isCancelled` and returns nil. The caller's token guard stays the
/// final authority on whether a result is committed.
struct FilterEvaluator {

    let library: CalibreLibrary
    let ftsLibrary: CalibreFTSLibrary?
    let metaDB: AmbrosiaMetaDB?
    let collectionStore: CollectionStore?
    let ruleMatchCache: RuleMatchCache?
    let bookTagsRevision: Int

    /// Inputs besides the expression that change how it is evaluated: whether
    /// word-count and kudos are custom columns (SQL) or ao3_metadata (second
    /// pass). Appended to the filter cache's visibility signature so a cached
    /// base is never reused across a change to that configuration.
    static var environmentSignature: String {
        ".wc\(CustomColumnConfig.shared.wordCountLabel == nil ? 0 : 1)"
            + ".ku\(CustomColumnConfig.shared.kudosLabel == nil ? 0 : 1)"
    }

    struct Output {
        /// Explicit, sorted IDs. Not visibility-filtered.
        let result: FilterResult
        /// Synonym expansions resolved for `expression`'s tag rules.
        let tagExpansions: [String: [String]]
    }

    init(library: CalibreLibrary,
         ftsLibrary: CalibreFTSLibrary?,
         metaDB: AmbrosiaMetaDB?,
         collectionStore: CollectionStore?,
         ruleMatchCache: RuleMatchCache? = nil,
         bookTagsRevision: Int = 0) {
        self.library = library
        self.ftsLibrary = ftsLibrary
        self.metaDB = metaDB
        self.collectionStore = collectionStore
        self.ruleMatchCache = ruleMatchCache
        self.bookTagsRevision = bookTagsRevision
    }

    /// `candidates` non-nil means: only these books can match. The result is
    /// then always a subset of `candidates`. Returns nil when cancelled.
    func evaluate(expression: FilterExpression,
                  fulltextMap: [String: Set<Int>],
                  candidates: Set<Int>? = nil) async -> Output? {
        let rules = expression.groups.flatMap(\.rules)

        let needsCollection = rules.contains { $0.field == .collection }
        var collectionMap: [String: Set<Int>] = needsCollection
            ? ((try? await collectionStore?.membershipMap()) ?? [:]) : [:]
        let statusValues = Set(rules.filter { $0.field == .status }
                                    .compactMap { AO3CompletionStatus(userValue: $0.value) })
        var statusMap: [AO3CompletionStatus: Set<Int>] = [:]
        if let metaDB {
            for status in statusValues {
                statusMap[status] = (try? await metaDB.ao3CompletionStatusIDs(status)) ?? []
            }
            if needsCollection && expression.referencesSeriesOrMergedCollection {
                collectionMap[SystemCollectionID.seriesOrMergedName] = (try? await metaDB.leadsAtLeastOneSeriesIDs()) ?? []
            }
            if needsCollection {
                let failedIDs = Set((try? await metaDB.allAO3Diagnostics(failedOnly: false).map(\.calibreID)) ?? [])
                collectionMap[SystemCollectionID.failedExtractionName] = failedIDs
            }
        }
        guard !Task.isCancelled else { return nil }

        // Snapshot the var maps as lets before they cross into the builder calls
        // (Swift 6 forbids capturing a var into concurrently-executing code).
        let collectionMapSnapshot = collectionMap
        let statusMapSnapshot = statusMap

        // §6: crossover map, IDs with fandoms.count > 1 in ao3_metadata.
        let crossoverMap: Set<Int> = rules.contains { $0.field == .crossover }
            ? await library.crossoverBookIDs() : []

        // Phase 5: calibre_id -> series_cache names. Restricted to the candidates
        // when narrowing, so the lookup does not read the whole library.
        var seriesNamesMap: [Int: [String]] = [:]
        if rules.contains(where: { $0.field == .series }), let metaDB {
            let ids: [Int]
            if let candidates { ids = Array(candidates) } else { ids = await library.allCalibreIDs() }
            let entries = (try? await metaDB.seriesEntries(for: ids)) ?? []
            seriesNamesMap = Dictionary(grouping: entries, by: \.calibreID).mapValues { $0.map(\.seriesName) }
        }
        guard !Task.isCancelled else { return nil }

        // §perf Fix 6 / §2.2c: two-pass word-count and kudos filtering. Pass 1
        // runs every other rule; pass 2 fetches the values for the survivors only.
        let needsWordCountFallback = rules.contains { $0.field == .wordCountGT || $0.field == .wordCountLT }
            && CustomColumnConfig.shared.wordCountLabel == nil
        let needsKudosFallback = rules.contains { $0.field == .kudosGT || $0.field == .kudosLT }
            && CustomColumnConfig.shared.kudosLabel == nil

        func isFallbackRule(_ rule: FilterRule) -> Bool {
            (needsWordCountFallback && (rule.field == .wordCountGT || rule.field == .wordCountLT))
                || (needsKudosFallback && (rule.field == .kudosGT || rule.field == .kudosLT))
        }

        var expressionWithoutFallback = expression
        if needsWordCountFallback || needsKudosFallback {
            expressionWithoutFallback.groups = expression.groups.compactMap { group in
                let kept = group.rules.filter { !isFallbackRule($0) }
                guard !kept.isEmpty else { return nil }
                return FilterGroup(rules: kept, conjunction: group.conjunction)
            }
        }

        let filterTagExpansions = await TagExpansionResolver.filterTagExpansions(for: expression, metaDB: metaDB)
        guard !Task.isCancelled else { return nil }
        let builder = FilterBuilder(library: library, ftsLibrary: ftsLibrary,
                                    metaDB: metaDB, tagExpansions: filterTagExpansions,
                                    ruleMatchCache: ruleMatchCache, bookTagsRevision: bookTagsRevision)

        // Pass 1. With candidates and nothing left after stripping (a lone
        // word-count or kudos delta), the survivors are simply the candidates;
        // `matchingIDs` of an empty expression would return no IDs.
        let pass1Result: FilterResult
        if let candidates, !expressionWithoutFallback.hasCompleteRules {
            let sorted = candidates.sorted()
            pass1Result = FilterResult(calibreIDs: sorted, totalCount: sorted.count)
        } else {
            pass1Result = await builder.matchingIDs(
                expression: expressionWithoutFallback,
                collectionMap: collectionMapSnapshot,
                statusMap: statusMapSnapshot,
                fulltextMap: fulltextMap,
                crossoverMap: crossoverMap,
                wordCountFallbackMap: nil,
                kudosFallbackMap: nil,
                seriesNamesMap: seriesNamesMap,
                candidateIDs: candidates
            )
        }
        guard !Task.isCancelled else { return nil }

        guard needsWordCountFallback || needsKudosFallback else {
            return Output(result: pass1Result, tagExpansions: filterTagExpansions)
        }

        // Pass 2: word-count and kudos rules, evaluated in memory on the survivors.
        let survivors = pass1Result.calibreIDs
        let wordCountFallback = needsWordCountFallback ? await library.ao3WordCounts(ids: survivors) : nil
        let kudosFallback = needsKudosFallback ? await library.ao3Kudos(ids: survivors) : nil

        var fallbackOnly = FilterExpression()
        fallbackOnly.groups = expression.groups.compactMap { group in
            let kept = group.rules.filter { isFallbackRule($0) && $0.isComplete }
            guard !kept.isEmpty else { return nil }
            return FilterGroup(rules: kept, conjunction: group.conjunction)
        }
        fallbackOnly.groupConjunction = expression.groupConjunction

        guard fallbackOnly.hasCompleteRules else {
            return Output(result: pass1Result, tagExpansions: filterTagExpansions)
        }
        let pass2Result = await builder.matchingIDs(
            expression: fallbackOnly,
            collectionMap: [:],
            statusMap: [:],
            fulltextMap: [:],
            crossoverMap: [],
            wordCountFallbackMap: wordCountFallback,
            kudosFallbackMap: kudosFallback,
            seriesNamesMap: [:]
        )
        let pass2Set = Set(pass2Result.calibreIDs)
        let combined = survivors.filter { pass2Set.contains($0) }
        return Output(result: FilterResult(calibreIDs: combined, totalCount: combined.count),
                      tagExpansions: filterTagExpansions)
    }
}
