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
    @State private var skippedIDs: Set<Int> = []
    @State private var seriesOrMergedIDs: Set<Int> = []
    @State private var ao3PublisherIDs: Set<Int> = []
    @State private var selectedIDs: Set<Int> = []
    @State private var fullTextTask: Task<Void, Never>? = nil
    @State private var filterCountTask: Task<Void, Never>? = nil
    // §perf: prevents the onChange(reloadToken) handler from firing a duplicate
    // loadPage() when applyFilterRules() has already called it synchronously.
    @State private var suppressNextReloadToken = false

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
                    skippedIDs = session.cachedSkippedIDs
                    seriesOrMergedIDs = session.cachedSeriesOrMergedIDs
                    ao3PublisherIDs = session.cachedAO3PublisherIDs
                    let t0 = Date()
                    print("[FlashDiag] onAppear — calling loadPage() t=0ms")
                    loadPage()
                    print("[FlashDiag] onAppear — loadPage() done, calling refreshBookStates() t=\(Int(Date().timeIntervalSince(t0)*1000))ms")
                    refreshBookStates()
                    print("[FlashDiag] onAppear — refreshBookStates() Task enqueued t=\(Int(Date().timeIntervalSince(t0)*1000))ms")
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
        let query = queryWithCachedFullText(rawQuery)
        if rawQuery.fulltextPhrase?.isEmpty == false && query.ftsMatchedIDs == nil {
            _ = startPendingSearchTextFullTextIfNeeded()
            return
        }

        if toolbarState.sortField == .wordCount {
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
                query: query, filter: filterForSQL, restrictIDs: restrictIDs
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
                filter: toolbarState.filterExpression
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
            let pageMetadata = (try? await metaDB.ao3Metadata(for: pageIDs)) ?? [:]
            let pageDiagnostics = (try? await metaDB.ao3ExtractionDiagnostics(for: pageIDs)) ?? [:]
            let entries = (try? await metaDB.seriesEntries(for: pageIDs)) ?? []
            let groupedEntries = Dictionary(grouping: entries.filter { !$0.isAnthology }, by: \.seriesKey)
            let seriesKeys = groupedEntries.keys.sorted()
            let allEntries = (try? await metaDB.seriesEntries(keys: seriesKeys)) ?? []
            let allIDs = Array(Set(allEntries.map(\.calibreID)))
            let allBooks = library.booksForIDs(allIDs)
            let seriesMetadata = (try? await metaDB.ao3Metadata(for: allIDs)) ?? [:]
            let seriesDiagnostics = (try? await metaDB.ao3ExtractionDiagnostics(for: allIDs)) ?? [:]
            let warnings = enrichWarnings((try? await metaDB.singletonNonLeadingSeriesEntries(for: pageIDs)) ?? [:], books: pageBooks)
            let placeholders = (try? await metaDB.placeholders(for: seriesKeys)) ?? [:]
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
        ids.filter { id in
            (prefs.showSkippedCollection || !skippedIDs.contains(id)) &&
            !seriesOrMergedIDs.contains(id) &&
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
            !seriesOrMergedIDs.contains(book.id) &&
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
        let rbs_t0 = Date()
        let all = (try? modelContext.fetch(FetchDescriptor<BookState>())) ?? []
        bookStates = all.reduce(into: [:]) { $0[$1.calibreID] = $1 }
        print("[FlashDiag] refreshBookStates — SwiftData fetch done: \(all.count) BookState records t=\(Int(Date().timeIntervalSince(rbs_t0)*1000))ms")
        Task {
            let task_t0 = Date()
            async let fetchedLiked = session.collectionStore?.likedIDs()
            async let fetchedSkipped = session.collectionStore?.members(of: SystemCollectionID.skipped)
            async let fetchedSeriesOrMerged = session.collectionStore?.members(of: SystemCollectionID.seriesOrMerged)
            async let fetchedPublisherIDs: Set<Int> = await Task.detached(priority: .userInitiated) {
                session.library?.ao3PublisherBookIDs() ?? []
            }.value
            let currentLiked = (try? await fetchedLiked) ?? []
            let currentSkipped = Set((try? await fetchedSkipped) ?? [])
            let currentSeriesOrMerged = Set((try? await fetchedSeriesOrMerged) ?? [])
            let currentAO3PublisherIDs = await fetchedPublisherIDs
            print("[FlashDiag] refreshBookStates — all async fetches resolved: liked=\(currentLiked.count) skipped=\(currentSkipped.count) seriesOrMerged=\(currentSeriesOrMerged.count) publisherIDs=\(currentAO3PublisherIDs.count) t=\(Int(Date().timeIntervalSince(task_t0)*1000))ms")
            await MainActor.run {
            likedIDs = currentLiked
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
            print("[FlashDiag] refreshBookStates — calling second loadPage() t=\(Int(Date().timeIntervalSince(task_t0)*1000))ms")
            loadPage()
            print("[FlashDiag] refreshBookStates — second loadPage() done t=\(Int(Date().timeIntervalSince(task_t0)*1000))ms")
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
            let count = library.bookCount(query: query, filter: expression)
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

            let builder = FilterBuilder(library: library, ftsLibrary: session.ftsLibrary)

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
            async let fetchedPublisherIDs: Set<Int> = await Task.detached(priority: .userInitiated) {
                session.library?.ao3PublisherBookIDs() ?? []
            }.value
            let currentSkipped = Set((try? await fetchedSkipped) ?? [])
            let currentSeriesOrMerged = Set((try? await fetchedSeriesOrMerged) ?? [])
            let publisherIDs = await fetchedPublisherIDs
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
            onOpen: { AppDelegate.shared?.openReaderWindow(target: .series(series), modelContext: modelContext) }
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

// MARK: - Book list row

struct BookListRow: View, Equatable {
    let book: CalibreBook
    let bookState: BookState?
    let ao3Metadata: AO3MetadataRecord?
    let ao3ExtractionDiagnostic: AO3ExtractionDiagnostic?
    let singletonSeriesWarning: SingletonSeriesWarning?
    let isLiked: Bool
    let hideFanworksTagPill: Bool
    let correctCalibreAmpEntities: Bool
    let modelContext: ModelContext
    let onTagTap: (String, FilterField) -> Void
    let onAuthorTap: (String) -> Void
    let onOpenSelected: () -> Void
    let onLikeToggle: () -> Void
    let onLikeSelected: () -> Void
    let onUnlikeSelected: () -> Void
    let onReadLater: () -> Void
    let onSkip: () -> Void
    let onMarkRead: () -> Void
    let onResetProgress: () -> Void
    let onCollectionChanged: () -> Void
    let selectedCount: Int
    let selectedIDs: [Int]
    @State private var showCollectionPicker = false

    static func == (lhs: BookListRow, rhs: BookListRow) -> Bool {
        lhs.book.id                       == rhs.book.id
            && lhs.book.title             == rhs.book.title
            && lhs.book.series            == rhs.book.series
            && lhs.book.seriesIndex       == rhs.book.seriesIndex
            && lhs.book.wordCount         == rhs.book.wordCount
            && lhs.book.kudos             == rhs.book.kudos
            && lhs.book.authors           == rhs.book.authors
            && lhs.book.tags              == rhs.book.tags
            && lhs.book.comment           == rhs.book.comment
            && lhs.ao3Metadata            == rhs.ao3Metadata
            && lhs.ao3ExtractionDiagnostic == rhs.ao3ExtractionDiagnostic
            && lhs.singletonSeriesWarning == rhs.singletonSeriesWarning
            && lhs.bookState?.calibreID        == rhs.bookState?.calibreID
            && lhs.isLiked                     == rhs.isLiked
            && lhs.hideFanworksTagPill         == rhs.hideFanworksTagPill
            && lhs.correctCalibreAmpEntities   == rhs.correctCalibreAmpEntities
            && lhs.bookState?.totalReadPercent == rhs.bookState?.totalReadPercent
            && lhs.selectedCount               == rhs.selectedCount
    }

    init(book: CalibreBook, bookState: BookState?, ao3Metadata: AO3MetadataRecord?, ao3ExtractionDiagnostic: AO3ExtractionDiagnostic?, singletonSeriesWarning: SingletonSeriesWarning?, isLiked: Bool, hideFanworksTagPill: Bool, correctCalibreAmpEntities: Bool, modelContext: ModelContext,
         onTagTap: @escaping (String, FilterField) -> Void,
         onAuthorTap: @escaping (String) -> Void,
         onOpenSelected: @escaping () -> Void,
         onLikeToggle: @escaping () -> Void,
         onLikeSelected: @escaping () -> Void,
         onUnlikeSelected: @escaping () -> Void,
         onReadLater: @escaping () -> Void,
         onSkip: @escaping () -> Void,
         onMarkRead: @escaping () -> Void,
         onResetProgress: @escaping () -> Void,
         onCollectionChanged: @escaping () -> Void,
         selectedCount: Int,
         selectedIDs: [Int]) {
        self.book         = book
        self.bookState    = bookState
        self.ao3Metadata  = ao3Metadata
        self.ao3ExtractionDiagnostic = ao3ExtractionDiagnostic
        self.singletonSeriesWarning = singletonSeriesWarning
        self.isLiked      = isLiked
        self.hideFanworksTagPill = hideFanworksTagPill
        self.correctCalibreAmpEntities = correctCalibreAmpEntities
        self.modelContext = modelContext
        self.onTagTap     = onTagTap
        self.onAuthorTap  = onAuthorTap
        self.onOpenSelected = onOpenSelected
        self.onLikeToggle = onLikeToggle
        self.onLikeSelected = onLikeSelected
        self.onUnlikeSelected = onUnlikeSelected
        self.onReadLater = onReadLater
        self.onSkip       = onSkip
        self.onMarkRead   = onMarkRead
        self.onResetProgress = onResetProgress
        self.onCollectionChanged = onCollectionChanged
        self.selectedCount = selectedCount
        self.selectedIDs = selectedIDs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            authorsRow
            LibraryStatsRow(stats: libraryStats)
            tagsRow
            statsRow
            descriptionRow
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            AppDelegate.shared?.openReaderWindow(book: book, modelContext: modelContext)
        }
        .contextMenu {
            Button(selectedCount == 1 ? "Open" : "Open Selected") {
                onOpenSelected()
            }
            Divider()
            if selectedCount == 1 {
                Button(isLiked ? "Unlike" : "Like") { onLikeToggle() }
            } else {
                Button("Like Selected") { onLikeSelected() }
                Button("Unlike Selected") { onUnlikeSelected() }
            }
            Button(selectedCount == 1 ? "Read Later" : "Add Selected to Read Later") { onReadLater() }
            Button(selectedCount == 1 ? "Mark as Read" : "Mark Selected as Read") { onMarkRead() }
            Button("Reset Reading Progress") { onResetProgress() }
            Button(selectedCount == 1 ? "Skip" : "Skip Selected") { onSkip() }
            Divider()
            Button("Add to Collection...") { showCollectionPicker = true }
        }
        .popover(isPresented: $showCollectionPicker, arrowEdge: .trailing) {
            CollectionSearchPickerView(
                calibreIDs: selectedIDs,
                onChange: {
                    onCollectionChanged()
                },
                onComplete: {
                    showCollectionPicker = false
                }
            )
        }
        .onAppear {
            logMissingDisplayedMetadataIfNeeded()
        }
    }

    // MARK: - Row sections

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(book.displayTitle).font(.headline).lineLimit(1)
            if let series = book.displaySeries {
                Text("·").foregroundStyle(.tertiary)
                Text(series).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            singletonSeriesWarningButton
            Button(action: onLikeToggle) {
                Image(systemName: isLiked ? "star.fill" : "star")
                    .foregroundStyle(isLiked ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isLiked ? "Unlike" : "Like")
        }
    }

    @ViewBuilder
    private var singletonSeriesWarningButton: some View {
        if let warning = singletonSeriesWarning {
            SingletonSeriesWarningButton(warning: warning)
        }
    }

    @ViewBuilder
    private var authorsRow: some View {
        if !book.authors.isEmpty {
            HStack(spacing: 4) {
                ForEach(book.authors, id: \.self) { author in
                    Text(author)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .onTapGesture { onAuthorTap(author) }
                    if author != book.authors.last {
                        Text("·").foregroundStyle(.tertiary).font(.subheadline)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tagsRow: some View {
        let pills = visibleTagPills
        if !pills.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(pills) { pill in
                    tagPill(pill.label, color: pill.color)
                        .onTapGesture { onTagTap(pill.label, pill.field) }
                }
            }
        }
    }

    @ViewBuilder
    private var statsRow: some View {
        let k  = book.displayKudos
        let ao3Kudos = book.kudos == nil ? ao3Metadata?.kudosCount : nil
        let pct = bookState.map { $0.totalReadPercent }
        if !k.isEmpty || ao3Kudos != nil || (pct ?? 0) > 0 {
            HStack(spacing: 14) {
                if !k.isEmpty  { statChip(k,  icon: "heart") }
                if let ao3Kudos { statChip(Self.formatKudos(ao3Kudos), icon: "heart") }
                if let p = pct, p > 0 {
                    statChip(String(format: "%.0f%% read", min(p, 1.0) * 100), icon: "book.pages")
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var descriptionRow: some View {
        if let comment = book.displayComment, !comment.isEmpty {
            Text(comment)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private var libraryStats: LibraryStats {
        LibraryStats(
            chapterText: ao3Metadata.flatMap(Self.chapterText),
            isComplete: ao3Metadata?.isComplete == true,
            wordText: (ao3Metadata?.wordCount ?? book.wordCount).map(Self.formatWordCount),
            publishedText: Self.nonEmpty(ao3Metadata?.publishedDate),
            updatedText: Self.nonEmpty(ao3Metadata?.updatedDate)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func chapterText(_ metadata: AO3MetadataRecord) -> String? {
        guard let current = metadata.chapterCurrent else { return nil }
        if let total = metadata.chapterTotal {
            return "\(current)/\(total) ch"
        }
        return "\(current)/? ch"
    }

    private static func formatWordCount(_ count: Int) -> String {
        switch count {
        case 0..<1_000: return "\(count) words"
        case 0..<1_000_000: return String(format: "%.1fk words", Double(count) / 1_000)
        default: return String(format: "%.2fM words", Double(count) / 1_000_000)
        }
    }

    private static func formatKudos(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fk kudos", Double(count) / 1_000) : "\(count) kudos"
    }

    private func tagPill(_ label: String, color: Color?) -> some View {
        Text(label)
            .font(.caption2)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                color.map { $0.opacity(0.18) }
                    ?? Color(NSColor.controlBackgroundColor)
            )
            .foregroundStyle(color ?? .secondary)
            .clipShape(Capsule())
    }

    private var visibleTagPills: [TagPillDisplay] {
        TagPillDisplay.make(
            calibreTags: book.tags,
            ao3Metadata: ao3Metadata,
            hideFanworks: hideFanworksTagPill
        )
    }

    private func statChip(_ label: String, icon: String) -> some View {
        Label(label, systemImage: icon).font(.caption2).foregroundStyle(.tertiary)
    }

    private func logMissingDisplayedMetadataIfNeeded() {
        #if DEBUG
        logMissingVisibleWorkMetadata(book: book, ao3Metadata: ao3Metadata, diagnostic: ao3ExtractionDiagnostic)
        #endif
    }
}

private struct LibraryStats: Equatable {
    let chapterText: String?
    let isComplete: Bool
    let wordText: String?
    let publishedText: String?
    let updatedText: String?

    var isEmpty: Bool {
        chapterText == nil && wordText == nil && publishedText == nil && normalizedUpdatedText == nil
    }

    var normalizedUpdatedText: String? {
        guard let updatedText, !updatedText.isEmpty, updatedText != publishedText else { return nil }
        return updatedText
    }
}

private struct LibraryStatsRow: View {
    let stats: LibraryStats

    var body: some View {
        if !stats.isEmpty {
            HStack(spacing: 14) {
                if let chapterText = stats.chapterText {
                    statChip(chapterText, icon: stats.isComplete ? "checkmark.circle" : "clock")
                }
                if let wordText = stats.wordText {
                    statChip(wordText, icon: "text.word.spacing")
                }
                if let publishedText = stats.publishedText {
                    statChip("Pub \(publishedText)", icon: "calendar")
                }
                if let updatedText = stats.normalizedUpdatedText {
                    statChip("Upd \(updatedText)", icon: "arrow.triangle.2.circlepath")
                }
                Spacer()
            }
        }
    }

    private func statChip(_ label: String, icon: String) -> some View {
        Label(label, systemImage: icon).font(.caption2).foregroundStyle(.tertiary)
    }
}

private struct TagPillDisplay: Identifiable, Equatable {
    enum Role {
        case rating
        case fandom
        case relationship
        case character
        case category
        case warning
        case regular
    }

    let label: String
    let field: FilterField
    let role: Role

    var id: String { "\(role)-\(label)" }

    var color: Color? {
        switch role {
        case .rating:       return .orange
        case .fandom:       return .purple
        case .relationship: return .pink
        case .character:    return .teal
        case .category:     return .blue
        case .warning:      return .red
        case .regular:      return nil
        }
    }

    static func make(
        calibreTags: [String],
        ao3Metadata: AO3MetadataRecord?,
        hideFanworks: Bool
    ) -> [TagPillDisplay] {
        var seen = Set<String>()
        var pills: [TagPillDisplay] = []

        func append(_ tags: [String], role: Role, field: FilterField = .tag) {
            for tag in tags where shouldShow(tag, hideFanworks: hideFanworks) {
                guard seen.insert(tag).inserted else { continue }
                pills.append(TagPillDisplay(label: tag, field: field, role: role))
            }
        }

        let buckets = AO3TagBuckets.from(tags: calibreTags)
        append(buckets.ratings, role: .rating, field: .rating)

        if let ao3Metadata {
            append(ao3Metadata.fandoms, role: .fandom)
            append(ao3Metadata.relationships, role: .relationship)
            append(ao3Metadata.characters, role: .character)
            append(ao3Metadata.categories, role: .category, field: .category)
            append(buckets.categories, role: .category, field: .category)
            append(buckets.warnings, role: .warning, field: .warning)
            append(ao3Metadata.additionalTags, role: .regular)
        } else {
            append(buckets.categories, role: .category, field: .category)
            append(buckets.warnings, role: .warning, field: .warning)
        }

        append(buckets.regular, role: .regular)
        return pills
    }

    static func makeForSeries(
        fandoms: [String],
        relationships: [String],
        characters: [String],
        categories: [String],
        warnings: [String],
        ratings: [String],
        additionalTags: [String],
        tags: [String],
        hideFanworks: Bool
    ) -> [TagPillDisplay] {
        let buckets = AO3TagBuckets.from(tags: tags)
        let regularTags = buckets.regular.filter { tag in
            !additionalTags.contains(tag) &&
            !fandoms.contains(tag) &&
            !relationships.contains(tag) &&
            !characters.contains(tag)
        }
        var seen = Set<String>()
        var pills: [TagPillDisplay] = []

        func append(_ values: [String], role: Role, field: FilterField = .tag) {
            for value in values where shouldShow(value, hideFanworks: hideFanworks) {
                guard seen.insert(value).inserted else { continue }
                pills.append(TagPillDisplay(label: value, field: field, role: role))
            }
        }

        append(ratings + buckets.ratings, role: .rating, field: .rating)
        append(fandoms, role: .fandom)
        append(relationships, role: .relationship)
        append(characters, role: .character)
        append(categories + buckets.categories, role: .category, field: .category)
        append(warnings + buckets.warnings, role: .warning, field: .warning)
        append(additionalTags, role: .regular)
        append(regularTags, role: .regular)
        return pills
    }

    private static func shouldShow(_ tag: String, hideFanworks: Bool) -> Bool {
        !(hideFanworks && tag == "Fanworks")
    }
}

// MARK: - FlowLayout
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    struct Cache {
        var subviewSizes: [CGSize] = []
        var lastWidth: CGFloat = -1
        var rows: [(startIndex: Int, y: CGFloat, height: CGFloat)] = []
        var totalHeight: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
        var c = Cache()
        c.subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return c
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.lastWidth = -1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? 800
        refreshSubviewSizes(in: &cache, subviews: subviews)
        rebuildRows(in: &cache, maxWidth: maxWidth)
        return CGSize(width: maxWidth, height: cache.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        refreshSubviewSizes(in: &cache, subviews: subviews)
        rebuildRows(in: &cache, maxWidth: bounds.width)
        var rowIdx = 0
        var x = bounds.minX

        for (i, sub) in subviews.enumerated() {
            let size = cache.subviewSizes[i]
            if rowIdx + 1 < cache.rows.count && i >= cache.rows[rowIdx + 1].startIndex {
                rowIdx += 1
                x = bounds.minX
            }
            let currentRowY = bounds.minY + cache.rows[rowIdx].y
            let currentRowH = cache.rows[rowIdx].height
            let yOffset = (currentRowH - size.height) / 2
            sub.place(at: CGPoint(x: x, y: currentRowY + yOffset), proposal: .unspecified)
            x += size.width + spacing
        }
    }

    private func refreshSubviewSizes(in cache: inout Cache, subviews: Subviews) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if sizes != cache.subviewSizes {
            cache.subviewSizes = sizes
            cache.lastWidth = -1
        }
    }

    private func rebuildRows(in cache: inout Cache, maxWidth: CGFloat) {
        guard abs(cache.lastWidth - maxWidth) > 0.5 else { return }
        cache.lastWidth = maxWidth

        var rows: [(startIndex: Int, y: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var rowStart = 0

        for (i, size) in cache.subviewSizes.enumerated() {
            if x + size.width > maxWidth && x > 0 {
                rows.append((startIndex: rowStart, y: y, height: rowH))
                y += rowH + spacing
                x = 0; rowH = 0; rowStart = i
            }
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        rows.append((startIndex: rowStart, y: y, height: rowH))
        cache.rows = rows
        cache.totalHeight = y + rowH
    }
}

private func isAnthology(_ book: CalibreBook) -> Bool {
    book.isDescriptionAnthology
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

private func logMissingVisibleWorkMetadata(
    book: CalibreBook,
    ao3Metadata: AO3MetadataRecord?,
    diagnostic: AO3ExtractionDiagnostic?
) {
    #if DEBUG
    let missingWords = (ao3Metadata?.wordCount ?? book.wordCount) == nil
    let missingChapters = ao3Metadata?.chapterCurrent == nil
    guard missingWords || missingChapters else { return }

    var reasons: [String] = []
    if ao3Metadata == nil {
        if let diagnostic {
            reasons.append("no AO3 metadata row; extractionStatus=\(diagnostic.status); extractionReason=\(diagnostic.reason)")
        } else {
            reasons.append("no AO3 metadata row; extraction has not recorded a status yet (pending, not attempted under diagnostics schema, or pre-diagnostics DB)")
        }
    } else {
        if ao3Metadata?.wordCount == nil {
            reasons.append("AO3 metadata has nil word count")
        }
        if ao3Metadata?.chapterCurrent == nil {
            reasons.append("AO3 metadata has nil chapter current")
        }
    }
    if missingWords, book.wordCount == nil {
        reasons.append("Calibre fallback missing")
    }

    print("[LibraryMetadata] visible work missing displayed metadata reason=\(reasons.joined(separator: "; ")) calibreID=\(book.id) title=\"\(book.displayTitle)\" hasAO3Metadata=\(ao3Metadata != nil) ao3WorkID=\(ao3Metadata?.workID ?? "nil") ao3Words=\(ao3Metadata?.wordCount.map(String.init) ?? "nil") ao3ChapterCurrent=\(ao3Metadata?.chapterCurrent.map(String.init) ?? "nil") ao3ChapterTotal=\(ao3Metadata?.chapterTotal.map(String.init) ?? "nil") calibreWords=\(book.wordCount.map(String.init) ?? "nil") extractedAt=\(ao3Metadata?.extractedAt ?? "nil") extractionStatus=\(diagnostic?.status ?? "nil") extractionReason=\"\(diagnostic?.reason ?? "nil")\" attemptedAt=\(diagnostic?.attemptedAt ?? "nil") epubFilename=\"\(diagnostic?.epubFilename ?? "nil")\" epubPath=\"\(diagnostic?.epubPath ?? "nil")\" spineItemsChecked=\(diagnostic?.spineItemsChecked.map(String.init) ?? "nil")")
    #endif
}

private struct SeriesListRow: View {
    let series: SeriesGroup
    let hideFanworksTagPill: Bool
    let isLiked: Bool
    let onTagTap: (String, FilterField) -> Void
    let onLikeToggle: () -> Void
    let onOpen: () -> Void

    @State private var showIndex = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(series.seriesName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                Text("\(series.works.count) works")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !series.indexRangeText.isEmpty {
                    Text(series.indexRangeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(series.missingIndices.isEmpty ? Color.secondary : Color.orange)
                }
                Spacer()
                Button {
                    showIndex.toggle()
                } label: {
                    Image(systemName: series.missingIndices.isEmpty ? "list.number" : "exclamationmark.triangle.fill")
                }
                .buttonStyle(.borderless)
                .help(series.missingIndices.isEmpty ? "Show series index" : "Missing works")
                .popover(isPresented: $showIndex) { indexPopover }
                Button(action: onLikeToggle) {
                    Image(systemName: isLiked ? "star.fill" : "star")
                        .foregroundStyle(isLiked ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(isLiked ? "Unlike Series" : "Like Series")
            }
            Text(series.displayAuthors)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            LibraryStatsRow(stats: libraryStats)
            tagsRow
            if !series.allDescriptions.isEmpty {
                Text(series.allDescriptions.joined(separator: "\n\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("Open Series", action: onOpen)
            Button("Show Individual Works") {
                showIndex = true
            }
        }
    }

    @ViewBuilder
    private var tagsRow: some View {
        let pills = TagPillDisplay.makeForSeries(
            fandoms: series.allFandoms,
            relationships: series.allRelationships,
            characters: series.allCharacters,
            categories: series.allCategories,
            warnings: series.allWarnings,
            ratings: series.allRatings,
            additionalTags: series.allAdditionalTags,
            tags: series.allTags,
            hideFanworks: hideFanworksTagPill
        )
        if !pills.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(pills) { pill in
                    tagPill(pill.label, color: pill.color)
                        .onTapGesture { onTagTap(pill.label, pill.field) }
                }
            }
        }
    }

    private var libraryStats: LibraryStats {
        LibraryStats(
            chapterText: series.displayChapterCount.nilIfEmptyForLibraryRow,
            isComplete: series.isComplete,
            wordText: series.displayWordCount.nilIfEmptyForLibraryRow,
            publishedText: series.earliestPublished.map(Self.formatDate),
            updatedText: series.latestUpdated.map(Self.formatDate)
        )
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func tagPill(_ label: String, color: Color?) -> some View {
        Text(label)
            .font(.caption2)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                color.map { $0.opacity(0.18) }
                    ?? Color(NSColor.controlBackgroundColor)
            )
            .foregroundStyle(color ?? .secondary)
            .clipShape(Capsule())
    }

    private var indexPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(series.seriesName).font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(series.works, id: \.id) { work in
                        HStack {
                            Text("\(series.displayIndex(for: work) ?? 0).")
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(work.displayTitle).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)

            if !series.missingIndices.isEmpty {
                Divider()
                Text("Missing: \(series.missingIndices.map(String.init).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 340)
        .frame(maxHeight: 460)
    }
}

private extension String {
    var nilIfEmptyForLibraryRow: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct SingletonSeriesWarningButton: View {
    let warning: SingletonSeriesWarning
    @State private var showIndex = false

    var body: some View {
        Button {
            showIndex.toggle()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .buttonStyle(.borderless)
        .help(warning.displayText)
        .popover(isPresented: $showIndex) {
            VStack(alignment: .leading, spacing: 10) {
                Text(warning.seriesName).font(.headline)
                Text("Local index: #\(warning.seriesIndex)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("\(warning.seriesIndex).")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    Text(warning.title).lineLimit(1)
                }
                Divider()
                Text(warning.displayText)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(14)
            .frame(width: 340)
        }
    }
}
