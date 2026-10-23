import Combine
import Foundation
import Observation

// MARK: - LibraryDisplayController
//
// Extracted as part of Phase 2 (Presentation Model & View Controller Unification).
// Single `@Observable` `@MainActor` controller that owns the query planner,
// 3-branch filter execution, pagination offset bookkeeping, series grouping,
// and metadata hydration for both List mode (LibraryRootView) and Email mode
// (EmailLibraryViewController).
//
// Consolidates the query orchestration formerly duplicated across ~5,000 lines
// of code into this single controller, eliminating cross-surface reload races
// (suppressNextReloadToken), redundant re-fetches on mode switch, and divergent
// series-grouping drain bugs.
@Observable
@MainActor
final class LibraryDisplayController {

    // MARK: - Dependencies

    let session: LibrarySession
    let toolbarState: LibraryToolbarState
    private let queryController: LibraryQueryController

    // MARK: - Published Display State

    private(set) var items: [LibraryItem] = []
    private(set) var books: [CalibreBook] = []
    private(set) var bookStates: [Int: BookState] = [:]
    private(set) var ao3Metadata: [Int: AO3MetadataRecord] = [:]
    private(set) var ao3ExtractionDiagnostics: [Int: AO3ExtractionDiagnostic] = [:]
    private(set) var singletonSeriesWarnings: [Int: [SingletonSeriesWarning]] = [:]

    // MARK: - Selection State (Used prominently in Email / Split mode)

    var selectedItemID: String? {
        didSet {
            updateSelectedBook()
        }
    }
    private(set) var selectedBook: CalibreBook?

    // MARK: - Pagination & Offset State

    private(set) var offsetState = PagingOffsetState()
    private(set) var hasNextPage = false
    var hasPreviousPage: Bool { offsetState.currentPage > 0 }
    let pageSize = 25
    var pageFetchLimit: Int { (pageSize * 3) + 1 }

    // MARK: - Aggregation & Status Metrics

    private(set) var filteredCount: Int?
    private(set) var visibleTotalCount: Int?
    private(set) var isLoading: Bool = false
    private(set) var didFinishFirstLoad: Bool = false
    private(set) var rebuildDegraded: Bool = false

    // MARK: - Internal Tasks & Generation Counters

    private var loadGeneration = 0
    private var loadPageTask: Task<Void, Never>?
    private var filterComputeTask: Task<Void, Never>?
    private var filterCountTask: Task<Void, Never>?
    private var fullTextTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var groupAwareCountTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private let debouncer = DebounceTimer(delay: 0.4)

    // MARK: - Cached Query Expansions & Observation Baselines

    private(set) var resolvedTagExpansions: [String: [String]] = [:]
    private(set) var cachedFilterTagExpansions: [String: [String]] = [:]
    private(set) var lastHandledReloadToken: String?
    private var lastObservedSearchText: String = ""
    private var lastObservedSortField: SortField = .title
    private var lastObservedAscending: Bool = true
    private var lastObservedReshuffleToken: Bool = false
    private var lastObservedGroupBySeries: Bool = false
    private var lastObservedFilterExpression: FilterExpression = FilterExpression()
    private var lastObservedReloadToken: String?

    // MARK: - Initialization

    init(session: LibrarySession, toolbarState: LibraryToolbarState) {
        self.session = session
        self.toolbarState = toolbarState
        self.queryController = LibraryQueryController(surfaceLabel: "displayController")
        self.lastObservedSearchText = toolbarState.searchText
        self.lastObservedSortField = toolbarState.sortField
        self.lastObservedAscending = toolbarState.ascending
        self.lastObservedReshuffleToken = toolbarState.reshuffleToken
        self.lastObservedGroupBySeries = toolbarState.groupBySeries
        self.lastObservedFilterExpression = toolbarState.filterExpression
        self.lastObservedReloadToken = toolbarState.activeFilterResult?.reloadToken

        startObserving()
        if session.isOpen {
            if !applyRestoredLastViewIfNeeded() {
                if toolbarState.filterExpression.hasCompleteRules {
                    applyFilterRules(resetPage: true)
                } else {
                    scheduleLoadPage()
                }
            }
        }
    }

    @discardableResult
    func applyRestoredLastViewIfNeeded() -> Bool {
        guard session.snapshotsReady else { return false }
        let hash = session.activeLibraryHash
        if toolbarState.recordingLastViewHash != hash { toolbarState.stopRecordingLastView() }
        defer { toolbarState.beginRecordingLastView(libraryHash: hash) }
        guard let restored = session.takeRestoredLastView(), toolbarState.isAtDefaultView else { return false }
        offsetState.resetForNewFilter()
        let expression = restored.filterExpression ?? FilterExpression()
        toolbarState.sortField = restored.sortField
        toolbarState.ascending = restored.ascending
        toolbarState.filterExpression = expression
        guard expression.hasCompleteRules else { return false }
        applyFilterRules()
        return true
    }

    // MARK: - Observation Orchestration

    private func startObserving() {
        scheduleToolbarObservation()
        startObservingPreferences()
        startObservingNotifications()

        toolbarState.registerFilterCommitHandler { [weak self] rule in
            self?.addOrReplaceRule(rule)
        }
    }

    private func scheduleToolbarObservation() {
        withObservationTracking {
            _ = self.toolbarState.sortField
            _ = self.toolbarState.ascending
            _ = self.toolbarState.reshuffleToken
            _ = self.toolbarState.groupBySeries
            _ = self.toolbarState.filterExpression
            _ = self.toolbarState.searchText
            _ = self.toolbarState.activeFilterResult?.reloadToken
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handleToolbarStateChange()
                self.scheduleToolbarObservation()
            }
        }
    }

    private func handleToolbarStateChange() {
        if toolbarState.sortField != lastObservedSortField {
            lastObservedSortField = toolbarState.sortField
            offsetState.resetForNewFilter()
            scheduleLoadPage()
        }
        if toolbarState.ascending != lastObservedAscending {
            lastObservedAscending = toolbarState.ascending
            offsetState.resetForNewFilter()
            scheduleLoadPage()
        }
        if toolbarState.reshuffleToken != lastObservedReshuffleToken {
            lastObservedReshuffleToken = toolbarState.reshuffleToken
            scheduleLoadPage()
        }
        if toolbarState.groupBySeries != lastObservedGroupBySeries {
            lastObservedGroupBySeries = toolbarState.groupBySeries
            offsetState.resetForNewFilter()
            scheduleLoadPage()
        }
        if toolbarState.filterExpression != lastObservedFilterExpression {
            lastObservedFilterExpression = toolbarState.filterExpression
            offsetState.resetForNewFilter()
            if toolbarState.filterExpression.hasCompleteRules {
                applyFilterRules()
            } else {
                scheduleLoadPage()
            }
        }
        if toolbarState.searchText != lastObservedSearchText {
            lastObservedSearchText = toolbarState.searchText
            offsetState.resetForNewFilter()
            if toolbarState.consumeSearchTextReloadSuppression() {
                LibraryFilterDebug.log("searchText.suppressed", [
                    "surface": "displayController",
                    "searchText": toolbarState.searchText
                ])
                filteredCount = nil
            } else {
                debouncer.schedule { [weak self] in
                    self?.handleDebouncedSearchText()
                }
            }
        }
        let currentToken = toolbarState.activeFilterResult?.reloadToken
        if currentToken != lastObservedReloadToken {
            lastObservedReloadToken = currentToken
            if let currentToken, currentToken != lastHandledReloadToken {
                lastHandledReloadToken = currentToken
                offsetState.resetForNewFilter()
                scheduleLoadPage()
            }
        }
    }

    private func handleDebouncedSearchText() {
        LibraryFilterDebug.log("searchText.debounced", [
            "surface": "displayController",
            "searchText": toolbarState.searchText
        ])
        if let phrase = activeFullTextPhrase {
            session.retryFulltext(for: phrase)
        }
        if toolbarState.activeFilterResult?.isSQLBacked == true,
           toolbarState.activeFilterResult?.totalCount != nil {
            let suppressedResult = FilterResult(calibreIDs: [], isSQLBacked: true)
            lastHandledReloadToken = suppressedResult.reloadToken
            toolbarState.activeFilterResult = suppressedResult
        }
        if startPendingSearchTextFullTextIfNeeded() {
            return
        }
        let tagTerms = toolbarState.searchText.isEmpty
            ? []
            : SearchQueryParser.parse(toolbarState.searchText).tagTerms
        if tagTerms != Array(resolvedTagExpansions.keys).sorted() {
            resolveTagExpansionsIfNeeded()
        }
        let token = toolbarState.beginLibraryFilterApplication()
        Task {
            await scheduleLoadPage().value
            if toolbarState.searchText.isEmpty {
                filteredCount = nil
            } else {
                let query = SearchQueryParser.parse(toolbarState.searchText)
                filteredCount = await session.library?.bookCount(query: query)
                await session.refreshLastSearchError()
            }
            if toolbarState.libraryFilterApplicationToken == token {
                let resultCount = toolbarState.activeFilterResult?.totalCount
                    ?? filteredCount
                    ?? books.count
                commitSearchActivityLogEntry(resultCount: resultCount)
            }
            toolbarState.finishLibraryFilterApplication(token: token)
        }
    }

    private func startObservingPreferences() {
        withObservationTracking {
            _ = ReaderPreferences.shared.showSkippedCollection
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.offsetState.resetForNewFilter()
                if self.toolbarState.filterExpression.hasCompleteRules {
                    self.applyFilterRules()
                } else {
                    self.scheduleLoadPage()
                }
                self.startObservingPreferences()
            }
        }

        withObservationTracking {
            _ = ReaderPreferences.shared.hideNonAO3PublisherBooks
            _ = ReaderPreferences.shared.hideAnthologyBooks
            _ = ReaderPreferences.shared.hideDuplicateBooks
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshVisibilitySnapshots()
                self.startObservingVisibilityPreferences()
            }
        }
    }

    private func startObservingVisibilityPreferences() {
        withObservationTracking {
            _ = ReaderPreferences.shared.hideNonAO3PublisherBooks
            _ = ReaderPreferences.shared.hideAnthologyBooks
            _ = ReaderPreferences.shared.hideDuplicateBooks
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshVisibilitySnapshots()
                self.startObservingVisibilityPreferences()
            }
        }
    }

    private func startObservingNotifications() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let persisted = UserDefaults.standard.bool(forKey: "groupBySeries")
                if self.toolbarState.groupBySeries != persisted {
                    self.toolbarState.groupBySeries = persisted
                    self.offsetState.resetForNewFilter()
                    self.scheduleLoadPage()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .seriesOrMergedCollectionDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.refreshVisibilitySnapshots(resetPage: false) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .libraryContentsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.refreshVisibilitySnapshots(resetPage: false) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .librarySnapshotsDidBecomeReady)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.applyRestoredLastViewIfNeeded() {
                    Task { await self.refreshVisibilitySnapshots(resetPage: false) }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed Visibility Policy

    var currentVisibilityPolicy: LibraryVisibilityPolicy {
        LibraryVisibilityPolicy(
            showSkippedCollection: ReaderPreferences.shared.showSkippedCollection,
            shouldGroupSeriesRows: shouldGroupSeriesRows,
            hideNonAO3PublisherBooks: ReaderPreferences.shared.hideNonAO3PublisherBooks,
            hideAnthologyBooks: ReaderPreferences.shared.hideAnthologyBooks,
            hideDuplicateBooks: ReaderPreferences.shared.hideDuplicateBooks,
            skippedIDs: session.cachedSkippedIDs,
            seriesOrMergedIDs: session.cachedSeriesOrMergedIDs,
            ao3PublisherIDs: session.cachedAO3PublisherIDs,
            anthologyIDs: session.cachedAnthologyIDs,
            duplicateLoserIDs: session.cachedDuplicateLoserIDs
        )
    }

    private var filterVisibilitySignature: String {
        LibraryVisibilityPolicy.signature(
            showSkippedCollection: ReaderPreferences.shared.showSkippedCollection,
            hideNonAO3PublisherBooks: ReaderPreferences.shared.hideNonAO3PublisherBooks,
            hideAnthologyBooks: ReaderPreferences.shared.hideAnthologyBooks,
            hideDuplicateBooks: ReaderPreferences.shared.hideDuplicateBooks
        )
    }

    var shouldGroupSeriesRows: Bool {
        toolbarState.groupBySeries || toolbarState.filterExpression.hasSeriesOrMergedEqualsRule
    }

    // MARK: - Selection Resolution

    private func updateSelectedBook() {
        guard let id = selectedItemID else {
            selectedBook = nil
            return
        }
        for item in items {
            switch item {
            case .book(let book) where item.id == id:
                selectedBook = book
                return
            case .series(let series) where item.id == id:
                selectedBook = series.works.first
                return
            case .orphanedSeriesEntry(let book, _) where item.id == id:
                selectedBook = book
                return
            default:
                continue
            }
        }
        selectedBook = nil
    }

    // MARK: - Pagination Actions

    func nextPage() {
        guard hasNextPage else { return }
        offsetState.currentPage += 1
        scheduleLoadPage()
    }

    func previousPage() {
        guard offsetState.currentPage > 0 else { return }
        offsetState.currentPage -= 1
        scheduleLoadPage()
    }

    func loadNextBatchIfAvailable() {
        guard hasNextPage, !isLoading else { return }
        offsetState.currentPage += 1
        scheduleLoadPage(accumulate: true)
    }

    func reloadCurrentPage() {
        scheduleLoadPage()
    }

    func addOrReplaceRule(_ rule: FilterRule) {
        LibraryQueryHelpers.addOrReplaceRule(rule, in: &toolbarState.filterExpression)
        applyFilterRules()
    }

    func refreshBookStates() {
        loadBookStatesForCurrentPage()
    }

    func refreshVisibilitySnapshots(resetPage: Bool = true) async {
        await session.refreshCollectionSnapshots()
        let shouldReset = resetPage || !keepsPageOnMembershipChange
        if shouldReset { offsetState.resetForNewFilter() }
        if toolbarState.filterExpression.hasCompleteRules {
            applyFilterRules(resetPage: shouldReset)
        } else {
            scheduleLoadPage()
        }
    }

    private var keepsPageOnMembershipChange: Bool {
        !shouldGroupSeriesRows && toolbarState.sortField != .random
    }

    var activeFullTextPhrase: String? {
        let phrase = SearchQueryParser.parse(toolbarState.searchText).fulltextPhrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return phrase?.isEmpty == false ? phrase : nil
    }

    var fulltextPhrasesInUse: [String] {
        var phrases: [String] = []
        if let phrase = activeFullTextPhrase { phrases.append(phrase) }
        phrases += toolbarState.filterExpression.groups.flatMap(\.rules)
            .filter { $0.field == .fulltext && $0.isComplete }
            .map(\.value)
        return phrases
    }

    var fulltextFailureMessage: String? {
        for phrase in fulltextPhrasesInUse {
            if case .failed(let message) = session.fulltextState(for: phrase) { return message }
        }
        return nil
    }

    func retryFailedFulltext() {
        let phrases = fulltextPhrasesInUse
        for phrase in phrases { session.retryFulltext(for: phrase) }
        let hasFilterRule = toolbarState.filterExpression.groups.flatMap(\.rules)
            .contains { $0.field == .fulltext && $0.isComplete }
        if hasFilterRule { applyFilterRules() }
        if activeFullTextPhrase != nil { _ = startPendingSearchTextFullTextIfNeeded() }
    }

    // MARK: - Filter Application (Unified 3-Branch Execution)

    func applyFilterRules(resetPage: Bool = true) {
        let applyStart = LibraryFilterDebug.now()
        fullTextTask?.cancel()
        fullTextTask = nil
        filterCountTask?.cancel()
        filterComputeTask?.cancel()
        filterComputeTask = nil

        guard let library = session.library else {
            toolbarState.cancelLibraryFilterApplication()
            return
        }

        guard toolbarState.filterExpression.hasCompleteRules else {
            toolbarState.activeFilterResult = nil
            toolbarState.cancelLibraryFilterApplication()
            if resetPage { offsetState.resetForNewFilter() }
            scheduleLoadPage()
            return
        }

        let expression = toolbarState.filterExpression
        LibraryFilterDebug.log("applyFilter.start", [
            "surface": "displayController",
            "rules": LibraryFilterDebug.summary(expression: expression),
            "sqlPageable": expression.isSQLPageable
        ])

        // Branch A: Fast SQL-Pageable
        if expression.isSQLPageable {
            let filterSignature = LibraryFilterDebug.summary(expression: expression)
            if let existing = toolbarState.activeFilterResult,
               existing.isSQLBacked,
               let existingTotalCount = existing.totalCount,
               existing.filterSignature == filterSignature {
                lastHandledReloadToken = existing.reloadToken
                toolbarState.clearPendingFullTextSearch()
                toolbarState.cancelLibraryFilterApplication()
                commitSearchActivityLogEntry(resultCount: existingTotalCount)
                if resetPage { offsetState.resetForNewFilter() }
                scheduleLoadPage()
                LibraryFilterDebug.log("applyFilter.end", [
                    "surface": "displayController",
                    "mode": "sqlPagedDeferredCount.reuseCount",
                    "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
                ])
                return
            }
            let newResult = FilterResult(calibreIDs: [], isSQLBacked: true)
            lastHandledReloadToken = newResult.reloadToken
            toolbarState.activeFilterResult = newResult
            toolbarState.clearPendingFullTextSearch()
            toolbarState.cancelLibraryFilterApplication()
            if resetPage { offsetState.resetForNewFilter() }
            scheduleLoadPage()
            LibraryFilterDebug.log("applyFilter.end", [
                "surface": "displayController",
                "mode": "sqlPagedDeferredCount",
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
            ])
            return
        }

        // Branch B: LRU Cache
        if let cached = session.cachedFilterResult(for: expression, visibilitySignature: filterVisibilitySignature) {
            toolbarState.activeFilterResult = cached
            toolbarState.clearPendingFullTextSearch()
            toolbarState.cancelLibraryFilterApplication()
            lastHandledReloadToken = cached.reloadToken
            commitSearchActivityLogEntry(resultCount: cached.totalCount ?? cached.calibreIDs.count)
            if resetPage { offsetState.resetForNewFilter() }
            scheduleLoadPage()
            LibraryFilterDebug.log("applyFilter.end", [
                "surface": "displayController",
                "mode": "cachedFilterResult",
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
            ])
            return
        }

        // Branch C: Full Evaluator Compute
        let token = toolbarState.beginLibraryFilterApplication()
        let fulltextRules = expression.groups.flatMap(\.rules)
            .filter { $0.field == .fulltext && $0.isComplete }
        if let firstPendingRule = fulltextRules.first(where: { session.fulltextState(for: $0.value) == .unknown }) {
            startPendingFilterFullText(rule: firstPendingRule, token: token)
            return
        }

        let bookTagsRevisionAtStart = session.bookTagsRevision
        let evaluator = FilterEvaluator(
            library: library,
            ftsLibrary: session.ftsLibrary,
            metaDB: session.metaDB,
            collectionStore: session.collectionStore,
            ruleMatchCache: session.ruleMatchCache,
            bookTagsRevision: bookTagsRevisionAtStart
        )

        // Incremental Narrowing Optimization
        if IncrementalFilterFlag.isEnabled,
           let narrowing = session.narrowingBase(for: expression, visibilitySignature: filterVisibilitySignature) {
            filterComputeTask = Task {
                let delta = narrowing.delta
                let deltaExpression = IncrementalFilterPlanner.deltaExpression(for: delta)
                let fulltextMap = LibraryQueryHelpers.fulltextMap(
                    values: delta.field == .fulltext ? [delta.value] : []
                ) { self.session.cachedFulltextIDs(for: $0) }
                let baseIDs = narrowing.base.calibreIDs
                guard let evaluated = await evaluator.evaluate(expression: deltaExpression,
                                                               fulltextMap: fulltextMap,
                                                               candidates: Set(baseIDs)) else { return }
                let deltaSet = Set(evaluated.result.calibreIDs)
                let narrowedIDs = baseIDs.filter { deltaSet.contains($0) }
                guard self.toolbarState.libraryFilterApplicationToken == token, !Task.isCancelled else { return }
                defer { self.toolbarState.finishLibraryFilterApplication(token: token) }
                let narrowed = FilterResult(calibreIDs: narrowedIDs, totalCount: narrowedIDs.count)
                self.commitSearchActivityLogEntry(resultCount: narrowedIDs.count)
                self.session.rememberFilterResult(
                    narrowed, for: expression,
                    visibilitySignature: self.filterVisibilitySignature,
                    bookTagsRevision: bookTagsRevisionAtStart
                )
                self.toolbarState.clearPendingFullTextSearch()
                self.cachedFilterTagExpansions = self.cachedFilterTagExpansions.merging(evaluated.tagExpansions) { _, new in new }
                self.lastHandledReloadToken = narrowed.reloadToken
                self.toolbarState.activeFilterResult = narrowed
                if resetPage { self.offsetState.resetForNewFilter() }
                self.scheduleLoadPage()
            }
            return
        }

        filterComputeTask = Task {
            let fulltextMap = LibraryQueryHelpers.fulltextMap(values: fulltextRules.map(\.value)) {
                self.session.cachedFulltextIDs(for: $0)
            }
            guard let evaluated = await evaluator.evaluate(expression: expression, fulltextMap: fulltextMap) else {
                return
            }
            let finalResult = evaluated.result
            let filterTagExpansions = evaluated.tagExpansions

            async let fetchedSkipped = self.session.collectionStore?.members(of: SystemCollectionID.skipped)
            async let fetchedSeriesOrMerged = self.session.collectionStore?.members(of: SystemCollectionID.seriesOrMerged)
            let capturedLibrary = self.session.library
            let currentSkipped = Set((try? await fetchedSkipped) ?? [])
            let currentSeriesOrMerged = Set((try? await fetchedSeriesOrMerged) ?? [])
            let publisherIDs = await capturedLibrary?.ao3PublisherBookIDs() ?? []
            let currentAnthologyIDs = await capturedLibrary?.anthologyBookIDs() ?? []
            let currentDuplicateLoserIDs = await capturedLibrary?.duplicateLoserBookIDs() ?? []

            let visibilitySignature = self.filterVisibilitySignature
            let prefs = ReaderPreferences.shared
            let filteredIDs = prefs.showSkippedCollection
                ? finalResult.calibreIDs
                : finalResult.calibreIDs.filter { !currentSkipped.contains($0) }
            let visibleFilteredIDs = filteredIDs.filter { !currentSeriesOrMerged.contains($0) }
                .filter { !prefs.hideNonAO3PublisherBooks || publisherIDs.contains($0) }
                .filter { !prefs.hideAnthologyBooks || !currentAnthologyIDs.contains($0) }
                .filter { !prefs.hideDuplicateBooks || !currentDuplicateLoserIDs.contains($0) }

            guard self.toolbarState.libraryFilterApplicationToken == token, !Task.isCancelled else { return }
            defer { self.toolbarState.finishLibraryFilterApplication(token: token) }

            let cacheableResult = FilterResult(
                calibreIDs: visibleFilteredIDs,
                totalCount: visibleFilteredIDs.count
            )
            self.toolbarState.activeFilterResult = cacheableResult
            self.commitSearchActivityLogEntry(resultCount: cacheableResult.totalCount ?? visibleFilteredIDs.count)
            self.session.rememberFilterResult(
                cacheableResult, for: expression, visibilitySignature: visibilitySignature,
                bookTagsRevision: bookTagsRevisionAtStart
            )
            self.toolbarState.clearPendingFullTextSearch()
            self.cachedFilterTagExpansions = filterTagExpansions
            self.session.cachedAnthologyIDs = currentAnthologyIDs
            self.session.cachedDuplicateLoserIDs = currentDuplicateLoserIDs
            self.lastHandledReloadToken = cacheableResult.reloadToken

            if resetPage { self.offsetState.resetForNewFilter() }
            self.scheduleLoadPage()
            LibraryFilterDebug.log("applyFilter.end", [
                "surface": "displayController",
                "mode": "explicitIDs",
                "ids": visibleFilteredIDs.count,
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
            ])
        }
    }

    private func startPendingFilterFullText(rule: FilterRule, token applicationToken: UUID) {
        let phrase = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else {
            toolbarState.finishLibraryFilterApplication(token: applicationToken)
            return
        }
        fullTextTask?.cancel()
        fullTextTask = Task {
            _ = await session.resolveFulltextIDs(for: phrase)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.toolbarState.libraryFilterApplicationToken == applicationToken else { return }
                self.applyFilterRules()
            }
        }
    }

    // MARK: - Load Page Orchestration

    @discardableResult
    func scheduleLoadPage(accumulate: Bool = false) -> Task<Void, Never> {
        loadGeneration += 1
        let gen = loadGeneration
        loadPageTask?.cancel()
        isLoading = true

        let task = Task {
            await self.executeLoadPage(generation: gen, accumulate: accumulate)
        }
        loadPageTask = task
        return task
    }

    private func executeLoadPage(generation: Int, accumulate: Bool) async {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        guard let library = session.library else {
            books = []
            items = []
            isLoading = false
            return
        }

        guard session.snapshotsReady else {
            isLoading = false
            return
        }

        let rawQuery = toolbarState.searchText.isEmpty
            ? SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
            : SearchQueryParser.parse(toolbarState.searchText)
        var query = queryWithCachedFullText(rawQuery)
        query.expandedTagTerms = resolvedTagExpansions

        if rawQuery.fulltextPhrase?.isEmpty == false && query.ftsMatchedIDs == nil {
            _ = startPendingSearchTextFullTextIfNeeded()
            isLoading = false
            return
        }

        var loadedPageBooks: [CalibreBook] = []
        var pageHasMore = false

        if toolbarState.sortField == .random {
            let (page, hasMore) = await library.randomSortedPage(
                offset: offsetState.currentPage * pageSize, limit: pageSize,
                CalibreLibrary.PageQuery(
                    query: query,
                    filter: toolbarState.activeFilterResult?.isSQLBacked == true ? toolbarState.filterExpression : nil,
                    restrictIDs: resolveRestrictIDs(query: query),
                    visibility: currentVisibilityPolicy,
                    filterTagExpansions: cachedFilterTagExpansions,
                    visibilityVersion: session.membershipVersion
                )
            )
            loadedPageBooks = page
            pageHasMore = hasMore
        } else if toolbarState.sortField == .wordCount {
            let (page, hasMore) = await library.wordCountSortedPage(
                offset: offsetState.currentPage * pageSize, limit: pageSize, ascending: toolbarState.ascending,
                CalibreLibrary.PageQuery(
                    query: query,
                    filter: toolbarState.activeFilterResult?.isSQLBacked == true ? toolbarState.filterExpression : nil,
                    restrictIDs: resolveRestrictIDs(query: query),
                    visibility: currentVisibilityPolicy,
                    filterTagExpansions: cachedFilterTagExpansions,
                    visibilityVersion: session.membershipVersion
                )
            )
            loadedPageBooks = page
            pageHasMore = hasMore
            triggerDeferredSQLCountIfNeeded(query: query)
        } else if toolbarState.sortField == .kudos {
            let (page, hasMore) = await library.kudosSortedPage(
                offset: offsetState.currentPage * pageSize, limit: pageSize, ascending: toolbarState.ascending,
                CalibreLibrary.PageQuery(
                    query: query,
                    filter: toolbarState.activeFilterResult?.isSQLBacked == true ? toolbarState.filterExpression : nil,
                    restrictIDs: resolveRestrictIDs(query: query),
                    visibility: currentVisibilityPolicy,
                    filterTagExpansions: cachedFilterTagExpansions,
                    visibilityVersion: session.membershipVersion
                )
            )
            loadedPageBooks = page
            pageHasMore = hasMore
            triggerDeferredSQLCountIfNeeded(query: query)
        } else if toolbarState.sortField == .title && shouldGroupSeriesRows {
            let (page, hasMore) = await library.groupAwareTitleSortedPage(
                offset: offsetState.currentPage * pageSize, limit: pageSize, ascending: toolbarState.ascending,
                CalibreLibrary.PageQuery(
                    query: query,
                    filter: toolbarState.activeFilterResult?.isSQLBacked == true ? toolbarState.filterExpression : nil,
                    restrictIDs: resolveRestrictIDs(query: query),
                    visibility: currentVisibilityPolicy,
                    filterTagExpansions: cachedFilterTagExpansions,
                    visibilityVersion: session.membershipVersion,
                    metaDB: session.metaDB
                )
            )
            loadedPageBooks = page
            pageHasMore = hasMore
            triggerDeferredSQLCountIfNeeded(query: query)
        } else if let result = toolbarState.activeFilterResult, result.isSQLBacked {
            let (page, hasMore) = await executeGroupAwareSQLDrain(library: library, query: query, filter: toolbarState.filterExpression)
            loadedPageBooks = page
            pageHasMore = hasMore
            triggerDeferredSQLCountIfNeeded(query: query)
        } else if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            let ids = currentVisibilityPolicy.filter(LibraryQueryHelpers.intersect(result.calibreIDs, with: query.ftsMatchedIDs))
            let raw = await library.books(
                ids: ids,
                offset: offsetState.currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query
            )
            pageHasMore = raw.count > pageSize
            loadedPageBooks = Array(raw.prefix(pageSize))
        } else if toolbarState.activeFilterResult != nil {
            loadedPageBooks = []
            pageHasMore = false
        } else {
            // Unfiltered
            if shouldGroupSeriesRows {
                let (page, hasMore) = await executeGroupAwareSQLDrain(library: library, query: query, filter: nil)
                loadedPageBooks = page
                pageHasMore = hasMore
            } else {
                let raw = await library.books(
                    offset: offsetState.currentPage * pageSize, limit: pageFetchLimit,
                    sort: toolbarState.sortField, ascending: toolbarState.ascending,
                    query: query,
                    filter: nil,
                    filterTagExpansions: cachedFilterTagExpansions,
                    visibilityVersion: session.membershipVersion
                )
                let visible = currentVisibilityPolicy.filter(raw)
                pageHasMore = raw.count == pageFetchLimit || visible.count > pageSize
                loadedPageBooks = Array(visible.prefix(pageSize))
            }
        }

        guard generation == loadGeneration, !Task.isCancelled else { return }

        if accumulate {
            books.append(contentsOf: loadedPageBooks)
        } else {
            books = loadedPageBooks
        }
        hasNextPage = pageHasMore
        isLoading = false
        didFinishFirstLoad = true

        rebuildItems()
        loadAO3MetadataForCurrentPage()
        loadBookStatesForCurrentPage()
        scheduleGroupAwareCountIfNeeded()
    }

    private func resolveRestrictIDs(query: SearchQuery) -> [Int]? {
        guard let result = toolbarState.activeFilterResult else { return nil }
        if result.isSQLBacked { return nil }
        if result.calibreIDs.isEmpty { return [] }
        return LibraryQueryHelpers.intersect(result.calibreIDs, with: query.ftsMatchedIDs)
    }

    // MARK: - Group-Aware SQL Drain

    private func executeGroupAwareSQLDrain(
        library: CalibreLibrary,
        query: SearchQuery,
        filter: FilterExpression?
    ) async -> ([CalibreBook], Bool) {
        guard shouldGroupSeriesRows else {
            let raw = await library.books(
                offset: offsetState.currentPage * pageSize, limit: pageFetchLimit,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query,
                filter: filter,
                filterTagExpansions: cachedFilterTagExpansions,
                visibilityVersion: session.membershipVersion
            )
            let visible = currentVisibilityPolicy.filter(raw)
            let hasMore = raw.count == pageFetchLimit || visible.count > pageSize
            return (Array(visible.prefix(pageSize)), hasMore)
        }

        let isNewPage = offsetState.currentPage == offsetState.rawSQLOffsetByPage.count
        let pageAtStart = offsetState.currentPage
        let startOffset: Int
        var visible: [CalibreBook]

        if isNewPage {
            startOffset = offsetState.rawSQLOffsetFrontier
            visible = offsetState.rawSQLOffsetOverflowFrontier
        } else if offsetState.currentPage < offsetState.rawSQLOffsetByPage.count {
            startOffset = offsetState.rawSQLOffsetByPage[offsetState.currentPage]
            visible = offsetState.seedOverflowByPage[offsetState.currentPage]
        } else {
            startOffset = offsetState.rawSQLOffsetFrontier
            visible = offsetState.rawSQLOffsetOverflowFrontier
        }

        var offset = startOffset
        var exhausted = false
        var iterations = 0
        let maxIterations = 40

        while visible.count < pageSize && iterations < maxIterations {
            iterations += 1
            let raw = await library.books(
                offset: offset, limit: pageFetchLimit,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query,
                filter: filter,
                filterTagExpansions: cachedFilterTagExpansions,
                visibilityVersion: session.membershipVersion
            )
            guard !Task.isCancelled else { break }
            offset += raw.count
            visible.append(contentsOf: currentVisibilityPolicy.filter(raw))
            if raw.count < pageFetchLimit { exhausted = true; break }
        }

        let overflow = Array(visible.dropFirst(pageSize))
        if isNewPage {
            offsetState.commitNewPage(
                page: pageAtStart, startOffset: startOffset,
                newFrontier: offset, overflow: overflow
            )
        }

        let hasMore = !exhausted || visible.count > pageSize
        return (Array(visible.prefix(pageSize)), hasMore)
    }

    // MARK: - Rebuild Items & Series Grouping

    func rebuildItems() {
        guard !books.isEmpty, let metaDB = session.metaDB, let library = session.library else {
            rebuildTask?.cancel()
            items = books.map { .book($0) }
            rebuildDegraded = false
            return
        }

        let pageBooks = books
        rebuildTask?.cancel()
        rebuildTask = Task {
            let degraded = false
            let pageIDs = pageBooks.map(\.id)

            async let pageMetadataTask = metaDB.ao3Metadata(for: pageIDs)
            async let pageDiagnosticsTask = metaDB.ao3ExtractionDiagnostics(for: pageIDs)
            async let entriesTask = metaDB.seriesEntries(for: pageIDs)
            async let singletonWarningsTask = metaDB.singletonNonLeadingSeriesEntries(for: pageIDs)

            let pageMetadata = (try? await pageMetadataTask) ?? [:]
            let pageDiagnostics = (try? await pageDiagnosticsTask) ?? [:]
            let entries = (try? await entriesTask) ?? []
            let rawWarnings = (try? await singletonWarningsTask) ?? [:]

            if shouldGroupSeriesRows {
                let groupedEntries = Dictionary(
                    grouping: entries.filter { !session.cachedAnthologyIDs.contains($0.calibreID) },
                    by: \.seriesKey
                )
                let seriesKeys = groupedEntries.keys.sorted()

                async let allEntriesTask = metaDB.seriesEntries(keys: seriesKeys)
                async let placeholdersTask = metaDB.placeholders(for: seriesKeys)

                let allEntries = (try? await allEntriesTask) ?? []
                let placeholders = (try? await placeholdersTask) ?? [:]
                let allIDs = Array(Set(allEntries.map(\.calibreID)))

                async let allBooksTask = library.booksForIDs(allIDs)
                async let seriesMetadataTask = metaDB.ao3Metadata(for: allIDs)
                async let seriesDiagnosticsTask = metaDB.ao3ExtractionDiagnostics(for: allIDs)

                let allBooks = await allBooksTask
                let seriesMetadata = (try? await seriesMetadataTask) ?? [:]
                let seriesDiagnostics = (try? await seriesDiagnosticsTask) ?? [:]

                let warnings = self.enrichWarnings(rawWarnings, books: pageBooks)
                let byID = LibraryQueryHelpers.indexed(allBooks.map { ($0.id, $0) })
                let seriesByKey = buildSeriesGroups(
                    allEntries: allEntries,
                    byID: byID,
                    seriesMetadata: seriesMetadata,
                    seriesDiagnostics: seriesDiagnostics,
                    anthologyIDs: session.cachedAnthologyIDs,
                    duplicateLoserIDs: session.cachedDuplicateLoserIDs,
                    placeholders: placeholders
                )

                var collapsedIDs = Set<Int>()
                for group in seriesByKey.values {
                    collapsedIDs.formUnion(group.works.map(\.id))
                }

                let nextItems = assignSeriesItems(
                    pageBooks: pageBooks,
                    entries: entries,
                    seriesByKey: seriesByKey,
                    collapsedIDs: collapsedIDs,
                    singletonWarningsByCalibreID: warnings,
                    anthologyIDs: session.cachedAnthologyIDs
                )

                guard !Task.isCancelled else { return }
                self.items = nextItems
                self.ao3Metadata = pageMetadata
                self.ao3ExtractionDiagnostics = pageDiagnostics
                self.singletonSeriesWarnings = warnings
                self.rebuildDegraded = degraded
            } else {
                guard !Task.isCancelled else { return }
                self.items = pageBooks.map { .book($0) }
                self.ao3Metadata = pageMetadata
                self.ao3ExtractionDiagnostics = pageDiagnostics
                self.singletonSeriesWarnings = self.enrichWarnings(rawWarnings, books: pageBooks)
                self.rebuildDegraded = degraded
            }
        }
    }

    private func enrichWarnings(
        _ warnings: [Int: [SingletonSeriesWarning]],
        books: [CalibreBook]
    ) -> [Int: [SingletonSeriesWarning]] {
        let titlesByID = LibraryQueryHelpers.indexed(books.map { ($0.id, $0.displayTitle) })
        return warnings.reduce(into: [:]) { result, pair in
            let (id, warningsForBook) = pair
            result[id] = warningsForBook.map { warning in
                SingletonSeriesWarning(
                    seriesKey: warning.seriesKey,
                    seriesName: warning.seriesName,
                    seriesIndex: warning.seriesIndex,
                    title: titlesByID[id] ?? warning.title
                )
            }
        }
    }

    // MARK: - Metadata Batch Hydration

    private func loadAO3MetadataForCurrentPage() {
        guard let metaDB = session.metaDB else { return }
        let ids = books.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            async let metaTask = metaDB.ao3Metadata(for: ids)
            async let diagTask = metaDB.ao3ExtractionDiagnostics(for: ids)
            let meta = (try? await metaTask) ?? [:]
            let diags = (try? await diagTask) ?? [:]
            guard !Task.isCancelled else { return }
            self.ao3Metadata.merge(meta) { _, new in new }
            self.ao3ExtractionDiagnostics.merge(diags) { _, new in new }
        }
    }

    private func loadBookStatesForCurrentPage() {
        guard let metaDB = session.metaDB else { return }
        let ids = books.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            let states = await metaDB.bookStates(for: ids)
            guard !Task.isCancelled else { return }
            self.bookStates = states
        }
    }

    // MARK: - Deferred Counts & Expansions

    private func triggerDeferredSQLCountIfNeeded(query: SearchQuery) {
        guard let result = toolbarState.activeFilterResult, result.isSQLBacked, result.totalCount == nil else { return }
        filterCountTask?.cancel()
        filterCountTask = Task {
            guard let library = session.library else { return }
            let count = await library.bookCount(
                query: query,
                filter: toolbarState.filterExpression,
                filterTagExpansions: cachedFilterTagExpansions
            )
            guard !Task.isCancelled else { return }
            if let current = toolbarState.activeFilterResult, current.isSQLBacked {
                let filterSignature = LibraryFilterDebug.summary(expression: toolbarState.filterExpression)
                let updated = FilterResult(
                    calibreIDs: [],
                    totalCount: count,
                    isSQLBacked: true,
                    filterSignature: filterSignature
                )
                toolbarState.activeFilterResult = updated
                filteredCount = count
                commitSearchActivityLogEntry(resultCount: count)
            }
        }
    }

    private func scheduleGroupAwareCountIfNeeded() {
        guard shouldGroupSeriesRows, let library = session.library else {
            visibleTotalCount = nil
            return
        }
        groupAwareCountTask?.cancel()
        let policy = currentVisibilityPolicy
        let version = session.membershipVersion
        let filterForSQL = toolbarState.activeFilterResult?.isSQLBacked == true ? toolbarState.filterExpression : nil
        let emptyQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
        let restrictIDs = resolveRestrictIDs(query: emptyQuery)
        let tagExpansions = cachedFilterTagExpansions

        groupAwareCountTask = Task {
            let count = await library.visibleBookCount(CalibreLibrary.PageQuery(
                query: emptyQuery,
                filter: filterForSQL,
                restrictIDs: restrictIDs,
                visibility: policy,
                filterTagExpansions: tagExpansions,
                visibilityVersion: version
            ))
            guard !Task.isCancelled else { return }
            self.visibleTotalCount = count
        }
    }

    func resolveTagExpansionsIfNeeded() {
        guard let metaDB = session.metaDB else { return }
        let rawQuery = SearchQueryParser.parse(toolbarState.searchText)
        let tagTerms = rawQuery.tagTerms
        guard !tagTerms.isEmpty else {
            resolvedTagExpansions = [:]
            return
        }
        Task {
            let expansions = await TagExpansionResolver.resolvedTagExpansions(for: tagTerms, metaDB: metaDB)
            guard !Task.isCancelled else { return }
            self.resolvedTagExpansions = expansions
        }
    }

    private func queryWithCachedFullText(_ rawQuery: SearchQuery) -> SearchQuery {
        var query = rawQuery
        if let phrase = rawQuery.fulltextPhrase, !phrase.isEmpty {
            query.ftsMatchedIDs = session.cachedFulltextIDs(for: phrase)
        }
        return query
    }

    private func startPendingSearchTextFullTextIfNeeded() -> Bool {
        let phrase = SearchQueryParser.parse(toolbarState.searchText).fulltextPhrase
        guard let phraseString = phrase, !phraseString.isEmpty else { return false }
        fullTextTask?.cancel()
        fullTextTask = Task {
            _ = await session.resolveFulltextIDs(for: phraseString)
            guard !Task.isCancelled else { return }
            scheduleLoadPage()
        }
        return true
    }

    private func commitSearchActivityLogEntry(resultCount: Int) {
        let text = toolbarState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let expr = toolbarState.filterExpression.hasCompleteRules ? toolbarState.filterExpression : nil
        guard !text.isEmpty || expr != nil else { return }
        SearchActivityLog.shared.append(
            searchText: text,
            filterExpression: expr,
            resultCount: resultCount
        )
    }
}
