import Foundation

// MARK: - LRU cache key

/// Cache key for a FilterResult: the serialised expression + membership version.
/// Two calls with identical filter rules but different membership states (e.g. the user
/// just liked a book) must NOT share a cache entry. The cached ID lists also have the
/// four visibility preferences applied, so `visibilitySignature` is part of the key:
/// toggling a preference changes no membership set, and stripped books cannot be
/// restored from a list that already lacks them. `bookTagsRevision` ties a cached
/// tag result to the `book_tags` contents it was computed from, so an AO3
/// extraction pass invalidates it.
struct FilterResultCacheKey: Hashable {
    let expressionDigest: String    // serialised rule descriptions (stable, cheap)
    let membershipVersion: Int
    let visibilitySignature: String
    let bookTagsRevision: Int
}

extension FilterResultCacheKey {
    init(expression: FilterExpression, membershipVersion: Int, visibilitySignature: String = "",
         bookTagsRevision: Int = 0) {
        // Encode group index, within-group conjunction, and sorted rules per group.
        // Two expressions with the same rules but different grouping must not share
        // a cache entry — (A OR B) AND C ≠ A OR (B AND C).
        let digest = expression.groups.enumerated().map { groupIndex, group in
            let rules = group.completeRules
                .map { "\($0.field.rawValue).\($0.op.rawValue).\($0.value)" }
                .sorted()
                .joined(separator: ",")
            return "g\(groupIndex)[\(group.conjunction.rawValue):\(rules)]"
        }.joined(separator: "|") + "|gc:\(expression.groupConjunction.rawValue)"
        self.expressionDigest = digest
        self.membershipVersion = membershipVersion
        self.visibilitySignature = visibilitySignature
        self.bookTagsRevision = bookTagsRevision
    }
}

// MARK: - §Phase3: Page/count cache keys

/// Everything that determines the full sorted id list for a view, i.e. a
/// `PageCacheKey` minus its paging window. Used by the in-memory sorted-id
/// cache so every page of one view reuses a single materialize-and-sort.
struct SortedIDsCacheKey: Hashable {
    let querySignature: String
    let filterSignature: String
    let tagExpansionsDigest: String
    let visibilityVersion: Int
    /// `LibraryVisibilityPolicy.cacheSignature` for the sorted-page functions that
    /// apply the policy inside `CalibreLibrary`; empty where the caller filters.
    let visibilitySignature: String
    let sortField: SortField
    let ascending: Bool
    let randomSeed: UInt64
}

/// Cache key for a page of hydrated CalibreBook results. Two calls that only
/// differ in one of these fields (offset, filter, query, sort, tag-expansion
/// resolution, or visibility/membership state) must NOT share a cache entry.
/// It contains a `SortedIDsCacheKey` rather than repeating its fields, so the
/// page key and the sorted-id key cannot drift apart.
struct PageCacheKey: Hashable {
    let sortedKey: SortedIDsCacheKey
    let offset: Int
    let limit: Int

    init(sortedKey: SortedIDsCacheKey, offset: Int, limit: Int) {
        self.sortedKey = sortedKey
        self.offset = offset
        self.limit = limit
    }

    init(querySignature: String, filterSignature: String, tagExpansionsDigest: String,
         visibilityVersion: Int, visibilitySignature: String, sortField: SortField,
         ascending: Bool, randomSeed: UInt64, offset: Int, limit: Int) {
        self.init(
            sortedKey: SortedIDsCacheKey(
                querySignature: querySignature,
                filterSignature: filterSignature,
                tagExpansionsDigest: tagExpansionsDigest,
                visibilityVersion: visibilityVersion,
                visibilitySignature: visibilitySignature,
                sortField: sortField,
                ascending: ascending,
                randomSeed: randomSeed
            ),
            offset: offset,
            limit: limit
        )
    }
}

/// Cache key for a bare count (no pagination, no hydration).
struct CountCacheKey: Hashable {
    let querySignature: String
    let filterSignature: String
    let tagExpansionsDigest: String
    let visibilityVersion: Int
}

/// Stable, order-independent digest of a resolved tag-synonym expansion
/// dictionary. Two dictionaries with the same keys/values in different
/// insertion order must produce the same digest.
func tagExpansionsDigest(_ expansions: [String: [String]]) -> String {
    expansions.keys.sorted().map { key in
        "\(key):[\((expansions[key] ?? []).sorted().joined(separator: ","))]"
    }.joined(separator: "|")
}

/// Cache key for `visibleBookCount` — the series-grouped, visibility-aware
/// total. Deliberately NOT `CountCacheKey`: that key's `visibilityVersion`
/// tracks membership changes (skip/like/series-cache) but does not change
/// when `hideNonAO3PublisherBooks`/`hideAnthologyBooks` are toggled, since
/// those are plain `ReaderPreferences` bools, not membership events. Reusing
/// `CountCacheKey` here would let a toggle flip return a stale cached count.
/// `PageCacheKey` and `FilterResultCacheKey` carry a `visibilitySignature` for the
/// same reason. `CountCacheKey` is unchanged: its counts do not depend on visibility.
struct GroupAwareCountCacheKey: Hashable {
    let querySignature: String
    let filterSignature: String
    let tagExpansionsDigest: String
    let visibilityVersion: Int
    let showSkippedCollection: Bool
    let hideNonAO3PublisherBooks: Bool
    let hideAnthologyBooks: Bool
    let hideDuplicateBooks: Bool
    let shouldGroupSeriesRows: Bool
}

/// A simple bounded LRU dictionary. The oldest-inserted entry is evicted when `limit` is reached.
/// Not thread-safe — must be accessed from a single actor (MainActor via LibrarySession).
struct LRUCache<Key: Hashable, Value> {
    private(set) var limit: Int
    private var store: [Key: Value] = [:]
    private var order: [Key] = []        // front = oldest, back = most recently inserted

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    subscript(key: Key) -> Value? {
        store[key]
    }

    /// Read that also refreshes recency, so eviction is least-recently-used
    /// rather than insertion-order. The plain subscript deliberately does not
    /// do this (see `LRUCacheTests`); use `get` for caches that want true LRU.
    mutating func get(_ key: Key) -> Value? {
        guard let value = store[key] else { return nil }
        if order.last != key {
            order.removeAll { $0 == key }
            order.append(key)
        }
        return value
    }

    mutating func set(_ value: Value, for key: Key) {
        if store[key] != nil {
            // Refresh: remove from current position, append to back
            order.removeAll { $0 == key }
        } else if store.count >= limit, let oldest = order.first {
            // Evict LRU
            store.removeValue(forKey: oldest)
            order.removeFirst()
        }
        store[key] = value
        order.append(key)
    }

    mutating func removeAll() {
        store.removeAll()
        order.removeAll()
    }

    var count: Int { store.count }
}
