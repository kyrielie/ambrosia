import Foundation

/// Key for one tag-family rule's GLOBAL match set across `matchingIDs` calls.
/// `bookTagsRevision` is part of the key so an extraction pass that rewrote
/// `book_tags` makes every older entry unreachable.
struct RuleMatchCacheKey: Hashable {
    let rule: RuleMatchKey
    let bookTagsRevision: Int
}

/// Session-level cache of per-rule match sets (plan PR J). Makes
/// remove-then-add and non-adjacent chip edits cheap: a rule already evaluated
/// anywhere in the last few expressions is not queried again.
///
/// Only GLOBAL (unrestricted) match sets may be stored. A candidate-restricted
/// result is a subset of the global set and would silently corrupt later
/// lookups that read it as global, so `store` refuses it. The rule is enforced
/// by the `isGlobal` argument and a `Bool` return rather than an assertion,
/// because assertions are stripped in release builds.
///
/// Entries are kept as sorted `[Int]` (8 bytes per id, so at most about 19 MB
/// for 24 entries on a 100,000-book library; arithmetic, not measured), and
/// handed back as a `Set` for the builder's set algebra.
///
/// A class with a lock rather than an actor: `FilterBuilder` reads it from
/// off-main code and must not hop to the main actor per rule. It holds no
/// per-query state beyond the keyed entries.
final class RuleMatchCache: @unchecked Sendable {
    static let defaultLimit = 24

    private let lock = NSLock()
    private var cache: LRUCache<RuleMatchCacheKey, [Int]>

    init(limit: Int = RuleMatchCache.defaultLimit) {
        cache = LRUCache(limit: limit)
    }

    func members(for key: RuleMatchKey, revision: Int) -> Set<Int>? {
        lock.lock()
        defer { lock.unlock() }
        guard let ids = cache[RuleMatchCacheKey(rule: key, bookTagsRevision: revision)] else { return nil }
        return Set(ids)
    }

    /// Returns false, storing nothing, when `isGlobal` is false.
    @discardableResult
    func store(_ ids: Set<Int>, for key: RuleMatchKey, revision: Int, isGlobal: Bool) -> Bool {
        guard isGlobal else { return false }
        let sorted = ids.sorted()
        lock.lock()
        defer { lock.unlock() }
        cache.set(sorted, for: RuleMatchCacheKey(rule: key, bookTagsRevision: revision))
        return true
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }
}
