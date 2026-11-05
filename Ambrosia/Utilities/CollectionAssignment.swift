import Foundation

/// Coordinates collection membership mutations and rapid toggle actions across all surfaces
/// (`ReaderWindowController`, `LibraryRootView`, `EmailLibraryViewController`), ensuring:
/// 1. Synchronous optimistic updates of `session.cachedLikedIDs` / `session.cachedReadLaterIDs`.
/// 2. Asynchronous persistence via `CollectionStore` debounced per book to prevent racing writes.
/// 3. Invalidation of filter caches via `session.bumpMembershipVersion()`.
/// 4. Execution of post-change UI refresh closures after rapid toggling settles.
@MainActor
enum CollectionAssignment {

    private(set) static var inFlightReadLaterIDs: Set<Int> = []
    private(set) static var inFlightLikedIDs: Set<Int> = []

    private static var readLaterDebounceTasks: [Int: Task<Void, Never>] = [:]
    private static var likedDebounceTasks: [Int: Task<Void, Never>] = [:]

    static func didAssign(session: LibrarySession, onRefresh: () -> Void) {
        session.bumpMembershipVersion()
        onRefresh()
    }

    /// Toggles the "Liked" state for the given calibre IDs optimistically and persists to the database.
    static func toggleLiked(
        calibreIDs: [Int],
        session: LibrarySession,
        onRefresh: (() async -> Void)? = nil
    ) {
        guard !calibreIDs.isEmpty else { return }
        let shouldLike = !calibreIDs.allSatisfy { session.cachedLikedIDs.contains($0) }
        if shouldLike {
            for id in calibreIDs { session.cachedLikedIDs.insert(id) }
        } else {
            for id in calibreIDs { session.cachedLikedIDs.remove(id) }
        }

        for id in calibreIDs {
            inFlightLikedIDs.insert(id)
            likedDebounceTasks[id]?.cancel()
            likedDebounceTasks[id] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                let finalLiked = session.cachedLikedIDs.contains(id)
                try? await session.collectionStore?.setLiked(calibreIDs: [id], liked: finalLiked)
                inFlightLikedIDs.remove(id)
                likedDebounceTasks.removeValue(forKey: id)
                session.bumpMembershipVersion()
                if let onRefresh {
                    await onRefresh()
                }
            }
        }
    }

    /// Toggles the "Read Later" state for the given calibre IDs optimistically and persists to the database.
    static func toggleReadLater(
        calibreIDs: [Int],
        session: LibrarySession,
        onRefresh: (() async -> Void)? = nil
    ) {
        guard !calibreIDs.isEmpty else { return }
        let shouldAdd = !calibreIDs.allSatisfy { session.cachedReadLaterIDs.contains($0) }
        if shouldAdd {
            for id in calibreIDs { session.cachedReadLaterIDs.insert(id) }
        } else {
            for id in calibreIDs { session.cachedReadLaterIDs.remove(id) }
        }

        for id in calibreIDs {
            inFlightReadLaterIDs.insert(id)
            readLaterDebounceTasks[id]?.cancel()
            readLaterDebounceTasks[id] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                let finalReadLater = session.cachedReadLaterIDs.contains(id)
                try? await session.collectionStore?.setReadLater(calibreIDs: [id], inReadLater: finalReadLater)
                inFlightReadLaterIDs.remove(id)
                readLaterDebounceTasks.removeValue(forKey: id)
                session.bumpMembershipVersion()
                if let onRefresh {
                    await onRefresh()
                }
            }
        }
    }
}
