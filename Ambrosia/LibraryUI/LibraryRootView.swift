import SwiftUI

// MARK: - Library Root View
//
// Refactored in Phase 2 (Presentation Model & View Controller Unification).
// Declarative presentation shell backed by `LibraryDisplayController`.
// All query planning, pagination offset tracking, series grouping, and
// metadata hydration are managed centrally by `displayController`.

struct LibraryRootView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(LibraryToolbarState.self) private var toolbarState
    @Environment(LibraryDisplayController.self) private var displayController
    @Environment(\.colorScheme) private var systemColorScheme
    @Bindable private var prefs = ReaderPreferences.shared

    // MARK: - View Identity & Scroll Position

    @State private var lastScrollResetKey: String?

    // MARK: - Resolved Library Colors

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

    var displayCount: Int {
        toolbarState.activeFilterResult?.totalCount ?? displayController.filteredCount ?? session.totalCount
    }

    private var scrollResetKey: String {
        let path = session.library?.root.path ?? ""
        let page = displayController.offsetState.currentPage
        let sort = toolbarState.sortField.rawValue
        let asc = toolbarState.ascending
        let group = toolbarState.groupBySeries
        let search = toolbarState.searchText
        let token = toolbarState.activeFilterResult?.reloadToken ?? ""
        return "\(path)-\(page)-\(sort)-\(asc)-\(group)-\(search)-\(token)"
    }

    private var activeCollectionID: String? {
        let collectionRules = toolbarState.filterExpression.groups.flatMap(\.rules)
            .filter { $0.field == .collection && $0.op == .equals }
        guard collectionRules.count == 1 else { return nil }
        return collectionRules[0].value
    }

    // MARK: - Body & Root Content

    var body: some View {
        attachSheets(to: mainLayout
            .background(libraryBGColor)
            .foregroundStyle(libraryTextColor)
            .preferredColorScheme(prefs.resolvedLibraryColorScheme))
    }

    private var mainLayout: some View {
        HStack(spacing: 0) {
            if toolbarState.showAO3FilterSidebar {
                AO3FilterSidebarView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            rootContent
        }
        .animation(.easeInOut(duration: 0.2), value: toolbarState.showAO3FilterSidebar)
    }

    private var rootContent: some View {
        VStack(spacing: 0) {
            Divider()
            if displayController.rebuildDegraded {
                degradedDataBanner
            }
            if let message = displayController.fulltextFailureMessage {
                searchFailureBanner(message: "Full-text search failed: \(message)", canRetry: true)
            } else if let message = session.lastSearchError {
                searchFailureBanner(message: "Search failed: \(message)", canRetry: false)
            }
            if toolbarState.hasActiveFilter || displayController.activeFullTextPhrase != nil {
                activeFilterChip(
                    count: toolbarState.activeFilterResult?.totalCount,
                    countPending: toolbarState.isFilterCountPending
                )
            }
            if !session.isOpen {
                emptyLibraryState
            } else if displayController.books.isEmpty && toolbarState.searchText.isEmpty && !toolbarState.hasActiveFilter {
                if displayController.didFinishFirstLoad { emptyBooksState } else { loadingState }
            } else if displayController.items.isEmpty && !displayController.books.isEmpty {
                loadingState
            } else if displayController.books.isEmpty && (toolbarState.hasActiveFilter || !toolbarState.searchText.isEmpty) {
                noResultsState
            } else {
                itemList
            }
            Divider()
            footer
        }
    }

    // MARK: - Status Banners

    private var degradedDataBanner: some View {
        Button {
            displayController.rebuildItems()
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

    private func searchFailureBanner(message: String, canRetry: Bool) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .lineLimit(2)
            Spacer()
            if canRetry {
                Button("Retry") { displayController.retryFailedFulltext() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
    }

    // MARK: - Active Filter Chip

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
                    displayController.scheduleLoadPage()
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
                if let phrase = displayController.activeFullTextPhrase {
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

    // MARK: - Item List

    private var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(displayController.items) { item in
                        itemRow(item)
                        Divider()
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .onChange(of: displayController.items.first?.id) {
                let key = scrollResetKey
                guard key != lastScrollResetKey else { return }
                lastScrollResetKey = key
                if let first = displayController.items.first?.id {
                    proxy.scrollTo(first, anchor: .top)
                }
            }
        }
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
            bookState: displayController.bookStates[book.id],
            ao3Metadata: displayController.ao3Metadata[book.id],
            ao3ExtractionDiagnostic: displayController.ao3ExtractionDiagnostics[book.id],
            singletonSeriesWarnings: warningsOverride ?? (displayController.singletonSeriesWarnings[book.id] ?? []),
            isLiked: session.cachedLikedIDs.contains(book.id),
            hideFanworksTagPill: prefs.hideFanworksTagPill,
            correctCalibreAmpEntities: prefs.correctCalibreAmpEntities,
            onTagTap: { tag, field in
                addTagPillRule(tag: tag, field: field)
            },
            onAuthorTap: { author in
                displayController.addOrReplaceRule(FilterRule(field: .authorName, op: .equals, value: author))
            },
            onOpen: { open([book]) },
            isInReadLater: session.cachedReadLaterIDs.contains(book.id),
            onReadLaterToggle: { toggleReadLater(for: book) },
            onLikeToggle: { toggleLike(for: book) },
            onReadLater: { addToReadLater([book]) },
            onSkip: { skip([book]) },
            onMarkRead: { markRead([book]) },
            onResetProgress: { resetProgress([book]) },
            onCollectionChanged: {
                CollectionAssignment.didAssign(session: session) {
                    Task { await displayController.refreshVisibilitySnapshots(resetPage: false) }
                }
            },
            activeCollectionID: activeCollectionID,
            onRemoveFromCollection: { collectionName in
                removeFromCollection(named: collectionName, calibreIDs: [book.id])
            }
        )
        .equatable()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func seriesRow(_ series: SeriesGroup, id: String) -> some View {
        SeriesListRow(
            series: series,
            hideFanworksTagPill: prefs.hideFanworksTagPill,
            isLiked: series.works.allSatisfy { session.cachedLikedIDs.contains($0.id) },
            onTagTap: { tag, field in
                addTagPillRule(tag: tag, field: field)
            },
            onLikeToggle: { toggleLike(for: series) },
            onOpen: { AppDelegate.shared?.openReaderWindow(target: .series(series)) },
            isInReadLater: series.works.allSatisfy { session.cachedReadLaterIDs.contains($0.id) },
            onReadLaterToggle: { toggleReadLater(for: series) },
            onSkip: { skip(series.works) },
            onMarkRead: { markRead(series.works) },
            onResetProgress: { resetProgress(series.works) },
            onCollectionChanged: {
                CollectionAssignment.didAssign(session: session) {
                    Task { await displayController.refreshVisibilitySnapshots(resetPage: false) }
                }
            },
            activeCollectionID: activeCollectionID,
            onRemoveFromCollection: { collectionName in
                removeFromCollection(named: collectionName, calibreIDs: series.works.map(\.id))
            },
            isSelected: false
        )
        .equatable()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func addTagPillRule(tag: String, field: FilterField) {
        let rule = FilterRule(field: field, op: .contains, value: tag)
        displayController.addOrReplaceRule(rule)
    }

    // MARK: - Row Actions & Mutations

    private func removeFromCollection(named collectionName: String, calibreIDs: [Int]) {
        Task {
            guard let collections = try? await session.collectionStore?.collections(),
                  let match = collections.first(where: { $0.name == collectionName }) else { return }
            try? await session.collectionStore?.bulkRemove(calibreIDs: calibreIDs, from: match.id)
            CollectionAssignment.didAssign(session: session) {
                Task { await displayController.refreshVisibilitySnapshots(resetPage: false) }
            }
        }
    }

    private func toggleLike(for book: CalibreBook) {
        Task {
            try? await session.collectionStore?.toggleLiked(calibreID: book.id)
            session.bumpMembershipVersion()
            await displayController.refreshVisibilitySnapshots(resetPage: false)
        }
    }

    private func toggleLike(for series: SeriesGroup) {
        let ids = series.works.map(\.id)
        let shouldLike = !series.works.allSatisfy { session.cachedLikedIDs.contains($0.id) }
        Task {
            try? await session.collectionStore?.setLiked(calibreIDs: ids, liked: shouldLike)
            session.bumpMembershipVersion()
            await displayController.refreshVisibilitySnapshots(resetPage: false)
        }
    }

    private func toggleReadLater(for book: CalibreBook) {
        let isCurrentlyInReadLater = session.cachedReadLaterIDs.contains(book.id)
        Task {
            if isCurrentlyInReadLater {
                try? await session.collectionStore?.remove(calibreID: book.id, from: SystemCollectionID.readLater)
            } else {
                try? await session.collectionStore?.bulkAdd(calibreIDs: [book.id], to: SystemCollectionID.readLater)
            }
            session.bumpMembershipVersion()
            await displayController.refreshVisibilitySnapshots(resetPage: false)
        }
    }

    private func toggleReadLater(for series: SeriesGroup) {
        let ids = series.works.map(\.id)
        let shouldAdd = !series.works.allSatisfy { session.cachedReadLaterIDs.contains($0.id) }
        Task {
            try? await session.collectionStore?.setReadLater(calibreIDs: ids, inReadLater: shouldAdd)
            session.bumpMembershipVersion()
            await displayController.refreshVisibilitySnapshots(resetPage: false)
        }
    }

    private func open(_ books: [CalibreBook]) {
        for book in books {
            AppDelegate.shared?.openReaderWindow(book: book)
        }
    }

    private func addToReadLater(_ books: [CalibreBook]) {
        let ids = books.map(\.id)
        Task {
            try? await session.collectionStore?.bulkAdd(calibreIDs: ids, to: SystemCollectionID.readLater)
            session.bumpMembershipVersion()
            await displayController.refreshVisibilitySnapshots(resetPage: false)
        }
    }

    private func skip(_ books: [CalibreBook]) {
        Task {
            for book in books {
                try? await session.collectionStore?.skipBook(calibreID: book.id)
            }
            session.bumpMembershipVersion()
            await displayController.refreshVisibilitySnapshots(resetPage: false)
        }
    }

    private func markRead(_ books: [CalibreBook]) {
        let ids = books.map(\.id)
        Task {
            if let metaDB = session.metaDB {
                for calibreID in ids {
                    try? await metaDB.markBookRead(calibreID: calibreID)
                }
            }
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
            session.bumpMembershipVersion()
            displayController.refreshBookStates()
        }
    }

    private func resetProgress(_ books: [CalibreBook]) {
        let ids = books.map(\.id)
        Task {
            if let metaDB = session.metaDB {
                for calibreID in ids {
                    try? await metaDB.resetReadingProgress(calibreID: calibreID)
                }
            }
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
            session.bumpMembershipVersion()
            displayController.refreshBookStates()
        }
    }

    // MARK: - Footer & Pagination

    private var footer: some View {
        HStack(spacing: 16) {
            Button("← Previous") {
                displayController.previousPage()
            }.disabled(!displayController.hasPreviousPage).buttonStyle(.borderless)
            Spacer()
            if session.isOpen {
                if displayController.shouldGroupSeriesRows {
                    if let total = displayController.visibleTotalCount {
                        let totalPages = max(1, Int(ceil(Double(total) / Double(displayController.pageSize))))
                        Text("Page \(displayController.offsetState.currentPage + 1) of \(totalPages)")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("\(displayController.items.count) item\(displayController.items.count == 1 ? "" : "s") on this page")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    let start = displayController.books.isEmpty ? 0 : displayController.offsetState.currentPage * displayController.pageSize + 1
                    let end   = displayController.offsetState.currentPage * displayController.pageSize + displayController.books.count
                    Text("\(start)–\(end) of \(displayController.visibleTotalCount ?? displayCount)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Next →") {
                displayController.nextPage()
            }.disabled(!displayController.hasNextPage).buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(libraryBGColor)
    }

    // MARK: - Empty States

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

    // MARK: - Sheets & Export Presentation

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
                        toolbarState.showFilterDrawer = false
                        displayController.applyFilterRules()
                    },
                    onClear: {
                        toolbarState.showFilterDrawer = false
                        toolbarState.filterExpression = FilterExpression()
                        toolbarState.activeFilterResult = nil
                        toolbarState.cancelLibraryFilterApplication()
                        displayController.scheduleLoadPage()
                    }
                )
                .preferredColorScheme(prefs.resolvedLibraryColorScheme)
            }
            .sheet(isPresented: Binding(
                get: { toolbarState.showCollections },
                set: { toolbarState.showCollections = $0 }
            )) {
                CollectionsView(onSelectCollection: { collection in
                    displayController.addOrReplaceRule(FilterRule(field: .collection, op: .equals, value: collection.name))
                    toolbarState.showCollections = false
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
                if toolbarState.triggerExport {
                    ExportManager.presentExportPanel(
                        books: displayController.books,
                        session: session,
                        filterResult: toolbarState.activeFilterResult,
                        toolbarState: toolbarState
                    )
                    toolbarState.triggerExport = false
                }
            }
            .onChange(of: toolbarState.triggerAnnotationExport) {
                if toolbarState.triggerAnnotationExport {
                    AnnotationExportManager.presentExportPanel(session: session)
                    toolbarState.triggerAnnotationExport = false
                }
            }
            .onChange(of: toolbarState.triggerEPUBExport) {
                if toolbarState.triggerEPUBExport {
                    toolbarState.triggerEPUBExport = false
                    guard let libraryRoot = session.library?.root else { return }
                    Task { @MainActor in
                        let rows = await ExportManager.buildExportRows(
                            currentPageBooks: displayController.books,
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

                        let confirm = NSAlert()
                        confirm.messageText = "Export \(count) EPUB\(count == 1 ? "" : "s")?"
                        confirm.informativeText = "This will copy \(count) EPUB file\(count == 1 ? "" : "s") " +
                            "to a folder you choose. Large libraries may take a minute."
                        confirm.addButton(withTitle: "Export")
                        confirm.addButton(withTitle: "Cancel")
                        guard confirm.runModal() == .alertFirstButtonReturn else { return }

                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.prompt = "Choose Export Folder"
                        guard panel.runModal() == .OK, let destination = panel.url else { return }

                        let progressAlert = NSAlert()
                        progressAlert.messageText = "Exporting EPUBs…"
                        progressAlert.informativeText = "Copying 0 of \(count)"
                        progressAlert.addButton(withTitle: "")
                        let progressBar = NSProgressIndicator()
                        progressBar.style = .bar
                        progressBar.isIndeterminate = false
                        progressBar.minValue = 0
                        progressBar.maxValue = Double(count)
                        progressBar.doubleValue = 0
                        progressBar.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
                        progressAlert.accessoryView = progressBar

                        var sheet: NSWindow?
                        if let win = NSApp.keyWindow ?? NSApp.mainWindow {
                            progressAlert.beginSheetModal(for: win) { _ in }
                            sheet = win.attachedSheet
                        }

                        let ao3Map = LibraryQueryHelpers.indexed(rows.compactMap { row in
                            row.ao3.map { (row.book.id, $0) }
                        })
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

                        if let win = sheet?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow,
                           let attachedSheet = win.attachedSheet {
                            win.endSheet(attachedSheet)
                        }

                        ExportManager.presentEPUBExportSummary(copied: copied, skipped: skipped)
                    }
                }
            }
    }
}
