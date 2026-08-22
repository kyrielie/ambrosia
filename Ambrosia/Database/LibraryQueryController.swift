import Foundation

/// Paging-offset bookkeeping for one view's current scroll position through
/// a filtered result set. Owned per-view, not shared — List and Email can be
/// scrolled to different pages of the same filter at the same time (their
/// rawSQLOffset bookkeeping is stateful and diverges independently under
/// series-grouping overflow), so this struct is passed around by the owning
/// view rather than stored inside LibraryQueryController itself.
struct PagingOffsetState {
    var currentPage: Int = 0

    /// The raw SQL offset that page `i`'s own drain loop started from, for
    /// every page ever visited this filter session, indexed by page number
    /// (0-based, always contiguous — Next/Previous only move one page at a
    /// time, so no index is ever skipped). Append-only: entries are never
    /// removed. Revisiting a page (Previous, or Next back to a page seen
    /// earlier after going back) re-drains from `rawSQLOffsetByPage[page]`
    /// and is fully deterministic given an unchanged filter/sort/
    /// visibilityVersion, so there is nothing to pop or restore — just
    /// look the value up.
    ///
    /// # Incident notes
    /// This replaced an earlier stack-based design
    /// (`rawSQLOffsetHistory: [Int]`, pushed on every forward load, popped
    /// by "Previous") that had two compounding bugs:
    ///
    /// 1. The push happened unconditionally on every `loadPage()` call
    ///    through the grouped drain branch, including calls triggered by
    ///    Previous itself and by unrelated reloads (filter reapply,
    ///    membershipVersion bumps from background AO3 extraction). Each
    ///    such call re-pushed the (already-stale) current offset, silently
    ///    duplicating entries and desyncing the stack's depth from
    ///    `currentPage`. A first fix attempted to gate the push by an
    ///    explicit `NavigationIntent` (forward/backward/reload) threaded
    ///    through ~20 call sites.
    ///
    /// 2. Even with that gating in place, the stack model was wrong on its
    ///    own terms: loading page N pushed *page N's own starting offset*,
    ///    but by the time page N+1 loaded, its push captured *page N's
    ///    post-drain (ending) offset* — the value page N left behind, not
    ///    a value belonging to N+1. Popping "the last entry" when going
    ///    Previous from N+1 therefore returned page N's *end* offset, not
    ///    its *start* offset — redraining from it just replayed page N+1's
    ///    own content again, one page short of where the user actually
    ///    was. This produced exactly the observed crash: after 7 clean
    ///    forward pages, one Previous click desynced
    ///    `rawSQLOffsetHistory.count` from `currentPage` and tripped the
    ///    debug assertion that had been added to catch this class of bug.
    ///
    /// The per-page array below sidesteps both problems: there is no
    /// "direction" to get wrong, because every page's start offset is
    /// looked up by its own index rather than inferred from stack depth.
    var rawSQLOffsetByPage: [Int] = []

    /// Same indexing as `rawSQLOffsetByPage`: the overflow rows (from the
    /// previous page's drain overshooting pageSize) that must seed page
    /// `i`'s `visible` array before its own drain runs. Needed because the
    /// group-aware drain loop couples adjacent pages together — page N+1's
    /// displayed rows are `[overflow left over from page N] + [freshly
    /// drained rows]` — so redraining page N+1 in isolation on a revisit
    /// requires knowing what N's overflow was, not just N+1's own SQL
    /// offset.
    var seedOverflowByPage: [[CalibreBook]] = []

    /// The furthest raw SQL offset drained so far this filter session.
    /// Only advances when a genuinely new (never-before-visited) page is
    /// loaded; revisiting an already-recorded page never touches this.
    var rawSQLOffsetFrontier: Int = 0

    /// The overflow rows produced by the most recently *newly drained*
    /// page, waiting to seed the next never-before-seen page. Only
    /// mutated alongside `rawSQLOffsetFrontier`, for the same reason.
    var rawSQLOffsetOverflowFrontier: [CalibreBook] = []

    mutating func resetForNewFilter() {
        currentPage = 0
        rawSQLOffsetByPage = []
        seedOverflowByPage = []
        rawSQLOffsetFrontier = 0
        rawSQLOffsetOverflowFrontier = []
    }
}

/// Filtering logic shared by `LibraryRootView` and `EmailLibraryViewController`.
///
/// §Phase2 (partial): this extracts the lowest-risk, genuinely pure pieces of
/// the ~17 near-identical methods duplicated across the two views —
/// `currentVisibilityPolicy` construction, `visibleIDs`, `visibleBooks`, and
/// `intersect`. Both views now call through this one implementation instead
/// of keeping their own copies.
///
/// `applyFilterRules()` and `loadPage()` are NOT moved here in this pass —
/// they are the two largest, most state-coupled methods (SwiftUI `@State`
/// paging offsets on the List side, `NSViewController` instance state on the
/// Email side), and mechanically relocating ~300+ line functions with that
/// much surrounding paging/offset bookkeeping in one sitting is exactly the
/// kind of single large change the source plan (ambrosia_caching_plan.md /
/// the Finding 2 discussion) warns against attempting all at once. Both
/// views' `loadPage()` already call into the cached `CalibreLibrary` methods
/// with `visibilityVersion:` wired in (§Phase3), which is what actually
/// fixes the "switching views re-fetches everything" problem; moving the
/// surrounding orchestration into this controller is a follow-up refactor,
/// not a prerequisite for that fix.
///
/// One instance is owned per view (`LibraryRootView` holds one,
/// `EmailLibraryViewController` holds one). This type intentionally holds no
/// paging-offset state itself — List and Email can be scrolled to different
/// pages of the same filtered result at the same time, so offset state stays
/// owned by each view and is passed in as needed by whatever still calls into
/// `CalibreLibrary` directly.
///
/// Deliberately NOT `@MainActor`: it holds no mutable state and calls no
/// actor-isolated APIs (`LibraryVisibilityPolicy` is a plain value type), so
/// leaving it unisolated avoids actor-isolation friction where it's stored as
/// a plain `let` property on `LibraryRootView` (a SwiftUI `View` struct).
final class LibraryQueryController {

    /// "list" or "email" — used only for `LibraryFilterDebug` log labels, so
    /// existing manual-repro log-reading workflows keep working unchanged.
    let surfaceLabel: String

    init(surfaceLabel: String) {
        self.surfaceLabel = surfaceLabel
    }

    /// Builds the visibility policy from the current toggle state and the
    /// four ID sets that drive it. Callers pass their own (session-mirrored,
    /// see LibrarySession.refreshCollectionSnapshots) `@State`/instance
    /// copies of `skippedIDs`/`seriesOrMergedIDs`/`ao3PublisherIDs`/
    /// `anthologyIDs` — this method does not read `LibrarySession` directly,
    /// so it stays usable from a plain view-model context without needing a
    /// `LibrarySession` reference.
    func visibilityPolicy(
        showSkippedCollection: Bool,
        shouldGroupSeriesRows: Bool,
        hideNonAO3PublisherBooks: Bool,
        hideAnthologyBooks: Bool,
        hideDuplicateBooks: Bool,
        skippedIDs: Set<Int>,
        seriesOrMergedIDs: Set<Int>,
        ao3PublisherIDs: Set<Int>,
        anthologyIDs: Set<Int>,
        duplicateLoserIDs: Set<Int>
    ) -> LibraryVisibilityPolicy {
        LibraryVisibilityPolicy(
            showSkippedCollection: showSkippedCollection,
            shouldGroupSeriesRows: shouldGroupSeriesRows,
            hideNonAO3PublisherBooks: hideNonAO3PublisherBooks,
            hideAnthologyBooks: hideAnthologyBooks,
            hideDuplicateBooks: hideDuplicateBooks,
            skippedIDs: skippedIDs,
            seriesOrMergedIDs: seriesOrMergedIDs,
            ao3PublisherIDs: ao3PublisherIDs,
            anthologyIDs: anthologyIDs,
            duplicateLoserIDs: duplicateLoserIDs
        )
    }

    func visibleIDs(_ ids: [Int], policy: LibraryVisibilityPolicy) -> [Int] {
        policy.filter(ids)
    }

    func intersect(_ ids: [Int], with optionalIDs: [Int]?) -> [Int] {
        LibraryQueryHelpers.intersect(ids, with: optionalIDs)
    }

    /// Filters raw (unfiltered-by-visibility) hydrated books down to what
    /// should actually be shown. Ports the `#if DEBUG` breakdown diagnostic
    /// that previously existed only in `LibraryRootView`'s copy of this
    /// method (`EmailLibraryViewController`'s copy was missing it) so both
    /// surfaces get the same debug visibility going forward.
    func visibleBooks(_ raw: [CalibreBook], policy: LibraryVisibilityPolicy) -> [CalibreBook] {
        #if DEBUG
        if policy.shouldGroupSeriesRows && !raw.isEmpty {
            let strippedBySkipped = raw.filter { !policy.showSkippedCollection && policy.skippedIDs.contains($0.id) }.count
            let strippedBySeriesOrMerged = raw.filter { policy.seriesOrMergedIDs.contains($0.id) }.count
            let strippedByPublisher = raw.filter { policy.hideNonAO3PublisherBooks && !$0.isAO3PublisherBook }.count
            let strippedByAnthology = raw.filter { policy.hideAnthologyBooks && $0.isDescriptionAnthology }.count
            let strippedByDuplicate = raw.filter { policy.hideDuplicateBooks && policy.duplicateLoserIDs.contains($0.id) }.count
            LibraryFilterDebug.log("visibleBooks.breakdown", [
                "surface": surfaceLabel,
                "raw": raw.count,
                "seriesOrMergedIDsSize": policy.seriesOrMergedIDs.count,
                "strippedBySkipped": strippedBySkipped,
                "strippedBySeriesOrMerged": strippedBySeriesOrMerged,
                "strippedByPublisher": strippedByPublisher,
                "strippedByAnthology": strippedByAnthology,
                "strippedByDuplicate": strippedByDuplicate,
                "sampleStrippedIDs": raw.filter { policy.seriesOrMergedIDs.contains($0.id) }.prefix(5).map(\.id).map(String.init).joined(separator: ",")
            ])
        }
        #endif
        return policy.filter(raw)
    }
}
