import Foundation
import SwiftData

// MARK: - LibraryQueryHelpers
//
// Both LibraryRootView (SwiftUI, List surface) and EmailLibraryViewController
// (AppKit, Email surface) independently reimplemented these exact helpers —
// see Finding 2 in ambrosia_cleanup_plan.md. The bodies below are the shared
// logic, taking each surface's own state as parameters instead of reading
// instance properties directly, so neither surface has to give up ownership
// of its @State / stored properties to use them.
//
// loadPage(...) and applyFilterRules(...) are deliberately NOT here: List
// paginates via discrete page replacement (Previous/Next, currentPage *
// pageSize) while Email is infinite-scroll append (loadPage(reset:), books
// grows via append(contentsOf:)). Merging those would mean redesigning one
// surface's pagination model, not deduplicating — out of scope for a cleanup
// pass. This file covers only the pieces that are genuinely identical.
enum LibraryQueryHelpers {

    /// NOTE: `visibleIDs`/`visibleBooks` used to live here as free functions
    /// taking 6-8 parameters each. Both call sites (LibraryRootView,
    /// EmailLibraryViewController) now build a `LibraryVisibilityPolicy` once
    /// (`currentVisibilityPolicy`) and call `.filter(_:)` directly — see
    /// LibraryVisibilityPolicy.swift. Retired rather than left as unused dead code.

    /// Intersects `ids` with `optionalIDs`, or returns `ids` unchanged if
    /// `optionalIDs` is nil (i.e. "no additional restriction").
    static func intersect(_ ids: [Int], with optionalIDs: [Int]?) -> [Int] {
        guard let other = optionalIDs else { return ids }
        let allowed = Set(other)
        return ids.filter { allowed.contains($0) }
    }

    /// Rewrites `query.ftsMatchedIDs` from the session's full-text cache when a
    /// cached result exists for the query's full-text phrase, so `whereClause`
    /// never needs to open its own connection to resolve full text (Invariant 10).
    @MainActor
    static func queryWithCachedFullText(_ query: SearchQuery, session: LibrarySession) -> SearchQuery {
        guard let phrase = query.fulltextPhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phrase.isEmpty else { return query }
        guard let ids = session.cachedFulltextIDs(for: phrase) else { return query }
        return SearchQuery(
            tagTerms: query.tagTerms,
            authorTerms: query.authorTerms,
            titleTerms: query.titleTerms,
            seriesTerms: query.seriesTerms,
            statusTerms: query.statusTerms,
            fulltextPhrase: query.fulltextPhrase,
            plainTerms: [],
            ftsMatchedIDs: ids
        )
    }

    /// Mutates `expression` in place to add `rule`, replacing any existing
    /// rule for single-value fields (author, series) instead of stacking, and
    /// skipping exact duplicates. Callers are responsible for re-running the
    /// filter afterward.
    static func addOrReplaceRule(_ rule: FilterRule, in expression: inout FilterExpression) {
        if expression.groups.isEmpty {
            expression.groups = [FilterGroup()]
        }
        let allRules = expression.groups.flatMap(\.rules)
        let isDuplicate = allRules.contains {
            $0.field == rule.field && $0.value == rule.value && $0.op == rule.op
        }
        guard !isDuplicate else { return }
        if rule.field == .authorName || rule.field == .series || rule.field == .collection {
            expression.groups[0].rules.removeAll { $0.field == rule.field }
        }
        expression.groups[0].rules.append(rule)
    }

    /// Fetches (or creates and inserts) the `BookState` row for `calibreID` in
    /// `context`. Callers are responsible for calling `context.save()`.
    static func stateForMutation(_ calibreID: Int, in context: ModelContext) -> BookState {
        var desc = FetchDescriptor<BookState>(
            predicate: #Predicate { $0.calibreID == calibreID }
        )
        desc.fetchLimit = 1
        let state = (try? context.fetch(desc).first) ?? BookState(calibreID: calibreID)
        if state.modelContext == nil {
            context.insert(state)
        }
        return state
    }
}
