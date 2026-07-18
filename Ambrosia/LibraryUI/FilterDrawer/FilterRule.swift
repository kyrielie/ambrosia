import Foundation

// MARK: - Filter field

enum FilterField: String, CaseIterable, Identifiable, Codable {
    case title
    case authorName
    case tag
    case rating
    case warning
    case category
    case series
    case comment
    case wordCountGT
    case wordCountLT
    case kudosGT
    case kudosLT
    case collection
    case status
    case fulltext
    case crossover  // §6: new; boolean — fandoms.count > 1

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title:       return "Title"
        case .authorName:  return "Author"
        case .tag:         return "Tag"
        case .rating:      return "Rating"
        case .warning:     return "Warning"
        case .category:    return "Category"
        case .series:      return "Series"
        case .comment:     return "Description"
        case .wordCountGT: return "Word count >"
        case .wordCountLT: return "Word count <"
        case .kudosGT:     return "Kudos >"
        case .kudosLT:     return "Kudos <"
        case .collection:  return "Collection"
        case .status:      return "Status"
        case .fulltext:    return "Full text"
        case .crossover:   return "Crossover"
        }
    }

    var expectsText: Bool {
        switch self {
        case .title, .authorName, .tag, .rating, .warning, .category, .series, .comment, .collection, .status, .fulltext:
            return true
        case .wordCountGT, .wordCountLT, .kudosGT, .kudosLT, .crossover:
            return false
        }
    }

    /// Whether filtering this field requires a JOIN against a related table.
    var requiresJoin: Bool {
        switch self {
        case .authorName, .tag, .rating, .warning, .category: return true
        default: return false
        }
    }

    static var visibleCases: [FilterField] { allCases }
}

// MARK: - AO3CompletionStatus
//
// §5: Renamed from .finished/.unfinished → .complete/.workInProgress.
// Raw values updated to "Complete"/"Work in Progress" (UI labels).
// init?(userValue:) accepts legacy "finished"/"unfinished" so that saved
// FilterRule.value strings and typed search text continue to resolve correctly.
// Does NOT touch SystemCollectionID.finished ("Finished" reading collection).

enum AO3CompletionStatus: String, CaseIterable, Identifiable {
    case complete       = "Complete"
    case workInProgress = "Work in Progress"

    var id: String { rawValue }

    init?(userValue: String) {
        switch userValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "complete", "finished":
            self = .complete
        case "work in progress", "wip", "incomplete", "unfinished":
            self = .workInProgress
        default:
            return nil
        }
    }
}

// MARK: - Filter operator

enum FilterOperator: String, CaseIterable, Identifiable, Codable {
    case contains
    case notContains
    case equals
    case notEquals
    case startsWith
    /// Rating ceiling: matches books whose highest rating is ≤ this value.
    /// Books with "Not Rated" ARE included (they are not higher than anything).
    case ratingAtMost
    /// Rating floor: matches books whose lowest rating is ≥ this value.
    /// Books with "Not Rated" are excluded.
    case ratingAtLeast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contains:     return "contains"
        case .notContains:  return "does not contain"
        case .equals:       return "is"
        case .notEquals:    return "is not"
        case .startsWith:   return "starts with"
        case .ratingAtMost: return "max rating"
        case .ratingAtLeast:return "min rating"
        }
    }

    static var numericOperators: [FilterOperator] { [.equals, .notEquals] }
    static var textOperators: [FilterOperator] { [.contains, .notContains, .equals, .startsWith] }
    static var exactOperators: [FilterOperator] { [.equals, .notEquals] }
    static var ratingOperators: [FilterOperator] { [.equals, .notEquals, .ratingAtMost, .ratingAtLeast] }
}

// MARK: - Filter conjunction

enum FilterConjunction: String, CaseIterable, Identifiable, Codable {
    case and = "AND"
    case or  = "OR"
    var id: String { rawValue }
    var label: String { rawValue }
}

// MARK: - FilterRule

struct FilterRule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var field: FilterField
    var op: FilterOperator
    var value: String

    init(field: FilterField = .title, op: FilterOperator = .contains, value: String = "") {
        self.field = field
        self.op    = op
        self.value = value
    }

    var isComplete: Bool {
        switch field {
        case .crossover:
            return true
        case .status:
            return AO3CompletionStatus(userValue: value) != nil
        case .wordCountGT, .wordCountLT, .kudosGT, .kudosLT:
            return Int(value) != nil
        default:
            return !value.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var numericValue: Int? { Int(value) }

    /// Operators valid for the current field.
    ///
    /// §9 (revised): `.tag` previously fell through to `default` ->
    /// `textOperators`, which does not include `.notEquals`. FilterRuleRow's
    /// `rule` is a live `@Binding` straight into the applied
    /// `FilterExpression`, and both `normalizeOperator()` (called on
    /// `.onAppear`) and `operatorBinding`'s getter treat any `op` not in
    /// `availableOperators` as invalid, silently overwriting it with
    /// `availableOperators[0]`. Since the AO3-style filter popup writes
    /// `.tag`/`.notEquals` rules for every excluded tag (see
    /// `AO3FilterPopupState.buildExpression`), simply opening the regular
    /// filter drawer -- which renders one `FilterRuleRow` per rule --
    /// silently rewrote every excluded tag into `.contains` (a substring
    /// *include*, not an exclude) before the user touched anything. `.tag`
    /// now gets its own case so `.notEquals` survives the round trip; order
    /// matches `textOperators` with `.notEquals` appended last so a
    /// freshly-switched-to-`.tag` row (via the field Picker's
    /// `.onChange`-driven reset to `availableOperators[0]`) still defaults
    /// to `.contains`, unchanged from before this fix.
    var availableOperators: [FilterOperator] {
        switch field {
        case .rating:
            return FilterOperator.ratingOperators
        case .warning, .category, .collection, .status, .crossover:
            return FilterOperator.exactOperators
        case .tag:
            return FilterOperator.textOperators + [.notEquals]
        case .fulltext:
            return [.contains, .notContains]
        case .wordCountGT, .wordCountLT, .kudosGT, .kudosLT:
            return FilterOperator.numericOperators
        default:
            return FilterOperator.textOperators
        }
    }
}

// MARK: - FilterGroup

/// A group of rules joined by a single conjunction.
/// Multiple groups are joined by the OPPOSITE conjunction at the top level.
///
/// Example — two groups, top-level OR between them:
///   Group 1 (AND): Tag=Fantasy, Tag=Romance   → Fantasy AND Romance
///   Group 2 (AND): Rating=Explicit            → Explicit
///   Result: (Fantasy AND Romance) OR Explicit
///
/// The top-level conjunction is stored on the first group; it is the conjunction
/// used *between* groups (not within them). Within a group, `conjunction` applies.
struct FilterGroup: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var rules: [FilterRule]
    /// How rules within this group are joined.
    var conjunction: FilterConjunction

    init(rules: [FilterRule] = [], conjunction: FilterConjunction = .and) {
        self.rules = rules
        self.conjunction = conjunction
    }

    var isComplete: Bool { rules.contains(where: \.isComplete) }
    var completeRules: [FilterRule] { rules.filter(\.isComplete) }
}

// MARK: - FilterExpression

/// The full filter state: a list of groups joined by `groupConjunction`.
struct FilterExpression: Codable, Equatable {
    var groups: [FilterGroup]
    /// How groups are joined to each other.
    var groupConjunction: FilterConjunction

    init() {
        groups = [FilterGroup()]
        groupConjunction = .or
    }

    var isEmpty: Bool { groups.allSatisfy { $0.rules.isEmpty } }
    var hasCompleteRules: Bool { groups.contains { $0.isComplete } }
}
