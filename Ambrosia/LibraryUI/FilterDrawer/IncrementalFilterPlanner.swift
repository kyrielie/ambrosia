import Foundation

/// Decides when a new filter expression can be answered by narrowing an
/// already-evaluated one (plan PR I). Pure value logic, no session or database.
///
/// `result(E') == result(E) ∩ matches(r)` holds when `E'` is `E` plus one
/// complete rule `r`, `r` sits in an AND group, and the groups combine with
/// AND (or there is a single complete group). Every evaluation phase is a
/// filter on a set, so rules inside an AND group commute. Removing a chip,
/// replacing a rule, editing a value in place, and anything involving an OR
/// are not narrowing and are never produced here.
enum IncrementalFilterPlanner {

    /// One way to read `expression` as `base` plus a single added rule.
    struct Split: Equatable {
        /// The expression with `delta` removed. Looked up in the filter cache.
        let base: FilterExpression
        /// The rule that was added on top of `base`.
        let delta: FilterRule
    }

    /// Every eligible (base, delta) pair of `expression`.
    ///
    /// A split is eligible when all of these hold:
    /// - `delta` is a complete rule in a group whose conjunction is `.and`;
    /// - the top level is a single complete group or `groupConjunction == .and`;
    /// - after removing `delta`, the same group still has at least one complete
    ///   rule. This keeps the base's group layout identical to the cached
    ///   expression, whose cache key encodes group indices, and it also rules
    ///   out an empty base (the whole library, never cached).
    ///
    /// Incomplete rules are ignored: the cache key only encodes complete rules.
    static func splits(of expression: FilterExpression) -> [Split] {
        let completeGroupCount = expression.groups.filter(\.isComplete).count
        guard completeGroupCount > 0 else { return [] }
        guard completeGroupCount == 1 || expression.groupConjunction == .and else { return [] }

        var result: [Split] = []
        for (groupIndex, group) in expression.groups.enumerated() {
            guard group.conjunction == .and else { continue }
            let complete = group.completeRules
            // The group must keep at least one complete rule once one is removed.
            guard complete.count >= 2 else { continue }
            for rule in complete {
                var base = expression
                base.groups[groupIndex].rules.removeAll { $0.id == rule.id }
                result.append(Split(base: base, delta: rule))
            }
        }
        return result
    }

    /// A one-group AND expression holding only `delta`. Evaluated with the
    /// base's IDs as candidates to produce the narrowing set.
    static func deltaExpression(for delta: FilterRule) -> FilterExpression {
        var expression = FilterExpression()
        expression.groups = [FilterGroup(rules: [delta], conjunction: .and)]
        expression.groupConjunction = .and
        return expression
    }
}
