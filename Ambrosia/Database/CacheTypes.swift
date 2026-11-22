import CryptoKit
import Foundation

// MARK: - Query Digest Builder

/// Builds a stable, collision-resistant 12-byte hex digest of all query, filter,
/// term-scoping, tag-expansion, restrict-IDs, and relevance-ranking inputs.
/// Precomputed once per `PageQuery` and carried across page requests.
enum QueryDigestBuilder {
    static func digest(
        query: SearchQuery,
        filter: FilterExpression? = nil,
        restrictIDs: [Int]? = nil,
        filterTagExpansions: [String: [String]] = [:],
        rankedIDs: [Int]? = nil,
        relevanceTargets: TagRelevanceTargets = .init(),
        rankedIDsAreOrdered: Bool = true
    ) -> String {
        var hasher = SHA256()

        if !query.plainTerms.isEmpty {
            hasher.update(data: Data("plain:\(query.plainTerms.joined(separator: "\u{1F}"))\n".utf8))
        }

        for (index, term) in query.tagTerms.enumerated() {
            let mode = query.scopedTagTerms.indices.contains(index) ? query.scopedTagTerms[index].mode.rawValue : "contains"
            hasher.update(data: Data("tag:\(mode):\(term)\n".utf8))
        }
        for (key, exps) in query.expandedTagTerms.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data("qTagExp:\(key):\(exps.sorted().joined(separator: ","))\n".utf8))
        }
        for (key, exps) in filterTagExpansions.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data("fTagExp:\(key):\(exps.sorted().joined(separator: ","))\n".utf8))
        }

        for (index, term) in query.authorTerms.enumerated() {
            let mode = query.scopedAuthorTerms.indices.contains(index) ? query.scopedAuthorTerms[index].mode.rawValue : "contains"
            hasher.update(data: Data("author:\(mode):\(term)\n".utf8))
        }

        for (index, term) in query.titleTerms.enumerated() {
            let mode = query.scopedTitleTerms.indices.contains(index) ? query.scopedTitleTerms[index].mode.rawValue : "contains"
            hasher.update(data: Data("title:\(mode):\(term)\n".utf8))
        }

        for (index, term) in query.seriesTerms.enumerated() {
            let mode = query.scopedSeriesTerms.indices.contains(index) ? query.scopedSeriesTerms[index].mode.rawValue : "contains"
            hasher.update(data: Data("series:\(mode):\(term)\n".utf8))
        }

        if let ftsIDs = query.ftsMatchedIDs {
            hasher.update(data: Data("fts:\(ftsIDs.map(String.init).joined(separator: ","))\n".utf8))
        }

        if let rIDs = restrictIDs {
            hasher.update(data: Data("restrict:\(rIDs.map(String.init).joined(separator: ","))\n".utf8))
        }

        if let filter = filter {
            hasher.update(data: Data("filter:\(LibraryFilterDebug.summary(expression: filter))\n".utf8))
        }

        let effectiveRanked = rankedIDs ?? query.ftsMatchedIDs
        if let ranked = effectiveRanked {
            hasher.update(data: Data("ranked:\(ranked.map(String.init).joined(separator: ","))\n".utf8))
        }

        if !relevanceTargets.isEmpty {
            let exactPart = relevanceTargets.exact.joined(separator: ",")
            let containsPart = relevanceTargets.contains.joined(separator: ",")
            hasher.update(data: Data("relTargets:exact:\(exactPart)|contains:\(containsPart)\n".utf8))
        }
        hasher.update(data: Data("rankedOrdered:\(rankedIDsAreOrdered)\n".utf8))

        let result = hasher.finalize()
        return result.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - LRU cache key

/// Cache key for a FilterResult: the serialised expression + visibility and pinned
/// collection versions. The cached ID lists also have the
/// four visibility preferences applied, so `visibilitySignature` is part of the key:
/// toggling a preference changes no membership set, and stripped books cannot be
/// restored from a list that already lacks them. `bookTagsRevision` ties a cached
/// tag result to the `book_tags` contents it was computed from, so an AO3
/// extraction pass invalidates it.
struct FilterResultCacheKey: Hashable {
    let expressionDigest: String    // serialised rule descriptions (stable, cheap)
    let visibilityVersion: Int
    let pinnedCollectionVersion: Int
    let visibilitySignature: String
    let bookTagsRevision: Int
}

extension FilterResultCacheKey {
    init(expression: FilterExpression, visibilityVersion: Int, pinnedCollectionVersion: Int,
         visibilitySignature: String = "", bookTagsRevision: Int = 0) {
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
        self.visibilityVersion = visibilityVersion
        self.pinnedCollectionVersion = pinnedCollectionVersion
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
    var pinnedCollectionVersion: Int = 0
    /// `LibraryVisibilityPolicy.cacheSignature` for the sorted-page functions that
    /// apply the policy inside `CalibreLibrary`; empty where the caller filters.
    let visibilitySignature: String
    let sortField: SortField
    let ascending: Bool
    let randomSeed: UInt64
    let queryDigest: String

    init(
        querySignature: String,
        filterSignature: String,
        tagExpansionsDigest: String,
        visibilityVersion: Int,
        pinnedCollectionVersion: Int = 0,
        visibilitySignature: String,
        sortField: SortField,
        ascending: Bool,
        randomSeed: UInt64,
        queryDigest: String = ""
    ) {
        self.querySignature = querySignature
        self.filterSignature = filterSignature
        self.tagExpansionsDigest = tagExpansionsDigest
        self.visibilityVersion = visibilityVersion
        self.pinnedCollectionVersion = pinnedCollectionVersion
        self.visibilitySignature = visibilitySignature
        self.sortField = sortField
        self.ascending = ascending
        // Non-random sorts ignore reshuffle; seed is zeroed so dead entries are not stranded.
        self.randomSeed = (sortField == .random) ? randomSeed : 0
        self.queryDigest = queryDigest
    }
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
         visibilityVersion: Int, pinnedCollectionVersion: Int = 0,
         visibilitySignature: String, sortField: SortField,
         ascending: Bool, randomSeed: UInt64, queryDigest: String = "", offset: Int, limit: Int) {
        self.init(
            sortedKey: SortedIDsCacheKey(
                querySignature: querySignature,
                filterSignature: filterSignature,
                tagExpansionsDigest: tagExpansionsDigest,
                visibilityVersion: visibilityVersion,
                pinnedCollectionVersion: pinnedCollectionVersion,
                visibilitySignature: visibilitySignature,
                sortField: sortField,
                ascending: ascending,
                randomSeed: randomSeed,
                queryDigest: queryDigest
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
    var pinnedCollectionVersion: Int = 0
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
    var pinnedCollectionVersion: Int = 0
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
