import Foundation
import SwiftUI

// MARK: - AnnotationColor

/// Semantic highlight color keys shared with Nectar (`Annotation.Color`).
/// Stored in `annotations.color_key` so switching `HighlightPalette` or reader
/// appearance updates existing highlights without rewriting persisted rows.
public enum AnnotationColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow
    case red
    case green
    case blue
    case purple

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .yellow: return "Yellow"
        case .red:    return "Red"
        case .green:  return "Green"
        case .blue:   return "Blue"
        case .purple: return "Purple"
        }
    }

    /// Maps legacy hex strings (`#FFD60A`, etc.) to their semantic color key.
    public init(legacyHex: String?) {
        let normalized = (legacyHex ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        switch normalized {
        case "#FFD60A", "#FFCC00": self = .yellow
        case "#FF453A", "#FF3B30": self = .red
        case "#30D158", "#34C759": self = .green
        case "#0A84FF", "#007AFF": self = .blue
        case "#BF5AF2", "#AF52DE": self = .purple
        default:                   self = .yellow
        }
    }
}

// MARK: - HighlightPalette

/// Nine curated highlight color palettes matching Nectar's `HighlightPalette`.
/// Each palette provides separate `lightHexSet` and `darkHexSet` values;
/// every `darkHexSet` color is deepened in HSL lightness so light body text
/// clears WCAG AA (≥ 4.5:1) contrast.
public enum HighlightPalette: Int, Codable, CaseIterable, Identifiable, Sendable {
    case `default` = 0
    case muted = 1
    case vivid = 2
    case sepia = 3
    case mint = 4
    case fluorescent = 5
    case refresh = 6
    case warm = 7
    case neutral = 8

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .default:     return "Default"
        case .muted:       return "Muted"
        case .vivid:       return "Vivid"
        case .sepia:       return "Sepia"
        case .mint:        return "Mint"
        case .fluorescent: return "Fluorescent"
        case .refresh:     return "Refresh"
        case .warm:        return "Warm"
        case .neutral:     return "Neutral"
        }
    }

    public struct HexSet: Equatable, Sendable {
        public let yellow: String
        public let red: String
        public let green: String
        public let blue: String
        public let purple: String

        public init(yellow: String, red: String, green: String, blue: String, purple: String) {
            self.yellow = yellow
            self.red = red
            self.green = green
            self.blue = blue
            self.purple = purple
        }

        public subscript(_ color: AnnotationColor) -> String {
            switch color {
            case .yellow: return yellow
            case .red:    return red
            case .green:  return green
            case .blue:   return blue
            case .purple: return purple
            }
        }
    }

    public var lightHexSet: HexSet {
        switch self {
        case .default:
            return HexSet(yellow: "#FFCC00", red: "#FF3B30", green: "#34C759", blue: "#007AFF", purple: "#AF52DE")
        case .muted:
            return HexSet(yellow: "#E8D48A", red: "#D99C90", green: "#9DC2A0", blue: "#92B8D4", purple: "#B79CC7")
        case .vivid:
            return HexSet(yellow: "#FFEA00", red: "#FF1744", green: "#00C853", blue: "#2962FF", purple: "#D500F9")
        case .sepia:
            return HexSet(yellow: "#D9A441", red: "#C06A4D", green: "#8A9A5B", blue: "#5E8A9E", purple: "#96789A")
        case .mint:
            return HexSet(yellow: "#a0d084", red: "#9cb2e3", green: "#d5d6da", blue: "#b6add8", purple: "#de556f")
        case .fluorescent:
            return HexSet(yellow: "#f1a5c7", red: "#f7c18e", green: "#f6e977", blue: "#85cbb3", purple: "#a4d3e6")
        case .refresh:
            return HexSet(yellow: "#e277cd", red: "#f9423a", green: "#cedc00", blue: "#00b2a9", purple: "#7474c1")
        case .warm:
            return HexSet(yellow: "#89afb4", red: "#d6735d", green: "#efcc82", blue: "#c093b2", purple: "#826860")
        case .neutral:
            return HexSet(yellow: "#c57955", red: "#d8b58f", green: "#f8cfb8", blue: "#bdc8d3", purple: "#b8b279")
        }
    }

    public var darkHexSet: HexSet {
        switch self {
        case .default:
            return HexSet(yellow: "#8B7300", red: "#EA0D00", green: "#1E8738", blue: "#0072E6", purple: "#B033EF")
        case .muted:
            return HexSet(yellow: "#8A7333", red: "#8A5147", green: "#4F7A56", blue: "#4A7396", purple: "#7C5F91")
        case .vivid:
            return HexSet(yellow: "#837600", red: "#EC0000", green: "#0D874B", blue: "#1E6AFF", purple: "#C605E6")
        case .sepia:
            return HexSet(yellow: "#976E29", red: "#8F4E38", green: "#64703F", blue: "#456B7A", purple: "#6B5470")
        case .mint:
            return HexSet(yellow: "#4F8232", red: "#4A72CC", green: "#727581", blue: "#7A6AB8", purple: "#D83654")
        case .fluorescent:
            return HexSet(yellow: "#DD2376", red: "#B45E0D", green: "#837609", blue: "#378269", purple: "#2C7E9F")
        case .refresh:
            return HexSet(yellow: "#CD2CAE", red: "#EA1107", green: "#737B00", blue: "#00837D", purple: "#6D6DBE")
        case .warm:
            return HexSet(yellow: "#527C82", red: "#C74E32", green: "#986E13", blue: "#A25F8D", purple: "#826860")
        case .neutral:
            return HexSet(yellow: "#AE603C", red: "#9C6B36", green: "#C35313", blue: "#607890", purple: "#7C7742")
        }
    }

    public func hexSet(isDark: Bool) -> HexSet {
        isDark ? darkHexSet : lightHexSet
    }

    public func hex(for color: AnnotationColor, isDark: Bool) -> String {
        hexSet(isDark: isDark)[color]
    }

    public func swiftUIColor(for color: AnnotationColor, isDark: Bool) -> Color {
        Color(hex: hex(for: color, isDark: isDark)) ?? .yellow
    }
}
