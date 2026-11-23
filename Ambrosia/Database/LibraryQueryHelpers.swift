import Foundation

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

    // NOTE: `visibleIDs`/`visibleBooks` used to live here as free functions
    // taking 6-8 parameters each. Both call sites (LibraryRootView,
    // EmailLibraryViewController) now build a `LibraryVisibilityPolicy` once
    // (`currentVisibilityPolicy`) and call `.filter(_:)` directly — see
    // LibraryVisibilityPolicy.swift. Retired rather than left as unused dead code.

    // MARK: - Full-text cache keys

    // The cache key for a `fulltext:` phrase is `FTSQuery.make(phrase)?.cacheKey`:
    // trimmed and NFKC-normalized, deliberately NOT case- or diacritic-folded.

    /// Builds the `fulltextMap` handed to `FilterBuilder` from the values of every
    /// full-text rule. Rules whose values normalize to the same key collapse to one
    /// entry (first wins) instead of trapping, which `Dictionary(uniqueKeysWithValues:)`
    /// did. A phrase with no cached result maps to an empty set, as before.
    static func fulltextMap(values: [String], lookup: (String) -> [Int]?) -> [String: Set<Int>] {
        var map: [String: Set<Int>] = [:]
        for value in values {
            guard let key = FTSQuery.make(value)?.cacheKey, map[key] == nil else { continue }
            map[key] = Set(lookup(value) ?? [])
        }
        return map
    }

    /// Builds a dictionary from `pairs`, keeping the first value for a repeated key
    /// instead of trapping like `Dictionary(uniqueKeysWithValues:)`. Use for any
    /// map built from database rows.
    static func indexed<K: Hashable, V>(_ pairs: [(K, V)]) -> [K: V] {
        Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    /// Escapes SQL LIKE wildcards (% and _) using a backslash.
    static func escapeLikePattern(_ pattern: String) -> String {
        pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

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
        let ids: [Int]
        switch session.fulltextState(for: phrase) {
        case .unknown: return query
        case .resolved(let resolved): ids = resolved
        case .failed: ids = []
        }
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

    static func hasCompleteRule(field: FilterField, value: String, in expression: FilterExpression) -> Bool {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return expression.groups
            .flatMap(\.rules)
            .contains {
                $0.isComplete
                    && $0.field == field
                    && $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        .localizedCaseInsensitiveCompare(normalizedValue) == .orderedSame
            }
    }

    /// Removes the rule with `id` from `expression`. Prunes empty groups only when
    /// more than one group exists, always leaving at least one group.
    /// Returns true if the expression was modified.
    @discardableResult
    static func removeRule(id: UUID, in expression: inout FilterExpression) -> Bool {
        var didRemove = false
        for groupIndex in expression.groups.indices {
            if let ruleIndex = expression.groups[groupIndex].rules.firstIndex(where: { $0.id == id }) {
                expression.groups[groupIndex].rules.remove(at: ruleIndex)
                didRemove = true
                break
            }
        }
        guard didRemove else { return false }
        if expression.groups.count > 1 {
            expression.groups.removeAll { $0.rules.isEmpty }
            if expression.groups.isEmpty {
                expression.groups = [FilterGroup()]
            }
        }
        return true
    }

    /// Inverts the operator of the rule with `id` to its negation counterpart if supported.
    /// Returns true if the operator was toggled.
    @discardableResult
    static func toggleNegation(id: UUID, in expression: inout FilterExpression) -> Bool {
        for groupIndex in expression.groups.indices {
            if let ruleIndex = expression.groups[groupIndex].rules.firstIndex(where: { $0.id == id }) {
                let rule = expression.groups[groupIndex].rules[ruleIndex]
                guard rule.canToggleNegation, let counterpart = rule.op.negatedCounterpart else {
                    return false
                }
                expression.groups[groupIndex].rules[ruleIndex].op = counterpart
                return true
            }
        }
        return false
    }

    /// Converts a `.tag` rule with `.equals` or `.notEquals` into a listed position field
    /// (`.firstRelationship` or `.firstCharacter`). Preserves `op` and `value`, resets `limit` and `matchVariants` to nil.
    @discardableResult
    static func convertTagRule(id: UUID, to targetField: FilterField, in expression: inout FilterExpression) -> Bool {
        guard targetField == .firstRelationship || targetField == .firstCharacter else { return false }
        for groupIndex in expression.groups.indices {
            if let ruleIndex = expression.groups[groupIndex].rules.firstIndex(where: { $0.id == id }) {
                let rule = expression.groups[groupIndex].rules[ruleIndex]
                guard rule.field == .tag, rule.op == .equals || rule.op == .notEquals else { return false }
                expression.groups[groupIndex].rules[ruleIndex].field = targetField
                expression.groups[groupIndex].rules[ruleIndex].limit = nil
                expression.groups[groupIndex].rules[ruleIndex].matchVariants = nil
                return true
            }
        }
        return false
    }

    /// Converts a listed position rule back to a `.tag` rule with the same `op` and `value`.
    /// Resets `limit` and `matchVariants` to nil.
    @discardableResult
    static func convertPositionRuleToTag(id: UUID, in expression: inout FilterExpression) -> Bool {
        for groupIndex in expression.groups.indices {
            if let ruleIndex = expression.groups[groupIndex].rules.firstIndex(where: { $0.id == id }) {
                let rule = expression.groups[groupIndex].rules[ruleIndex]
                guard rule.field == .firstRelationship || rule.field == .firstCharacter else { return false }
                expression.groups[groupIndex].rules[ruleIndex].field = .tag
                expression.groups[groupIndex].rules[ruleIndex].limit = nil
                expression.groups[groupIndex].rules[ruleIndex].matchVariants = nil
                return true
            }
        }
        return false
    }

    /// Updates the `matchVariants` toggle for a listed rule.
    @discardableResult
    static func setRuleVariants(id: UUID, enabled: Bool, in expression: inout FilterExpression) -> Bool {
        for groupIndex in expression.groups.indices {
            if let ruleIndex = expression.groups[groupIndex].rules.firstIndex(where: { $0.id == id }) {
                let rule = expression.groups[groupIndex].rules[ruleIndex]
                guard rule.field == .firstRelationship || rule.field == .firstCharacter || rule.field == .relationshipCount else {
                    return false
                }
                expression.groups[groupIndex].rules[ruleIndex].matchVariants = enabled
                return true
            }
        }
        return false
    }
}
