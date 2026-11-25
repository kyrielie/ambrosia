import Foundation

/// User-configurable mapping from semantic role → Calibre custom column label.
/// Persisted in UserDefaults. Populated from the Preferences window (Phase 7)
/// or auto-detected on first open.
///
/// `@unchecked Sendable`: this type has no mutable stored properties — all state
/// is proxied through UserDefaults, which is itself thread-safe. It is read from
/// both the MainActor (Preferences window) and the CalibreLibrary actor (query
/// helpers), so it must be safe to reference across isolation domains.
final class CustomColumnConfig: @unchecked Sendable {

    static let shared = CustomColumnConfig()
    public let userDefaults: UserDefaults

    init(userDefaults: UserDefaults? = nil) {
        if let userDefaults {
            self.userDefaults = userDefaults
        } else if AppEnvironment.isRunningTests {
            self.userDefaults = UserDefaults(suiteName: "com.ambrosia.test-custom-columns") ?? .standard
        } else {
            self.userDefaults = .standard
        }
    }

    private let wordCountKey = "customColumn.wordCount"
    private let kudosKey     = "customColumn.kudos"

    /// The Calibre custom column label (e.g. "words", "kudos") for word count.
    /// nil = not configured / not available in this library.
    var wordCountLabel: String? {
        get { userDefaults.string(forKey: wordCountKey) }
        set { userDefaults.set(newValue, forKey: wordCountKey) }
    }

    /// The Calibre custom column label for kudos.
    var kudosLabel: String? {
        get { userDefaults.string(forKey: kudosKey) }
        set { userDefaults.set(newValue, forKey: kudosKey) }
    }

    // MARK: - Auto-detection

    /// Tries common label names in the library's custom_columns table.
    /// Only writes if the key is not already set.
    func autoDetect(using library: CalibreLibrary) async {
        let cols = await library.customColumns()
        let labels = cols.map { $0.label }   // already lowercased

        if wordCountLabel == nil {
            let candidates = ["words", "word_count", "wordcount", "word count"]
            wordCountLabel = candidates.first { labels.contains($0) }
        }
        if kudosLabel == nil {
            let candidates = ["kudos", "kudo"]
            kudosLabel = candidates.first { labels.contains($0) }
        }
    }
}
