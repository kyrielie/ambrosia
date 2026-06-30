import SwiftUI
import SwiftData

// MARK: - Library root view

struct LibraryRootView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(LibraryToolbarState.self) private var toolbarState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject private var prefs = ReaderPreferences.shared

    // MARK: - Resolved library colours

    private var effectiveIsDark: Bool {
        switch prefs.libraryAppearanceMode {
        case .system: return systemColorScheme == .dark
        case .light:  return false
        case .dark:   return true
        }
    }

    private var libraryBGColor: Color {
        switch prefs.libraryColorMode {
        case .systemDefault: return Color(nsColor: .windowBackgroundColor)
        case .accentColor:   return Color(nsColor: .controlAccentColor).opacity(0.08)
        case .custom:        return Color(hex: effectiveIsDark
                                    ? prefs.libraryDarkBackgroundColor
                                    : prefs.libraryLightBackgroundColor)
                                    ?? Color(nsColor: .windowBackgroundColor)
        }
    }

    private var libraryTextColor: Color {
        switch prefs.libraryColorMode {
        case .systemDefault, .accentColor: return Color(nsColor: .labelColor)
        case .custom: return Color(hex: effectiveIsDark
                                    ? prefs.libraryDarkTextColor
                                    : prefs.libraryLightTextColor)
                                    ?? Color(nsColor: .labelColor)
        }
    }

    @State private var books: [CalibreBook] = []
    @State private var items: [LibraryItem] = []
    @State private var hasNextPage  = false
    @State private var currentPage  = 0
    @State private var filteredCount: Int? = nil

    @State private var bookStates: [Int: BookState] = [:]
    @State private var ao3Metadata: [Int: AO3MetadataRecord] = [:]
    @State private var ao3ExtractionDiagnostics: [Int: AO3ExtractionDiagnostic] = [:]
    @State private var singletonSeriesWarnings: [Int: SingletonSeriesWarning] = [:]
    // Seeded from LibrarySession cache so the first render on every mode
    // switch uses correct membership data — no flash of wrong ordering.
    @State private var likedIDs: Set<Int> = []
    @State private var readLaterIDs: Set<Int> = []
    @State private var skippedIDs: Set<Int> = []
    @State private var seriesOrMergedIDs: Set<Int> = []
    @State private var ao3PublisherIDs: Set<Int> = []
    @State private var selectedIDs: Set<Int> = []
    @State private var fullTextTask: Task<Void, Never>? = nil
    @State private var filterCountTask: Task<Void, Never>? = nil
    // §perf: prevents the onChange(reloadToken) handler from firing a duplicate
    // loadPage() when applyFilterRules() has already called it synchronously.
    @State private var suppressNextReloadToken = false

    /// Async-resolved synonym expansions for the current search query's tag terms.
    /// Populated by `resolveTagExpansionsIfNeeded` whenever `tagTerms` changes.
    /// `loadPage` injects these into the `SearchQuery` before passing to `whereClause`
    /// so `CalibreLibrary` never opens its own connection to `ambrosia_meta.db`
    /// (Invariant 10).
    @State private var resolvedTagExpansions: [String: [String]] = [:]

    /// Expansions for committed filter rule tag values, populated async in
    /// `applyFilterRules` and read sync in `loadPage`'s SQL-paged path.
    @State private var cachedFilterTagExpansions: [String: [String]] = [:]

    private let pageSize = 25
    private var pageFetchLimit: Int { (pageSize * 3) + 1 }
    private let debouncer = DebounceTimer(delay: 0.4)

    var displayCount: Int {
        toolbarState.activeFilterResult?.totalCount ?? filteredCount ?? session.totalCount
    }

    private var extractionRefreshToken: String {
        "\(session.extractionProgress.completed)-\(session.extractionProgress.isRunning)"
    }

    var body: some View {
        attachSheets(to: attachLifecycleHandlers(to: rootContent
            .background(libraryBGColor)
            .foregroundStyle(libraryTextColor)
            .preferredColorScheme(prefs.resolvedLibraryColorScheme)))
    }

    // Split into two methods so the Swift type-checker doesn't time out
    // on a single overlong modifier chain (SR-11289 / compiler perf limit).
    private func attachLifecycleHandlers<V: View>(to view: V) -> some View {
        attachAppearanceHandlers(to: attachDataHandlers(to: view))
    }

    /// Pagination, sort, search-text, and filter-result changes.
    private func attachDataHandlers<V: View>(to view: V) -> some View {
        view
            .onChange(of: currentPage)                { loadPage() }
            .onChange(of: toolbarState.sortField)     { selectedIDs.removeAll(); currentPage = 0; loadPage() }
            .onChange(of: toolbarState.ascending)     { selectedIDs.removeAll(); currentPage = 0; loadPage() }
            .onChange(of: toolbarState.reshuffleToken)   { loadPage() }
            .onChange(of: toolbarState.groupBySeries) { selectedIDs.removeAll(); currentPage = 0; loadPage() }
            .onChange(of: toolbarState.searchText) {
                selectedIDs.removeAll()
                currentPage = 0
                if toolbarState.consumeSearchTextReloadSuppression() {
                    LibraryFilterDebug.log("searchText.suppressed", [
                        "surface": "list",
                        "searchText": toolbarState.searchText
                    ])
                    filteredCount = nil
                    return
                }
                debouncer.schedule {
                    LibraryFilterDebug.log("searchText.debounced", [
                        "surface": "list",
                        "searchText": toolbarState.searchText
                    ])
                    if toolbarState.activeFilterResult?.isSQLBacked == true,
                       toolbarState.activeFilterResult?.totalCount != nil {
                        toolbarState.activeFilterResult = FilterResult(calibreIDs: [], isSQLBacked: true)
                    }
                    if startPendingSearchTextFullTextIfNeeded() {
                        return
                    }
                    // Resolve tag synonym expansions async. resolveTagExpansionsIfNeeded
                    // calls loadPage() again once the actor responds; the loadPage()
                    // below runs immediately with any previously cached expansions.
                    let tagTerms = toolbarState.searchText.isEmpty
                        ? []
                        : SearchQueryParser.parse(toolbarState.searchText).tagTerms
                    if tagTerms != Array(resolvedTagExpansions.keys).sorted() {
                        resolveTagExpansionsIfNeeded(terms: tagTerms)
                    }
                    let token = toolbarState.beginLibraryFilterApplication()
                    loadPage()
                    if toolbarState.searchText.isEmpty {
                        filteredCount = nil
                    } else {
                        let query = SearchQueryParser.parse(toolbarState.searchText)
                        filteredCount = session.library?.bookCount(query: query)
                    }
                    toolbarState.finishLibraryFilterApplication(token: token)
                }
            }
            .onChange(of: toolbarState.activeFilterResult?.reloadToken) {
                if suppressNextReloadToken { suppressNextReloadToken = false; return }
                selectedIDs.removeAll()
                currentPage = 0; loadPage()
            }
    }

    /// Extraction refresh, visibility prefs, session lifecycle, and appear/disappear.
    private func attachAppearanceHandlers<V: View>(to view: V) -> some View {
        view
            .onChange(of: extractionRefreshToken) {
                loadAO3MetadataForCurrentPage()
            }
            .onChange(of: prefs.showSkippedCollection) {
                currentPage = 0
                if toolbarState.filterExpression.hasCompleteRules {
                    applyFilterRules()
                } else {
                    loadPage()
                }
            }
            .onChange(of: prefs.hideNonAO3PublisherBooks) {
                refreshVisibilitySnapshots()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                let persisted = UserDefaults.standard.bool(forKey: "groupBySeries")
                if toolbarState.groupBySeries != persisted {
                    toolbarState.groupBySeries = persisted
                    selectedIDs.removeAll()
                    currentPage = 0
                    loadPage()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .seriesOrMergedCollectionDidChange)) { _ in
                refreshBookStates()
            }
            .onChange(of: session.isOpen) {
                if session.isOpen {
                    selectedIDs.removeAll()
                    currentPage = 0
                    toolbarState.searchText = ""
                    toolbarState.activeFilterResult = nil
                    toolbarState.cancelLibraryFilterApplication()
                    toolbarState.filterExpression = FilterExpression()
                    if let lib = session.library {
                        CustomColumnConfig.shared.autoDetect(using: lib)
                    }
                    loadPage()
                    refreshBookStates()
                } else {
                    books = []; bookStates = [:]; selectedIDs.removeAll()
                }
            }
            .onAppear {
                if session.isOpen {
                    // Seed local state from session cache before the first
                    // loadPage() so the initial render is correct. On the
                    // first ever open the cache is empty and behaviour is
                    // unchanged; on subsequent mode switches it's populated.
                    likedIDs = session.cachedLikedIDs
                    readLaterIDs = session.cachedReadLaterIDs
                    skippedIDs = session.cachedSkippedIDs
                    seriesOrMergedIDs = session.cachedSeriesOrMergedIDs
                    ao3PublisherIDs = session.cachedAO3PublisherIDs
                    loadPage()
                    refreshBookStates()
                }
                // Register so LibraryWindowController can deliver committed filter rules
                toolbarState.registerFilterCommitHandler { [self] rule in
                    addOrReplaceRule(rule)
                }
            }
            .onDisappear {
                // Deregister when this view leaves the hierarchy (view mode switch)
                toolbarState.filterCommitHandler = nil
            }
    }

    private func attachSheets<V: View>(to view: V) -> some View {
        view
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
                        applyFilterRules()
                    },
                    onClear: {
                        toolbarState.filterExpression = FilterExpression()
                        toolbarState.activeFilterResult = nil
                        toolbarState.cancelLibraryFilterApplication()
                        currentPage = 0; loadPage()
                    }
                )
                .preferredColorScheme(prefs.resolvedLibraryColorScheme)
            }
            .sheet(isPresented: Binding(
                get: { toolbarState.showCollections },
                set: { toolbarState.showCollections = $0 }
            )) {
                CollectionsView(onSelectCollection: { collection in
                    addOrReplaceRule(FilterRule(field: .collection, op: .equals, value: collection.name))
                })
                .preferredColorScheme(prefs.resolvedLibraryColorScheme)
            }
            .sheet(isPresented: Binding(
                get: { toolbarState.showReadingGoal },
                set: { toolbarState.showReadingGoal = $0 }
            )) {
                ReadingGoalView()
                    .preferredColorScheme(prefs.resolvedLibraryColorScheme)
            }
            .onChange(of: toolbarState.triggerExport) {
                if toolbarState.triggerExport {
                    ExportManager.presentExportPanel(         // §1
                        books: books,
                        session: session,
                        filterResult: toolbarState.activeFilterResult,
                        toolbarState: toolbarState
                    )
                    toolbarState.triggerExport = false
                }
            }
            .onChange(of: toolbarState.triggerEPUBExport) {
                if toolbarState.triggerEPUBExport {
                    toolbarState.triggerEPUBExport = false
                    guard let libraryRoot = session.library?.root else { return }
                    Task { @MainActor in
                        // 1. Build the full export rows (needed for count and ao3Map).
                        let rows = await ExportManager.buildExportRows(
                            currentPageBooks: books,
                            session: session,
                            filterResult: toolbarState.activeFilterResult,
                            toolbarState: toolbarState
                        )
                        let count = rows.count
                        guard count > 0 else {
                            let a = NSAlert()
                            a.messageText = "Nothing to Export"
                            a.informativeText = "No matching EPUBs found with the current filter."
                            a.runModal()
                            return
                        }

                        // 2. Confirm with count warning.
                        let confirm = NSAlert()
                        confirm.messageText = "Export \(count) EPUB\(count == 1 ? "" : "s")?"
                        confirm.informativeText = "This will copy \(count) EPUB file\(count == 1 ? "" : "s") to a folder you choose. Large libraries may take a minute."
                        confirm.addButton(withTitle: "Export")
                        confirm.addButton(withTitle: "Cancel")
                        guard confirm.runModal() == .alertFirstButtonReturn else { return }

                        // 3. Folder picker.
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.prompt = "Choose Export Folder"
                        guard panel.runModal() == .OK, let destination = panel.url else { return }

                        // 4. Progress sheet on the library window.
                        let progressAlert = NSAlert()
                        progressAlert.messageText = "Exporting EPUBs…"
                        progressAlert.informativeText = "Copying 0 of \(count)"
                        progressAlert.addButton(withTitle: "")   // hidden — sheet has no buttons while running
                        let progressBar = NSProgressIndicator()
                        progressBar.style = .bar
                        progressBar.isIndeterminate = false
                        progressBar.minValue = 0
                        progressBar.maxValue = Double(count)
                        progressBar.doubleValue = 0
                        progressBar.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
                        progressAlert.accessoryView = progressBar

                        // Present as a sheet so the window is still visible behind it.
                        var sheet: NSWindow?
                        if let win = NSApp.keyWindow ?? NSApp.mainWindow {
                            progressAlert.beginSheetModal(for: win) { _ in }
                            sheet = win.attachedSheet
                        }

                        let ao3Map = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                            row.ao3.map { (row.book.id, $0) }
                        })
                        let (copied, skipped) = await ExportManager.exportEPUBs(
                            books: rows.map(\.book),
                            libraryRoot: libraryRoot,
                            destination: destination,
                            ao3Map: ao3Map,
                            groupBySeries: toolbarState.groupBySeries,
                            progress: { done in
                                Task { @MainActor in
                                    progressBar.doubleValue = Double(done)
                                    progressAlert.informativeText = "Copying \(done) of \(count)"
                                }
                            }
                        )

                        // 5. Dismiss progress sheet.
                        if let win = sheet?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow,
                           let attachedSheet = win.attachedSheet {
                            win.endSheet(attachedSheet)
                        }

                        // 6. Summary.
                        ExportManager.presentEPUBExportSummary(copied: copied, skipped: skipped)
                    }
                }
            }
    }

    private var rootContent: some View {
        VStack(spacing: 0) {
            Divider()
            if toolbarState.hasActiveFilter || activeFullTextPhrase != nil {
                activeFilterChip(count: toolbarState.activeFilterResult?.totalCount)
            }
            if !session.isOpen {
                emptyLibraryState
            } else if books.isEmpty && toolbarState.searchText.isEmpty && !toolbarState.hasActiveFilter {
                loadingState
            } else if books.isEmpty && (toolbarState.hasActiveFilter || !toolbarState.searchText.isEmpty) {
                noResultsState
            } else {
                itemList
            }
            Divider()
            footer
        }
    }

    // MARK: - Data loading

    private func loadPage() {
        let loadStart = LibraryFilterDebug.now()
        guard let library = session.library else { books = []; return }
        let rawQuery = toolbarState.searchText.isEmpty
            ? SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
            : SearchQueryParser.parse(toolbarState.searchText)
        var query = queryWithCachedFullText(rawQuery)
        // Inject pre-resolved synonym expansions so whereClause needs no actor
        // calls (Invariant 10). resolvedTagExpansions is populated async by
        // resolveTagExpansionsIfNeeded whenever the tag terms change.
        query.expandedTagTerms = resolvedTagExpansions
        if rawQuery.fulltextPhrase?.isEmpty == false && query.ftsMatchedIDs == nil {
            _ = startPendingSearchTextFullTextIfNeeded()
            return
        }

        if toolbarState.sortField == .random {
            let restrictIDs: [Int]?
            let filterForSQL: FilterExpression?
            if let result = toolbarState.activeFilterResult, result.isSQLBacked {
                restrictIDs = nil
                filterForSQL = toolbarState.filterExpression
            } else if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
                restrictIDs = visibleIDs(intersect(result.calibreIDs, with: query.ftsMatchedIDs))
                filterForSQL = nil
            } else if toolbarState.activeFilterResult != nil {
                books = []; items = []; hasNextPage = false
                rebuildItems(); loadAO3MetadataForCurrentPage(); pruneSelection()
                return
            } else {
                restrictIDs = nil
                filterForSQL = nil
            }
            let (page, hasMore) = library.randomSortedPage(
                offset: currentPage * pageSize, limit: pageSize,
                query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                filterTagExpansions: cachedFilterTagExpansions
            )
            books = page
            hasNextPage = hasMore
        } else if toolbarState.sortField == .wordCount {
            // §2a fix (2): word count can't be sorted by a single SQL ORDER BY —
            // see orderByClause(.wordCount) and wordCountSortedPage(...) for why.
            // Resolve the same three filter states as below, but route through the
            // full-set in-memory sort instead of an offset/limit SQL query.
            let restrictIDs: [Int]?
            let filterForSQL: FilterExpression?
            if let result = toolbarState.activeFilterResult, result.isSQLBacked {
                restrictIDs = nil
                filterForSQL = toolbarState.filterExpression
            } else if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
                restrictIDs = visibleIDs(intersect(result.calibreIDs, with: query.ftsMatchedIDs))
                filterForSQL = nil
            } else if toolbarState.activeFilterResult != nil {
                LibraryFilterDebug.log("loadPage.start", [
                    "surface": "list", "mode": "emptyExplicitIDs.wordCount", "page": currentPage
                ])
                books = []; items = []; hasNextPage = false
                rebuildItems(); loadAO3MetadataForCurrentPage(); pruneSelection()
                return
            } else {
                restrictIDs = nil
                filterForSQL = nil
            }
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list", "mode": "wordCountSorted", "page": currentPage,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            let (page, hasMore) = library.wordCountSortedPage(
                offset: currentPage * pageSize, limit: pageSize, ascending: toolbarState.ascending,
                query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                filterTagExpansions: cachedFilterTagExpansions
            )
            books = page
            hasNextPage = hasMore
        } else if let result = toolbarState.activeFilterResult, result.isSQLBacked {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list",
                "mode": "sqlPagedDeferredCount",
                "page": currentPage,
                "query": LibraryFilterDebug.summary(query: query),
                "filter": LibraryFilterDebug.summary(expression: toolbarState.filterExpression)
            ])
            let raw = library.books(
                offset: currentPage * pageSize, limit: pageFetchLimit,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query,
                filter: toolbarState.filterExpression,
                filterTagExpansions: cachedFilterTagExpansions
            )
            let visible = visibleBooks(raw)
            hasNextPage = raw.count == pageFetchLimit || visible.count > pageSize
            books = Array(visible.prefix(pageSize))
            scheduleDeferredSQLFilterCount(query: query)
        } else if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list",
                "mode": "explicitIDs",
                "page": currentPage,
                "candidateIDs": result.calibreIDs.count,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            let ids = visibleIDs(intersect(result.calibreIDs, with: query.ftsMatchedIDs))
            let raw = library.books(
                ids: ids,
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query
            )
            hasNextPage = raw.count > pageSize
            books = Array(raw.prefix(pageSize))
        } else if toolbarState.activeFilterResult != nil {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list",
                "mode": "emptyExplicitIDs",
                "page": currentPage
            ])
            books = []; items = []; hasNextPage = false
        } else {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list",
                "mode": "unfiltered",
                "page": currentPage,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            let raw = library.books(
                offset: currentPage * pageSize, limit: pageFetchLimit,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query
            )
            let visible = visibleBooks(raw)
            hasNextPage = raw.count == pageFetchLimit || visible.count > pageSize
            books = Array(visible.prefix(pageSize))
        }
        rebuildItems()
        loadAO3MetadataForCurrentPage()
        pruneSelection()
        LibraryFilterDebug.log("loadPage.end", [
            "surface": "list",
            "rows": books.count,
            "hasNext": hasNextPage,
            "elapsedMS": LibraryFilterDebug.elapsedMS(since: loadStart)
        ])

        // Log to activity feed — only on page 0 (new query), not pagination.
        // MainActor.assumeIsolated: loadPage() is always invoked from @MainActor
        // SwiftUI update paths; the explicit annotation satisfies Swift 6 strict
        // concurrency checking without introducing an async boundary.
        if currentPage == 0 {
            MainActor.assumeIsolated {
                let expr = toolbarState.filterExpression.hasCompleteRules
                    ? toolbarState.filterExpression : nil
                SearchActivityLog.shared.append(
                    searchText: toolbarState.searchText,
                    filterExpression: expr,
                    resultCount: books.count
                )
            }
        }
    }

    private func rebuildItems() {
        guard shouldGroupSeriesRows, let metaDB = session.metaDB, let library = session.library else {
            items = books.map { .book($0) }
            return
        }
        let pageBooks = books
        Task {
            let pageIDs = pageBooks.map(\.id)
            let pageMetadata: [Int: AO3MetadataRecord]
            let pageDiagnostics: [Int: AO3ExtractionDiagnostic]
            let entries: [SeriesCacheEntry]
            do { pageMetadata   = try await metaDB.ao3Metadata(for: pageIDs) }
            catch { pageMetadata = [:]; print("[LibraryRootView] rebuildItems: ao3Metadata(page) failed: \(error)") }
            do { pageDiagnostics = try await metaDB.ao3ExtractionDiagnostics(for: pageIDs) }
            catch { pageDiagnostics = [:]; print("[LibraryRootView] rebuildItems: ao3ExtractionDiagnostics(page) failed: \(error)") }
            do { entries = try await metaDB.seriesEntries(for: pageIDs) }
            catch { entries = []; print("[LibraryRootView] rebuildItems: seriesEntries(page) failed: \(error)") }
            let groupedEntries = Dictionary(grouping: entries.filter { !$0.isAnthology }, by: \.seriesKey)
            let seriesKeys = groupedEntries.keys.sorted()
            let allEntries: [SeriesCacheEntry]
            do { allEntries = try await metaDB.seriesEntries(keys: seriesKeys) }
            catch { allEntries = []; print("[LibraryRootView] rebuildItems: seriesEntries(keys) failed: \(error)") }
            let allIDs = Array(Set(allEntries.map(\.calibreID)))
            let allBooks = library.booksForIDs(allIDs)
            let seriesMetadata: [Int: AO3MetadataRecord]
            let seriesDiagnostics: [Int: AO3ExtractionDiagnostic]
            let singletonWarnings: [Int: SingletonSeriesWarning]
            let placeholders: [String: [SeriesPlaceholder]]
            do { seriesMetadata   = try await metaDB.ao3Metadata(for: allIDs) }
            catch { seriesMetadata = [:]; print("[LibraryRootView] rebuildItems: ao3Metadata(series) failed: \(error)") }
            do { seriesDiagnostics = try await metaDB.ao3ExtractionDiagnostics(for: allIDs) }
            catch { seriesDiagnostics = [:]; print("[LibraryRootView] rebuildItems: ao3ExtractionDiagnostics(series) failed: \(error)") }
            do { singletonWarnings = try await metaDB.singletonNonLeadingSeriesEntries(for: pageIDs) }
            catch { singletonWarnings = [:]; print("[LibraryRootView] rebuildItems: singletonNonLeadingSeriesEntries failed: \(error)") }
            do { placeholders = try await metaDB.placeholders(for: seriesKeys) }
            catch { placeholders = [:]; print("[LibraryRootView] rebuildItems: placeholders failed: \(error)") }
            let warnings = enrichWarnings(singletonWarnings, books: pageBooks)
            let byID = Dictionary(uniqueKeysWithValues: allBooks.map { ($0.id, $0) })
            let entriesBySeries = Dictionary(grouping: allEntries.filter { !$0.isAnthology }, by: \.seriesKey)
            var collapsedIDs = Set<Int>()
            var seriesByKey: [String: SeriesGroup] = [:]

            for (seriesKey, entries) in entriesBySeries {
                let sortedEntries = entries.sorted { $0.seriesIndex < $1.seriesIndex }
                let works = sortedEntries.compactMap { byID[$0.calibreID] }
                guard works.count > 1 else { continue }
                guard works.allSatisfy({ !isAnthology($0) }) else { continue }
                collapsedIDs.formUnion(works.map(\.id))
                let metadata = works.compactMap { seriesMetadata[$0.id] }
                let metadataByID = seriesMetadata
                let indices = sortedEntries.map(\.seriesIndex)
                let missing = missingIndices(in: indices)
                let ratings = Array(Set(works.flatMap(\.tags).filter { if case .rating = AO3TagKind.classify($0) { return true }; return false })).sorted()
                let warnings = Array(Set(works.flatMap(\.tags).filter { if case .warning = AO3TagKind.classify($0) { return true }; return false })).sorted()
                let categories = Array(Set(metadata.flatMap(\.categories) + works.flatMap(\.tags).filter { if case .category = AO3TagKind.classify($0) { return true }; return false })).sorted()
                let fandoms = Array(Set(metadata.flatMap(\.fandoms))).sorted()
                let relationships = Array(Set(metadata.flatMap(\.relationships))).sorted()
                let characters = Array(Set(metadata.flatMap(\.characters))).sorted()
                let additionalTags = Array(Set(metadata.flatMap(\.additionalTags))).sorted()
                let tags = Array(Set(works.flatMap(\.tags) + additionalTags)).sorted()
                let authors = Array(Set(works.flatMap(\.authors))).sorted()
                let descriptions = works.compactMap(\.displayComment)
                let chapterRecords = works.compactMap { metadataByID[$0.id] }.filter { $0.chapterCurrent != nil }
                let knownChapterCurrentTotal = chapterRecords.reduce(0) { $0 + ($1.chapterCurrent ?? 0) }
                let chapterTotalKnownForAll = !chapterRecords.isEmpty && chapterRecords.count == works.count && chapterRecords.allSatisfy { $0.chapterTotal != nil }
                #if DEBUG
                works.forEach { logMissingVisibleWorkMetadata(book: $0, ao3Metadata: metadataByID[$0.id], diagnostic: seriesDiagnostics[$0.id]) }
                #endif
                seriesByKey[seriesKey] = SeriesGroup(
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
                    allTags: tags,
                    allAuthors: authors,
                    allDescriptions: descriptions,
                    totalWordCount: works.reduce(0) { total, work in
                        total + (seriesMetadata[work.id]?.wordCount ?? work.wordCount ?? 0)
                    },
                    chapterCurrentTotal: chapterRecords.isEmpty ? nil : knownChapterCurrentTotal,
                    chapterTotalTotal: chapterTotalKnownForAll ? chapterRecords.reduce(0) { $0 + ($1.chapterTotal ?? 0) } : nil,
                    hasUnknownChapterTotal: !chapterRecords.isEmpty && !chapterTotalKnownForAll,
                    earliestPublished: metadata.compactMap { parseISODate($0.publishedDate) }.min(),
                    latestUpdated: metadata.compactMap { parseISODate($0.updatedDate) }.max(),
                    workIndices: indices,
                    missingIndices: missing,
                    placeholders: placeholders[seriesKey] ?? [],
                    isComplete: !metadata.isEmpty && metadata.allSatisfy(\.isComplete)
                )
            }

            var nextItems: [LibraryItem] = []
            var emittedSeries = Set<String>()
            for book in pageBooks {
                if let entry = entries.first(where: { $0.calibreID == book.id && !$0.isAnthology }),
                   let group = seriesByKey[entry.seriesKey],
                   !emittedSeries.contains(entry.seriesKey) {
                    nextItems.append(.series(group))
                    emittedSeries.insert(entry.seriesKey)
                } else if !collapsedIDs.contains(book.id) {
                    nextItems.append(.book(book))
                }
            }
            await MainActor.run {
                items = nextItems
                ao3Metadata = pageMetadata
                ao3ExtractionDiagnostics = pageDiagnostics
                singletonSeriesWarnings = warnings
            }
        }
    }

    private func loadAO3MetadataForCurrentPage() {
        let ids = books.map(\.id)
        guard !ids.isEmpty, let metaDB = session.metaDB else {
            ao3Metadata = [:]
            ao3ExtractionDiagnostics = [:]
            singletonSeriesWarnings = [:]
            return
        }
        Task {
            let metadata = (try? await metaDB.ao3Metadata(for: ids)) ?? [:]
            let diagnostics = (try? await metaDB.ao3ExtractionDiagnostics(for: ids)) ?? [:]
            let warnings = enrichWarnings((try? await metaDB.singletonNonLeadingSeriesEntries(for: ids)) ?? [:], books: books)
            await MainActor.run {
                ao3Metadata = metadata
                ao3ExtractionDiagnostics = diagnostics
                singletonSeriesWarnings = warnings
            }
        }
    }

    private var shouldGroupSeriesRows: Bool {
        toolbarState.groupBySeries || toolbarState.filterExpression.hasSeriesOrMergedEqualsRule
    }

    private func visibleIDs(_ ids: [Int]) -> [Int] {
        // Only suppress seriesOrMergedIDs members when series grouping is active and a
        // SeriesGroup row is being shown to represent them. Without grouping, this filter
        // silently drops books that are rn>1 in one series but rn=1 in another — the
        // multi-series-membership case (e.g. "Star Wars Drabbles" + "100 Star Wars Women
        // Drabbles") causes all works in a series to vanish from a bare series: search.
        ids.filter { id in
            (prefs.showSkippedCollection || !skippedIDs.contains(id)) &&
            (!shouldGroupSeriesRows || !seriesOrMergedIDs.contains(id)) &&
            (!prefs.hideNonAO3PublisherBooks || ao3PublisherIDs.contains(id))
        }
    }

    private func intersect(_ ids: [Int], with optionalIDs: [Int]?) -> [Int] {
        guard let other = optionalIDs else { return ids }
        let allowed = Set(other)
        return ids.filter { allowed.contains($0) }
    }

    private func visibleBooks(_ raw: [CalibreBook]) -> [CalibreBook] {
        raw.filter { book in
            (prefs.showSkippedCollection || !skippedIDs.contains(book.id)) &&
            (!shouldGroupSeriesRows || !seriesOrMergedIDs.contains(book.id)) &&
            (!prefs.hideNonAO3PublisherBooks || book.isAO3PublisherBook) &&
            !isAnthology(book)
        }
    }

    private func refreshVisibilitySnapshots(resetPage: Bool = true) {
        ao3PublisherIDs = session.library?.ao3PublisherBookIDs() ?? []
        if resetPage { currentPage = 0 }
        if toolbarState.filterExpression.hasCompleteRules {
            applyFilterRules()
        } else {
            loadPage()
        }
    }

    private func refreshBookStates() {
        let all = (try? modelContext.fetch(FetchDescriptor<BookState>())) ?? []
        bookStates = all.reduce(into: [:]) { $0[$1.calibreID] = $1 }
        Task {
            async let fetchedLiked = session.collectionStore?.likedIDs()
            async let fetchedReadLater = session.collectionStore?.members(of: SystemCollectionID.readLater)
            async let fetchedSkipped = session.collectionStore?.members(of: SystemCollectionID.skipped)
            async let fetchedSeriesOrMerged = session.collectionStore?.members(of: SystemCollectionID.seriesOrMerged)
            let capturedLibrary = session.library
            let currentAO3PublisherIDs = await Task.detached(priority: .userInitiated) {
                capturedLibrary?.ao3PublisherBookIDs() ?? []
            }.value
            let currentLiked = (try? await fetchedLiked) ?? []
            let currentReadLater = Set((try? await fetchedReadLater) ?? [])
            let currentSkipped = Set((try? await fetchedSkipped) ?? [])
            let currentSeriesOrMerged = Set((try? await fetchedSeriesOrMerged) ?? [])
            await MainActor.run {
            likedIDs = currentLiked
            readLaterIDs = currentReadLater
            session.cachedReadLaterIDs = currentReadLater
            skippedIDs = currentSkipped
            seriesOrMergedIDs = currentSeriesOrMerged
            ao3PublisherIDs = currentAO3PublisherIDs
            // Write back to session cache so the next mode switch gets
            // correct data on its first render.
            session.cachedLikedIDs = currentLiked
            session.cachedSkippedIDs = currentSkipped
            session.cachedSeriesOrMergedIDs = currentSeriesOrMerged
            session.cachedAO3PublisherIDs = currentAO3PublisherIDs
            pruneSelection()
            currentPage = 0
            loadPage()
            }
        }
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
            "surface": "list",
            "mode": "sqlPagedDeferredCount",
            "query": querySignature,
            "filter": filterSignature
        ])
        filterCountTask = Task {
            let count = library.bookCount(query: query, filter: expression,
                                          filterTagExpansions: cachedFilterTagExpansions)
            await MainActor.run {
                guard !Task.isCancelled,
                      toolbarState.activeFilterResult?.isSQLBacked == true,
                      toolbarState.activeFilterResult?.totalCount == nil,
                      LibraryFilterDebug.summary(expression: toolbarState.filterExpression) == filterSignature,
                      LibraryFilterDebug.summary(query: queryWithCachedFullText(toolbarState.searchText.isEmpty
                          ? SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
                          : SearchQueryParser.parse(toolbarState.searchText))) == querySignature else {
                    LibraryFilterDebug.log("deferredCount.discard", [
                        "surface": "list",
                        "mode": "sqlPagedDeferredCount"
                    ])
                    return
                }
                toolbarState.activeFilterResult = FilterResult(
                    calibreIDs: [],
                    totalCount: count,
                    isSQLBacked: true
                )
                LibraryFilterDebug.log("deferredCount.apply", [
                    "surface": "list",
                    "mode": "sqlPagedDeferredCount",
                    "count": count
                ])
            }
        }
    }

    private func applyFilterRules() {
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
            currentPage = 0; loadPage(); return
        }
        let expression = toolbarState.filterExpression
        LibraryFilterDebug.log("applyFilter.start", [
            "surface": "list",
            "rules": LibraryFilterDebug.summary(expression: expression),
            "sqlPageable": expression.isSQLPageable
        ])
        if expression.isSQLPageable {
            suppressNextReloadToken = true   // §perf: we call loadPage() below; skip onChange duplicate
            toolbarState.activeFilterResult = FilterResult(calibreIDs: [], isSQLBacked: true)
            toolbarState.clearPendingFullTextSearch()
            toolbarState.cancelLibraryFilterApplication()
            selectedIDs.removeAll()
            currentPage = 0
            loadPage()
            LibraryFilterDebug.log("applyFilter.end", [
                "surface": "list",
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
            selectedIDs.removeAll()
            currentPage = 0
            suppressNextReloadToken = true   // §perf: we call loadPage() below; skip onChange duplicate
            loadPage()
            LibraryFilterDebug.log("applyFilter.end", [
                "surface": "list",
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
            let needsLiked = expression.groups.flatMap(\.rules).contains { $0.field == .isLiked }
            let currentLikedIDs = needsLiked ? ((try? await session.collectionStore?.likedIDs()) ?? []) : []
            let needsCollection = expression.groups.flatMap(\.rules).contains { $0.field == .collection }
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
                    collectionMap[SystemCollectionID.seriesOrMergedName] = (try? await metaDB.collapsedSeriesRepresentativeIDs()) ?? []
                }
            }
            let fulltextMap = Dictionary(uniqueKeysWithValues: fulltextRules.map { rule in
                let key = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return (key, Set(session.cachedFulltextIDs(for: rule.value) ?? []))
            })
            // Snapshot the var maps as immutable lets before any async let
            // binding below. Swift 6 forbids capturing a var into a
            // concurrently-executing closure — these two lines fix the
            // data-race warnings on collectionMap and statusMap.
            let collectionMapSnapshot = collectionMap
            let statusMapSnapshot = statusMap
            // Run matchingIDs and all post-filter data fetches concurrently and
            // off the main actor. matchingIDs uses Task.detached internally;
            // the three membership fetches are actor-isolated but independent.
            // §6: Crossover map — IDs with fandoms.count > 1 in ao3_metadata
            var crossoverMap: Set<Int> = []
            let needsCrossover = expression.groups.flatMap(\.rules).contains { $0.field == .crossover }
            if needsCrossover {
                crossoverMap = await Task.detached(priority: .userInitiated) {
                    library.crossoverBookIDs()
                }.value
            }
            // §perf Fix 6: Two-pass word-count filter.
            // Pass 1 runs all non-wordcount rules to get candidates; pass 2 fetches
            // word counts only for candidates, then applies wordcount rules in-memory.
            let needsWordCount = expression.groups.flatMap(\.rules).contains {
                $0.field == .wordCountGT || $0.field == .wordCountLT
            }
            let needsWordCountFallback = needsWordCount && CustomColumnConfig.shared.wordCountLabel == nil

            // Strip wordcount rules for the first pass (no-op if fallback not needed).
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

            var filterTagExpansions: [String: [String]] = [:]
            if let metaDB = session.metaDB {
                let tagValues = Set(expression.groups.flatMap(\.rules)
                    .filter { $0.field == .tag && $0.isComplete }
                    .map(\.value))
                for value in tagValues {
                    filterTagExpansions[value] = await metaDB.expandedTerms(for: value)
                }
            }
            cachedFilterTagExpansions = filterTagExpansions
            let builder = FilterBuilder(library: library, ftsLibrary: session.ftsLibrary,
                                        tagExpansions: filterTagExpansions)

            // Pass 1: run all non-wordcount rules.
            let pass1Result = await builder.matchingIDs(
                expression: expressionWithoutWordCount,
                likedIDs: currentLikedIDs,
                collectionMap: collectionMapSnapshot,
                statusMap: statusMapSnapshot,
                fulltextMap: fulltextMap,
                crossoverMap: crossoverMap,
                wordCountFallbackMap: nil
            )

            // Pass 2: if wordcount fallback is needed, fetch counts for candidates only.
            var finalResult: FilterResult
            if needsWordCountFallback {
                let candidateIDs = pass1Result.calibreIDs
                let fallbackMap = await Task.detached(priority: .userInitiated) {
                    library.ao3WordCounts(ids: candidateIDs)
                }.value

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
                    finalResult = FilterResult(calibreIDs: combined, totalCount: combined.count)
                } else {
                    finalResult = pass1Result
                }
            } else {
                finalResult = pass1Result
            }

            async let fetchedSkipped = session.collectionStore?.members(of: SystemCollectionID.skipped)
            async let fetchedSeriesOrMerged = session.collectionStore?.members(of: SystemCollectionID.seriesOrMerged)
            let capturedLibrary2 = session.library
            let currentSkipped = Set((try? await fetchedSkipped) ?? [])
            let currentSeriesOrMerged = Set((try? await fetchedSeriesOrMerged) ?? [])
            let publisherIDs = await Task.detached(priority: .userInitiated) {
                capturedLibrary2?.ao3PublisherBookIDs() ?? []
            }.value
            let filteredIDs = prefs.showSkippedCollection
                ? finalResult.calibreIDs
                : finalResult.calibreIDs.filter { !currentSkipped.contains($0) }
            let visibleFilteredIDs = filteredIDs.filter { !currentSeriesOrMerged.contains($0) }
                .filter { !prefs.hideNonAO3PublisherBooks || publisherIDs.contains($0) }
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
            selectedIDs.removeAll()
            suppressNextReloadToken = true   // §perf: we call loadPage() below; skip onChange duplicate
            currentPage = 0; loadPage()
            LibraryFilterDebug.log("applyFilter.end", [
                "surface": "list",
                "mode": "explicitIDs",
                "ids": visibleFilteredIDs.count,
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
            ])
        }
    }

    /// Add or replace a filter rule. All quick taps (tag, author, rating, etc.)
    /// go through this path — no separate LibraryFilter system.
    private func addOrReplaceRule(_ rule: FilterRule) {
        if toolbarState.filterExpression.groups.isEmpty {
            toolbarState.filterExpression.groups = [FilterGroup()]
        }
        let allRules = toolbarState.filterExpression.groups.flatMap(\.rules)
        let isDuplicate = allRules.contains {
            $0.field == rule.field && $0.value == rule.value && $0.op == rule.op
        }
        guard !isDuplicate else { return }
        // For single-value fields (author, series) replace instead of stacking
        if rule.field == .authorName || rule.field == .series {
            toolbarState.filterExpression.groups[0].rules.removeAll { $0.field == rule.field }
        }
        toolbarState.filterExpression.groups[0].rules.append(rule)
        applyFilterRules()
    }

    private func startPendingSearchTextFullTextIfNeeded() -> Bool {
        guard let phrase = activeFullTextPhrase else {
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
                guard toolbarState.pendingFullTextSearch?.token == token,
                      toolbarState.libraryFilterApplicationToken == applicationToken,
                      activeFullTextPhrase == phrase else { return }
                defer { toolbarState.finishLibraryFilterApplication(token: applicationToken) }
                applyResolvedSearchTextFullText(phrase: phrase, ids: ids)
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
                guard toolbarState.pendingFullTextSearch?.token == token,
                      toolbarState.libraryFilterApplicationToken == applicationToken,
                      toolbarState.filterExpression.groups.flatMap(\.rules).contains(where: {
                          $0.field == .fulltext && $0.value == phrase && $0.isComplete
                      }) else { return }
                toolbarState.clearPendingFullTextSearch()
                toolbarState.finishLibraryFilterApplication(token: applicationToken)
                applyFilterRules()
            }
        }
    }

    private func applyResolvedSearchTextFullText(phrase: String, ids: [Int]) {
        guard activeFullTextPhrase == phrase else { return }
        toolbarState.activeFilterResult = FilterResult(calibreIDs: ids, totalCount: ids.count)
        toolbarState.clearPendingFullTextSearch()
        filteredCount = ids.count
        currentPage = 0
        loadPage()
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

    /// Resolves synonym expansions for `terms` via `AmbrosiaMetaDB` (Invariant 10)
    /// and stores them in `resolvedTagExpansions`. Called whenever tag terms in the
    /// search field change. `loadPage` reads the result synchronously via
    /// `query.expandedTagTerms` — no actor calls inside the hot page-fetch path.
    private func resolveTagExpansionsIfNeeded(terms: [String]) {
        guard !terms.isEmpty, let metaDB = session.metaDB else {
            resolvedTagExpansions = [:]
            return
        }
        Task { @MainActor in
            var resolved: [String: [String]] = [:]
            for term in terms {
                resolved[term] = await metaDB.expandedTerms(for: term)
            }
            resolvedTagExpansions = resolved
            // Re-run loadPage now that expansions are available, so the WHERE
            // clause reflects synonym expansion on the first keystroke delay.
            loadPage()
        }
    }

    private func addTagPillRule(tag: String, field: FilterField) {
        addOrReplaceRule(FilterRuleFactory.tagPillRule(label: tag, field: field))
    }

    // MARK: - Subviews

    private var activeFullTextPhrase: String? {
        let phrase = SearchQueryParser.parse(toolbarState.searchText).fulltextPhrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return phrase?.isEmpty == false ? phrase : nil
    }

    private func activeFilterChip(count: Int?) -> some View {
        let completeRules = toolbarState.filterExpression.groups.flatMap(\.rules).filter(\.isComplete)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                Text(count.map { "\($0) result\($0 == 1 ? "" : "s")" } ?? "Filtered results")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit") { toolbarState.showFilterDrawer = true }
                    .buttonStyle(.borderless).font(.caption)
                Button {
                    toolbarState.filterExpression = FilterExpression()
                    toolbarState.activeFilterResult = nil
                    toolbarState.cancelLibraryFilterApplication()
                    currentPage = 0; loadPage()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            FlowLayout(spacing: 4) {
                ForEach(completeRules) { rule in
                    let negated = rule.op == .notContains || rule.op == .notEquals
                    HStack(spacing: 3) {
                        if negated {
                            Text("NOT")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.red.opacity(0.85))
                                .clipShape(Capsule())
                        }
                        Text(rule.field.label)
                            .font(.caption2).foregroundStyle(.secondary)
                        if !rule.value.isEmpty {
                            Text(rule.value).font(.caption2.bold())
                        }
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(negated ? Color.red.opacity(0.08) : Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(
                        negated ? Color.red.opacity(0.3) : Color.accentColor.opacity(0.3),
                        lineWidth: 0.5))
                }
                if let phrase = activeFullTextPhrase {
                    HStack(spacing: 3) {
                        Text("Full Text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(phrase)
                            .font(.caption2.bold())
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5))
                }
                if let pending = toolbarState.pendingFullTextSearch {
                    HStack(spacing: 3) {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                        Text("Searching")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(pending.phrase)
                            .font(.caption2.bold())
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var itemList: some View {
        List(items) { item in
            itemRow(item)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func itemRow(_ item: LibraryItem) -> some View {
        switch item {
        case .book(let book):
            bookRow(book)
        case .series(let series):
            seriesRow(series)
        }
    }

    private func bookRow(_ book: CalibreBook) -> some View {
        BookListRow(
            book: book,
            bookState: bookStates[book.id],
            ao3Metadata: ao3Metadata[book.id],
            ao3ExtractionDiagnostic: ao3ExtractionDiagnostics[book.id],
            singletonSeriesWarning: singletonSeriesWarnings[book.id],
            isLiked: likedIDs.contains(book.id),
            hideFanworksTagPill: prefs.hideFanworksTagPill,
            correctCalibreAmpEntities: prefs.correctCalibreAmpEntities,
            modelContext: modelContext,
            onTagTap: { tag, field in
                addTagPillRule(tag: tag, field: field)
            },
            onAuthorTap: { author in
                addOrReplaceRule(FilterRule(field: .authorName, op: .equals, value: author))
            },
            onOpenSelected: { open(selectedBooks(fallback: book)) },
            isInReadLater: readLaterIDs.contains(book.id),
            onReadLaterToggle: { toggleReadLater(for: book) },
            onLikeToggle: { toggleLike(for: book) },
            onLikeSelected: { setLiked(selectedBooks(fallback: book), liked: true) },
            onUnlikeSelected: { setLiked(selectedBooks(fallback: book), liked: false) },
            onReadLater: { addToReadLater(selectedBooks(fallback: book)) },
            onSkip: { skip(selectedBooks(fallback: book)) },
            onMarkRead: { markRead(selectedBooks(fallback: book)) },
            onResetProgress: { resetProgress(selectedBooks(fallback: book)) },
            onCollectionChanged: {
                session.bumpMembershipVersion()
                refreshVisibilitySnapshots(resetPage: false)
            },
            selectedCount: selectedBooks(fallback: book).count,
            selectedIDs: selectedBookIDs(fallback: book)
        )
        .equatable()
        .listRowSeparator(.visible)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func seriesRow(_ series: SeriesGroup) -> some View {
        SeriesListRow(
            series: series,
            hideFanworksTagPill: prefs.hideFanworksTagPill,
            isLiked: series.works.allSatisfy { likedIDs.contains($0.id) },
            onTagTap: { tag, field in
                addTagPillRule(tag: tag, field: field)
            },
            onLikeToggle: { toggleLike(for: series) },
            onOpen: { AppDelegate.shared?.openReaderWindow(target: .series(series), modelContext: modelContext) },
            onReadLater:      { addToReadLater(series.works) },
            onSkip:           { skip(series.works) },
            onMarkRead:       { markRead(series.works) },
            onResetProgress:  { resetProgress(series.works) },
            onCollectionChanged: { refreshBookStates() }
        )
        .listRowSeparator(.visible)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func toggleLike(for book: CalibreBook) {
        Task {
            try? await session.collectionStore?.toggleLiked(calibreID: book.id)
            session.bumpMembershipVersion()
            let refreshed = (try? await session.collectionStore?.likedIDs()) ?? []
            await MainActor.run {
                likedIDs = refreshed
                session.cachedLikedIDs = refreshed
                // Only re-run the filter when the active filter actually uses isLiked.
                // For all other filters (and no filter) the star state is reflected
                // immediately via likedIDs without touching currentPage or loadPage().
                let filterUsesLiked = toolbarState.filterExpression.groups
                    .flatMap(\.rules).contains { $0.field == .isLiked }
                if filterUsesLiked { applyFilterRules() }
            }
        }
    }

    private func toggleLike(for series: SeriesGroup) {
        let ids = series.works.map(\.id)
        let shouldLike = !series.works.allSatisfy { likedIDs.contains($0.id) }
        Task {
            try? await session.collectionStore?.setLiked(calibreIDs: ids, liked: shouldLike)
            session.bumpMembershipVersion()
            let refreshed = (try? await session.collectionStore?.likedIDs()) ?? []
            await MainActor.run {
                likedIDs = refreshed
                session.cachedLikedIDs = refreshed
                let filterUsesLiked = toolbarState.filterExpression.groups
                    .flatMap(\.rules).contains { $0.field == .isLiked }
                if filterUsesLiked { applyFilterRules() }
            }
        }
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
            let refreshed = Set((try? await session.collectionStore?.members(of: SystemCollectionID.readLater)) ?? [])
            await MainActor.run {
                readLaterIDs = refreshed
                session.cachedReadLaterIDs = refreshed
            }
        }
    }

    private func open(_ books: [CalibreBook]) {
        for book in books {
            AppDelegate.shared?.openReaderWindow(book: book, modelContext: modelContext)
        }
    }

    private func enrichWarnings(_ warnings: [Int: SingletonSeriesWarning], books: [CalibreBook]) -> [Int: SingletonSeriesWarning] {
        let titlesByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.displayTitle) })
        return warnings.reduce(into: [:]) { result, pair in
            let (id, warning) = pair
            result[id] = SingletonSeriesWarning(
                seriesKey: warning.seriesKey,
                seriesName: warning.seriesName,
                seriesIndex: warning.seriesIndex,
                title: titlesByID[id] ?? warning.title
            )
        }
    }

    private func selectedBooks(fallback book: CalibreBook) -> [CalibreBook] {
        let selected = books.filter { selectedIDs.contains($0.id) }
        return selected.isEmpty ? [book] : selected
    }

    private func selectedBookIDs(fallback book: CalibreBook) -> [Int] {
        let ids = selectedBooks(fallback: book).map(\.id)
        return ids.isEmpty ? [book.id] : ids
    }

    private func pruneSelection() {
        let visible = Set(books.map(\.id))
        selectedIDs.formIntersection(visible)
    }

    private func setLiked(_ books: [CalibreBook], liked: Bool) {
        let ids = books.map(\.id)
        Task {
            try? await session.collectionStore?.setLiked(calibreIDs: ids, liked: liked)
            session.bumpMembershipVersion()  // §7
            likedIDs = (try? await session.collectionStore?.likedIDs()) ?? []
        }
    }

    private func addToReadLater(_ books: [CalibreBook]) {
        let ids = books.map(\.id)
        Task {
            try? await session.collectionStore?.bulkAdd(calibreIDs: ids, to: SystemCollectionID.readLater)
            session.bumpMembershipVersion()  // §7
        }
    }

    private func skip(_ books: [CalibreBook]) {
        Task {
            for book in books {
                try? await session.collectionStore?.skipBook(calibreID: book.id)
                skippedIDs.insert(book.id)
            }
            session.bumpMembershipVersion()  // §7
            applyFilterRules()
        }
    }

    private func markRead(_ books: [CalibreBook]) {
        let ids = books.map(\.id)
        for calibreID in ids {
            let state = stateForMutation(calibreID)
            state.markRead()
            bookStates[calibreID] = state
        }
        try? modelContext.save()
        Task {
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
        }
    }

    private func resetProgress(_ books: [CalibreBook]) {
        let ids = books.map(\.id)
        for calibreID in ids {
            let state = stateForMutation(calibreID)
            state.resetReadingProgress()
            bookStates[calibreID] = state
        }
        try? modelContext.save()
        Task {
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
        }
    }

    private func stateForMutation(_ calibreID: Int) -> BookState {
        var desc = FetchDescriptor<BookState>(
            predicate: #Predicate { $0.calibreID == calibreID }
        )
        desc.fetchLimit = 1
        let state = (try? modelContext.fetch(desc).first) ?? BookState(calibreID: calibreID)
        if state.modelContext == nil {
            modelContext.insert(state)
        }
        return state
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("← Previous") { currentPage -= 1 }.disabled(currentPage == 0).buttonStyle(.borderless)
            Spacer()
            if session.isOpen {
                let start = books.isEmpty ? 0 : currentPage * pageSize + 1
                let end   = currentPage * pageSize + books.count
                Text("\(start)–\(end) of \(displayCount)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Next →") { currentPage += 1 }.disabled(!hasNextPage).buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(libraryBGColor)
    }

    private var emptyLibraryState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "books.vertical").font(.system(size: 48)).foregroundStyle(.quaternary)
            Text("No library open").font(.title3).foregroundStyle(.secondary)
            Button("Open Calibre Library…") { AppDelegate.shared?.chooseLibraryFolder() }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer(); ProgressView(); Text("Loading…").foregroundStyle(.secondary); Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("No matching fics")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

