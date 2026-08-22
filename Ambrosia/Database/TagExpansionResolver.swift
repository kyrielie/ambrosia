import Foundation

/// Shared tag-synonym expansion helpers used by both `LibraryRootView` and
/// `EmailLibraryViewController`. Both views previously carried their own
/// copies of these two call-site blocks (Phase 2 already removed one instance
/// of this duplication; this is a smaller recurrence in the filter/search
/// pipeline — see Invariant 17 in `docs/concurrency-invariants.md` and the gap-closure
/// plan Phase 3).
enum TagExpansionResolver {
    /// Resolves synonym expansions for every complete `.tag` rule value in
    /// `expression`, via a single batched `AmbrosiaMetaDB` call rather than one
    /// call per distinct tag value.
    static func filterTagExpansions(
        for expression: FilterExpression,
        metaDB: AmbrosiaMetaDB?
    ) async -> [String: [String]] {
        guard let metaDB else { return [:] }
        let tagValues = Set(expression.groups.flatMap(\.rules)
                                .filter { $0.field == .tag && $0.isComplete }
                                .map(\.value))
        guard !tagValues.isEmpty else { return [:] }
        return await metaDB.expandedTermsBatch(for: Array(tagValues))
    }

    /// Resolves synonym expansions for `terms` via a single batched
    /// `AmbrosiaMetaDB` call. Used by search-field tag term resolution.
    static func resolvedTagExpansions(
        for terms: [String],
        metaDB: AmbrosiaMetaDB?
    ) async -> [String: [String]] {
        guard let metaDB, !terms.isEmpty else { return [:] }
        return await metaDB.expandedTermsBatch(for: terms)
    }
}
