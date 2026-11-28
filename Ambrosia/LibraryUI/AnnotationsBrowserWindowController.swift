import AppKit
import Observation
import SwiftUI

enum AnnotationBrowserScope: String, CaseIterable, Identifiable {
    case thisChapter = "This Chapter"
    case thisBook = "This Book"
    case entireLibrary = "Entire Library"

    var id: String { rawValue }
}

@MainActor
@Observable
final class AnnotationsBrowserViewModel {
    var query: String = ""
    var scope: AnnotationBrowserScope = .entireLibrary
    var filterType: AmbrosiaMetaDB.AnnotationFilterType = .all
    var colorFilter: AnnotationColor?
    var contextCalibreID: Int?
    var contextSpineIndex: Int?
    var rows: [(annotation: Annotation, book: CalibreBook)] = []
    var isLoading = false

    func reload(session: LibrarySession) async {
        guard let metaDB = session.metaDB, let library = session.library else {
            rows = []
            return
        }
        isLoading = true
        defer { isLoading = false }

        let scopeCalibreID: Int? = (scope == .thisBook || scope == .thisChapter) ? contextCalibreID : nil
        let scopeSpine: Int? = (scope == .thisChapter) ? contextSpineIndex : nil

        let matches: [(annotation: Annotation, calibreID: Int)]
        do {
            matches = try await metaDB.searchAnnotations(
                query: query,
                scopeCalibreID: scopeCalibreID,
                scopeSpineIndex: scopeSpine,
                filterType: filterType,
                colorKey: colorFilter
            )
        } catch {
            rows = []
            return
        }

        let ids = Array(Set(matches.map(\.calibreID)))
        let books = await library.booksForIDs(ids)
        let bookMap = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        rows = matches.compactMap { match in
            guard let book = bookMap[match.calibreID] else { return nil }
            return (match.annotation, book)
        }
    }

    func deleteAnnotation(_ annotation: Annotation, calibreID: Int, session: LibrarySession) async {
        try? await session.metaDB?.deleteAnnotation(id: annotation.id, calibreID: calibreID)
        await reload(session: session)
    }
}

struct AnnotationsBrowserView: View {
    let session: LibrarySession
    @State var viewModel: AnnotationsBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            controlsBar
            Divider()

            if viewModel.isLoading && viewModel.rows.isEmpty {
                ProgressView("Searching annotations…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.rows.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.rows, id: \.annotation.id) { item in
                        annotationRow(annotation: item.annotation, book: item.book)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                jumpTo(annotation: item.annotation, book: item.book)
                            }
                            .contextMenu {
                                Button("Open in Reader") {
                                    jumpTo(annotation: item.annotation, book: item.book)
                                }
                                Button("Copy Quote") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        "\(item.annotation.displayText) — \(item.book.displayTitle)",
                                        forType: .string
                                    )
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    Task {
                                        await viewModel.deleteAnnotation(
                                            item.annotation,
                                            calibreID: item.book.id,
                                            session: session
                                        )
                                    }
                                }
                            }
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .task {
            await viewModel.reload(session: session)
        }
        .onChange(of: viewModel.query) { _, _ in
            Task { await viewModel.reload(session: session) }
        }
        .onChange(of: viewModel.scope) { _, _ in
            Task { await viewModel.reload(session: session) }
        }
        .onChange(of: viewModel.filterType) { _, _ in
            Task { await viewModel.reload(session: session) }
        }
        .onChange(of: viewModel.colorFilter) { _, _ in
            Task { await viewModel.reload(session: session) }
        }
    }

    private var controlsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Search highlights, notes, and text edits…", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)

                Picker("Scope", selection: $viewModel.scope) {
                    ForEach(AnnotationBrowserScope.allCases) { scope in
                        if scope == .entireLibrary || viewModel.contextCalibreID != nil {
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
            }

            HStack(spacing: 8) {
                Picker("Type", selection: $viewModel.filterType) {
                    ForEach(AmbrosiaMetaDB.AnnotationFilterType.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Picker("Color", selection: $viewModel.colorFilter) {
                    Text("All Colors").tag(AnnotationColor?.none)
                    ForEach(AnnotationColor.allCases) { color in
                        Text(color.displayName).tag(AnnotationColor?.some(color))
                    }
                }
                .labelsHidden()
                .frame(width: 120)

                Spacer()

                Text("\(viewModel.rows.count) annotation\(viewModel.rows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "highlighter")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No matching annotations")
                .font(.headline)
            Text("Highlights, bookmarks, notes, and text edits across your library appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func annotationRow(annotation: Annotation, book: CalibreBook) -> some View {
        let context = SentenceContext.extract(
            quotePrefix: annotation.quotePrefix,
            selectedText: annotation.displayText,
            quoteSuffix: annotation.quoteSuffix
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: annotation.isPointAnnotation ? "bookmark.fill" : "highlighter")
                    .foregroundStyle(.secondary)
                Text(book.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let chapter = annotation.chapterTitle, !chapter.isEmpty {
                    Text("· \(chapter)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if annotation.isOrphaned {
                    Text("Couldn't relocate")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Text(annotation.updatedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let orig = annotation.originalText, let repl = annotation.replacementText {
                HStack(spacing: 4) {
                    Text(orig)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                    Text("→")
                        .foregroundStyle(.secondary)
                    Text(repl)
                        .fontWeight(.medium)
                }
                .font(.caption)
            }

            if !context.sentence.isEmpty {
                Text(context.sentence)
                    .font(.callout)
                    .lineLimit(3)
                    .opacity(annotation.isOrphaned ? 0.65 : 1.0)
            }

            if let note = annotation.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func jumpTo(annotation: Annotation, book: CalibreBook) {
        ReaderWindowController.open(book: book)
    }
}

@MainActor
final class AnnotationsBrowserWindowController: NSWindowController {
    private static var shared: AnnotationsBrowserWindowController?

    static func show(
        session: LibrarySession,
        contextCalibreID: Int? = nil,
        contextSpineIndex: Int? = nil
    ) {
        if let existing = shared {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let vm = AnnotationsBrowserViewModel()
        vm.contextCalibreID = contextCalibreID
        vm.contextSpineIndex = contextSpineIndex
        if contextCalibreID != nil {
            vm.scope = .thisBook
        }
        let hosting = NSHostingController(rootView: AnnotationsBrowserView(session: session, viewModel: vm))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Annotations Browser"
        window.setContentSize(NSSize(width: 780, height: 540))
        window.center()

        let wc = AnnotationsBrowserWindowController(window: window)
        shared = wc
        wc.showWindow(nil)
    }
}
