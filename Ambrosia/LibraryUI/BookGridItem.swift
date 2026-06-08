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

    // BookState dictionary keyed by calibreID — fetched ONCE here, never per-row
    @State private var bookStates: [Int: BookState] = [:]

    private let pageSize = 100
    private let debouncer = DebounceTimer(delay: 0.3)

    var displayCount: Int {
        toolbarState.activeFilterResult?.totalCount ?? filteredCount ?? session.totalCount
    }

    var body: some View {
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
        .background(libraryBGColor)
        .foregroundStyle(libraryTextColor)
        .preferredColorScheme(prefs.libraryAppearanceMode == .system ? nil
            : prefs.libraryAppearanceMode == .light ? .light : .dark)
        .onChange(of: currentPage)                { loadPage() }
        .onChange(of: toolbarState.sortField)     { currentPage = 0; loadPage() }
        .onChange(of: toolbarState.ascending)     { currentPage = 0; loadPage() }
        .onChange(of: toolbarState.searchText) {
            currentPage = 0
            debouncer.schedule {
                loadPage()
                filteredCount = toolbarState.searchText.isEmpty ? nil
                    : session.library?.bookCount(search: toolbarState.searchText)
            }
        }
        .onChange(of: toolbarState.activeFilterResult?.calibreIDs) {
            currentPage = 0; loadPage()
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
        }
        // Sheet presentations driven by toolbarState trigger flags
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
        }
        .sheet(isPresented: Binding(
            get: { toolbarState.showCollections },
            set: { toolbarState.showCollections = $0 }
        )) {
            CollectionsView(onSelectCollection: { collection in
                addOrReplaceRule(FilterRule(field: .collection, op: .equals, value: collection.name))
            })
        }
        .sheet(isPresented: Binding(
            get: { toolbarState.showReadingGoal },
            set: { toolbarState.showReadingGoal = $0 }
        )) {
            ReadingGoalView()
        }
        .onChange(of: toolbarState.triggerExport) {
            if toolbarState.triggerExport {
                ExportManager.presentExportPanel(books: books)
                toolbarState.triggerExport = false
            }
        }
    }

    // MARK: - Data loading

    private func loadPage() {
        guard let library = session.library else { books = []; return }
        let effectiveSearch = toolbarState.searchText.isEmpty ? nil : toolbarState.searchText

        if let result = toolbarState.activeFilterResult, !result.calibreIDs.isEmpty {
            let raw = library.books(
                ids: result.calibreIDs,
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                search: effectiveSearch
            )
            hasNextPage = raw.count > pageSize
            books = Array(raw.prefix(pageSize))
        } else if toolbarState.activeFilterResult != nil {
            books = []; hasNextPage = false
        } else {
            let raw = library.books(
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: toolbarState.sortField, ascending: toolbarState.ascending,
                search: effectiveSearch
            )
            hasNextPage = raw.count > pageSize
            books = Array(raw.prefix(pageSize))
        }
    }

    /// Fetch all BookState rows once. O(n) over ever-opened books, not per visible row.
    private func refreshBookStates() {
        let all = (try? modelContext.fetch(FetchDescriptor<BookState>())) ?? []
        bookStates = Dictionary(uniqueKeysWithValues: all.map { ($0.calibreID, $0) })
    }

    private func applyFilterRules() {
        guard let library = session.library else { return }
        guard toolbarState.filterExpression.hasCompleteRules else {
            toolbarState.activeFilterResult = nil; currentPage = 0; loadPage(); return
        }
        let needsLiked = toolbarState.filterExpression.groups.flatMap(\.rules).contains { $0.field == .isLiked }
        let likedIDs: Set<Int> = needsLiked
            ? Set(bookStates.values.filter(\.isLiked).map(\.calibreID))
            : []

        let needsCollection = toolbarState.filterExpression.groups.flatMap(\.rules).contains { $0.field == .collection }
        let collectionMap: [String: Set<Int>]
        if needsCollection {
            let allCollections = (try? modelContext.fetch(FetchDescriptor<Collection>())) ?? []
            collectionMap = Dictionary(uniqueKeysWithValues:
                allCollections.map { ($0.name, Set($0.calibreIDs)) }
            )
        } else {
            collectionMap = [:]
        }

        let builder = FilterBuilder(library: library)
        toolbarState.activeFilterResult = builder.matchingIDs(
            expression: toolbarState.filterExpression,
            likedIDs: likedIDs,
            collectionMap: collectionMap
        )
        currentPage = 0; loadPage()
    }

    private func addOrReplaceRule(_ rule: FilterRule) {
        if toolbarState.filterExpression.groups.isEmpty {
            toolbarState.filterExpression.groups = [FilterGroup()]
        }
        let allRules = toolbarState.filterExpression.groups.flatMap(\.rules)
        let isDuplicate = allRules.contains {
            $0.field == rule.field && $0.value == rule.value && $0.op == rule.op
        }
        guard !isDuplicate else { return }
        if rule.field == .authorName {
            toolbarState.filterExpression.groups[0].rules.removeAll { $0.field == .authorName }
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
                modelContext: modelContext,
                onTagTap: { tag, field in
                    addOrReplaceRule(FilterRule(field: field, op: .equals, value: tag))
                },
                onAuthorTap: { author in
                    addOrReplaceRule(FilterRule(field: .authorName, op: .equals, value: author))
                },
                onLikeToggle: { toggleLike(for: book) }
            )
            .equatable()
            .listRowSeparator(.visible)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        }
        .listStyle(.plain)
    }

    private func toggleLike(for book: CalibreBook) {
        if let existing = bookStates[book.id] {
            existing.isLiked.toggle()
        } else {
            let s = BookState(calibreID: book.id)
            s.isLiked = true
            modelContext.insert(s)
            bookStates[book.id] = s
        }
        try? modelContext.save()
        refreshBookStates()
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

/// A single row in the library list.
///
/// Performance contract:
/// - NO SwiftData fetches inside this view. `bookState` is passed in by the parent.
/// - `AO3TagBuckets` is computed once from `book.tags` at init time (stored struct, not recomputed).
struct BookListRow: View, Equatable {
    let book: CalibreBook
    let bookState: BookState?       // pre-fetched by parent; nil if never opened
    let modelContext: ModelContext
    let onTagTap: (String, FilterField) -> Void
    let onAuthorTap: (String) -> Void
    let onLikeToggle: () -> Void

    // Equatable: closures cannot be compared so we only check data fields.
    static func == (lhs: BookListRow, rhs: BookListRow) -> Bool {
        lhs.book == rhs.book
            && lhs.bookState?.calibreID        == rhs.bookState?.calibreID
            && lhs.bookState?.isLiked          == rhs.bookState?.isLiked
            && lhs.bookState?.totalReadPercent == rhs.bookState?.totalReadPercent
    }

    // Computed once at struct init time — not recomputed on re-render
    private let buckets: AO3TagBuckets

    init(book: CalibreBook, bookState: BookState?, modelContext: ModelContext,
         onTagTap: @escaping (String, FilterField) -> Void,
         onAuthorTap: @escaping (String) -> Void,
         onLikeToggle: @escaping () -> Void) {
        self.book         = book
        self.bookState    = bookState
        self.modelContext = modelContext
        self.onTagTap     = onTagTap
        self.onAuthorTap  = onAuthorTap
        self.onLikeToggle = onLikeToggle
        self.buckets      = AO3TagBuckets.from(tags: book.tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            authorsRow
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
            Button(bookState?.isLiked == true ? "Unlike" : "Like") { onLikeToggle() }
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
                    Button(author) { onAuthorTap(author) }
                        .buttonStyle(.plain).font(.subheadline).foregroundStyle(.secondary)
                    if author != book.authors.last {
                        Text("·").foregroundStyle(.tertiary).font(.subheadline)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tagsRow: some View {
        let hasAny = !buckets.ratings.isEmpty || !buckets.warnings.isEmpty
                   || !buckets.categories.isEmpty || !buckets.regular.isEmpty

        if hasAny {
            CachedFlowLayout(spacing: 4) {
                ForEach(buckets.ratings, id: \.self) { tag in
                    ao3Pill(tag, color: .orange) { onTagTap(tag, .rating) }
                }
                ForEach(buckets.categories, id: \.self) { tag in
                    ao3Pill(tag, color: .blue)   { onTagTap(tag, .category) }
                }
                ForEach(buckets.warnings, id: \.self) { tag in
                    ao3Pill(tag, color: .red)    { onTagTap(tag, .warning) }
                }
                ForEach(buckets.regular, id: \.self) { tag in
                    regularPill(tag) { onTagTap(tag, .tag) }
                }
            }
            .drawingGroup()
        }
    }

    @ViewBuilder
    private var statsRow: some View {
        let wc = book.displayWordCount
        let k  = book.displayKudos
        let pct = bookState.map { $0.totalReadPercent }
        if !wc.isEmpty || !k.isEmpty || (pct ?? 0) > 0 {
            HStack(spacing: 14) {
                if !wc.isEmpty { statChip(wc, icon: "text.word.spacing") }
                if !k.isEmpty  { statChip(k,  icon: "heart") }
                if let p = pct, p > 0 {
                    statChip(String(format: "%.0f%% read", p * 100), icon: "book.pages")
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var descriptionRow: some View {
        if let comment = book.displayComment {
            CollapsibleText(text: comment)
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

    // MARK: - Pill builders

    private func ao3Pill(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.18))
                .foregroundStyle(color)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func regularPill(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(NSColor.controlBackgroundColor))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func statChip(_ label: String, icon: String) -> some View {
        Label(label, systemImage: icon).font(.caption2).foregroundStyle(.tertiary)
    }
}

// MARK: - Cached flow layout

/// `FlowLayout` with a size cache so `placeSubviews` doesn't remeasure every subview.
struct CachedFlowLayout: Layout {
    var spacing: CGFloat = 4

    struct Cache {
        var sizes: [CGSize] = []
        var proposedWidth: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? 600
        if cache.sizes.count != subviews.count || cache.proposedWidth != maxWidth {
            cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            cache.proposedWidth = maxWidth
        }
        return layout(sizes: cache.sizes, maxWidth: maxWidth, spacing: spacing).totalSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let maxWidth = bounds.width
        if cache.sizes.count != subviews.count || cache.proposedWidth != maxWidth {
            cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            cache.proposedWidth = maxWidth
        }
        let positions = layout(sizes: cache.sizes, maxWidth: maxWidth, spacing: spacing).positions
        for (i, sub) in subviews.enumerated() where i < positions.count {
            sub.place(at: CGPoint(x: bounds.minX + positions[i].x,
                                  y: bounds.minY + positions[i].y),
                      proposal: .unspecified)
        }
    }

    private struct LayoutResult {
        var positions: [CGPoint]
        var totalSize: CGSize
    }

    private func layout(sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat) -> LayoutResult {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for size in sizes {
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowH + spacing; rowH = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        return LayoutResult(positions: positions, totalSize: CGSize(width: maxWidth, height: y + rowH))
    }
}

// MARK: - Collapsible text

struct CollapsibleText: View {
    let text: String
    var collapsedLineLimit: Int = 4
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : collapsedLineLimit)
            if text.count > 300 {
                Button(expanded ? "Less ↑" : "More ↓") { expanded.toggle() }
                    .font(.caption2).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - FlowLayout (kept for filter chips)
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            rowH = max(rowH, size.height); x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified); rowH = max(rowH, size.height); x += size.width + spacing
        }
    }
}
