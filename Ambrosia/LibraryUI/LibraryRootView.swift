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
    // §Phase2-Pass1: offsetState.currentPage and the per-page raw-SQL-offset
    // fields used to be independent @State vars, reset together at ~15 call
    // sites throughout this file. Bundled into one PagingOffsetState so
    // LibraryQueryController (Pass 4/5) can take one inout value instead of
    // several loose parameters. See PagingOffsetState's doc comment for why
    // this stays owned per-view rather than shared, and for the history of
    // the rawSQLOffsetByPage design (its incident notes).
    @State private var offsetState = PagingOffsetState()
    @State private var filteredCount: Int?

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
    // Row view intentionally has no selection state: no click-to-select, no
    // shift/cmd-click, no Cmd+A. Opening is double-click (or Enter via
    // context menu) and acts on the row in question only. This used to be
    // backed by a `selectedItemIDs` set plus a derived `selectedIDs`/
    // `selectedBooks(fallback:)` pair that every row recomputed against the
    // *entire* library on every render — that was the main cause of row-view
    // scroll lag, and it's gone along with the selection concept itself.
    // §Phase2: shared visibility-filtering logic, also owned by
    // EmailLibraryViewController. Stateless aside from its debug-log label,
    // so a plain `let` (not `@State`) is correct here.
    private let queryController = LibraryQueryController(surfaceLabel: "list")
    @State private var fullTextTask: Task<Void, Never>?
    @State private var filterCountTask: Task<Void, Never>?
    // The filter compute (full or narrowed). Tracked so a newer apply cancels it;
    // the evaluator stops at its next phase boundary and the token guard at commit
    // stays the final authority.
    @State private var filterComputeTask: Task<Void, Never>?
    @State private var rebuildTask: Task<Void, Never>?
    // One in-flight loadPage per list surface. `loadGeneration` is compared after
    // every await inside loadPage because CalibreLibrary actor calls do not observe
    // task cancellation, so cancellation alone cannot stop a stale load committing.
    @State private var loadPageTask: Task<Void, Never>?
    @State private var loadGeneration = 0
    // False until the first load of an open library has produced a result (even an
    // empty one); gates the "Loading..." state so an empty library does not spin forever.
    @State private var didFinishFirstLoad = false
    // F.3: series-grouped, visibility-aware total, computed by
    // CalibreLibrary.visibleBookCount and used for "Page X of Y" in the
    // footer while shouldGroupSeriesRows is true. nil is the "not yet
    // computed" sentinel — the footer must not show a stale/wrong number
    // while a recompute (triggered by loadPage()) is in flight.
    @State private var visibleTotalCount: Int?
    @State private var groupAwareCountTask: Task<Void, Never>?
    // Every `scheduleLoadPage()` call site below now goes through this
    // instead of being fire-and-forget. Previously ~20 sites (sort/filter/page
    // changes) could each spawn an untracked Task, and nothing cancelled a
    // still-running one when a newer change superseded it — same-surface calls
    // could interleave and last-write-wins on `books`/`items`/`hasNextPage` in
    // an undefined order, and a task begun just before switching away from this
    // view mode kept running with nothing to stop it. Matches the existing
    // tracked-task idiom already used for fullTextTask/filterCountTask/rebuildTask.
    // §perf/§duplicate-loadPage fix: prevents the onChange(reloadToken) handler
    // from firing a duplicate loadPage() when applyFilterRules()/the cached/
    // SQL-pageable paths have already called it synchronously for the same
    // activeFilterResult change.
    //
    // Previously a plain Bool (`suppressNextReloadToken`) set to true right
    // before each direct `loadPage()` call, on the assumption that SwiftUI
    // would deliver this view's `.onChange(of: activeFilterResult?.reloadToken)`
    // strictly after the `.onChange`/direct-call site that set the flag, in
    // the same update pass. That ordering does NOT hold when
    // `activeFilterResult` is mutated as a side effect of
    // `toolbarState.filterExpression` being written from
    // `AO3FilterPopupWindowController` -- a *separate* NSWindow with its own
    // SwiftUI update cycle. Under that path the flag could still be false (or
    // already reset) by the time the reloadToken handler ran, causing a
    // second, fully redundant `loadPage()` for the identical filter. Visible
    // directly in `filterlogs.txt` as back-to-back duplicate `loadPage.start`
    // pairs with identical `pageBookIDs`, which in turn kept cancelling
    // `filterCountTask` before `scheduleDeferredSQLFilterCount` could ever
    // finish (`deferredCount.apply` never appeared in the logs at all).
    //
    // Fix: instead of a timing-dependent flag, record the exact reloadToken
    // value that was already handled by the direct call. The onChange handler
    // then compares against that value rather than trusting flag timing --
    // it's a value equality check, not a race.
    @State private var lastHandledReloadToken: String?

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

    /// KNOWN LIMITATION: the fallback values here (`filteredCount`, `session.totalCount`)
    /// are raw SQL row counts. They do not apply `LibraryVisibilityPolicy`, and when
    /// `shouldGroupSeriesRows` is true they also count every non-representative series
    /// member. The footer prefers `visibleTotalCount` (visibility-aware, every mode)
    /// and uses this only while that count is still being computed.
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
            .onChange(of: offsetState.currentPage) { scheduleLoadPage() }
            .onChange(of: toolbarState.sortField) { offsetState.resetForNewFilter(); scheduleLoadPage() }
            .onChange(of: toolbarState.ascending) { offsetState.resetForNewFilter(); scheduleLoadPage() }
            .onChange(of: toolbarState.reshuffleToken) { scheduleLoadPage() }
            .onChange(of: toolbarState.groupBySeries) { offsetState.resetForNewFilter(); scheduleLoadPage() }
            .onChange(of: toolbarState.filterExpression) {
                // AO3FilterPopupWindowController's popup lives in its own NSWindow
                // and writes toolbarState.filterExpression directly (no shared view
                // tree with LibraryRootView to route an explicit apply call through).
                // Without this handler that write was inert: applyFilterRules() --
                // the only thing that turns filterExpression into an actual
                // activeFilterResult/reload -- was only ever called from this
                // view's own addOrReplaceRule(_:) quick-filter path.
                offsetState.resetForNewFilter()
                if toolbarState.filterExpression.hasCompleteRules {
                    applyFilterRules()
                } else {
                    scheduleLoadPage()
                }
            }
            .onChange(of: toolbarState.searchText) {
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
                    // Editing the query is a retry for a previously failed phrase.
                    if let phrase = activeFullTextPhrase {
                        session.retryFulltext(for: phrase)
                    }
                    if toolbarState.activeFilterResult?.isSQLBacked == true,
                       toolbarState.activeFilterResult?.totalCount != nil {
                        let suppressedResult = FilterResult(calibreIDs: [], isSQLBacked: true)
                        lastHandledReloadToken = suppressedResult.reloadToken   // §perf: mirrors applyFilterRules() branches; skip onChange duplicate
                        toolbarState.activeFilterResult = suppressedResult
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
                        await scheduleLoadPage().value
                        if toolbarState.searchText.isEmpty {
                            filteredCount = nil
                        } else {
                            let query = SearchQueryParser.parse(toolbarState.searchText)
                            filteredCount = await session.library?.bookCount(query: query)
                            await session.refreshLastSearchError()
                        }
                        if toolbarState.libraryFilterApplicationToken == token {
                            // A stale continuation's guard fails silently here, so an
                            // abandoned in-progress query never reaches history — its
                            // own resolution arrives after being superseded.
                            let resultCount = toolbarState.activeFilterResult?.totalCount
                                ?? filteredCount
                                ?? books.count
                            commitSearchActivityLogEntry(resultCount: resultCount)
                        }
                        toolbarState.finishLibraryFilterApplication(token: token)
                    }
                }
            }
            .onChange(of: toolbarState.activeFilterResult?.reloadToken) {
                let currentToken = toolbarState.activeFilterResult?.reloadToken
                if lastHandledReloadToken == currentToken { return }
                lastHandledReloadToken = currentToken
                offsetState.resetForNewFilter(); scheduleLoadPage()
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
                    scheduleLoadPage()
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
                    offsetState.resetForNewFilter()
                    scheduleLoadPage()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .seriesOrMergedCollectionDidChange)) { _ in
                Task { await refreshVisibilitySnapshots(resetPage: false) }
            }
            .onChange(of: session.isOpen) {
                didFinishFirstLoad = false
                if session.isOpen {
                    offsetState.resetForNewFilter()
                    toolbarState.searchText = ""
                    toolbarState.activeFilterResult = nil
                    toolbarState.cancelLibraryFilterApplication()
                    toolbarState.filterExpression = FilterExpression()
                    if let lib = session.library {
                        Task { await CustomColumnConfig.shared.autoDetect(using: lib) }
                    }
                    scheduleLoadPage()
                    refreshMembershipSnapshots(reload: false)
                } else {
                    books = []; bookStates = [:]
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
                    scheduleLoadPage()
                    refreshMembershipSnapshots(reload: false)
                }
                // Register so LibraryWindowController can deliver committed filter rules
                registerFilterCommitHandler()
            }
            // A hidden hosting view may not get onAppear when it is shown again, so
            // re-register when the list becomes the live surface.
            .onChange(of: toolbarState.isListSurfaceTornDown) {
                if !toolbarState.isListSurfaceTornDown { registerFilterCommitHandler() }
            }
            .onDisappear {
                // Deregister when this view leaves the hierarchy (view mode switch)
                toolbarState.filterCommitHandler = nil
            }
    }

    private func registerFilterCommitHandler() {
        toolbarState.registerFilterCommitHandler { [self] rule in
            addOrReplaceRule(rule)
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
                        offsetState.resetForNewFilter(); scheduleLoadPage()
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
            .sheet(isPresented: Binding(
                get: { toolbarState.showErrorLog },
                set: { toolbarState.showErrorLog = $0 }
            )) {
                ErrorLogView()
                    .preferredColorScheme(prefs.resolvedLibraryColorScheme)
            }
            .onChange(of: toolbarState.triggerExport) {
                guard !toolbarState.isListSurfaceTornDown else { return }
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
            .onChange(of: toolbarState.triggerAnnotationExport) {
                guard !toolbarState.isListSurfaceTornDown else { return }
                if toolbarState.triggerAnnotationExport {
                    AnnotationExportManager.presentExportPanel(session: session)
                    toolbarState.triggerAnnotationExport = false
                }
            }
            .onChange(of: toolbarState.triggerEPUBExport) {
                guard !toolbarState.isListSurfaceTornDown else { return }
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
                            let alert = NSAlert()
                            alert.messageText = "Nothing to Export"
                            alert.informativeText = "No matching EPUBs found with the current filter."
                            alert.runModal()
                            return
                        }

                        // 2. Confirm with count warning.
                        let confirm = NSAlert()
                        confirm.messageText = "Export \(count) EPUB\(count == 1 ? "" : "s")?"
                        confirm.informativeText = "This will copy \(count) EPUB file\(count == 1 ? "" : "s") " +
                            "to a folder you choose. Large libraries may take a minute."
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

                        let ao3Map = LibraryQueryHelpers.indexed(rows.compactMap { row in
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
                            options: ExportManager.ExportEPUBsOptions(
                                destination: destination,
                                ao3Map: ao3Map,
                                groupBySeries: toolbarState.groupBySeries,
                                seriesEntries: seriesEntriesByBook
                            ),
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
            if let message = fulltextFailureMessage {
                searchFailureBanner(message: "Full-text search failed: \(message)", canRetry: true)
            } else if let message = session.lastSearchError {
                searchFailureBanner(message: "Search failed: \(message)", canRetry: false)
            }
            if toolbarState.hasActiveFilter || activeFullTextPhrase != nil {
                activeFilterChip(
                    count: toolbarState.activeFilterResult?.totalCount,
                    countPending: toolbarState.isFilterCountPending
                )
            }
            if !session.isOpen {
                emptyLibraryState
            } else if books.isEmpty && toolbarState.searchText.isEmpty && !toolbarState.hasActiveFilter {
                if didFinishFirstLoad { emptyBooksState } else { loadingState }
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

    /// Every full-text phrase currently in play: the search-bar phrase plus
    /// complete `fulltext` filter rules.
    private var fulltextPhrasesInUse: [String] {
        var phrases: [String] = []
        if let phrase = activeFullTextPhrase { phrases.append(phrase) }
        phrases += toolbarState.filterExpression.groups.flatMap(\.rules)
            .filter { $0.field == .fulltext && $0.isComplete }
            .map(\.value)
        return phrases
    }

    private var fulltextFailureMessage: String? {
        for phrase in fulltextPhrasesInUse {
            if case .failed(let message) = session.fulltextState(for: phrase) { return message }
        }
        return nil
    }

    private func searchFailureBanner(message: String, canRetry: Bool) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .lineLimit(2)
            Spacer()
            if canRetry {
                Button("Retry") { retryFailedFulltext() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
    }

    private func retryFailedFulltext() {
        let phrases = fulltextPhrasesInUse
        for phrase in phrases { session.retryFulltext(for: phrase) }
        let hasFilterRule = toolbarState.filterExpression.groups.flatMap(\.rules)
            .contains { $0.field == .fulltext && $0.isComplete }
        if hasFilterRule { applyFilterRules() }
        if activeFullTextPhrase != nil { _ = startPendingSearchTextFullTextIfNeeded() }
    }

    // MARK: - Data loading

    /// The only way to start a page load. Cancels the previous load and bumps the
    /// generation so a superseded load stops at its next check.
    @discardableResult
    private func scheduleLoadPage() -> Task<Void, Never> {
        loadPageTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        let task = Task { await loadPage(generation: generation) }
        loadPageTask = task
        return task
    }

    @MainActor
    private func loadPage(generation: Int) async {
        // §list-teardown fix: no-op if the List surface has been torn down
        // (mode switched away). See LibraryToolbarState.isListSurfaceTornDown.
        guard !toolbarState.isListSurfaceTornDown else { return }
        guard generation == loadGeneration, !Task.isCancelled else { return }
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
                rebuildItems(); loadAO3MetadataForCurrentPage()
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
                CalibreLibrary.PageQuery(
                    query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                    visibility: currentVisibilityPolicy,
                    filterTagExpansions: cachedFilterTagExpansions,
                    visibilityVersion: session.membershipVersion
                )
            )
            guard !toolbarState.isListSurfaceTornDown else { return }
            guard generation == loadGeneration, !Task.isCancelled else { return }
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
                rebuildItems(); loadAO3MetadataForCurrentPage()
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
                CalibreLibrary.PageQuery(
                    query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                    visibility: currentVisibilityPolicy,
                    filterTagExpansions: cachedFilterTagExpansions,
                    visibilityVersion: session.membershipVersion
                )
            )
            guard !toolbarState.isListSurfaceTornDown else { return }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            books = page
            hasNextPage = hasMore
            triggerDeferredSQLCountIfNeeded(query: query)
        } else if toolbarState.sortField == .kudos {
            // §2.2d: kudos can't be sorted by a single SQL ORDER BY when no custom
            // column is configured — see orderByClause(.kudos) and kudosSortedPage(...),
            // mirroring the word-count case immediately above exactly.
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
                    "surface": "list", "mode": "emptyExplicitIDs.kudos", "page": offsetState.currentPage
                ])
                books = []; items = []; hasNextPage = false
                rebuildItems(); loadAO3MetadataForCurrentPage()
                return
            } else {
                restrictIDs = nil
                filterForSQL = nil
            }
            LibraryFilterDebug.log("loadPage.start", [
                "surface": "list", "mode": "kudosSorted", "page": offsetState.currentPage,
                "query": LibraryFilterDebug.summary(query: query)
            ])
            let (kudosPage, kudosHasMore) = await library.kudosSortedPage(
                offset: offsetState.currentPage * pageSize, limit: pageSize, ascending: toolbarState.ascending,
                CalibreLibrary.PageQuery(
                    query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                    visibility: currentVisibilityPolicy,
                    filterTagExpansions: cachedFilterTagExpansions,
                    visibilityVersion: session.membershipVersion
                )
            )
            guard !toolbarState.isListSurfaceTornDown else { return }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            books = kudosPage
            hasNextPage = kudosHasMore
            triggerDeferredSQLCountIfNeeded(query: query)
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
                rebuildItems(); loadAO3MetadataForCurrentPage()
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
                CalibreLibrary.PageQuery(
                    query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                    visibility: currentVisibilityPolicy,
                    filterTagExpansions: cachedFilterTagExpansions,
                    visibilityVersion: session.membershipVersion,
                    metaDB: session.metaDB
                )
            )
            guard !toolbarState.isListSurfaceTornDown else { return }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            books = page
            hasNextPage = hasMore
            triggerDeferredSQLCountIfNeeded(query: query)
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
                // far fewer than pageSize visible rows.
                //
                // If this page has been visited before (Previous, or Next
                // back to an earlier page after going back), replay it
                // deterministically from its recorded offset/seed instead
                // of touching the frontier at all -- see
                // PagingOffsetState.rawSQLOffsetByPage's doc comment for
                // why a stack-based "push on forward, pop on Previous"
                // design was wrong (it desynced under reloads and, even
                // once that was gated, popped the wrong entry -- see the
                // incident notes there).
                #if DEBUG
                assert(
                    offsetState.currentPage <= offsetState.rawSQLOffsetByPage.count,
                    "currentPage (\(offsetState.currentPage)) skipped ahead of recorded pages " +
                        "(\(offsetState.rawSQLOffsetByPage.count)) -- Next/Previous should only move one page at a time"
                )
                #endif
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
                    // Defensive only: Next/Previous move one page at a time,
                    // so currentPage should never get ahead of the recorded
                    // pages. If it ever does, fall back to the frontier
                    // rather than crashing or reading out of bounds.
                    LibraryFilterDebug.log("visibleBooks.pageIndexOutOfSync", [
                        "surface": "list",
                        "currentPage": offsetState.currentPage,
                        "recordedPages": offsetState.rawSQLOffsetByPage.count
                    ])
                    startOffset = offsetState.rawSQLOffsetFrontier
                    visible = offsetState.rawSQLOffsetOverflowFrontier
                }

                var offset = startOffset
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
                    // A stale drain loop stops after its current fetch.
                    guard generation == loadGeneration, !Task.isCancelled else { return }
                    LibraryFilterDebug.log("visibleBooks.fetch", [
                        "surface": "list", "offset": offset, "raw": raw.count
                    ])
                    totalRawFetched += raw.count
                    offset += raw.count
                    visible.append(contentsOf: visibleBooks(raw))
                    if raw.count < pageFetchLimit { exhausted = true; break }
                }
                guard !toolbarState.isListSurfaceTornDown else { return }
                guard generation == loadGeneration, !Task.isCancelled else { return }
                let overflow = Array(visible.dropFirst(pageSize))
                if isNewPage {
                    offsetState.commitNewPage(
                        page: pageAtStart, startOffset: startOffset,
                        newFrontier: offset, overflow: overflow
                    )
                }
                // Revisits intentionally don't touch rawSQLOffsetByPage,
                // seedOverflowByPage, rawSQLOffsetFrontier, or
                // rawSQLOffsetOverflowFrontier -- this page's rows were
                // fully re-derived above from what was already recorded.
                hasNextPage = !exhausted || visible.count > pageSize
                books = Array(visible.prefix(pageSize))
                LibraryFilterDebug.log("visibleBooks.end", [
                    "surface": "list",
                    "rawFetched": totalRawFetched,
                    "visibleAfterFilter": visible.count,
                    "books": books.count,
                    "overflow": overflow.count,
                    "shouldGroup": true,
                    "exhausted": exhausted,
                    "isNewPage": isNewPage
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
                guard generation == loadGeneration, !Task.isCancelled else { return }
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
            triggerDeferredSQLCountIfNeeded(query: query)
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
            guard generation == loadGeneration, !Task.isCancelled else { return }
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
                // See the first grouped drain block above (the
                // sqlPagedDeferredCount/active-filter branch) for the full
                // rationale; this is its "no active filter" twin and must
                // be kept in sync with it.
                #if DEBUG
                assert(
                    offsetState.currentPage <= offsetState.rawSQLOffsetByPage.count,
                    "currentPage (\(offsetState.currentPage)) skipped ahead of recorded pages " +
                        "(\(offsetState.rawSQLOffsetByPage.count)) -- Next/Previous should only move one page at a time"
                )
                #endif
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
                    LibraryFilterDebug.log("visibleBooks.pageIndexOutOfSync", [
                        "surface": "list",
                        "currentPage": offsetState.currentPage,
                        "recordedPages": offsetState.rawSQLOffsetByPage.count
                    ])
                    startOffset = offsetState.rawSQLOffsetFrontier
                    visible = offsetState.rawSQLOffsetOverflowFrontier
                }

                var offset = startOffset
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
                    // A stale drain loop stops after its current fetch.
                    guard generation == loadGeneration, !Task.isCancelled else { return }
                    LibraryFilterDebug.log("visibleBooks.fetch", [
                        "surface": "list", "offset": offset, "raw": raw.count
                    ])
                    totalRawFetched += raw.count
                    offset += raw.count
                    visible.append(contentsOf: visibleBooks(raw))
                    if raw.count < pageFetchLimit { exhausted = true; break }
                }
                guard !toolbarState.isListSurfaceTornDown else { return }
                guard generation == loadGeneration, !Task.isCancelled else { return }
                let overflow = Array(visible.dropFirst(pageSize))
                if isNewPage {
                    offsetState.commitNewPage(
                        page: pageAtStart, startOffset: startOffset,
                        newFrontier: offset, overflow: overflow
                    )
                }
                hasNextPage = !exhausted || visible.count > pageSize
                books = Array(visible.prefix(pageSize))
                LibraryFilterDebug.log("visibleBooks.end", [
                    "surface": "list",
                    "rawFetched": totalRawFetched,
                    "visibleAfterFilter": visible.count,
                    "books": books.count,
                    "overflow": overflow.count,
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
                guard generation == loadGeneration, !Task.isCancelled else { return }
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
        refreshBookStatesForCurrentPage()
        rebuildItems()
        loadAO3MetadataForCurrentPage()
        refreshVisibleCount(query: query)
        LibraryFilterDebug.log("loadPage.end", [
            "surface": "list",
            "rows": books.count,
            "hasNext": hasNextPage,
            "elapsedMS": LibraryFilterDebug.elapsedMS(since: loadStart)
        ])
    }

    /// Commits a settled search generation to the activity log. Called only
    /// from the guarded commit points that know a final, non-superseded
    /// result count (the plain-text debounce continuation and each
    /// `applyFilterRules()` branch) — never from `loadPage()` itself, since
    /// a page-0 load can happen more than once per settled query. Mirrors
    /// `EmailLibraryViewController.commitSearchActivityLogEntry`.
    /// `SearchActivityLog.append` already no-ops on an empty/no-filter query
    /// and dedupes against the most recent entry.
    private func commitSearchActivityLogEntry(resultCount: Int) {
        let expr = toolbarState.filterExpression.hasCompleteRules
            ? toolbarState.filterExpression : nil
        SearchActivityLog.shared.append(
            searchText: toolbarState.searchText,
            filterExpression: expr,
            resultCount: resultCount
        )
    }

    private func rebuildItems() {
        // §list-teardown fix: no-op if the List surface has been torn down.
        guard !toolbarState.isListSurfaceTornDown else { return }
        // Every non-stale loadPage completion, including empty results, reaches here.
        didFinishFirstLoad = true
        guard shouldGroupSeriesRows, let metaDB = session.metaDB, let library = session.library else {
            LibraryFilterDebug.log("rebuildItems.sync", [
                "surface": "list",
                "books": books.count,
                "shouldGroup": shouldGroupSeriesRows,
                "reason": shouldGroupSeriesRows ? "noMetaDB" : "groupingOff"
            ])
            // A grouped rebuild still in flight must not overwrite this result.
            rebuildTask?.cancel()
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
            do { pageMetadata   = try await pageMetadataTask } catch {
                pageMetadata = [:]
                degraded = true
                #if DEBUG
                print("[LibraryRootView] rebuildItems: ao3Metadata(page) failed: \(error)")
                #endif
            }
            guard !Task.isCancelled else { return }
            do { pageDiagnostics = try await pageDiagnosticsTask } catch {
                pageDiagnostics = [:]
                degraded = true
                #if DEBUG
                print("[LibraryRootView] rebuildItems: ao3ExtractionDiagnostics(page) failed: \(error)")
                #endif
            }
            guard !Task.isCancelled else { return }
            do { entries = try await entriesTask } catch {
                entries = []
                degraded = true
                #if DEBUG
                print("[LibraryRootView] rebuildItems: seriesEntries(page) failed: \(error)")
                #endif
            }
            guard !Task.isCancelled else { return }
            do { singletonWarnings = try await singletonWarningsTask } catch {
                singletonWarnings = [:]
                degraded = true
                #if DEBUG
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
            do { allEntries = try await allEntriesTask } catch {
                allEntries = []
                degraded = true
                #if DEBUG
                print("[LibraryRootView] rebuildItems: seriesEntries(keys) failed: \(error)")
                #endif
            }
            guard !Task.isCancelled else { return }
            do { placeholders = try await placeholdersTask } catch {
                placeholders = [:]
                degraded = true
                #if DEBUG
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
            do { seriesMetadata   = try await seriesMetadataTask } catch {
                seriesMetadata = [:]
                degraded = true
                #if DEBUG
                print("[LibraryRootView] rebuildItems: ao3Metadata(series) failed: \(error)")
                #endif
            }
            guard !Task.isCancelled else { return }
            do { seriesDiagnostics = try await seriesDiagnosticsTask } catch {
                seriesDiagnostics = [:]
                degraded = true
                #if DEBUG
                print("[LibraryRootView] rebuildItems: ao3ExtractionDiagnostics(series) failed: \(error)")
                #endif
            }
            let warnings = enrichWarnings(singletonWarnings, books: pageBooks)
            let byID = LibraryQueryHelpers.indexed(allBooks.map { ($0.id, $0) })
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
                // Stale-write guard: the page may have changed while these awaited.
                guard books.map(\.id) == ids else { return }
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
        LibraryVisibilityPolicy(
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
        let shouldReset = resetPage || !keepsPageOnMembershipChange
        if shouldReset { offsetState.resetForNewFilter() }
        if toolbarState.filterExpression.hasCompleteRules {
            applyFilterRules(resetPage: shouldReset)
        } else {
            scheduleLoadPage()
        }
    }

    /// A membership-only change can keep the current page only in the plain
    /// ungrouped, non-random mode. In grouped mode the recorded raw offsets are
    /// invalid once membership changes, and random order is seed-paged, so
    /// resetting to page 1 is the honest behavior there.
    private var filterVisibilitySignature: String {
        LibraryVisibilityPolicy.signature(
            showSkippedCollection: prefs.showSkippedCollection,
            hideNonAO3PublisherBooks: prefs.hideNonAO3PublisherBooks,
            hideAnthologyBooks: prefs.hideAnthologyBooks,
            hideDuplicateBooks: prefs.hideDuplicateBooks
        ) + FilterEvaluator.environmentSignature
    }

    private var keepsPageOnMembershipChange: Bool {
        !shouldGroupSeriesRows && toolbarState.sortField != .random
    }

    /// Re-reads `BookState` rows for the books on the current page. No paging
    /// reset and no page load; `loadPage` calls this once the new page is in place.
    private func refreshBookStatesForCurrentPage() {
        // §list-teardown fix: no-op if the List surface has been torn down.
        guard !toolbarState.isListSurfaceTornDown else { return }
        let pageIDs = Set(books.map(\.id))
        let descriptor = FetchDescriptor<BookState>(
            predicate: #Predicate { pageIDs.contains($0.calibreID) }
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        bookStates = all.reduce(into: [:]) { $0[$1.calibreID] = $1 }
    }

    /// Mirrors the session's membership snapshots into this view's `@State`.
    /// With `reload`, resets paging and schedules one page load afterwards.
    private func refreshMembershipSnapshots(reload: Bool) {
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
            if reload {
                offsetState.resetForNewFilter()
                scheduleLoadPage()
            }
        }
    }

    /// Recomputes `visibleTotalCount` (visibility-aware, in every mode). Mirrors
    /// `scheduleDeferredSQLFilterCount`'s restrictIDs/filterForSQL derivation
    /// so the count matches whatever `loadPage()` actually fetched, and uses
    /// the same staleness-guard shape (Invariant 23): every write into
    /// `visibleTotalCount` is gated on the query/filter signature still
    /// matching what was true when the task was kicked off, not just the
    /// "final" success path.
    private func refreshVisibleCount(query: SearchQuery) {
        groupAwareCountTask?.cancel()
        guard let library = session.library else {
            visibleTotalCount = nil
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
            visibleTotalCount = 0
            return
        } else {
            restrictIDs = nil
            filterForSQL = nil
        }

        // "Not yet computed" sentinel while the recompute is in flight, so the
        // footer falls back to the per-page item count rather than showing a
        // stale total from the previous filter/page.
        visibleTotalCount = nil

        let visibility = currentVisibilityPolicy
        let membershipVersion = session.membershipVersion
        let tagExpansions = cachedFilterTagExpansions
        let querySignature = LibraryFilterDebug.summary(query: query)
        let filterSignature = filterForSQL.map { LibraryFilterDebug.summary(expression: $0) } ?? ""

        groupAwareCountTask = Task {
            let count = await library.visibleBookCount(CalibreLibrary.PageQuery(
                query: query, filter: filterForSQL, restrictIDs: restrictIDs,
                visibility: visibility, filterTagExpansions: tagExpansions,
                visibilityVersion: membershipVersion
            ))
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
                      LibraryFilterDebug.summary(query: query) == querySignature,
                      currentFilterSignature == filterSignature
                else { return }
                visibleTotalCount = count
            }
        }
    }

    /// Single call site for kicking off the deferred count of a SQL-backed
    /// filter's total row count, used by every `loadPage()` sort-mode branch
    /// that can serve a `result.isSQLBacked` filter (base SQL-windowed path,
    /// word-count sort, and grouped title sort). `scheduleDeferredSQLFilterCount`
    /// already no-ops unless `activeFilterResult.isSQLBacked && totalCount == nil`,
    /// so this wrapper mainly exists so a new sort-mode branch can't silently
    /// forget to trigger the count the way `.wordCount` and grouped `.title`
    /// previously did — see LibraryFilterDebug `deferredCount.schedule` /
    /// `.apply` / `.discard` logs to confirm this fires for a given branch.
    private func triggerDeferredSQLCountIfNeeded(query: SearchQuery) {
        guard let result = toolbarState.activeFilterResult, result.isSQLBacked else { return }
        scheduleDeferredSQLFilterCount(query: query)
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
            let count = await library.bookCount(query: query, filter: expression,
                                                filterTagExpansions: cachedFilterTagExpansions)
            await session.refreshLastSearchError()
            await MainActor.run {
                let currentQuery = toolbarState.searchText.isEmpty
                    ? SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
                    : SearchQueryParser.parse(toolbarState.searchText)
                guard !Task.isCancelled,
                      toolbarState.activeFilterResult?.isSQLBacked == true,
                      toolbarState.activeFilterResult?.totalCount == nil,
                      LibraryFilterDebug.summary(expression: toolbarState.filterExpression) == filterSignature,
                      LibraryFilterDebug.summary(query: queryWithCachedFullText(currentQuery)) == querySignature else {
                    LibraryFilterDebug.log("deferredCount.discard", [
                        "surface": "list",
                        "mode": "sqlPagedDeferredCount"
                    ])
                    return
                }
                toolbarState.activeFilterResult = FilterResult(
                    calibreIDs: [],
                    totalCount: count,
                    isSQLBacked: true,
                    filterSignature: filterSignature
                )
                commitSearchActivityLogEntry(resultCount: count)
                LibraryFilterDebug.log("deferredCount.apply", [
                    "surface": "list",
                    "mode": "sqlPagedDeferredCount",
                    "count": count
                ])
            }
        }
    }

    /// `resetPage: false` keeps the current page across a membership-only change
    /// (skip, collection edits). Callers pass it only where recorded offsets stay
    /// valid; see `keepsPageOnMembershipChange`.
    private func applyFilterRules(resetPage: Bool = true) {
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
            if resetPage { offsetState.resetForNewFilter() }; scheduleLoadPage(); return
        }
        let expression = toolbarState.filterExpression
        LibraryFilterDebug.log("applyFilter.start", [
            "surface": "list",
            "rules": LibraryFilterDebug.summary(expression: expression),
            "sqlPageable": expression.isSQLPageable
        ])
        if expression.isSQLPageable {
            let filterSignature = LibraryFilterDebug.summary(expression: expression)
            // If this exact filter was already applied and counted (e.g.
            // applyFilterRules() is being re-run only because a sibling
            // surface — Email — just (re)mounted and called it again on
            // the same shared toolbarState), keep the known totalCount
            // instead of resetting it to nil. Resetting here is what made
            // the result count and spinner reset on every surface switch
            // even though nothing about the filter changed.
            if let existing = toolbarState.activeFilterResult,
               existing.isSQLBacked,
               let existingTotalCount = existing.totalCount,
               existing.filterSignature == filterSignature {
                lastHandledReloadToken = existing.reloadToken   // §perf: we call loadPage() below; skip onChange duplicate
                toolbarState.clearPendingFullTextSearch()
                toolbarState.cancelLibraryFilterApplication()
                commitSearchActivityLogEntry(resultCount: existingTotalCount)
                if resetPage { offsetState.resetForNewFilter() }
                scheduleLoadPage()
                LibraryFilterDebug.log("applyFilter.end", [
                    "surface": "list",
                    "mode": "sqlPagedDeferredCount.reuseCount",
                    "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
                ])
                return
            }
            let newResult = FilterResult(calibreIDs: [], isSQLBacked: true)
            lastHandledReloadToken = newResult.reloadToken   // §perf: we call loadPage() below; skip onChange duplicate
            toolbarState.activeFilterResult = newResult
            toolbarState.clearPendingFullTextSearch()
            toolbarState.cancelLibraryFilterApplication()
            if resetPage { offsetState.resetForNewFilter() }
            scheduleLoadPage()
            LibraryFilterDebug.log("applyFilter.end", [
                "surface": "list",
                "mode": "sqlPagedDeferredCount",
                "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
            ])
            return
        }
        // §7: Check the LRU cache before kicking off the expensive Task pipeline.
        if let cached = session.cachedFilterResult(for: expression, visibilitySignature: filterVisibilitySignature) {
            toolbarState.activeFilterResult = cached
            toolbarState.clearPendingFullTextSearch()
            toolbarState.cancelLibraryFilterApplication()
            if resetPage { offsetState.resetForNewFilter() }
            lastHandledReloadToken = cached.reloadToken   // §perf: we call loadPage() below; skip onChange duplicate
            commitSearchActivityLogEntry(resultCount: cached.totalCount ?? cached.calibreIDs.count)
            scheduleLoadPage()
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
        if let firstPendingRule = fulltextRules.first(where: { session.fulltextState(for: $0.value) == .unknown }) {
            startPendingFilterFullText(rule: firstPendingRule, token: token)
            return
        }
        // Captured before any await: results computed from this evaluation are
        // filed under this revision, even if an extraction flush lands meanwhile.
        let bookTagsRevisionAtStart = session.bookTagsRevision
        let evaluator = FilterEvaluator(library: library, ftsLibrary: session.ftsLibrary,
                                        metaDB: session.metaDB, collectionStore: session.collectionStore,
                                        ruleMatchCache: session.ruleMatchCache,
                                        bookTagsRevision: bookTagsRevisionAtStart)

        // Plan PR I: when exactly one AND rule was added to an expression whose
        // result is cached, evaluate only that rule against the cached IDs.
        // The base was keyed under the same membership version and visibility
        // signature, so it is already visibility-filtered and so is its subset.
        if IncrementalFilterFlag.isEnabled,
           let narrowing = session.narrowingBase(for: expression, visibilitySignature: filterVisibilitySignature) {
            filterComputeTask = Task {
                let delta = narrowing.delta
                let deltaExpression = IncrementalFilterPlanner.deltaExpression(for: delta)
                let fulltextMap = LibraryQueryHelpers.fulltextMap(
                    values: delta.field == .fulltext ? [delta.value] : []
                ) { session.cachedFulltextIDs(for: $0) }
                let baseIDs = narrowing.base.calibreIDs
                guard let evaluated = await evaluator.evaluate(expression: deltaExpression,
                                                               fulltextMap: fulltextMap,
                                                               candidates: Set(baseIDs)) else { return }
                // Filtering the sorted base keeps it sorted; no re-sort needed.
                let deltaSet = Set(evaluated.result.calibreIDs)
                let narrowedIDs = baseIDs.filter { deltaSet.contains($0) }
                guard toolbarState.libraryFilterApplicationToken == token, !Task.isCancelled else { return }
                defer { toolbarState.finishLibraryFilterApplication(token: token) }
                let narrowed = FilterResult(calibreIDs: narrowedIDs, totalCount: narrowedIDs.count)
                commitSearchActivityLogEntry(resultCount: narrowedIDs.count)
                session.rememberFilterResult(narrowed, for: expression,
                                             visibilitySignature: filterVisibilitySignature,
                                             bookTagsRevision: bookTagsRevisionAtStart)
                toolbarState.clearPendingFullTextSearch()
                cachedFilterTagExpansions = cachedFilterTagExpansions.merging(evaluated.tagExpansions) { _, new in new }
                lastHandledReloadToken = narrowed.reloadToken   // §perf: we call loadPage() below; skip onChange duplicate
                // Written last among the state writes (Invariant 23).
                toolbarState.activeFilterResult = narrowed
                if resetPage { offsetState.resetForNewFilter() }; await scheduleLoadPage().value
                LibraryFilterDebug.log("applyFilter.end", [
                    "surface": "list",
                    "mode": "narrowed",
                    "ids": narrowedIDs.count,
                    "baseIDs": baseIDs.count,
                    "elapsedMS": LibraryFilterDebug.elapsedMS(since: applyStart)
                ])
            }
            return
        }

        filterComputeTask = Task {
            let currentLikedIDs = session.cachedLikedIDs
            let fulltextMap = LibraryQueryHelpers.fulltextMap(values: fulltextRules.map(\.value)) {
                session.cachedFulltextIDs(for: $0)
            }
            guard let evaluated = await evaluator.evaluate(expression: expression, fulltextMap: fulltextMap) else {
                return
            }
            let finalResult = evaluated.result
            let filterTagExpansions = evaluated.tagExpansions

            async let fetchedSkipped = session.collectionStore?.members(of: SystemCollectionID.skipped)
            async let fetchedSeriesOrMerged = session.collectionStore?.members(of: SystemCollectionID.seriesOrMerged)
            let capturedLibrary2 = session.library
            let currentSkipped = Set((try? await fetchedSkipped) ?? [])
            let currentSeriesOrMerged = Set((try? await fetchedSeriesOrMerged) ?? [])
            let publisherIDs = await capturedLibrary2?.ao3PublisherBookIDs() ?? []
            let currentAnthologyIDs2 = await capturedLibrary2?.anthologyBookIDs() ?? []
            let currentDuplicateLoserIDs2 = await capturedLibrary2?.duplicateLoserBookIDs() ?? []
            // Captured here, next to the reads of `prefs` below, so the cache key
            // describes exactly the preferences these IDs were filtered with.
            let visibilitySignature = filterVisibilitySignature
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
            commitSearchActivityLogEntry(resultCount: cacheableResult.totalCount ?? visibleFilteredIDs.count)
            session.rememberFilterResult(cacheableResult, for: expression, visibilitySignature: visibilitySignature,
                                         bookTagsRevision: bookTagsRevisionAtStart)  // §7
            toolbarState.clearPendingFullTextSearch()
            cachedFilterTagExpansions = filterTagExpansions
            likedIDs = currentLikedIDs
            skippedIDs = currentSkipped
            seriesOrMergedIDs = currentSeriesOrMerged
            anthologyIDs = currentAnthologyIDs2
            session.cachedAnthologyIDs = currentAnthologyIDs2
            duplicateLoserIDs = currentDuplicateLoserIDs2
            session.cachedDuplicateLoserIDs = currentDuplicateLoserIDs2
            lastHandledReloadToken = cacheableResult.reloadToken   // §perf: we call loadPage() below; skip onChange duplicate
            if resetPage { offsetState.resetForNewFilter() }; await scheduleLoadPage().value
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
        switch session.fulltextState(for: phrase) {
        case .resolved(let cached):
            applyResolvedSearchTextFullText(phrase: phrase, ids: cached)
            return false
        case .failed:
            // A recorded failure is shown by the banner and not searched again
            // until Retry or an edit to the search text.
            applyResolvedSearchTextFullText(phrase: phrase, ids: [])
            return false
        case .unknown:
            break
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
        scheduleLoadPage()
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
            scheduleLoadPage()
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

    private func activeFilterChip(count: Int?, countPending: Bool) -> some View {
        let completeRules = toolbarState.filterExpression.groups.flatMap(\.rules).filter(\.isComplete)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                if countPending {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                    Text("Filtering…")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(count.map { "\($0) result\($0 == 1 ? "" : "s")" } ?? "Filtered results")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit") { toolbarState.showFilterDrawer = true }
                    .buttonStyle(.borderless).font(.caption)
                Button {
                    toolbarState.filterExpression = FilterExpression()
                    toolbarState.activeFilterResult = nil
                    toolbarState.cancelLibraryFilterApplication()
                    offsetState.resetForNewFilter(); scheduleLoadPage()
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
        // No `selection:` binding on this List — row view intentionally has
        // no click-to-select, no Cmd/Shift-click range selection, and no
        // Cmd+A. Opening is double-click (BookListRow/SeriesListRow's own
        // `.simultaneousGesture(TapGesture(count: 2)...)`, calling `onOpen`)
        // or right-click → context menu, both of which act on the row they
        // land on. This also removes the per-row "what's currently
        // selected" bookkeeping that used to run on every row on every
        // scroll/render pass (the old `selectedBooks(fallback:)` /
        // `selectedBookIDs(fallback:)` calls in `bookRow`), which was the
        // main source of row-view scroll lag.
        //
        // A window-level NSEvent monitor / NSTableView doubleAction
        // approach (LibraryListDoubleClickMonitor) was tried to avoid a
        // per-row gesture recognizer competing with List's own mouseDown
        // handling, but never reliably fired double-clicks landing on
        // rows. Reverted to the row-level TapGesture, which is known to
        // work now that there's no `selection:` binding on this List for
        // it to compete with.
        List(items) { item in
            itemRow(item)
        }
        .listStyle(.plain)
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
            onOpen: { open([book]) },
            isInReadLater: readLaterIDs.contains(book.id),
            onReadLaterToggle: { toggleReadLater(for: book) },
            onLikeToggle: { toggleLike(for: book) },
            onReadLater: { addToReadLater([book]) },
            onSkip: { skip([book]) },
            onMarkRead: { markRead([book]) },
            onResetProgress: { resetProgress([book]) },
            onCollectionChanged: {
                CollectionAssignment.didAssign(session: session) {
                    Task { await refreshVisibilitySnapshots(resetPage: false) }
                }
            },
            activeCollectionID: activeCollectionID,
            onRemoveFromCollection: { collectionName in
                removeFromCollection(named: collectionName, calibreIDs: [book.id])
            }
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
            onSkip: { skip(series.works) },
            onMarkRead: { markRead(series.works) },
            onResetProgress: { resetProgress(series.works) },
            onCollectionChanged: {
                CollectionAssignment.didAssign(session: session) {
                    Task { await refreshVisibilitySnapshots(resetPage: false) }
                }
            },
            activeCollectionID: activeCollectionID,
            onRemoveFromCollection: { collectionName in
                removeFromCollection(named: collectionName, calibreIDs: series.works.map(\.id))
            },
            // Row view has no selection concept anymore; SeriesListRow still
            // takes `isSelected` purely for its tag-pill contrast styling,
            // which is now always the unselected variant.
            isSelected: false
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
            applyFilterRules(resetPage: !keepsPageOnMembershipChange)
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
                // No offset bookkeeping needed here at all -- loadPage()
                // looks up offsetState.rawSQLOffsetByPage[currentPage - 1]
                // itself once currentPage changes below. See
                // PagingOffsetState.rawSQLOffsetByPage's doc comment for
                // why this button previously had to pop/restore state
                // manually (and why that was buggy).
                offsetState.currentPage -= 1
            }.disabled(offsetState.currentPage == 0).buttonStyle(.borderless)
            Spacer()
            if session.isOpen {
                if shouldGroupSeriesRows {
                    if let total = visibleTotalCount {
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
                    Text("\(start)–\(end) of \(visibleTotalCount ?? displayCount)").font(.callout).foregroundStyle(.secondary)
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

    /// Open library, nothing to show, no search or filter active. Distinguishes a
    /// library with no books from one whose books are all hidden by preferences.
    private var emptyBooksState: some View {
        let hiddenBySettings = session.totalCount > 0
        return VStack(spacing: 10) {
            Spacer()
            Image(systemName: "books.vertical").font(.system(size: 40)).foregroundStyle(.quaternary)
            Text(hiddenBySettings ? "All books are hidden by your settings" : "This library has no books")
                .font(.title3).foregroundStyle(.secondary)
            if hiddenBySettings {
                Button("Open Preferences") { PreferencesWindowController.show() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
