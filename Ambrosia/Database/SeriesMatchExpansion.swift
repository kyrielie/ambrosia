import Foundation

/// Series-grouping Phase 1: expands a raw matched-ID set (from
/// `CalibreLibrary.fetchAllMatchingIDs`) to include every member of any
/// series it touches, so a query hit on a non-leading member still pulls in
/// the series leader before `LibraryVisibilityPolicy` filtering runs.
///
/// Mirrors `TagExpansionResolver`'s shape deliberately: a stateless enum that
/// composes two actors (`CalibreLibrary`, `AmbrosiaMetaDB`) from outside
/// either's isolation domain, so it's usable from `LibraryQueryController`,
/// a SwiftUI view's Task, or an AppKit view controller's Task without extra
/// MainActor hops.
///
/// Grouping-off path is unaffected: when `shouldGroupSeriesRows` is false,
/// this is a no-op passthrough, matching the plan's "grouping off = fall
/// back to real per-book behavior everywhere."
///
/// Phase 2 (rating hierarchy): expansion alone can pull a higher-rated
/// series member into a rating-filtered result with no rating check at all.
/// When the active `filter` unambiguously implies a rating constraint (see
/// `ratingConstraint(in:)`), `expand` now drops every ID belonging to a
/// series that violates it — the whole series, including IDs present in the
/// original `matchedIDs`, not just the newly-pulled-in ones, since a series
/// card that contains a disqualifying member must not surface at all.
enum SeriesMatchExpansion {
    /// A single-rating-rule constraint extracted from a `FilterExpression`,
    /// used to decide whether an expanded series group should be dropped
    /// entirely. Two distinct shapes, matching the two rating-shaped
    /// `FilterOperator`s that can appear on a `.rating` `FilterRule`:
    enum SeriesRatingConstraint {
        /// From `.ratingAtMost` — a series may contain this rating or
        /// anything lower on the hierarchy (`AO3Rating.level`); only a
        /// member rated *above* `level` disqualifies the group.
        case ceiling(level: Int)
        /// From `.rating .equals` — every rated member of the series must
        /// be exactly this rating; any member rated either higher or lower
        /// disqualifies the group. (E.g. an "equals Teen And Up" search
        /// must exclude a series with a General Audiences companion work,
        /// just as much as an Explicit one.)
        case exact(level: Int)
    }

    /// - Parameters:
    ///   - matchedIDs: raw result of `fetchAllMatchingIDs` (or equivalent),
    ///     before visibility filtering.
    ///   - shouldGroupSeriesRows: current toggle state; expansion is skipped
    ///     entirely when false.
    ///   - filter: the active `FilterExpression`, used to extract a rating
    ///     constraint (see `ratingConstraint(in:)`). Passing `nil` disables
    ///     the rating-hierarchy gate for this call, same as today.
    ///   - library: source of `bulkRatingTags(ids:)`. Passing `nil` disables
    ///     the rating-hierarchy gate for this call, same as today.
    ///   - metaDB: owns `series_cache`; expansion is skipped if unavailable.
    /// - Returns: `matchedIDs` unioned with every qualifying series member,
    ///   minus any series disqualified by the rating constraint (if any),
    ///   as an array (order is not meaningful — callers sort/paginate after).
    static func expand(
        matchedIDs: [Int],
        shouldGroupSeriesRows: Bool,
        filter: FilterExpression?,
        library: CalibreLibrary?,
        metaDB: AmbrosiaMetaDB?
    ) async -> [Int] {
        guard shouldGroupSeriesRows, let metaDB, !matchedIDs.isEmpty else {
            return matchedIDs
        }
        guard let expanded = try? await metaDB.expandedSeriesMemberIDs(for: matchedIDs) else {
            return matchedIDs
        }
        guard let constraint = ratingConstraint(in: filter), let library else {
            return Array(expanded)
        }
        // Determine which series (by key) among the expanded set violate the
        // constraint, and drop every member of those series entirely —
        // including ones present in the original `matchedIDs`, not just the
        // newly-pulled-in ones, since the whole group must not surface.
        guard let entries = try? await metaDB.seriesEntries(for: Array(expanded)), !entries.isEmpty else {
            return Array(expanded)
        }
        let idsByKey = Dictionary(grouping: entries, by: \.seriesKey).mapValues { $0.map(\.calibreID) }
        let ratingTagsByID = await library.bulkRatingTags(ids: Array(expanded))
        var disqualifiedIDs = Set<Int>()
        for (_, memberIDs) in idsByKey {
            // "Not Rated" (level == nil) is dropped by compactMap and never
            // disqualifies a group on its own, in either mode — matching
            // ao3TagFragment's own .ratingAtMost semantics ("Books with Not
            // Rated ARE included", FilterOperator.ratingAtMost doc comment).
            let levels = memberIDs
                .flatMap { ratingTagsByID[$0] ?? [] }
                .compactMap { AO3Rating(rawValue: $0)?.level }
            let violates: Bool
            switch constraint {
            case .ceiling(let ceilingLevel):
                violates = levels.contains { $0 > ceilingLevel }
            case .exact(let targetLevel):
                violates = levels.contains { $0 != targetLevel }
            }
            if violates {
                disqualifiedIDs.formUnion(memberIDs)
            }
        }
        return Array(expanded.subtracting(disqualifiedIDs))
    }

    /// Extracts a rating constraint from `filter`, but only when the
    /// expression makes it unambiguous: exactly one `.rating` rule across
    /// the whole expression (any group, any conjunction), with `op` in
    /// {`.ratingAtMost`, `.equals`}.
    ///
    /// Anything more complex (more than one `.rating` rule, `.notEquals`,
    /// `.ratingAtLeast`, or a `.rating` rule mixed into a group in a way
    /// that doesn't dominate the match) returns nil, and the pre-fix
    /// behavior is preserved for that query rather than risk hiding a
    /// legitimate result.
    static func ratingConstraint(in filter: FilterExpression?) -> SeriesRatingConstraint? {
        guard let filter else { return nil }
        let ratingRules = filter.groups.flatMap(\.rules).filter { $0.field == .rating }
        guard ratingRules.count == 1, let rule = ratingRules.first else { return nil }
        guard let level = AO3Rating(rawValue: rule.value)?.level else { return nil }
        switch rule.op {
        case .ratingAtMost: return .ceiling(level: level)
        case .equals:       return .exact(level: level)
        default:            return nil
        }
    }
}
