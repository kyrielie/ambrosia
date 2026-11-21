import Foundation
import os

/// Thread-safe holder for immutable suggestion snapshots with generation-guarded publishing.
public final class SuggestionStore: Sendable {

    private struct State: Sendable {
        var generation: Int = 0
        var tags: SuggestionSnapshot?
        var authors: SuggestionSnapshot?
        var series: SuggestionSnapshot?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Current generation token.
    public var currentGeneration: Int {
        lock.withLock { $0.generation }
    }

    /// Increments and returns the new generation token, invalidating any pending background builds.
    @discardableResult
    public func invalidate() -> Int {
        lock.withLock { state in
            state.generation += 1
            return state.generation
        }
    }

    /// Publishes newly built snapshots if and only if the generation is still current.
    /// Returns true if published, false if dropped due to a newer generation.
    @discardableResult
    public func publish(
        tags: SuggestionSnapshot?,
        authors: SuggestionSnapshot?,
        series: SuggestionSnapshot?,
        generation: Int
    ) -> Bool {
        lock.withLock { state in
            guard state.generation == generation else {
                return false
            }
            state.tags = tags
            state.authors = authors
            state.series = series
            return true
        }
    }

    /// Returns the active tag suggestions snapshot, or nil if not yet warmed.
    public var tagSnapshot: SuggestionSnapshot? {
        lock.withLock { $0.tags }
    }

    /// Returns the active author suggestions snapshot, or nil if not yet warmed.
    public var authorSnapshot: SuggestionSnapshot? {
        lock.withLock { $0.authors }
    }

    /// Returns the active series suggestions snapshot, or nil if not yet warmed.
    public var seriesSnapshot: SuggestionSnapshot? {
        lock.withLock { $0.series }
    }
}
