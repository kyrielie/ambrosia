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
    @State private var hasNextPage  = false
    @State private var currentPage  = 0
    @State private var filteredCount: Int? = nil

    @State private var bookStates: [Int: BookState] = [:]
    @State private var ao3Metadata: [Int: AO3MetadataRecord] = [:]
    @State private var likedIDs: Set<Int> = []
    @State private var skippedIDs: Set<Int> = []

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
        rootContent
            .background(libraryBGColor)
            .foregroundStyle(libraryTextColor)
            .preferredColorScheme(prefs.resolvedLibraryColorScheme)
            .onChange(of: currentPage)                { loadPage() }
            .onChange(of: toolbarState.sortField)     { currentPage = 0; loadPage() }
            .onChange(of: toolbarState.ascending)     { currentPage = 0; loadPage() }
            .onChange(of: toolbarState.searchText) {
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
            .onChange(of: session.isOpen) {
                if session.isOpen {
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
                    books = []; bookStates = [:]
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
                bookList
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
            books = []; hasNextPage = false
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
        loadAO3MetadataForCurrentPage()
    }

    private func loadAO3MetadataForCurrentPage() {
        let ids = books.map(\.id)
        guard !ids.isEmpty, let metaDB = session.metaDB else {
            ao3Metadata = [:]
            return
        }
        Task {
            let metadata = (try? await metaDB.ao3Metadata(for: ids)) ?? [:]
            await MainActor.run {
                ao3Metadata = metadata
            }
        }
    }

    private func visibleIDs(_ ids: [Int]) -> [Int] {
        prefs.showSkippedCollection ? ids : ids.filter { !skippedIDs.contains($0) }
    }

    private func visibleBooks(_ raw: [CalibreBook]) -> [CalibreBook] {
        prefs.showSkippedCollection ? raw : raw.filter { !skippedIDs.contains($0.id) }
    }

    private func refreshBookStates() {
        let all = (try? modelContext.fetch(FetchDescriptor<BookState>())) ?? []
        bookStates = all.reduce(into: [:]) { $0[$1.calibreID] = $1 }
        Task {
            let currentLiked = (try? await session.collectionStore?.likedIDs()) ?? []
            let currentSkipped = Set((try? await session.collectionStore?.members(of: SystemCollectionID.skipped)) ?? [])
            await MainActor.run {
                likedIDs = currentLiked
                skippedIDs = currentSkipped
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
            let filteredIDs = prefs.showSkippedCollection
                ? result.calibreIDs
                : result.calibreIDs.filter { !currentSkipped.contains($0) }
            toolbarState.activeFilterResult = FilterResult(
                calibreIDs: filteredIDs,
                totalCount: filteredIDs.count
            )
            likedIDs = currentLikedIDs
            skippedIDs = currentSkipped
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

    private var bookList: some View {
        List(books) { book in
            BookListRow(
                book: book,
                bookState: bookStates[book.id],
                ao3Metadata: ao3Metadata[book.id],
                isLiked: likedIDs.contains(book.id),
                modelContext: modelContext,
                onTagTap: { tag, field in
                    addOrReplaceRule(FilterRule(field: field, op: .equals, value: tag))
                },
                onAuthorTap: { author in
                    addOrReplaceRule(FilterRule(field: .authorName, op: .equals, value: author))
                },
                onLikeToggle: { toggleLike(for: book) },
                onSkip: { skip(book) },
                onMarkRead: { markRead(book) }
            )
            .equatable()
            .listRowSeparator(.visible)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        }
        .listStyle(.plain)
    }

    private func toggleLike(for book: CalibreBook) {
        Task {
            try? await session.collectionStore?.toggleLiked(calibreID: book.id)
            likedIDs = (try? await session.collectionStore?.likedIDs()) ?? []
        }
    }

    private func skip(_ book: CalibreBook) {
        Task {
            try? await session.collectionStore?.skipBook(calibreID: book.id)
            skippedIDs.insert(book.id)
            applyFilterRules()
        }
    }

    private func markRead(_ book: CalibreBook) {
        let calibreID = book.id
        var desc = FetchDescriptor<BookState>(
            predicate: #Predicate { $0.calibreID == calibreID }
        )
        desc.fetchLimit = 1
        let state = (try? modelContext.fetch(desc).first) ?? BookState(calibreID: calibreID)
        if state.modelContext == nil {
            modelContext.insert(state)
        }
        state.totalReadPercent = 100
        try? modelContext.save()
        bookStates[calibreID] = state
        Task {
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
    let isLiked: Bool
    let modelContext: ModelContext
    let onTagTap: (String, FilterField) -> Void
    let onAuthorTap: (String) -> Void
    let onLikeToggle: () -> Void
    let onSkip: () -> Void
    let onMarkRead: () -> Void

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
            && lhs.bookState?.calibreID        == rhs.bookState?.calibreID
            && lhs.isLiked                     == rhs.isLiked
            && lhs.bookState?.totalReadPercent == rhs.bookState?.totalReadPercent
    }

    private let buckets: AO3TagBuckets

    init(book: CalibreBook, bookState: BookState?, ao3Metadata: AO3MetadataRecord?, isLiked: Bool, modelContext: ModelContext,
         onTagTap: @escaping (String, FilterField) -> Void,
         onAuthorTap: @escaping (String) -> Void,
         onLikeToggle: @escaping () -> Void,
         onSkip: @escaping () -> Void,
         onMarkRead: @escaping () -> Void) {
        self.book         = book
        self.bookState    = bookState
        self.ao3Metadata  = ao3Metadata
        self.isLiked      = isLiked
        self.modelContext = modelContext
        self.onTagTap     = onTagTap
        self.onAuthorTap  = onAuthorTap
        self.onLikeToggle = onLikeToggle
        self.onSkip       = onSkip
        self.onMarkRead   = onMarkRead
        self.buckets      = AO3TagBuckets.from(tags: book.tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            authorsRow
            ao3SummaryRow
            tagsRow
            statsRow
            descriptionRow
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            AppDelegate.shared?.openReaderWindow(book: book, modelContext: modelContext)
        }
        .contextMenu {
            Button("Open") {
                AppDelegate.shared?.openReaderWindow(book: book, modelContext: modelContext)
            }
            Divider()
            Button(isLiked ? "Unlike" : "Like") { onLikeToggle() }
            Button("Mark as Read") { onMarkRead() }
            Button("Skip") { onSkip() }
            Divider()
            AddToCollectionMenu(book: book)
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
    private var ao3SummaryRow: some View {
        HStack(spacing: 10) {
            let chapterLabel = ao3Metadata.flatMap(Self.chapterText) ?? "AO3 chapters unknown"
            statChip(chapterLabel, icon: (ao3Metadata?.isComplete == true) ? "checkmark.circle" : "clock")
            if let meta = ao3Metadata {
                if let language = meta.language, !language.isEmpty {
                    statChip(language, icon: "globe")
                }
                if let published = meta.publishedDate, !published.isEmpty {
                    statChip("Pub \(published)", icon: "calendar")
                }
                if let updated = meta.updatedDate, !updated.isEmpty, updated != meta.publishedDate {
                    statChip("Upd \(updated)", icon: "arrow.triangle.2.circlepath")
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statsRow: some View {
        let wc = ao3Metadata?.wordCount.map(Self.formatWordCount) ?? "AO3 words unknown"
        let k  = book.displayKudos
        let ao3Kudos = book.kudos == nil ? ao3Metadata?.kudosCount : nil
        let pct = bookState.map { $0.totalReadPercent }
        if !wc.isEmpty || !k.isEmpty || ao3Kudos != nil || (pct ?? 0) > 0 {
            HStack(spacing: 14) {
                if !wc.isEmpty { statChip(wc, icon: "text.word.spacing") }
                if !k.isEmpty  { statChip(k,  icon: "heart") }
                if let ao3Kudos { statChip(Self.formatKudos(ao3Kudos), icon: "heart") }
                if let p = pct, p > 0 {
                    statChip(String(format: "%.0f%% read", p * 100), icon: "book.pages")
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
        if cache.subviewSizes.count != subviews.count {
            cache.subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
            cache.lastWidth = -1
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? 800
        rebuildRows(in: &cache, maxWidth: maxWidth)
        return CGSize(width: maxWidth, height: cache.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
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
