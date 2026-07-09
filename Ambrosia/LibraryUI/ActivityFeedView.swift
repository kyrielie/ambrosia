import SwiftUI
import SwiftData

// MARK: - Top-level view

struct ActivityFeedView: View {
    let session: LibrarySession
    let modelContainer: ModelContainer

    // Received from LibraryViewController so toolbar buttons work in this mode.
    @Environment(LibraryToolbarState.self) private var toolbarState

    @State private var allEntries: [ActivityFeedEntry] = []
    @State private var filter: ActivityFeedFilter = .all
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            content
        }
        // Toolbar actions — same bindings used by list/email views.
        .sheet(isPresented: filterDrawerBinding) {
            FilterDrawerView(
                expression: Binding(
                    get: { toolbarState.filterExpression },
                    set: { toolbarState.filterExpression = $0 }
                ),
                onApply: {
                    toolbarState.showFilterDrawer = false
                },
                onClear: {
                    toolbarState.filterExpression = FilterExpression()
                    toolbarState.showFilterDrawer = false
                }
            )
        }
        .sheet(isPresented: collectionsBinding) {
            CollectionsView()
                .environment(session)
        }
        .sheet(isPresented: readingGoalBinding) {
            ReadingGoalView()
                .modelContainer(modelContainer)
        }
        .onChange(of: toolbarState.triggerExport) { _, triggered in
            // The activity view has no book list; silently reset the flag.
            // Export is handled by whichever content view owns the current book list.
            if triggered { toolbarState.triggerExport = false }
        }
        .task { await load() }
    }

    // MARK: Toolbar sheet bindings

    private var filterDrawerBinding: Binding<Bool> {
        Binding(
            get: { toolbarState.showFilterDrawer },
            set: { toolbarState.showFilterDrawer = $0 }
        )
    }

    private var collectionsBinding: Binding<Bool> {
        Binding(
            get: { toolbarState.showCollections },
            set: { toolbarState.showCollections = $0 }
        )
    }

    private var readingGoalBinding: Binding<Bool> {
        Binding(
            get: { toolbarState.showReadingGoal },
            set: { toolbarState.showReadingGoal = $0 }
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity")
                    .font(.title3.weight(.semibold))
                Text("Sessions, annotations, collection changes, and searches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ActivityFeedFilter.allCases) { tab in
                    ActivityFilterChip(
                        label: tab.rawValue,
                        symbol: tab.sfSymbol,
                        count: count(for: tab),
                        selected: filter == tab
                    ) {
                        if reduceMotion {
                            filter = tab
                        } else {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                filter = tab
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading && allEntries.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = errorMessage {
            ContentUnavailableView(
                "Activity Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(msg)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView(
                filter == .all ? "No Activity" : "No \(filter.rawValue)",
                systemImage: filter.emptyStateSymbol,
                description: Text(filter.emptyStateMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { entry in
                        ActivityFeedRow(entry: entry) {
                            handleRowTap(entry)
                        }
                        Divider()
                            .padding(.leading, 18)
                    }
                }
            }
        }
    }

    // MARK: Row tap handler

    private func handleRowTap(_ entry: ActivityFeedEntry) {
        switch entry {
        case .session(_, let book),
             .annotation(_, _, let book),
             .collectionChange(_, let book):
            ReaderWindowController.open(book: book, modelContainer: modelContainer)

        case .search(let s):
            // Re-apply the search and filter, then switch to list view.
            toolbarState.searchText        = s.searchText
            toolbarState.filterExpression  = s.filterExpression ?? FilterExpression()
            toolbarState.viewMode          = .list
        }
    }

    // MARK: Filtering

    private var filtered: [ActivityFeedEntry] {
        guard filter != .all else { return allEntries }
        return allEntries.filter { $0.matchesFilter == filter }
    }

    private func count(for tab: ActivityFeedFilter) -> Int {
        guard !allEntries.isEmpty else { return 0 }
        if tab == .all { return allEntries.count }
        return allEntries.filter { $0.matchesFilter == tab }.count
    }

    // MARK: Data loading

    @MainActor
    private func load() async {
        guard let metaDB = session.metaDB, let library = session.library else {
            errorMessage = "Open a Calibre library to see activity."
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil

        do {
            // Fetch DB-backed streams concurrently.
            async let sessionsTask    = metaDB.recentReadingHistory(limit: 250)
            async let annotationsTask = metaDB.recentAnnotations(limit: 250)
            async let collectionsTask = metaDB.recentCollectionActivity(limit: 250)

            let (sessions, annotations, collections) =
                try await (sessionsTask, annotationsTask, collectionsTask)

            // Resolve all book IDs in one library call.
            let allIDs: [Int] = Array(
                Set(sessions.map(\.calibreID))
                    .union(annotations.map(\.calibreID))
                    .union(collections.map(\.calibreID))
            )
            let bookMap: [Int: CalibreBook] = Dictionary(
                uniqueKeysWithValues: await library.booksForIDs(allIDs).map { ($0.id, $0) }
            )

            var merged: [ActivityFeedEntry] = []
            merged.reserveCapacity(
                sessions.count + annotations.count + collections.count
                + SearchActivityLog.shared.entries.count
            )

            for entry in sessions {
                if let book = bookMap[entry.calibreID] {
                    merged.append(.session(entry, book: book))
                }
            }
            for (annotation, calibreID) in annotations {
                if let book = bookMap[calibreID] {
                    merged.append(.annotation(annotation, calibreID: calibreID, book: book))
                }
            }
            for event in collections {
                if let book = bookMap[event.calibreID] {
                    merged.append(.collectionChange(event, book: book))
                }
            }
            for s in SearchActivityLog.shared.entries {
                merged.append(.search(s))
            }

            allEntries = merged.sorted { $0.date > $1.date }

        } catch {
            errorMessage = error.localizedDescription
            allEntries = []
        }

        isLoading = false
    }
}

// MARK: - Filter chip

private struct ActivityFilterChip: View {
    let label: String
    let symbol: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.caption.weight(.medium))
                Text(label)
                    .font(.caption.weight(selected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(selected ? .white : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(selected ? Color.accentColor : Color.secondary.opacity(0.25))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        selected ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
    }
}

// MARK: - Feed row

struct ActivityFeedRow: View {
    let entry: ActivityFeedEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Coloured type indicator
                ZStack {
                    Circle()
                        .fill(rowTint.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: rowSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(rowTint)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 5) {
                    titleLine
                    subtitleLine
                    detailBlock
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Common lines

    @ViewBuilder
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline) {
            if let book = entry.book {
                Text(book.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
            } else if case .search(let s) = entry {
                Text(s.displaySummary.isEmpty ? "Search" : s.displaySummary)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.date, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
            + Text(" ago")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var subtitleLine: some View {
        HStack(spacing: 6) {
            if let book = entry.book {
                Text(book.displayAuthors)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.tertiary)
            }
            Text(eventLabel)
                .font(.subheadline)
                .foregroundStyle(rowTint)
        }
    }

    // MARK: Event detail block

    @ViewBuilder
    private var detailBlock: some View {
        switch entry {

        case .session(let e, _):
            let pct = min(max(e.percentEnd ?? 0, 0), 1)
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: pct)
                    .tint(pct >= 1 ? .green : .accentColor)
                HStack(spacing: 10) {
                    Text("\(Int((pct * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let w = e.wordsRead, w > 0 {
                        Text("·").foregroundStyle(.tertiary).font(.caption)
                        Text("\(w.formatted()) words read")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let duration = e.sessionEnd.timeIntervalSince(e.sessionStart)
                    if duration > 60 {
                        Text(formattedDuration(duration))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !e.fandoms.isEmpty || !e.categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(e.fandoms.prefix(3), id: \.self) { PillLabel(text: $0, symbol: "sparkles") }
                            ForEach(e.categories.prefix(2), id: \.self) { PillLabel(text: $0, symbol: "person.2") }
                        }
                    }
                }
            }

        case .annotation(let a, _, _):
            VStack(alignment: .leading, spacing: 4) {
                if !a.isPointAnnotation, !a.selectedText.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(Color(hex: a.colorHex) ?? .yellow)
                            .frame(width: 3)
                            .clipShape(Capsule())
                        Text("\u{201C}\(a.selectedText.prefix(200))\u{201D}")
                            .font(.callout).italic()
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("Bookmark — spine \(a.spineIndex)", systemImage: "bookmark.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let note = a.note, !note.isEmpty {
                    Text(note.prefix(120))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).padding(.top, 1)
                }
            }

        case .collectionChange(let c, _):
            HStack(spacing: 6) {
                Image(systemName: c.isSystem ? "star.circle.fill" : "folder.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Text(c.collectionName)
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .search(let s):
            VStack(alignment: .leading, spacing: 6) {
                // Search text pill
                if !s.searchText.isEmpty {
                    Label("\"\(s.searchText)\"", systemImage: "magnifyingglass")
                        .font(.callout)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                // Filter rule pills
                if let expr = s.filterExpression {
                    let rules = expr.groups.flatMap(\.completeRules)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(rules.prefix(5)) { rule in
                                PillLabel(
                                    text: "\(rule.field.label): \(rule.value)",
                                    symbol: "line.3.horizontal.decrease"
                                )
                            }
                            if rules.count > 5 {
                                Text("+\(rules.count - 5) more")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                // Result count + re-apply hint
                HStack(spacing: 4) {
                    Text("\(s.resultCount) result\(s.resultCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption).foregroundStyle(.tertiary)
                    Text("Tap to re-apply")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Visual identity

    private var rowSymbol: String {
        switch entry {
        case .session:                       return "book.fill"
        case .annotation(let a, _, _):       return a.isPointAnnotation ? "bookmark.fill" : "highlighter"
        case .collectionChange:              return "folder.badge.plus"
        case .search(let s):                 return s.hasFilterRules ? "line.3.horizontal.decrease.circle.fill" : "magnifyingglass"
        }
    }

    private var rowTint: Color {
        switch entry {
        case .session:                       return .purple
        case .annotation(let a, _, _):
            return a.isPointAnnotation ? .blue : (Color(hex: a.colorHex) ?? .yellow)
        case .collectionChange:              return .green
        case .search(let s):                 return s.hasFilterRules ? .orange : .blue
        }
    }

    private var eventLabel: String {
        switch entry {
        case .session:                       return "Reading session"
        case .annotation(let a, _, _):       return a.isPointAnnotation ? "Bookmark" : "Highlight"
        case .collectionChange(let c, _):    return "Added to \u{201C}\(c.collectionName)\u{201D}"
        case .search(let s):                 return s.hasFilterRules ? "Filter" : "Search"
        }
    }

    // MARK: Helpers

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Pill label (shared)

struct PillLabel: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
