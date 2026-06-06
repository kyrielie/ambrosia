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
}

enum AO3Warning: String, CaseIterable {
    case noWarnings           = "No Archive Warnings Apply"
    case creatorChoseNot      = "Creator Chose Not To Use Archive Warnings"
    case chooseNotTo          = "Choose Not To Use Archive Warnings"  // alternate AO3 export spelling
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
        if let r = AO3Rating(rawValue: tag)   { return .rating(r) }
        if let w = AO3Warning(rawValue: tag)  { return .warning(w) }
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
    var ratings:    [String] = []
    var warnings:   [String] = []
    var categories: [String] = []
    var regular:    [String] = []

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
