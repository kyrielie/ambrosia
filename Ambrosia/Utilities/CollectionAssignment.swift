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
    private static var pendingSeriesActions: [String: [SeriesPressAction]] = [:]
    private static var pendingSeriesRefresh: [String: (() async -> Void)] = [:]
    private static var seriesActionTasks: [String: Task<Void, Never>] = [:]
    private(set) static var inFlightSeriesFlagKeys: Set<String> = []

    static func inFlightSeriesIDs(collectionID: String) -> Set<Int> {
        Set(inFlightSeriesFlagKeys.compactMap { key in
            guard key.hasPrefix(collectionID + "|") else { return nil }
            return Int(key.dropFirst(collectionID.count + 1))
        })
    }

    static func didAssign(session: LibrarySession, onRefresh: () -> Void) {
        session.bumpCollectionVersion()
        onRefresh()
    }

    // MARK: - Reading state and bulk removal (shared by the list and email views)

    /// Marks the books read: persists full progress, moves them to "Finished"
    /// and out of "In Progress", bumps the collection version, then calls `onFinished`.
    static func markRead(
        calibreIDs: [Int],
        session: LibrarySession,
        onFinished: @escaping () -> Void
    ) {
        Task { @MainActor in
            if let metaDB = session.metaDB {
                for calibreID in calibreIDs {
                    try? await metaDB.markBookRead(calibreID: calibreID)
                }
            }
            await syncReadingCollections(calibreIDs: calibreIDs, session: session, isFinished: true)
            session.bumpCollectionVersion()
            onFinished()
        }
    }

    /// Resets reading progress: clears stored position and progress, removes the
    /// books from both "Finished" and "In Progress", bumps the collection
    /// version, then calls `onFinished`.
    static func resetProgress(
        calibreIDs: [Int],
        session: LibrarySession,
        onFinished: @escaping () -> Void
    ) {
        Task { @MainActor in
            if let metaDB = session.metaDB {
                for calibreID in calibreIDs {
                    try? await metaDB.resetReadingProgress(calibreID: calibreID)
                }
            }
            await syncReadingCollections(calibreIDs: calibreIDs, session: session, isFinished: false)
            session.bumpCollectionVersion()
            onFinished()
        }
    }

    /// Removes the books from the collection with the given display name. Liked and
    /// Read Later are flag-backed, so they are cleared through `setWorkFlags`; every
    /// other collection uses `bulkRemove`. Does nothing if no collection has that
    /// name. `onRefresh` runs after the collection version bump.
    static func removeFromCollection(
        named collectionName: String,
        calibreIDs: [Int],
        session: LibrarySession,
        onRefresh: @escaping () async -> Void
    ) {
        Task { @MainActor in
            guard let collections = try? await session.collectionStore?.collections(),
                  let match = collections.first(where: { $0.name == collectionName }) else { return }
            if match.id == SystemCollectionID.liked || match.id == SystemCollectionID.readLater {
                _ = try? await session.collectionStore?.setWorkFlags(
                    collectionID: match.id,
                    desired: Dictionary(uniqueKeysWithValues: calibreIDs.map { ($0, false) })
                )
            } else {
                try? await session.collectionStore?.bulkRemove(calibreIDs: calibreIDs, from: match.id)
            }
            didAssign(session: session) {
                Task { await onRefresh() }
            }
        }
    }

    /// Syncs the automated "Finished" and "In Progress" collections after a
    /// reading-state change. "In Progress" membership is always cleared here.
    private static func syncReadingCollections(
        calibreIDs: [Int],
        session: LibrarySession,
        isFinished: Bool
    ) async {
        for calibreID in calibreIDs {
            try? await session.collectionStore?.syncAutomatedCollection(
                collectionID: SystemCollectionID.finished,
                calibreID: calibreID,
                shouldBeMember: isFinished
            )
            try? await session.collectionStore?.syncAutomatedCollection(
                collectionID: SystemCollectionID.inProgress,
                calibreID: calibreID,
                shouldBeMember: false
            )
        }
    }

    /// Toggles the "Liked" state for the given calibre IDs optimistically and persists to the database.
    static func toggleLiked(
        calibreIDs: [Int],
        session: LibrarySession,
        onRefresh: (() async -> Void)? = nil
    ) {
        guard !calibreIDs.isEmpty else { return }
        let shouldLike = !calibreIDs.allSatisfy { session.effectiveLikedIDs.contains($0) }
        for id in calibreIDs {
            if shouldLike {
                if !session.effectiveLikedIDs.contains(id) { session.explicitLikedIDs.insert(id) }
                session.effectiveLikedIDs.insert(id)
            } else {
                session.explicitLikedIDs.remove(id)
                session.effectiveLikedIDs.remove(id)
            }
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
            let states = Dictionary(uniqueKeysWithValues: ids.map { ($0, session.effectiveLikedIDs.contains($0)) })
            _ = try? await session.collectionStore?.setWorkFlags(collectionID: SystemCollectionID.liked, desired: states)
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
        let shouldAdd = !calibreIDs.allSatisfy { session.effectiveReadLaterIDs.contains($0) }
        for id in calibreIDs {
            if shouldAdd {
                if !session.effectiveReadLaterIDs.contains(id) { session.explicitReadLaterIDs.insert(id) }
                session.effectiveReadLaterIDs.insert(id)
            } else {
                session.explicitReadLaterIDs.remove(id)
                session.effectiveReadLaterIDs.remove(id)
            }
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
            let states = Dictionary(uniqueKeysWithValues: ids.map { ($0, session.effectiveReadLaterIDs.contains($0)) })
            _ = try? await session.collectionStore?.setWorkFlags(collectionID: SystemCollectionID.readLater, desired: states)
            session.noteCollectionMutationPersisted()
            inFlightReadLaterIDs.subtract(ids.subtracting(pendingReadLaterIDs))
            await refresh?()
        }
    }

    static func toggleLiked(series: SeriesGroup, session: LibrarySession,
                            onRefresh: (() async -> Void)? = nil) {
        toggleSeriesFlag(series: series, collectionID: SystemCollectionID.liked, session: session, onRefresh: onRefresh)
    }

    static func toggleReadLater(series: SeriesGroup, session: LibrarySession,
                                onRefresh: (() async -> Void)? = nil) {
        toggleSeriesFlag(series: series, collectionID: SystemCollectionID.readLater, session: session, onRefresh: onRefresh)
    }

    private static func toggleSeriesFlag(series: SeriesGroup, collectionID: String,
                                         session: LibrarySession,
                                         onRefresh: (() async -> Void)?) {
        guard series.isFlaggable, let seriesID = series.seriesID else { return }
        var flags = collectionID == SystemCollectionID.readLater ? session.readLaterSeriesFlags : session.likedSeriesFlags
        let currentFlag = flags[seriesID]
        var covering: [Int: String] = [:]
        for (otherID, flag) in flags where otherID != seriesID {
            for memberID in flag.memberIDs where !flag.exclusions.contains(memberID) {
                covering[memberID] = flag.seriesName
            }
        }
        let memberIDs = Set(series.works.map(\.id))
        let effective = collectionID == SystemCollectionID.readLater ? session.effectiveReadLaterIDs : session.effectiveLikedIDs
        let explicit = collectionID == SystemCollectionID.readLater ? session.explicitReadLaterIDs : session.explicitLikedIDs
        let plan = SeriesPressPlanner.plan(
            flagIsSet: currentFlag != nil,
            exclusions: currentFlag?.exclusions ?? [],
            displayedMemberIDs: memberIDs,
            effectiveIDs: effective,
            explicitIDs: explicit,
            coveringSeriesByMember: covering
        )
        guard !plan.actions.isEmpty else { return }
        for action in plan.actions {
            switch action {
            case .clearExclusions:
                if let flag = flags[seriesID] {
                    flags[seriesID] = SeriesCollectionFlag(seriesID: seriesID, seriesName: flag.seriesName,
                                                          memberIDs: flag.memberIDs, exclusions: [])
                }
            case .clearFlag:
                flags[seriesID] = nil
            case .clearExplicit(let ids):
                if collectionID == SystemCollectionID.readLater {
                    session.explicitReadLaterIDs.subtract(ids)
                } else {
                    session.explicitLikedIDs.subtract(ids)
                }
            case .setFlag:
                flags[seriesID] = SeriesCollectionFlag(seriesID: seriesID, seriesName: series.seriesName,
                                                      memberIDs: memberIDs, exclusions: [])
            }
        }
        if collectionID == SystemCollectionID.readLater {
            session.readLaterSeriesFlags = flags
        } else {
            session.likedSeriesFlags = flags
        }
        session.recomputeEffectiveFlags(collectionID: collectionID, calibreIDs: memberIDs)
        session.noteOptimisticCollectionMutation()

        let queueKey = "\(collectionID)|\(seriesID)"
        pendingSeriesActions[queueKey, default: []].append(contentsOf: plan.actions)
        inFlightSeriesFlagKeys.insert(queueKey)
        if let onRefresh { pendingSeriesRefresh[queueKey] = onRefresh }
        guard seriesActionTasks[queueKey] == nil else { return }
        seriesActionTasks[queueKey] = Task { @MainActor in
            while !Task.isCancelled {
                await Task.yield()
                let actions = pendingSeriesActions.removeValue(forKey: queueKey) ?? []
                if actions.isEmpty { break }
                let refresh = pendingSeriesRefresh[queueKey]
                _ = try? await session.collectionStore?.applySeriesActions(
                    collectionID: collectionID, seriesID: seriesID, actions: actions
                )
                session.noteCollectionMutationPersisted()
                await refresh?()
            }
            seriesActionTasks[queueKey] = nil
            pendingSeriesRefresh[queueKey] = nil
            inFlightSeriesFlagKeys.remove(queueKey)
        }
    }
}
