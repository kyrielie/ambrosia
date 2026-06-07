import SwiftUI
import SwiftData

// MARK: - Library root view

struct LibraryRootView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.modelContext) private var modelContext

    @State private var books: [CalibreBook] = []
    @State private var hasNextPage  = false
    @State private var currentPage  = 0
    @State private var searchText   = ""
    @State private var sortField    = SortField.title
    @State private var ascending    = true
    @State private var filteredCount: Int? = nil

    // Filter state
    @State private var filterExpression  = FilterExpression()
    @State private var activeFilterResult: FilterResult? = nil
    @State private var showFilterDrawer  = false

    // BookState dictionary keyed by calibreID — fetched ONCE here, never per-row
    @State private var bookStates: [Int: BookState] = [:]

    // Phase 6 sheet state
    @State private var showCollections = false
    @State private var showReadingGoal = false

    private let pageSize = 100
    private let debouncer = DebounceTimer(delay: 0.3)

    var displayCount: Int {
        activeFilterResult?.totalCount ?? filteredCount ?? session.totalCount
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let result = activeFilterResult {
                activeFilterChip(count: result.totalCount)
            }
            if !session.isOpen {
                emptyLibraryState
            } else if books.isEmpty && searchText.isEmpty && activeFilterResult == nil {
                loadingState
            } else {
                bookList
            }
            Divider()
            footer
        }
        .onChange(of: currentPage)    { loadPage() }
        .onChange(of: sortField)      { currentPage = 0; loadPage() }
        .onChange(of: ascending)      { currentPage = 0; loadPage() }
        .onChange(of: searchText) {
            currentPage = 0
            debouncer.schedule {
                loadPage()
                filteredCount = searchText.isEmpty ? nil
                    : session.library?.bookCount(search: searchText)
            }
        }
        .onChange(of: session.isOpen) {
            if session.isOpen {
                currentPage = 0; searchText = ""
                activeFilterResult = nil; filterExpression = FilterExpression()
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
        .sheet(isPresented: $showFilterDrawer) {
            FilterDrawerView(
                expression: $filterExpression,
                onApply: { applyFilterRules() },
                onClear: {
                    filterExpression = FilterExpression()
                    activeFilterResult = nil
                    currentPage = 0; loadPage()
                }
            )
        }
        .sheet(isPresented: $showCollections) {
            CollectionsView(onSelectCollection: { collection in
                addOrReplaceRule(FilterRule(field: .collection, op: .equals, value: collection.name))
            })
        }
        .sheet(isPresented: $showReadingGoal) {
            ReadingGoalView()
        }
    }

    // MARK: - Data loading

    private func loadPage() {
        guard let library = session.library else { books = []; return }
        let effectiveSearch = searchText.isEmpty ? nil : searchText

        if let result = activeFilterResult, !result.calibreIDs.isEmpty {
            let raw = library.books(
                ids: result.calibreIDs,
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: sortField, ascending: ascending, search: effectiveSearch
            )
            hasNextPage = raw.count > pageSize
            books = Array(raw.prefix(pageSize))
        } else if activeFilterResult != nil {
            books = []; hasNextPage = false
        } else {
            let raw = library.books(
                offset: currentPage * pageSize, limit: pageSize + 1,
                sort: sortField, ascending: ascending, search: effectiveSearch
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
        guard filterExpression.hasCompleteRules else {
            activeFilterResult = nil; currentPage = 0; loadPage(); return
        }
        let needsLiked = filterExpression.groups.flatMap(\.rules).contains { $0.field == .isLiked }
        let likedIDs: Set<Int> = needsLiked
            ? Set(bookStates.values.filter(\.isLiked).map(\.calibreID))
            : []

        // Build collection name → IDs map (from SwiftData) for in-memory evaluation
        let needsCollection = filterExpression.groups.flatMap(\.rules).contains { $0.field == .collection }
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
        activeFilterResult = builder.matchingIDs(expression: filterExpression,
                                                  likedIDs: likedIDs,
                                                  collectionMap: collectionMap)
        currentPage = 0; loadPage()
    }

    private func addOrReplaceRule(_ rule: FilterRule) {
        if filterExpression.groups.isEmpty { filterExpression.groups = [FilterGroup()] }
        let allRules = filterExpression.groups.flatMap(\.rules)
        let isDuplicate = allRules.contains {
            $0.field == rule.field && $0.value == rule.value && $0.op == rule.op
        }
        guard !isDuplicate else { return }
        if rule.field == .authorName {
            filterExpression.groups[0].rules.removeAll { $0.field == .authorName }
        }
        filterExpression.groups[0].rules.append(rule)
        applyFilterRules()
    }

    // MARK: - Subviews

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("Search titles…", text: $searchText)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
            Spacer()
            // Phase 6 — Collections
            Button { showCollections = true } label: {
                Label("Collections", systemImage: "tray.2")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Manage Collections")

            // Phase 6 — Reading Goal
            Button { showReadingGoal = true } label: {
                Label("Reading Goal", systemImage: "target")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Reading Goal")

            // Phase 6 — CSV Export
            Button {
                ExportManager.presentExportPanel(books: books)
            } label: {
                Label("Export", systemImage: "arrow.up.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Export current list to CSV")
            .disabled(books.isEmpty)

            Divider().frame(height: 16)

            Button { showFilterDrawer = true } label: {
                Label("Filter", systemImage: filterExpression.isEmpty
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .overlay(alignment: .topTrailing) {
                if !filterExpression.isEmpty {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8).offset(x: 2, y: -2)
                }
            }
            Picker("Sort", selection: $sortField) {
                ForEach(SortField.allCases) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.menu).frame(width: 140)
            Button { ascending.toggle() } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func activeFilterChip(count: Int) -> some View {
        let completeRules = filterExpression.groups.flatMap(\.rules).filter(\.isComplete)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                Text("\(count) result\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit") { showFilterDrawer = true }
                    .buttonStyle(.borderless).font(.caption)
                Button {
                    filterExpression = FilterExpression(); activeFilterResult = nil
                    currentPage = 0; loadPage()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            // Show each active filter value as a pill.
            // Negated operators (notContains, notEquals) get a red NOT badge.
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
                onLikeToggle: {
                    // Update the shared dictionary so the row reflects the new state immediately
                    toggleLike(for: book)
                }
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
        .background(Color(NSColor.windowBackgroundColor))
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
    // This lets .equatable() skip re-rendering rows whose book data is unchanged.
    static func == (lhs: BookListRow, rhs: BookListRow) -> Bool {
        lhs.book == rhs.book
            && lhs.bookState?.calibreID    == rhs.bookState?.calibreID
            && lhs.bookState?.isLiked      == rhs.bookState?.isLiked
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

    // MARK: - Row sections (each a @ViewBuilder to keep body clean)

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

    /// All tags in one FlowLayout pass — AO3 metadata first (coloured), then all regular tags.
    /// .drawingGroup() flattens all pills into a single Metal layer per row.
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

    /// Format a last-opened date as a static string so SwiftUI does not create
    /// a live-updating timer for every visible row. Relative date Text views
    /// fire re-renders across all visible rows on a system timer.
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
        // Measure each subview once and cache
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

// MARK: - (Unused original FlowLayout kept for reference — use CachedFlowLayout)
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
