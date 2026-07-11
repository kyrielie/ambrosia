import AppKit

/// Bridges AppKit's `NSFontManager` target/action pattern (which requires an
/// `NSObject` target) into `ReaderPreferences`, so the system Font Panel can
/// be used as an escape hatch beyond the ten curated `fontPresets`.
final class FontPanelCoordinator: NSObject {
    static let shared = FontPanelCoordinator()

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let manager = sender else { return }
        let base = NSFont(name: ReaderPreferences.shared.displayFontFamily, size: 13)
            ?? NSFont.systemFont(ofSize: 13)
        let picked = manager.convert(base)
        // Emit just the quoted family name, no generic fallback appended. If the
        // picked font isn't available to WKWebView for web rendering, it will
        // fall back to its own default — acceptable since the alternative is
        // guessing serif vs. sans-serif from trait masks, which isn't reliable
        // enough to be worth the complexity here.
        let familyName = picked.familyName ?? picked.fontName
        ReaderPreferences.shared.fontFamily = "\"\(familyName)\""
    }
}
