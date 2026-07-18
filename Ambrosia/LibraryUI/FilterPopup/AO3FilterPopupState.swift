import Foundation

// MARK: - AO3FilterPopupState
//
// Independent, checkbox-shaped filter state modeled on AO3's own
// `_filters.html.erb` include/exclude panel. This is intentionally NOT
// derived from or synchronized with `FilterExpression` — it builds its own
// state and performs a one-way overwrite of `LibraryToolbarState
// .filterExpression` on Apply. See the AO3-style filter popup plan, §3.4.

@Observable
final class AO3FilterPopupState {

    // MARK: Tag facet fields (checkbox, include/exclude, mutually exclusive per value)

    var includedFandoms:       Set<String> = []
    var excludedFandoms:       Set<String> = []
    var includedRelationships: Set<String> = []
    var excludedRelationships: Set<String> = []
    var includedCharacters:    Set<String> = []
    var excludedCharacters:    Set<String> = []
    var includedFreeforms:     Set<String> = []
    var excludedFreeforms:     Set<String> = []

    // Warning/Category use AO3's own fixed vocabularies (AO3Warning/AO3Category)
    // rather than free-form facet strings, but are still include/exclude pairs.
    var includedWarnings:      Set<AO3Warning> = []
    var excludedWarnings:      Set<AO3Warning> = []
    var includedCategories:    Set<AO3Category> = []
    var excludedCategories:    Set<AO3Category> = []

    // MARK: Rating — AO3 renders this as a radio group when including (only one
    // rating can be "included" at a time), but still allows several ratings to
    // be excluded independently. Mirrors that asymmetry exactly (see
    // _filters.html.erb: radio only when filter_action == "include").
    var includedRating: AO3Rating? = nil
    var excludedRatings: Set<AO3Rating> = []

    // MARK: More Options — 3-way, matching AO3's blank/F/T radio groups exactly.
    enum TriState {
        case any
        case excludeOnly
        case includeOnly
    }
    var crossoverState: TriState = .any
    var completionState: TriState = .any

    // MARK: Sort (mirrors AO3's single "Sort and Filter" button doing both jobs)
    var sortField: SortField = .title
    var ascending: Bool = true

    // MARK: Lifetime tracking
    //
    // Digest of (FilterExpression, searchText) captured when this state was
    // created or last applied. Compared against the live toolbar state each
    // time the popup window is (re)opened; a mismatch means the underlying
    // search/filter changed since, so this state is discarded in favor of a
    // fresh `AO3FilterPopupState()`.
    let capturedDigest: String

    init(capturedDigest: String) {
        self.capturedDigest = capturedDigest
    }

    // MARK: Mutual exclusion helpers (mirrors AO3's toggleInclude/toggleExclude)

    func toggleInclude(_ value: String,
                        include: WritableKeyPath<AO3FilterPopupState, Set<String>>,
                        exclude: WritableKeyPath<AO3FilterPopupState, Set<String>>) {
        if self[keyPath: include].contains(value) {
            self[keyPath: include].remove(value)
        } else {
            self[keyPath: include].insert(value)
            self[keyPath: exclude].remove(value)
        }
    }

    func toggleExclude(_ value: String,
                        include: WritableKeyPath<AO3FilterPopupState, Set<String>>,
                        exclude: WritableKeyPath<AO3FilterPopupState, Set<String>>) {
        if self[keyPath: exclude].contains(value) {
            self[keyPath: exclude].remove(value)
        } else {
            self[keyPath: exclude].insert(value)
            self[keyPath: include].remove(value)
        }
    }

    func toggleInclude<T: Hashable>(_ value: T,
                                     include: WritableKeyPath<AO3FilterPopupState, Set<T>>,
                                     exclude: WritableKeyPath<AO3FilterPopupState, Set<T>>) {
        if self[keyPath: include].contains(value) {
            self[keyPath: include].remove(value)
        } else {
            self[keyPath: include].insert(value)
            self[keyPath: exclude].remove(value)
        }
    }

    func toggleExclude<T: Hashable>(_ value: T,
                                     include: WritableKeyPath<AO3FilterPopupState, Set<T>>,
                                     exclude: WritableKeyPath<AO3FilterPopupState, Set<T>>) {
        if self[keyPath: exclude].contains(value) {
            self[keyPath: exclude].remove(value)
        } else {
            self[keyPath: exclude].insert(value)
            self[keyPath: include].remove(value)
        }
    }
}

// MARK: - Digest helper

/// Builds the digest used to decide whether a popup's in-progress checkbox
/// state should be kept (search/filter unchanged since last open/Apply) or
/// discarded (search/filter changed underneath it). Reuses
/// `FilterResultCacheKey`'s `expressionDigest` construction rather than
/// inventing a second hashing scheme; `membershipVersion` is irrelevant here
/// (that field tracks book-list membership, not filter identity) so it is
/// passed as a throwaway constant.
enum AO3FilterPopupDigest {
    static func current(toolbarState: LibraryToolbarState) -> String {
        let key = FilterResultCacheKey(expression: toolbarState.filterExpression, membershipVersion: 0)
        return key.expressionDigest + "||" + toolbarState.searchText
    }
}

// MARK: - Building the final FilterExpression on Apply

extension AO3FilterPopupState {
    /// Builds a fresh `FilterExpression` from the popup's own state. This is
    /// a one-way overwrite target for `LibraryToolbarState.filterExpression`
    /// — it does not attempt to preserve anything from whatever expression
    /// was previously active.
    func buildExpression() -> FilterExpression {
        var includeGroup = FilterGroup(conjunction: .and)
        var excludeGroup = FilterGroup(conjunction: .and) // AND-of-NOTs == AO3's must_not-any semantics

        func addTagRules(include: Set<String>, exclude: Set<String>, field: FilterField = .tag) {
            for v in include { includeGroup.rules.append(FilterRule(field: field, op: .equals, value: v)) }
            for v in exclude { excludeGroup.rules.append(FilterRule(field: field, op: .notEquals, value: v)) }
        }

        addTagRules(include: includedFandoms, exclude: excludedFandoms)
        addTagRules(include: includedRelationships, exclude: excludedRelationships)
        addTagRules(include: includedCharacters, exclude: excludedCharacters)
        addTagRules(include: includedFreeforms, exclude: excludedFreeforms)

        for w in includedWarnings { includeGroup.rules.append(FilterRule(field: .warning, op: .equals, value: w.rawValue)) }
        for w in excludedWarnings { excludeGroup.rules.append(FilterRule(field: .warning, op: .notEquals, value: w.rawValue)) }
        for c in includedCategories { includeGroup.rules.append(FilterRule(field: .category, op: .equals, value: c.rawValue)) }
        for c in excludedCategories { excludeGroup.rules.append(FilterRule(field: .category, op: .notEquals, value: c.rawValue)) }

        if let includedRating {
            includeGroup.rules.append(FilterRule(field: .rating, op: .equals, value: includedRating.rawValue))
        }
        for r in excludedRatings {
            excludeGroup.rules.append(FilterRule(field: .rating, op: .notEquals, value: r.rawValue))
        }

        switch crossoverState {
        case .any: break
        case .includeOnly: includeGroup.rules.append(FilterRule(field: .crossover, op: .equals, value: "true"))
        case .excludeOnly: includeGroup.rules.append(FilterRule(field: .crossover, op: .equals, value: "false"))
        }
        switch completionState {
        case .any: break
        case .includeOnly: includeGroup.rules.append(FilterRule(field: .status, op: .equals, value: AO3CompletionStatus.complete.rawValue))
        case .excludeOnly: includeGroup.rules.append(FilterRule(field: .status, op: .equals, value: AO3CompletionStatus.workInProgress.rawValue))
        }

        var expr = FilterExpression()
        expr.groups = [includeGroup, excludeGroup].filter { !$0.rules.isEmpty }
        expr.groupConjunction = .and
        return expr.groups.isEmpty ? FilterExpression() : expr
    }
}
