import AppKit
import Combine
import SwiftUI
import SwiftData

class LibraryViewController: NSViewController {
    private let modelContainer: ModelContainer
    private let session: LibrarySession

    /// Shared state between NSToolbar and all content views.
    /// Created here and vended upward to LibraryWindowController.
    let toolbarState = LibraryToolbarState()

    /// Tracks the hosting view for list mode so we can remove it on mode switch.
    private var listHostingView: NSHostingView<AnyView>?
    private var appearanceCancellable: AnyCancellable?

    init(modelContainer: ModelContainer, session: LibrarySession) {
        self.modelContainer = modelContainer
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 740)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyLibraryAppearance()
        applyViewMode(toolbarState.viewMode)
        startObservingViewMode()
        startObservingAppearance()
    }

    // MARK: - Appearance

    private func applyLibraryAppearance() {
        let appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
        view.appearance = appearance
        children.forEach { $0.view.appearance = appearance }
        listHostingView?.appearance = appearance
    }

    private func startObservingAppearance() {
        appearanceCancellable = ReaderPreferences.shared.$libraryAppearanceMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLibraryAppearance()
            }
    }

    // MARK: - View mode switching

    private func applyViewMode(_ mode: LibraryViewMode) {
        // Remove existing child VCs
        children.forEach {
            $0.view.removeFromSuperview()
            $0.removeFromParent()
        }
        // Remove any NSHostingView used directly (list mode)
        listHostingView?.removeFromSuperview()
        listHostingView = nil

        switch mode {
        case .list:
            // Use NSHostingView directly so we control sizing entirely via constraints.
            //
            // The {inf, 88} intrinsicContentSize crash happens because NSHostingView's
            // default sizingOptions (.intrinsicContentSize) makes Auto Layout ask SwiftUI
            // for its natural size during a layout pass triggered by state changes (e.g.
            // a tag tap mutating toolbarState).  SwiftUI returns {inf, 88} because it
            // hasn't been given a concrete width yet, and AppKit rejects the size.
            //
            // Fix: set sizingOptions = [] so the hosting view is purely constraint-driven
            // and never participates in intrinsic-size negotiation.
            let root = AnyView(
                LibraryRootView()
                    .environment(toolbarState)
                    .modelContainer(modelContainer)
                    .environment(session)
            )
            let hv = NSHostingView(rootView: root)
            hv.sizingOptions = []                             // ← the real fix
            hv.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
            hv.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hv)
            NSLayoutConstraint.activate([
                hv.topAnchor.constraint(equalTo: view.topAnchor),
                hv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                hv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            listHostingView = hv

        case .email:
            let childVC = EmailLibraryViewController(
                modelContainer: modelContainer,
                session: session,
                toolbarState: toolbarState
            )
            addChild(childVC)
            childVC.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
            childVC.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(childVC.view)
            NSLayoutConstraint.activate([
                childVC.view.topAnchor.constraint(equalTo: view.topAnchor),
                childVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                childVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                childVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])

        case .ranking:
            let placeholder = AnyView(
                ReadingHistoryView(session: session, modelContainer: modelContainer)
                    .environment(session)
            )
            let childVC = NSHostingController(rootView: placeholder)
            addChild(childVC)
            childVC.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance
            childVC.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(childVC.view)
            NSLayoutConstraint.activate([
                childVC.view.topAnchor.constraint(equalTo: view.topAnchor),
                childVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                childVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                childVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
    }

    // MARK: - Observation

    private func startObservingViewMode() {
        scheduleViewModeObservation()
    }

    private func scheduleViewModeObservation() {
        withObservationTracking {
            _ = toolbarState.viewMode
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyViewMode(self.toolbarState.viewMode)
                self.scheduleViewModeObservation()
            }
        }
    }
}

private struct ReadingHistoryView: View {
    let session: LibrarySession
    let modelContainer: ModelContainer

    @State private var rows: [ReadingHistoryDisplayRow] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading && rows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Reading History Unavailable", systemImage: "clock.badge.exclamationmark", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("No Reading History", systemImage: "clock", description: Text("Open a work in the reader to start logging sessions."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            ReadingHistoryRow(row: row) {
                                ReaderWindowController.open(book: row.book, modelContainer: modelContainer)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .task { await loadRows() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reading History")
                    .font(.title3.weight(.semibold))
                Text("Recent reader sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await loadRows() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @MainActor
    private func loadRows() async {
        guard let metaDB = session.metaDB, let library = session.library else {
            rows = []
            errorMessage = "Open a Calibre library first."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let entries = try await metaDB.recentReadingHistory(limit: 250)
            let ids = Array(Set(entries.map(\.calibreID)))
            let bookMap = Dictionary(uniqueKeysWithValues: library.booksForIDs(ids).map { ($0.id, $0) })
            rows = entries.compactMap { entry in
                guard let book = bookMap[entry.calibreID] else { return nil }
                return ReadingHistoryDisplayRow(entry: entry, book: book)
            }
        } catch {
            errorMessage = error.localizedDescription
            rows = []
        }
        isLoading = false
    }
}

private struct ReadingHistoryDisplayRow: Identifiable, Hashable {
    let entry: ReadingHistoryEntry
    let book: CalibreBook

    var id: Int64 { entry.id }
}

private struct ReadingHistoryRow: View {
    let row: ReadingHistoryDisplayRow
    let open: () -> Void

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.book.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(row.book.displayAuthors)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Opened \(Self.timestampFormatter.string(from: row.entry.sessionStart))")
                        Text("Closed \(Self.timestampFormatter.string(from: row.entry.sessionEnd))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let description = conciseDescription {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                tagLine

                ProgressView(value: progress)
                    .tint(progress >= 1 ? .green : .accentColor)
                HStack {
                    Text(progressText)
                    if let wordsRead = row.entry.wordsRead, wordsRead > 0 {
                        Text("\(wordsRead.formatted()) words")
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tagLine: some View {
        let fandoms = Array(row.entry.fandoms.prefix(4))
        let categories = Array(row.entry.categories.prefix(4))
        if !fandoms.isEmpty || !categories.isEmpty {
            HStack(spacing: 6) {
                ForEach(fandoms, id: \.self) { tag in
                    HistoryPill(text: tag, systemImage: "sparkles")
                }
                ForEach(categories, id: \.self) { tag in
                    HistoryPill(text: tag, systemImage: "person.2")
                }
                Spacer()
            }
        }
    }

    private var conciseDescription: String? {
        guard let description = row.book.displayComment?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return nil }
        if description.count <= 300 { return description }
        let end = description.index(description.startIndex, offsetBy: 300)
        return String(description[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private var progress: Double {
        min(max(row.entry.percentEnd ?? 0, 0), 1)
    }

    private var progressText: String {
        "\(Int((progress * 100).rounded()))%"
    }
}

private struct HistoryPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
