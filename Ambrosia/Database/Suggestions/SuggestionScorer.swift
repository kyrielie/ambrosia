import Foundation

/// Tag type classification stored as a compact 1-byte value in the suggestion snapshot.
public enum SuggestionTagType: UInt8, Sendable, CaseIterable {
    case unknown = 0
    case relationship = 1
    case character = 2
    case fandom = 3
    case freeform = 4
    case rating = 5
    case warning = 6
    case category = 7

    /// Converts a raw string (e.g. from `book_tags.tag_type`) into `SuggestionTagType`.
    public static func from(rawType: String) -> SuggestionTagType {
        switch rawType.lowercased() {
        case "relationship": return .relationship
        case "character":    return .character
        case "fandom":       return .fandom
        case "freeform":     return .freeform
        case "rating":       return .rating
        case "warning":      return .warning
        case "category":     return .category
        default:             return .unknown
        }
    }

    /// User-facing descriptive label for accessibility.
    public var accessibilityLabel: String {
        switch self {
        case .unknown:      return "Tag"
        case .relationship: return "Relationship tag"
        case .character:    return "Character tag"
        case .fandom:       return "Fandom tag"
        case .freeform:     return "Freeform tag"
        case .rating:       return "Rating tag"
        case .warning:      return "Warning tag"
        case .category:     return "Category tag"
        }
    }
}

/// Strict match class hierarchy where match quality strictly dominates frequency.
public enum SuggestionMatchClass: Int, Comparable, Sendable {
    case exact = 1
    case prefix = 2
    case wordPrefix = 3
    case substring = 4
    case relationshipPermuted = 5
    case acronym = 6
    case fuzzyDistance1 = 7
    case fuzzyDistance2 = 8

    public static func < (lhs: SuggestionMatchClass, rhs: SuggestionMatchClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A matched suggestion with value, match class, tag type, and link frequency.
public struct SuggestionMatch: Sendable, Equatable {
    public let value: String
    public let matchClass: SuggestionMatchClass
    public let tagType: SuggestionTagType?
    public let frequency: Int
    public let foldedName: String

    public init(
        value: String,
        matchClass: SuggestionMatchClass,
        tagType: SuggestionTagType? = nil,
        frequency: Int = 1,
        foldedName: String? = nil
    ) {
        self.value = value
        self.matchClass = matchClass
        self.tagType = tagType
        self.frequency = frequency
        self.foldedName = foldedName ?? SuggestionNormalizer.fold(value)
    }

    /// Primary comparator: matchClass ascending (lower value = better),
    /// frequency descending (higher = better), foldedName ascending (alphabetical tiebreak).
    public static func isBetter(_ first: SuggestionMatch, than second: SuggestionMatch) -> Bool {
        if first.matchClass != second.matchClass {
            return first.matchClass < second.matchClass
        }
        if first.frequency != second.frequency {
            return first.frequency > second.frequency
        }
        return first.foldedName < second.foldedName
    }
}

/// Bounded top-k collector for suggestion matches.
public struct SuggestionCollector {
    private let limit: Int
    private var matches: [SuggestionMatch] = []
    private var seenValues: Set<String> = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var count: Int {
        matches.count
    }

    public var isFull: Bool {
        matches.count >= limit && (matches.last?.matchClass == .exact || matches.last?.matchClass == .prefix)
    }

    /// Checks whether the collector has capacity to be improved by a match of this class.
    public func hasCapacity(forClass matchClass: SuggestionMatchClass) -> Bool {
        if matches.count < limit { return true }
        guard let worst = matches.last else { return true }
        return matchClass < worst.matchClass
    }

    /// Inserts a match if not already present and ranks it into the bounded top-k list.
    public mutating func insert(_ match: SuggestionMatch) {
        guard !seenValues.contains(match.value) else { return }

        if matches.count < limit {
            seenValues.insert(match.value)
            matches.append(match)
            matches.sort(by: SuggestionMatch.isBetter)
        } else if let worst = matches.last, SuggestionMatch.isBetter(match, than: worst) {
            seenValues.remove(worst.value)
            seenValues.insert(match.value)
            matches[matches.count - 1] = match
            matches.sort(by: SuggestionMatch.isBetter)
        }
    }

    /// Returns the final sorted top-k results.
    public func finalized() -> [SuggestionMatch] {
        matches
    }
}
