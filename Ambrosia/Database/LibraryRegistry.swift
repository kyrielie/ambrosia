import Foundation

// MARK: - App Environment

public enum AppEnvironment {

    /// True when running inside an XCTest test runner process (CLI or Xcode Test navigator).
    public static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Determines whether a given URL points to a temporary test fixture or test-created directory.
    public static func isTestLibraryURL(_ url: URL) -> Bool {
        let path = url.path
        if path.contains("ambrosia_test_library_")
            || path.contains("AmbrosiaTest")
            || path.contains("CalibreTestFixture")
            || path.contains("TagCandidateRestrictionTests")
            || path.contains("AmbrosiaMetaDB-vacuum-")
            || path.contains("MembershipDeltaTests")
            || path.contains("TagExpansionResolverTests")
            || path.contains("BookStateMetaDBTests")
            || path.contains("ErrorLogTests")
            || path.contains("CollectionStoreTests")
            || path.contains("IncrementalEquivalenceTests")
            || path.contains("CollectionAssignmentTests")
            || path.contains("LibraryStateTests")
            || path.contains("LibraryIndexManagerTests")
            || path.contains("CalibreFTSLibraryTests")
            || path.contains("LibraryDisplayControllerTests")
            || path.contains("CustomColumnConfigTests")
            || path.contains("StandaloneCalibreTests") {
            return true
        }

        let tempDir = FileManager.default.temporaryDirectory.path
        if (path.hasPrefix(tempDir) || path.hasPrefix("/var/folders/") || path.hasPrefix("/private/var/folders/"))
            && !FileManager.default.fileExists(atPath: path.appending("/metadata.db")) {
            return true
        }

        return false
    }
}

/// Persists the list of known Calibre library paths and the currently active one.
/// Stored in UserDefaults — no SwiftData dependency, readable before ModelContainer loads.
///
/// A "library" in Ambrosia terms = one Calibre folder containing metadata.db.
/// Switching libraries triggers a full metadata reset + re-import from the new path.
final class LibraryRegistry {

    static let shared = LibraryRegistry()

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults? = nil) {
        if let userDefaults {
            self.userDefaults = userDefaults
        } else if AppEnvironment.isRunningTests {
            self.userDefaults = UserDefaults(suiteName: "com.ambrosia.test-registry") ?? .standard
        } else {
            self.userDefaults = .standard
        }
    }

    private let activeKey  = "calibreLibraryPath"
    private let knownKey   = "calibreKnownLibraries"

    // MARK: - Active library

    /// The currently active Calibre library path (set after a successful import).
    var activePath: String? {
        get {
            guard let path = userDefaults.string(forKey: activeKey), !path.isEmpty else { return nil }
            if !AppEnvironment.isRunningTests && AppEnvironment.isTestLibraryURL(URL(fileURLWithPath: path)) {
                return nil
            }
            return path
        }
        set { userDefaults.set(newValue, forKey: activeKey) }
    }

    var activeURL: URL? {
        activePath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Known libraries

    /// All library paths the user has ever imported, most-recently-used first.
    var knownPaths: [String] {
        get {
            let paths = userDefaults.stringArray(forKey: knownKey) ?? []
            if AppEnvironment.isRunningTests { return paths }
            return paths.filter { !AppEnvironment.isTestLibraryURL(URL(fileURLWithPath: $0)) }
        }
        set { userDefaults.set(newValue, forKey: knownKey) }
    }

    /// Register a path after a successful import. Moves it to the front of the list.
    func register(_ url: URL) {
        if !AppEnvironment.isRunningTests && AppEnvironment.isTestLibraryURL(url) {
            return
        }
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

    /// Prunes any test library paths that may have lingered from previous test runs.
    func pruneStaleTestLibraries(force: Bool = false) {
        guard !AppEnvironment.isRunningTests || force else { return }
        let rawPaths = userDefaults.stringArray(forKey: knownKey) ?? []
        let sanitized = rawPaths.filter { !AppEnvironment.isTestLibraryURL(URL(fileURLWithPath: $0)) }
        if sanitized.count != rawPaths.count {
            userDefaults.set(sanitized, forKey: knownKey)
        }
        if let rawActive = userDefaults.string(forKey: activeKey),
           AppEnvironment.isTestLibraryURL(URL(fileURLWithPath: rawActive)) {
            userDefaults.set(sanitized.first, forKey: activeKey)
        }
    }
}
