import Foundation

/// Coordinates collection membership mutations and rapid toggle actions across all surfaces
/// (`ReaderWindowController`, `LibraryRootView`, `EmailLibraryViewController`), ensuring:
/// 1. Synchronous optimistic updates of `session.explicitLikedIDs` / `session.explicitReadLaterIDs`.
/// 2. Asynchronous persistence via one debounced batch per collection to prevent racing writes.
/// 3. Invalidation of collection-dependent filter caches.
/// 4. Execution of post-change UI refresh closures after rapid toggling settles.
@MainActor
enum CollectionAssignment {

    private(set) static var inFlightReadLaterIDs: Set<Int> = []
    private(set) static var inFlightLikedIDs: Set<Int> = []

    private static var readLaterDebounceTask: Task<Void, Never>?
    private static var likedDebounceTask: Task<Void, Never>?
    private static var pendingReadLaterIDs: Set<Int> = []
    private static var pendingLikedIDs: Set<Int> = []
    private static var pendingReadLaterRefresh: (() async -> Void)?
    private static var pendingLikedRefresh: (() async -> Void)?

    static func didAssign(session: LibrarySession, onRefresh: () -> Void) {
        session.bumpCollectionVersion()
        onRefresh()
    }

    /// Toggles the "Liked" state for the given calibre IDs optimistically and persists to the database.
    static func toggleLiked(
        calibreIDs: [Int],
        session: LibrarySession,
        onRefresh: (() async -> Void)? = nil
    ) {
        guard !calibreIDs.isEmpty else { return }
        let shouldLike = !calibreIDs.allSatisfy { session.explicitLikedIDs.contains($0) }
        if shouldLike {
            for id in calibreIDs { session.explicitLikedIDs.insert(id) }
        } else {
            for id in calibreIDs { session.explicitLikedIDs.remove(id) }
        }
        session.noteOptimisticCollectionMutation()

        pendingLikedIDs.formUnion(calibreIDs)
        inFlightLikedIDs.formUnion(calibreIDs)
        if let onRefresh { pendingLikedRefresh = onRefresh }
        likedDebounceTask?.cancel()
        likedDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }

            let ids = pendingLikedIDs
            pendingLikedIDs.subtract(ids)
            let refresh = pendingLikedRefresh
            pendingLikedRefresh = nil
            let states = Dictionary(uniqueKeysWithValues: ids.map { ($0, session.explicitLikedIDs.contains($0)) })
            try? await session.collectionStore?.setLiked(states: states)
            session.noteCollectionMutationPersisted()
            inFlightLikedIDs.subtract(ids.subtracting(pendingLikedIDs))
            await refresh?()
        }
    }

    /// Toggles the "Read Later" state for the given calibre IDs optimistically and persists to the database.
    static func toggleReadLater(
        calibreIDs: [Int],
        session: LibrarySession,
        onRefresh: (() async -> Void)? = nil
    ) {
        guard !calibreIDs.isEmpty else { return }
        let shouldAdd = !calibreIDs.allSatisfy { session.explicitReadLaterIDs.contains($0) }
        if shouldAdd {
            for id in calibreIDs { session.explicitReadLaterIDs.insert(id) }
        } else {
            for id in calibreIDs { session.explicitReadLaterIDs.remove(id) }
        }
        session.noteOptimisticCollectionMutation()

        pendingReadLaterIDs.formUnion(calibreIDs)
        inFlightReadLaterIDs.formUnion(calibreIDs)
        if let onRefresh { pendingReadLaterRefresh = onRefresh }
        readLaterDebounceTask?.cancel()
        readLaterDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }

            let ids = pendingReadLaterIDs
            pendingReadLaterIDs.subtract(ids)
            let refresh = pendingReadLaterRefresh
            pendingReadLaterRefresh = nil
            let states = Dictionary(uniqueKeysWithValues: ids.map { ($0, session.explicitReadLaterIDs.contains($0)) })
            try? await session.collectionStore?.setReadLater(states: states)
            session.noteCollectionMutationPersisted()
            inFlightReadLaterIDs.subtract(ids.subtracting(pendingReadLaterIDs))
            await refresh?()
        }
    }
}
