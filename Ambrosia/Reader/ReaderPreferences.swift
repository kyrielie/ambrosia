import Foundation
import AppKit
import Combine
import SwiftUI

// MARK: - LibraryColorMode

/// Controls how the library background and text colours are determined.
enum LibraryColorMode: String, CaseIterable, Identifiable {
    case systemDefault = "systemDefault"  // NSColor.windowBackgroundColor (default)
    case accentColor   = "accentColor"    // subtle system accent colour tint
    case custom        = "custom"         // user picks separate light/dark colour pairs

    var id: String { rawValue }
    var label: String {
        switch self {
        case .systemDefault: return "System Default"
        case .accentColor:   return "Use Accent Color"
        case .custom:        return "Custom"
        }
    }
}

// MARK: - LibraryAppearanceMode

/// Whether the library follows the system appearance or is locked to light/dark.
enum LibraryAppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Follow System"
        case .light:  return "Always Light"
        case .dark:   return "Always Dark"
        }
    }
}

// MARK: - LibraryColorScheme

/// The colour pair applied to the library background and text.
struct LibraryColorScheme: Equatable {
    var backgroundColor: String   // "#RRGGBB"
    var textColor: String
}

// MARK: - ReaderPreferences

/// User-configurable reading and library preferences, all UserDefaults-backed.
final class ReaderPreferences: ObservableObject {

    static let shared = ReaderPreferences()

    // MARK: - Reader appearance

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
    @Published var readerBackgroundColor: String {
        didSet { UserDefaults.standard.set(readerBackgroundColor, forKey: Keys.readerBackgroundColor) }
    }
    @Published var readerTextColor: String {
        didSet { UserDefaults.standard.set(readerTextColor, forKey: Keys.readerTextColor) }
    }
    @Published var paddingH: Int {
        didSet { UserDefaults.standard.set(paddingH, forKey: Keys.paddingH) }
    }
    @Published var paddingV: Int {
        didSet { UserDefaults.standard.set(paddingV, forKey: Keys.paddingV) }
    }
    @Published var allowReaderLinkClicks: Bool {
        didSet { UserDefaults.standard.set(allowReaderLinkClicks, forKey: Keys.allowReaderLinkClicks) }
    }
    @Published var removeParagraphIndents: Bool {
        didSet { UserDefaults.standard.set(removeParagraphIndents, forKey: Keys.removeParagraphIndents) }
    }
    @Published var colsPerScreen: ColsPerScreen {
        didSet { UserDefaults.standard.set(colsPerScreen.rawValue, forKey: Keys.colsPerScreen) }
    }

    // MARK: - Library appearance — colour mode

    @Published var libraryColorMode: LibraryColorMode {
        didSet { UserDefaults.standard.set(libraryColorMode.rawValue, forKey: Keys.libraryColorMode) }
    }

    @Published var libraryAppearanceMode: LibraryAppearanceMode {
        didSet { UserDefaults.standard.set(libraryAppearanceMode.rawValue, forKey: Keys.libraryAppearanceMode) }
    }

    // Custom light/dark colour pairs (used when libraryColorMode == .custom)
    @Published var libraryLightBackgroundColor: String {
        didSet { UserDefaults.standard.set(libraryLightBackgroundColor, forKey: Keys.libraryLightBG) }
    }
    @Published var libraryDarkBackgroundColor: String {
        didSet { UserDefaults.standard.set(libraryDarkBackgroundColor, forKey: Keys.libraryDarkBG) }
    }
    @Published var libraryLightTextColor: String {
        didSet { UserDefaults.standard.set(libraryLightTextColor, forKey: Keys.libraryLightText) }
    }
    @Published var libraryDarkTextColor: String {
        didSet { UserDefaults.standard.set(libraryDarkTextColor, forKey: Keys.libraryDarkText) }
    }
    @Published var showSkippedCollection: Bool {
        didSet { UserDefaults.standard.set(showSkippedCollection, forKey: Keys.showSkippedCollection) }
    }
    @Published var hideFanworksTagPill: Bool {
        didSet { UserDefaults.standard.set(hideFanworksTagPill, forKey: Keys.hideFanworksTagPill) }
    }
    @Published var correctCalibreAmpEntities: Bool {
        didSet { UserDefaults.standard.set(correctCalibreAmpEntities, forKey: Keys.correctCalibreAmpEntities) }
    }
    @Published var hideNonAO3PublisherBooks: Bool {
        didSet { UserDefaults.standard.set(hideNonAO3PublisherBooks, forKey: Keys.hideNonAO3PublisherBooks) }
    }
    @Published var emailPillsShowCollections: Bool {
        didSet { UserDefaults.standard.set(emailPillsShowCollections, forKey: Keys.emailPillsShowCollections) }
    }

    // MARK: - Feed server

    /// Whether the random daily-story feed (/feed/random-daily.xml) is enabled.
    /// Off by default, consistent with the architecture doc's "off by default" posture.
    @Published var feedServerEnableDailyStory: Bool {
        didSet { UserDefaults.standard.set(feedServerEnableDailyStory, forKey: Keys.feedServerEnableDailyStory) }
    }

    /// Collection IDs excluded from the RSS feed server. Stored as a
    /// comma-delimited string to match the pattern used by other multi-value prefs.
    @Published var feedServerExcludedCollectionIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(
                feedServerExcludedCollectionIDs.sorted().joined(separator: ","),
                forKey: Keys.feedServerExcludedCollectionIDs
            )
        }
    }

    // MARK: - Derived: resolved library colour for current appearance

    /// Returns the effective library background hex string given whether the
    /// current effective appearance is dark.
    func resolvedLibraryBackgroundColor(isDark: Bool) -> String {
        switch libraryColorMode {
        case .systemDefault:
            // Return a sentinel that BookGridItem maps to NSColor.windowBackgroundColor
            return "__system__"
        case .accentColor:
            return "__accent__"
        case .custom:
            return isDark ? libraryDarkBackgroundColor : libraryLightBackgroundColor
        }
    }

    func resolvedLibraryTextColor(isDark: Bool) -> String {
        switch libraryColorMode {
        case .systemDefault, .accentColor:
            return "__system_label__"
        case .custom:
            return isDark ? libraryDarkTextColor : libraryLightTextColor
        }
    }

    var resolvedLibraryNSAppearance: NSAppearance? {
        switch libraryAppearanceMode {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    var resolvedLibraryColorScheme: ColorScheme? {
        switch libraryAppearanceMode {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    // MARK: - Reading mode

    @Published var defaultReadingMode: ReadingMode {
        didSet { UserDefaults.standard.set(defaultReadingMode.rawValue,
                                           forKey: Keys.defaultReadingMode) }
    }

    // MARK: - Window size

    @Published var useScreenFraction: Bool {
        didSet { UserDefaults.standard.set(useScreenFraction, forKey: Keys.useScreenFraction) }
    }
    @Published var defaultWindowWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(defaultWindowWidth), forKey: Keys.defaultWindowWidth) }
    }
    @Published var defaultWindowHeight: CGFloat {
        didSet { UserDefaults.standard.set(Double(defaultWindowHeight), forKey: Keys.defaultWindowHeight) }
    }

    /// Context menu configuration — not persisted.
    var contextMenu: ContextMenuPreferences = ContextMenuPreferences()

    // MARK: - Defaults

    private enum Defaults {
        static let fontFamily                  = "\"Iowan Old Style\", Georgia, serif"
        static let fontSize                    = 18
        static let lineHeight                  = 1.7
        static let maxWidth                    = 680
        static let readerBackgroundColor       = "#FFFDF6"
        static let readerTextColor             = "#1A1A1A"
        static let paddingH                    = 24
        static let paddingV                    = 32
        static let allowReaderLinkClicks       = false
        static let removeParagraphIndents      = false
        static let colsPerScreen               = ColsPerScreen.one
        static let libraryColorMode            = LibraryColorMode.systemDefault
        static let libraryAppearanceMode       = LibraryAppearanceMode.system
        static let libraryLightBackgroundColor = "#FFFFFF"
        static let libraryDarkBackgroundColor  = "#1E1E1E"
        static let libraryLightTextColor       = "#1A1A1A"
        static let libraryDarkTextColor        = "#EBEBF0"
        static let showSkippedCollection       = false
        static let hideFanworksTagPill         = true
        static let correctCalibreAmpEntities   = true
        static let hideNonAO3PublisherBooks    = false
        static let emailPillsShowCollections   = false
        static let useScreenFraction           = true
        static let defaultWindowWidth          = CGFloat(960)
        static let defaultWindowHeight         = CGFloat(1080)
        static let defaultReadingMode          = ReadingMode.scroll
    }

    private enum Keys {
        static let fontFamily                  = "rp.fontFamily"
        static let fontSize                    = "rp.fontSize"
        static let lineHeight                  = "rp.lineHeight"
        static let maxWidth                    = "rp.maxWidth"
        static let readerBackgroundColor       = "rp.readerBackgroundColor"
        static let readerTextColor             = "rp.readerTextColor"
        static let paddingH                    = "rp.paddingH"
        static let paddingV                    = "rp.paddingV"
        static let allowReaderLinkClicks       = "rp.allowReaderLinkClicks"
        static let removeParagraphIndents      = "rp.removeParagraphIndents"
        static let colsPerScreen               = "rp.colsPerScreen"
        static let libraryColorMode            = "rp.libraryColorMode"
        static let libraryAppearanceMode       = "rp.libraryAppearanceMode"
        static let libraryLightBG              = "rp.libraryLightBG"
        static let libraryDarkBG               = "rp.libraryDarkBG"
        static let libraryLightText            = "rp.libraryLightText"
        static let libraryDarkText             = "rp.libraryDarkText"
        static let showSkippedCollection       = "rp.showSkippedCollection"
        static let hideFanworksTagPill         = "rp.hideFanworksTagPill"
        static let correctCalibreAmpEntities   = "rp.correctCalibreAmpEntities"
        static let hideNonAO3PublisherBooks    = "rp.hideNonAO3PublisherBooks"
        static let emailPillsShowCollections   = "rp.emailPillsShowCollections"
        static let feedServerEnableDailyStory  = "rp.feedServerEnableDailyStory"
        static let feedServerExcludedCollectionIDs = "rp.feedServerExcludedCollectionIDs"
        static let useScreenFraction           = "pref.useScreenFraction"
        static let defaultWindowWidth          = "pref.windowWidth"
        static let defaultWindowHeight         = "pref.windowHeight"
        static let defaultReadingMode          = "rp.defaultReadingMode"
    }

    private init() {
        let ud = UserDefaults.standard
        fontFamily   = ud.string(forKey: Keys.fontFamily)  ?? Defaults.fontFamily
        fontSize     = ud.integer(forKey: Keys.fontSize).nonZero  ?? Defaults.fontSize
        lineHeight   = ud.double(forKey: Keys.lineHeight).nonZero  ?? Defaults.lineHeight
        maxWidth     = ud.integer(forKey: Keys.maxWidth).nonZero   ?? Defaults.maxWidth
        paddingH     = ud.integer(forKey: Keys.paddingH).nonZero   ?? Defaults.paddingH
        paddingV     = ud.integer(forKey: Keys.paddingV).nonZero   ?? Defaults.paddingV
        allowReaderLinkClicks = ud.object(forKey: Keys.allowReaderLinkClicks) != nil
            ? ud.bool(forKey: Keys.allowReaderLinkClicks)
            : Defaults.allowReaderLinkClicks
        removeParagraphIndents = ud.object(forKey: Keys.removeParagraphIndents) != nil
            ? ud.bool(forKey: Keys.removeParagraphIndents)
            : Defaults.removeParagraphIndents
        let rawCols = ud.integer(forKey: Keys.colsPerScreen).nonZero
        colsPerScreen = rawCols.flatMap(ColsPerScreen.init(rawValue:)) ?? Defaults.colsPerScreen

        // Migrate old "rp.backgroundColor" key if present
        let legacyBG = ud.string(forKey: "rp.backgroundColor")
        readerBackgroundColor = ud.string(forKey: Keys.readerBackgroundColor)
            ?? legacyBG
            ?? Defaults.readerBackgroundColor
        readerTextColor = ud.string(forKey: Keys.readerTextColor)
            ?? (legacyBG != nil ? Defaults.readerTextColor : nil)
            ?? ud.string(forKey: "rp.textColor")
            ?? Defaults.readerTextColor

        // Library colour mode
        let rawColorMode = ud.string(forKey: Keys.libraryColorMode) ?? Defaults.libraryColorMode.rawValue
        libraryColorMode = LibraryColorMode(rawValue: rawColorMode) ?? Defaults.libraryColorMode

        let rawAppearance = ud.string(forKey: Keys.libraryAppearanceMode) ?? Defaults.libraryAppearanceMode.rawValue
        libraryAppearanceMode = LibraryAppearanceMode(rawValue: rawAppearance) ?? Defaults.libraryAppearanceMode

        // Migrate old flat libraryBackgroundColor / libraryTextColor to new light keys
        let legacyLibBG   = ud.string(forKey: "rp.libraryBackgroundColor")
        let legacyLibText = ud.string(forKey: "rp.libraryTextColor")
        libraryLightBackgroundColor = ud.string(forKey: Keys.libraryLightBG)
            ?? legacyLibBG ?? Defaults.libraryLightBackgroundColor
        libraryLightTextColor       = ud.string(forKey: Keys.libraryLightText)
            ?? legacyLibText ?? Defaults.libraryLightTextColor
        libraryDarkBackgroundColor  = ud.string(forKey: Keys.libraryDarkBG)
            ?? Defaults.libraryDarkBackgroundColor
        libraryDarkTextColor        = ud.string(forKey: Keys.libraryDarkText)
            ?? Defaults.libraryDarkTextColor
        showSkippedCollection = ud.object(forKey: Keys.showSkippedCollection) != nil
            ? ud.bool(forKey: Keys.showSkippedCollection)
            : Defaults.showSkippedCollection
        hideFanworksTagPill = ud.object(forKey: Keys.hideFanworksTagPill) != nil
            ? ud.bool(forKey: Keys.hideFanworksTagPill)
            : Defaults.hideFanworksTagPill
        correctCalibreAmpEntities = ud.object(forKey: Keys.correctCalibreAmpEntities) != nil
            ? ud.bool(forKey: Keys.correctCalibreAmpEntities)
            : Defaults.correctCalibreAmpEntities
        hideNonAO3PublisherBooks = ud.object(forKey: Keys.hideNonAO3PublisherBooks) != nil
            ? ud.bool(forKey: Keys.hideNonAO3PublisherBooks)
            : Defaults.hideNonAO3PublisherBooks
        emailPillsShowCollections = ud.object(forKey: Keys.emailPillsShowCollections) != nil
            ? ud.bool(forKey: Keys.emailPillsShowCollections)
            : Defaults.emailPillsShowCollections

        feedServerEnableDailyStory = ud.object(forKey: Keys.feedServerEnableDailyStory) != nil
            ? ud.bool(forKey: Keys.feedServerEnableDailyStory)
            : false
        let excludedRaw = ud.string(forKey: Keys.feedServerExcludedCollectionIDs) ?? ""
        feedServerExcludedCollectionIDs = excludedRaw.isEmpty
            ? []
            : Set(excludedRaw.split(separator: ",").map(String.init))

        if ud.object(forKey: Keys.useScreenFraction) != nil {
            useScreenFraction = ud.bool(forKey: Keys.useScreenFraction)
        } else {
            useScreenFraction = Defaults.useScreenFraction
        }
        let sw = ud.double(forKey: Keys.defaultWindowWidth)
        let sh = ud.double(forKey: Keys.defaultWindowHeight)
        defaultWindowWidth  = sw > 0 ? CGFloat(sw) : Defaults.defaultWindowWidth
        defaultWindowHeight = sh > 0 ? CGFloat(sh) : Defaults.defaultWindowHeight

        let rawMode = ud.string(forKey: Keys.defaultReadingMode) ?? Defaults.defaultReadingMode.rawValue
        defaultReadingMode = ReadingMode(rawValue: rawMode) ?? .scroll
    }

    // MARK: - CSS (reader only)

    var css: String {
        css(paginated: false)
    }

    /// - Parameter paginated: When true, omits body padding — paginated mode
    ///   applies its own page-margin padding via PaginationJS's ambrosiaSetup,
    ///   and would otherwise fight with this rule for the same property.
    func css(paginated: Bool) -> String {
        let linkPointerEvents = allowReaderLinkClicks ? "auto" : "none"
        let bodyPadding = paginated ? "0" : "\(paddingV)px \(paddingH)px"
        let paragraphIndentCSS = removeParagraphIndents
            ? """
        p, div, li {
            text-indent: 0 !important;
        }
        p::first-line, div::first-line, li::first-line {
            text-indent: 0 !important;
        }
        """
            : ""
        return """
        /* === Ambrosia user preferences === */
        html, body {
            background-color: \(readerBackgroundColor);
            color: \(readerTextColor);
        }
        body {
            font-family: \(fontFamily);
            font-size: \(fontSize)px;
            line-height: \(lineHeight);
            max-width: \(maxWidth)px;
            margin: 0 auto;
            padding: \(bodyPadding);
            -webkit-font-smoothing: antialiased;
            word-wrap: break-word;
        }
        img  { max-width: 100%; height: auto; display: block; margin: 1em auto; }
        p    { margin-bottom: 0.8em; }
        a    { color: inherit; text-decoration: underline; pointer-events: \(linkPointerEvents); cursor: pointer; }
        em, i { font-style: italic; }
        strong, b { font-weight: bold; }
        h1, h2, h3, h4, h5, h6 { font-weight: bold; margin: 1em 0 0.5em; line-height: 1.2; }
        h1 { font-size: 1.6em; } h2 { font-size: 1.4em; } h3 { font-size: 1.2em; }
        table { border-collapse: collapse; width: 100%; margin: 1em 0; }
        td, th { border: 1px solid currentColor; padding: 0.4em 0.6em; }
        hr { border: none; border-top: 1px solid currentColor; opacity: 0.3; margin: 1.5em 0; }
        code, pre { font-family: "SF Mono", Menlo, monospace; font-size: 0.9em; }
        pre { overflow-x: auto; padding: 1em; background: rgba(128,128,128,0.1); border-radius: 4px; }
        div, section, article { float: none !important; position: static !important; }
        nav[epub\\:type="toc"], nav[epub\\:type="landmarks"] { display: none; }
        \(paragraphIndentCSS)
        """
    }

    // MARK: - Font presets

    struct FontPreset: Identifiable {
        let id: String
        let label: String
        let cssStack: String
    }

    static let fontPresets: [FontPreset] = [
        FontPreset(id: "iowan",       label: "Iowan Old Style",  cssStack: "\"Iowan Old Style\", Georgia, serif"),
        FontPreset(id: "newyork",     label: "New York",          cssStack: "\"New York\", Georgia, serif"),
        FontPreset(id: "georgia",     label: "Georgia",           cssStack: "Georgia, serif"),
        FontPreset(id: "palatino",    label: "Palatino",          cssStack: "Palatino, \"Palatino Linotype\", serif"),
        FontPreset(id: "times",       label: "Times New Roman",   cssStack: "\"Times New Roman\", Times, serif"),
        FontPreset(id: "charter",     label: "Charter",           cssStack: "Charter, Georgia, serif"),
        FontPreset(id: "system",      label: "System (SF Pro)",   cssStack: "-apple-system, sans-serif"),
        FontPreset(id: "avenir",      label: "Avenir Next",       cssStack: "\"Avenir Next\", Avenir, sans-serif"),
        FontPreset(id: "seravek",     label: "Seravek",           cssStack: "Seravek, \"Gill Sans\", sans-serif"),
        FontPreset(id: "courier",     label: "Courier New",       cssStack: "\"Courier New\", Courier, monospace"),
    ]

    /// Returns the display label for the currently selected font family.
    var displayFontFamily: String {
        if let match = Self.fontPresets.first(where: { $0.cssStack == fontFamily }) {
            return match.label
        }
        return fontFamily
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            ?? fontFamily
    }

    // MARK: - Reset

    func resetReaderToDefaults() {
        fontFamily            = Defaults.fontFamily
        fontSize              = Defaults.fontSize
        lineHeight            = Defaults.lineHeight
        maxWidth              = Defaults.maxWidth
        readerBackgroundColor = Defaults.readerBackgroundColor
        readerTextColor       = Defaults.readerTextColor
        paddingH              = Defaults.paddingH
        paddingV              = Defaults.paddingV
        allowReaderLinkClicks = Defaults.allowReaderLinkClicks
        removeParagraphIndents = Defaults.removeParagraphIndents
        colsPerScreen          = Defaults.colsPerScreen
        defaultReadingMode    = Defaults.defaultReadingMode
    }

    func resetLibraryToDefaults() {
        libraryColorMode            = Defaults.libraryColorMode
        libraryAppearanceMode       = Defaults.libraryAppearanceMode
        libraryLightBackgroundColor = Defaults.libraryLightBackgroundColor
        libraryDarkBackgroundColor  = Defaults.libraryDarkBackgroundColor
        libraryLightTextColor       = Defaults.libraryLightTextColor
        libraryDarkTextColor        = Defaults.libraryDarkTextColor
        showSkippedCollection       = Defaults.showSkippedCollection
        hideFanworksTagPill         = Defaults.hideFanworksTagPill
        hideNonAO3PublisherBooks    = Defaults.hideNonAO3PublisherBooks
        emailPillsShowCollections   = Defaults.emailPillsShowCollections
    }
}

// MARK: - Helpers

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
