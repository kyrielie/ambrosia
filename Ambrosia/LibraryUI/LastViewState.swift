import Foundation

/// The part of the list view a user expects to find again on relaunch: sort,
/// direction and filter. Search text is deliberately not stored (a plain or
/// `fulltext:` search can cost FTS work at launch), and `groupBySeries` keeps
/// its own existing `UserDefaults` key so there is one source of truth.
///
/// View state is user intent, so it lives in `UserDefaults` (per library hash),
/// not in a cache directory that the OS may purge.
struct LastViewState: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = LastViewState.currentSchemaVersion
    /// Stored as the raw string so an unknown value from a newer or older
    /// build degrades to the default sort instead of failing the whole decode.
    var sortFieldRaw: String
    var ascending: Bool
    /// Nil means the default (unfiltered) view.
    var filterExpression: FilterExpression?

    init(sortField: SortField, ascending: Bool, filterExpression: FilterExpression?) {
        self.sortFieldRaw = sortField.rawValue
        self.ascending = ascending
        self.filterExpression = filterExpression
    }

    var sortField: SortField { SortField(rawValue: sortFieldRaw) ?? .title }

    static let defaultView = LastViewState(sortField: .title, ascending: true, filterExpression: nil)

    var isDefaultView: Bool {
        sortField == .title && ascending && filterExpression == nil
    }
}

/// Makes a persisted view safe to apply. A rule can reference something that no
/// longer exists (a deleted collection, referenced by name), and a `fulltext`
/// rule would put FTS work on the launch path. Incomplete rows are editing
/// state, not intent, so they are dropped silently.
enum LastViewValidator {
    struct Result: Equatable {
        var state: LastViewState
        /// Human-readable list of what was removed, for a log line.
        var dropped: [String]
    }

    /// `collectionNames` nil skips the collection check (used when sanitizing
    /// before a write, or if the collection list could not be read).
    static func validate(_ state: LastViewState, collectionNames: Set<String>?) -> Result {
        var dropped: [String] = []
        if SortField(rawValue: state.sortFieldRaw) == nil {
            dropped.append("sort:\(state.sortFieldRaw)")
        }

        var filter: FilterExpression?
        if let source = state.filterExpression {
            var groups: [FilterGroup] = []
            for group in source.groups {
                var kept: [FilterRule] = []
                for rule in group.rules {
                    guard rule.isComplete else { continue }
                    if rule.field == .fulltext {
                        dropped.append("fulltext:\(rule.value)")
                        continue
                    }
                    if rule.field == .collection, let names = collectionNames, !names.contains(rule.value) {
                        dropped.append("collection:\(rule.value)")
                        continue
                    }
                    kept.append(rule)
                }
                guard !kept.isEmpty else { continue }
                var survivor = group
                survivor.rules = kept
                groups.append(survivor)
            }
            if !groups.isEmpty {
                var expression = FilterExpression()
                expression.groups = groups
                expression.groupConjunction = source.groupConjunction
                filter = expression
            }
        }
        return Result(
            state: LastViewState(sortField: state.sortField, ascending: state.ascending, filterExpression: filter),
            dropped: dropped
        )
    }
}

/// `UserDefaults`-backed persistence for `LastViewState`, keyed per library.
struct LastViewStore {
    /// Rollback switch for restoring the last view on open. Remove the switch
    /// and the dead path in a follow-up once the behavior is accepted.
    static let restoreLastView = true

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(forLibraryHash hash: String) -> String { "lastView.\(hash)" }

    /// Nil for a missing value, undecodable data, or a different schema version.
    func load(libraryHash: String) -> LastViewState? {
        guard let data = defaults.data(forKey: Self.key(forLibraryHash: libraryHash)),
              let state = try? JSONDecoder().decode(LastViewState.self, from: data),
              state.schemaVersion == LastViewState.currentSchemaVersion else { return nil }
        return state
    }

    /// The default view is stored as the absence of a value, so clearing the
    /// filter and restoring the default sort leaves nothing behind.
    func save(_ state: LastViewState, libraryHash: String) {
        let key = Self.key(forLibraryHash: libraryHash)
        if state.isDefaultView {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    func clear(libraryHash: String) {
        defaults.removeObject(forKey: Self.key(forLibraryHash: libraryHash))
    }

    /// The validated state to apply on open, or nil when there is nothing to
    /// restore (no stored view, or it reduces to the default view).
    func restore(libraryHash: String, collectionNames: Set<String>?) -> (state: LastViewState, dropped: [String])? {
        guard Self.restoreLastView, let stored = load(libraryHash: libraryHash) else { return nil }
        let result = LastViewValidator.validate(stored, collectionNames: collectionNames)
        guard !result.state.isDefaultView else { return nil }
        return (result.state, result.dropped)
    }
}
