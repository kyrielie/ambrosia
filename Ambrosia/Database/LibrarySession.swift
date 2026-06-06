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
    /// Validates that metadata.db exists, opens a Connection, caches total count.
    /// Replaces any previously open library — no migration needed.
    func open(url: URL) {
        lastError = nil
        do {
            let newLibrary = try CalibreLibrary(root: url)
            library    = newLibrary
            activePath = url.path
            totalCount = newLibrary.bookCount()
            LibraryRegistry.shared.register(url)
            print("[LibrarySession] Opened \(url.lastPathComponent) — \(totalCount) books")
        } catch {
            lastError = "Could not open library: \(error.localizedDescription)"
            print("[LibrarySession] Open failed: \(error)")
        }
    }

    func close() {
        library    = nil
        totalCount = 0
        activePath = nil
    }

    // MARK: - Count refresh (call after debounced search input)

    func refreshCount(search: String?, filter: LibraryFilter = .none) {
        guard let library else { return }
        totalCount = library.bookCount(search: search, filter: filter)
    }

    // MARK: - Re-open saved library on launch

    /// Attempt to reopen the last used library from UserDefaults.
    /// Silent failure — if the path is gone, the user gets the empty state.
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
