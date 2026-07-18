import Foundation

// MARK: - AO3FilterFacetController
//
// Popup-side glue that answers "what's the current base result set, and what
// does it look like with the popup's own in-progress checkboxes applied
// (excluding one field at a time)?" — mirroring AO3's own facet-scoping
// behavior (§2 of the plan: facet counts are scoped to whatever the
// search/filter is already narrowed to, and recompute live as more boxes are
// checked).
//
// This intentionally reuses `FilterBuilder` for the "intersect with other
// fields' current selections" step (via a throwaway `FilterExpression` built
// purely for scoping) rather than duplicating its SQL machinery. Only
// `AO3FilterPopupState.buildExpression()` builds the "real" expression that
// gets written to `LibraryToolbarState` on Apply.
@MainActor
final class AO3FilterFacetController {
    let metaDB: AmbrosiaMetaDB
    let library: CalibreLibrary
    let filterBuilder: FilterBuilder

    /// Fixed for the popup's lifetime: the toolbar/drawer's current match
    /// set, captured once when the popup opens. The popup never mutates
    /// `filterExpression` until Apply, so this doesn't change underneath it
    /// while the popup is open.
    let baseIDs: Set<Int>

    private let crossoverMap: Set<Int>
    private let statusMap: [AO3CompletionStatus: Set<Int>]

    private init(metaDB: AmbrosiaMetaDB, library: CalibreLibrary, filterBuilder: FilterBuilder,
                 baseIDs: Set<Int>, crossoverMap: Set<Int>, statusMap: [AO3CompletionStatus: Set<Int>]) {
        self.metaDB = metaDB
        self.library = library
        self.filterBuilder = filterBuilder
        self.baseIDs = baseIDs
        self.crossoverMap = crossoverMap
        self.statusMap = statusMap
    }

    /// Builds a controller scoped to `toolbarState`'s currently active
    /// filter/search, following the same construction pattern
    /// `LibraryRootView`/`EmailLibraryViewController` use per-query: a fresh
    /// `FilterBuilder`, built from `session.library`/`session.ftsLibrary`,
    /// with synonym expansions and crossover/status membership maps
    /// resolved up front. crossoverMap/statusMap are always computed (not
    /// gated on the base expression) — see fix note below.
    static func make(toolbarState: LibraryToolbarState,
                      metaDB: AmbrosiaMetaDB,
                      library: CalibreLibrary,
                      ftsLibrary: CalibreFTSLibrary?,
                      collectionStore: CollectionStore?) async -> AO3FilterFacetController {
        let expression = toolbarState.filterExpression
        let tagExpansions = await TagExpansionResolver.filterTagExpansions(for: expression, metaDB: metaDB)
        let filterBuilder = FilterBuilder(library: library, ftsLibrary: ftsLibrary, tagExpansions: tagExpansions)

        // Always computed, unconditionally: unlike LibraryRootView's per-query
        // path, these maps back scoping queries built from the popup's OWN
        // in-progress crossoverState/completionState (via otherFieldsExpression),
        // not just whatever the base toolbar expression happens to contain.
        // Gating on the base expression (the old `needsCrossover`/`needsStatus`
        // checks) left these empty the moment a user touched either control,
        // and idSet.intersection([]) is always empty — every tag facet
        // silently dropped to zero. Both are cheap (actor-cached crossover
        // IDs; a handful of indexed lookups over a small fixed enum for
        // status), so there's no cost reason to keep the old gating.
        let crossoverMap = await library.crossoverBookIDs()

        var statusMap: [AO3CompletionStatus: Set<Int>] = [:]
        for status in AO3CompletionStatus.allCases {
            statusMap[status] = (try? await metaDB.ao3CompletionStatusIDs(status)) ?? []
        }

        var likedIDs: Set<Int> = []
        let needsLiked = expression.groups.flatMap(\.rules).contains { $0.field == .isLiked }
        if needsLiked {
            likedIDs = (try? await collectionStore?.likedIDs()) ?? []
        }

        // `FilterBuilder.matchingIDs` treats an expression with no complete
        // rules as "match nothing" (see matchingIDsSync's early-return
        // branch), not "match everything" — it's designed to be called only
        // when `expression.hasCompleteRules` is true, exactly like
        // `LibraryRootView.applyFilterRules` guards before ever calling it.
        // With no active drawer/search filter, the popup's base scope is the
        // whole library, so that path is skipped here too.
        let baseIDs: Set<Int>
        if expression.hasCompleteRules {
            let baseResult = await filterBuilder.matchingIDs(
                expression: expression,
                likedIDs: likedIDs,
                statusMap: statusMap,
                crossoverMap: crossoverMap
            )
            baseIDs = Set(baseResult.calibreIDs)
        } else {
            baseIDs = Set(await library.allCalibreIDs())
        }

        return AO3FilterFacetController(
            metaDB: metaDB, library: library, filterBuilder: filterBuilder,
            baseIDs: baseIDs, crossoverMap: crossoverMap, statusMap: statusMap
        )
    }

    /// Scoped ID set for computing one field's facet: `baseIDs` intersected
    /// with everything the popup's OWN state currently requires, excluding
    /// that field's own selections (AO3's "ignoring: type" behavior — so
    /// toggling a Fandom checkbox narrows Character/Freeform/etc. counts but
    /// never its own).
    func scopedIDs(ignoring field: AO3FacetField?, state: AO3FilterPopupState) async -> [Int] {
        let popupExpression = otherFieldsExpression(ignoring: field, state: state)
        guard !popupExpression.isEmpty else { return Array(baseIDs) }

        let result = await filterBuilder.matchingIDs(
            expression: popupExpression,
            likedIDs: [],
            statusMap: statusMap,
            crossoverMap: crossoverMap
        )
        return Array(baseIDs.intersection(result.calibreIDs))
    }

    /// Builds a throwaway `FilterExpression` representing every popup field's
    /// current selections EXCEPT `field` (and except rating, which has its
    /// own scoping entry point below). Used purely for scoping — never
    /// written to `LibraryToolbarState`.
    private func otherFieldsExpression(ignoring field: AO3FacetField?, state: AO3FilterPopupState) -> FilterExpression {
        var includeGroup = FilterGroup(conjunction: .and)
        var excludeGroup = FilterGroup(conjunction: .and)

        func addTagRules(_ include: Set<String>, _ exclude: Set<String>, _ filterField: FilterField) {
            for v in include { includeGroup.rules.append(FilterRule(field: filterField, op: .equals, value: v)) }
            for v in exclude { excludeGroup.rules.append(FilterRule(field: filterField, op: .notEquals, value: v)) }
        }

        if field != .fandom { addTagRules(state.includedFandoms, state.excludedFandoms, .tag) }
        if field != .relationship { addTagRules(state.includedRelationships, state.excludedRelationships, .tag) }
        if field != .character { addTagRules(state.includedCharacters, state.excludedCharacters, .tag) }
        if field != .freeform { addTagRules(state.includedFreeforms, state.excludedFreeforms, .tag) }
        if field != .warning {
            for w in state.includedWarnings { includeGroup.rules.append(FilterRule(field: .warning, op: .equals, value: w.rawValue)) }
            for w in state.excludedWarnings { excludeGroup.rules.append(FilterRule(field: .warning, op: .notEquals, value: w.rawValue)) }
        }
        if field != .category {
            for c in state.includedCategories { includeGroup.rules.append(FilterRule(field: .category, op: .equals, value: c.rawValue)) }
            for c in state.excludedCategories { excludeGroup.rules.append(FilterRule(field: .category, op: .notEquals, value: c.rawValue)) }
        }

        // Rating, crossover, and completion status always narrow every tag
        // facet — none of them has a same-type facet list of its own to
        // avoid self-narrowing.
        if let includedRating = state.includedRating {
            includeGroup.rules.append(FilterRule(field: .rating, op: .equals, value: includedRating.rawValue))
        }
        for r in state.excludedRatings {
            excludeGroup.rules.append(FilterRule(field: .rating, op: .notEquals, value: r.rawValue))
        }
        switch state.crossoverState {
        case .any: break
        case .includeOnly: includeGroup.rules.append(FilterRule(field: .crossover, op: .equals, value: "true"))
        case .excludeOnly: includeGroup.rules.append(FilterRule(field: .crossover, op: .equals, value: "false"))
        }
        switch state.completionState {
        case .any: break
        case .includeOnly: includeGroup.rules.append(FilterRule(field: .status, op: .equals, value: AO3CompletionStatus.complete.rawValue))
        case .excludeOnly: includeGroup.rules.append(FilterRule(field: .status, op: .equals, value: AO3CompletionStatus.workInProgress.rawValue))
        }

        var expr = FilterExpression()
        expr.groups = [includeGroup, excludeGroup].filter { !$0.rules.isEmpty }
        expr.groupConjunction = .and
        return expr
    }

    /// Rating facet scoping: ignores only the rating fields themselves (no
    /// `AO3FacetField` case for rating — it's handled separately from the
    /// six JSON-column facets).
    func scopedIDsForRating(state: AO3FilterPopupState) async -> [Int] {
        await scopedIDs(ignoring: nil, state: ratingExcludedState(state))
    }

    /// Returns a lightweight copy of `state` with rating selections cleared,
    /// so rating's own scoping doesn't narrow against itself. Only rating
    /// fields are cleared; every other field's selections still apply.
    private func ratingExcludedState(_ state: AO3FilterPopupState) -> AO3FilterPopupState {
        let copy = AO3FilterPopupState(capturedDigest: state.capturedDigest)
        copy.includedFandoms = state.includedFandoms
        copy.excludedFandoms = state.excludedFandoms
        copy.includedRelationships = state.includedRelationships
        copy.excludedRelationships = state.excludedRelationships
        copy.includedCharacters = state.includedCharacters
        copy.excludedCharacters = state.excludedCharacters
        copy.includedFreeforms = state.includedFreeforms
        copy.excludedFreeforms = state.excludedFreeforms
        copy.includedWarnings = state.includedWarnings
        copy.excludedWarnings = state.excludedWarnings
        copy.includedCategories = state.includedCategories
        copy.excludedCategories = state.excludedCategories
        copy.crossoverState = state.crossoverState
        copy.completionState = state.completionState
        // includedRating/excludedRatings intentionally left at their defaults (nil/[]).
        return copy
    }
}
