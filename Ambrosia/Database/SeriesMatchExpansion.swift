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
enum SeriesMatchExpansion {
    /// - Parameters:
    ///   - matchedIDs: raw result of `fetchAllMatchingIDs` (or equivalent),
    ///     before visibility filtering.
    ///   - shouldGroupSeriesRows: current toggle state; expansion is skipped
    ///     entirely when false.
    ///   - metaDB: owns `series_cache`; expansion is skipped if unavailable.
    /// - Returns: `matchedIDs` unioned with every qualifying series member,
    ///   as an array (order is not meaningful — callers sort/paginate after).
    static func expand(
        matchedIDs: [Int],
        shouldGroupSeriesRows: Bool,
        metaDB: AmbrosiaMetaDB?
    ) async -> [Int] {
        guard shouldGroupSeriesRows, let metaDB, !matchedIDs.isEmpty else {
            return matchedIDs
        }
        guard let expanded = try? await metaDB.expandedSeriesMemberIDs(for: matchedIDs) else {
            return matchedIDs
        }
        return Array(expanded)
    }
}
