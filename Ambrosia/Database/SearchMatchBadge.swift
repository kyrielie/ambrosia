// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI

/// Typographic match badges explaining why a book was retrieved or prioritized in search results.
public enum SearchMatchBadge: Equatable, Sendable {
    case exactTag(String)
    case exactTitle
    case exactAuthor
    case exactSeries
    case semantic(percent: Int)
    case hybrid(semanticPercent: Int)
    case bodyText(count: Int? = nil)

    public var label: String {
        switch self {
        case .exactTag(let tag):
            return "Exact Tag: \(tag)"
        case .exactTitle:
            return "Exact Title"
        case .exactAuthor:
            return "Exact Author"
        case .exactSeries:
            return "Exact Series"
        case .semantic(let percent):
            return "\(percent)% Semantic"
        case .hybrid(let percent):
            return "Top Match (\(percent)% Semantic)"
        case .bodyText(let count):
            if let count, count > 1 {
                return "\(count) Body Text Matches"
            }
            return "Body Text Match"
        }
    }

    public var systemImage: String {
        switch self {
        case .exactTag:
            return "tag.fill"
        case .exactTitle:
            return "text.quote"
        case .exactAuthor:
            return "person.fill"
        case .exactSeries:
            return "books.vertical.fill"
        case .semantic:
            return "sparkles"
        case .hybrid:
            return "sparkle.magnifyingglass"
        case .bodyText:
            return "doc.text.magnifyingglass"
        }
    }

    public var tintColor: Color {
        Color(nsColor: nsColor)
    }

    public var nsColor: NSColor {
        switch self {
        case .exactTag:
            return .systemTeal
        case .exactTitle, .exactAuthor, .exactSeries:
            return .systemBlue
        case .semantic:
            return .systemIndigo
        case .hybrid:
            return .systemPurple
        case .bodyText:
            return .systemOrange
        }
    }
}
