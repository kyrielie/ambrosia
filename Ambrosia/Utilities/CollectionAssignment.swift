import Foundation

/// Coordinates the single post-change step every "Add to Collection…" call site
/// must perform consistently after a successful assignment via
/// `CollectionSearchPickerView`: bumping the filter-result LRU cache's
/// membership version, plus whatever surface-local refresh the call site
/// also needs (e.g. `refreshVisibilitySnapshots`, `refreshBookStates`).
///
/// `SeriesListRow`'s call site previously only ran its local refresh and
/// never bumped the membership version, so a collection-scoped filter view
/// could show stale membership after adding a whole series to a collection.
/// Routing every call site through this helper removes the possibility of a
/// fourth site drifting the same way.
@MainActor
enum CollectionAssignment {
    static func didAssign(session: LibrarySession, onRefresh: () -> Void) {
        session.bumpMembershipVersion()
        onRefresh()
    }
}
