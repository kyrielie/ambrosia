import Foundation
import Observation

/// Holds the active CalibreLibrary connection for the current session.
/// Opened when the user picks a folder or on launch if a path was saved.
/// Replaced wholesale when the user switches libraries — no import, no sync.
///
/// Injected into the SwiftUI environment so all views share one instance.
@Observable
final class LibrarySession {

    /// The open library connection. Nil until the user picks a folder.
    private(set) var library: CalibreLibrary?

    /// Optional full-text-search connection. Nil if full-text-search.db doesn't exist.
    private(set) var ftsLibrary: CalibreFTSLibrary?

    /// Cached total book count from metadata.db. Refreshed on library open
    /// and on search input (debounced). Never recomputed on page turns.
    private(set) var totalCount: Int = 0

    /// The path of the currently open library.
    private(set) var activePath: String?

    /// True while a library is open and ready to query.
    var isOpen: Bool { library != nil }

    /// Error from the last open attempt, shown in the UI if non-nil.
    private(set) var lastError: String?

    // MARK: - Opening / closing

    /// Open a Calibre library at the given URL.
    func open(url: URL) {
        lastError = nil
        do {
            let newLibrary = try CalibreLibrary(root: url)
            library    = newLibrary
            activePath = url.path
            totalCount = newLibrary.bookCount()
            ftsLibrary = CalibreFTSLibrary(libraryURL: url)
            LibraryRegistry.shared.register(url)
            print("[LibrarySession] Opened \(url.lastPathComponent) — \(totalCount) books")
        } catch {
            lastError = "Could not open library: \(error.localizedDescription)"
            print("[LibrarySession] Open failed: \(error)")
        }
    }

    func close() {
        library    = nil
        ftsLibrary = nil
        totalCount = 0
        activePath = nil
    }

    // MARK: - Count refresh

    func refreshCount(query: SearchQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])) {
        guard let library else { return }
        if query.isEmpty {
            totalCount = library.bookCount()
        } else {
            totalCount = library.bookCount(query: query)
        }
    }

    // MARK: - FTS resolution

    /// Attempts FTS resolution for plain terms; falls back to LIKE if FTS unavailable or empty.
    /// Shared between list view and email view — single source of truth.
    func resolvedQuery(_ query: SearchQuery) -> SearchQuery {
        guard !query.plainTerms.isEmpty,
              let fts = ftsLibrary else { return query }
        let plainText = query.plainTerms.joined(separator: " ")
        guard let ftsIDs = fts.search(query: plainText), !ftsIDs.isEmpty else {
            return query
        }
        return SearchQuery(
            tagTerms:     query.tagTerms,
            authorTerms:  query.authorTerms,
            titleTerms:   query.titleTerms,
            seriesTerms:  query.seriesTerms,
            plainTerms:   [],
            ftsMatchedIDs: ftsIDs
        )
    }

    // MARK: - Re-open saved library on launch

    func reopenIfNeeded() {
        guard library == nil,
              let path = LibraryRegistry.shared.activePath,
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard LibraryRegistry.shared.isValid(path) else {
            print("[LibrarySession] Saved path no longer valid: \(path)")
            return
        }
        open(url: url)
    }
}
