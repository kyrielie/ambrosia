import Foundation

// MARK: - AO3FilterPopupState
//
// Independent, checkbox-shaped filter state modeled on AO3's own
// `_filters.html.erb` include/exclude panel. This is intentionally NOT
// derived from or synchronized with `FilterExpression` — it builds its own
// state and performs a one-way overwrite of `LibraryToolbarState
// .filterExpression` on Apply. See the AO3-style filter popup plan, §3.4.

// MARK: - Rating Match Mode
enum RatingMatch: String, CaseIterable, Identifiable {
    case exact = "Exact"
    case orHigher = "Rating+"
    case orLower = "Rating−"

    var id: String { rawValue }
}

// MARK: - FilterSelectionState (3-state cycling: Clear -> Included -> Excluded -> Clear)
enum FilterSelectionState {
    case clear
    case included
    case excluded

    var next: FilterSelectionState {
        switch self {
        case .clear: return .included
        case .included: return .excluded
        case .excluded: return .clear
        }
    }
}

@Observable
final class AO3FilterPopupState {

    // MARK: Tag facet fields (checkbox, include/exclude, mutually exclusive per value)

    var includedFandoms: Set<String> = []
    var excludedFandoms: Set<String> = []
    var includedRelationships: Set<String> = []
    var excludedRelationships: Set<String> = []
    var includedCharacters: Set<String> = []
    var excludedCharacters: Set<String> = []
    var includedFreeforms: Set<String> = []
    var excludedFreeforms: Set<String> = []
    var includedAuthors: Set<String> = []
    var excludedAuthors: Set<String> = []

    // Warning/Category use AO3's own fixed vocabularies (AO3Warning/AO3Category)
    // rather than free-form facet strings, but are still include/exclude pairs.
    var includedWarnings: Set<AO3Warning> = []
    var excludedWarnings: Set<AO3Warning> = []
    var includedCategories: Set<AO3Category> = []
    var excludedCategories: Set<AO3Category> = []

    // MARK: Rating
    var includedRating: AO3Rating?
    var excludedRatings: Set<AO3Rating> = []
    var ratingMatch: RatingMatch = .exact
    var includeNotRated: Bool = false

    // MARK: Numeric bounds (word count & kudos)
    var wordsFrom: Int?
    var wordsTo: Int?
    var kudosFrom: Int?
    var kudosTo: Int?

    // MARK: Preserved unmanaged rules from drawer
    var passthroughRules: [FilterRule] = []

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
    var capturedDigest: String

    init(capturedDigest: String) {
        self.capturedDigest = capturedDigest
    }

    /// Lossless initialization from an active `FilterExpression`, mapping
    /// recognized fields into structured properties and retaining unmapped
    /// drawer rules in `passthroughRules`.
    convenience init(from expression: FilterExpression, capturedDigest: String) {
        self.init(capturedDigest: capturedDigest)

        for group in expression.groups {
            for rule in group.rules {
                switch rule.field {
                case .tag:
                    if rule.op == .equals {
                        if let rating = AO3Rating(rawValue: rule.value) {
                            includedRating = rating
                            ratingMatch = .exact
                        } else if let warning = AO3Warning(rawValue: rule.value) {
                            includedWarnings.insert(warning)
                        } else if let category = AO3Category(rawValue: rule.value) {
                            includedCategories.insert(category)
                        } else {
                            includedFreeforms.insert(rule.value)
                        }
                    } else if rule.op == .notEquals {
                        if let rating = AO3Rating(rawValue: rule.value) {
                            excludedRatings.insert(rating)
                        } else if let warning = AO3Warning(rawValue: rule.value) {
                            excludedWarnings.insert(warning)
                        } else if let category = AO3Category(rawValue: rule.value) {
                            excludedCategories.insert(category)
                        } else {
                            excludedFreeforms.insert(rule.value)
                        }
                    } else if rule.op == .ratingAtMost {
                        if let rating = AO3Rating(rawValue: rule.value) {
                            includedRating = rating
                            ratingMatch = .orLower
                        }
                    } else if rule.op == .ratingAtLeast {
                        if let rating = AO3Rating(rawValue: rule.value) {
                            includedRating = rating
                            ratingMatch = .orHigher
                        }
                    } else {
                        passthroughRules.append(rule)
                    }

                case .authorName:
                    if rule.op == .equals {
                        includedAuthors.insert(rule.value)
                    } else if rule.op == .notEquals {
                        excludedAuthors.insert(rule.value)
                    } else {
                        passthroughRules.append(rule)
                    }

                case .warning:
                    if let warning = AO3Warning(rawValue: rule.value) {
                        if rule.op == .equals {
                            includedWarnings.insert(warning)
                        } else if rule.op == .notEquals {
                            excludedWarnings.insert(warning)
                        }
                    }

                case .category:
                    if let category = AO3Category(rawValue: rule.value) {
                        if rule.op == .equals {
                            includedCategories.insert(category)
                        } else if rule.op == .notEquals {
                            excludedCategories.insert(category)
                        }
                    }

                case .rating:
                    if let rating = AO3Rating(rawValue: rule.value) {
                        switch rule.op {
                        case .equals:
                            includedRating = rating
                            ratingMatch = .exact
                        case .notEquals:
                            excludedRatings.insert(rating)
                        case .ratingAtMost:
                            includedRating = rating
                            ratingMatch = .orLower
                        case .ratingAtLeast:
                            includedRating = rating
                            ratingMatch = .orHigher
                        default:
                            passthroughRules.append(rule)
                        }
                    }

                case .crossover:
                    if rule.op == .equals {
                        crossoverState = .includeOnly
                    } else if rule.op == .notEquals {
                        crossoverState = .excludeOnly
                    }

                case .status:
                    if rule.value == AO3CompletionStatus.complete.rawValue {
                        completionState = .includeOnly
                    } else if rule.value == AO3CompletionStatus.workInProgress.rawValue {
                        completionState = .excludeOnly
                    }

                case .wordCountGT:
                    wordsFrom = Int(rule.value)
                case .wordCountLT:
                    wordsTo = Int(rule.value)
                case .kudosGT:
                    kudosFrom = Int(rule.value)
                case .kudosLT:
                    kudosTo = Int(rule.value)

                default:
                    passthroughRules.append(rule)
                }
            }
        }
    }

    // MARK: Mutual exclusion helpers (mirrors AO3's toggleInclude/toggleExclude)
    //
    // These switch on an explicit field enum and access each property
    // directly rather than going through a `WritableKeyPath` subscript.
    // `@Observable`'s macro-synthesized storage does not support keyPath
    // subscripting on the type at all -- not just in-place mutation
    // (`self[keyPath: kp].remove(...)`), but even a plain
    // `self[keyPath: kp] = newValue` assignment fails to typecheck
    // ("Cannot assign through subscript: 'self' is immutable"). Ordinary
    // property access (`self.includedFandoms = ...`) is unaffected, so
    // dispatching through a switch avoids the problem entirely.
    enum StringTagField {
        case fandom, relationship, character, freeform, author
    }

    func isIncluded(_ value: String, field: StringTagField) -> Bool {
        switch field {
        case .fandom:       return includedFandoms.contains(value)
        case .relationship: return includedRelationships.contains(value)
        case .character:    return includedCharacters.contains(value)
        case .freeform:     return includedFreeforms.contains(value)
        case .author:       return includedAuthors.contains(value)
        }
    }

    func isExcluded(_ value: String, field: StringTagField) -> Bool {
        switch field {
        case .fandom:       return excludedFandoms.contains(value)
        case .relationship: return excludedRelationships.contains(value)
        case .character:    return excludedCharacters.contains(value)
        case .freeform:     return excludedFreeforms.contains(value)
        case .author:       return excludedAuthors.contains(value)
        }
    }

    func toggleInclude(_ value: String, field: StringTagField) {
        switch field {
        case .fandom:
            if includedFandoms.contains(value) { includedFandoms.remove(value) } else { includedFandoms.insert(value); excludedFandoms.remove(value) }
        case .relationship:
            if includedRelationships.contains(value) {
                includedRelationships.remove(value)
            } else {
                includedRelationships.insert(value)
                excludedRelationships.remove(value)
            }
        case .character:
            if includedCharacters.contains(value) {
                includedCharacters.remove(value)
            } else {
                includedCharacters.insert(value)
                excludedCharacters.remove(value)
            }
        case .freeform:
            if includedFreeforms.contains(value) { includedFreeforms.remove(value) } else { includedFreeforms.insert(value); excludedFreeforms.remove(value) }
        case .author:
            if includedAuthors.contains(value) { includedAuthors.remove(value) } else { includedAuthors.insert(value); excludedAuthors.remove(value) }
        }
    }

    func toggleExclude(_ value: String, field: StringTagField) {
        switch field {
        case .fandom:
            if excludedFandoms.contains(value) { excludedFandoms.remove(value) } else { excludedFandoms.insert(value); includedFandoms.remove(value) }
        case .relationship:
            if excludedRelationships.contains(value) {
                excludedRelationships.remove(value)
            } else {
                excludedRelationships.insert(value)
                includedRelationships.remove(value)
            }
        case .character:
            if excludedCharacters.contains(value) {
                excludedCharacters.remove(value)
            } else {
                excludedCharacters.insert(value)
                includedCharacters.remove(value)
            }
        case .freeform:
            if excludedFreeforms.contains(value) { excludedFreeforms.remove(value) } else { excludedFreeforms.insert(value); includedFreeforms.remove(value) }
        case .author:
            if excludedAuthors.contains(value) { excludedAuthors.remove(value) } else { excludedAuthors.insert(value); includedAuthors.remove(value) }
        }
    }

    func removeTag(_ value: String, field: StringTagField) {
        switch field {
        case .fandom:
            includedFandoms.remove(value)
            excludedFandoms.remove(value)
        case .relationship:
            includedRelationships.remove(value)
            excludedRelationships.remove(value)
        case .character:
            includedCharacters.remove(value)
            excludedCharacters.remove(value)
        case .freeform:
            includedFreeforms.remove(value)
            excludedFreeforms.remove(value)
        case .author:
            includedAuthors.remove(value)
            excludedAuthors.remove(value)
        }
    }

    func tagSelectionState(_ value: String, field: StringTagField) -> FilterSelectionState {
        if isIncluded(value, field: field) { return .included }
        if isExcluded(value, field: field) { return .excluded }
        return .clear
    }

    func cycleTag(_ value: String, field: StringTagField) {
        switch tagSelectionState(value, field: field) {
        case .clear:
            toggleInclude(value, field: field)
        case .included:
            toggleExclude(value, field: field)
        case .excluded:
            removeTag(value, field: field)
        }
    }

    // MARK: - 3-State cycling for Warnings & Categories

    func selectionState(for warning: AO3Warning) -> FilterSelectionState {
        if includedWarnings.contains(warning) { return .included }
        if excludedWarnings.contains(warning) { return .excluded }
        return .clear
    }

    func cycleWarning(_ warning: AO3Warning) {
        switch selectionState(for: warning) {
        case .clear:
            includedWarnings.insert(warning)
            excludedWarnings.remove(warning)
        case .included:
            includedWarnings.remove(warning)
            excludedWarnings.insert(warning)
        case .excluded:
            includedWarnings.remove(warning)
            excludedWarnings.remove(warning)
        }
    }

    func selectionState(for category: AO3Category) -> FilterSelectionState {
        if includedCategories.contains(category) { return .included }
        if excludedCategories.contains(category) { return .excluded }
        return .clear
    }

    func cycleCategory(_ category: AO3Category) {
        switch selectionState(for: category) {
        case .clear:
            includedCategories.insert(category)
            excludedCategories.remove(category)
        case .included:
            includedCategories.remove(category)
            excludedCategories.insert(category)
        case .excluded:
            includedCategories.remove(category)
            excludedCategories.remove(category)
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
            for value in include { includeGroup.rules.append(FilterRule(field: field, op: .equals, value: value)) }
            for value in exclude { excludeGroup.rules.append(FilterRule(field: field, op: .notEquals, value: value)) }
        }

        addTagRules(include: includedFandoms, exclude: excludedFandoms)
        addTagRules(include: includedRelationships, exclude: excludedRelationships)
        addTagRules(include: includedCharacters, exclude: excludedCharacters)
        addTagRules(include: includedFreeforms, exclude: excludedFreeforms)
        addTagRules(include: includedAuthors, exclude: excludedAuthors, field: .authorName)

        for warning in includedWarnings { includeGroup.rules.append(FilterRule(field: .warning, op: .equals, value: warning.rawValue)) }
        for warning in excludedWarnings { excludeGroup.rules.append(FilterRule(field: .warning, op: .notEquals, value: warning.rawValue)) }
        for category in includedCategories { includeGroup.rules.append(FilterRule(field: .category, op: .equals, value: category.rawValue)) }
        for category in excludedCategories { excludeGroup.rules.append(FilterRule(field: .category, op: .notEquals, value: category.rawValue)) }

        if let includedRating {
            switch ratingMatch {
            case .exact:
                includeGroup.rules.append(FilterRule(field: .rating, op: .equals, value: includedRating.rawValue))
            case .orHigher:
                includeGroup.rules.append(FilterRule(field: .rating, op: .ratingAtLeast, value: includedRating.rawValue))
            case .orLower:
                includeGroup.rules.append(FilterRule(field: .rating, op: .ratingAtMost, value: includedRating.rawValue))
            }
        }
        for rating in excludedRatings {
            excludeGroup.rules.append(FilterRule(field: .rating, op: .notEquals, value: rating.rawValue))
        }

        if let wordsFrom {
            includeGroup.rules.append(FilterRule(field: .wordCountGT, op: .equals, value: "\(wordsFrom)"))
        }
        if let wordsTo {
            includeGroup.rules.append(FilterRule(field: .wordCountLT, op: .equals, value: "\(wordsTo)"))
        }
        if let kudosFrom {
            includeGroup.rules.append(FilterRule(field: .kudosGT, op: .equals, value: "\(kudosFrom)"))
        }
        if let kudosTo {
            includeGroup.rules.append(FilterRule(field: .kudosLT, op: .equals, value: "\(kudosTo)"))
        }

        switch crossoverState {
        case .any: break
        case .includeOnly: includeGroup.rules.append(FilterRule(field: .crossover, op: .equals))
        case .excludeOnly: includeGroup.rules.append(FilterRule(field: .crossover, op: .notEquals))
        }
        switch completionState {
        case .any: break
        case .includeOnly: includeGroup.rules.append(FilterRule(field: .status, op: .equals, value: AO3CompletionStatus.complete.rawValue))
        case .excludeOnly: includeGroup.rules.append(FilterRule(field: .status, op: .equals, value: AO3CompletionStatus.workInProgress.rawValue))
        }

        // Preserve unmapped rules from the drawer
        includeGroup.rules.append(contentsOf: passthroughRules)

        var expr = FilterExpression()
        expr.groups = [includeGroup, excludeGroup].filter { !$0.rules.isEmpty }
        expr.groupConjunction = .and
        return expr.groups.isEmpty ? FilterExpression() : expr
    }
}
