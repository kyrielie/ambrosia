import Foundation

/// Difference between a persisted collection membership and a freshly
/// computed one. Pure value type so the "did anything change" decision in
/// `LibrarySession.syncSeriesOrMergedCollection` is unit-testable without a
/// database.
struct MembershipDelta: Equatable {
    /// Ids in `computed` but not in `current`, ascending.
    let toAdd: [Int]
    /// Ids in `current` but not in `computed`, ascending.
    let toRemove: [Int]

    init(current: Set<Int>, computed: Set<Int>) {
        toAdd = computed.subtracting(current).sorted()
        toRemove = current.subtracting(computed).sorted()
    }

    /// True when applying the delta would change nothing.
    var isEmpty: Bool { toAdd.isEmpty && toRemove.isEmpty }
}
