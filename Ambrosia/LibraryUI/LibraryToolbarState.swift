import AppKit
import Observation

// MARK: - View mode

enum LibraryViewMode: Int {
    case list    = 0
    case email   = 1
    case ranking = 2
}

// MARK: - LibraryToolbarState

@Observable
final class LibraryToolbarState {

    // MARK: - Toolbar-driven fields

    var searchText:   String          = ""
    var sortField:    SortField       = .title
    var ascending:    Bool            = true
    var viewMode:     LibraryViewMode = .list

    var showFilterDrawer:   Bool = false
    var showCollections:    Bool = false
    var showReadingGoal:    Bool = false
    var triggerExport:      Bool = false
    var toggleEmailSidebar: Bool = false

    // MARK: - Filter state

    var filterExpression:   FilterExpression = FilterExpression()
    var activeFilterResult: FilterResult?    = nil

    // MARK: - Search → filter commit
    //
    // When the user commits a scoped search token (e.g. tag:horror, author:rowling)
    // via Return or suggestion tap, LibraryWindowController calls
    // commitSearchTokenAsFilter(_:). The active content view (BookGridItem or
    // EmailLibraryViewController) registers the handler via registerFilterCommitHandler.
    //
    // This avoids any direct reference between the AppKit toolbar layer and the
    // SwiftUI/AppKit content layer.

    /// Registered by the active content view. Called on the main thread.
    var filterCommitHandler: ((FilterRule) -> Void)?

    func registerFilterCommitHandler(_ handler: @escaping (FilterRule) -> Void) {
        filterCommitHandler = handler
    }

    // MARK: - Convenience

    var hasActiveFilter: Bool { activeFilterResult != nil }
}

