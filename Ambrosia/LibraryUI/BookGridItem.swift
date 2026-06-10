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
    @State private var likedIDs: Set<Int> = []
    @State private var skippedIDs: Set<Int> = []
    @State private var seriesOrMergedIDs: Set<Int> = []
    @State private var selectedIDs: Set<Int> = []

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

    private func attachLifecycleHandlers<V: View>(to view: V) -> some View {
        view
            .onChange(of: currentPage)                { loadPage() }
            .onChange(of: toolbarState.sortField)     { selectedIDs.removeAll(); currentPage = 0; loadPage() }
            .onChange(of: toolbarState.ascending)     { selectedIDs.removeAll(); currentPage = 0; loadPage() }
            .onChange(of: toolbarState.groupBySeries) { selectedIDs.removeAll(); currentPage = 0; loadPage() }
            .onChange(of: toolbarState.searchText) {
                selectedIDs.removeAll()
                currentPage = 0
                debouncer.schedule {
                    loadPage()
                    if toolbarState.searchText.isEmpty {
                        filteredCount = nil
                    } else {
                        let query = SearchQueryParser.parse(toolbarState.searchText)
                        let resolved = session.resolvedQuery(query)
                        filteredCount = session.library?.bookCount(query: resolved)
                    }
                }
            }
            .onChange(of: toolbarState.activeFilterResult?.calibreIDs) {
                selectedIDs.removeAll()
                currentPage = 0; loadPage()
            }
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
                if session.isOpen { loadPage(); refreshBookStates() }
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
                    onApply: { applyFilterRules() },
                    onClear: {
                        toolbarState.filterExpression = FilterExpression()
                        toolbarState.activeFilterResult = nil
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
                    ExportManager.presentExportPanel(books: books)
                    toolbarState.triggerExport = false
                }
            }
    }

    private var rootContent: some View {
        VStack(spacing: 0) {
            Divider()
            if toolbarState.hasActiveFilter {
                activeFilterChip(count: toolbarState.activeFilterResult!.totalCount)
            }
            if !session.isOpen {
                emptyLibraryState
            } else if books.isEmpty && toolbarState.searchText.isEmpty && !toolbarState.hasActiveFilter {
                loadingState
            } else {
                itemList
            }
            Divider()
            footer
        }
    }

    // MARK: - Data loading

    private func loadPage() {
        guard let library = session.library else { books = []; return }
        let rawQuery = toolbarState.searchText.isEmpty
            ? SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
            : SearchQueryParser.parse(toolbarState.searchText)
        let query = session.resolvedQuery(rawQuery)

        if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            let ids = visibleIDs(query.ftsMatchedIDs ?? result.calibreIDs)
            let raw = library.books(
                ids: ids,
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                query: query
            )
            hasNextPage = raw.count > pageSize
            books = Array(raw.prefix(pageSize))
        } else if toolbarState.activeFilterResult != nil {
            books = []; items = []; hasNextPage = false
        } else {
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
    }

    private func rebuildItems() {
        guard toolbarState.groupBySeries, let metaDB = session.metaDB, let library = session.library else {
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
                let tags = Array(Set(works.flatMap(\.tags) + metadata.flatMap(\.additionalTags))).sorted()
                let fandoms = Array(Set(metadata.flatMap(\.fandoms))).sorted()
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

    private func visibleIDs(_ ids: [Int]) -> [Int] {
        ids.filter { id in
            (prefs.showSkippedCollection || !skippedIDs.contains(id)) &&
            !seriesOrMergedIDs.contains(id)
        }
    }

    private func visibleBooks(_ raw: [CalibreBook]) -> [CalibreBook] {
        raw.filter { book in
            (prefs.showSkippedCollection || !skippedIDs.contains(book.id)) &&
            !seriesOrMergedIDs.contains(book.id) &&
            !isAnthology(book)
        }
    }

    private func refreshBookStates() {
        let all = (try? modelContext.fetch(FetchDescriptor<BookState>())) ?? []
        bookStates = all.reduce(into: [:]) { $0[$1.calibreID] = $1 }
        Task {
            let currentLiked = (try? await session.collectionStore?.likedIDs()) ?? []
            let currentSkipped = Set((try? await session.collectionStore?.members(of: SystemCollectionID.skipped)) ?? [])
            let currentSeriesOrMerged = Set((try? await session.collectionStore?.members(of: SystemCollectionID.seriesOrMerged)) ?? [])
            await MainActor.run {
            likedIDs = currentLiked
            skippedIDs = currentSkipped
            seriesOrMergedIDs = currentSeriesOrMerged
            pruneSelection()
            currentPage = 0
            loadPage()
            }
        }
    }

    private func applyFilterRules() {
        guard let library = session.library else { return }
        guard toolbarState.filterExpression.hasCompleteRules else {
            toolbarState.activeFilterResult = nil; currentPage = 0; loadPage(); return
        }
        Task {
            let needsLiked = toolbarState.filterExpression.groups.flatMap(\.rules).contains { $0.field == .isLiked }
            let currentLikedIDs = needsLiked ? ((try? await session.collectionStore?.likedIDs()) ?? []) : []
            let needsCollection = toolbarState.filterExpression.groups.flatMap(\.rules).contains { $0.field == .collection }
            let collectionMap = needsCollection ? ((try? await session.collectionStore?.membershipMap()) ?? [:]) : [:]
            let builder = FilterBuilder(library: library)
            let result = builder.matchingIDs(
                expression: toolbarState.filterExpression,
                likedIDs: currentLikedIDs,
                collectionMap: collectionMap
            )
            let currentSkipped = Set((try? await session.collectionStore?.members(of: SystemCollectionID.skipped)) ?? [])
            let currentSeriesOrMerged = Set((try? await session.collectionStore?.members(of: SystemCollectionID.seriesOrMerged)) ?? [])
            let filteredIDs = prefs.showSkippedCollection
                ? result.calibreIDs
                : result.calibreIDs.filter { !currentSkipped.contains($0) }
            let visibleFilteredIDs = filteredIDs.filter { !currentSeriesOrMerged.contains($0) }
            toolbarState.activeFilterResult = FilterResult(
                calibreIDs: visibleFilteredIDs,
                totalCount: visibleFilteredIDs.count
            )
            likedIDs = currentLikedIDs
            skippedIDs = currentSkipped
            seriesOrMergedIDs = currentSeriesOrMerged
            selectedIDs.removeAll()
            currentPage = 0; loadPage()
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

    // MARK: - Subviews

    private func activeFilterChip(count: Int) -> some View {
        let completeRules = toolbarState.filterExpression.groups.flatMap(\.rules).filter(\.isComplete)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                Text("\(count) result\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit") { toolbarState.showFilterDrawer = true }
                    .buttonStyle(.borderless).font(.caption)
                Button {
                    toolbarState.filterExpression = FilterExpression()
                    toolbarState.activeFilterResult = nil
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
            modelContext: modelContext,
            onTagTap: { tag, field in
                addOrReplaceRule(FilterRule(field: field, op: .equals, value: tag))
            },
            onAuthorTap: { author in
                addOrReplaceRule(FilterRule(field: .authorName, op: .equals, value: author))
            },
            onOpenSelected: { open(selectedBooks(fallback: book)) },
            onLikeToggle: { toggleLike(for: book) },
            onLikeSelected: { setLiked(selectedBooks(fallback: book), liked: true) },
            onUnlikeSelected: { setLiked(selectedBooks(fallback: book), liked: false) },
            onSkip: { skip(selectedBooks(fallback: book)) },
            onMarkRead: { markRead(selectedBooks(fallback: book)) },
            onResetProgress: { resetProgress(selectedBooks(fallback: book)) },
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
            onTagTap: { tag, field in
                addOrReplaceRule(FilterRule(field: field, op: .equals, value: tag))
            },
            onOpen: { AppDelegate.shared?.openReaderWindow(target: .series(series), modelContext: modelContext) },
            onShowWorks: {},
            onSavePlaceholder: { index, note in
                Task {
                    try? await session.metaDB?.upsertPlaceholder(seriesKey: series.seriesKey, seriesName: series.seriesName, partIndex: index, note: note)
                    await MainActor.run { loadPage() }
                }
            }
        )
        .listRowSeparator(.visible)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func toggleLike(for book: CalibreBook) {
        Task {
            try? await session.collectionStore?.toggleLiked(calibreID: book.id)
            likedIDs = (try? await session.collectionStore?.likedIDs()) ?? []
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
            likedIDs = (try? await session.collectionStore?.likedIDs()) ?? []
        }
    }

    private func skip(_ books: [CalibreBook]) {
        Task {
            for book in books {
                try? await session.collectionStore?.skipBook(calibreID: book.id)
                skippedIDs.insert(book.id)
            }
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
}

// MARK: - Book list row

struct BookListRow: View, Equatable {
    let book: CalibreBook
    let bookState: BookState?
    let ao3Metadata: AO3MetadataRecord?
    let ao3ExtractionDiagnostic: AO3ExtractionDiagnostic?
    let singletonSeriesWarning: SingletonSeriesWarning?
    let isLiked: Bool
    let modelContext: ModelContext
    let onTagTap: (String, FilterField) -> Void
    let onAuthorTap: (String) -> Void
    let onOpenSelected: () -> Void
    let onLikeToggle: () -> Void
    let onLikeSelected: () -> Void
    let onUnlikeSelected: () -> Void
    let onSkip: () -> Void
    let onMarkRead: () -> Void
    let onResetProgress: () -> Void
    let selectedCount: Int
    let selectedIDs: [Int]

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
            && lhs.bookState?.totalReadPercent == rhs.bookState?.totalReadPercent
            && lhs.selectedCount               == rhs.selectedCount
    }

    private let buckets: AO3TagBuckets

    init(book: CalibreBook, bookState: BookState?, ao3Metadata: AO3MetadataRecord?, ao3ExtractionDiagnostic: AO3ExtractionDiagnostic?, singletonSeriesWarning: SingletonSeriesWarning?, isLiked: Bool, modelContext: ModelContext,
         onTagTap: @escaping (String, FilterField) -> Void,
         onAuthorTap: @escaping (String) -> Void,
         onOpenSelected: @escaping () -> Void,
         onLikeToggle: @escaping () -> Void,
         onLikeSelected: @escaping () -> Void,
         onUnlikeSelected: @escaping () -> Void,
         onSkip: @escaping () -> Void,
         onMarkRead: @escaping () -> Void,
         onResetProgress: @escaping () -> Void,
         selectedCount: Int,
         selectedIDs: [Int]) {
        self.book         = book
        self.bookState    = bookState
        self.ao3Metadata  = ao3Metadata
        self.ao3ExtractionDiagnostic = ao3ExtractionDiagnostic
        self.singletonSeriesWarning = singletonSeriesWarning
        self.isLiked      = isLiked
        self.modelContext = modelContext
        self.onTagTap     = onTagTap
        self.onAuthorTap  = onAuthorTap
        self.onOpenSelected = onOpenSelected
        self.onLikeToggle = onLikeToggle
        self.onLikeSelected = onLikeSelected
        self.onUnlikeSelected = onUnlikeSelected
        self.onSkip       = onSkip
        self.onMarkRead   = onMarkRead
        self.onResetProgress = onResetProgress
        self.selectedCount = selectedCount
        self.selectedIDs = selectedIDs
        self.buckets      = AO3TagBuckets.from(tags: book.tags)
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
            Button(selectedCount == 1 ? "Mark as Read" : "Mark Selected as Read") { onMarkRead() }
            Button("Reset Reading Progress") { onResetProgress() }
            Button(selectedCount == 1 ? "Skip" : "Skip Selected") { onSkip() }
            Divider()
            AddToCollectionMenu(calibreIDs: selectedIDs)
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
            if let s = bookState, s.lastOpenedDate > Date(timeIntervalSince1970: 1) {
                Text(Self.formatLastOpened(s.lastOpenedDate))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            singletonSeriesWarningButton
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
        if !buckets.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(buckets.ratings, id: \.self) { tag in
                    tagPill(tag, color: .orange)
                        .onTapGesture { onTagTap(tag, .rating) }
                }
                ForEach(buckets.categories, id: \.self) { tag in
                    tagPill(tag, color: .blue)
                        .onTapGesture { onTagTap(tag, .category) }
                }
                ForEach(buckets.warnings, id: \.self) { tag in
                    tagPill(tag, color: .red)
                        .onTapGesture { onTagTap(tag, .warning) }
                }
                ForEach(buckets.regular, id: \.self) { tag in
                    tagPill(tag, color: nil)
                        .onTapGesture { onTagTap(tag, .tag) }
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

    private static func formatLastOpened(_ date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        if age < 3600 { return "just now" }
        if age < 86400 {
            let h = Int(age / 3600)
            return "\(h)h ago"
        }
        if age < 86400 * 7 {
            let d = Int(age / 86400)
            return "\(d)d ago"
        }
        let f = DateFormatter()
        f.dateStyle = .short; f.timeStyle = .none
        return f.string(from: date)
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
    let onTagTap: (String, FilterField) -> Void
    let onOpen: () -> Void
    let onShowWorks: () -> Void
    let onSavePlaceholder: (Int, String?) -> Void

    @State private var showIndex = false
    @State private var placeholderIndex = ""
    @State private var placeholderNote = ""

    private var buckets: AO3TagBuckets {
        AO3TagBuckets.from(tags: series.allFandoms + series.allTags)
    }

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
                onShowWorks()
            }
        }
    }

    @ViewBuilder
    private var tagsRow: some View {
        if !buckets.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(Array(buckets.ratings.prefix(10)), id: \.self) { tag in
                    tagPill(tag, color: .orange)
                        .onTapGesture { onTagTap(tag, .rating) }
                }
                ForEach(Array(buckets.categories.prefix(max(0, 10 - buckets.ratings.count))), id: \.self) { tag in
                    tagPill(tag, color: .blue)
                        .onTapGesture { onTagTap(tag, .category) }
                }
                ForEach(Array(buckets.warnings.prefix(max(0, 10 - buckets.ratings.count - buckets.categories.count))), id: \.self) { tag in
                    tagPill(tag, color: .red)
                        .onTapGesture { onTagTap(tag, .warning) }
                }
                ForEach(Array(buckets.regular.prefix(max(0, 10 - buckets.ratings.count - buckets.categories.count - buckets.warnings.count))), id: \.self) { tag in
                    tagPill(tag, color: nil)
                        .onTapGesture { onTagTap(tag, .tag) }
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
            ForEach(Array(series.works.enumerated()), id: \.element.id) { offset, work in
                HStack {
                    Text("\(offset + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    Text(work.displayTitle).lineLimit(1)
                }
            }
            if !series.missingIndices.isEmpty {
                Divider()
                Text("Missing: \(series.missingIndices.map(String.init).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
                HStack {
                    TextField("Part", text: $placeholderIndex)
                        .frame(width: 48)
                    TextField("Note", text: $placeholderNote)
                    Button("Save") {
                        guard let index = Int(placeholderIndex) else { return }
                        onSavePlaceholder(index, placeholderNote.isEmpty ? nil : placeholderNote)
                        placeholderIndex = ""
                        placeholderNote = ""
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
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
