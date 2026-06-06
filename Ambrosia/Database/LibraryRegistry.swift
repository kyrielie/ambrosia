import Foundation

/// Persists the list of known Calibre library paths and the currently active one.
/// Stored in UserDefaults — no SwiftData dependency, readable before ModelContainer loads.
///
/// A "library" in Ambrosia terms = one Calibre folder containing metadata.db.
/// Switching libraries triggers a full metadata reset + re-import from the new path.
final class LibraryRegistry {

    static let shared = LibraryRegistry()
    private init() {}

    private let activeKey  = "calibreLibraryPath"
    private let knownKey   = "calibreKnownLibraries"

    // MARK: - Active library

    /// The currently active Calibre library path (set after a successful import).
    var activePath: String? {
        get { UserDefaults.standard.string(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }

    var activeURL: URL? {
        activePath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Known libraries

    /// All library paths the user has ever imported, most-recently-used first.
    var knownPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: knownKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: knownKey) }
    }

    /// Register a path after a successful import. Moves it to the front of the list.
    func register(_ url: URL) {
        let path = url.path
        var known = knownPaths.filter { $0 != path }   // remove if already present
        known.insert(path, at: 0)
        knownPaths = known
        activePath = path
    }

    /// Remove a path from the known list (e.g. if the folder no longer exists).
    func remove(_ path: String) {
        knownPaths = knownPaths.filter { $0 != path }
        if activePath == path { activePath = knownPaths.first }
    }

    /// Display name for a library path — the folder name, not the full path.
    func displayName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Returns true if the path contains a readable metadata.db.
    func isValid(_ path: String) -> Bool {
        let db = URL(fileURLWithPath: path).appendingPathComponent("metadata.db").path
        return FileManager.default.isReadableFile(atPath: db)
    }
}
