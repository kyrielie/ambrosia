import Foundation

/// Counts down a batch of background tasks that each want the Series or
/// Merged sync to run, so only the last expected completion triggers it.
///
/// Extracted from `LibrarySession` so the rules are unit-testable:
/// - a completion carrying a stale generation (a newer `begin` superseded
///   its batch) never fires;
/// - exactly one completion per batch fires, even if extra completions
///   arrive after the count reaches zero.
struct SeriesSyncCoordinator {
    private(set) var generation = 0
    private var pending = 0

    /// Starts a new batch expecting `count` completions and returns its
    /// generation token. Any earlier batch becomes stale.
    mutating func begin(awaiting count: Int) -> Int {
        generation &+= 1
        pending = max(0, count)
        return generation
    }

    /// Records one completion. Returns true when the caller should run the
    /// sync now: the generation is current and this was the last expected
    /// completion.
    mutating func complete(generation: Int) -> Bool {
        guard generation == self.generation, pending > 0 else { return false }
        pending -= 1
        return pending == 0
    }

    /// True while `generation` has not been superseded by a newer `begin`.
    func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }
}
