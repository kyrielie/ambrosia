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
    private var skippedIDs: Set<Int> = []
    private var seriesOrMergedIDs: Set<Int> = []
    private var ao3PublisherIDs: Set<Int> = []
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
    private var lastSidebarToggle: Bool  = false
    private var lastReaderSidebarToggle: Bool = false
    private var lastReaderSidebarShow: Bool = false

    private let debouncer = DebounceTimer(delay: 0.4)

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
        refreshBookStates()
        refreshCollections()
        if toolbarState.filterExpression.hasCompleteRules {
            applyFilterRules()
        } else {
            loadPage(reset: true)
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
                    loadPage(reset: true)
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
        sidebarVC.onToggleLiked = { [weak self] book in
            guard let self else { return }
            Task {
                try? await self.session.collectionStore?.toggleLiked(calibreID: book.id)
                await self.refreshCollectionSnapshots()
            }
        }
        sidebarVC.onContextMenuReadLater = { [weak self] books in
            guard let self else { return }
            Task {
                try? await self.session.collectionStore?.bulkAdd(calibreIDs: books.map(\.id), to: SystemCollectionID.readLater)
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

        splitVC.addSplitViewItem(librarySidebarItem)
        splitVC.addSplitViewItem(readerPaneItem)
        splitVC.addSplitViewItem(annotationsSidebarItem)

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
        withObservationTracking {
            _ = toolbarState.searchText
            _ = toolbarState.sortField
            _ = toolbarState.ascending
            _ = toolbarState.activeFilterResult?.calibreIDs
            _ = toolbarState.toggleEmailSidebar
            _ = toolbarState.toggleEmailReaderSidebar
            _ = toolbarState.showEmailReaderSidebar
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.toolbarStateDidChange()
                self?.scheduleObservation()
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
        if toolbarState.showEmailReaderSidebar != lastReaderSidebarShow {
            lastReaderSidebarShow = toolbarState.showEmailReaderSidebar
            showReaderSidebar()
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
            applyFullTextPhraseToLocalFind()
            refreshReaderSidebar()
            debouncer.schedule { [weak self] in self?.loadPage(reset: true) }
        } else {
            applyFullTextPhraseToLocalFind()
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
            var collectionMap = needsCollection ? ((try? await session.collectionStore?.membershipMap()) ?? [:]) : [:]
            let statusValues = Set(toolbarState.filterExpression.groups
                .flatMap(\.rules)
                .filter { $0.field == .status }
                .compactMap { AO3CompletionStatus(userValue: $0.value) })
            var statusMap: [AO3CompletionStatus: Set<Int>] = [:]
            if let metaDB = session.metaDB {
                for status in statusValues {
                    statusMap[status] = (try? await metaDB.ao3CompletionStatusIDs(status)) ?? []
                }
                if needsCollection && toolbarState.filterExpression.referencesSeriesOrMergedCollection {
                    collectionMap[SystemCollectionID.seriesOrMergedName] = (try? await metaDB.collapsedSeriesRepresentativeIDs()) ?? []
                }
            }

            let builder = FilterBuilder(library: library, ftsLibrary: session.ftsLibrary)
            let result = builder.matchingIDs(
                expression: toolbarState.filterExpression,
                likedIDs:      currentLikedIDs,
                collectionMap: collectionMap,
                statusMap: statusMap
            )
            let currentSkipped = Set((try? await session.collectionStore?.members(of: SystemCollectionID.skipped)) ?? [])
            let currentSeriesOrMerged = Set((try? await session.collectionStore?.members(of: SystemCollectionID.seriesOrMerged)) ?? [])
            let currentAO3PublisherIDs = library.ao3PublisherBookIDs()
            let filteredIDs = ReaderPreferences.shared.showSkippedCollection
                ? result.calibreIDs
                : result.calibreIDs.filter { !currentSkipped.contains($0) }
            let visibleFilteredIDs = filteredIDs
                .filter { !currentSeriesOrMerged.contains($0) }
                .filter { !ReaderPreferences.shared.hideNonAO3PublisherBooks || currentAO3PublisherIDs.contains($0) }
            toolbarState.activeFilterResult = FilterResult(
                calibreIDs: visibleFilteredIDs,
                totalCount: visibleFilteredIDs.count
            )
            likedIDs = currentLikedIDs
            skippedIDs = currentSkipped
            seriesOrMergedIDs = currentSeriesOrMerged
            ao3PublisherIDs = currentAO3PublisherIDs
            loadPage(reset: true)
        }
    }

    // MARK: - Data loading (uses SearchQuery path — mirrors BookGridItem exactly)

    func loadPage(reset: Bool) {
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
        if reset { currentPage = 0; books = [] }

        // Parse search text into a structured query — same path as list view
        let rawQuery = toolbarState.searchText.isEmpty
            ? SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
            : SearchQueryParser.parse(toolbarState.searchText)
        let query = session.resolvedQuery(rawQuery)

        let raw: [CalibreBook]
        if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            let ids = visibleIDs(intersect(result.calibreIDs, with: query.ftsMatchedIDs))
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

        rebuildSidebarItems()
        sidebarVC?.books      = books
        sidebarVC?.bookStates = bookStates
        sidebarVC?.ao3Metadata = ao3Metadata
        sidebarVC?.likedIDs = likedIDs
        loadAO3MetadataForSidebarBooks()
    }

    private func rebuildSidebarItems() {
        guard toolbarState.filterExpression.hasSeriesOrMergedEqualsRule,
              let metaDB = session.metaDB,
              let library = session.library else {
            items = books.map { .book($0) }
            sidebarVC?.items = items
            return
        }

        let pageBooks = books
        Task {
            let pageIDs = pageBooks.map(\.id)
            let entries = (try? await metaDB.seriesEntries(for: pageIDs)) ?? []
            let groupedEntries = Dictionary(grouping: entries.filter { !$0.isAnthology }, by: \.seriesKey)
            let seriesKeys = groupedEntries.keys.sorted()
            let allEntries = (try? await metaDB.seriesEntries(keys: seriesKeys)) ?? []
            let allIDs = Array(Set(allEntries.map(\.calibreID)))
            let allBooks = library.booksForIDs(allIDs)
            let metadata = (try? await metaDB.ao3Metadata(for: allIDs)) ?? [:]
            let placeholders = (try? await metaDB.placeholders(for: seriesKeys)) ?? [:]
            let byID = Dictionary(uniqueKeysWithValues: allBooks.map { ($0.id, $0) })
            let entriesBySeries = Dictionary(grouping: allEntries.filter { !$0.isAnthology }, by: \.seriesKey)
            var groups: [String: SeriesGroup] = [:]

            for (seriesKey, entries) in entriesBySeries {
                let sortedEntries = entries.sorted { $0.seriesIndex < $1.seriesIndex }
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
                    works: works.sorted { left, right in
                        (sortedEntries.first { $0.calibreID == left.id }?.seriesIndex ?? 0) <
                        (sortedEntries.first { $0.calibreID == right.id }?.seriesIndex ?? 0)
                    },
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

            var nextItems: [LibraryItem] = []
            for book in pageBooks {
                if let entry = entries.first(where: { $0.calibreID == book.id && !$0.isAnthology }),
                   let group = groups[entry.seriesKey] {
                    nextItems.append(.series(group))
                } else {
                    nextItems.append(.book(book))
                }
            }
            await MainActor.run {
                guard self.books.map(\.id) == pageBooks.map(\.id) else { return }
                self.items = nextItems
                self.sidebarVC?.items = nextItems
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

    private func visibleIDs(_ ids: [Int]) -> [Int] {
        ids.filter { id in
            (ReaderPreferences.shared.showSkippedCollection || !skippedIDs.contains(id)) &&
            !seriesOrMergedIDs.contains(id) &&
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
            !seriesOrMergedIDs.contains(book.id) &&
            (!ReaderPreferences.shared.hideNonAO3PublisherBooks || book.isAO3PublisherBook) &&
            !book.isDescriptionAnthology
        }
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
        let currentSeriesOrMerged = membershipByID[SystemCollectionID.seriesOrMerged] ?? []
        let currentAO3PublisherIDs = session.library?.ao3PublisherBookIDs() ?? []
        collectionMembership = Dictionary(uniqueKeysWithValues: collections.map { collection in
            return (collection.name, membershipByID[collection.id] ?? [])
        })
        likedIDs = (try? await session.collectionStore?.likedIDs()) ?? []
        let shouldReloadPage = skippedIDs != currentSkipped || seriesOrMergedIDs != currentSeriesOrMerged || ao3PublisherIDs != currentAO3PublisherIDs
        skippedIDs = currentSkipped
        seriesOrMergedIDs = currentSeriesOrMerged
        ao3PublisherIDs = currentAO3PublisherIDs
        sidebarVC?.collectionMembership = collectionMembership
        sidebarVC?.likedIDs = likedIDs
        if shouldReloadPage {
            loadPage(reset: true)
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
        splitVC.insertSplitViewItem(item, at: min(1, splitVC.splitViewItems.count))
        oldVC?.removeFromParent()
        restoreSidebarThickness(sidebarThickness)
        repairReaderSplitItems()
    }

    private func makeReaderSidebarVC() -> NSViewController {
        let vc = NSHostingController(rootView: makeReaderSidebarView())
        readerSidebarHostingVC = vc
        return vc
    }

    private func makeReaderSidebarView() -> EmailReaderSidebarView {
        EmailReaderSidebarView(
            annotations: readerAnnotations,
            onJumpToAnnotation: { [weak self] annotation in
                self?.currentReaderVC?.jumpToAnnotation(annotation)
            },
            onDeleteAnnotation: { [weak self] id in
                self?.currentReaderVC?.deleteAnnotationFromSidebar(id: id)
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
        guard let item = annotationsSidebarItem else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            item.isCollapsed.toggle()
            splitVC.splitView.layoutSubtreeIfNeeded()
        }
        repairReaderSplitItems()
        toolbarState.isEmailReaderSidebarVisible = !item.isCollapsed
    }

    private func showReaderSidebar() {
        guard let item = annotationsSidebarItem else { return }
        guard item.isCollapsed else {
            toolbarState.isEmailReaderSidebarVisible = true
            repairReaderSplitItems()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            item.isCollapsed = false
            splitVC.splitView.layoutSubtreeIfNeeded()
        }
        repairReaderSplitItems()
        toolbarState.isEmailReaderSidebarVisible = true
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

        guard splitVC.view.window != nil,
              splitVC.splitView.bounds.width > 0,
              !annotationsSidebarItem.isCollapsed,
              let sidebarIndex = splitVC.splitViewItems.firstIndex(of: annotationsSidebarItem),
              sidebarIndex > 0 else { return }
        let dividerIndex = sidebarIndex - 1
        let splitWidth = splitVC.splitView.bounds.width
        guard splitWidth > 0 else { return }
        let desiredWidth: CGFloat = 300
        let width = min(max(desiredWidth, annotationsSidebarItem.minimumThickness), annotationsSidebarItem.maximumThickness)
        splitVC.splitView.setPosition(max(0, splitWidth - width), ofDividerAt: dividerIndex)
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

private func missingIndices(in indices: [Int]) -> [Int] {
    let unique = Array(Set(indices)).sorted()
    guard let last = unique.last, last > 1 else { return [] }
    let present = Set(unique)
    return (1...last).filter { !present.contains($0) }
}

private func parseISODate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    if let date = iso.date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
}
