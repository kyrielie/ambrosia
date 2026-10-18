// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The slice of `CalibreFTSLibrary` that `LibrarySession` uses to resolve `fulltext:`
/// phrases. It exists so session-level cache rules (never cache a failure, cancellation
/// handling) can be tested with a stub instead of a real `full-text-search.db`.
protocol FulltextSearching: Sendable {
    /// Starts a search and invalidates every earlier one (Invariant 24).
    func beginSearch() -> SearchToken
    func cancel(_ token: SearchToken)
    func searchBooks(_ query: FTSQuery, token: SearchToken) async throws -> FTSBookSet
}

extension CalibreFTSLibrary: FulltextSearching {}
