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
    var groupBySeries: Bool {
        didSet { UserDefaults.standard.set(groupBySeries, forKey: "groupBySeries") }
    }

    var showFilterDrawer:   Bool = false
    var showCollections:    Bool = false
    var showReadingGoal:    Bool = false
    var triggerExport:      Bool = false
    var triggerEPUBExport:  Bool = false
    var reshuffleToken:     Bool = false
    var toggleEmailSidebar: Bool = false
    var toggleEmailReaderSidebar: Bool = false
    var showEmailReaderSidebar: Bool = false
    var isEmailReaderSidebarVisible: Bool = false
    var emailReaderSidebarMode: EmailReaderSidebarMode = .annotations

    // MARK: - Filter state

    var filterExpression:   FilterExpression = FilterExpression()
    var activeFilterResult: FilterResult?    = nil
    var pendingFullTextSearch: PendingFullTextSearch? = nil
    var isApplyingLibraryFilter: Bool = false
    var libraryFilterApplicationToken: UUID? = nil
    private var shouldSuppressNextSearchTextReload = false

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

    /// Set by LibraryViewController immediately before the List surface's
    /// NSHostingView is removed from the hierarchy. LibraryRootView's async
    /// reload paths must check this and no-op if true, since unstructured
    /// Task { } blocks triggered by .onChange are not auto-cancelled when a
    /// SwiftUI view is removed from an NSHostingView.
    var isListSurfaceTornDown: Bool = false

    init() {
        groupBySeries = UserDefaults.standard.bool(forKey: "groupBySeries")
    }

    func registerFilterCommitHandler(_ handler: @escaping (FilterRule) -> Void) {
        filterCommitHandler = handler
    }

    // MARK: - Convenience

    var hasActiveFilter: Bool { activeFilterResult != nil || pendingFullTextSearch != nil }

    /// True while a SQL-pageable filter's row set is already applied but its
    /// total count hasn't come back from `scheduleDeferredSQLFilterCount` yet.
    /// `applyFilterRules()` clears `isApplyingLibraryFilter` as soon as the
    /// filtered rows are pageable (so the list itself isn't stuck "loading"),
    /// but the *count* used in the toolbar label and filter chip is still
    /// pending — without this, those labels briefly fall back to their
    /// "Filtered fics" / "Filtered results" placeholder text as if nothing
    /// were happening, instead of showing a spinner until the real count
    /// arrives.
    var isFilterCountPending: Bool {
        guard let result = activeFilterResult else { return false }
        return result.isSQLBacked && result.totalCount == nil
    }

    @discardableResult
    func beginLibraryFilterApplication() -> UUID {
        let token = UUID()
        libraryFilterApplicationToken = token
        isApplyingLibraryFilter = true
        return token
    }

    func finishLibraryFilterApplication(token: UUID) {
        guard libraryFilterApplicationToken == token else { return }
        libraryFilterApplicationToken = nil
        isApplyingLibraryFilter = false
    }

    func cancelLibraryFilterApplication() {
        libraryFilterApplicationToken = nil
        isApplyingLibraryFilter = false
        pendingFullTextSearch = nil
    }

    func clearPendingFullTextSearch() {
        pendingFullTextSearch = nil
    }

    func suppressNextSearchTextReload() {
        shouldSuppressNextSearchTextReload = true
    }

    func consumeSearchTextReloadSuppression() -> Bool {
        guard shouldSuppressNextSearchTextReload else { return false }
        shouldSuppressNextSearchTextReload = false
        return true
    }

    func syncFullTextFieldFromSearchText() {}
    func applyFullTextFieldToSearchText() {}
}
