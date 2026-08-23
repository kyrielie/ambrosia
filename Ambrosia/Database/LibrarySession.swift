import Foundation
import Observation
import SwiftData

extension Notification.Name {
    static let seriesOrMergedCollectionDidChange = Notification.Name("Ambrosia.seriesOrMergedCollectionDidChange")
}

/// Holds the active CalibreLibrary connection for the current session.
/// Opened when the user picks a folder or on launch if a path was saved.
/// Replaced wholesale when the user switches libraries — no import, no sync.
///
/// Injected into the SwiftUI environment so all views share one instance.
@Observable
@MainActor
final class LibrarySession {

    /// The open library connection. Nil until the user picks a folder.
    private(set) var library: CalibreLibrary?

    /// Optional full-text-search connection. Nil if full-text-search.db doesn't exist.
    private(set) var ftsLibrary: CalibreFTSLibrary?

    /// Per-library app-owned SQLite database for collections and annotations.
    private(set) var metaDB: AmbrosiaMetaDB?

    let extractionProgress = ExtractionProgress()

    /// Typed collection operations for the active library.
    private(set) var collectionStore: CollectionStore?

    // §4: Local RSS feed server. nil when disabled in Preferences (off by default).
    private(set) var feedServer: LocalFeedServer?

    /// Set once from `AmbrosiaApp.init()` alongside `appDelegate.modelContainer`.
    /// Not library-scoped (unlike `metaDB`/`collectionStore`) — the SwiftData
    /// store is shared across every Calibre library the app opens, so this
    /// doesn't need to be replaced on a library switch the way those are.
    /// Needed by the Phase 2 `.sqlite` feed route to read `BookState.
    /// totalReadPercent` for the wire schema's `reading_progress` column;
    /// `LocalFeedServer` has no other path to a `ModelContainer` (see
    /// docs/ambrosia-feed-transfer-phase0-findings.md).
    var modelContainer: ModelContainer?

    /// Cached total book count from metadata.db. Refreshed on library open
    /// and on search input (debounced). Never recomputed on page turns.
    private(set) var totalCount: Int = 0

    // MARK: - Collection membership cache
    //
    // Survives view mode switches (list ↔ email ↔ history). The library view
    // initialises its local @State directly from these so the first render
    // uses correct membership data and no flash occurs. Written back by the
    // view after each async refresh. Cleared on library open/close.
    var cachedLikedIDs: Set<Int> = []
    var cachedSkippedIDs: Set<Int> = []
    var cachedSeriesOrMergedIDs: Set<Int> = []
    var cachedAO3PublisherIDs: Set<Int> = []
    var cachedReadLaterIDs: Set<Int> = []
    var cachedAnthologyIDs: Set<Int> = []

    /// Non-winning calibre IDs of any AO3-work duplicate group (see
    /// `DuplicateBookDetector`). Computed inside `CalibreLibrary` whenever
    /// `refreshAO3MetaCaches()` runs (library open, after AO3 extraction
    /// batches); mirrored into `refreshCollectionSnapshots()` below so it
    /// participates in the same "did visibility change" diff as the other
    /// five sets.
    var cachedDuplicateLoserIDs: Set<Int> = []

    /// The path of the currently open library.
    private(set) var activePath: String?

    /// Name-keyed collection membership, mirroring what each view used to
    /// build itself from `collectionStore.collections()` +
    /// `membershipByCollectionID()`. Populated by `refreshCollectionSnapshots()`.
    var collectionMembershipByName: [String: Set<Int>] = [:]

    /// §Phase1: Single source of truth for the six visibility ID sets.
    /// Replaces the two independent per-surface refresh functions previously
    /// duplicated in LibraryRootView (`refreshBookStates()`) and
    /// EmailLibraryViewController (`refreshCollectionSnapshots()`), of which
    /// only the former reliably wrote all six `cachedX` sets back here — the
    /// latter only wrote `cachedAnthologyIDs`. Diffs against the previous
    /// cached values and bumps `membershipVersion` exactly once if anything
    /// actually changed, so callers can rely on `membershipVersion` as an
    /// accurate "did visibility change" signal instead of calling
    /// `bumpMembershipVersion()` themselves after this returns.
    func refreshCollectionSnapshots() async {
        guard let collectionStore else { return }
        let collections = (try? await collectionStore.collections()) ?? []
        let membershipByID = (try? await collectionStore.membershipByCollectionID()) ?? [:]
        let currentLiked = (try? await collectionStore.likedIDs()) ?? []
        let currentReadLater = Set((try? await collectionStore.members(of: SystemCollectionID.readLater)) ?? [])
        let currentSkipped = membershipByID[SystemCollectionID.skipped] ?? []
        let currentSeriesOrMerged = membershipByID[SystemCollectionID.seriesOrMerged] ?? []
        let currentAO3PublisherIDs = await library?.ao3PublisherBookIDs() ?? []
        let currentAnthologyIDs = await library?.anthologyBookIDs() ?? []
        let currentDuplicateLoserIDs = await library?.duplicateLoserBookIDs() ?? []

        let changed = cachedLikedIDs != currentLiked
            || cachedReadLaterIDs != currentReadLater
            || cachedSkippedIDs != currentSkipped
            || cachedSeriesOrMergedIDs != currentSeriesOrMerged
            || cachedAO3PublisherIDs != currentAO3PublisherIDs
            || cachedAnthologyIDs != currentAnthologyIDs
            || cachedDuplicateLoserIDs != currentDuplicateLoserIDs

        cachedLikedIDs = currentLiked
        cachedReadLaterIDs = currentReadLater
        cachedSkippedIDs = currentSkipped
        cachedSeriesOrMergedIDs = currentSeriesOrMerged
        cachedAO3PublisherIDs = currentAO3PublisherIDs
        cachedAnthologyIDs = currentAnthologyIDs
        cachedDuplicateLoserIDs = currentDuplicateLoserIDs

        collectionMembershipByName = Dictionary(uniqueKeysWithValues: collections.map { collection in
            (collection.name, membershipByID[collection.id] ?? [])
        })

        if changed {
            bumpMembershipVersion()
        }
    }

    /// True while a library is open and ready to query.
    var isOpen: Bool { library != nil }

    /// Error from the last open attempt, shown in the UI if non-nil.
    private(set) var lastError: String?

    /// §6.2: pulls `CalibreLibrary.lastSearchError` (set on a `bookCount` query
    /// failure) into `lastError` so it's observable in the UI. Cross-actor by
    /// necessity: `CalibreLibrary` is a separate actor and cannot mutate this
    /// `@MainActor` property directly, so the caller (a search/count call site)
    /// awaits this after the count call rather than `CalibreLibrary` reaching
    /// out on its own. Minimum-viable per Phase 6.2 of the gap closure plan:
    /// this can overwrite an unrelated `lastError` (e.g. from library open) if
    /// both happen to be set; a full solution would give search errors their
    /// own observable property instead of sharing this one.
    func refreshLastSearchError() async {
        guard let library, let message = await library.lastSearchError else { return }
        lastError = message
    }

    private var extractionTask: Task<Void, Never>?
    private var resolvedFulltextCache: [String: [Int]] = [:]
    private let resolvedFulltextCacheLimit = 12

    // §7: True LRU cache for FilterResult (limit 8).
    var filterResultCache = LRUCache<FilterResultCacheKey, FilterResult>(limit: 8)

    // §7: Membership version — bump after any liked/skipped/status change to
    // invalidate stale filter-result cache entries keyed on an older version.
    var membershipVersion: Int = 0

    // §7: Insertion-order tracker for correct LRU eviction of the fulltext cache.
    // The old implementation used .keys.first which picks an arbitrary hash bucket.
    var resolvedFulltextCacheOrder: [String] = []

    // startAO3Extraction() and seedCalibreSeriesCache() each independently used
    // to call syncSeriesOrMergedCollection() on completion. Since open() and
    // reextractAO3Metadata() kick both off concurrently, that meant the
    // "Series or Merged" membership sync — and the reload/scroll-reset it
    // triggers in LibraryRootView/EmailLibraryViewController via
    // .seriesOrMergedCollectionDidChange — ran twice per library open. These
    // two properties coordinate so only the last of a batch of expected
    // completions actually performs the sync.
    private var seriesSyncGeneration = 0
    private var seriesSyncPending = 0

    /// Call once, on MainActor, before kicking off `count` background tasks
    /// that will each eventually want `syncSeriesOrMergedCollection()` to run.
    /// Returns a generation token to pass to `completeCoordinatedSeriesSync`.
    private func beginCoordinatedSeriesSync(awaiting count: Int) -> Int {
        seriesSyncGeneration &+= 1
        seriesSyncPending = count
        return seriesSyncGeneration
    }

    /// Call from each of the `count` tasks on completion. Only the call that
    /// brings the pending count to zero actually runs the sync. A generation
    /// mismatch means a newer open()/reextractAO3Metadata() superseded this
    /// batch — in that case this completion is stale and does nothing.
    private func completeCoordinatedSeriesSync(generation: Int) async {
        guard generation == seriesSyncGeneration else { return }
        seriesSyncPending -= 1
        guard seriesSyncPending <= 0 else { return }
        await syncSeriesOrMergedCollection()
    }

    // MARK: - Opening / closing

    /// Open a Calibre library at the given URL.
    func open(url: URL) async {
        lastError = nil
        do {
            let newLibrary = try CalibreLibrary(root: url)
            let newMetaDB = try AmbrosiaMetaDB(libraryURL: url)
            library    = newLibrary
            metaDB = newMetaDB
            collectionStore = CollectionStore(db: newMetaDB)
            activePath = url.path
            totalCount = await newLibrary.bookCount()
            ftsLibrary = CalibreFTSLibrary(libraryURL: url)
            resolvedFulltextCache.removeAll()
            resolvedFulltextCacheOrder.removeAll()           // §7
            filterResultCache.removeAll()                    // §7
            membershipVersion = 0                            // §7
            cachedLikedIDs = []
            cachedSkippedIDs = []
            cachedSeriesOrMergedIDs = []
            cachedAO3PublisherIDs = []
            cachedReadLaterIDs = []
            cachedAnthologyIDs = []
            cachedDuplicateLoserIDs = []
            LibraryRegistry.shared.register(url)
            LibraryIndexManager.shared.record(url: url)
            importAO3TagSeeds()
            let seriesSyncGen = beginCoordinatedSeriesSync(awaiting: 2)
            startAO3Extraction(seriesSyncGeneration: seriesSyncGen)
            seedCalibreSeriesCache(seriesSyncGeneration: seriesSyncGen)
            refreshAO3MetaCaches()
            // Load persisted search history for this library.
            SearchActivityLog.shared.load(libraryHash: Ambrosia.libraryHash(for: url))
            // Re-point the per-library feed prefs (excluded collections, daily
            // story toggle) at this library before anything reads them.
            ReaderPreferences.shared.reloadFeedPrefs(forLibraryHash: Ambrosia.libraryHash(for: url))
            if let server = feedServer, let cs = collectionStore {
                // Server object already exists (survived a library switch,
                // not a relaunch) — just repoint it at the new library.
                Task { await server.updateLibrary(newLibrary, metaDB: newMetaDB, collectionStore: cs) }
            } else {
                // No server running yet this session — if one was running for
                // *this* library when the app last quit, and the user opted
                // into auto-restart, bring it back now.
                autoRestartFeedServerIfNeeded(path: url.path)
            }
            #if DEBUG
            print("[LibrarySession] Opened \(url.lastPathComponent) — \(totalCount) books")
            #endif
        } catch {
            lastError = "Could not open library: \(error.localizedDescription)"
            #if DEBUG
            print("[LibrarySession] Open failed: \(error)")
            #endif
        }
    }

    /// Bulk-refreshes `CalibreLibrary`'s AO3 word-count/date/crossover caches
    /// from `AmbrosiaMetaDB`. Called on open and after AO3 extraction
    /// completes. `AmbrosiaMetaDB` remains the sole owner of reads against
    /// ambrosia_meta.db (Invariant 10); `CalibreLibrary` only ever sees the
    /// results pushed in here.
    private func refreshAO3MetaCaches() {
        guard let library, let metaDB else { return }
        Task { [weak self] in
            async let wordCounts = metaDB.allAO3WordCounts()
            async let kudos = metaDB.allAO3Kudos()
            async let dates = metaDB.allAO3Dates()
            async let crossoverIDs = metaDB.allCrossoverBookIDs()
            async let workIDs = metaDB.allAO3WorkIDs()
            let resolvedWordCounts = await wordCounts
            let resolvedKudos = await kudos
            let resolvedDates = await dates
            let resolvedCrossoverIDs = await crossoverIDs
            let resolvedWorkIDs = await workIDs
            // This Task was created from a MainActor context and is not detached,
            // so it already runs on the MainActor — no MainActor.run hop needed.
            // `library` is a separate actor now, so the call into it still needs `await`.
            guard self?.library === library else { return }
            await library.updateAO3MetaCaches(
                wordCounts: resolvedWordCounts,
                kudos: resolvedKudos,
                dates: resolvedDates,
                crossoverIDs: resolvedCrossoverIDs,
                workIDs: resolvedWorkIDs
            )
            // `duplicateLoserIDCache` was just recomputed inside the actor from
            // the freshly-fetched work IDs/dates — mirror it into
            // `cachedDuplicateLoserIDs` now rather than waiting for the next
            // unrelated `refreshCollectionSnapshots()` call (e.g. after a
            // like/skip toggle) to happen to pick it up.
            await self?.refreshCollectionSnapshots()
        }
    }

    func close() {
        extractionTask?.cancel()
        extractionTask = nil
        extractionProgress.isRunning = false
        extractionProgress.completed = 0
        extractionProgress.total = 0
        library    = nil
        ftsLibrary = nil
        metaDB = nil
        collectionStore = nil
        totalCount = 0
        if let path = activePath {
            SearchActivityLog.shared.clear(libraryHash: Ambrosia.libraryHash(for: URL(fileURLWithPath: path)))
        } else {
            SearchActivityLog.shared.discardWithoutPersisting()
        }
        activePath = nil
        ReaderPreferences.shared.reloadFeedPrefs(forLibraryHash: nil)
        resolvedFulltextCache.removeAll()
        resolvedFulltextCacheOrder.removeAll()           // §7
        filterResultCache.removeAll()                    // §7
        membershipVersion = 0                            // §7
        cachedLikedIDs = []
        cachedSkippedIDs = []
        cachedSeriesOrMergedIDs = []
        cachedReadLaterIDs = []
        cachedAO3PublisherIDs = []
        cachedAnthologyIDs = []
        cachedDuplicateLoserIDs = []
        stopFeedServer()                                     // §4
    }

    /// Cancels the AO3 extraction task without the rest of close()'s teardown
    /// (library/metaDB/caches). Task cancellation is a cheap, synchronous flag
    /// set — safe to call from applicationWillTerminate, unlike close() as a
    /// whole. Does not flush pendingSuccess/pendingFailure/pendingIndexed; any
    /// work not yet flushed to the DB is simply re-attempted on next launch,
    /// since `missing` in startAO3Extraction is always recomputed from what's
    /// actually stored.
    func cancelExtractionTaskIfRunning() {
        extractionTask?.cancel()
    }

    // MARK: - Count refresh

    func refreshCount(query: SearchQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])) async {
        guard let library else { return }
        if query.isEmpty {
            totalCount = await library.bookCount()
        } else {
            totalCount = await library.bookCount(query: query)
        }
    }

    // MARK: - FTS resolution

    func cachedFulltextIDs(for phrase: String) -> [Int]? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return resolvedFulltextCache[fulltextCacheKey(trimmed)]
    }

    func resolveFulltextIDs(for phrase: String) async -> [Int] {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let key = fulltextCacheKey(trimmed)
        if let cachedIDs = resolvedFulltextCache[key] {
            return cachedIDs
        }
        guard let fts = ftsLibrary else {
            #if DEBUG
            print("[LibrarySession] fulltext search unavailable for phrase=\"\(trimmed)\"")
            #endif
            return []
        }
        let limit = max(await library?.bookCount() ?? 0, 1)
        let ids = await fts.search(query: trimmed, limit: limit) ?? []
        if ids.isEmpty {
            #if DEBUG
            print("[LibrarySession] fulltext search returned no matches for phrase=\"\(trimmed)\"")
            #endif
        }
        rememberResolvedFulltext(ids: ids, key: key)
        return ids
    }

    /// Attempts FTS resolution for explicit fulltext only.
    /// Shared between list view and email view — single source of truth.
    func resolvedQuery(_ query: SearchQuery) async -> SearchQuery {
        guard let phrase = query.fulltextPhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phrase.isEmpty else {
            return query
        }
        let cacheKey = fulltextCacheKey(phrase)
        if let cachedIDs = resolvedFulltextCache[cacheKey] {
            return SearchQuery(
                tagTerms: query.tagTerms,
                authorTerms: query.authorTerms,
                titleTerms: query.titleTerms,
                seriesTerms: query.seriesTerms,
                statusTerms: query.statusTerms,
                fulltextPhrase: query.fulltextPhrase,
                plainTerms: [],
                ftsMatchedIDs: cachedIDs
            )
        }
        guard let fts = ftsLibrary else {
            #if DEBUG
            print("[LibrarySession] fulltext search unavailable for phrase=\"\(phrase)\"")
            #endif
            return SearchQuery(
                tagTerms: query.tagTerms,
                authorTerms: query.authorTerms,
                titleTerms: query.titleTerms,
                seriesTerms: query.seriesTerms,
                statusTerms: query.statusTerms,
                fulltextPhrase: query.fulltextPhrase,
                plainTerms: [],
                ftsMatchedIDs: []
            )
        }
        guard let ftsIDs = await fts.search(query: phrase), !ftsIDs.isEmpty else {
            #if DEBUG
            print("[LibrarySession] fulltext search returned no matches for phrase=\"\(phrase)\"")
            #endif
            rememberResolvedFulltext(ids: [], key: cacheKey)
            return SearchQuery(
                tagTerms: query.tagTerms,
                authorTerms: query.authorTerms,
                titleTerms: query.titleTerms,
                seriesTerms: query.seriesTerms,
                statusTerms: query.statusTerms,
                fulltextPhrase: query.fulltextPhrase,
                plainTerms: [],
                ftsMatchedIDs: []
            )
        }
        rememberResolvedFulltext(ids: ftsIDs, key: cacheKey)
        return SearchQuery(
            tagTerms: query.tagTerms,
            authorTerms: query.authorTerms,
            titleTerms: query.titleTerms,
            seriesTerms: query.seriesTerms,
            statusTerms: query.statusTerms,
            fulltextPhrase: query.fulltextPhrase,
            plainTerms: [],
            ftsMatchedIDs: ftsIDs
        )
    }

    private func rememberResolvedFulltext(ids: [Int], key: String) {
        // §7: Insertion-order LRU eviction — evicts the oldest entry, not a random
        // hash-bucket occupant (which is what .keys.first would give us).
        if resolvedFulltextCache[key] != nil {
            // Refresh: move to back of order list so it is not evicted next.
            resolvedFulltextCacheOrder.removeAll { $0 == key }
        } else if resolvedFulltextCache.count >= resolvedFulltextCacheLimit {
            // Evict least-recently-used (front of insertion-order list).
            if let oldest = resolvedFulltextCacheOrder.first {
                resolvedFulltextCache.removeValue(forKey: oldest)
                resolvedFulltextCacheOrder.removeFirst()
            }
        }
        resolvedFulltextCache[key] = ids
        resolvedFulltextCacheOrder.append(key)
    }

    // MARK: - §7: Filter result cache

    /// Look up a cached FilterResult. Returns nil on cache miss.
    func cachedFilterResult(for expression: FilterExpression) -> FilterResult? {
        let key = FilterResultCacheKey(expression: expression,
                                       membershipVersion: membershipVersion)
        return filterResultCache[key]
    }

    /// Store a FilterResult in the LRU cache.
    func rememberFilterResult(_ result: FilterResult, for expression: FilterExpression) {
        let key = FilterResultCacheKey(expression: expression,
                                       membershipVersion: membershipVersion)
        filterResultCache.set(result, for: key)
    }

    /// Increment the membership version, invalidating all cached filter results
    /// that depend on collection / liked / status membership data.
    /// Call after: liked/skipped toggle, AO3 extraction batch flush, series sync.
    func bumpMembershipVersion() {
        membershipVersion &+= 1   // wrapping add — no overflow crash
    }

    // MARK: - §4: Feed server lifecycle
    //
    // Whether the server was running is persisted per-library
    // ("feedServer.enabled.<hash>") so it can be restarted automatically on
    // next launch — but only when the user has opted into
    // ReaderPreferences.feedServerAutoRestart (see `open(url:)`). Off by
    // default: a server that reappears on the LAN without a fresh
    // confirmation each launch would be a quiet posture change.

    private func feedServerEnabledKey(for path: String) -> String {
        "feedServer.enabled.\(libraryHash(for: URL(fileURLWithPath: path)))"
    }

    private func feedServerPortKey(for path: String) -> String {
        "feedServer.port.\(libraryHash(for: URL(fileURLWithPath: path)))"
    }

    private func persistFeedServerRunning(_ running: Bool, port: UInt16) {
        guard let path = activePath else { return }
        let ud = UserDefaults.standard
        ud.set(running, forKey: feedServerEnabledKey(for: path))
        if running { ud.set(Int(port), forKey: feedServerPortKey(for: path)) }
    }

    func startFeedServer(port: UInt16 = 8765) {
        guard let library, let metaDB, let collectionStore else { return }
        if feedServer == nil { feedServer = LocalFeedServer() }
        guard let server = feedServer else { return }
        let config = LocalFeedServer.Config(port: port)
        persistFeedServerRunning(true, port: port)
        Task {
            await server.start(
                library: library,
                metaDB: metaDB,
                collectionStore: collectionStore,
                modelContainer: modelContainer,
                config: config
            )
        }
    }

    /// Starts the feed server and suspends until it's actually bound and
    /// listening, or `timeout` elapses. Prefer this over `startFeedServer`
    /// wherever the caller needs to reliably read `localNetworkURLSync`
    /// afterward (design-philosophy audit, Finding 4).
    @discardableResult
    func startFeedServerAndWaitUntilListening(port: UInt16 = 8765, timeout: TimeInterval = 5) async -> Bool {
        guard let library, let metaDB, let collectionStore else { return false }
        if feedServer == nil { feedServer = LocalFeedServer() }
        guard let server = feedServer else { return false }
        let config = LocalFeedServer.Config(port: port)
        let didStart = await server.startAndWaitUntilListening(
            library: library,
            metaDB: metaDB,
            collectionStore: collectionStore,
            modelContainer: modelContainer,
            config: config,
            timeout: timeout
        )
        if didStart { persistFeedServerRunning(true, port: port) }
        return didStart
    }

    func stopFeedServer() {
        let server = feedServer
        feedServer = nil
        persistFeedServerRunning(false, port: 8765)
        Task { await server?.stop() }
    }

    /// If the feed server was running for this library last time and the
    /// user has opted into auto-restart, start it again now. Called from
    /// `open(url:)` after the library/collectionStore are ready.
    private func autoRestartFeedServerIfNeeded(path: String) {
        guard ReaderPreferences.shared.feedServerAutoRestart else { return }
        let ud = UserDefaults.standard
        guard ud.object(forKey: feedServerEnabledKey(for: path)) != nil,
              ud.bool(forKey: feedServerEnabledKey(for: path)) else { return }
        let savedPort = ud.object(forKey: feedServerPortKey(for: path)).flatMap { _ in ud.integer(forKey: feedServerPortKey(for: path)) }
        let port = savedPort.flatMap { UInt16(exactly: $0) } ?? 8765
        startFeedServer(port: port)
    }

    private func fulltextCacheKey(_ phrase: String) -> String {
        phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    // MARK: - Re-open saved library on launch

    func reopenIfNeeded() async {
        guard library == nil,
              let path = LibraryRegistry.shared.activePath,
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard LibraryRegistry.shared.isValid(path) else {
            #if DEBUG
            print("[LibrarySession] Saved path no longer valid: \(path)")
            #endif
            return
        }
        await open(url: url)
    }

    func reextractAO3Metadata() {
        guard metaDB != nil else { return }
        extractionTask?.cancel()
        Task {
            do {
                try await metaDB?.clearAO3Metadata()
                await MainActor.run {
                    let gen = self.beginCoordinatedSeriesSync(awaiting: 2)
                    self.seedCalibreSeriesCache(seriesSyncGeneration: gen)
                    self.startAO3Extraction(forceAll: true, seriesSyncGeneration: gen)
                }
            } catch {
                #if DEBUG
                print("[LibrarySession] AO3 metadata reset failed: \(error)")
                #endif
            }
        }
    }

    private func startAO3Extraction(forceAll: Bool = false, seriesSyncGeneration: Int? = nil) {
        extractionTask?.cancel()
        let generation = seriesSyncGeneration ?? beginCoordinatedSeriesSync(awaiting: 1)
        guard let library, let metaDB else {
            Task { await self.completeCoordinatedSeriesSync(generation: generation) }
            return
        }

        extractionProgress.completed = 0
        extractionProgress.total = 0
        extractionProgress.isRunning = true

        extractionTask = Task(priority: .background) { [weak self, library, metaDB] in
            let allIDs = await library.allBookIDs()
            let existing = (try? await metaDB.existingAO3MetadataIDs()) ?? []
            let attempted = (try? await metaDB.attemptedAO3ExtractionIDs()) ?? []
            // §7.3 (Phase 6): a book that reaches `.indexed` writes to neither
            // ao3_metadata nor ao3_extraction_diagnostics, so without this third
            // exclusion set every non-AO3 book would be fully re-decompressed and
            // re-parsed on every single library open, forever.
            let indexed = (try? await metaDB.existingBookIndexIDs()) ?? []
            let missing = forceAll ? allIDs : allIDs.filter {
                !existing.contains($0) && !attempted.contains($0) && !indexed.contains($0)
            }

            DispatchQueue.main.async { [weak self] in
                self?.extractionProgress.total = missing.count
                self?.extractionProgress.completed = 0
                self?.extractionProgress.isRunning = !missing.isEmpty
            }

            guard !missing.isEmpty else {
                await self?.completeCoordinatedSeriesSync(generation: generation)
                return
            }

            // Process in batches: parse EPUBs individually (CPU-bound, off-actor),
            // then flush accumulated results to the DB in one transaction per batch.
            // Yielding between batches lets higher-priority actor calls (e.g. filter
            // queries from the UI) cut in without waiting for the full extraction run.
            //
            // Quitting (applicationWillTerminate) does not cancel or flush this task —
            // that's deliberate, since flushing is async and not safe to force
            // synchronously during termination. Instead, batchSize and flushInterval
            // together bound how much already-completed work a quit can discard: at
            // most batchSize books, or flushInterval seconds' worth, whichever comes
            // first. Anything not flushed simply gets re-attempted on next launch,
            // since `missing` above is always recomputed from what's actually in the
            // DB — there is no separate "resume point" to track.
            let batchSize = 10
            let flushInterval: TimeInterval = 2
            var pendingSuccess: [(AO3MetadataRecord, Int)] = []
            var pendingFailure: [AO3ExtractionDiagnostic] = []
            var pendingIndexed: [(BookIndexRecord, Int)] = []
            var lastFlushAt = Date()

            func flushBatch() async {
                guard !pendingSuccess.isEmpty || !pendingFailure.isEmpty || !pendingIndexed.isEmpty else { return }
                // Only clear the pending buffers once the write has actually
                // succeeded. This used to copy-then-clear-then-write-with-try?,
                // so any transient insertBatch failure (e.g. the nested
                // transaction AmbrosiaMetaDB.insert(_:calibreID:) used to open)
                // silently discarded that batch's results with no retry and no
                // log line — those books would then look "never attempted" and
                // get needlessly reprocessed on every subsequent launch.
                do {
                    try await metaDB.insertBatch(pendingSuccess, diagnostics: pendingFailure, indexed: pendingIndexed)
                    pendingSuccess.removeAll()
                    pendingFailure.removeAll()
                    pendingIndexed.removeAll()
                } catch {
                    #if DEBUG
                    print("[LibrarySession] AO3 batch flush failed, will retry next flush: \(error)")
                    #endif
                }
                lastFlushAt = Date()
            }

            // A single book's parse + extract, factored out so it can run as an
            // independent task in the group below. Identical logic to the former
            // serial loop body — only the fan-out changed, not what each book does.
            enum ExtractionOutcome {
                case success(AO3MetadataRecord, BookIndexRecord, Int)
                case indexed(BookIndexRecord, Int)     // parsed fine, no AO3 preface found
                case failure(AO3ExtractionDiagnostic)
            }

            // Concurrency is capped rather than unbounded: each task holds a parsed
            // EPUB DOM in memory for the duration of its parse, so fanning out to
            // every available core on a large library risks memory pressure rather
            // than a proportional speedup. 8 is a conservative starting cap.
            let concurrency = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
            var nextIndex = 0
            var completedCount = 0

            @Sendable
            func extractOneBook(id: Int) async -> ExtractionOutcome {
                var failureReason: String?
                var failureStatus = "skipped"
                var diagnosticEPUB: URL?
                var spineItemsChecked: Int?
                var indexedRecord: BookIndexRecord?
                // epubURL is an actor-isolated (async) CalibreLibrary call now, and
                // autoreleasepool's closure is synchronous, so resolve it first —
                // the CPU-bound parse/extract work below never touches `library`.
                let epub = await library.epubURL(calibreID: id)
                let metadata: AO3MetadataRecord?
                if let epub {
                    diagnosticEPUB = epub
                    metadata = autoreleasepool { () -> AO3MetadataRecord? in
                        do {
                            var parser = EPUBParser(epubURL: epub)
                            try parser.parse()
                            // §7.3 (Phase 6): book_index gets a row for every book where
                            // parse() succeeds, AO3 or not — build it here, before the
                            // preface scan below, so it's available regardless of which
                            // branch (AO3 preface found or not) this book takes.
                            indexedRecord = buildBookIndexRecord(from: parser)
                            // AO3 EPUBs always place the preface (dl.tags metadata block) in
                            // spine[0]. Try it first as the fast path; only continue scanning
                            // up to 4 more items for non-standard EPUBs where something (a
                            // cover, a TOC page) precedes the preface.
                            var checked = 0
                            for item in parser.spine.prefix(5) {
                                checked += 1
                                let html = try parser.html(for: item, userCSS: "")
                                if var metadata = AO3MetadataExtractor.extract(from: html) {
                                    spineItemsChecked = checked
                                    let prefaceIndex = checked - 1

                                    // Byline is the very next spine item in every observed
                                    // case; scan a couple further only in case something
                                    // non-standard sits between preface and chapter 1. Do
                                    // NOT reuse the wide prefix(5) preface scan here — this
                                    // runs on ~70k books, and the covers/TOC pages that
                                    // justify a wide scan before the preface don't exist
                                    // after it.
                                    let bylineRangeEnd = min(prefaceIndex + 3, parser.spine.count)
                                    for candidateIndex in (prefaceIndex + 1)..<bylineRangeEnd {
                                        let candidate = parser.spine[candidateIndex]
                                        guard let chapterHTML = try? parser.html(for: candidate, userCSS: "") else { continue }
                                        let bylineAuthors = AO3MetadataExtractor.parseAuthors(from: chapterHTML)
                                        if !bylineAuthors.isEmpty {
                                            metadata.authors = bylineAuthors
                                            break
                                        }
                                    }

                                    // Tier 2: EPUB's own dc:creator — free, already parsed,
                                    // no Calibre dependency. One dc:creator element may hold
                                    // a comma-joined name list (observed AO3 export shape).
                                    if metadata.authors.isEmpty {
                                        let names = parser.opfCreators
                                            .flatMap { $0.components(separatedBy: ", ") }
                                            .map { $0.trimmingCharacters(in: .whitespaces) }
                                            .filter { !$0.isEmpty }
                                        metadata.authors = names.map {
                                            AO3AuthorEntry(username: $0, pseud: nil, profileURL: nil, source: .opfCreator)
                                        }
                                    }
                                    return metadata
                                }
                            }
                            spineItemsChecked = checked
                            failureReason = "no dl.tags AO3 preface metadata in first \(checked) spine items"
                            return nil
                        } catch {
                            failureStatus = "failed"
                            failureReason = error.localizedDescription
                            return nil
                        }
                    }
                } else {
                    failureReason = "no EPUB found"
                    metadata = nil
                }
                if var metadata {
                    // Tier 3: Calibre's own author field, last resort. Deliberately
                    // resolved here rather than inside the inner scan above — this is
                    // the one dependency we're trying to phase out (see 3.4), kept as
                    // a single, isolated, easy-to-delete-later call site.
                    if metadata.authors.isEmpty {
                        let calibreAuthors = await library.booksForIDs([id]).first?.authors ?? []
                        metadata.authors = calibreAuthors.map {
                            AO3AuthorEntry(username: $0, pseud: nil, profileURL: nil, source: .calibre)
                        }
                    }
                    // indexedRecord is always set here: metadata is only non-nil when
                    // parse() succeeded above, and indexedRecord is built unconditionally
                    // right after parse() succeeds, before metadata can be returned. Guarded
                    // rather than force-unwrapped per Invariant 12 (overview.md): if that
                    // ordering is ever broken by a future refactor, this book is skipped
                    // (logged) instead of crashing the whole extraction batch.
                    guard let indexedRecord else {
                        #if DEBUG
                        print("extractOneBook: indexedRecord unexpectedly nil for id \(id) despite non-nil metadata; skipping")
                        #endif
                        return .failure(AO3ExtractionDiagnostic(
                            calibreID: id,
                            status: "failed",
                            reason: "internal inconsistency: indexedRecord missing after successful parse",
                            epubPath: diagnosticEPUB?.path,
                            epubFilename: diagnosticEPUB?.lastPathComponent,
                            spineItemsChecked: spineItemsChecked,
                            attemptedAt: ISO8601DateFormatter().string(from: Date())
                        ))
                    }
                    return .success(metadata, indexedRecord, id)
                } else if let indexedRecord {
                    return .indexed(indexedRecord, id)
                } else {
                    return .failure(AO3ExtractionDiagnostic(
                        calibreID: id,
                        status: failureStatus,
                        reason: failureReason ?? "unknown reason",
                        epubPath: diagnosticEPUB?.path,
                        epubFilename: diagnosticEPUB?.lastPathComponent,
                        spineItemsChecked: spineItemsChecked,
                        attemptedAt: ISO8601DateFormatter().string(from: Date())
                    ))
                }
            }

            await withTaskGroup(of: ExtractionOutcome.self) { group in
                func addNextTask() {
                    guard !Task.isCancelled, nextIndex < missing.count else { return }
                    let id = missing[nextIndex]
                    nextIndex += 1
                    group.addTask { await extractOneBook(id: id) }
                }

                for _ in 0..<concurrency { addNextTask() }

                while let result = await group.next() {
                    switch result {
                    case .success(let metadata, let indexRecord, let id):
                        pendingSuccess.append((metadata, id))
                        pendingIndexed.append((indexRecord, id))
                    case .indexed(let record, let id):
                        pendingIndexed.append((record, id))
                    case .failure(let diagnostic):
                        pendingFailure.append(diagnostic)
                        #if DEBUG
                        print("[LibrarySession] AO3 extraction skipped calibreID=\(diagnostic.calibreID): \(diagnostic.reason)")
                        #endif
                    }
                    completedCount += 1
                    DispatchQueue.main.async { [weak self] in
                        self?.extractionProgress.completed += 1
                    }
                    // Flush and yield every batchSize books, or every flushInterval
                    // seconds if a batch of slow-parsing EPUBs takes longer than that,
                    // so read queries can cut in and a quit mid-run loses little.
                    if completedCount.isMultiple(of: batchSize) || Date().timeIntervalSince(lastFlushAt) >= flushInterval {
                        await flushBatch()
                        await Task.yield()
                    }
                    addNextTask()
                }
            }
            // Flush any remaining records.
            await flushBatch()

            DispatchQueue.main.async { [weak self] in
                self?.extractionProgress.isRunning = false
            }
            await self?.completeCoordinatedSeriesSync(generation: generation)
            self?.refreshAO3MetaCaches()
        }
    }

    private func importAO3TagSeeds() {
        guard let metaDB else { return }
        Task.detached(priority: .background) {
            do {
                try await metaDB.importConfiguredAO3TagSeedsIfNeeded()
                guard AO3TagSeedDatabaseConfig.shared.isEnabled else { return }
                let counts = try await metaDB.ao3TagSeedCounts()
                #if DEBUG
                print("""
                [LibrarySession] AO3 tag seeds ready: \(counts.canonicalTags) canonical tags, \
                \(counts.synonyms) synonyms, \(counts.hierarchyEdges) hierarchy edges
                """)
                #endif
            } catch {
                #if DEBUG
                print("[LibrarySession] AO3 tag seed import failed: \(error)")
                #endif
            }
        }
    }

    private func seedCalibreSeriesCache(seriesSyncGeneration: Int? = nil) {
        let generation = seriesSyncGeneration ?? beginCoordinatedSeriesSync(awaiting: 1)
        guard let library, let metaDB else {
            Task { await self.completeCoordinatedSeriesSync(generation: generation) }
            return
        }
        Task.detached(priority: .background) { [weak self, library, metaDB] in
            // CalibreLibrary is actor-isolated, so this serializes automatically
            // with page fetches and rebuildItems tasks that also access it —
            // no MainActor hop needed.
            let entries = await library.allCalibreSeriesEntries()
            do {
                try await metaDB.insertCalibreSeriesFallback(entries)
            } catch {
                #if DEBUG
                print("[LibrarySession] Calibre series cache seed failed: \(error)")
                #endif
            }
            await self?.completeCoordinatedSeriesSync(generation: generation)
        }
    }

    func syncSeriesOrMergedCollection() async {
        guard let library, let metaDB, let collectionStore else { return }
        do {
            let neverLeadsIDs = try await metaDB.neverLeadsSeriesIDs()
            // CalibreLibrary is actor-isolated, so these calls serialize
            // automatically with any other in-flight query against it —
            // no MainActor hop needed.
            let anthologyIDs = await library.anthologyBookIDs()
            let totalLibraryBooks = await library.bookCount()
            var ids = neverLeadsIDs
            ids.formUnion(anthologyIDs)
            LibraryFilterDebug.log("syncSeriesOrMerged.compute", [
                "neverLeadsSeriesIDs": neverLeadsIDs.count,
                "anthologyBookIDs": anthologyIDs.count,
                "unionTotal": ids.count,
                "totalLibraryBooks": totalLibraryBooks,
                "fractionOfLibrary": totalLibraryBooks > 0
                    ? String(format: "%.1f%%", Double(ids.count) / Double(totalLibraryBooks) * 100)
                    : "n/a"
            ])
            try await collectionStore.replaceMembers(of: SystemCollectionID.seriesOrMerged, with: ids)
            let verifyMembers = try await collectionStore.members(of: SystemCollectionID.seriesOrMerged)
            LibraryFilterDebug.log("syncSeriesOrMerged.persisted", [
                "writtenCount": ids.count,
                "readBackCount": verifyMembers.count
            ])
            await MainActor.run {
                NotificationCenter.default.post(name: .seriesOrMergedCollectionDidChange, object: nil)
            }
        } catch {
            #if DEBUG
            print("[LibrarySession] Series or Merged sync failed: \(error)")
            #endif
        }
    }
}

/// §7.3 (Phase 6): builds a `BookIndexRecord` from an already-`parse()`d
/// `EPUBParser` — called from `extractOneBook` at the point a book parses
/// fine but has no AO3 preface. Word count is computed by summing
/// `plainText(for:)` across the spine (the reader's own existing text
/// machinery, not a second extraction path); per-item failures are skipped
/// rather than aborting the whole count, and `wordCount` is nil only if
/// every spine item failed to yield text.
private func buildBookIndexRecord(from parser: EPUBParser) -> BookIndexRecord {
    var totalWords = 0
    var anySucceeded = false
    for item in parser.spine {
        guard let text = try? parser.plainText(for: item) else { continue }
        anySucceeded = true
        totalWords += text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
    let subject = parser.opfSubjects.isEmpty ? nil : parser.opfSubjects.joined(separator: ", ")
    return BookIndexRecord(
        title: parser.title.isEmpty ? nil : parser.title,
        description: parser.opfDescription,
        wordCount: anySucceeded ? totalWords : nil,
        pubDate: parser.opfDate,
        publisher: parser.opfPublisher,
        subject: subject,
        indexedAt: ISO8601DateFormatter().string(from: Date())
    )
}
