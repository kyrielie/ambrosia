import AppKit
import SwiftUI
import SwiftData

// MARK: - EmailLibraryViewController

final class EmailLibraryViewController: NSViewController {

    // MARK: - Dependencies

    let modelContainer: ModelContainer
    let session:        LibrarySession
    let toolbarState:   LibraryToolbarState

    // MARK: - Child VCs

    private var splitVC:   NSSplitViewController!
    private var sidebarVC: EmailSidebarViewController!

    // MARK: - Filter sheet host

    private var filterSheetHost: NSHostingView<FilterSheetCarrier>?

    // MARK: - Sidebar state

    private var isSidebarHidden = false

    // MARK: - Pagination

    private var books:      [CalibreBook]    = []
    var currentBooks: [CalibreBook] { books }
    var bookStates: [Int: BookState] = [:]
    private var collectionMembership: [String: Set<Int>] = [:]
    private var currentPage = 0
    private var hasNextPage = false
    private let pageSize    = 25

    // MARK: - Toolbar snapshots

    private var lastSearch:    String    = ""
    private var lastSort:      SortField = .title
    private var lastAscending: Bool      = true
    private var lastFilterIDs: [Int]?    = nil

    private let debouncer = DebounceTimer(delay: 0.4)

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
        addFilterSheetHost()
        refreshBookStates()
        refreshCollections()
        loadPage(reset: true)
        startObservingToolbarState()
        // Register so LibraryWindowController can deliver committed filter rules
        toolbarState.registerFilterCommitHandler { [weak self] rule in
            self?.addOrReplaceRule(rule)
        }
    }

    // MARK: - Split-view setup

    private func buildSplitView() {
        sidebarVC = EmailSidebarViewController()
        sidebarVC.toolbarState = toolbarState
        sidebarVC.onSelect     = { [weak self] book in self?.selectedBook = book }
        sidebarVC.onOpen       = { [weak self] book in
            guard let self else { return }
            let ctx = ModelContext(modelContainer)
            AppDelegate.shared?.openReaderWindow(book: book, modelContext: ctx)
        }
        sidebarVC.onLoadMore   = { [weak self] in self?.loadNextPageIfAvailable() }
        sidebarVC.onEditFilter = { [weak self] in
            self?.toolbarState.showFilterDrawer = true
        }
        sidebarVC.onClearFilter = { [weak self] in
            guard let self else { return }
            toolbarState.filterExpression   = FilterExpression()
            toolbarState.activeFilterResult = nil
            loadPage(reset: true)
        }
        sidebarVC.onContextMenuOpen = { [weak self] book in
            guard let self else { return }
            let ctx = ModelContext(modelContainer)
            AppDelegate.shared?.openReaderWindow(book: book, modelContext: ctx)
        }
        sidebarVC.onContextMenuLike = { [weak self] book in
            guard let self else { return }
            if let existing = bookStates[book.id] {
                existing.isLiked.toggle()
            } else {
                let ctx = ModelContext(modelContainer)
                let s = BookState(calibreID: book.id)
                s.isLiked = true
                ctx.insert(s)
                try? ctx.save()
            }
            refreshBookStates()
        }
        sidebarVC.onContextMenuToggleCollection = { [weak self] book, collectionName in
            guard let self else { return }
            let ctx = ModelContext(modelContainer)
            let all = (try? ctx.fetch(FetchDescriptor<Collection>())) ?? []
            if let col = all.first(where: { $0.name == collectionName }) {
                if col.contains(calibreID: book.id) {
                    col.remove(calibreID: book.id)
                } else {
                    col.add(calibreID: book.id)
                }
                try? ctx.save()
                refreshCollections()
            }
        }
        sidebarVC.onContextMenuNewCollection = { [weak self] _ in
            guard let self else { return }
            toolbarState.showCollections = true
        }

        splitVC = NSSplitViewController()
        splitVC.splitView.isVertical   = true
        splitVC.splitView.autosaveName = "AmbrosiaEmailSplitView"

        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness           = 200
        sidebarItem.maximumThickness           = 380
        sidebarItem.preferredThicknessFraction = 0.26
        sidebarItem.canCollapse                = true

        let readerItem = NSSplitViewItem(viewController: makePlaceholderVC())
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

    // MARK: - Filter sheet host

    private func addFilterSheetHost() {
        let carrier = FilterSheetCarrier(
            toolbarState:   toolbarState,
            modelContainer: modelContainer,
            emailVC:        self
        )
        let hv = NSHostingView(rootView: carrier)
        hv.sizingOptions = []
        hv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hv)
        NSLayoutConstraint.activate([
            hv.widthAnchor.constraint(equalToConstant: 0),
            hv.heightAnchor.constraint(equalToConstant: 0),
            hv.topAnchor.constraint(equalTo: view.topAnchor),
            hv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ])
        filterSheetHost = hv
    }

    // MARK: - Placeholder

    private func makePlaceholderVC() -> NSViewController {
        NSHostingController(rootView:
            VStack(spacing: 14) {
                Image(systemName: "book.closed")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("Select a book to read")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("Filter by tag in the list view, then switch here to read through results.")
                    .font(.callout)
                    .foregroundStyle(.quaternary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    // MARK: - Sidebar toggle

    @objc func performSidebarToggle() {
        isSidebarHidden.toggle()
        guard let item = splitVC.splitViewItems.first else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            item.animator().isCollapsed = isSidebarHidden
        }
    }

    // MARK: - Toolbar state observation

    private func startObservingToolbarState() { scheduleObservation() }

    private func scheduleObservation() {
        withObservationTracking {
            _ = toolbarState.searchText
            _ = toolbarState.sortField
            _ = toolbarState.ascending
            _ = toolbarState.activeFilterResult?.calibreIDs
            _ = toolbarState.toggleEmailSidebar
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.toolbarStateDidChange()
                self?.scheduleObservation()
            }
        }
    }

    private func toolbarStateDidChange() {
        if toolbarState.toggleEmailSidebar {
            toolbarState.toggleEmailSidebar = false
            performSidebarToggle()
        }

        let newSearch    = toolbarState.searchText
        let newSort      = toolbarState.sortField
        let newAscending = toolbarState.ascending
        let newFilterIDs = toolbarState.activeFilterResult?.calibreIDs

        let changed = newSearch    != lastSearch
                   || newSort      != lastSort
                   || newAscending != lastAscending
                   || newFilterIDs != lastFilterIDs

        guard changed else { return }

        let searchChanged = newSearch != lastSearch
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

    // MARK: - Quick filter helper (mirrors BookGridItem.addOrReplaceRule)

    func addOrReplaceRule(_ rule: FilterRule) {
        if toolbarState.filterExpression.groups.isEmpty {
            toolbarState.filterExpression.groups = [FilterGroup()]
        }
        let allRules = toolbarState.filterExpression.groups.flatMap(\.rules)
        let isDuplicate = allRules.contains {
            $0.field == rule.field && $0.value == rule.value && $0.op == rule.op
        }
        guard !isDuplicate else { return }
        if rule.field == .authorName || rule.field == .series {
            toolbarState.filterExpression.groups[0].rules.removeAll { $0.field == rule.field }
        }
        toolbarState.filterExpression.groups[0].rules.append(rule)
        applyFilterRules()
    }

    // MARK: - Filter application

    func applyFilterRules() {
        guard let library = session.library else { return }
        guard toolbarState.filterExpression.hasCompleteRules else {
            toolbarState.activeFilterResult = nil
            loadPage(reset: true)
            return
        }

        let needsLiked = toolbarState.filterExpression.groups
            .flatMap(\.rules).contains { $0.field == .isLiked }
        let likedIDs: Set<Int> = needsLiked
            ? Set(bookStates.values.filter(\.isLiked).map(\.calibreID))
            : []

        let needsCollection = toolbarState.filterExpression.groups
            .flatMap(\.rules).contains { $0.field == .collection }
        let collectionMap: [String: Set<Int>]
        if needsCollection {
            let ctx  = ModelContext(modelContainer)
            let cols = (try? ctx.fetch(FetchDescriptor<Collection>())) ?? []
            collectionMap = Dictionary(uniqueKeysWithValues:
                cols.map { ($0.name, Set($0.calibreIDs)) }
            )
        } else {
            collectionMap = [:]
        }

        let builder = FilterBuilder(library: library)
        toolbarState.activeFilterResult = builder.matchingIDs(
            expression: toolbarState.filterExpression,
            likedIDs:      likedIDs,
            collectionMap: collectionMap
        )
        loadPage(reset: true)
    }

    // MARK: - Data loading (uses SearchQuery path — mirrors BookGridItem exactly)

    func loadPage(reset: Bool) {
        guard let library = session.library else {
            books = []; sidebarVC?.books = []; return
        }
        if reset { currentPage = 0; books = []; selectedBook = nil }

        // Parse search text into a structured query — same path as list view
        let rawQuery = toolbarState.searchText.isEmpty
            ? SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
            : SearchQueryParser.parse(toolbarState.searchText)
        let query = session.resolvedQuery(rawQuery)

        let raw: [CalibreBook]
        if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            let ids = query.ftsMatchedIDs ?? result.calibreIDs
            raw = library.books(
                ids: ids,
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query
            )
        } else if toolbarState.activeFilterResult != nil {
            raw = []
        } else {
            raw = library.books(
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query
            )
        }

        hasNextPage = raw.count > pageSize
        let page    = Array(raw.prefix(pageSize))
        if reset { books = page } else { books.append(contentsOf: page) }

        sidebarVC?.books      = books
        sidebarVC?.bookStates = bookStates
    }

    private func loadNextPageIfAvailable() {
        guard hasNextPage else { return }
        currentPage += 1
        loadPage(reset: false)
    }

    func refreshBookStates() {
        let ctx = ModelContext(modelContainer)
        let all = (try? ctx.fetch(FetchDescriptor<BookState>())) ?? []
        bookStates = all.reduce(into: [:]) { $0[$1.calibreID] = $1 }
        sidebarVC?.bookStates = bookStates
    }

    func refreshCollections() {
        let ctx = ModelContext(modelContainer)
        let all = (try? ctx.fetch(FetchDescriptor<Collection>())) ?? []
        collectionMembership = Dictionary(uniqueKeysWithValues:
            all.map { ($0.name, Set($0.calibreIDs)) }
        )
        sidebarVC?.collectionMembership = collectionMembership
    }

    // MARK: - Inline reader pane

    private func updateReaderPane() {
        replaceRightPane(with: makeRightVC())
    }

    private func makeRightVC() -> NSViewController {
        guard let book = selectedBook else { return makePlaceholderVC() }
        let rvc = ReaderViewController(book: book, modelContainer: modelContainer)
        let cid = book.id
        Task.detached { [mc = modelContainer] in
            let ctx = ModelContext(mc)
            let all = (try? ctx.fetch(FetchDescriptor<BookState>())) ?? []
            if let s = all.first(where: { $0.calibreID == cid }) {
                s.lastOpenedDate = Date()
            } else {
                let s = BookState(calibreID: cid)
                s.lastOpenedDate = Date()
                ctx.insert(s)
            }
            try? ctx.save()
        }
        return rvc
    }

    private func replaceRightPane(with vc: NSViewController) {
        if splitVC.splitViewItems.count > 1 {
            let last  = splitVC.splitViewItems.last!
            let oldVC = last.viewController
            splitVC.removeSplitViewItem(last)
            oldVC.removeFromParent()
        }
        splitVC.addChild(vc)
        let item = NSSplitViewItem(viewController: vc)
        item.minimumThickness = 420
        splitVC.addSplitViewItem(item)
    }
}

// MARK: - FilterSheetCarrier

struct FilterSheetCarrier: View {
    let toolbarState:   LibraryToolbarState
    let modelContainer: ModelContainer
    weak var emailVC:   EmailLibraryViewController?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { toolbarState.showFilterDrawer },
                set: { toolbarState.showFilterDrawer = $0 }
            )) {
                FilterDrawerView(
                    expression: Binding(
                        get: { toolbarState.filterExpression },
                        set: { toolbarState.filterExpression = $0 }
                    ),
                    onApply: { emailVC?.applyFilterRules() },
                    onClear: {
                        toolbarState.filterExpression   = FilterExpression()
                        toolbarState.activeFilterResult = nil
                        emailVC?.loadPage(reset: true)
                    }
                )
                .environment(toolbarState)
                .modelContainer(modelContainer)
            }
            .sheet(isPresented: Binding(
                get: { toolbarState.showCollections },
                set: { toolbarState.showCollections = $0 }
            )) {
                CollectionsView(onSelectCollection: { collection in
                    let rule = FilterRule(field: .collection, op: .equals, value: collection.name)
                    var expr = toolbarState.filterExpression
                    if expr.groups.isEmpty {
                        expr.groups = [FilterGroup(rules: [rule])]
                    } else {
                        expr.groups[0].rules.removeAll { $0.field == .collection }
                        expr.groups[0].rules.append(rule)
                    }
                    toolbarState.filterExpression = expr
                    toolbarState.showCollections  = false
                    emailVC?.applyFilterRules()
                })
                .modelContainer(modelContainer)
            }
            .sheet(isPresented: Binding(
                get: { toolbarState.showReadingGoal },
                set: { toolbarState.showReadingGoal = $0 }
            )) {
                ReadingGoalView()
                    .modelContainer(modelContainer)
            }
            .onChange(of: toolbarState.triggerExport) {
                if toolbarState.triggerExport {
                    if let books = emailVC?.currentBooks {
                        ExportManager.presentExportPanel(books: books)
                    }
                    toolbarState.triggerExport = false
                }
            }
    }
}
