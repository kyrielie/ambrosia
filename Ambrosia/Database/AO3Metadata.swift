import Foundation

// MARK: - AO3 Metadata Classification

/// AO3 uses specific tag strings for ratings, content warnings, and relationship
/// categories. These should never be treated as generic freeform tags — they
/// deserve their own filter fields, display sections, and click behaviour.

enum AO3Rating: String, CaseIterable {
    case generalAudiences  = "General Audiences"
    case teenAndUp         = "Teen And Up Audiences"
    case mature            = "Mature"
    case explicit          = "Explicit"
    case notRated          = "Not Rated"

    // MARK: - Ordinal hierarchy
    //
    // "Not Rated" sits outside the linear scale — a book tagged "Not Rated" could
    // be anything, so it is treated as unrated rather than given a position.
    // The four rated values form a strict ascending order used by the ceiling filter.

    /// Numeric level for hierarchy comparisons. nil means "outside the scale".
    var level: Int? {
        switch self {
        case .generalAudiences: return 1
        case .teenAndUp:        return 2
        case .mature:           return 3
        case .explicit:         return 4
        case .notRated:         return nil
        }
    }

    /// All ratings that are strictly higher than this one on the linear scale.
    var higherRatings: [AO3Rating] {
        guard let myLevel = level else { return [] }
        return AO3Rating.allCases.filter { ($0.level ?? 0) > myLevel }
    }

    /// All ratings that are strictly lower than this one on the linear scale.
    var lowerRatings: [AO3Rating] {
        guard let myLevel = level else { return [] }
        return AO3Rating.allCases.filter { ($0.level ?? Int.max) < myLevel }
    }

    /// The single highest-hierarchy rating found among `tags`. Unrecognized
    /// tags are ignored. `.notRated` (outside the linear scale, `level ==
    /// nil`) only wins if every recognized rating tag present is itself
    /// `.notRated` — any ranked rating beats it. Returns nil if `tags`
    /// contains no recognized rating tag at all.
    static func highest(among tags: [String]) -> AO3Rating? {
        tags.compactMap { AO3Rating(rawValue: $0) }
            .max { ($0.level ?? -1) < ($1.level ?? -1) }
    }
}

enum AO3Warning: String, CaseIterable {
    case noWarnings           = "No Archive Warnings Apply"
    // AO3 EPUB preface HTML spells this "Creator Chose Not To Use Archive Warnings",
    // but Calibre tags (the source for AO3TagKind.classify) spell it "Choose Not To
    // Use Archive Warnings". This case is the single canonical value for both.
    // AO3MetadataExtractor normalizes the preface spelling to this one before
    // constructing the enum, so both sources always resolve to `.chooseNotTo`.
    case chooseNotTo          = "Choose Not To Use Archive Warnings"
    case graphicViolence      = "Graphic Depictions Of Violence"
    case majorCharDeath       = "Major Character Death"
    case underage             = "Underage Sex"
    case nonCon               = "Rape/Non-Con"
}

enum AO3Category: String, CaseIterable {
    case gen   = "Gen"
    case fm    = "F/M"
    case mm    = "M/M"
    case ff    = "F/F"
    case multi = "Multi"
    case other = "Other"
}

/// Central classifier — call once per tag string to determine how it should be
/// displayed and filtered.
enum AO3TagKind: Equatable {
    case rating(AO3Rating)
    case warning(AO3Warning)
    case category(AO3Category)
    case regular                // ordinary freeform tag
}

extension AO3TagKind {
    static func classify(_ tag: String) -> AO3TagKind {
        if let r = AO3Rating(rawValue: tag) { return .rating(r) }
        if let w = AO3Warning(rawValue: tag) { return .warning(w) }
        if let c = AO3Category(rawValue: tag) { return .category(c) }
        return .regular
    }

    /// The `FilterField` that corresponds to this kind, for use when the user
    /// clicks a tag pill to create a filter rule.
    var filterField: FilterField {
        switch self {
        case .rating:   return .rating
        case .warning:  return .warning
        case .category: return .category
        case .regular:  return .tag
        }
    }

    var sectionLabel: String? {
        switch self {
        case .rating:   return "Rating"
        case .warning:  return "Warning"
        case .category: return "Category"
        case .regular:  return nil
        }
    }
}

// MARK: - Tag bucket

/// All tags for a book split into their four buckets, in display order.
struct AO3TagBuckets {
    var ratings: [String] = []
    var warnings: [String] = []
    var categories: [String] = []
    var regular: [String] = []

    init() {}   // empty — used as @State initial value

    static func from(tags: [String]) -> AO3TagBuckets {
        var b = AO3TagBuckets()
        for tag in tags {
            switch AO3TagKind.classify(tag) {
            case .rating:   b.ratings.append(tag)
            case .warning:  b.warnings.append(tag)
            case .category: b.categories.append(tag)
            case .regular:  b.regular.append(tag)
            }
        }
        return b
    }

    var isEmpty: Bool {
        ratings.isEmpty && warnings.isEmpty && categories.isEmpty && regular.isEmpty
    }
}
