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

// MARK: - PreferenceChangeKind

/// Distinguishes preference changes that can be applied to an already-loaded
/// reader document by mutating CSS variables in place (`.cosmetic`) from ones
/// that require a full `reloadHTML()`/`loadSpineItem(...)` (`.structural`).
/// `keyBindings` and `contextMenu` are read by neither `css(paginated:)` nor
/// any reload path, so they intentionally send neither case.
enum PreferenceChangeKind: Equatable {
    case cosmetic
    case structural
}

// MARK: - ReaderPreferences

/// User-configurable reading and library preferences, all UserDefaults-backed.
final class ReaderPreferences: ObservableObject {

    static let shared = ReaderPreferences()

    /// Fired once per cosmetic or structural preference change, in addition
    /// to the blanket `objectWillChange` Combine already provides via
    /// `@Published`. `ReaderViewController.subscribeToPreferences()` sinks on
    /// this instead of `objectWillChange` so cosmetic changes can take the
    /// live CSS-variable path instead of a full reload.
    let preferenceChangeKind = PassthroughSubject<PreferenceChangeKind, Never>()

    // MARK: - Reader appearance

    @Published var fontFamily: String {
        didSet {
            UserDefaults.standard.set(fontFamily, forKey: Keys.fontFamily)
            preferenceChangeKind.send(.cosmetic)
        }
    }
    @Published var fontSize: Int {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: Keys.fontSize)
            preferenceChangeKind.send(.cosmetic)
        }
    }
    @Published var lineHeight: Double {
        didSet {
            UserDefaults.standard.set(lineHeight, forKey: Keys.lineHeight)
            preferenceChangeKind.send(.cosmetic)
        }
    }
    @Published var maxWidth: Int {
        didSet {
            UserDefaults.standard.set(maxWidth, forKey: Keys.maxWidth)
            preferenceChangeKind.send(.cosmetic)
        }
    }
    @Published var readerBackgroundColor: String {
        didSet {
            UserDefaults.standard.set(readerBackgroundColor, forKey: Keys.readerBackgroundColor)
            preferenceChangeKind.send(.cosmetic)
        }
    }
    @Published var readerTextColor: String {
        didSet {
            UserDefaults.standard.set(readerTextColor, forKey: Keys.readerTextColor)
            preferenceChangeKind.send(.cosmetic)
        }
    }
    @Published var paddingH: Int {
        didSet {
            UserDefaults.standard.set(paddingH, forKey: Keys.paddingH)
            preferenceChangeKind.send(.cosmetic)
        }
    }
    @Published var paddingV: Int {
        didSet {
            UserDefaults.standard.set(paddingV, forKey: Keys.paddingV)
            preferenceChangeKind.send(.cosmetic)
        }
    }
    @Published var allowReaderLinkClicks: Bool {
        didSet {
            UserDefaults.standard.set(allowReaderLinkClicks, forKey: Keys.allowReaderLinkClicks)
            preferenceChangeKind.send(.cosmetic)
        }
    }
    /// Structural, not cosmetic: indent removal is now applied by
    /// EPUBParser.stripLeadingIndentWhitespace when the HTML is built (see
    /// sanitise/extractBodyContent), not by a live CSS variable, so toggling
    /// this needs a full reloadHTML() to regenerate the document — a
    /// cosmetic-path CSS swap has nothing left to update.
    @Published var removeParagraphIndents: Bool {
        didSet {
            UserDefaults.standard.set(removeParagraphIndents, forKey: Keys.removeParagraphIndents)
            preferenceChangeKind.send(.structural)
        }
    }
    @Published var colsPerScreen: ColsPerScreen {
        didSet {
            UserDefaults.standard.set(colsPerScreen.rawValue, forKey: Keys.colsPerScreen)
            preferenceChangeKind.send(.structural)
        }
    }
    /// When true (default), opening a book from a `fulltext:` search — or
    /// changing the search text while a book from that search is open —
    /// automatically shows the reader's Find bar and populates it with the
    /// search phrase (see `EmailLibraryViewController.applyFullTextPhraseToLocalFind`).
    /// Some readers find this intrusive (e.g. short/common phrases producing
    /// a wall of highlights, or wanting to read without the find bar taking
    /// up screen space), so it's user-toggleable rather than always-on.
    @Published var autoOpenFindBarForFullTextSearch: Bool {
        didSet {
            UserDefaults.standard.set(autoOpenFindBarForFullTextSearch, forKey: Keys.autoOpenFindBarForFullTextSearch)
        }
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
    /// Hides books whose Calibre description was written by the EPUB-merge plugin
    /// (see `CalibreBook.isDescriptionAnthology`) — i.e. merged/anthology files —
    /// from the library list entirely, separate from the existing series-grouping
    /// exclusion (which only keeps them out of grouped series rows, not out of the
    /// library altogether).
    @Published var hideAnthologyBooks: Bool {
        didSet { UserDefaults.standard.set(hideAnthologyBooks, forKey: Keys.hideAnthologyBooks) }
    }
    /// Hides the non-winning copy of a Calibre duplicate — two rows for the
    /// same AO3 work (same `ao3_work_id`, different `calibre_id`), which
    /// happens when a work gets re-downloaded/re-imported. The more recently
    /// updated copy is kept (falling back to published date, then an
    /// arbitrary but stable tiebreak); the rest are hidden from the library
    /// list, search, series grouping, and feeds. See `DuplicateBookDetector`.
    /// Never silent by default — surfaced as its own toggle next to
    /// `hideNonAO3PublisherBooks` so the user knows books are being hidden.
    @Published var hideDuplicateBooks: Bool {
        didSet { UserDefaults.standard.set(hideDuplicateBooks, forKey: Keys.hideDuplicateBooks) }
    }
    @Published var emailPillsShowCollections: Bool {
        didSet { UserDefaults.standard.set(emailPillsShowCollections, forKey: Keys.emailPillsShowCollections) }
    }

    // MARK: - Feed server
    //
    // feedServerEnableDailyStory / feedServerExcludedCollectionIDs are
    // per-library settings. They're namespaced by `activeFeedNamespace`
    // (the target library's `libraryHash`) so that excluding "Skipped" in
    // one library doesn't silently exclude it in every other library, and
    // switching libraries doesn't drag along the wrong collection-ID set.
    // Call `reloadFeedPrefs(forLibraryHash:)` whenever the active library
    // changes (LibrarySession.open()/close() do this).

    private var activeFeedNamespace: String = ""

    private func feedKey(_ base: String) -> String {
        activeFeedNamespace.isEmpty ? base : "\(base).\(activeFeedNamespace)"
    }

    /// Whether the random daily-story feed (/feed/random-daily.xml) is enabled
    /// for the currently active library. Off by default.
    @Published var feedServerEnableDailyStory: Bool {
        didSet { UserDefaults.standard.set(feedServerEnableDailyStory, forKey: feedKey(Keys.feedServerEnableDailyStory)) }
    }

    /// Collection IDs excluded from the RSS feed server, for the currently
    /// active library. Stored as a comma-delimited string to match the
    /// pattern used by other multi-value prefs.
    @Published var feedServerExcludedCollectionIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(
                feedServerExcludedCollectionIDs.sorted().joined(separator: ","),
                forKey: feedKey(Keys.feedServerExcludedCollectionIDs)
            )
        }
    }

    /// If true, reopening a library whose feed server was running when the
    /// app last quit will automatically restart it (see
    /// `LibrarySession.open()`). Off by default — restarting a server that
    /// broadcasts on the LAN without the user re-confirming each launch
    /// would be a quiet posture change.
    @Published var feedServerAutoRestart: Bool {
        didSet { UserDefaults.standard.set(feedServerAutoRestart, forKey: Keys.feedServerAutoRestart) }
    }

    /// Re-point the per-library feed prefs at a new library and reload their
    /// values from UserDefaults under that library's namespace. Pass nil
    /// when no library is open (falls back to the global/legacy key).
    func reloadFeedPrefs(forLibraryHash hash: String?) {
        activeFeedNamespace = hash ?? ""
        let ud = UserDefaults.standard
        feedServerEnableDailyStory = ud.object(forKey: feedKey(Keys.feedServerEnableDailyStory)) != nil
            ? ud.bool(forKey: feedKey(Keys.feedServerEnableDailyStory))
            : false
        if let storedExcluded = ud.string(forKey: feedKey(Keys.feedServerExcludedCollectionIDs)) {
            feedServerExcludedCollectionIDs = storedExcluded.isEmpty
                ? []
                : Set(storedExcluded.split(separator: ",").map(String.init))
        } else {
            // No stored value for this library yet — apply the default
            // exclusion set and persist it immediately. LocalFeedServer
            // reads this UserDefaults key directly (not through this
            // property), so the default must be written here, not just
            // held in memory, or the server won't see it until the user
            // toggles a collection.
            let defaults = Defaults.feedServerExcludedCollectionIDs
            feedServerExcludedCollectionIDs = defaults
            ud.set(defaults.sorted().joined(separator: ","), forKey: feedKey(Keys.feedServerExcludedCollectionIDs))
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
        didSet {
            UserDefaults.standard.set(defaultReadingMode.rawValue, forKey: Keys.defaultReadingMode)
            preferenceChangeKind.send(.structural)
        }
    }

    // MARK: - Library grouping

    /// Mirrors the exact same `"groupBySeries"` raw `UserDefaults` key that
    /// `LibraryToolbarState` reads/writes directly. This is intentionally the
    /// same storage, not a new key — `LibraryRootView`'s existing
    /// `UserDefaults.didChangeNotification` bridge already keeps the two in
    /// sync for free. Do not migrate this to a new key or add a second sync
    /// mechanism.
    @Published var groupBySeries: Bool {
        didSet { UserDefaults.standard.set(groupBySeries, forKey: Keys.groupBySeries) }
    }

    /// Context menu configuration — not persisted.
    var contextMenu: ContextMenuPreferences = ContextMenuPreferences()

    // MARK: - Keyboard shortcuts

    /// Actions absent from this dictionary are unbound. `showTOCSidebar`
    /// deliberately ships unbound by default (it had no shortcut before
    /// Pass A) rather than being given one now — a mixed "some actions have
    /// no default shortcut" state is fine as long as it's a deliberate
    /// choice, which this comment is recording it as.
    @Published var keyBindings: [RebindableAction: KeyBinding] {
        didSet {
            if let data = try? JSONEncoder().encode(keyBindings) {
                UserDefaults.standard.set(data, forKey: Keys.keyBindings)
            }
        }
    }

    /// A user-named background/text colour pair, saved from the reader's
    /// custom `ColorPicker`s. Deliberately separate from `ReaderTheme` (the
    /// fixed built-in enum) rather than a unification of the two — both
    /// coexist and render side by side in `themePresetRow`.
    struct SavedTheme: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var bg: String   // "#RRGGBB", same hex string shape as readerBackgroundColor
        var fg: String
    }

    /// User-authored data (closer to `CollectionStore` collections than to a
    /// single-value preference), so it's deliberately NOT part of
    /// `isReaderCustomized`/`resetReaderToDefaults()` — there's no "default"
    /// saved-theme list to reset to.
    @Published var savedThemes: [SavedTheme] {
        didSet {
            if let data = try? JSONEncoder().encode(savedThemes) {
                UserDefaults.standard.set(data, forKey: Keys.savedThemes)
            }
        }
    }

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
        static let autoOpenFindBarForFullTextSearch = true
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
        static let hideAnthologyBooks          = true
        static let hideDuplicateBooks          = true
        static let emailPillsShowCollections   = false
        // Default set of system collections excluded from RSS/JSON feed
        // publishing. Applied whenever no per-library exclusion value has
        // ever been stored (see reloadFeedPrefs/init) — these are reading-
        // state or app-generated groupings, not curated collections someone
        // would want broadcast on the local network by default.
        static let feedServerExcludedCollectionIDs: Set<String> = [
            SystemCollectionID.skipped,
            SystemCollectionID.finished,
            SystemCollectionID.inProgress,
            SystemCollectionID.hasAnnotations,
            SystemCollectionID.seriesOrMerged,
        ]
        static let groupBySeries               = false
        static let defaultReadingMode          = ReadingMode.scroll

        // showTOCSidebar is intentionally absent — see keyBindings' doc comment.
        static let keyBindings: [RebindableAction: KeyBinding] = [
            .toggleReadingMode:     KeyBinding(character: "m", modifiers: [.command, .shift]),
            .addAnnotation:         KeyBinding(character: "d", modifiers: [.command]),
            .showAnnotationSidebar: KeyBinding(character: "b", modifiers: [.command]),
            .toggleFindBar:         KeyBinding(character: "f", modifiers: [.command]),
            .findNext:              KeyBinding(character: "g", modifiers: [.command]),
            .findPrevious:          KeyBinding(character: "g", modifiers: [.command, .shift]),
        ]
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
        static let autoOpenFindBarForFullTextSearch = "rp.autoOpenFindBarForFullTextSearch"
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
        static let hideAnthologyBooks          = "rp.hideAnthologyBooks"
        static let hideDuplicateBooks          = "rp.hideDuplicateBooks"
        static let emailPillsShowCollections   = "rp.emailPillsShowCollections"
        static let feedServerEnableDailyStory  = "rp.feedServerEnableDailyStory"
        static let feedServerExcludedCollectionIDs = "rp.feedServerExcludedCollectionIDs"
        static let feedServerAutoRestart       = "rp.feedServerAutoRestart"
        // Deliberately the same literal key `LibraryToolbarState` already uses —
        // not a new namespaced key. See the `groupBySeries` property comment.
        static let groupBySeries               = "groupBySeries"
        static let defaultReadingMode          = "rp.defaultReadingMode"
        static let keyBindings                 = "rp.keyBindings"
        static let savedThemes                 = "rp.savedThemes"
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
        autoOpenFindBarForFullTextSearch = ud.object(forKey: Keys.autoOpenFindBarForFullTextSearch) != nil
            ? ud.bool(forKey: Keys.autoOpenFindBarForFullTextSearch)
            : Defaults.autoOpenFindBarForFullTextSearch

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
        hideAnthologyBooks = ud.object(forKey: Keys.hideAnthologyBooks) != nil
            ? ud.bool(forKey: Keys.hideAnthologyBooks)
            : Defaults.hideAnthologyBooks
        hideDuplicateBooks = ud.object(forKey: Keys.hideDuplicateBooks) != nil
            ? ud.bool(forKey: Keys.hideDuplicateBooks)
            : Defaults.hideDuplicateBooks
        emailPillsShowCollections = ud.object(forKey: Keys.emailPillsShowCollections) != nil
            ? ud.bool(forKey: Keys.emailPillsShowCollections)
            : Defaults.emailPillsShowCollections

        // Loaded unnamespaced at init (no library open yet); LibrarySession calls
        // reloadFeedPrefs(forLibraryHash:) once a library is opened or closed.
        feedServerEnableDailyStory = ud.object(forKey: Keys.feedServerEnableDailyStory) != nil
            ? ud.bool(forKey: Keys.feedServerEnableDailyStory)
            : false
        if let storedExcluded = ud.string(forKey: Keys.feedServerExcludedCollectionIDs) {
            feedServerExcludedCollectionIDs = storedExcluded.isEmpty
                ? []
                : Set(storedExcluded.split(separator: ",").map(String.init))
        } else {
            let defaults = Defaults.feedServerExcludedCollectionIDs
            feedServerExcludedCollectionIDs = defaults
            ud.set(defaults.sorted().joined(separator: ","), forKey: Keys.feedServerExcludedCollectionIDs)
        }
        feedServerAutoRestart = ud.object(forKey: Keys.feedServerAutoRestart) != nil
            ? ud.bool(forKey: Keys.feedServerAutoRestart)
            : false

        groupBySeries = ud.object(forKey: Keys.groupBySeries) != nil
            ? ud.bool(forKey: Keys.groupBySeries)
            : Defaults.groupBySeries

        let rawMode = ud.string(forKey: Keys.defaultReadingMode) ?? Defaults.defaultReadingMode.rawValue
        defaultReadingMode = ReadingMode(rawValue: rawMode) ?? .scroll

        if let data = ud.data(forKey: Keys.keyBindings),
           let decoded = try? JSONDecoder().decode([RebindableAction: KeyBinding].self, from: data) {
            keyBindings = decoded
        } else {
            keyBindings = Defaults.keyBindings
        }

        if let data = ud.data(forKey: Keys.savedThemes),
           let decoded = try? JSONDecoder().decode([SavedTheme].self, from: data) {
            savedThemes = decoded
        } else {
            savedThemes = []
        }
    }

    // MARK: - CSS (reader only)

    var css: String {
        css(paginated: false)
    }

    /// Emits just the *contents* of the `:root { ... }` block (no braces) for
    /// the cosmetic properties `css(paginated:)` drives via CSS variables:
    /// fontFamily, fontSize, lineHeight, readerBackgroundColor,
    /// readerTextColor, paddingH, paddingV, maxWidth, allowReaderLinkClicks.
    /// `ReaderViewController.applyCosmeticCSSUpdate()` writes this into a
    /// standalone `<style id="ambrosia-vars">` element without needing the
    /// rest of the stylesheet reinjected.
    /// (removeParagraphIndents is deliberately not one of these — see its
    /// own doc comment above. It used to be expressed here as a
    /// `--ambrosia-paragraph-indent` variable feeding a `text-indent`
    /// override, but publisher CSS is stripped unconditionally before this
    /// stylesheet is ever injected, so there was never any publisher
    /// `text-indent` left for that override to cancel out — dead code,
    /// removed. The actual fix is EPUBParser.stripLeadingIndentWhitespace.)
    var cssVariableDeclarations: String {
        """
        --ambrosia-font-family: \(fontFamily);
        --ambrosia-font-size: \(fontSize)px;
        --ambrosia-line-height: \(lineHeight);
        --ambrosia-bg: \(readerBackgroundColor);
        --ambrosia-text: \(readerTextColor);
        --ambrosia-padding-h: \(paddingH)px;
        --ambrosia-padding-v: \(paddingV)px;
        --ambrosia-max-width: \(maxWidth)px;
        --ambrosia-link-pointer-events: \(allowReaderLinkClicks ? "auto" : "none");
        """
    }

    /// - Parameter paginated: When true, omits body padding — paginated mode
    ///   applies its own page-margin padding via `paginatedColumnCSS`'s body
    ///   rule (with `!important`), and would otherwise fight with this rule
    ///   for the same property. This is a reading-mode concern, not a
    ///   live-updatable preference, so it stays a parameter here rather than
    ///   folding into `cssVariableDeclarations` (mode switches are already a
    ///   full reload per Invariant 7) — the `bodyPadding` literal below is
    ///   substituted directly into the rule rather than driven by a CSS
    ///   variable, since it never needs to change without a full reload.
    func css(paginated: Bool) -> String {
        // Body padding is intentionally NOT one of the CSS variables in
        // `cssVariableDeclarations`: whether it's 0 or paddingV/paddingH
        // depends on reading mode, not on any live-updatable preference, and
        // reading-mode switches already go through a full reload (Invariant
        // 7). Substituting it directly here keeps that reload path
        // unchanged; the cosmetic live-update path never touches this rule.
        let bodyPadding = paginated ? "0" : "var(--ambrosia-padding-v) var(--ambrosia-padding-h)"
        return """
        /* === Ambrosia user preferences === */
        :root {
            \(cssVariableDeclarations)
        }
        html, body {
            background-color: var(--ambrosia-bg);
            color: var(--ambrosia-text);
        }
        body {
            font-family: var(--ambrosia-font-family);
            font-size: var(--ambrosia-font-size);
            line-height: var(--ambrosia-line-height);
            max-width: var(--ambrosia-max-width);
            margin: 0 auto;
            padding: \(bodyPadding);
            -webkit-font-smoothing: antialiased;
            word-wrap: break-word;
        }
        img  { max-width: 100%; height: auto; display: block; margin: 1em auto; }
        p    { margin-bottom: 0.8em; }
        a    { color: inherit; text-decoration: underline; pointer-events: var(--ambrosia-link-pointer-events); cursor: pointer; }
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
        """
    }

    // MARK: - Paginated column CSS
    //
    // Column layout CSS injected into the HTML string BEFORE loadHTMLString is
    // called (see ReaderViewController.loadSpineItem), never via evaluateJavaScript
    // after load. This is what eliminates the scroll-mode flash and the race with
    // BaseStyles.css. See build plan invariant 2.
    //
    // Columns are placed on :root (`html`), not `body`: `html` is simultaneously
    // the column container and the scroll container, so window.scrollX maps
    // directly to column position with no overflow propagation through ancestors.
    // `body` is a plain child with `max-width: none`, which defeats the maxWidth
    // cap from `css(paginated:)` that would otherwise clip columns to a narrow
    // centred strip. See build plan invariant 3.
    func paginatedColumnCSS(viewportWidth: CGFloat, viewportHeight: CGFloat) -> String {
        let colsPerScreen = self.colsPerScreen.rawValue
        let marginH = CGFloat(paddingH)     // page left/right margin
        let marginV = CGFloat(paddingV)     // top/bottom padding inside body

        let vw = Int(viewportWidth.rounded())
        let vh = Int(viewportHeight.rounded())
        let marginHInt = Int(marginH.rounded())

        // colWidth/colGap used to be computed by dividing `vw` (the full
        // viewport) directly. That was the actual bug behind the "page 2's
        // left margin looks 2x" symptom: the horizontal margin was applied
        // as body's own padding-left/right, but body is the block that gets
        // FRAGMENTED into columns, and a fragmented block's own padding at
        // internal column breaks is exactly the kind of thing WebKit doesn't
        // handle the way naive CSS-fragmentation-spec reading suggests —
        // empirically it does not cleanly apply body's padding once at the
        // true start/end of the whole flow; interior column boundaries pick
        // up extra inset from it. Top/bottom padding didn't show this because
        // it's orthogonal to the fragmentation axis (every column shares the
        // same vertical span within the row), which is exactly why the
        // vertical margins were fine while only the horizontal ones drifted.
        //
        // Fix: move the horizontal margin OFF body entirely and onto `html`
        // (the multicol container) instead. Container-level padding is
        // unambiguous — it only ever shows at the true first column's left
        // edge and the true last column's right edge, never at interior
        // column breaks. All interior spacing then comes purely from
        // column-gap (blank space, no box involved, so nothing to be
        // ambiguous about). Because html's own padding reduces its CONTENT
        // box once (not per screen), colWidth/colGap must divide
        // `vw - 2*marginH` (html's content box), not `vw` directly — dividing
        // `vw` itself here would double-subtract the margin.
        let availableWidth = vw - 2 * marginHInt

        var colGap = max(1, Int((marginH * 2).rounded()))
        let colWidth: Int
        if colsPerScreen <= 1 {
            colWidth = availableWidth
        } else {
            let raw = availableWidth + colGap
            let overhang = raw % colsPerScreen
            if overhang != 0 { colGap += colsPerScreen - overhang }
            colWidth = (availableWidth + colGap) / colsPerScreen - colGap
        }

        // maxWidth in single-column mode: cap and center the rendered text
        // within the (unchanged) column box via body's own max-width + auto
        // margin, rather than touching html's column-width/padding. `html`
        // remains the column container and keeps exactly the geometry it had
        // before (colWidth == availableWidth, same padding), so the
        // scrollWidth/colAndGap math in ambrosiaColumnCount/ambrosiaCurrentColumn
        // (Task 1) is completely unaffected — this only changes how content
        // renders inside each already-correctly-sized column. Multi-column
        // screens are never capped: the point there is filling the screen
        // with multiple reading columns, not narrow centered text.
        let capSingleColumn = colsPerScreen <= 1 && maxWidth < availableWidth
        let bodyWidthCSS = capSingleColumn
            ? "max-width: \(maxWidth)px !important; margin: 0 auto !important;"
            : "max-width: none !important; margin: 0 !important;"

        #if DEBUG
        print("[Pagination] requested: vw=\(vw) vh=\(vh) marginH=\(marginHInt) availableWidth=\(availableWidth) colsPerScreen=\(colsPerScreen) colWidth=\(colWidth) colGap=\(colGap) colTotal=\(colWidth * colsPerScreen + colGap * (colsPerScreen - 1)) pitch=\(colWidth + colGap) capSingleColumn=\(capSingleColumn) maxWidth=\(maxWidth)")
        #endif

        return """
        /* === Ambrosia paginated layout === */
        html {
            /* :root is the column container and the scroll container.
               Horizontal margin lives here (container-level padding — applies
               once, at the true first/last column edge only). */
            width: \(vw)px !important;
            height: \(vh)px !important;
            max-width: \(vw)px !important;
            max-height: \(vh)px !important;
            min-width: \(vw)px !important;
            min-height: \(vh)px !important;
            padding-left: \(marginHInt)px !important;
            padding-right: \(marginHInt)px !important;
            padding-top: \(Int(marginV))px !important;
            padding-bottom: \(Int(marginV))px !important;
            column-width: \(colWidth)px !important;
            column-gap: \(colGap)px !important;
            column-fill: auto !important;
            overflow-x: scroll !important;
            overflow-y: hidden !important;
            scrollbar-width: none !important;
            box-sizing: border-box !important;
        }
        html::-webkit-scrollbar { display: none !important; }
        body {
            /* body is a normal child; it must NOT be the column container,
               and must NOT carry padding on either axis — see comments above.
               Horizontal margin comes from column-gap + html's padding;
               vertical margin comes from html's padding-top/bottom, which
               (unlike body's) is not subject to box-decoration-break:slice
               dropping it from interior pages, since html itself is the
               container, not a fragmented box. Its own max-width/margin
               (bodyWidthCSS) only crops/centers the rendered text within
               each already-sized column; it does not change column geometry. */
            width: 100% !important;
            \(bodyWidthCSS)
            height: auto !important;
            overflow: visible !important;
            box-sizing: border-box !important;
        }
        /* Prevent the first element from creating a blank leading column */
        body > *:first-child,
        body > div:first-child > *:first-child {
            break-before: avoid !important;
        }
        /* AO3 preface metadata (tag lists, "Additional Tags" runs, dl/dd blocks,
           and tables) can contain long comma-separated inline content. CSS
           multi-column columns are only as wide as column-width *requests* —
           an unbreakable run of content wider than that forces the browser to
           widen just that one column to fit it, which throws off every column
           boundary after it (JS assumes a uniform pitch). Force wrapping
           everywhere so no element can be wider than its column. */
        * {
            max-width: 100% !important;
            overflow-wrap: break-word !important;
            word-break: break-word !important;
        }
        *:not(pre):not(code) {
            white-space: normal !important;
        }
        table {
            table-layout: fixed !important;
            width: 100% !important;
        }
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

    /// Mirrors CotEditor's `isRestorable` pattern (Finding 8): true only when at
    /// least one reader setting differs from its default, so the reset button
    /// is inert rather than an always-live destructive action.
    var isReaderCustomized: Bool {
        fontFamily != Defaults.fontFamily
            || fontSize != Defaults.fontSize
            || lineHeight != Defaults.lineHeight
            || maxWidth != Defaults.maxWidth
            || readerBackgroundColor != Defaults.readerBackgroundColor
            || readerTextColor != Defaults.readerTextColor
            || paddingH != Defaults.paddingH
            || paddingV != Defaults.paddingV
            || allowReaderLinkClicks != Defaults.allowReaderLinkClicks
            || removeParagraphIndents != Defaults.removeParagraphIndents
            || colsPerScreen != Defaults.colsPerScreen
            || autoOpenFindBarForFullTextSearch != Defaults.autoOpenFindBarForFullTextSearch
            || defaultReadingMode != Defaults.defaultReadingMode
            || keyBindings != Defaults.keyBindings
    }

    var isLibraryCustomized: Bool {
        libraryColorMode != Defaults.libraryColorMode
            || libraryAppearanceMode != Defaults.libraryAppearanceMode
            || libraryLightBackgroundColor != Defaults.libraryLightBackgroundColor
            || libraryDarkBackgroundColor != Defaults.libraryDarkBackgroundColor
            || libraryLightTextColor != Defaults.libraryLightTextColor
            || libraryDarkTextColor != Defaults.libraryDarkTextColor
            || showSkippedCollection != Defaults.showSkippedCollection
            || hideFanworksTagPill != Defaults.hideFanworksTagPill
            || hideNonAO3PublisherBooks != Defaults.hideNonAO3PublisherBooks
            || hideAnthologyBooks != Defaults.hideAnthologyBooks
            || hideDuplicateBooks != Defaults.hideDuplicateBooks
            || emailPillsShowCollections != Defaults.emailPillsShowCollections
            || groupBySeries != Defaults.groupBySeries
    }

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
        autoOpenFindBarForFullTextSearch = Defaults.autoOpenFindBarForFullTextSearch
        defaultReadingMode    = Defaults.defaultReadingMode
        keyBindings           = Defaults.keyBindings
    }

    /// Resets only `keyBindings`, independent of the rest of the Reader tab's
    /// "Restore Defaults" (which would also reset fonts, colors, etc.) — the
    /// Shortcuts tab has its own scoped restore button.
    func resetReaderShortcutsToDefaults() {
        keyBindings = Defaults.keyBindings
    }

    /// Exposed so `ShortcutsTab` can disable its own restore button without
    /// reaching into the private `Defaults` enum.
    static var defaultKeyBindingsForReset: [RebindableAction: KeyBinding] {
        Defaults.keyBindings
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
        hideAnthologyBooks          = Defaults.hideAnthologyBooks
        hideDuplicateBooks          = Defaults.hideDuplicateBooks
        emailPillsShowCollections   = Defaults.emailPillsShowCollections
        groupBySeries               = Defaults.groupBySeries
    }
}

// MARK: - Helpers

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
