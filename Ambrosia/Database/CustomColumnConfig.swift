import Foundation

/// User-configurable mapping from semantic role → Calibre custom column label.
/// Persisted in UserDefaults. Populated from the Preferences window (Phase 7)
/// or auto-detected on first open.
final class CustomColumnConfig {

    static let shared = CustomColumnConfig()
    private init() {}

    private let wordCountKey = "customColumn.wordCount"
    private let kudosKey     = "customColumn.kudos"

    /// The Calibre custom column label (e.g. "words", "kudos") for word count.
    /// nil = not configured / not available in this library.
    var wordCountLabel: String? {
        get { UserDefaults.standard.string(forKey: wordCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: wordCountKey) }
    }

    /// The Calibre custom column label for kudos.
    var kudosLabel: String? {
        get { UserDefaults.standard.string(forKey: kudosKey) }
        set { UserDefaults.standard.set(newValue, forKey: kudosKey) }
    }

    // MARK: - Auto-detection

    /// Tries common label names in the library's custom_columns table.
    /// Only writes if the key is not already set.
    func autoDetect(using library: CalibreLibrary) {
        let cols = library.customColumns()
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
