import Foundation

/// The seven AO3 tag types reproduced by the filter popup, minus rating
/// (handled separately — it's a single TEXT column, not a JSON array).
/// Order matches AO3's own `_filters.html.erb`:
/// rating, archive_warning, category, fandom, character, relationship, freeform.
enum AO3FacetField: String, CaseIterable {
    case fandom
    case relationship
    case character
    case freeform
    case warning
    case category
    case author

    /// The `ao3_metadata` JSON-array column this facet is aggregated over.
    var jsonColumn: String {
        switch self {
        case .fandom:       return "fandoms_json"
        case .relationship: return "relationships_json"
        case .character:    return "characters_json"
        case .freeform:     return "additional_tags_json"
        case .warning:      return "warnings_json"
        case .category:     return "category_json"
        case .author:       return "author_names_json"
        }
    }

    /// The `FilterRule.field` this facet's checkboxes translate to on Apply.
    var filterField: FilterField {
        switch self {
        case .fandom, .relationship, .character, .freeform: return .tag
        case .warning: return .warning
        case .category: return .category
        case .author: return .authorName
        }
    }

    var sectionLabel: String {
        switch self {
        case .fandom:       return "Fandoms"
        case .relationship: return "Relationships"
        case .character:    return "Characters"
        case .freeform:     return "Additional Tags"
        case .warning:      return "Archive Warnings"
        case .category:     return "Categories"
        case .author:       return "Authors"
        }
    }
}
