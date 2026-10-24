import AppKit
import Foundation

public struct ThemeColorSet: Codable, Equatable {
    public var background: String
    public var text: String
    public var link: String
    public var prefaceBorder: String
    public var prefaceBackground: String
    public var prefaceLabel: String

    public init(
        background: String,
        text: String,
        link: String,
        prefaceBorder: String,
        prefaceBackground: String,
        prefaceLabel: String
    ) {
        self.background = background
        self.text = text
        self.link = link
        self.prefaceBorder = prefaceBorder
        self.prefaceBackground = prefaceBackground
        self.prefaceLabel = prefaceLabel
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum ReaderTheme: String, CaseIterable, Identifiable {
    case parchment
    case sepia
    case paper
    case night
    case dark
    case oled
    case slate

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .parchment: return "Parchment"
        case .sepia:     return "Sepia"
        case .paper:     return "Paper"
        case .night:     return "Night"
        case .dark:      return "Dark"
        case .oled:      return "OLED"
        case .slate:     return "Slate"
        }
    }

    public var light: ThemeColorSet {
        switch self {
        case .parchment:
            return ThemeColorSet(
                background: "#FFFDF6", text: "#1A1A1A", link: "#8A5A2B",
                prefaceBorder: "#E0D8C3", prefaceBackground: "#F7F3E8", prefaceLabel: "#2C251E"
            )
        case .sepia:
            return ThemeColorSet(
                background: "#FBF0D9", text: "#433422", link: "#8A5A2B",
                prefaceBorder: "#E2D2B8", prefaceBackground: "#F4E8CF", prefaceLabel: "#433224"
            )
        case .paper:
            return ThemeColorSet(
                background: "#FFFFFF", text: "#111111", link: "#0068DA",
                prefaceBorder: "#E0E0E0", prefaceBackground: "#F8F8F8", prefaceLabel: "#000000"
            )
        case .night:
            return ThemeColorSet(
                background: "#F2F2F7", text: "#1C1C1E", link: "#007AFF",
                prefaceBorder: "#D8D8DC", prefaceBackground: "#E5E5EA", prefaceLabel: "#000000"
            )
        case .dark:
            return ThemeColorSet(
                background: "#EFEFF4", text: "#16161A", link: "#0068DA",
                prefaceBorder: "#D4D4D8", prefaceBackground: "#E2E2E8", prefaceLabel: "#000000"
            )
        case .oled:
            return ThemeColorSet(
                background: "#FFFFFF", text: "#000000", link: "#0068DA",
                prefaceBorder: "#D0D0D0", prefaceBackground: "#F5F5F5", prefaceLabel: "#000000"
            )
        case .slate:
            return ThemeColorSet(
                background: "#EBEBF0", text: "#3A3A3C", link: "#007AFF",
                prefaceBorder: "#D1D1D6", prefaceBackground: "#E5E5EA", prefaceLabel: "#1C1C1E"
            )
        }
    }

    public var dark: ThemeColorSet {
        switch self {
        case .parchment:
            return ThemeColorSet(
                background: "#242426", text: "#E8E0D4", link: "#5AA9FF",
                prefaceBorder: "#38383A", prefaceBackground: "#2C2C2E", prefaceLabel: "#FFFFFF"
            )
        case .sepia:
            return ThemeColorSet(
                background: "#2B2216", text: "#D8C9A8", link: "#C99A55",
                prefaceBorder: "#4A3B2C", prefaceBackground: "#382C1E", prefaceLabel: "#E0D0B0"
            )
        case .paper:
            return ThemeColorSet(
                background: "#1C1C1E", text: "#E5E5EA", link: "#5AA9FF",
                prefaceBorder: "#38383A", prefaceBackground: "#252527", prefaceLabel: "#FFFFFF"
            )
        case .night:
            return ThemeColorSet(
                background: "#1C1C1E", text: "#E5E5EA", link: "#5AA9FF",
                prefaceBorder: "#38383A", prefaceBackground: "#252527", prefaceLabel: "#FFFFFF"
            )
        case .dark:
            return ThemeColorSet(
                background: "#16161A", text: "#CFCFD4", link: "#5AA9FF",
                prefaceBorder: "#333338", prefaceBackground: "#1F1F24", prefaceLabel: "#FFFFFF"
            )
        case .oled:
            return ThemeColorSet(
                background: "#000000", text: "#D4D4D8", link: "#5AA9FF",
                prefaceBorder: "#333333", prefaceBackground: "#141414", prefaceLabel: "#FFFFFF"
            )
        case .slate:
            return ThemeColorSet(
                background: "#2C2C2E", text: "#EBEBF5", link: "#7FB2E8",
                prefaceBorder: "#48484A", prefaceBackground: "#363638", prefaceLabel: "#FFFFFF"
            )
        }
    }

    public func colorSet(for isDark: Bool) -> ThemeColorSet {
        isDark ? dark : light
    }

    public var bg: String {
        colorSet(for: ReaderPreferences.shared.effectiveIsDark).background
    }

    public var fg: String {
        colorSet(for: ReaderPreferences.shared.effectiveIsDark).text
    }

    public var link: String {
        colorSet(for: ReaderPreferences.shared.effectiveIsDark).link
    }

    public var isDark: Bool {
        ReaderPreferences.shared.effectiveIsDark
    }

    public var prefaceBorderColor: String {
        colorSet(for: ReaderPreferences.shared.effectiveIsDark).prefaceBorder
    }

    public var prefaceBackgroundColor: String {
        colorSet(for: ReaderPreferences.shared.effectiveIsDark).prefaceBackground
    }

    public var prefaceLabelColor: String {
        colorSet(for: ReaderPreferences.shared.effectiveIsDark).prefaceLabel
    }

    public static func current(bg: String, fg: String) -> ReaderTheme? {
        // Match against either light or dark sets
        allCases.first {
            ($0.light.background.caseInsensitiveCompare(bg) == .orderedSame &&
             $0.light.text.caseInsensitiveCompare(fg) == .orderedSame) ||
            ($0.dark.background.caseInsensitiveCompare(bg) == .orderedSame &&
             $0.dark.text.caseInsensitiveCompare(fg) == .orderedSame)
        }
    }
}

extension ReaderPreferences {
    public func applyTheme(_ theme: ReaderTheme) {
        selectedTheme = theme
        updateEffectiveColors()
    }

    public var activeTheme: ReaderTheme? {
        selectedTheme
    }

    public func increaseFontSize() {
        fontSize = min(36, fontSize + 1)
    }

    public func decreaseFontSize() {
        fontSize = max(10, fontSize - 1)
    }

    public func resetFontSize() {
        fontSize = ReaderPreferences.Defaults.fontSize
    }
}
