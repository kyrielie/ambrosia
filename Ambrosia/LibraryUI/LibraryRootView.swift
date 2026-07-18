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
    // Finding 12: set true if any of rebuildItems' eight AmbrosiaMetaDB calls throws
    // (locked file, disk read error, corrupt row). Without this, a failure and an
    // honestly-empty result (e.g. "this book has no series") are indistinguishable
    // to the user. Reset at the start of each rebuildItems() run.
    @State private var rebuildDegraded: Bool = false
    @State private var hasNextPage  = false
    // §Phase2-Pass1: offsetState.currentPage, offsetState.rawSQLOffset, offsetState.rawSQLOffsetHistory, and
    // offsetState.rawSQLOffsetOverflow used to be four independent @State vars, reset
    // together at ~15 call sites throughout this file. Bundled into one
    // PagingOffsetState so LibraryQueryController (Pass 4/5) can take one
    // inout value instead of four loose parameters. See PagingOffsetState's
    // doc comment for why this stays owned per-view rather than shared.
    @State private var offsetState = PagingOffsetState()
    @State private var filteredCount: Int? = nil

    @State private var bookStates: [Int: BookState] = [:]
    @State private var ao3Metadata: [Int: AO3MetadataRecord] = [:]
    @State private var ao3ExtractionDiagnostics: [Int: AO3ExtractionDiagnostic] = [:]
    @State private var singletonSeriesWarnings: [Int: [SingletonSeriesWarning]] = [:]
    // Seeded from LibrarySession cache so the first render on every mode
    // switch uses correct membership data — no flash of wrong ordering.
    @State private var likedIDs: Set<Int> = []
    @State private var readLaterIDs: Set<Int> = []
    @State private var skippedIDs: Set<Int> = []
    @State private var seriesOrMergedIDs: Set<Int> = []
    @State private var ao3PublisherIDs: Set<Int> = []
    @State private var anthologyIDs: Set<Int> = []
    @State private var duplicateLoserIDs: Set<Int> = []
    /// Native List selection, keyed by `LibraryItem.id` (String) so both plain
    /// book rows and series-group rows can be selected/highlighted/arrow-key-
    /// navigated the same way a Finder-style list would. This is the source of
    /// truth for what's highlighted; `selectedIDs` below is derived from it.
    @State private var selectedItemIDs: Set<String> = []
    /// Calibre book IDs implied by `selectedItemIDs` — a series selection expands
    /// to every work in that series. This is what `selectedBooks(fallback:)` and
    /// the "Selected" context-menu actions actually operate on; it is recomputed
    /// whenever `selectedItemIDs` or `items` changes, never mutated directly.
    private var selectedIDs: Set<Int> {
        var ids = Set<Int>()
        for item in items where selectedItemIDs.contains(item.id) {
            switch item {
            case .book(let book): ids.insert(book.id)
            case .series(let series): ids.formUnion(series.works.map(\.id))
            case .orphanedSeriesEntry(let book, _): ids.insert(book.id)
            }
        }
        return ids
    }
    // §Phase2: shared visibility-filtering logic, also owned by
    // EmailLibraryViewController. Stateless aside from its debug-log label,
    // so a plain `let` (not `@State`) is correct here.
    private let queryController = LibraryQueryController(surfaceLabel: "list")
    @State private var fullTextTask: Task<Void, Never>? = nil
    @State private var filterCountTask: Task<Void, Never>? = nil
    @State private var rebuildTask: Task<Void, Never>? = nil
    // F.3: series-grouped, visibility-aware total, computed by
    // CalibreLibrary.visibleBookCount and used for "Page X of Y" in the
    // footer while shouldGroupSeriesRows is true. nil is the "not yet
    // computed" sentinel — the footer must not show a stale/wrong number
    // while a recompute (triggered by loadPage()) is in flight.
    @State private var groupAwareTotalCount: Int? = nil
    @State private var groupAwareCountTask: Task<Void, Never>? = nil
    // Every `Task { await loadPage() }` call site below now goes through this
    // instead of being fire-and-forget. Previously ~20 sites (sort/filter/page
    // changes) could each spawn an untracked Task, and nothing cancelled a
    // still-running one when a newer change superseded it — same-surface calls
    // could interleave and last-write-wins on `books`/`items`/`hasNextPage` in
    // an undefined order, and a task begun just before switching away from this
    // view mode kept running with nothing to stop it. Matches the existing
    // tracked-task idiom already used for fullTextTask/filterCountTask/rebuildTask.
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
            .onChange(of: offsetState.currentPage)                { Task { await loadPage() } }
            .onChange(of: toolbarState.sortField)     { selectedItemIDs.removeAll(); offsetState.resetForNewFilter(); Task { await loadPage() } }
            .onChange(of: toolbarState.ascending)     { selectedItemIDs.removeAll(); offsetState.resetForNewFilter(); Task { await loadPage() } }
            .onChange(of: toolbarState.reshuffleToken)   { Task { await loadPage() } }
            .onChange(of: toolbarState.groupBySeries) { selectedItemIDs.removeAll(); offsetState.resetForNewFilter(); Task { await loadPage() } }
            .onChange(of: toolbarState.filterExpression) {
                // AO3FilterPopupWindowController's popup lives in its own NSWindow
                // and writes toolbarState.filterExpression directly (no shared view
                // tree with LibraryRootView to route an explicit apply call through).
                // Without this handler that write was inert: applyFilterRules() --
                // the only thing that turns filterExpression into an actual
                // activeFilterResult/reload -- was only ever called from this
                // view's own addOrReplaceRule(_:) quick-filter path.
                selectedItemIDs.removeAll()
                offsetState.resetForNewFilter()
                if toolbarState.filterExpression.hasCompleteRules {
                    applyFilterRules()
                } else {
                    Task { await loadPage() }
                }
            }
            .onChange(of: toolbarState.searchText) {
                selectedItemIDs.removeAll()
                offsetState.resetForNewFilter()
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
                    Task {
                        await loadPage()
                        if toolbarState.searchText.isEmpty {
                            filteredCount = nil
                        } else {
                            let query = SearchQueryParser.parse(toolbarState.searchText)
                            filteredCount = await session.library?.bookCount(query: query)
                            await session.refreshLastSearchError()
                        }
                        toolbarState.finishLibraryFilterApplication(token: token)
                    }
                }
            }
            .onChange(of: toolbarState.activeFilterResult?.reloadToken) {
                if suppressNextReloadToken { suppressNextReloadToken = false; return }
                selectedItemIDs.removeAll()
                offsetState.resetForNewFilter(); Task { await loadPage() }
            }
    }

    /// Extraction refresh, visibility prefs, session lifecycle, and appear/disappear.
    private func attachAppearanceHandlers<V: View>(to view: V) -> some View {
        view
            .onChange(of: extractionRefreshToken) {
                loadAO3MetadataForCurrentPage()
            }
            .onChange(of: prefs.showSkippedCollection) {
                offsetState.resetForNewFilter()
                if toolbarState.filterExpression.hasCompleteRules {
                    applyFilterRules()
                } else {
                    Task { await loadPage() }
                }
            }
            .onChange(of: prefs.hideNonAO3PublisherBooks) {
                Task { await refreshVisibilitySnapshots() }
            }
            .onChange(of: prefs.hideAnthologyBooks) {
                Task { await refreshVisibilitySnapshots() }
            }
            .onChange(of: prefs.hideDuplicateBooks) {
                Task { await refreshVisibilitySnapshots() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                let persisted = UserDefaults.standard.bool(forKey: "groupBySeries")
                if toolbarState.groupBySeries != persisted {
                    toolbarState.groupBySeries = persisted
                    selectedItemIDs.removeAll()
                    offsetState.resetForNewFilter()
                    Task { await loadPage() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .seriesOrMergedCollectionDidChange)) { _ in
                refreshBookStates()
            }
            .onChange(of: session.isOpen) {
                if session.isOpen {
                    selectedItemIDs.removeAll()
                    offsetState.resetForNewFilter()
                    toolbarState.searchText = ""
                    toolbarState.activeFilterResult = nil
                    toolbarState.cancelLibraryFilterApplication()
                    toolbarState.filterExpression = FilterExpression()
                    if let lib = session.library {
                        Task { await CustomColumnConfig.shared.autoDetect(using: lib) }
                    }
                    Task { await loadPage() }
                    refreshBookStates()
                } else {
                    books = []; bookStates = [:]; selectedItemIDs.removeAll()
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
                    anthologyIDs = session.cachedAnthologyIDs
                    duplicateLoserIDs = session.cachedDuplicateLoserIDs
                    Task { await loadPage() }
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
                        selectedItemIDs.removeAll()
                        offsetState.resetForNewFilter(); Task { await loadPage() }
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
                        // Fetch every series membership (not just one) per book so a
                        // multi-series book is duplicated into every relevant series
                        // folder below, rather than only ever landing in one.
                        var seriesEntriesByBook: [Int: [SeriesCacheEntry]] = [:]
                        if toolbarState.groupBySeries, let metaDB = session.metaDB {
                            let ids = rows.map(\.book.id)
                            let currentAnthologyIDs = await session.library?.anthologyBookIDs() ?? []
                            if let entries = try? await metaDB.seriesEntries(for: ids) {
                                seriesEntriesByBook = Dictionary(grouping: entries.filter { !currentAnthologyIDs.contains($0.calibreID) }, by: \.calibreID)
                            }
                        }
                        let (copied, skipped) = await ExportManager.exportEPUBs(
                            books: rows.map(\.book),
                            libraryRoot: libraryRoot,
                            destination: destination,
                            ao3Map: ao3Map,
                            groupBySeries: toolbarState.groupBySeries,
                            seriesEntries: seriesEntriesByBook,
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
            if rebuildDegraded {
                degradedDataBanner
            }
            if toolbarState.hasActiveFilter || activeFullTextPhrase != nil {
                activeFilterChip(count: toolbarState.activeFilterResult?.totalCount)
            }
            if !session.isOpen {
                emptyLibraryState
            } else if books.isEmpty && toolbarState.searchText.isEmpty && !toolbarState.hasActiveFilter {
                loadingState
            } else if shouldGroupSeriesRows && items.isEmpty && !books.isEmpty {
                // books has loaded but rebuildItems' async grouping Task hasn't
                // produced a result yet, and there's no previous list to keep
                // showing (e.g. the very first grouped load). Show loading
                // rather than an empty-looking list — never render List(items)
                // while items is artificially/incidentally empty here.
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

    // Finding 12: shown when any of rebuildItems' AmbrosiaMetaDB calls failed this
    // pass, so series grouping / tag diagnostics / singleton warnings may be
    // showing an empty-but-not-actually-empty result. Tapping retries the pass.
    private var degradedDataBanner: some View {
        Button {
            rebuildItems()
        } label: {
            Label("Some library data couldn't load — tap to retry", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(Color.yellow.opacity(0.15))
    }

    // MARK: - Data loading

    @MainActor
    private func loadPage() async {
        // §list-teardown fix: no-op if the List surface has been torn down
        // (mode switched away). See LibraryToolbarState.isListSurfaceTornDown.
        guard !toolbarState.isListSurfaceTornDown else { return }
        guard !Task.isCancelled else { return }
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
                restrictIDs = intersect(result.calibreIDs, with: query.ftsMatchedIDs)
                filterForSQL = nil
            } else if toolbarState.activeFilterResult != nil {
                books = []; items = []; hasNextPage = false
                rebuildItems(); loadAO3MetadataForCurrentPage(); pruneSelection()
                return
            } else {
                restrictIDs = nil
                filterForSQL = nil
            }
            // The visibility policy (skip/series-grouping/AO3-publisher-only/
            // anthology) is now applied once, uniformly, inside
            // randomSortedPage regardless of which branch above set
            // restrictIDs — this replaces per-branch restrictIDs mutation
            // hacks that used to leave the SQL-backed-filter and no-filter
            // cases uncovered (see git history / prior session notes).
            let (page, hasMore) = await library.randomSortedPage(
                offset: offsetState.currentPage * pageSize, limit: pageSize,
                query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                visibility: currentVisibilityPolicy,
                filterTagExpansions: cachedFilterTagExpansions,
                visibilityVersion: session.membershipVersion
            )
            guard !toolbarState.isListSurfaceTornDown else { return }
            guard !Task.isCancelled else { return }
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
                restrictIDs = intersect(result.calibreIDs, with: query.ftsMatchedIDs)
                filterForSQL = nil
            } else if toolbarState.activeFilterResult != nil {
                LibraryFilterDebug.log("loadPage.start", [
                    "surface": "list", "mode": "emptyExplicitIDs.wordCount", "page": offsetState.currentPage
                ])
                books = []; items = []; hasNextPage = false
                rebuildItems(); loadAO3MetadataForCurrentPage(); pruneSelection()
                return
            } else {
                restrictIDs = nil
                filterForSQL = nil
            }
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list", "mode": "wordCountSorted", "page": offsetState.currentPage,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            let (page, hasMore) = await library.wordCountSortedPage(
                offset: offsetState.currentPage * pageSize, limit: pageSize, ascending: toolbarState.ascending,
                query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                visibility: currentVisibilityPolicy,
                filterTagExpansions: cachedFilterTagExpansions,
                visibilityVersion: session.membershipVersion
            )
            guard !toolbarState.isListSurfaceTornDown else { return }
            guard !Task.isCancelled else { return }
            books = page
            hasNextPage = hasMore
        } else if toolbarState.sortField == .title && shouldGroupSeriesRows {
            // §SeriesGrouping Phase 2: title sort needs the same
            // materialize-then-sort treatment as word count once grouping is
            // on, so a series' representative row sorts under the series'
            // name rather than the leading book's own title, and a match on
            // a non-leading member still pulls the leader in. Ungrouped
            // title sort keeps using the plain SQL-windowed path below.
            let restrictIDs: [Int]?
            let filterForSQL: FilterExpression?
            if let result = toolbarState.activeFilterResult, result.isSQLBacked {
                restrictIDs = nil
                filterForSQL = toolbarState.filterExpression
            } else if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
                restrictIDs = intersect(result.calibreIDs, with: query.ftsMatchedIDs)
                filterForSQL = nil
            } else if toolbarState.activeFilterResult != nil {
                books = []; items = []; hasNextPage = false
                rebuildItems(); loadAO3MetadataForCurrentPage(); pruneSelection()
                return
            } else {
                restrictIDs = nil
                filterForSQL = nil
            }
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list", "mode": "titleSortedGrouped", "page": offsetState.currentPage,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            let (page, hasMore) = await library.groupAwareTitleSortedPage(
                offset: offsetState.currentPage * pageSize, limit: pageSize, ascending: toolbarState.ascending,
                query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                visibility: currentVisibilityPolicy,
                filterTagExpansions: cachedFilterTagExpansions,
                visibilityVersion: session.membershipVersion,
                metaDB: session.metaDB
            )
            guard !toolbarState.isListSurfaceTornDown else { return }
            guard !Task.isCancelled else { return }
            books = page
            hasNextPage = hasMore
        } else if let result = toolbarState.activeFilterResult, result.isSQLBacked {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list",
                "mode": "sqlPagedDeferredCount",
                "page": offsetState.currentPage,
                "query": LibraryFilterDebug.summary(query: query),
                "filter": LibraryFilterDebug.summary(expression: toolbarState.filterExpression)
            ])
            if shouldGroupSeriesRows {
                // Group-aware fetch: visibleBooks strips non-representative series
                // members, so a single pageFetchLimit-sized SQL window can collapse to
                // far fewer than pageSize visible rows. Drain forward from offsetState.rawSQLOffset,
                // accumulating visible rows until we have a full page or SQL is exhausted.
                // offsetState.rawSQLOffsetOverflow carries forward any extra visible rows the
                // previous page's drain loop fetched but didn't display, so they are
                // shown on this page instead of being silently dropped.
                var visible: [CalibreBook] = offsetState.rawSQLOffsetOverflow
                offsetState.rawSQLOffsetOverflow = []
                var offset = offsetState.rawSQLOffset
                var exhausted = false
                var totalRawFetched = 0
                var iterations = 0
                let maxIterations = 40 // safety cap: 40 * pageFetchLimit (76) = ~3040 raw rows max per page load
                while visible.count < pageSize && iterations < maxIterations {
                    iterations += 1
                    let raw = await library.books(
                        offset: offset, limit: pageFetchLimit,
                        sort: toolbarState.sortField, ascending: toolbarState.ascending,
                        query: query,
                        filter: toolbarState.filterExpression,
                        filterTagExpansions: cachedFilterTagExpansions,
    visibilityVersion: session.membershipVersion
                    )
                    LibraryFilterDebug.log("visibleBooks.fetch", [
                        "surface": "list", "offset": offset, "raw": raw.count
                    ])
                    totalRawFetched += raw.count
                    offset += raw.count
                    visible.append(contentsOf: visibleBooks(raw))
                    if raw.count < pageFetchLimit { exhausted = true; break }
                }
                guard !toolbarState.isListSurfaceTornDown else { return }
                guard !Task.isCancelled else { return }
                offsetState.rawSQLOffsetHistory.append(offsetState.rawSQLOffset)
                offsetState.rawSQLOffset = offset
                hasNextPage = !exhausted || visible.count > pageSize
                books = Array(visible.prefix(pageSize))
                offsetState.rawSQLOffsetOverflow = Array(visible.dropFirst(pageSize))
                LibraryFilterDebug.log("visibleBooks.end", [
                    "surface": "list",
                    "rawFetched": totalRawFetched,
                    "visibleAfterFilter": visible.count,
                    "books": books.count,
                    "overflow": offsetState.rawSQLOffsetOverflow.count,
                    "shouldGroup": true,
                    "exhausted": exhausted
                ])
            } else {
                let raw = await library.books(
                    offset: offsetState.currentPage * pageSize, limit: pageFetchLimit,
                    sort: toolbarState.sortField, ascending: toolbarState.ascending,
                    query: query,
                    filter: toolbarState.filterExpression,
                    filterTagExpansions: cachedFilterTagExpansions,
    visibilityVersion: session.membershipVersion
                )
                let visible = visibleBooks(raw)
                guard !toolbarState.isListSurfaceTornDown else { return }
                guard !Task.isCancelled else { return }
                hasNextPage = raw.count == pageFetchLimit || visible.count > pageSize
                books = Array(visible.prefix(pageSize))
                LibraryFilterDebug.log("visibleBooks.end", [
                    "surface": "list",
                    "raw": raw.count,
                    "visibleAfterFilter": visible.count,
                    "books": books.count,
                    "seriesOrMergedStripped": raw.count - visible.count,
                    "shouldGroup": false
                ])
            }
            scheduleDeferredSQLFilterCount(query: query)
        } else if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list",
                "mode": "explicitIDs",
                "page": offsetState.currentPage,
                "candidateIDs": result.calibreIDs.count,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            let ids = visibleIDs(intersect(result.calibreIDs, with: query.ftsMatchedIDs))
            let raw = await library.books(
                ids: ids,
                offset: offsetState.currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query
            )
            guard !toolbarState.isListSurfaceTornDown else { return }
            guard !Task.isCancelled else { return }
            hasNextPage = raw.count > pageSize
            books = Array(raw.prefix(pageSize))
        } else if toolbarState.activeFilterResult != nil {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list",
                "mode": "emptyExplicitIDs",
                "page": offsetState.currentPage
            ])
            books = []; items = []; hasNextPage = false
        } else {
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list",
                "mode": "unfiltered",
                "page": offsetState.currentPage,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            if shouldGroupSeriesRows {
                var visible: [CalibreBook] = offsetState.rawSQLOffsetOverflow
                offsetState.rawSQLOffsetOverflow = []
                var offset = offsetState.rawSQLOffset
                var exhausted = false
                var totalRawFetched = 0
                var iterations = 0
                let maxIterations = 40
                while visible.count < pageSize && iterations < maxIterations {
                    iterations += 1
                    let raw = await library.books(
                        offset: offset, limit: pageFetchLimit,
                        sort: toolbarState.sortField, ascending: toolbarState.ascending,
                        query: query,
                        visibilityVersion: session.membershipVersion
                    )
                    LibraryFilterDebug.log("visibleBooks.fetch", [
                        "surface": "list", "offset": offset, "raw": raw.count
                    ])
                    totalRawFetched += raw.count
                    offset += raw.count
                    visible.append(contentsOf: visibleBooks(raw))
                    if raw.count < pageFetchLimit { exhausted = true; break }
                }
                guard !toolbarState.isListSurfaceTornDown else { return }
                guard !Task.isCancelled else { return }
                offsetState.rawSQLOffsetHistory.append(offsetState.rawSQLOffset)
                offsetState.rawSQLOffset = offset
                hasNextPage = !exhausted || visible.count > pageSize
                books = Array(visible.prefix(pageSize))
                offsetState.rawSQLOffsetOverflow = Array(visible.dropFirst(pageSize))
                LibraryFilterDebug.log("visibleBooks.end", [
                    "surface": "list",
                    "rawFetched": totalRawFetched,
                    "visibleAfterFilter": visible.count,
                    "books": books.count,
                    "overflow": offsetState.rawSQLOffsetOverflow.count,
                    "shouldGroup": true,
                    "exhausted": exhausted
                ])
            } else {
                let raw = await library.books(
                    offset: offsetState.currentPage * pageSize, limit: pageFetchLimit,
                    sort: toolbarState.sortField, ascending: toolbarState.ascending,
                    query: query,
                    visibilityVersion: session.membershipVersion
                )
                let visible = visibleBooks(raw)
                guard !toolbarState.isListSurfaceTornDown else { return }
                guard !Task.isCancelled else { return }
                hasNextPage = raw.count == pageFetchLimit || visible.count > pageSize
                books = Array(visible.prefix(pageSize))
                LibraryFilterDebug.log("visibleBooks.end", [
                    "surface": "list",
                    "raw": raw.count,
                    "visibleAfterFilter": visible.count,
                    "books": books.count,
                    "seriesOrMergedStripped": raw.count - visible.count,
                    "shouldGroup": false
                ])
            }
        }
        rebuildItems()
        loadAO3MetadataForCurrentPage()
        pruneSelection()
        refreshGroupAwareCountIfNeeded(query: query)
        LibraryFilterDebug.log("loadPage.end", [
            "surface": "list",
            "rows": books.count,
            "hasNext": hasNextPage,
            "elapsedMS": LibraryFilterDebug.elapsedMS(since: loadStart)
        ])

        // Log to activity feed — only on page 0 (new query), not pagination.
        // loadPage() is @MainActor, so this is already guaranteed to run on
        // MainActor without an explicit hop.
        if offsetState.currentPage == 0 {
            let expr = toolbarState.filterExpression.hasCompleteRules
                ? toolbarState.filterExpression : nil
            SearchActivityLog.shared.append(
                searchText: toolbarState.searchText,
                filterExpression: expr,
                resultCount: toolbarState.activeFilterResult?.totalCount ?? books.count
            )
        }
    }

    private func rebuildItems() {
        // §list-teardown fix: no-op if the List surface has been torn down.
        guard !toolbarState.isListSurfaceTornDown else { return }
        guard shouldGroupSeriesRows, let metaDB = session.metaDB, let library = session.library else {
            LibraryFilterDebug.log("rebuildItems.sync", [
                "surface": "list",
                "books": books.count,
                "shouldGroup": shouldGroupSeriesRows,
                "reason": shouldGroupSeriesRows ? "noMetaDB" : "groupingOff"
            ])
            items = books.map { .book($0) }
            rebuildDegraded = false
            return
        }
        // §grouping-flash fix: do NOT pre-assign items = books.map(.book) here. That
        // would briefly render ungrouped individual rows before this async Task
        // completes and overwrites them with collapsed SeriesGroup rows. Leave the
        // previous page's items in place until nextItems is fully computed below,
        // then swap atomically in one MainActor.run assignment. loadPage() must
        // never clear `items` ahead of this call — see rootContent's loading-state
        // branch for how the brand-new-list case (no previous items to show) is
        // handled instead.
        let pageBooks = books
        LibraryFilterDebug.log("rebuildItems.asyncStart", [
            "surface": "list",
            "pageBooks": pageBooks.count,
            "pageBookIDs": pageBooks.map(\.id).map(String.init).joined(separator: ","),
            "pageBookTitles": pageBooks.map(\.title).joined(separator: " | "),
            "pageBookCalibreSeries": pageBooks.map { $0.series ?? "none" }.joined(separator: " | ")
        ])
        // Cancel any in-flight task before starting a new one. CalibreLibrary is
        // actor-isolated, so overlapping calls to library.booksForIDs from rapid
        // search changes now serialize safely rather than crash — but without this
        // cancellation, a slow stale task could still finish after a newer one and
        // overwrite `items` with out-of-date results.
        rebuildTask?.cancel()
        rebuildTask = Task {
            var degraded = false
            let pageIDs = pageBooks.map(\.id)

            // These four only depend on pageIDs, not on each other's results —
            // fire them concurrently rather than awaiting one at a time.
            async let pageMetadataTask = metaDB.ao3Metadata(for: pageIDs)
            async let pageDiagnosticsTask = metaDB.ao3ExtractionDiagnostics(for: pageIDs)
            async let entriesTask = metaDB.seriesEntries(for: pageIDs)
            async let singletonWarningsTask = metaDB.singletonNonLeadingSeriesEntries(for: pageIDs)

            let pageMetadata: [Int: AO3MetadataRecord]
            let pageDiagnostics: [Int: AO3ExtractionDiagnostic]
            let entries: [SeriesCacheEntry]
            let singletonWarnings: [Int: [SingletonSeriesWarning]]
            guard !Task.isCancelled else { return }
            do { pageMetadata   = try await pageMetadataTask }
            catch {
                pageMetadata = [:]
                #if DEBUG
                degraded = true
                print("[LibraryRootView] rebuildItems: ao3Metadata(page) failed: \(error)")
                #endif
            }
            guard !Task.isCancelled else { return }
            do { pageDiagnostics = try await pageDiagnosticsTask }
            catch {
                pageDiagnostics = [:]
                #if DEBUG
                degraded = true
                print("[LibraryRootView] rebuildItems: ao3ExtractionDiagnostics(page) failed: \(error)")
                #endif
            }
            guard !Task.isCancelled else { return }
            do { entries = try await entriesTask }
            catch {
                entries = []
                #if DEBUG
                degraded = true
                print("[LibraryRootView] rebuildItems: seriesEntries(page) failed: \(error)")
                #endif
            }
            guard !Task.isCancelled else { return }
            do { singletonWarnings = try await singletonWarningsTask }
            catch {
                singletonWarnings = [:]
                #if DEBUG
                degraded = true
                print("[LibraryRootView] rebuildItems: singletonNonLeadingSeriesEntries failed: \(error)")
                #endif
            }

            let groupedEntries = Dictionary(grouping: entries.filter { !anthologyIDs.contains($0.calibreID) }, by: \.seriesKey)
            let seriesKeys = groupedEntries.keys.sorted()

            // allEntries and placeholders both only depend on seriesKeys.
            async let allEntriesTask = metaDB.seriesEntries(keys: seriesKeys)
            async let placeholdersTask = metaDB.placeholders(for: seriesKeys)

            let allEntries: [SeriesCacheEntry]
            let placeholders: [String: [SeriesPlaceholder]]
            guard !Task.isCancelled else { return }
            do { allEntries = try await allEntriesTask }
            catch {
                allEntries = []
                #if DEBUG
                degraded = true
                print("[LibraryRootView] rebuildItems: seriesEntries(keys) failed: \(error)")
                #endif
            }
            guard !Task.isCancelled else { return }
            do { placeholders = try await placeholdersTask }
            catch {
                placeholders = [:]
                #if DEBUG
                degraded = true
                print("[LibraryRootView] rebuildItems: placeholders failed: \(error)")
                #endif
            }

            let allIDs = Array(Set(allEntries.map(\.calibreID)))
            guard !Task.isCancelled else { return }
            // CalibreLibrary is actor-isolated now: this await serializes automatically
            // with loadPage()'s page-fetch calls and any other in-flight query against
            // the same library, on whatever executor the actor runs on. The SQLITE_BUSY
            // race this MainActor hop used to guard against is no longer possible —
            // the actor itself is CalibreLibrary.db's only access path.
            //
            // allBooks, seriesMetadata, and seriesDiagnostics all only depend on
            // allIDs, so fetch them concurrently too.
            async let allBooksTask = library.booksForIDs(allIDs)
            async let seriesMetadataTask = metaDB.ao3Metadata(for: allIDs)
            async let seriesDiagnosticsTask = metaDB.ao3ExtractionDiagnostics(for: allIDs)

            let allBooks = await allBooksTask
            let seriesMetadata: [Int: AO3MetadataRecord]
            let seriesDiagnostics: [Int: AO3ExtractionDiagnostic]
            guard !Task.isCancelled else { return }
            do { seriesMetadata   = try await seriesMetadataTask }
            catch {
                seriesMetadata = [:]
                #if DEBUG
                degraded = true
                print("[LibraryRootView] rebuildItems: ao3Metadata(series) failed: \(error)")
                #endif
            }
            guard !Task.isCancelled else { return }
            do { seriesDiagnostics = try await seriesDiagnosticsTask }
            catch {
                seriesDiagnostics = [:]
                #if DEBUG
                degraded = true
                print("[LibraryRootView] rebuildItems: ao3ExtractionDiagnostics(series) failed: \(error)")
                #endif
            }
            let warnings = enrichWarnings(singletonWarnings, books: pageBooks)
            let byID = Dictionary(uniqueKeysWithValues: allBooks.map { ($0.id, $0) })
            let seriesByKey = buildSeriesGroups(
                allEntries: allEntries,
                byID: byID,
                seriesMetadata: seriesMetadata,
                seriesDiagnostics: seriesDiagnostics,
                anthologyIDs: anthologyIDs,
                duplicateLoserIDs: duplicateLoserIDs,
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
                anthologyIDs: anthologyIDs
            )
            await MainActor.run {
                // §list-teardown fix: no-op if the List surface was torn down
                // while this Task was in flight.
                guard !self.toolbarState.isListSurfaceTornDown else { return }
                // Staleness guard: if loadPage() ran again while this Task was in
                // flight, books has changed and these results are stale — discard
                // them rather than overwriting newer state. Mirrors the equivalent
                // guard in EmailLibraryViewController.rebuildSidebarItems.
                guard self.books.map(\.id) == pageBooks.map(\.id) else {
                    LibraryFilterDebug.log("rebuildItems.stale", [
                        "surface": "list",
                        "pageBooks": pageBooks.count,
                        "currentBooks": self.books.count
                    ])
                    return
                }
                items = nextItems
                ao3Metadata = pageMetadata
                ao3ExtractionDiagnostics = pageDiagnostics
                singletonSeriesWarnings = warnings
                rebuildDegraded = degraded
                LibraryFilterDebug.log("rebuildItems.end", [
                    "surface": "list",
                    "pageBooks": pageBooks.count,
                    "seriesKeys": seriesByKey.count,
                    "collapsedIDs": collapsedIDs.count,
                    "items": nextItems.count,
                    "series": nextItems.filter { if case .series = $0 { return true }; return false }.count,
                    "orphanedSeries": nextItems.filter { if case .orphanedSeriesEntry = $0 { return true }; return false }.count,
                    "singletons": nextItems.filter { if case .book = $0 { return true }; return false }.count
                ])
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

    /// Single point where this surface's scattered visibility state
    /// (skip/series-grouping/AO3-publisher/anthology bools + cached ID sets)
    /// becomes one value. See LibraryVisibilityPolicy.swift.
    private var currentVisibilityPolicy: LibraryVisibilityPolicy {
        queryController.visibilityPolicy(
            showSkippedCollection: prefs.showSkippedCollection,
            shouldGroupSeriesRows: shouldGroupSeriesRows,
            hideNonAO3PublisherBooks: prefs.hideNonAO3PublisherBooks,
            hideAnthologyBooks: prefs.hideAnthologyBooks,
            hideDuplicateBooks: prefs.hideDuplicateBooks,
            skippedIDs: skippedIDs,
            seriesOrMergedIDs: seriesOrMergedIDs,
            ao3PublisherIDs: ao3PublisherIDs,
            anthologyIDs: anthologyIDs,
            duplicateLoserIDs: duplicateLoserIDs
        )
    }

    private func visibleIDs(_ ids: [Int]) -> [Int] {
        queryController.visibleIDs(ids, policy: currentVisibilityPolicy)
    }

    private func intersect(_ ids: [Int], with optionalIDs: [Int]?) -> [Int] {
        queryController.intersect(ids, with: optionalIDs)
    }

    private func visibleBooks(_ raw: [CalibreBook]) -> [CalibreBook] {
        queryController.visibleBooks(raw, policy: currentVisibilityPolicy)
    }

    @MainActor
    private func refreshVisibilitySnapshots(resetPage: Bool = true) async {
        // §Phase1: was previously the only place in this file that wrote
        // session.cachedAnthologyIDs directly without going through a single
        // writer; now goes through the shared session function like every
        // other visibility refresh path.
        await session.refreshCollectionSnapshots()
        ao3PublisherIDs = session.cachedAO3PublisherIDs
        anthologyIDs = session.cachedAnthologyIDs
        duplicateLoserIDs = session.cachedDuplicateLoserIDs
        if resetPage { offsetState.resetForNewFilter() }
        if toolbarState.filterExpression.hasCompleteRules {
            applyFilterRules()
        } else {
            await loadPage()
        }
    }

    private func refreshBookStates() {
        // §list-teardown fix: no-op if the List surface has been torn down.
        guard !toolbarState.isListSurfaceTornDown else { return }
        let pageIDs = Set(books.map(\.id))
        let descriptor = FetchDescriptor<BookState>(
            predicate: #Predicate { pageIDs.contains($0.calibreID) }
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        bookStates = all.reduce(into: [:]) { $0[$1.calibreID] = $1 }
        Task {
            // §Phase1: session.refreshCollectionSnapshots() is now the single
            // writer for all six cachedX sets and bumps membershipVersion
            // itself when something actually changed. This view just mirrors
            // the result into its own @State for SwiftUI diffing.
            await session.refreshCollectionSnapshots()
            guard !toolbarState.isListSurfaceTornDown else { return }
            likedIDs = session.cachedLikedIDs
            readLaterIDs = session.cachedReadLaterIDs
            skippedIDs = session.cachedSkippedIDs
            seriesOrMergedIDs = session.cachedSeriesOrMergedIDs
            ao3PublisherIDs = session.cachedAO3PublisherIDs
            anthologyIDs = session.cachedAnthologyIDs
            duplicateLoserIDs = session.cachedDuplicateLoserIDs
            pruneSelection()
            offsetState.resetForNewFilter()
            // loadPage() is async now (CalibreLibrary is actor-isolated), so it can't
            // be called from inside a synchronous MainActor closure — call it here
            // instead, still sequential within this same Task.
            await loadPage()
        }
    }

    /// Recomputes `groupAwareTotalCount` whenever grouping is on. Mirrors
    /// `scheduleDeferredSQLFilterCount`'s restrictIDs/filterForSQL derivation
    /// so the count matches whatever `loadPage()` actually fetched, and uses
    /// the same staleness-guard shape (Invariant 23): every write into
    /// `groupAwareTotalCount` is gated on the query/filter signature still
    /// matching what was true when the task was kicked off, not just the
    /// "final" success path.
    private func refreshGroupAwareCountIfNeeded(query: SearchQuery) {
        groupAwareCountTask?.cancel()
        guard shouldGroupSeriesRows, let library = session.library else {
            groupAwareTotalCount = nil
            return
        }

        let restrictIDs: [Int]?
        let filterForSQL: FilterExpression?
        if let result = toolbarState.activeFilterResult, result.isSQLBacked {
            restrictIDs = nil
            filterForSQL = toolbarState.filterExpression
        } else if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            restrictIDs = intersect(result.calibreIDs, with: query.ftsMatchedIDs)
            filterForSQL = nil
        } else if toolbarState.activeFilterResult != nil {
            groupAwareTotalCount = 0
            return
        } else {
            restrictIDs = nil
            filterForSQL = nil
        }

        // "Not yet computed" sentinel while the recompute is in flight, so the
        // footer falls back to the per-page item count rather than showing a
        // stale total from the previous filter/page.
        groupAwareTotalCount = nil

        let visibility = currentVisibilityPolicy
        let membershipVersion = session.membershipVersion
        let tagExpansions = cachedFilterTagExpansions
        let querySignature = LibraryFilterDebug.summary(query: query)
        let filterSignature = filterForSQL.map { LibraryFilterDebug.summary(expression: $0) } ?? ""

        groupAwareCountTask = Task {
            let count = await library.visibleBookCount(
                query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                visibility: visibility, filterTagExpansions: tagExpansions,
                visibilityVersion: membershipVersion
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let currentFilterForSQL: FilterExpression? = {
                    if let result = toolbarState.activeFilterResult, result.isSQLBacked {
                        return toolbarState.filterExpression
                    }
                    return nil
                }()
                let currentFilterSignature = currentFilterForSQL.map { LibraryFilterDebug.summary(expression: $0) } ?? ""
                guard !toolbarState.isListSurfaceTornDown,
                      shouldGroupSeriesRows,
                      LibraryFilterDebug.summary(query: query) == querySignature,
                      currentFilterSignature == filterSignature
                else { return }
                groupAwareTotalCount = count
            }
        }
    }

    /// KNOWN LIMITATION: this count is the raw SQL row count (every book matching the
    /// filter, including every non-representative series member). When shouldGroupSeriesRows
    /// is true, the displayed count therefore overstates the number of rows the user will
    /// actually see (series rows + singletons). Making this group-aware requires either a
    /// second COUNT query joined against seriesOrMergedIDs (NOT IN clause) or counting
    /// representatives only — out of scope for this pass; the footer hides the now-known-
    /// wrong "X-Y of N" display when grouping is on (see footer) rather than show a
    /// misleading number.
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
            let count = await library.bookCount(query: query, filter: expression,
                                          filterTagExpansions: cachedFilterTagExpansions)
            await session.refreshLastSearchError()
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
            offsetState.resetForNewFilter(); Task { await loadPage() }; return
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
            selectedItemIDs.removeAll()
            offsetState.resetForNewFilter()
            Task { await loadPage() }
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
            selectedItemIDs.removeAll()
            offsetState.resetForNewFilter()
            suppressNextReloadToken = true   // §perf: we call loadPage() below; skip onChange duplicate
            Task { await loadPage() }
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
                    collectionMap[SystemCollectionID.seriesOrMergedName] = (try? await metaDB.leadsAtLeastOneSeriesIDs()) ?? []
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
            // off the main actor. matchingIDs relies on CalibreLibrary's own actor
            // isolation for serialization/off-main execution; the three membership
            // fetches are actor-isolated but independent.
            // §6: Crossover map — IDs with fandoms.count > 1 in ao3_metadata
            var crossoverMap: Set<Int> = []
            let needsCrossover = expression.groups.flatMap(\.rules).contains { $0.field == .crossover }
            if needsCrossover {
                crossoverMap = await library.crossoverBookIDs()
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

            let filterTagExpansions = await TagExpansionResolver.filterTagExpansions(
                for: expression, metaDB: session.metaDB
            )
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
            let publisherIDs = await capturedLibrary2?.ao3PublisherBookIDs() ?? []
            let currentAnthologyIDs2 = await capturedLibrary2?.anthologyBookIDs() ?? []
            let currentDuplicateLoserIDs2 = await capturedLibrary2?.duplicateLoserBookIDs() ?? []
            let filteredIDs = prefs.showSkippedCollection
                ? finalResult.calibreIDs
                : finalResult.calibreIDs.filter { !currentSkipped.contains($0) }
            let visibleFilteredIDs = filteredIDs.filter { !currentSeriesOrMerged.contains($0) }
                .filter { !prefs.hideNonAO3PublisherBooks || publisherIDs.contains($0) }
                .filter { !prefs.hideAnthologyBooks || !currentAnthologyIDs2.contains($0) }
                .filter { !prefs.hideDuplicateBooks || !currentDuplicateLoserIDs2.contains($0) }
            guard toolbarState.libraryFilterApplicationToken == token else { return }
            defer { toolbarState.finishLibraryFilterApplication(token: token) }
            let cacheableResult = FilterResult(
                calibreIDs: visibleFilteredIDs,
                totalCount: visibleFilteredIDs.count
            )
            toolbarState.activeFilterResult = cacheableResult
            session.rememberFilterResult(cacheableResult, for: expression)  // §7
            toolbarState.clearPendingFullTextSearch()
            cachedFilterTagExpansions = filterTagExpansions
            likedIDs = currentLikedIDs
            skippedIDs = currentSkipped
            seriesOrMergedIDs = currentSeriesOrMerged
            anthologyIDs = currentAnthologyIDs2
            session.cachedAnthologyIDs = currentAnthologyIDs2
            duplicateLoserIDs = currentDuplicateLoserIDs2
            session.cachedDuplicateLoserIDs = currentDuplicateLoserIDs2
            selectedItemIDs.removeAll()
            suppressNextReloadToken = true   // §perf: we call loadPage() below; skip onChange duplicate
            offsetState.resetForNewFilter(); await loadPage()
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
        LibraryQueryHelpers.addOrReplaceRule(rule, in: &toolbarState.filterExpression)
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
        offsetState.resetForNewFilter()
        Task { await loadPage() }
    }

    private func queryWithCachedFullText(_ query: SearchQuery) -> SearchQuery {
        LibraryQueryHelpers.queryWithCachedFullText(query, session: session)
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
            let resolved = await TagExpansionResolver.resolvedTagExpansions(for: terms, metaDB: metaDB)
            resolvedTagExpansions = resolved
            // Re-run loadPage now that expansions are available, so the WHERE
            // clause reflects synonym expansion on the first keystroke delay.
            await loadPage()
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
                    selectedItemIDs.removeAll()
                    offsetState.resetForNewFilter(); Task { await loadPage() }
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
        // `selection:` is what makes this an actual NSTableView-backed selectable
        // list rather than a plain scroll of tappable rows: click-to-select,
        // Cmd/Shift-click range selection, arrow-key navigation, and type-ahead
        // all come from this binding, not from anything we implement ourselves.
        //
        // Double-click-to-open used to be a `TapGesture(count: 2)` on each row
        // (BookListRow/SeriesListRow), which competed with the selection above
        // and broke click/shift-click/cmd-click. It's now a single window-level
        // monitor (see LibraryListDoubleClickMonitor.swift) that never touches
        // mouseDown, plus Return-key as the keyboard equivalent.
        List(items, selection: $selectedItemIDs) { item in
            itemRow(item)
        }
        .listStyle(.plain)
        .background(
            LibraryListDoubleClickMonitor { row in
                guard items.indices.contains(row) else { return }
                openItem(items[row])
            }
        )
        .onKeyPress(.return) {
            openSelection()
            return .handled
        }
    }

    /// Opens a single item the same way its context menu's "Open" / "Open
    /// Selected" / "Open Series" action already does. For a `.book`, this
    /// expands to the full current selection via `selectedBooks(fallback:)`
    /// (matching "Open Selected"), not just the double-clicked row.
    private func openItem(_ item: LibraryItem) {
        switch item {
        case .book(let book):
            open(selectedBooks(fallback: book))
        case .orphanedSeriesEntry(let book, _):
            open(selectedBooks(fallback: book))
        case .series(let series):
            AppDelegate.shared?.openReaderWindow(target: .series(series), modelContext: modelContext)
        }
    }

    /// Return-key equivalent of double-click: opens the current selection.
    /// No-op if nothing is selected.
    private func openSelection() {
        guard let firstID = selectedItemIDs.first,
              let item = items.first(where: { $0.id == firstID }) else { return }
        openItem(item)
    }

    /// The single collection this list is currently filtered to, or nil if
    /// zero or more than one `.collection` rule is active. Computed once per
    /// render rather than passed as a whole `FilterExpression` down into the
    /// row views, since rows shouldn't know about filter internals.
    private var activeCollectionID: String? {
        let collectionRules = toolbarState.filterExpression.groups.flatMap(\.rules)
            .filter { $0.field == .collection && $0.op == .equals }
        guard collectionRules.count == 1 else { return nil }
        return collectionRules[0].value
    }

    @ViewBuilder
    private func itemRow(_ item: LibraryItem) -> some View {
        switch item {
        case .book(let book):
            bookRow(book, warningsOverride: nil, id: item.id)
        case .series(let series):
            seriesRow(series, id: item.id)
        case .orphanedSeriesEntry(let book, let warning):
            bookRow(book, warningsOverride: [warning], id: item.id)
        }
    }

    private func bookRow(_ book: CalibreBook, warningsOverride: [SingletonSeriesWarning]?, id: String) -> some View {
        BookListRow(
            book: book,
            bookState: bookStates[book.id],
            ao3Metadata: ao3Metadata[book.id],
            ao3ExtractionDiagnostic: ao3ExtractionDiagnostics[book.id],
            singletonSeriesWarnings: warningsOverride ?? (singletonSeriesWarnings[book.id] ?? []),
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
                CollectionAssignment.didAssign(session: session) {
                    Task { await refreshVisibilitySnapshots(resetPage: false) }
                }
            },
            selectedCount: selectedBooks(fallback: book).count,
            selectedIDs: selectedBookIDs(fallback: book),
            activeCollectionID: activeCollectionID,
            onRemoveFromCollection: { collectionName in
                removeFromCollection(named: collectionName, calibreIDs: selectedBookIDs(fallback: book))
            },
            isSelected: selectedItemIDs.contains(id)
        )
        .equatable()
        .listRowSeparator(.visible)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func seriesRow(_ series: SeriesGroup, id: String) -> some View {
        SeriesListRow(
            series: series,
            hideFanworksTagPill: prefs.hideFanworksTagPill,
            isLiked: series.works.allSatisfy { likedIDs.contains($0.id) },
            onTagTap: { tag, field in
                addTagPillRule(tag: tag, field: field)
            },
            onLikeToggle: { toggleLike(for: series) },
            onOpen: { AppDelegate.shared?.openReaderWindow(target: .series(series), modelContext: modelContext) },
            isInReadLater: series.works.allSatisfy { readLaterIDs.contains($0.id) },
            onReadLaterToggle: { toggleReadLater(for: series) },
            onSkip:           { skip(series.works) },
            onMarkRead:       { markRead(series.works) },
            onResetProgress:  { resetProgress(series.works) },
            onCollectionChanged: {
                CollectionAssignment.didAssign(session: session) {
                    refreshBookStates()
                }
            },
            activeCollectionID: activeCollectionID,
            onRemoveFromCollection: { collectionName in
                removeFromCollection(named: collectionName, calibreIDs: series.works.map(\.id))
            },
            isSelected: selectedItemIDs.contains(id)
        )
        .equatable()
        .listRowSeparator(.visible)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    /// The active `.collection` filter rule's value is the collection's
    /// *name* (see `addOrReplaceRule(FilterRule(field: .collection, …,
    /// value: collection.name))`), while `CollectionStore.bulkRemove(from:)`
    /// takes the collection's id. Resolve name -> id against the current
    /// collections list before removing.
    private func removeFromCollection(named collectionName: String, calibreIDs: [Int]) {
        Task {
            guard let collections = try? await session.collectionStore?.collections(),
                  let match = collections.first(where: { $0.name == collectionName }) else { return }
            try? await session.collectionStore?.bulkRemove(calibreIDs: calibreIDs, from: match.id)
            CollectionAssignment.didAssign(session: session) {
                Task { await refreshVisibilitySnapshots(resetPage: false) }
            }
        }
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
                // immediately via likedIDs without touching offsetState.currentPage or loadPage().
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

    // "All works satisfy" mirrors isLiked's semantics for series (a series only
    // shows as read-later once every work is). An incomplete or partially
    // read-later series shows the outline bookmark until every work is added;
    // this matches the star's existing behavior. See
    // ambrosia_series_fix_plan.md Task 1 for the rationale.
    private func toggleReadLater(for series: SeriesGroup) {
        let ids = series.works.map(\.id)
        let shouldAdd = !series.works.allSatisfy { readLaterIDs.contains($0.id) }
        Task {
            try? await session.collectionStore?.setReadLater(calibreIDs: ids, inReadLater: shouldAdd)
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

    private func enrichWarnings(_ warnings: [Int: [SingletonSeriesWarning]], books: [CalibreBook]) -> [Int: [SingletonSeriesWarning]] {
        let titlesByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.displayTitle) })
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

    private func selectedBooks(fallback book: CalibreBook) -> [CalibreBook] {
        let selected = books.filter { selectedIDs.contains($0.id) }
        return selected.isEmpty ? [book] : selected
    }

    private func selectedBookIDs(fallback book: CalibreBook) -> [Int] {
        let ids = selectedBooks(fallback: book).map(\.id)
        return ids.isEmpty ? [book.id] : ids
    }

    private func pruneSelection() {
        let visible = Set(items.map(\.id))
        selectedItemIDs.formIntersection(visible)
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
        LibraryQueryHelpers.stateForMutation(calibreID, in: modelContext)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("← Previous") {
                if shouldGroupSeriesRows, let previousOffset = offsetState.rawSQLOffsetHistory.popLast() {
                    offsetState.rawSQLOffset = previousOffset
                    offsetState.rawSQLOffsetOverflow = []
                }
                offsetState.currentPage -= 1
            }.disabled(offsetState.currentPage == 0).buttonStyle(.borderless)
            Spacer()
            if session.isOpen {
                if shouldGroupSeriesRows {
                    if let total = groupAwareTotalCount {
                        let totalPages = max(1, Int(ceil(Double(total) / Double(pageSize))))
                        Text("Page \(offsetState.currentPage + 1) of \(totalPages)")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        // Count still loading (or grouping just turned on) —
                        // keep today's fallback rather than showing a stale
                        // or wrong number.
                        Text("\(items.count) item\(items.count == 1 ? "" : "s") on this page")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    let start = books.isEmpty ? 0 : offsetState.currentPage * pageSize + 1
                    let end   = offsetState.currentPage * pageSize + books.count
                    Text("\(start)–\(end) of \(displayCount)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Next →") { offsetState.currentPage += 1 }.disabled(!hasNextPage).buttonStyle(.borderless)
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

