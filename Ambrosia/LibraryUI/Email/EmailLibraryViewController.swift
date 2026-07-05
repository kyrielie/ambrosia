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
    private var readerSidebarHostingVC: NSHostingController<EmailReaderSidebarView>!
    private var librarySidebarItem: NSSplitViewItem!
    private var readerPaneItem: NSSplitViewItem!
    private var annotationsSidebarItem: NSSplitViewItem!

    // MARK: - Filter sheet host

    private var filterSheetHost: NSHostingView<FilterSheetCarrier>?
    private var collectionPickerPopover: NSPopover?
    private var skippedCollectionCancellable: AnyCancellable?
    private var seriesOrMergedCancellable: AnyCancellable?
    private var appearanceCancellable: AnyCancellable?
    private var preferenceCancellables: Set<AnyCancellable> = []

    // MARK: - Sidebar state

    private var isSidebarHidden = false
    private var lastSidebarThickness: CGFloat = 280

    // MARK: - Pagination

    private var books:      [CalibreBook]    = []
    private var items:      [LibraryItem]    = []
    var currentBooks: [CalibreBook] { books }
    var bookStates: [Int: BookState] = [:]
    private var ao3Metadata: [Int: AO3MetadataRecord] = [:]
    private var likedIDs: Set<Int> = []
    private var readLaterIDs: Set<Int> = []
    private var skippedIDs: Set<Int> = []
    private var seriesOrMergedIDs: Set<Int> = []
    private var ao3PublisherIDs: Set<Int> = []
    private var collectionMembership: [String: Set<Int>] = [:]
    private var pendingCollectionSeedIDs: [Int] = []
    private var currentPage = 0
    /// Raw SQL row offset for the current load, used instead of currentPage * pageSize
    /// when grouping is on — see LibraryRootView.rawSQLOffset for full rationale.
    private var rawSQLOffset = 0
    /// History of prior rawSQLOffset values. The email view only paginates forward
    /// (infinite scroll, no Previous button), so this exists purely for symmetry with
    /// LibraryRootView and is cleared on every reset; nothing currently pops it.
    private var rawSQLOffsetHistory: [Int] = []
    private var hasNextPage = false
    /// Overflow from the group-aware drain loop in loadPage: the loop stops once it
    /// has >= pageSize visible rows, which can overshoot by up to pageFetchLimit - 1.
    /// The excess is buffered here and prepended to the next page instead of being
    /// re-fetched (rawSQLOffset has already moved past it) or silently dropped.
    private var groupAwareOverflow: [CalibreBook] = []
    private let pageSize    = 25
    private var pageFetchLimit: Int { (pageSize * 3) + 1 }

    /// Async-resolved synonym expansions for the current search query's tag terms.
    /// Mirrors `LibraryRootView.resolvedTagExpansions` — see that property for rationale.
    private var resolvedTagExpansions: [String: [String]] = [:]

    /// Expansions for committed filter rule tag values, populated async in
    /// `applyFilterRules` and read sync in `loadPage`'s SQL-paged path.
    private var cachedFilterTagExpansions: [String: [String]] = [:]

    // MARK: - Toolbar snapshots

    private var lastSearch:    String    = ""
    private var lastSort:      SortField = .title
    private var lastAscending: Bool      = true
    private var lastFilterIDs: [Int]?    = nil
    private var lastFilterToken: String? = nil
    private var lastSidebarToggle: Bool  = false
    private var lastReaderSidebarToggle: Bool = false
    private var lastShowReaderSidebarToggle: Bool = false
    private var lastReshuffleToken: Bool = false
    private var lastGroupBySeries: Bool = false

    /// §switch-flicker fix: set true by `stopObserving()` when this controller is
    /// removed from the view hierarchy (see LibraryViewController.applyViewMode).
    /// Switching to email view recreates a brand new EmailLibraryViewController
    /// every time — old instances were never deallocated because scheduleObservation()
    /// implicitly captured `self` strongly via `self.toolbarState` inside the
    /// withObservationTracking apply-closure, which the Observation runtime holds
    /// onto until it next fires. Since toolbarState is shared and kept alive by
    /// LibraryViewController, every "dead" EmailLibraryViewController stayed fully
    /// alive too, kept reacting to toolbarState changes, and kept calling
    /// loadPage()/applyFilterRules() — racing with the current, visible instance and
    /// overwriting the shared toolbarState.activeFilterResult out from under it.
    /// That's the source of both the load/sort/loadPage "blink" and the
    /// briefly-shows-then-clears flicker when a filter is active.
    private var isTornDown = false

    /// Called by LibraryViewController right before this controller is removed from
    /// the view hierarchy. Stops the observation loop from rescheduling itself, so
    /// the only remaining strong reference to self is released the next time
    /// toolbarState changes (instead of being held indefinitely).
    func stopObserving() {
        isTornDown = true
    }

    private let debouncer = DebounceTimer(delay: 0.4)
    private var fullTextTask: Task<Void, Never>?
    private var filterCountTask: Task<Void, Never>?
    private var rebuildSidebarTask: Task<Void, Never>?

    private var selectedBook: CalibreBook?
    private weak var currentReaderVC: ReaderViewController?
    private var readerLocalFindState = LocalReaderFindState()
    private var lastAppliedFullTextPhrase = ""
    private weak var lastAppliedFullTextReader: ReaderViewController?
    private var pendingFullTextPhrase = ""
    private var readerAnnotations: [Annotation] = []

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
        toolbarState.isEmailReaderSidebarVisible = false
        buildSplitView()
        addFilterSheetHost()
        // §switch-flicker fix: seed visibility snapshots from the session cache so the
        // first loadPage/applyFilterRules call below sees correct data and doesn't flash
        // all books before the async refreshCollectionSnapshots completes.
        // LibraryRootView writes these caches back after every refresh; they are cleared
        // on library open/close. If the cache is empty (first launch, library just opened)
        // the initial render is the same as before and refreshCollectionSnapshots corrects it.
        seriesOrMergedIDs = session.cachedSeriesOrMergedIDs
        skippedIDs        = session.cachedSkippedIDs
        likedIDs          = session.cachedLikedIDs
        ao3PublisherIDs   = session.cachedAO3PublisherIDs
        readLaterIDs      = session.cachedReadLaterIDs
        lastGroupBySeries = toolbarState.groupBySeries
        refreshBookStates()
        refreshCollections()
        if toolbarState.filterExpression.hasCompleteRules {
            applyFilterRules()
        } else {
            Task { await loadPage(reset: true) }
        }
        startObservingToolbarState()
        startObservingPreferences()
        // Register so LibraryWindowController can deliver committed filter rules
        toolbarState.registerFilterCommitHandler { [weak self] rule in
            self?.addOrReplaceRule(rule)
        }
    }

    deinit {
        toolbarState.isEmailReaderSidebarVisible = false
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
                    Task { await self.loadPage(reset: true) }
                }
            }

        appearanceCancellable = ReaderPreferences.shared.$libraryAppearanceMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLibraryAppearance()
            }

        seriesOrMergedCancellable = NotificationCenter.default.publisher(for: .seriesOrMergedCollectionDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCollections()
            }
        ReaderPreferences.shared.$hideNonAO3PublisherBooks
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCollections()
            }
            .store(in: &preferenceCancellables)
        ReaderPreferences.shared.$emailPillsShowCollections
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.sidebarVC?.reloadAppearance()
            }
            .store(in: &preferenceCancellables)
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
        sidebarVC.onOpen       = { [weak self] target in
            guard let self else { return }
            let ctx = ModelContext(modelContainer)
            AppDelegate.shared?.openReaderWindow(target: target, modelContext: ctx)
        }
        sidebarVC.onLoadMore   = { [weak self] in self?.loadNextPageIfAvailable() }
        sidebarVC.onEditFilter = { [weak self] in
            self?.toolbarState.showFilterDrawer = true
        }
        sidebarVC.onClearFilter = { [weak self] in
            guard let self else { return }
            toolbarState.filterExpression   = FilterExpression()
            toolbarState.activeFilterResult = nil
            toolbarState.cancelLibraryFilterApplication()
            Task { await self.loadPage(reset: true) }
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
                self.session.bumpMembershipVersion()  // §7
                await self.refreshCollectionSnapshots()
            }
        }
        sidebarVC.onToggleLiked = { [weak self] book in
            guard let self else { return }
        sidebarVC.onToggleReadLater = { [weak self] book in
            self?.toggleReadLater(for: book)
        }
            Task {
                try? await self.session.collectionStore?.toggleLiked(calibreID: book.id)
                self.session.bumpMembershipVersion()  // §7
                await self.refreshCollectionSnapshots()
            }
        }
        sidebarVC.onContextMenuReadLater = { [weak self] books in
            guard let self else { return }
            Task {
                try? await self.session.collectionStore?.bulkAdd(calibreIDs: books.map(\.id), to: SystemCollectionID.readLater)
                self.session.bumpMembershipVersion()  // §7
                await self.refreshCollectionSnapshots()
            }
        }
        sidebarVC.onContextMenuSkip = { [weak self] books in
            guard let self else { return }
            Task {
                for book in books {
                    try? await self.session.collectionStore?.skipBook(calibreID: book.id)
                }
                self.session.bumpMembershipVersion()  // §7
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
        sidebarVC.onContextMenuCollectionPicker = { [weak self] books, anchorView, anchorRect in
            guard let self else { return }
            self.showCollectionPicker(for: books.map(\.id), relativeTo: anchorRect, of: anchorView)
        }

        splitVC = NSSplitViewController()
        splitVC.splitView.isVertical   = true
        splitVC.splitView.autosaveName = "AmbrosiaEmailSplitView"
        applyLibraryAppearance()

        librarySidebarItem = NSSplitViewItem(viewController: sidebarVC)
        librarySidebarItem.minimumThickness           = 200
        librarySidebarItem.maximumThickness           = 380
        librarySidebarItem.preferredThicknessFraction = 0.26
        librarySidebarItem.canCollapse                = true

        readerPaneItem = NSSplitViewItem(viewController: makePlaceholderVC())
        readerPaneItem.minimumThickness = 420
        readerPaneItem.canCollapse = false

        annotationsSidebarItem = NSSplitViewItem(viewController: makeReaderSidebarVC())
        annotationsSidebarItem.minimumThickness = 240
        annotationsSidebarItem.maximumThickness = 360
        annotationsSidebarItem.preferredThicknessFraction = 0.24
        annotationsSidebarItem.canCollapse = true
        annotationsSidebarItem.isCollapsed = true

        // Fixed order: [library | annotations | reader].
        // The annotations pane is structurally at index 1 so it always
        // appears between the book list and the reading pane. Collapsing
        // it causes the reader to expand left and fill the gap naturally.
        splitVC.addSplitViewItem(librarySidebarItem)
        splitVC.addSplitViewItem(annotationsSidebarItem)
        splitVC.addSplitViewItem(readerPaneItem)

        addChild(splitVC)
        splitVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitVC.view)
        NSLayoutConstraint.activate([
            splitVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            splitVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        DispatchQueue.main.async { [weak self] in
            self?.rememberSidebarThickness()
        }
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

    private func showCollectionPicker(for calibreIDs: [Int], relativeTo rect: NSRect, of view: NSView) {
        collectionPickerPopover?.close()
        let popover = NSPopover()
        popover.behavior = .semitransient
        let root = CollectionSearchPickerView(
            calibreIDs: calibreIDs,
            onChange: { [weak self] in
                await self?.refreshCollectionSnapshots()
            },
            onComplete: { [weak popover] in
                popover?.close()
            }
        )
        .environment(session)
        .preferredColorScheme(ReaderPreferences.shared.resolvedLibraryColorScheme)
        popover.contentViewController = NSHostingController(rootView: root)
        collectionPickerPopover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
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
        guard let item = librarySidebarItem else { return }
        isSidebarHidden = !item.isCollapsed
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            item.isCollapsed = isSidebarHidden
            splitVC.splitView.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Toolbar state observation

    private func startObservingToolbarState() { scheduleObservation() }

    private func scheduleObservation() {
        // §switch-flicker fix: capture `ts` directly rather than reading
        // `toolbarState` (= `self.toolbarState`) inside the apply-closure below.
        // withObservationTracking's apply-closure is held by the Observation
        // runtime until it next fires, so any implicit `self` capture there keeps
        // this whole controller alive for as long as that closure goes unfired —
        // which, since toolbarState is shared and long-lived, could be indefinitely
        // after this controller has already been removed from the view hierarchy.
        let ts = toolbarState
        withObservationTracking {
            _ = ts.searchText
            _ = ts.sortField
            _ = ts.ascending
            _ = ts.activeFilterResult?.reloadToken
            _ = ts.isApplyingLibraryFilter
            _ = ts.pendingFullTextSearch
            _ = ts.toggleEmailSidebar
            _ = ts.toggleEmailReaderSidebar
            _ = ts.showEmailReaderSidebar
            _ = ts.reshuffleToken
            _ = ts.groupBySeries
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.isTornDown else { return }
                self.toolbarStateDidChange()
                self.scheduleObservation()
            }
        }
    }

    private func toolbarStateDidChange() {
        if toolbarState.toggleEmailSidebar != lastSidebarToggle {
            lastSidebarToggle = toolbarState.toggleEmailSidebar
            performSidebarToggle()
        }
        if toolbarState.toggleEmailReaderSidebar != lastReaderSidebarToggle {
            lastReaderSidebarToggle = toolbarState.toggleEmailReaderSidebar
            performReaderSidebarToggle()
        }
        if toolbarState.showEmailReaderSidebar != lastShowReaderSidebarToggle {
            lastShowReaderSidebarToggle = toolbarState.showEmailReaderSidebar
            switch toolbarState.emailReaderSidebarMode {
            case .annotations:      showEmailAnnotationSidebar(nil)
            case .tableOfContents:  showTOCInEmailSidebar(nil)
            }
        }
        if toolbarState.reshuffleToken != lastReshuffleToken {
            lastReshuffleToken = toolbarState.reshuffleToken
            if toolbarState.sortField == .random {
                Task { await loadPage(reset: true) }
            }
        }
        if toolbarState.groupBySeries != lastGroupBySeries {
            lastGroupBySeries = toolbarState.groupBySeries
            Task { await loadPage(reset: true) }
        }
        let newSearch    = toolbarState.searchText
        let newSort      = toolbarState.sortField
        let newAscending = toolbarState.ascending
        let newFilterToken = toolbarState.activeFilterResult?.reloadToken

        if newFilterToken != lastFilterToken {
            LibraryFilterDebug.log("toolbarState.filterTokenChanged", [
                "surface": "email",
                "old": lastFilterToken ?? "nil",
                "new": newFilterToken ?? "nil"
            ])
        }

        let changed = newSearch    != lastSearch
                   || newSort      != lastSort
                   || newAscending != lastAscending
                   || newFilterToken != lastFilterToken

        guard changed else { return }

        let searchChanged = newSearch != lastSearch
        lastSearch    = newSearch
        lastSort      = newSort
        lastAscending = newAscending
        lastFilterIDs = toolbarState.activeFilterResult?.calibreIDs
        lastFilterToken = newFilterToken

        if searchChanged {
            applyFullTextPhraseToLocalFind()
            refreshReaderSidebar()
            if toolbarState.consumeSearchTextReloadSuppression() {
                LibraryFilterDebug.log("searchText.suppressed", [
                    "surface": "email",
                    "searchText": toolbarState.searchText
                ])
                return
            }
            debouncer.schedule { [weak self] in
                guard let self else { return }
                LibraryFilterDebug.log("searchText.debounced", [
                    "surface": "email",
                    "searchText": self.toolbarState.searchText
                ])
                if self.toolbarState.activeFilterResult?.isSQLBacked == true,
                   self.toolbarState.activeFilterResult?.totalCount != nil {
                    self.toolbarState.activeFilterResult = FilterResult(calibreIDs: [], isSQLBacked: true)
                }
                if !self.startPendingSearchTextFullTextIfNeeded() {
                    let tagTerms = self.toolbarState.searchText.isEmpty
                        ? []
                        : SearchQueryParser.parse(self.toolbarState.searchText).tagTerms
                    if tagTerms != Array(self.resolvedTagExpansions.keys).sorted() {
                        self.resolveTagExpansionsIfNeeded(terms: tagTerms)
                    }
                    let token = self.toolbarState.beginLibraryFilterApplication()
                    Task {
                        await self.loadPage(reset: true)
                        self.toolbarState.finishLibraryFilterApplication(token: token)
                    }
                }
            }
        } else {
            applyFullTextPhraseToLocalFind()
            Task { await loadPage(reset: true) }
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
        let applyStart = LibraryFilterDebug.now()
        fullTextTask?.cancel()
        fullTextTask = nil
        filterCountTask?.cancel()
        guard let library = session.library else {
            toolbarState.cancelLibraryFilterApplication()
            return
        }
        guard toolbarState.filterExpression.hasCompleteRules else {
            toolbarState.activeFilterResult = nil
            toolbarState.cancelLibraryFilterApplication()
            Task { await loadPage(reset: true) }
            return
        }
        let expression = toolbarState.filterExpression
        LibraryFilterDebug.log("applyFilter.start", [
            "surface": "email",
            "rules": LibraryFilterDebug.summary(expression: expression),
            "sqlPageable": expression.isSQLPageable
        ])
        if expression.isSQLPageable {
            toolbarState.activeFilterResult = FilterResult(calibreIDs: [], isSQLBacked: true)
            toolbarState.clearPendingFullTextSearch()
            toolbarState.cancelLibraryFilterApplication()
            Task { await loadPage(reset: true) }
            LibraryFilterDebug.log("applyFilter.end", [
                "surface": "email",
                "mode": "sqlPagedDeferredCount",
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
            ])
            return
        }
        // §7: Check the LRU cache before kicking off the expensive Task pipeline.
        if let cached = session.cachedFilterResult(for: expression) {
            toolbarState.activeFilterResult = cached
            toolbarState.clearPendingFullTextSearch()
            toolbarState.cancelLibraryFilterApplication()
            Task { await loadPage(reset: true) }
            LibraryFilterDebug.log("applyFilter.end", [
                "surface": "email",
                "mode": "cached",
                "ids": cached.calibreIDs.count,
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
            ])
            return
        }
        let token = toolbarState.beginLibraryFilterApplication()
        let fulltextRules = expression.groups.flatMap(\.rules)
            .filter { $0.field == .fulltext && $0.isComplete }
        if let firstPendingRule = fulltextRules.first(where: { session.cachedFulltextIDs(for: $0.value) == nil }) {
            startPendingFilterFullText(rule: firstPendingRule, token: token)
            return
        }

        Task {
            let needsLiked = expression.groups
                .flatMap(\.rules).contains { $0.field == .isLiked }
            let currentLikedIDs = needsLiked ? ((try? await session.collectionStore?.likedIDs()) ?? []) : []
            let needsCollection = expression.groups
                .flatMap(\.rules).contains { $0.field == .collection }
            var collectionMap = needsCollection ? ((try? await session.collectionStore?.membershipMap()) ?? [:]) : [:]
            let statusValues = Set(expression.groups
                .flatMap(\.rules)
                .filter { $0.field == .status }
                .compactMap { AO3CompletionStatus(userValue: $0.value) })
            var statusMap: [AO3CompletionStatus: Set<Int>] = [:]
            if let metaDB = session.metaDB {
                for status in statusValues {
                    statusMap[status] = (try? await metaDB.ao3CompletionStatusIDs(status)) ?? []
                }
                if needsCollection && expression.referencesSeriesOrMergedCollection {
                    collectionMap[SystemCollectionID.seriesOrMergedName] = (try? await metaDB.leadsAtLeastOneSeriesIDs()) ?? []
                }
            }
            let fulltextMap = Dictionary(uniqueKeysWithValues: fulltextRules.map { rule in
                let key = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return (key, Set(session.cachedFulltextIDs(for: rule.value) ?? []))
            })

            // §6: Crossover map
            var crossoverMap: Set<Int> = []
            let needsCrossover = expression.groups.flatMap(\.rules).contains { $0.field == .crossover }
            if needsCrossover {
                crossoverMap = await library.crossoverBookIDs()
            }
            // §perf Fix 6: Two-pass word-count filter (mirrors BookGridItem).
            let needsWordCount = expression.groups.flatMap(\.rules).contains {
                $0.field == .wordCountGT || $0.field == .wordCountLT
            }
            let needsWordCountFallback = needsWordCount && CustomColumnConfig.shared.wordCountLabel == nil

            let expressionWithoutWordCount: FilterExpression = needsWordCountFallback ? {
                var stripped = expression
                stripped.groups = expression.groups.compactMap { group in
                    let rules = group.rules.filter {
                        $0.field != .wordCountGT && $0.field != .wordCountLT
                    }
                    guard !rules.isEmpty else { return nil }
                    return FilterGroup(rules: rules, conjunction: group.conjunction)
                }
                return stripped
            }() : expression

            let filterTagExpansions = await TagExpansionResolver.filterTagExpansions(
                for: expression, metaDB: session.metaDB
            )
            cachedFilterTagExpansions = filterTagExpansions
            let builder = FilterBuilder(library: library, ftsLibrary: session.ftsLibrary,
                                        tagExpansions: filterTagExpansions)

            let pass1Result = await builder.matchingIDs(
                expression: expressionWithoutWordCount,
                likedIDs:      currentLikedIDs,
                collectionMap: collectionMap,
                statusMap: statusMap,
                fulltextMap: fulltextMap,
                crossoverMap: crossoverMap,
                wordCountFallbackMap: nil
            )

            var result: FilterResult
            if needsWordCountFallback {
                let candidateIDs = pass1Result.calibreIDs
                let fallbackMap = await library.ao3WordCounts(ids: candidateIDs)
                var wcOnlyExpression = FilterExpression()
                wcOnlyExpression.groups = expression.groups.compactMap { group in
                    let rules = group.rules.filter {
                        ($0.field == .wordCountGT || $0.field == .wordCountLT) && $0.isComplete
                    }
                    guard !rules.isEmpty else { return nil }
                    return FilterGroup(rules: rules, conjunction: group.conjunction)
                }
                wcOnlyExpression.groupConjunction = expression.groupConjunction
                if wcOnlyExpression.hasCompleteRules {
                    let pass2Result = await builder.matchingIDs(
                        expression: wcOnlyExpression,
                        likedIDs: [],
                        collectionMap: [:],
                        statusMap: [:],
                        fulltextMap: [:],
                        crossoverMap: [],
                        wordCountFallbackMap: fallbackMap
                    )
                    let pass2Set = Set(pass2Result.calibreIDs)
                    let combined = candidateIDs.filter { pass2Set.contains($0) }
                    result = FilterResult(calibreIDs: combined, totalCount: combined.count)
                } else {
                    result = pass1Result
                }
            } else {
                result = pass1Result
            }
            let currentSkipped = Set((try? await session.collectionStore?.members(of: SystemCollectionID.skipped)) ?? [])
            let currentSeriesOrMerged = Set((try? await session.collectionStore?.members(of: SystemCollectionID.seriesOrMerged)) ?? [])
            let currentAO3PublisherIDs = await library.ao3PublisherBookIDs()
            let filteredIDs = ReaderPreferences.shared.showSkippedCollection
                ? result.calibreIDs
                : result.calibreIDs.filter { !currentSkipped.contains($0) }
            let visibleFilteredIDs = filteredIDs
                .filter { !currentSeriesOrMerged.contains($0) }
                .filter { !ReaderPreferences.shared.hideNonAO3PublisherBooks || currentAO3PublisherIDs.contains($0) }
            guard toolbarState.libraryFilterApplicationToken == token else { return }
            defer { toolbarState.finishLibraryFilterApplication(token: token) }
            let cacheableResult = FilterResult(
                calibreIDs: visibleFilteredIDs,
                totalCount: visibleFilteredIDs.count
            )
            toolbarState.activeFilterResult = cacheableResult
            session.rememberFilterResult(cacheableResult, for: expression)  // §7
            toolbarState.clearPendingFullTextSearch()
            likedIDs = currentLikedIDs
            skippedIDs = currentSkipped
            seriesOrMergedIDs = currentSeriesOrMerged
            ao3PublisherIDs = currentAO3PublisherIDs
            await loadPage(reset: true)
            LibraryFilterDebug.log("applyFilter.end", [
                "surface": "email",
                "mode": "explicitIDs",
                "ids": visibleFilteredIDs.count,
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
            ])
        }
    }

    private func startPendingSearchTextFullTextIfNeeded() -> Bool {
        guard let phrase = activeFullTextPhrase()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phrase.isEmpty else {
            toolbarState.clearPendingFullTextSearch()
            return false
        }
        if let cached = session.cachedFulltextIDs(for: phrase) {
            applyResolvedSearchTextFullText(phrase: phrase, ids: cached)
            return false
        }
        let token = UUID()
        let applicationToken = toolbarState.beginLibraryFilterApplication()
        toolbarState.pendingFullTextSearch = PendingFullTextSearch(token: token, phrase: phrase, source: .searchText)
        fullTextTask?.cancel()
        fullTextTask = Task {
            let ids = await session.resolveFulltextIDs(for: phrase)
            await MainActor.run {
                guard self.toolbarState.pendingFullTextSearch?.token == token,
                      self.toolbarState.libraryFilterApplicationToken == applicationToken,
                      self.activeFullTextPhrase()?.trimmingCharacters(in: .whitespacesAndNewlines) == phrase else { return }
                defer { self.toolbarState.finishLibraryFilterApplication(token: applicationToken) }
                self.applyResolvedSearchTextFullText(phrase: phrase, ids: ids)
            }
        }
        return true
    }

    private func startPendingFilterFullText(rule: FilterRule, token applicationToken: UUID) {
        let phrase = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else {
            toolbarState.finishLibraryFilterApplication(token: applicationToken)
            return
        }
        let token = UUID()
        toolbarState.pendingFullTextSearch = PendingFullTextSearch(token: token, phrase: phrase, source: .filterExpression)
        fullTextTask?.cancel()
        fullTextTask = Task {
            _ = await session.resolveFulltextIDs(for: phrase)
            await MainActor.run {
                guard self.toolbarState.pendingFullTextSearch?.token == token,
                      self.toolbarState.libraryFilterApplicationToken == applicationToken,
                      self.toolbarState.filterExpression.groups.flatMap(\.rules).contains(where: {
                          $0.field == .fulltext && $0.value == phrase && $0.isComplete
                      }) else { return }
                self.toolbarState.clearPendingFullTextSearch()
                self.toolbarState.finishLibraryFilterApplication(token: applicationToken)
                self.applyFilterRules()
            }
        }
    }

    private func applyResolvedSearchTextFullText(phrase: String, ids: [Int]) {
        guard activeFullTextPhrase()?.trimmingCharacters(in: .whitespacesAndNewlines) == phrase else { return }
        toolbarState.activeFilterResult = FilterResult(calibreIDs: ids, totalCount: ids.count)
        toolbarState.clearPendingFullTextSearch()
        Task { await loadPage(reset: true) }
    }

    private func scheduleDeferredSQLFilterCount(query: SearchQuery) {
        guard let library = session.library,
              let result = toolbarState.activeFilterResult,
              result.isSQLBacked,
              result.totalCount == nil else { return }
        let expression = toolbarState.filterExpression
        let filterSignature = LibraryFilterDebug.summary(expression: expression)
        let querySignature = LibraryFilterDebug.summary(query: query)
        filterCountTask?.cancel()
        LibraryFilterDebug.log("deferredCount.schedule", [
            "surface": "email",
            "mode": "sqlPagedDeferredCount",
            "query": querySignature,
            "filter": filterSignature
        ])
        filterCountTask = Task { [weak self] in
            let tagExpansions = self?.cachedFilterTagExpansions ?? [:]
            let count = await library.bookCount(query: query, filter: expression,
                                          filterTagExpansions: tagExpansions)
            await self?.session.refreshLastSearchError()
            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.toolbarState.activeFilterResult?.isSQLBacked == true,
                      self.toolbarState.activeFilterResult?.totalCount == nil,
                      LibraryFilterDebug.summary(expression: self.toolbarState.filterExpression) == filterSignature,
                      LibraryFilterDebug.summary(query: self.queryWithCachedFullText(self.toolbarState.searchText.isEmpty
                          ? SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
                          : SearchQueryParser.parse(self.toolbarState.searchText))) == querySignature else {
                    LibraryFilterDebug.log("deferredCount.discard", [
                        "surface": "email",
                        "mode": "sqlPagedDeferredCount"
                    ])
                    return
                }
                self.toolbarState.activeFilterResult = FilterResult(
                    calibreIDs: [],
                    totalCount: count,
                    isSQLBacked: true
                )
                LibraryFilterDebug.log("deferredCount.apply", [
                    "surface": "email",
                    "mode": "sqlPagedDeferredCount",
                    "count": count
                ])
            }
        }
    }

    // MARK: - Data loading (uses SearchQuery path — mirrors BookGridItem exactly)

    @MainActor
    func loadPage(reset: Bool) async {
        let loadStart = LibraryFilterDebug.now()
        guard let library = session.library else {
            books = []
            items = []
            ao3Metadata = [:]
            setSelectedBook(nil)
            sidebarVC?.books = []
            sidebarVC?.items = []
            sidebarVC?.ao3Metadata = [:]
            return
        }
        // Parse search text into a structured query — same path as list view
        let rawQuery = toolbarState.searchText.isEmpty
            ? SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
            : SearchQueryParser.parse(toolbarState.searchText)
        var query = queryWithCachedFullText(rawQuery)
        // Inject pre-resolved synonym expansions (Invariant 10 — mirrors LibraryRootView).
        query.expandedTagTerms = resolvedTagExpansions
        if rawQuery.fulltextPhrase?.isEmpty == false && query.ftsMatchedIDs == nil {
            _ = startPendingSearchTextFullTextIfNeeded()
            return
        }

        if reset {
            currentPage = 0
            rawSQLOffset = 0
            rawSQLOffsetHistory = []
            groupAwareOverflow = []
            books = []
            // §grouping-flash fix: clear items immediately on a fresh query so the
            // sidebar shows nothing rather than the previous query's stale rows while
            // rebuildSidebarItems' async Task (when grouping) is in flight. Mirrors
            // LibraryRootView's loadPage clearing items before rebuildItems().
            if shouldGroupSidebarRows {
                items = []
                sidebarVC?.items = []
            }
        }

        let raw: [CalibreBook]
        var wordCountPage: [CalibreBook]? = nil
        var wordCountHasMore = false
        // §grouping-pagination fix: when shouldGroupSidebarRows is true, the
        // sqlPagedDeferredCount and unfiltered branches below populate this directly
        // via a group-aware drain loop instead of relying on the shared raw/visibleBooks
        // computation after the if/else chain, which assumed pageFetchLimit raw rows
        // collapse to roughly pageSize visible rows — false once series grouping strips
        // most rows. nil means "use the shared raw-based path below" (ungrouped, or a
        // branch — explicitIDs, emptyExplicitIDs, random, wordCount — that already
        // computes its own page).
        var groupAwareVisible: [CalibreBook]? = nil
        if toolbarState.sortField == .random {
            let restrictIDs: [Int]?
            let filterForSQL: FilterExpression?
            var isEmptyExplicitIDs = false
            if let result = toolbarState.activeFilterResult, result.isSQLBacked {
                restrictIDs = nil
                filterForSQL = toolbarState.filterExpression
            } else if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
                restrictIDs = visibleIDs(intersect(result.calibreIDs, with: query.ftsMatchedIDs))
                filterForSQL = nil
            } else if toolbarState.activeFilterResult != nil {
                isEmptyExplicitIDs = true
                restrictIDs = nil
                filterForSQL = nil
            } else {
                restrictIDs = nil
                filterForSQL = nil
            }
            if isEmptyExplicitIDs {
                if reset { books = [] }
                hasNextPage = false
                rebuildSidebarItems()
                sidebarVC?.books = books
                sidebarVC?.items = items
                sidebarVC?.ao3Metadata = ao3Metadata
                sidebarVC?.likedIDs = likedIDs
                return
            }
            let (page, hasMore) = await library.randomSortedPage(
                offset: currentPage * pageSize, limit: pageSize,
                query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                filterTagExpansions: cachedFilterTagExpansions
            )
            if reset { books = page } else { books.append(contentsOf: page) }
            hasNextPage = hasMore
            rebuildSidebarItems()
            sidebarVC?.books = books
            sidebarVC?.bookStates = bookStates
            sidebarVC?.ao3Metadata = ao3Metadata
            sidebarVC?.likedIDs = likedIDs
            loadAO3MetadataForSidebarBooks()
            return
        } else if toolbarState.sortField == .wordCount {
            // §2a fix (2): see orderByClause(.wordCount) / wordCountSortedPage(...)
            // in CalibreLibrary.swift — word count can't be sorted via a single SQL
            // ORDER BY, so it's resolved in memory over the full matching set.
            let restrictIDs: [Int]?
            let filterForSQL: FilterExpression?
            var isEmptyExplicitIDs = false
            if let result = toolbarState.activeFilterResult, result.isSQLBacked {
                restrictIDs = nil
                filterForSQL = toolbarState.filterExpression
            } else if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
                restrictIDs = visibleIDs(intersect(result.calibreIDs, with: query.ftsMatchedIDs))
                filterForSQL = nil
            } else if toolbarState.activeFilterResult != nil {
                restrictIDs = nil
                filterForSQL = nil
                isEmptyExplicitIDs = true
            } else {
                restrictIDs = nil
                filterForSQL = nil
            }
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "email", "mode": "wordCountSorted", "page": currentPage,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            if isEmptyExplicitIDs {
                wordCountPage = []
                wordCountHasMore = false
            } else {
                let (page, hasMore) = await library.wordCountSortedPage(
                    offset: currentPage * pageSize, limit: pageSize, ascending: toolbarState.ascending,
                    query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                    filterTagExpansions: cachedFilterTagExpansions
                )
                wordCountPage = page
                wordCountHasMore = hasMore
            }
            raw = []
        } else if let result = toolbarState.activeFilterResult, result.isSQLBacked {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "email",
                "mode": "sqlPagedDeferredCount",
                "page": currentPage,
                "query": LibraryFilterDebug.summary(query: query),
                "filter": LibraryFilterDebug.summary(expression: toolbarState.filterExpression)
            ])
            if shouldGroupSidebarRows {
                var visible: [CalibreBook] = reset ? [] : groupAwareOverflow
                if !reset { groupAwareOverflow = [] }
                var offset = rawSQLOffset
                var exhausted = false
                var totalRawFetched = 0
                var iterations = 0
                let maxIterations = 40
                while visible.count < pageSize && iterations < maxIterations {
                    iterations += 1
                    let rawChunk = await library.books(
                        offset: offset, limit: pageFetchLimit,
                        sort: toolbarState.sortField, ascending: toolbarState.ascending,
                        query: query,
                        filter: toolbarState.filterExpression,
                        filterTagExpansions: cachedFilterTagExpansions
                    )
                    LibraryFilterDebug.log("visibleBooks.fetch", [
                        "surface": "email", "offset": offset, "raw": rawChunk.count
                    ])
                    totalRawFetched += rawChunk.count
                    offset += rawChunk.count
                    visible.append(contentsOf: visibleBooks(rawChunk))
                    if rawChunk.count < pageFetchLimit { exhausted = true; break }
                }
                rawSQLOffsetHistory.append(rawSQLOffset)
                rawSQLOffset = offset
                groupAwareVisible = visible
                hasNextPage = !exhausted || visible.count > pageSize
                LibraryFilterDebug.log("visibleBooks.end", [
                    "surface": "email",
                    "rawFetched": totalRawFetched,
                    "visibleAfterFilter": visible.count,
                    "shouldGroup": true,
                    "exhausted": exhausted
                ])
                raw = []
            } else {
                raw = await library.books(
                    offset: currentPage * pageSize, limit: pageFetchLimit,
                    sort: toolbarState.sortField, ascending: toolbarState.ascending,
                    query: query,
                    filter: toolbarState.filterExpression,
                    filterTagExpansions: cachedFilterTagExpansions
                )
            }
            scheduleDeferredSQLFilterCount(query: query)
        } else if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "email",
                "mode": "explicitIDs",
                "page": currentPage,
                "candidateIDs": result.calibreIDs.count,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            let ids = visibleIDs(intersect(result.calibreIDs, with: query.ftsMatchedIDs))
            raw = await library.books(
                ids: ids,
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query
            )
        } else if toolbarState.activeFilterResult != nil {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "email",
                "mode": "emptyExplicitIDs",
                "page": currentPage
            ])
            raw = []
        } else {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "email",
                "mode": "unfiltered",
                "page": currentPage,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            if shouldGroupSidebarRows {
                var visible: [CalibreBook] = reset ? [] : groupAwareOverflow
                if !reset { groupAwareOverflow = [] }
                var offset = rawSQLOffset
                var exhausted = false
                var totalRawFetched = 0
                var iterations = 0
                let maxIterations = 40
                while visible.count < pageSize && iterations < maxIterations {
                    iterations += 1
                    let rawChunk = await library.books(
                        offset: offset, limit: pageFetchLimit,
                        sort: toolbarState.sortField, ascending: toolbarState.ascending,
                        query: query
                    )
                    LibraryFilterDebug.log("visibleBooks.fetch", [
                        "surface": "email", "offset": offset, "raw": rawChunk.count
                    ])
                    totalRawFetched += rawChunk.count
                    offset += rawChunk.count
                    visible.append(contentsOf: visibleBooks(rawChunk))
                    if rawChunk.count < pageFetchLimit { exhausted = true; break }
                }
                rawSQLOffsetHistory.append(rawSQLOffset)
                rawSQLOffset = offset
                groupAwareVisible = visible
                hasNextPage = !exhausted || visible.count > pageSize
                LibraryFilterDebug.log("visibleBooks.end", [
                    "surface": "email",
                    "rawFetched": totalRawFetched,
                    "visibleAfterFilter": visible.count,
                    "shouldGroup": true,
                    "exhausted": exhausted
                ])
                raw = []
            } else {
                raw = await library.books(
                    offset: currentPage * pageSize, limit: pageFetchLimit,
                    sort: toolbarState.sortField, ascending: toolbarState.ascending,
                    query: query
                )
            }
        }

        let page: [CalibreBook]
        if let wordCountPage {
            hasNextPage = wordCountHasMore
            page = wordCountPage
        } else if let groupAwareVisible {
            // hasNextPage was already set by the group-aware drain loop above.
            page = Array(groupAwareVisible.prefix(pageSize))
            groupAwareOverflow = Array(groupAwareVisible.dropFirst(pageSize))
            LibraryFilterDebug.log("visibleBooks.pagePrefix", [
                "surface": "email",
                "visible": groupAwareVisible.count,
                "page": page.count,
                "overflow": groupAwareOverflow.count
            ])
        } else {
            let visible = visibleBooks(raw)
            hasNextPage = raw.count == pageFetchLimit || visible.count > pageSize
            page = Array(visible.prefix(pageSize))
            LibraryFilterDebug.log("visibleBooks.end", [
                "surface": "email",
                "raw": raw.count,
                "visibleAfterFilter": visible.count,
                "page": page.count,
                "seriesOrMergedStripped": raw.count - visible.count,
                "shouldGroup": false
            ])
        }
        if reset { books = page } else { books.append(contentsOf: page) }

        rebuildSidebarItems()
        sidebarVC?.books      = books
        sidebarVC?.bookStates = bookStates
        sidebarVC?.ao3Metadata = ao3Metadata
        sidebarVC?.likedIDs = likedIDs
        sidebarVC?.readLaterIDs = readLaterIDs
        loadAO3MetadataForSidebarBooks()
        LibraryFilterDebug.log("loadPage.end", [
            "surface": "email",
            "rows": books.count,
            "pageRows": page.count,
            "hasNext": hasNextPage,
            "elapsedMS": LibraryFilterDebug.elapsedMS(since: loadStart)
        ])

        // Log to activity feed — only on reset (new query), not pagination.
        if reset {
            let expr = toolbarState.filterExpression.hasCompleteRules
                ? toolbarState.filterExpression : nil
            SearchActivityLog.shared.append(
                searchText: toolbarState.searchText,
                filterExpression: expr,
                resultCount: books.count
            )
        }
    }

    private func queryWithCachedFullText(_ query: SearchQuery) -> SearchQuery {
        guard let phrase = query.fulltextPhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phrase.isEmpty else { return query }
        guard let ids = session.cachedFulltextIDs(for: phrase) else { return query }
        return SearchQuery(
            tagTerms: query.tagTerms,
            authorTerms: query.authorTerms,
            titleTerms: query.titleTerms,
            seriesTerms: query.seriesTerms,
            statusTerms: query.statusTerms,
            fulltextPhrase: query.fulltextPhrase,
            plainTerms: [],
            ftsMatchedIDs: ids
        )
    }

    /// Mirrors `LibraryRootView.resolveTagExpansionsIfNeeded`. See that method for rationale.
    private func resolveTagExpansionsIfNeeded(terms: [String]) {
        guard !terms.isEmpty, let metaDB = session.metaDB else {
            resolvedTagExpansions = [:]
            return
        }
        Task { @MainActor [weak self] in
            guard let self, !self.isTornDown else { return }
            let resolved = await TagExpansionResolver.resolvedTagExpansions(for: terms, metaDB: metaDB)
            self.resolvedTagExpansions = resolved
            await self.loadPage(reset: false)
        }
    }

    private func rebuildSidebarItems() {
        guard shouldGroupSidebarRows,
              let metaDB = session.metaDB,
              let library = session.library else {
            LibraryFilterDebug.log("rebuildSidebarItems.ungrouped", [
                "surface": "email",
                "books": books.count,
                "reason": shouldGroupSidebarRows ? "noMetaDB" : "groupingOff"
            ])
            items = books.map { .book($0) }
            sidebarVC?.items = items
            return
        }

        // §grouping-flash fix: do NOT pre-assign items = books.map(.book) here — see
        // the matching comment in LibraryRootView.rebuildItems. loadPage(reset:) clears
        // items to [] on a fresh query so ungrouped works are never shown.
        let pageBooks = books
        LibraryFilterDebug.log("rebuildSidebarItems.start", [
            "surface": "email",
            "pageBooks": pageBooks.count
        ])
        // Cancel any in-flight task before starting a new one. CalibreLibrary is
        // actor-isolated, so overlapping calls to library.booksForIDs from rapid
        // search changes now serialize safely rather than crash — but without this
        // cancellation, a slow stale task could still finish after a newer one and
        // overwrite `items` with out-of-date results.
        rebuildSidebarTask?.cancel()
        rebuildSidebarTask = Task {
            let pageIDs = pageBooks.map(\.id)
            guard !Task.isCancelled else { return }
            let entries = (try? await metaDB.seriesEntries(for: pageIDs)) ?? []
            let groupedEntries = Dictionary(grouping: entries.filter { !$0.isAnthology }, by: \.seriesKey)
            let seriesKeys = groupedEntries.keys.sorted()
            guard !Task.isCancelled else { return }
            let allEntries = (try? await metaDB.seriesEntries(keys: seriesKeys)) ?? []
            let allIDs = Array(Set(allEntries.map(\.calibreID)))
            guard !Task.isCancelled else { return }
            // CalibreLibrary is actor-isolated now: this await serializes automatically
            // with loadPage(reset:)'s page-fetch calls and any other in-flight query
            // against the same library. The SQLITE_BUSY race this MainActor hop used
            // to guard against is no longer possible — the actor itself is
            // CalibreLibrary.db's only access path. See the matching fix in
            // LibraryRootView.rebuildItems.
            let allBooks = await library.booksForIDs(allIDs)
            guard !Task.isCancelled else { return }
            let metadata = (try? await metaDB.ao3Metadata(for: allIDs)) ?? [:]
            guard !Task.isCancelled else { return }
            let placeholders = (try? await metaDB.placeholders(for: seriesKeys)) ?? [:]
            let byID = Dictionary(uniqueKeysWithValues: allBooks.map { ($0.id, $0) })
            let entriesBySeries = Dictionary(grouping: allEntries.filter { !$0.isAnthology }, by: \.seriesKey)
            var groups: [String: SeriesGroup] = [:]

            for (seriesKey, entries) in entriesBySeries {
                let sortedEntries = sortedSeriesEntries(entries)
                let works = sortedEntries.compactMap { byID[$0.calibreID] }
                guard works.count > 1, works.allSatisfy({ !($0.isDescriptionAnthology) }) else { continue }
                let seriesMetadata = works.compactMap { metadata[$0.id] }
                let chapterRecords = seriesMetadata.filter { $0.chapterCurrent != nil }
                let chapterTotalKnownForAll = !chapterRecords.isEmpty && chapterRecords.count == works.count && chapterRecords.allSatisfy { $0.chapterTotal != nil }
                let indices = sortedEntries.map(\.seriesIndex)
                let ratings = Array(Set(works.flatMap(\.tags).filter { if case .rating = AO3TagKind.classify($0) { return true }; return false })).sorted()
                let warnings = Array(Set(works.flatMap(\.tags).filter { if case .warning = AO3TagKind.classify($0) { return true }; return false })).sorted()
                let categories = Array(Set(seriesMetadata.flatMap(\.categories) + works.flatMap(\.tags).filter { if case .category = AO3TagKind.classify($0) { return true }; return false })).sorted()
                let fandoms = Array(Set(seriesMetadata.flatMap(\.fandoms))).sorted()
                let relationships = Array(Set(seriesMetadata.flatMap(\.relationships))).sorted()
                let characters = Array(Set(seriesMetadata.flatMap(\.characters))).sorted()
                let additionalTags = Array(Set(seriesMetadata.flatMap(\.additionalTags))).sorted()
                groups[seriesKey] = SeriesGroup(
                    id: seriesKey,
                    seriesKey: seriesKey,
                    seriesName: sortedEntries.first?.seriesName ?? seriesKey,
                    works: sortedSeriesWorks(works, using: sortedEntries),
                    allFandoms: fandoms,
                    allRelationships: relationships,
                    allCharacters: characters,
                    allCategories: categories,
                    allWarnings: warnings,
                    allRatings: ratings,
                    allAdditionalTags: additionalTags,
                    allTags: Array(Set(works.flatMap(\.tags) + additionalTags)).sorted(),
                    allAuthors: Array(Set(works.flatMap(\.authors))).sorted(),
                    allDescriptions: works.compactMap(\.displayComment),
                    totalWordCount: works.reduce(0) { $0 + (metadata[$1.id]?.wordCount ?? $1.wordCount ?? 0) },
                    chapterCurrentTotal: chapterRecords.isEmpty ? nil : chapterRecords.reduce(0) { $0 + ($1.chapterCurrent ?? 0) },
                    chapterTotalTotal: chapterTotalKnownForAll ? chapterRecords.reduce(0) { $0 + ($1.chapterTotal ?? 0) } : nil,
                    hasUnknownChapterTotal: !chapterRecords.isEmpty && !chapterTotalKnownForAll,
                    earliestPublished: seriesMetadata.compactMap { parseISODate($0.publishedDate) }.min(),
                    latestUpdated: seriesMetadata.compactMap { parseISODate($0.updatedDate) }.max(),
                    workIndices: indices,
                    missingIndices: missingIndices(in: indices),
                    placeholders: placeholders[seriesKey] ?? [],
                    isComplete: !seriesMetadata.isEmpty && seriesMetadata.allSatisfy(\.isComplete)
                )
            }

            // Build collapsedIDs so books subsumed into an emitted series row are not
            // also emitted as standalone .book rows. Mirrors rebuildItems in LibraryRootView.
            let collapsedIDs = Set(groups.values.flatMap { $0.works.map(\.id) })
            let nextItems = assignSeriesItems(
                pageBooks: pageBooks,
                entries: entries,
                seriesByKey: groups,
                collapsedIDs: collapsedIDs
            )
            await MainActor.run {
                guard self.books.map(\.id) == pageBooks.map(\.id) else {
                    LibraryFilterDebug.log("rebuildSidebarItems.stale", [
                        "surface": "email",
                        "pageBooks": pageBooks.count,
                        "currentBooks": self.books.count
                    ])
                    return
                }
                self.items = nextItems
                self.sidebarVC?.items = nextItems
                LibraryFilterDebug.log("rebuildSidebarItems.end", [
                    "surface": "email",
                    "pageBooks": pageBooks.count,
                    "groups": groups.count,
                    "collapsedIDs": collapsedIDs.count,
                    "items": nextItems.count,
                    "series": nextItems.filter { if case .series = $0 { return true }; return false }.count,
                    "singletons": nextItems.filter { if case .book = $0 { return true }; return false }.count
                ])
            }
        }
    }

    private func loadAO3MetadataForSidebarBooks() {
        let ids = books.map(\.id)
        guard !ids.isEmpty, let metaDB = session.metaDB else {
            ao3Metadata = [:]
            sidebarVC?.ao3Metadata = [:]
            return
        }

        Task {
            let metadata = (try? await metaDB.ao3Metadata(for: ids)) ?? [:]
            await MainActor.run {
                let currentIDs = Set(self.books.map(\.id))
                guard currentIDs == Set(ids) else { return }
                self.ao3Metadata = metadata
                self.sidebarVC?.ao3Metadata = metadata
            }
        }
    }

    /// Mirrors LibraryRootView.shouldGroupSeriesRows: grouping is active either because
    /// the user has the groupBySeries toggle on, or because a "Series or Merged" filter
    /// rule is committed (which always implies grouping regardless of the toggle).
    private var shouldGroupSidebarRows: Bool {
        toolbarState.groupBySeries || toolbarState.filterExpression.hasSeriesOrMergedEqualsRule
    }

    private func visibleIDs(_ ids: [Int]) -> [Int] {
        // Only suppress seriesOrMergedIDs members when series grouping is active and a
        // SeriesGroup row is being shown for them. Without grouping the suppression
        // silently deletes books that are rn>1 in one series but rn=1 (representative)
        // in another — e.g. all works in "Star Wars Drabbles" become invisible because
        // they are also members of "100 Star Wars Women Drabbles".
        ids.filter { id in
            (ReaderPreferences.shared.showSkippedCollection || !skippedIDs.contains(id)) &&
            (!shouldGroupSidebarRows || !seriesOrMergedIDs.contains(id)) &&
            (!ReaderPreferences.shared.hideNonAO3PublisherBooks || ao3PublisherIDs.contains(id))
        }
    }

    private func intersect(_ ids: [Int], with optionalIDs: [Int]?) -> [Int] {
        guard let other = optionalIDs else { return ids }
        let allowed = Set(other)
        return ids.filter { allowed.contains($0) }
    }

    private func visibleBooks(_ raw: [CalibreBook]) -> [CalibreBook] {
        raw.filter { book in
            (ReaderPreferences.shared.showSkippedCollection || !skippedIDs.contains(book.id)) &&
            (!shouldGroupSidebarRows || !seriesOrMergedIDs.contains(book.id)) &&
            (!ReaderPreferences.shared.hideNonAO3PublisherBooks || book.isAO3PublisherBook) &&
            !book.isDescriptionAnthology
        }
    }

    private func loadNextPageIfAvailable() {
        guard hasNextPage else { return }
        currentPage += 1
        Task { await loadPage(reset: false) }
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

    private func toggleReadLater(for book: CalibreBook) {
        let isCurrentlyInReadLater = readLaterIDs.contains(book.id)
        Task {
            if isCurrentlyInReadLater {
                try? await session.collectionStore?.remove(calibreID: book.id, from: SystemCollectionID.readLater)
            } else {
                try? await session.collectionStore?.bulkAdd(calibreIDs: [book.id], to: SystemCollectionID.readLater)
            }
            session.bumpMembershipVersion()
            await refreshCollectionSnapshots()
        }
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
            session.bumpMembershipVersion()  // §7
            refreshBookStates()
            await loadPage(reset: true)
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
            session.bumpMembershipVersion()  // §7
            refreshBookStates()
            await loadPage(reset: true)
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
        let currentSeriesOrMerged = membershipByID[SystemCollectionID.seriesOrMerged] ?? []
        let currentAO3PublisherIDs = await session.library?.ao3PublisherBookIDs() ?? []
        collectionMembership = Dictionary(uniqueKeysWithValues: collections.map { collection in
            return (collection.name, membershipByID[collection.id] ?? [])
        })
        likedIDs = (try? await session.collectionStore?.likedIDs()) ?? []
        readLaterIDs = Set((try? await session.collectionStore?.members(of: SystemCollectionID.readLater)) ?? [])
        let shouldReloadPage = skippedIDs != currentSkipped || seriesOrMergedIDs != currentSeriesOrMerged || ao3PublisherIDs != currentAO3PublisherIDs
        skippedIDs = currentSkipped
        seriesOrMergedIDs = currentSeriesOrMerged
        ao3PublisherIDs = currentAO3PublisherIDs
        sidebarVC?.collectionMembership = collectionMembership
        sidebarVC?.likedIDs = likedIDs
        sidebarVC?.readLaterIDs = readLaterIDs
        if shouldReloadPage {
            await loadPage(reset: true)
        }
    }

    // MARK: - Inline reader pane

    private func setSelectedBook(_ book: CalibreBook?) {
        if selectedBook == nil, book == nil {
            return
        }
        if let selectedBook, let book,
           selectedBook.id == book.id,
           let currentReaderVC,
           currentReaderVC.book.id == book.id {
            return
        }
        selectedBook = book
        updateReaderPane()
    }

    private func updateReaderPane() {
        readerLocalFindState = LocalReaderFindState()
        lastAppliedFullTextPhrase = ""
        lastAppliedFullTextReader = nil
        pendingFullTextPhrase = activeFullTextPhrase()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        readerAnnotations = []
        currentReaderVC = nil
        replaceRightPane(with: makeRightVC())
        refreshReaderSidebar()
    }

    private func makeRightVC() -> NSViewController {
        guard let book = selectedBook else { return makePlaceholderVC() }
        let rvc = ReaderViewController(book: book, modelContainer: modelContainer)
        currentReaderVC = rvc
        rvc.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        rvc.onReadingProgressChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshBookStates()
            }
        }
        rvc.onAnnotationsChanged = { [weak self] annotations in
            DispatchQueue.main.async {
                self?.readerAnnotations = annotations
                self?.refreshReaderSidebar()
            }
        }
        rvc.onLocalFindStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.readerLocalFindState = state
                self?.refreshReaderSidebar()
            }
        }
        rvc.onOpenSearchSidebar = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshReaderSidebar()
            }
        }
        rvc.onReaderContentReady = { [weak self, weak rvc] in
            DispatchQueue.main.async {
                guard let self, let rvc, self.currentReaderVC === rvc else { return }
                self.applyFullTextPhraseToLocalFind(reader: rvc, allowDeferred: false)
            }
        }
        readerLocalFindState = rvc.currentLocalFindState()
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
        let sidebarThickness = currentSidebarThickness()
        let oldItem = readerPaneItem
        let oldVC = oldItem?.viewController
        if let oldItem, splitVC.splitViewItems.contains(oldItem) {
            splitVC.removeSplitViewItem(oldItem)
        }
        splitVC.addChild(vc)
        vc.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        let item = NSSplitViewItem(viewController: vc)
        item.minimumThickness = 420
        item.canCollapse = false
        readerPaneItem = item
        // The reader pane is always at index 2: [library(0) | annotations(1) | reader(2)].
        // annotationsSidebarItem is never removed, so after removing the old readerPaneItem
        // the array always has exactly 2 items. Appending places it correctly at index 2.
        splitVC.addSplitViewItem(item)
        oldVC?.removeFromParent()
        restoreSidebarThickness(sidebarThickness)
    }

    private var readerSidebarMode: EmailReaderSidebarMode = .annotations

    private func makeReaderSidebarVC() -> NSViewController {
        let vc = NSHostingController(rootView: makeReaderSidebarView())
        readerSidebarHostingVC = vc
        return vc
    }

    private func makeReaderSidebarView() -> EmailReaderSidebarView {
        EmailReaderSidebarView(
            mode: readerSidebarMode,
            annotations: readerAnnotations,
            onJumpToAnnotation: { [weak self] annotation in
                self?.currentReaderVC?.jumpToAnnotation(annotation)
            },
            onDeleteAnnotation: { [weak self] id in
                self?.currentReaderVC?.deleteAnnotationFromSidebar(id: id)
            },
            tocEntries: currentReaderVC?.globalTOCEntries ?? [],
            currentSpineIndex: currentReaderVC?.currentSpineIndexValue ?? 0,
            onJumpToTOCEntry: { [weak self] entry in
                self?.currentReaderVC?.jumpToTOCEntry(entry)
            }
        )
    }

    private func refreshReaderSidebar() {
        readerSidebarHostingVC?.rootView = makeReaderSidebarView()
    }

    private func activeFullTextPhrase() -> String? {
        if let phrase = SearchQueryParser.parse(toolbarState.searchText).fulltextPhrase,
           !phrase.isEmpty {
            return phrase
        }
        return toolbarState.filterExpression.groups
            .flatMap(\.rules)
            .first { $0.field == .fulltext && $0.op == .contains && $0.isComplete }?
            .value
    }

    private func applyFullTextPhraseToLocalFind(reader: ReaderViewController? = nil, allowDeferred: Bool = true) {
        let phrase = activeFullTextPhrase() ?? ""
        let targetReader = reader ?? currentReaderVC
        guard let targetReader else { return }
        pendingFullTextPhrase = phrase
        guard targetReader.isReaderContentReady else {
            if !phrase.isEmpty && allowDeferred { return }
            if phrase.isEmpty,
               lastAppliedFullTextReader === targetReader,
               !lastAppliedFullTextPhrase.isEmpty {
                targetReader.setLocalFindText("")
                lastAppliedFullTextPhrase = ""
                lastAppliedFullTextReader = nil
            }
            return
        }
        if phrase.isEmpty {
            if lastAppliedFullTextReader === targetReader, !lastAppliedFullTextPhrase.isEmpty {
                targetReader.setLocalFindText("")
            }
        } else {
            targetReader.showLocalFind()
            targetReader.setLocalFindText(phrase)
        }
        lastAppliedFullTextPhrase = phrase
        lastAppliedFullTextReader = phrase.isEmpty ? nil : targetReader
        pendingFullTextPhrase = ""
        readerLocalFindState = targetReader.currentLocalFindState()
    }

    @objc func performReaderSidebarToggle() {
        setReaderSidebarVisible(!(annotationsSidebarItem?.isCollapsed ?? true))
    }

    private func setReaderSidebarVisible(_ visible: Bool) {
        guard let item = annotationsSidebarItem else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            item.isCollapsed = !visible
            splitVC.splitView.layoutSubtreeIfNeeded()
        }
        repairReaderSplitItems()
        toolbarState.isEmailReaderSidebarVisible = visible
    }

    @objc func showEmailAnnotationSidebar(_ sender: Any?) {
        readerSidebarMode = .annotations
        refreshReaderSidebar()
        setReaderSidebarVisible(true)
    }

    @objc func showTOCInEmailSidebar(_ sender: Any?) {
        readerSidebarMode = .tableOfContents
        refreshReaderSidebar()
        setReaderSidebarVisible(true)
    }

    private func currentSidebarThickness() -> CGFloat {
        guard let sidebarView = librarySidebarItem?.viewController.view,
              !sidebarView.isHidden,
              sidebarView.frame.width > 0 else {
            return lastSidebarThickness
        }
        lastSidebarThickness = sidebarView.frame.width
        return sidebarView.frame.width
    }

    private func rememberSidebarThickness() {
        _ = currentSidebarThickness()
    }

    private func restoreSidebarThickness(_ thickness: CGFloat) {
        guard let librarySidebarItem,
              !librarySidebarItem.isCollapsed else { return }
        let clamped = min(max(thickness, librarySidebarItem.minimumThickness), librarySidebarItem.maximumThickness)
        lastSidebarThickness = clamped
        splitVC.splitView.setPosition(clamped, ofDividerAt: 0)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.librarySidebarItem.isCollapsed else { return }
            self.splitVC.splitView.setPosition(clamped, ofDividerAt: 0)
            self.repairReaderSplitItems()
        }
    }

    private func repairReaderSplitItems() {
        guard let readerPaneItem, let annotationsSidebarItem else { return }
        readerPaneItem.isCollapsed = false
        readerPaneItem.canCollapse = false
        readerPaneItem.minimumThickness = 420

        annotationsSidebarItem.minimumThickness = 240
        annotationsSidebarItem.maximumThickness = 360
        annotationsSidebarItem.preferredThicknessFraction = 0.24

        // Split order is fixed: [library | annotations | reader].
        // The divider between annotations and reader is always the last divider
        // (splitViewItems.count - 2), whether or not library is collapsed.
        // Position it so the annotations pane gets its desired width from the right.
        guard splitVC.view.window != nil,
              !annotationsSidebarItem.isCollapsed,
              splitVC.splitView.bounds.width > 0 else { return }

        let splitWidth = splitVC.splitView.bounds.width
        let desiredAnnotationsWidth: CGFloat = 300
        let annotationsWidth = min(
            max(desiredAnnotationsWidth, annotationsSidebarItem.minimumThickness),
            annotationsSidebarItem.maximumThickness
        )
        let dividerIndex = splitVC.splitViewItems.count - 2
        guard dividerIndex >= 0 else { return }
        splitVC.splitView.setPosition(splitWidth - annotationsWidth, ofDividerAt: dividerIndex)
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
                    onApply: {
                        emailVC?.applyFilterRules()
                    },
                    onClear: {
                        toolbarState.filterExpression   = FilterExpression()
                        toolbarState.activeFilterResult = nil
                        toolbarState.cancelLibraryFilterApplication()
                        Task { await emailVC?.loadPage(reset: true) }
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
                        ExportManager.presentExportPanel(         // §1
                            books: books,
                            session: emailVC?.session,
                            filterResult: emailVC?.toolbarState.activeFilterResult,
                            toolbarState: emailVC?.toolbarState
                        )
                    }
                    toolbarState.triggerExport = false
                }
            }
            .onChange(of: toolbarState.triggerEPUBExport) {
                if toolbarState.triggerEPUBExport {
                    if let books = emailVC?.currentBooks,
                       let session = emailVC?.session,
                       let libraryRoot = session.library?.root {
                        let capturedToolbarState = emailVC?.toolbarState
                        Task {
                            let rows = await ExportManager.buildExportRows(
                                currentPageBooks: books,
                                session: session,
                                filterResult: capturedToolbarState?.activeFilterResult,
                                toolbarState: capturedToolbarState
                            )
                            let ao3Map = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                                row.ao3.map { (row.book.id, $0) }
                            })
                            ExportManager.presentEPUBExportPanel(
                                books: rows.map(\.book),
                                libraryRoot: libraryRoot,
                                ao3Map: ao3Map,
                                groupBySeries: capturedToolbarState?.groupBySeries ?? false
                            )
                        }
                    }
                    toolbarState.triggerEPUBExport = false
                }
            }
    }
}
