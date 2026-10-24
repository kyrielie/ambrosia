import Foundation

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

    public var bg: String {
        switch self {
        case .parchment: return "#FFFDF6"
        case .sepia:     return "#FBF0D9"
        case .paper:     return "#FFFFFF"
        case .night:     return "#1C1C1E"
        case .dark:      return "#16161A"
        case .oled:      return "#000000"
        case .slate:     return "#2C2C2E"
        }
    }

    public var fg: String {
        switch self {
        case .parchment: return "#1A1A1A"
        case .sepia:     return "#5B4636"
        case .paper:     return "#111111"
        case .night:     return "#E5E5EA"
        case .dark:      return "#CFCFD4"
        case .oled:      return "#CFCFD4"
        case .slate:     return "#EBEBF5"
        }
    }

    public var isDark: Bool {
        switch self {
        case .night, .dark, .oled, .slate:
            return true
        case .parchment, .sepia, .paper:
            return false
        }
    }

    public var prefaceBorderColor: String {
        switch self {
        case .parchment: return "#E0D8C3"
        case .sepia:     return "#E2D2B8"
        case .paper:     return "#E0E0E0"
        case .night:     return "#38383A"
        case .dark:      return "#333338"
        case .oled:      return "#333333"
        case .slate:     return "#48484A"
        }
    }

    public var prefaceBackgroundColor: String {
        switch self {
        case .parchment: return "#F7F3E8"
        case .sepia:     return "#F4E8CF"
        case .paper:     return "#F8F8F8"
        case .night:     return "#252527"
        case .dark:      return "#1F1F24"
        case .oled:      return "#141414"
        case .slate:     return "#363638"
        }
    }

    public var prefaceLabelColor: String {
        switch self {
        case .parchment: return "#2C251E"
        case .sepia:     return "#433224"
        case .paper:     return "#000000"
        case .night, .dark, .oled, .slate: return "#FFFFFF"
        }
    }

    public static func current(bg: String, fg: String) -> ReaderTheme? {
        allCases.first {
            $0.bg.caseInsensitiveCompare(bg) == .orderedSame &&
            $0.fg.caseInsensitiveCompare(fg) == .orderedSame
        }
    }
}

extension ReaderPreferences {
    public func applyTheme(_ theme: ReaderTheme) {
        readerBackgroundColor = theme.bg
        readerTextColor = theme.fg
    }

    public var activeTheme: ReaderTheme? {
        ReaderTheme.current(bg: readerBackgroundColor, fg: readerTextColor)
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
