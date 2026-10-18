// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3

/// Generation counter plus the one off-actor touch of the SQLite handle: `sqlite3_interrupt`.
///
/// `Connection` is not `Sendable` in SQLite.swift 0.16.0, so the actor that owns it cannot
/// be interrupted from outside by calling the connection. This class holds the raw handle
/// behind a lock and only ever passes it to `sqlite3_interrupt`, which SQLite documents as
/// safe to call from a thread other than the one running the statement (Invariant 24).
///
/// The handle must be swapped out (`swap(handle:)`) before the connection it belongs to is
/// closed, otherwise `begin()` could interrupt freed memory.
final class SearchControl: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var handle: OpaquePointer?

    init(handle: OpaquePointer?) {
        self.handle = handle
    }

    /// Starts a new search: invalidates every earlier token and interrupts whatever
    /// statement is currently running on the connection.
    func begin() -> SearchToken {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        if let handle { sqlite3_interrupt(handle) }
        return SearchToken(generation: generation)
    }

    /// Cancels `token` if it is still the current search. No-op for stale tokens, so a
    /// late cancellation of an old search cannot abort a newer one.
    func cancel(_ token: SearchToken) {
        lock.lock()
        defer { lock.unlock() }
        guard token.generation == generation else { return }
        generation += 1
        if let handle { sqlite3_interrupt(handle) }
    }

    func isCurrent(_ token: SearchToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token.generation == generation
    }

    /// Replaces the interruptible handle (after the actor reopens the connection, or
    /// with nil just before closing it). Called only from the owning actor.
    func swap(handle newHandle: OpaquePointer?) {
        lock.lock()
        defer { lock.unlock() }
        handle = newHandle
    }
}
