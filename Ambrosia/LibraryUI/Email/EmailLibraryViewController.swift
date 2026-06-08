import AppKit
import SwiftUI
import SwiftData

// MARK: - EmailLibraryViewController
//
// Email-style split view: hideable left sidebar + right inline reader pane.
//
// Filters/sorts applied in the list view are inherited here because the same
// LibraryToolbarState is shared across all view modes.  Single-click on a
// sidebar row loads the book into the inline ReaderViewController on the
// right.  Double-click opens a dedicated reader window (the normal flow).
//
// Sidebar visibility is toggled by a small button that floats just inside the
// leading edge of the content area.  Collapsing uses NSSplitViewItem.isCollapsed
// so the split view remembers the open width on restore.
//
// When toolbarState.showFilterDrawer becomes true this VC presents the
// FilterDrawerView as an NSWindow sheet so the filter UI is available in
// email mode the same as in list mode.

final class EmailLibraryViewController: NSViewController {

    // MARK: - Dependencies

    private let modelContainer: ModelContainer
    private let session:        LibrarySession
    private let toolbarState:   LibraryToolbarState

    // MARK: - Child VCs

    private var splitVC:   NSSplitViewController!
    private var sidebarVC: EmailSidebarViewController!

    // MARK: - Sidebar toggle

    private var sidebarToggleButton: NSButton!
    private var isSidebarHidden = false

    // MARK: - Filter sheet

    private var filterSheetWindowController: NSWindowController?

    // MARK: - Pagination state

    private var books:      [CalibreBook]    = []
    private var bookStates: [Int: BookState] = [:]
    private var currentPage = 0
    private var hasNextPage = false
    private let pageSize    = 100

    // MARK: - Toolbar observation snapshots

    private var lastSearch:     String    = ""
    private var lastSort:       SortField = .title
    private var lastAscending:  Bool      = true
    private var lastFilterIDs:  [Int]?    = nil
    private var lastShowFilter: Bool      = false

    private let debouncer = DebounceTimer(delay: 0.3)

    // Currently selected book — setting it triggers updateReaderPane()
    private var selectedBook: CalibreBook? { didSet { updateReaderPane() } }

    // MARK: - Init

    init(modelContainer: ModelContainer,
         session:        LibrarySession,
         toolbarState:   LibraryToolbarState) {
        self.modelContainer = modelContainer
        self.session        = session
        self.toolbarState   = toolbarState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildSplitView()
        addSidebarToggleButton()
        refreshBookStates()
        loadPage(reset: true)
        startObservingToolbarState()
    }

    // MARK: - Split-view setup

    private func buildSplitView() {
        sidebarVC = EmailSidebarViewController()
        sidebarVC.onSelect   = { [weak self] book in self?.selectedBook = book }
        sidebarVC.onOpen     = { [weak self] book in
            guard let self else { return }
            let ctx = ModelContext(modelContainer)
            AppDelegate.shared?.openReaderWindow(book: book, modelContext: ctx)
        }
        sidebarVC.onLoadMore = { [weak self] in self?.loadNextPageIfAvailable() }

        let placeholder = makePlaceholderVC()

        splitVC = NSSplitViewController()
        splitVC.splitView.isVertical   = true
        splitVC.splitView.autosaveName = "AmbrosiaEmailSplitView"

        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness          = 200
        sidebarItem.maximumThickness          = 380
        sidebarItem.preferredThicknessFraction = 0.26
        sidebarItem.canCollapse               = true

        let readerItem = NSSplitViewItem(viewController: placeholder)
        readerItem.minimumThickness = 420

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(readerItem)

        addChild(splitVC)
        splitVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitVC.view)
        NSLayoutConstraint.activate([
            splitVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            splitVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Placeholder

    private func makePlaceholderVC() -> NSViewController {
        let v = NSHostingController(rootView:
            VStack(spacing: 14) {
                Image(systemName: "book.closed")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("Select a book to read")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("Use the list view to filter by tag, then switch here to read.")
                    .font(.callout)
                    .foregroundStyle(.quaternary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        return v
    }

    // MARK: - Sidebar toggle button

    private func addSidebarToggleButton() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let img = NSImage(systemSymbolName: "sidebar.left",
                          accessibilityDescription: "Toggle sidebar")?
            .withSymbolConfiguration(cfg)

        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        btn.bezelStyle      = .regularSquare
        btn.isBordered      = false
        btn.image           = img
        btn.imageScaling    = .scaleProportionallyDown
        btn.target          = self
        btn.action          = #selector(toggleSidebar)
        btn.toolTip         = "Hide sidebar"
        btn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(btn)

        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            btn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            btn.widthAnchor.constraint(equalToConstant: 28),
            btn.heightAnchor.constraint(equalToConstant: 24),
        ])

        sidebarToggleButton = btn
    }

    @objc private func toggleSidebar() {
        isSidebarHidden.toggle()
        guard let sidebarItem = splitVC.splitViewItems.first else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            sidebarItem.animator().isCollapsed = isSidebarHidden
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let imgName = isSidebarHidden ? "sidebar.right" : "sidebar.left"
        sidebarToggleButton.image = NSImage(systemSymbolName: imgName,
                                             accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        sidebarToggleButton.toolTip = isSidebarHidden ? "Show sidebar" : "Hide sidebar"
    }

    // MARK: - Toolbar state observation

    private func startObservingToolbarState() { scheduleObservation() }

    private func scheduleObservation() {
        withObservationTracking {
            _ = toolbarState.searchText
            _ = toolbarState.sortField
            _ = toolbarState.ascending
            _ = toolbarState.activeFilterResult?.calibreIDs
            _ = toolbarState.showFilterDrawer
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.toolbarStateDidChange()
                self?.scheduleObservation()
            }
        }
    }

    private func toolbarStateDidChange() {
        let newSearch     = toolbarState.searchText
        let newSort       = toolbarState.sortField
        let newAscending  = toolbarState.ascending
        let newFilterIDs  = toolbarState.activeFilterResult?.calibreIDs
        let newShowFilter = toolbarState.showFilterDrawer

        if newShowFilter && !lastShowFilter { presentFilterSheet() }
        lastShowFilter = newShowFilter

        let searchChanged = newSearch    != lastSearch
        let sortChanged   = newSort      != lastSort || newAscending != lastAscending
        let filterChanged = newFilterIDs != lastFilterIDs

        guard searchChanged || sortChanged || filterChanged else { return }
        lastSearch    = newSearch
        lastSort      = newSort
        lastAscending = newAscending
        lastFilterIDs = newFilterIDs

        if searchChanged {
            debouncer.schedule { [weak self] in self?.loadPage(reset: true) }
        } else {
            loadPage(reset: true)
        }
    }

    // MARK: - Filter sheet

    private func presentFilterSheet() {
        guard filterSheetWindowController == nil,
              let parentWindow = view.window else { return }

        // Build a sheet window hosting FilterDrawerView
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Filter Library"
        panel.isReleasedWhenClosed = false

        let hostVC = NSHostingController(rootView: EmailFilterSheet(toolbarState: toolbarState) {
            [weak self] in self?.dismissFilterSheet()
        }.modelContainer(modelContainer))
        panel.contentViewController = hostVC

        let wc = NSWindowController(window: panel)
        filterSheetWindowController = wc

        parentWindow.beginSheet(panel) { [weak self] _ in
            self?.filterSheetWindowController = nil
            // Reset the trigger flag so it can fire again next time
            self?.toolbarState.showFilterDrawer = false
            self?.lastShowFilter = false
        }
    }

    private func dismissFilterSheet() {
        guard let wc = filterSheetWindowController,
              let sheet = wc.window,
              let parentWindow = view.window else { return }
        parentWindow.endSheet(sheet)
    }

    // MARK: - Data loading

    private var libraryRootURL: URL? {
        LibraryRegistry.shared.activePath.map { URL(fileURLWithPath: $0) }
    }

    private func loadPage(reset: Bool) {
        guard let library = session.library else {
            books = []; sidebarVC.books = []; return
        }
        if reset { currentPage = 0; books = []; selectedBook = nil }

        let effectiveSearch = toolbarState.searchText.isEmpty ? nil : toolbarState.searchText
        let raw: [CalibreBook]
        if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            raw = library.books(
                ids: result.calibreIDs,
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                search: effectiveSearch
            )
        } else if toolbarState.activeFilterResult != nil {
            raw = []
        } else {
            raw = library.books(
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                search: effectiveSearch
            )
        }

        hasNextPage = raw.count > pageSize
        let page    = Array(raw.prefix(pageSize))
        if reset { books = page } else { books.append(contentsOf: page) }

        sidebarVC.books      = books
        sidebarVC.bookStates = bookStates
    }

    private func loadNextPageIfAvailable() {
        guard hasNextPage else { return }
        currentPage += 1
        loadPage(reset: false)
    }

    private func refreshBookStates() {
        let ctx = ModelContext(modelContainer)
        let all = (try? ctx.fetch(FetchDescriptor<BookState>())) ?? []
        bookStates = Dictionary(uniqueKeysWithValues: all.map { ($0.calibreID, $0) })
        sidebarVC?.bookStates = bookStates
    }

    // MARK: - Inline reader pane

    private func updateReaderPane() {
        // Pull out and replace the right-pane split item
        replaceRightPane(with: makeRightVC())
    }

    private func makeRightVC() -> NSViewController {
        guard let book = selectedBook else { return makePlaceholderVC() }

        let rvc = ReaderViewController(book: book, modelContainer: modelContainer)

        // Record lastOpenedDate without the window controller wrapper
        let cid = book.id
        Task.detached { [mc = modelContainer] in
            let ctx = ModelContext(mc)
            let all = (try? ctx.fetch(FetchDescriptor<BookState>())) ?? []
            if let state = all.first(where: { $0.calibreID == cid }) {
                state.lastOpenedDate = Date()
            } else {
                let s = BookState(calibreID: cid)
                s.lastOpenedDate = Date()
                ctx.insert(s)
            }
            try? ctx.save()
        }
        return rvc
    }

    /// Remove the last NSSplitViewItem and replace with `vc`.
    ///
    /// IMPORTANT: NSSplitViewController requires that every VC in its items is
    /// one of *its own* children.  We must call splitVC.addChild (not self.addChild)
    /// before calling addSplitViewItem, otherwise the right pane stays blank because
    /// the split view never gets a chance to size and display the view.
    private func replaceRightPane(with vc: NSViewController) {
        // 1. Remove the existing right split item (if any)
        if splitVC.splitViewItems.count > 1 {
            let last = splitVC.splitViewItems.last!
            // Detach the old child VC from the split VC's hierarchy
            let oldVC = last.viewController
            splitVC.removeSplitViewItem(last)
            oldVC.removeFromParent()
        }

        // 2. Add the new VC as a child of splitVC (not self) and create the item
        splitVC.addChild(vc)
        let item = NSSplitViewItem(viewController: vc)
        item.minimumThickness = 420
        splitVC.addSplitViewItem(item)
    }
}

// MARK: - EmailFilterSheet

/// SwiftUI wrapper that hosts FilterDrawerView as an NSWindow sheet.
///
/// FilterDrawerView already contains its own X button (via @Environment(\.dismiss))
/// and an Apply button that calls onApply then dismisses.  We just need to wire the
/// bindings and pass an onApply that closes the sheet through the NSWindow sheet API.
private struct EmailFilterSheet: View {
    let toolbarState: LibraryToolbarState
    let onDismiss: () -> Void

    var body: some View {
        FilterDrawerView(
            expression: Binding(
                get: { toolbarState.filterExpression },
                set: { toolbarState.filterExpression = $0 }
            ),
            onApply: {
                // Email view inherits activeFilterResult from toolbarState directly.
                // The list-view FilterBuilder result will already be set if the user
                // was in list view first; if not, leave activeFilterResult nil and
                // let the sidebar show the full library (consistent behaviour).
                onDismiss()
            },
            onClear: {
                toolbarState.filterExpression   = FilterExpression()
                toolbarState.activeFilterResult = nil
            }
        )
        .environment(toolbarState)
        // FilterDrawerView's built-in dismiss button calls @Environment(\.dismiss)
        // which resolves to the sheet's endSheet when presented as NSWindow sheet.
    }
}
