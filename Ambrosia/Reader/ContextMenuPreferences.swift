import Foundation

/// Configuration for the WKWebView right-click context menu in the reader.
/// Stored as a value type on ReaderPreferences; no UserDefaults persistence needed
/// for the initial implementation (all items shown by default).
struct ContextMenuPreferences {
    /// Show "Search in Browser" item (opens selected text in the system browser).
    var showSearchInBrowser: Bool = true
    /// Show "Add Annotation…" item (presents the annotation popover — B2).
    var showAddAnnotation: Bool   = true
}
