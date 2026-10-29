import SwiftUI
import AppKit

// MARK: - Search Scope

enum FTSSearchScope: String, CaseIterable, Identifiable {
    case allBooks = "All Books"
    case filtered = "Current Filter"

    var id: String { rawValue }
}

// MARK: - Result Item

struct FTSResultItem: Identifiable {
    let id: Int
    let book: CalibreBook
    var ao3Metadata: AO3MetadataRecord?
    var snippetsResult: FTSMultiSnippetResult?
    var isLoadingSnippets: Bool
}

// MARK: - View Model

@Observable
@MainActor
final class FTSSearchViewModel {
    var queryText: String = ""
    var scope: FTSSearchScope = .allBooks
    private(set) var isSearching: Bool = false
    private(set) var isStreamingSnippets: Bool = false
    private(set) var results: [FTSResultItem] = []
    private(set) var totalOccurrences: Int = 0
    private(set) var errorMessage: String?
    private(set) var hasSearched: Bool = false

    private var searchTask: Task<Void, Never>?
    private var snippetStreamTask: Task<Void, Never>?

    func performSearch() {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            totalOccurrences = 0
            hasSearched = false
            errorMessage = nil
            return
        }

        guard let query = FTSQuery.make(trimmed) else {
            errorMessage = "Invalid search syntax. Please check for unbalanced quotes or invalid operators."
            return
        }

        searchTask?.cancel()
        snippetStreamTask?.cancel()

        guard let session = AppDelegate.shared?.session else {
            errorMessage = "No active library session."
            return
        }

        guard let ftsLibrary = session.ftsLibrary else {
            errorMessage = "Full-text search database (full-text-search.db) not found for this library."
            return
        }

        guard let calibreLibrary = session.library else {
            errorMessage = "Calibre library is unavailable."
            return
        }

        errorMessage = nil
        isSearching = true
        isStreamingSnippets = false
        hasSearched = true
        results = []
        totalOccurrences = 0

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = await ftsLibrary.beginSearch()
                let bookSet = try await ftsLibrary.searchBooks(query, token: token)
                var matchedIDs = bookSet.bookIDs

                if self.scope == .filtered {
                    let activeIDs = self.currentFilterIDs()
                    matchedIDs = matchedIDs.filter { activeIDs.contains($0) }
                }

                guard !Task.isCancelled else { return }

                let fetchedBooks = await calibreLibrary.booksForIDs(matchedIDs)
                guard !Task.isCancelled else { return }

                let ao3Map = (try? await session.metaDB?.ao3Metadata(for: matchedIDs)) ?? [:]
                guard !Task.isCancelled else { return }

                var initialItems: [FTSResultItem] = []
                for book in fetchedBooks {
                    initialItems.append(FTSResultItem(
                        id: book.id,
                        book: book,
                        ao3Metadata: ao3Map[book.id],
                        snippetsResult: nil,
                        isLoadingSnippets: true
                    ))
                }

                self.results = initialItems
                self.isSearching = false

                // Phase 2: Asynchronous streaming of multi-snippets
                self.streamSnippets(query: query, token: token, ftsLibrary: ftsLibrary)
            } catch is CancellationError {
                // Cancelled by a new search
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = "Search failed: \(error.localizedDescription)"
                    self.isSearching = false
                }
            }
        }
    }

    private func streamSnippets(query: FTSQuery, token: SearchToken, ftsLibrary: CalibreFTSLibrary) {
        snippetStreamTask = Task { [weak self] in
            guard let self else { return }
            self.isStreamingSnippets = true
            var runningTotal = 0

            for index in 0..<self.results.count {
                guard !Task.isCancelled else { break }
                let bookID = self.results[index].book.id

                let multiSnippets = try? await ftsLibrary.multiSnippets(
                    bookID: bookID,
                    query: query,
                    token: token,
                    maxSnippets: 5,
                    snippetTokens: 32
                )

                guard !Task.isCancelled else { break }

                if let firstSnippet = multiSnippets?.first {
                    self.results[index].snippetsResult = firstSnippet
                    runningTotal += firstSnippet.totalOccurrences
                }
                self.results[index].isLoadingSnippets = false
                self.totalOccurrences = runningTotal
            }
            self.isStreamingSnippets = false
        }
    }

    private func currentFilterIDs() -> Set<Int> {
        if let lwc = AppDelegate.shared?.libraryWindowController,
           let lvc = lwc.contentViewController as? LibraryViewController {
            if let activeResult = lvc.toolbarState.activeFilterResult {
                return Set(activeResult.calibreIDs)
            }
            return Set(lvc.displayController.books.map(\.id))
        }
        return []
    }
}

// MARK: - Search Results View

struct FTSSearchResultsView: View {
    @State private var viewModel = FTSSearchViewModel()

    var body: some View {
        VStack(spacing: 0) {
            topControlBar
            Divider()
            statusSummaryBar
            Divider()
            contentArea
        }
        .frame(minWidth: 550, minHeight: 450)
    }

    // MARK: - Top Control Bar

    private var topControlBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search book body text (e.g. \"dialogue phrase\", tag:angst)...", text: $viewModel.queryText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.performSearch()
                    }

                if !viewModel.queryText.isEmpty {
                    Button {
                        viewModel.queryText = ""
                        viewModel.performSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )

            Picker("Scope", selection: $viewModel.scope) {
                ForEach(FTSSearchScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .onChange(of: viewModel.scope) { _, _ in
                if viewModel.hasSearched {
                    viewModel.performSearch()
                }
            }

            Button("Search") {
                viewModel.performSearch()
            }
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(12)
    }

    // MARK: - Status Summary Bar

    private var statusSummaryBar: some View {
        HStack {
            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                Text("Searching full-text index…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if viewModel.isStreamingSnippets {
                ProgressView()
                    .controlSize(.small)
                Text("Extracting passages (\(viewModel.totalOccurrences) matches found)…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if viewModel.hasSearched {
                let bookCount = viewModel.results.count
                let bookLabel = bookCount == 1 ? "1 book" : "\(bookCount) books"
                let matchLabel = viewModel.totalOccurrences == 1 ? "1 match" : "\(viewModel.totalOccurrences) matches"
                Text("\(bookLabel) found (\(matchLabel))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Enter terms or phrases to search book bodies across your Calibre library.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if let error = viewModel.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundColor(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if !viewModel.hasSearched {
            emptyPromptView
        } else if viewModel.results.isEmpty && !viewModel.isSearching {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("No matching passages found for \"\(viewModel.queryText)\".")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.results) { item in
                        FTSTypographicCardView(
                            book: item.book,
                            ao3Metadata: item.ao3Metadata,
                            result: item.snippetsResult,
                            isLoadingSnippets: item.isLoadingSnippets,
                            onOpen: {
                                openBook(item.book, snippet: item.snippetsResult?.snippets.first)
                            },
                            onSelectInLibrary: {
                                selectInLibrary(item.book)
                            },
                            onJumpToSnippet: { snippet in
                                openBook(item.book, snippet: snippet)
                            }
                        )
                    }
                }
                .padding(14)
            }
        }
    }

    private var emptyPromptView: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 38))
                .foregroundColor(.secondary.opacity(0.8))

            Text("Full-Text Search")
                .font(.headline)

            Text("Search full EPUB text across books in your library.\nSupports exact phrases with \"quotes\" and wildcard prefixes like run*.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func openBook(_ book: CalibreBook, snippet: FTSOccurrenceSnippet?) {
        AppDelegate.shared?.openReaderWindow(
            book: book,
            jumpToSnippet: snippet,
            searchQuery: viewModel.queryText
        )
    }

    private func selectInLibrary(_ book: CalibreBook) {
        guard let lwc = AppDelegate.shared?.libraryWindowController else { return }
        lwc.showWindow(nil)
        lwc.window?.makeKeyAndOrderFront(nil)
        if let lvc = lwc.contentViewController as? LibraryViewController {
            lvc.displayController.selectedItemID = "book-\(book.id)"
        }
    }
}
