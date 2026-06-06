import Foundation
import AppKit
import Combine

/// User-configurable reading preferences.
/// Changes trigger a full HTML reload in ReaderViewController (never patch the live DOM).
/// Stored in UserDefaults under the "ReaderPreferences" key prefix.
final class ReaderPreferences: ObservableObject {

    static let shared = ReaderPreferences()

    // MARK: - Stored properties (UserDefaults-backed)

    @Published var fontFamily: String {
        didSet { UserDefaults.standard.set(fontFamily, forKey: Keys.fontFamily) }
    }
    @Published var fontSize: Int {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }
    @Published var lineHeight: Double {
        didSet { UserDefaults.standard.set(lineHeight, forKey: Keys.lineHeight) }
    }
    @Published var maxWidth: Int {
        didSet { UserDefaults.standard.set(maxWidth, forKey: Keys.maxWidth) }
    }
    @Published var backgroundColor: String {
        didSet { UserDefaults.standard.set(backgroundColor, forKey: Keys.backgroundColor) }
    }
    @Published var textColor: String {
        didSet { UserDefaults.standard.set(textColor, forKey: Keys.textColor) }
    }
    @Published var paddingH: Int {
        didSet { UserDefaults.standard.set(paddingH, forKey: Keys.paddingH) }
    }
    @Published var paddingV: Int {
        didSet { UserDefaults.standard.set(paddingV, forKey: Keys.paddingV) }
    }

    // MARK: - Defaults

    private enum Defaults {
        static let fontFamily       = "Georgia, serif"
        static let fontSize         = 18
        static let lineHeight       = 1.7
        static let maxWidth         = 680
        static let backgroundColor  = "#FFFDF6"
        static let textColor        = "#1A1A1A"
        static let paddingH         = 24
        static let paddingV         = 32
    }

    private enum Keys {
        static let fontFamily       = "rp.fontFamily"
        static let fontSize         = "rp.fontSize"
        static let lineHeight       = "rp.lineHeight"
        static let maxWidth         = "rp.maxWidth"
        static let backgroundColor  = "rp.backgroundColor"
        static let textColor        = "rp.textColor"
        static let paddingH         = "rp.paddingH"
        static let paddingV         = "rp.paddingV"
    }

    private init() {
        let ud = UserDefaults.standard
        fontFamily      = ud.string(forKey: Keys.fontFamily)       ?? Defaults.fontFamily
        fontSize        = ud.integer(forKey: Keys.fontSize).nonZero ?? Defaults.fontSize
        lineHeight      = ud.double(forKey: Keys.lineHeight).nonZero ?? Defaults.lineHeight
        maxWidth        = ud.integer(forKey: Keys.maxWidth).nonZero ?? Defaults.maxWidth
        backgroundColor = ud.string(forKey: Keys.backgroundColor)  ?? Defaults.backgroundColor
        textColor       = ud.string(forKey: Keys.textColor)         ?? Defaults.textColor
        paddingH        = ud.integer(forKey: Keys.paddingH).nonZero ?? Defaults.paddingH
        paddingV        = ud.integer(forKey: Keys.paddingV).nonZero ?? Defaults.paddingV
    }

    // MARK: - CSS generation

    /// Returns a CSS string ready to inject into the EPUB's <head>.
    /// ReaderViewController calls this each time it builds HTML.
    var css: String {
        """
        /* === Ambrosia user preferences === */
        html, body {
            background-color: \(backgroundColor);
            color: \(textColor);
        }
        body {
            font-family: \(fontFamily);
            font-size: \(fontSize)px;
            line-height: \(lineHeight);
            max-width: \(maxWidth)px;
            margin: 0 auto;
            padding: \(paddingV)px \(paddingH)px;
            -webkit-font-smoothing: antialiased;
            word-wrap: break-word;
        }
        img  { max-width: 100%; height: auto; display: block; margin: 1em auto; }
        p    { margin-bottom: 0.8em; }
        a    { color: inherit; text-decoration: underline; pointer-events: none; }
        em, i { font-style: italic; }
        strong, b { font-weight: bold; }
        h1, h2, h3, h4, h5, h6 { font-weight: bold; margin: 1em 0 0.5em; line-height: 1.2; }
        h1 { font-size: 1.6em; } h2 { font-size: 1.4em; } h3 { font-size: 1.2em; }
        table { border-collapse: collapse; width: 100%; margin: 1em 0; }
        td, th { border: 1px solid currentColor; padding: 0.4em 0.6em; }
        hr { border: none; border-top: 1px solid currentColor; opacity: 0.3; margin: 1.5em 0; }
        code, pre { font-family: "SF Mono", Menlo, monospace; font-size: 0.9em; }
        pre { overflow-x: auto; padding: 1em; background: rgba(128,128,128,0.1); border-radius: 4px; }
        div, section, article { float: none !important; position: static !important; column-count: unset !important; }
        /* Suppress EPUB nav landmarks */
        nav[epub\\:type="toc"], nav[epub\\:type="landmarks"] { display: none; }
        """
    }

    // MARK: - Reset

    func resetToDefaults() {
        fontFamily      = Defaults.fontFamily
        fontSize        = Defaults.fontSize
        lineHeight      = Defaults.lineHeight
        maxWidth        = Defaults.maxWidth
        backgroundColor = Defaults.backgroundColor
        textColor       = Defaults.textColor
        paddingH        = Defaults.paddingH
        paddingV        = Defaults.paddingV
    }
}

// MARK: - Helpers

private extension Int {
    /// Returns nil when the stored value is 0 (i.e. key was never set).
    var nonZero: Int? { self == 0 ? nil : self }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
