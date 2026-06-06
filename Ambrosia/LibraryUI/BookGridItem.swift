import SwiftUI
import SwiftData

// MARK: - Library root view

struct LibraryRootView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.modelContext) private var modelContext

    @State private var books: [CalibreBook] = []
    @State private var hasNextPage = false
    @State private var currentPage = 0
    @State private var searchText  = ""
    @State private var sortField   = SortField.title
    @State private var ascending   = true
    @State private var filter      = LibraryFilter.none
    @State private var filteredCount: Int? = nil   // non-nil when searching

    private let pageSize = 100
    private let debouncer = DebounceTimer(delay: 0.3)

    var displayCount: Int {
        filteredCount ?? session.totalCount
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !session.isOpen {
                emptyLibraryState
            } else if books.isEmpty && searchText.isEmpty && filter == .none {
                loadingState
            } else {
                bookList
            }
            Divider()
            footer
        }
        // Active filter chip
        .safeAreaInset(edge: .top, spacing: 0) {
            if filter != .none {
                filterChip
            }
        }
        .onChange(of: currentPage)   { loadPage() }
        .onChange(of: sortField)     { currentPage = 0; loadPage() }
        .onChange(of: ascending)     { currentPage = 0; loadPage() }
        .onChange(of: filter)        { currentPage = 0; loadPage() }
        .onChange(of: searchText)    {
            currentPage = 0
            debouncer.schedule {
                loadPage()
                // Refresh count for search
                if searchText.isEmpty {
                    filteredCount = nil
                    session.refreshCount(search: nil, filter: filter)
                } else {
                    filteredCount = session.library?.bookCount(
                        search: searchText, filter: filter)
                }
            }
        }
        .onChange(of: session.isOpen) {
            if session.isOpen {
                currentPage = 0
                searchText = ""
                filter = .none
                loadPage()
            } else {
                books = []
            }
        }
        .onAppear { if session.isOpen { loadPage() } }
    }

    // MARK: - Load

    private func loadPage() {
        guard let library = session.library else { books = []; return }
        let raw = library.books(
            offset:    currentPage * pageSize,
            limit:     pageSize + 1,
            sort:      sortField,
            ascending: ascending,
            search:    searchText.isEmpty ? nil : searchText,
            filter:    filter
        )
        hasNextPage = raw.count > pageSize
        books = Array(raw.prefix(pageSize))
    }

    // MARK: - Subviews

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("Search titles…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            Spacer()

            Picker("Sort", selection: $sortField) {
                ForEach(SortField.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Button {
                ascending.toggle()
            } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(ascending ? "Ascending" : "Descending")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var filterChip: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.accent)
            Text(filter.label ?? "")
                .font(.callout)
            Spacer()
            Button {
                filter = .none
                filteredCount = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var bookList: some View {
        List(books) { book in
            BookListRow(book: book, modelContext: modelContext) { tapped in
                switch tapped {
                case .author(let name):
                    filter = .author(name)
                    filteredCount = session.library?.bookCount(filter: .author(name))
                case .tag(let name):
                    filter = .tag(name)
                    filteredCount = session.library?.bookCount(filter: .tag(name))
                }
            }
            .listRowSeparator(.visible)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        }
        .listStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("← Previous") { currentPage -= 1 }
                .disabled(currentPage == 0)
                .buttonStyle(.borderless)
            Spacer()
            if session.isOpen {
                let start = books.isEmpty ? 0 : currentPage * pageSize + 1
                let end   = currentPage * pageSize + books.count
                Text("\(start)–\(end) of \(displayCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Next →") { currentPage += 1 }
                .disabled(!hasNextPage)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var emptyLibraryState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("No library open")
                .font(.title3).foregroundStyle(.secondary)
            Button("Open Calibre Library…") {
                AppDelegate.shared?.chooseLibraryFolder()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Loading…")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tap action

enum RowTapAction {
    case author(String)
    case tag(String)
}

// MARK: - Book list row

struct BookListRow: View {
    let book: CalibreBook
    let modelContext: ModelContext
    let onTap: (RowTapAction) -> Void

    /// Cached BookState for progress overlay — fetched lazily
    @State private var state: BookState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {

            // Row 1: Title · Series · last opened
            HStack(alignment: .firstTextBaseline) {
                Text(book.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                if let series = book.displaySeries {
                    Text("·").foregroundStyle(.tertiary)
                    Text(series)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let s = state, s.lastOpenedDate > Date(timeIntervalSince1970: 1) {
                    Text(s.lastOpenedDate, style: .relative)
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            // Row 2: Authors (tappable)
            if !book.authors.isEmpty {
                HStack(spacing: 4) {
                    ForEach(book.authors, id: \.self) { author in
                        Button(author) { onTap(.author(author)) }
                            .buttonStyle(.plain)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if author != book.authors.last {
                            Text("·").foregroundStyle(.tertiary).font(.subheadline)
                        }
                    }
                }
            }

            // Row 3: Tags (tappable pills)
            if !book.tags.isEmpty {
                TagWrapView(tags: book.tags, onTap: { onTap(.tag($0)) })
            }

            // Row 4: Stats
            HStack(spacing: 14) {
                if !book.displayWordCount.isEmpty {
                    statChip(book.displayWordCount, icon: "text.word.spacing")
                }
                if !book.displayKudos.isEmpty {
                    statChip(book.displayKudos, icon: "heart")
                }
                if let s = state, s.totalReadPercent > 0 {
                    statChip(
                        String(format: "%.0f%% read", s.totalReadPercent * 100),
                        icon: "book.pages"
                    )
                }
                Spacer()
            }

            // Row 5: Description
            let commentText = book.displayComment ?? "No description"
            Text(commentText)
                .font(.caption)
                .foregroundStyle(book.displayComment != nil ? .secondary : .tertiary)
                .lineLimit(3)
                .padding(.top, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openReader() }
        .contextMenu {
            Button("Open") { openReader() }
            Divider()
            Button(state?.isLiked == true ? "Unlike" : "Like") { toggleLiked() }
            Button("Hide") { }   // Phase 6
        }
        .onAppear { fetchState() }
    }

    private func statChip(_ label: String, icon: String) -> some View {
        Label(label, systemImage: icon)
            .font(.caption2).foregroundStyle(.tertiary)
    }

    private func fetchState() {
        var desc = FetchDescriptor<BookState>(
            predicate: #Predicate { $0.calibreID == book.id }
        )
        desc.fetchLimit = 1
        state = try? modelContext.fetch(desc).first
    }

    private func toggleLiked() {
        if let s = state {
            s.isLiked.toggle()
            try? modelContext.save()
        } else {
            let s = BookState(calibreID: book.id)
            s.isLiked = true
            modelContext.insert(s)
            try? modelContext.save()
            state = s
        }
    }

    private func openReader() {
        // Phase 3: open ReaderWindowController
        print("[Ambrosia] Open: \(book.displayTitle)")
    }
}

// MARK: - Tag wrap view (flow layout, tappable)

struct TagWrapView: View {
    let tags: [String]
    var onTap: ((String) -> Void)? = nil

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Button(action: { onTap?(tag) }) {
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(onTap == nil)
            }
        }
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
