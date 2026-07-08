import Foundation

// MARK: - LRU cache key

/// Cache key for a FilterResult: the serialised expression + membership version.
/// Two calls with identical filter rules but different membership states (e.g. the user
/// just liked a book) must NOT share a cache entry.
struct FilterResultCacheKey: Hashable {
    let expressionDigest: String    // serialised rule descriptions (stable, cheap)
    let membershipVersion: Int
}

extension FilterResultCacheKey {
    init(expression: FilterExpression, membershipVersion: Int) {
        // Encode group index, within-group conjunction, and sorted rules per group.
        // Two expressions with the same rules but different grouping must not share
        // a cache entry — (A OR B) AND C ≠ A OR (B AND C).
        let digest = expression.groups.enumerated().map { (i, group) in
            let rules = group.completeRules
                .map { "\($0.field.rawValue).\($0.op.rawValue).\($0.value)" }
                .sorted()
                .joined(separator: ",")
            return "g\(i)[\(group.conjunction.rawValue):\(rules)]"
        }.joined(separator: "|") + "|gc:\(expression.groupConjunction.rawValue)"
        self.expressionDigest = digest
        self.membershipVersion = membershipVersion
    }
}

// MARK: - §Phase3: Page/count cache keys

/// Cache key for a page of hydrated CalibreBook results. Two calls that only
/// differ in one of these fields (offset, filter, query, sort, tag-expansion
/// resolution, or visibility/membership state) must NOT share a cache entry.
struct PageCacheKey: Hashable {
    let querySignature: String
    let filterSignature: String
    let tagExpansionsDigest: String
    let visibilityVersion: Int
    let sortField: SortField
    let ascending: Bool
    let randomSeed: UInt64
    let offset: Int
    let limit: Int
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

// MARK: - LRU container

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
        get { store[key] }
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
