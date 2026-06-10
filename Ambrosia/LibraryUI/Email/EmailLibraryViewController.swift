import AppKit
import Combine
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
    private var skippedCollectionCancellable: AnyCancellable?
    private var appearanceCancellable: AnyCancellable?

    // MARK: - Sidebar state

    private var isSidebarHidden = false

    // MARK: - Pagination

    private var books:      [CalibreBook]    = []
    var currentBooks: [CalibreBook] { books }
    var bookStates: [Int: BookState] = [:]
    private var likedIDs: Set<Int> = []
    private var skippedIDs: Set<Int> = []
    private var collectionMembership: [String: Set<Int>] = [:]
    private var pendingCollectionSeedIDs: [Int] = []
    private var currentPage = 0
    private var hasNextPage = false
    private let pageSize    = 25
    private var pageFetchLimit: Int { (pageSize * 3) + 1 }

    // MARK: - Toolbar snapshots

    private var lastSearch:    String    = ""
    private var lastSort:      SortField = .title
    private var lastAscending: Bool      = true
    private var lastFilterIDs: [Int]?    = nil

    private let debouncer = DebounceTimer(delay: 0.4)

    private var selectedBook: CalibreBook?

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
        startObservingPreferences()
        // Register so LibraryWindowController can deliver committed filter rules
        toolbarState.registerFilterCommitHandler { [weak self] rule in
            self?.addOrReplaceRule(rule)
        }
    }

    private func startObservingPreferences() {
        skippedCollectionCancellable = ReaderPreferences.shared.$showSkippedCollection
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if toolbarState.filterExpression.hasCompleteRules {
                    applyFilterRules()
                } else {
                    loadPage(reset: true)
                }
            }

        appearanceCancellable = ReaderPreferences.shared.$libraryAppearanceMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLibraryAppearance()
            }
    }

    private func applyLibraryAppearance() {
        let appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        view.appearance = appearance
        splitVC?.view.appearance = appearance
        sidebarVC?.view.appearance = appearance
        filterSheetHost?.appearance = appearance
        sidebarVC?.reloadAppearance()
    }

    // MARK: - Split-view setup

    private func buildSplitView() {
        sidebarVC = EmailSidebarViewController()
        sidebarVC.toolbarState = toolbarState
        sidebarVC.onSelect     = { [weak self] book in self?.setSelectedBook(book) }
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
        sidebarVC.onContextMenuOpen = { [weak self] books in
            guard let self else { return }
            let ctx = ModelContext(modelContainer)
            for book in books {
                AppDelegate.shared?.openReaderWindow(book: book, modelContext: ctx)
            }
        }
        sidebarVC.onContextMenuSetLiked = { [weak self] books, liked in
            guard let self else { return }
            Task {
                try? await self.session.collectionStore?.setLiked(calibreIDs: books.map(\.id), liked: liked)
                await self.refreshCollectionSnapshots()
            }
        }
        sidebarVC.onContextMenuSkip = { [weak self] books in
            guard let self else { return }
            Task {
                for book in books {
                    try? await self.session.collectionStore?.skipBook(calibreID: book.id)
                }
                await self.refreshCollectionSnapshots()
                self.applyFilterRules()
            }
        }
        sidebarVC.onContextMenuMarkRead = { [weak self] books in
            self?.markRead(books)
        }
        sidebarVC.onContextMenuResetProgress = { [weak self] books in
            self?.resetProgress(books)
        }
        sidebarVC.onContextMenuToggleCollection = { [weak self] books, collectionName in
            guard let self else { return }
            Task {
                let collections = (try? await self.session.collectionStore?.collections()) ?? []
                if let collection = collections.first(where: { $0.name == collectionName }) {
                    let ids = books.map(\.id)
                    let membership = (try? await self.session.collectionStore?.membershipByCollectionID()) ?? [:]
                    let members = membership[collection.id] ?? []
                    if Set(ids).isSubset(of: members) {
                        try? await self.session.collectionStore?.bulkRemove(calibreIDs: ids, from: collection.id)
                    } else {
                        try? await self.session.collectionStore?.bulkAdd(calibreIDs: ids, to: collection.id)
                    }
                }
                await self.refreshCollectionSnapshots()
            }
        }
        sidebarVC.onContextMenuNewCollection = { [weak self] books in
            guard let self else { return }
            self.pendingCollectionSeedIDs = books.map(\.id)
            toolbarState.showCollections = true
        }

        splitVC = NSSplitViewController()
        splitVC.splitView.isVertical   = true
        splitVC.splitView.autosaveName = "AmbrosiaEmailSplitView"
        applyLibraryAppearance()

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
            session:        session,
            emailVC:        self
        )
        let hv = NSHostingView(rootView: carrier)
        hv.sizingOptions = []
        hv.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
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
            .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
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

        Task {
            let needsLiked = toolbarState.filterExpression.groups
                .flatMap(\.rules).contains { $0.field == .isLiked }
            let currentLikedIDs = needsLiked ? ((try? await session.collectionStore?.likedIDs()) ?? []) : []
            let needsCollection = toolbarState.filterExpression.groups
                .flatMap(\.rules).contains { $0.field == .collection }
            let collectionMap = needsCollection ? ((try? await session.collectionStore?.membershipMap()) ?? [:]) : [:]

            let builder = FilterBuilder(library: library)
            let result = builder.matchingIDs(
                expression: toolbarState.filterExpression,
                likedIDs:      currentLikedIDs,
                collectionMap: collectionMap
            )
            let currentSkipped = Set((try? await session.collectionStore?.members(of: SystemCollectionID.skipped)) ?? [])
            let filteredIDs = ReaderPreferences.shared.showSkippedCollection
                ? result.calibreIDs
                : result.calibreIDs.filter { !currentSkipped.contains($0) }
            toolbarState.activeFilterResult = FilterResult(
                calibreIDs: filteredIDs,
                totalCount: filteredIDs.count
            )
            likedIDs = currentLikedIDs
            skippedIDs = currentSkipped
            loadPage(reset: true)
        }
    }

    // MARK: - Data loading (uses SearchQuery path — mirrors BookGridItem exactly)

    func loadPage(reset: Bool) {
        guard let library = session.library else {
            books = []
            setSelectedBook(nil)
            sidebarVC?.books = []
            return
        }
        if reset { currentPage = 0; books = [] }

        // Parse search text into a structured query — same path as list view
        let rawQuery = toolbarState.searchText.isEmpty
            ? SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
            : SearchQueryParser.parse(toolbarState.searchText)
        let query = session.resolvedQuery(rawQuery)

        let raw: [CalibreBook]
        if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            let ids = visibleIDs(query.ftsMatchedIDs ?? result.calibreIDs)
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
                offset: currentPage * pageSize, limit: pageFetchLimit,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query
            )
        }

        let visible = visibleBooks(raw)
        hasNextPage = raw.count == pageFetchLimit || visible.count > pageSize
        let page    = Array(visible.prefix(pageSize))
        if reset { books = page } else { books.append(contentsOf: page) }

        sidebarVC?.books      = books
        sidebarVC?.bookStates = bookStates
        sidebarVC?.likedIDs = likedIDs
    }

    private func visibleIDs(_ ids: [Int]) -> [Int] {
        ReaderPreferences.shared.showSkippedCollection ? ids : ids.filter { !skippedIDs.contains($0) }
    }

    private func visibleBooks(_ raw: [CalibreBook]) -> [CalibreBook] {
        ReaderPreferences.shared.showSkippedCollection ? raw : raw.filter { !skippedIDs.contains($0.id) }
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
        Task { await refreshCollectionSnapshots() }
    }

    func refreshCollections() {
        Task { await refreshCollectionSnapshots() }
    }

    func consumePendingCollectionSeedIDs() -> [Int] {
        let ids = pendingCollectionSeedIDs
        pendingCollectionSeedIDs = []
        return ids
    }

    private func markRead(_ books: [CalibreBook]) {
        let ids = books.map(\.id)
        let container = modelContainer
        Task {
            let ctx = ModelContext(container)
            for calibreID in ids {
                let state = self.stateForMutation(calibreID, in: ctx)
                state.markRead()
            }
            try? ctx.save()
            for calibreID in ids {
                try? await session.collectionStore?.syncAutomatedCollection(
                    collectionID: SystemCollectionID.finished,
                    calibreID: calibreID,
                    shouldBeMember: true
                )
                try? await session.collectionStore?.syncAutomatedCollection(
                    collectionID: SystemCollectionID.inProgress,
                    calibreID: calibreID,
                    shouldBeMember: false
                )
            }
            refreshBookStates()
            loadPage(reset: true)
        }
    }

    private func resetProgress(_ books: [CalibreBook]) {
        let ids = books.map(\.id)
        let container = modelContainer
        Task {
            let ctx = ModelContext(container)
            for calibreID in ids {
                let state = self.stateForMutation(calibreID, in: ctx)
                state.resetReadingProgress()
            }
            try? ctx.save()
            for calibreID in ids {
                try? await session.collectionStore?.syncAutomatedCollection(
                    collectionID: SystemCollectionID.finished,
                    calibreID: calibreID,
                    shouldBeMember: false
                )
                try? await session.collectionStore?.syncAutomatedCollection(
                    collectionID: SystemCollectionID.inProgress,
                    calibreID: calibreID,
                    shouldBeMember: false
                )
            }
            refreshBookStates()
            loadPage(reset: true)
        }
    }

    private func stateForMutation(_ calibreID: Int, in ctx: ModelContext) -> BookState {
        var desc = FetchDescriptor<BookState>(
            predicate: #Predicate { $0.calibreID == calibreID }
        )
        desc.fetchLimit = 1
        let state = (try? ctx.fetch(desc).first) ?? BookState(calibreID: calibreID)
        if state.modelContext == nil {
            ctx.insert(state)
        }
        return state
    }

    @MainActor
    private func refreshCollectionSnapshots() async {
        let collections = (try? await session.collectionStore?.collections()) ?? []
        let membershipByID = (try? await session.collectionStore?.membershipByCollectionID()) ?? [:]
        let currentSkipped = membershipByID[SystemCollectionID.skipped] ?? []
        collectionMembership = Dictionary(uniqueKeysWithValues: collections.map { collection in
            return (collection.name, membershipByID[collection.id] ?? [])
        })
        likedIDs = (try? await session.collectionStore?.likedIDs()) ?? []
        let shouldReloadPage = skippedIDs != currentSkipped
        skippedIDs = currentSkipped
        sidebarVC?.collectionMembership = collectionMembership
        sidebarVC?.likedIDs = likedIDs
        if shouldReloadPage {
            loadPage(reset: true)
        }
    }

    // MARK: - Inline reader pane

    private func setSelectedBook(_ book: CalibreBook?) {
        guard selectedBook?.id != book?.id else { return }
        selectedBook = book
        updateReaderPane()
    }

    private func updateReaderPane() {
        replaceRightPane(with: makeRightVC())
    }

    private func makeRightVC() -> NSViewController {
        guard let book = selectedBook else { return makePlaceholderVC() }
        let rvc = ReaderViewController(book: book, modelContainer: modelContainer)
        rvc.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        rvc.onReadingProgressChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshBookStates()
            }
        }
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
        vc.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        let item = NSSplitViewItem(viewController: vc)
        item.minimumThickness = 420
        splitVC.addSplitViewItem(item)
    }
}

// MARK: - FilterSheetCarrier

struct FilterSheetCarrier: View {
    let toolbarState:   LibraryToolbarState
    let modelContainer: ModelContainer
    let session:        LibrarySession
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
                .environment(session)
                .modelContainer(modelContainer)
                .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
            }
            .sheet(isPresented: Binding(
                get: { toolbarState.showCollections },
                set: { toolbarState.showCollections = $0 }
            )) {
                let seedIDs = emailVC?.consumePendingCollectionSeedIDs() ?? []
                CollectionsView(calibreIDsToAdd: seedIDs, onSelectCollection: { collection in
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
                .environment(session)
                .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
            }
            .sheet(isPresented: Binding(
                get: { toolbarState.showReadingGoal },
                set: { toolbarState.showReadingGoal = $0 }
            )) {
                ReadingGoalView()
                    .modelContainer(modelContainer)
                    .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
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
