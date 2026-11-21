// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

// MARK: - Search Mode

enum FTSSearchMode: String, CaseIterable, Identifiable {
    case lexical = "Exact (FTS5)"
    case semantic = "Semantic (Passages)"

    var id: String { rawValue }
}

// MARK: - Search Scope

enum FTSSearchScope: String, CaseIterable, Identifiable {
    case allBooks = "All Books"
    case filtered = "Current Filter"

    var id: String { rawValue }
}

// MARK: - Result Items

struct FTSResultItem: Identifiable {
    let id: Int
    let book: CalibreBook
    var ao3Metadata: AO3MetadataRecord?
    var snippetsResult: FTSMultiSnippetResult?
    var isLoadingSnippets: Bool
}

struct SemanticResultItem: Identifiable {
    let id: Int
    let book: CalibreBook
    var ao3Metadata: AO3MetadataRecord?
    var passage: SemanticPassageMatch
}

// MARK: - View Model

@Observable
@MainActor
final class FTSSearchViewModel {
    var mode: FTSSearchMode = .lexical
    var queryText: String = ""
    var scope: FTSSearchScope = .filtered
    private(set) var isSearching: Bool = false
    private(set) var isStreamingSnippets: Bool = false
    private(set) var results: [FTSResultItem] = []
    private(set) var passageResults: [SemanticResultItem] = []
    private(set) var totalOccurrences: Int = 0
    private(set) var errorMessage: String?
    private(set) var hasSearched: Bool = false

    private var searchTask: Task<Void, Never>?
    private var snippetStreamTask: Task<Void, Never>?

    func performSearch() {
        if mode == .semantic {
            performSemanticSearch()
        } else {
            performLexicalSearch()
        }
    }

    // MARK: - Lexical FTS5 Search

    private func performLexicalSearch() {
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

        guard ReaderPreferences.shared.enableFullTextSearch else {
            errorMessage = "Full-text search is disabled in Preferences ▸ Data."
            return
        }

        guard let ftsLibrary = session.ftsLibrary else {
            errorMessage = "Full-text search database (full-text-search.db) not found for this library. You can build it in Preferences ▸ Data."
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
                let token = ftsLibrary.beginSearch()
                let bookSet = try await ftsLibrary.searchBooks(query, token: token)
                var matchedIDs = bookSet.bookIDs

                if self.scope == .filtered {
                    if let activeIDs = await self.currentFilterIDs() {
                        matchedIDs = matchedIDs.filter { activeIDs.contains($0) }
                    }
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

    // MARK: - Semantic Passage Search

    private func performSemanticSearch() {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            passageResults = []
            hasSearched = false
            errorMessage = nil
            return
        }

        searchTask?.cancel()
        snippetStreamTask?.cancel()

        guard let session = AppDelegate.shared?.session else {
            errorMessage = "No active library session."
            return
        }

        guard let passageDB = session.passageDB else {
            errorMessage = "Semantic passage database (ambrosia_semantic_passages.db) not found for this library. "
                + "Generate it using scripts/ambrosia_embed_cli.py or copy it into the library folder."
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
        passageResults = []

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let embedder = PassageQueryEmbedder.shared
                guard await embedder.isModelAvailable else {
                    self.errorMessage = "CoreML embedding model (Qwen3-Embedding-0.6B) is not installed in Application Support/Ambrosia/Models/."
                    self.isSearching = false
                    return
                }

                let queryVector = try await embedder.embed(query: trimmed)
                guard !Task.isCancelled else { return }

                var restrictIDs: Set<Int>?
                if self.scope == .filtered {
                    restrictIDs = await self.currentFilterIDs()
                }

                let matches = try await passageDB.search(
                    queryVector: queryVector,
                    topK: 50,
                    minSimilarity: 0.15,
                    restrictBookIDs: restrictIDs
                )

                guard !Task.isCancelled else { return }

                let bookIDs = Array(Set(matches.map { $0.calibreID }))
                let fetchedBooks = await calibreLibrary.booksForIDs(bookIDs)
                let bookMap = Dictionary(uniqueKeysWithValues: fetchedBooks.map { ($0.id, $0) })
                let ao3Map = (try? await session.metaDB?.ao3Metadata(for: bookIDs)) ?? [:]

                var initialItems: [SemanticResultItem] = []
                for match in matches {
                    guard let book = bookMap[match.calibreID] else { continue }
                    initialItems.append(SemanticResultItem(
                        id: match.id,
                        book: book,
                        ao3Metadata: ao3Map[book.id],
                        passage: match
                    ))
                }

                self.passageResults = initialItems
                self.isSearching = false

                self.streamPassageExcerpts()
            } catch is CancellationError {
                // Cancelled
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = "Semantic passage search failed: \(error.localizedDescription)"
                    self.isSearching = false
                }
            }
        }
    }

    private func streamPassageExcerpts() {
        guard let pathStr = LibraryRegistry.shared.activePath else { return }
        let libraryRoot = URL(fileURLWithPath: pathStr)

        snippetStreamTask = Task { [weak self] in
            guard let self else { return }
            self.isStreamingSnippets = true

            for index in 0..<self.passageResults.count {
                guard !Task.isCancelled else { break }
                let item = self.passageResults[index]
                if let epubURL = item.book.epubURL(libraryRoot: libraryRoot) {
                    let excerpt = PassageSnippetExtractor.extractPassage(
                        epubURL: epubURL,
                        spineIndex: item.passage.spineIndex,
                        startOffset: item.passage.startOffset,
                        endOffset: item.passage.endOffset
                    )
                    guard !Task.isCancelled else { break }
                    if let excerpt, !excerpt.isEmpty {
                        self.passageResults[index].passage.extractedText = excerpt
                    }
                }
            }
            self.isStreamingSnippets = false
        }
    }

    private func currentFilterIDs() async -> Set<Int>? {
        guard let lwc = AppDelegate.shared?.libraryWindowController,
              let lvc = lwc.contentViewController as? LibraryViewController else {
            return nil
        }
        if let activeResult = lvc.toolbarState.activeFilterResult, !activeResult.calibreIDs.isEmpty {
            return Set(activeResult.calibreIDs)
        }
        if let activeResult = lvc.toolbarState.activeFilterResult, activeResult.isSQLBacked {
            let searchQuery = !lvc.toolbarState.searchText.isEmpty
                ? SearchQueryParser.parse(lvc.toolbarState.searchText)
                : SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])
            let ids = await AppDelegate.shared?.session.library?.fetchAllMatchingIDs(
                query: searchQuery,
                filter: lvc.toolbarState.filterExpression,
                restrictIDs: nil
            ) ?? []
            return Set(ids)
        }
        if !lvc.toolbarState.searchText.isEmpty {
            let searchQuery = SearchQueryParser.parse(lvc.toolbarState.searchText)
            let ids = await AppDelegate.shared?.session.library?.fetchAllMatchingIDs(
                query: searchQuery,
                filter: nil,
                restrictIDs: nil
            ) ?? []
            return Set(ids)
        }
        return nil
    }
}

// MARK: - Search Results View

struct FTSSearchResultsView: View {
    @State private var viewModel = FTSSearchViewModel()
    @State private var readLaterIDs: Set<Int> = AppDelegate.shared?.session.effectiveReadLaterIDs ?? []

    var body: some View {
        VStack(spacing: 0) {
            topControlBar
            Divider()
            statusSummaryBar
            Divider()
            contentArea
        }
        .frame(minWidth: 550, minHeight: 450)
        .onAppear {
            if let session = AppDelegate.shared?.session {
                readLaterIDs = session.effectiveReadLaterIDs
            }
        }
    }

    // MARK: - Top Control Bar

    private var topControlBar: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(FTSSearchMode.allCases) { searchMode in
                    Text(searchMode.rawValue).tag(searchMode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: viewModel.mode) { _, _ in
                if viewModel.hasSearched {
                    viewModel.performSearch()
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField(placeholderText, text: $viewModel.queryText)
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
            .labelsHidden()
            .fixedSize()
            .help("Search scope")
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

    private var placeholderText: String {
        switch viewModel.mode {
        case .lexical:
            return "Search book text (e.g. \"dialogue phrase\", tag:angst)..."
        case .semantic:
            return "Search narrative tropes, emotions, or scenes (e.g. \"duel in the snow\")..."
        }
    }

    // MARK: - Status Summary Bar

    private var statusSummaryBar: some View {
        HStack {
            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                Text(viewModel.mode == .semantic ? "Computing semantic passage matches…" : "Searching full-text index…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if viewModel.isStreamingSnippets {
                ProgressView()
                    .controlSize(.small)
                let streamLabel = viewModel.mode == .semantic
                    ? "Extracting scene paragraphs from EPUBs…"
                    : "Extracting passages (\(viewModel.totalOccurrences) matches found)…"
                Text(streamLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if viewModel.hasSearched {
                if viewModel.mode == .semantic {
                    let count = viewModel.passageResults.count
                    let label = count == 1 ? "1 matching scene found" : "\(count) matching scenes found"
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    let bookCount = viewModel.results.count
                    let bookLabel = bookCount == 1 ? "1 book" : "\(bookCount) books"
                    let matchLabel = viewModel.totalOccurrences == 1 ? "1 match" : "\(viewModel.totalOccurrences) matches"
                    Text("\(bookLabel) found (\(matchLabel))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                let defaultPrompt = viewModel.mode == .semantic
                    ? "Search scenes, narrative moments, or conceptual tropes across your library."
                    : "Enter terms or phrases to search book bodies across your Calibre library."
                Text(defaultPrompt)
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
        } else if viewModel.mode == .semantic {
            semanticContentArea
        } else {
            lexicalContentArea
        }
    }

    // MARK: - Semantic Results List

    @ViewBuilder
    private var semanticContentArea: some View {
        if viewModel.passageResults.isEmpty && !viewModel.isSearching {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("No matching scenes found for \"\(viewModel.queryText)\".")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.passageResults) { item in
                        PassageTypographicCardView(
                            book: item.book,
                            ao3Metadata: item.ao3Metadata,
                            passage: item.passage,
                            isReadLater: readLaterIDs.contains(item.book.id),
                            onToggleReadLater: {
                                toggleReadLater(for: item.book)
                            },
                            onOpenBook: {
                                openBook(item.book, passage: item.passage)
                            },
                            onSelectInLibrary: {
                                selectInLibrary(item.book)
                            },
                            onJumpToPassage: { match in
                                openBook(item.book, passage: match)
                            }
                        )
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Lexical Results List

    @ViewBuilder
    private var lexicalContentArea: some View {
        if viewModel.results.isEmpty && !viewModel.isSearching {
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
                            isReadLater: readLaterIDs.contains(item.book.id),
                            onToggleReadLater: {
                                toggleReadLater(for: item.book)
                            },
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
            Image(systemName: viewModel.mode == .semantic ? "sparkles" : "text.book.closed")
                .font(.system(size: 38))
                .foregroundColor(.secondary.opacity(0.8))

            Text(viewModel.mode == .semantic ? "Semantic Passage Search" : "Full-Text Search")
                .font(.headline)

            Text(viewModel.mode == .semantic
                 ? "Search scenes, narrative arcs, and conceptual tropes.\nReturns ranked passages matching narrative themes across your entire library."
                 : "Search full EPUB text across books in your library.\nSupports exact phrases with \"quotes\" and wildcard prefixes like run*.")
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

    private func openBook(_ book: CalibreBook, passage: SemanticPassageMatch) {
        AppDelegate.shared?.openReaderWindow(
            book: book,
            jumpToPassage: passage,
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

    private func toggleReadLater(for book: CalibreBook) {
        guard let session = AppDelegate.shared?.session else { return }
        CollectionAssignment.toggleReadLater(calibreIDs: [book.id], session: session) {
            self.readLaterIDs = session.effectiveReadLaterIDs
        }
        self.readLaterIDs = session.effectiveReadLaterIDs
    }
}
