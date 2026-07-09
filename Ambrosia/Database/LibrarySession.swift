import Foundation
import Observation

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

        let changed = cachedLikedIDs != currentLiked
            || cachedReadLaterIDs != currentReadLater
            || cachedSkippedIDs != currentSkipped
            || cachedSeriesOrMergedIDs != currentSeriesOrMerged
            || cachedAO3PublisherIDs != currentAO3PublisherIDs
            || cachedAnthologyIDs != currentAnthologyIDs

        cachedLikedIDs = currentLiked
        cachedReadLaterIDs = currentReadLater
        cachedSkippedIDs = currentSkipped
        cachedSeriesOrMergedIDs = currentSeriesOrMerged
        cachedAO3PublisherIDs = currentAO3PublisherIDs
        cachedAnthologyIDs = currentAnthologyIDs

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
            LibraryRegistry.shared.register(url)
            LibraryIndexManager.shared.record(url: url)
            importAO3TagSeeds()
            let seriesSyncGen = beginCoordinatedSeriesSync(awaiting: 2)
            startAO3Extraction(seriesSyncGeneration: seriesSyncGen)
            seedCalibreSeriesCache(seriesSyncGeneration: seriesSyncGen)
            refreshAO3MetaCaches()
            // Load persisted search history for this library.
            SearchActivityLog.shared.load(libraryHash: Ambrosia.libraryHash(for: url))
            // TODO(§4): Restart feed server with new library if it was already running
            if let server = feedServer, let cs = collectionStore {
                Task { await server.updateLibrary(newLibrary, metaDB: newMetaDB, collectionStore: cs) }
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
            async let dates = metaDB.allAO3Dates()
            async let crossoverIDs = metaDB.allCrossoverBookIDs()
            let resolvedWordCounts = await wordCounts
            let resolvedDates = await dates
            let resolvedCrossoverIDs = await crossoverIDs
            // This Task was created from a MainActor context and is not detached,
            // so it already runs on the MainActor — no MainActor.run hop needed.
            // `library` is a separate actor now, so the call into it still needs `await`.
            guard self?.library === library else { return }
            await library.updateAO3MetaCaches(
                wordCounts: resolvedWordCounts,
                dates: resolvedDates,
                crossoverIDs: resolvedCrossoverIDs
            )
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
            SearchActivityLog.shared.save(libraryHash: Ambrosia.libraryHash(for: URL(fileURLWithPath: path)))
        }
        activePath = nil
        resolvedFulltextCache.removeAll()
        resolvedFulltextCacheOrder.removeAll()           // §7
        filterResultCache.removeAll()                    // §7
        membershipVersion = 0                            // §7
        cachedLikedIDs = []
        cachedSkippedIDs = []
        cachedSeriesOrMergedIDs = []
        cachedReadLaterIDs = []
        SearchActivityLog.shared.clear()
        cachedAO3PublisherIDs = []
        cachedAnthologyIDs = []
        stopFeedServer()                                     // §4
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
                tagTerms:     query.tagTerms,
                authorTerms:  query.authorTerms,
                titleTerms:   query.titleTerms,
                seriesTerms:  query.seriesTerms,
                statusTerms:  query.statusTerms,
                fulltextPhrase: query.fulltextPhrase,
                plainTerms:   [],
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
            tagTerms:     query.tagTerms,
            authorTerms:  query.authorTerms,
            titleTerms:   query.titleTerms,
            seriesTerms:  query.seriesTerms,
            statusTerms:  query.statusTerms,
            fulltextPhrase: query.fulltextPhrase,
            plainTerms:   [],
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

    func startFeedServer(port: UInt16 = 8765) {
        guard let library, let metaDB, let collectionStore else { return }
        if feedServer == nil { feedServer = LocalFeedServer() }
        guard let server = feedServer else { return }
        Task {
            await server.start(
                library: library,
                metaDB: metaDB,
                collectionStore: collectionStore,
                config: LocalFeedServer.Config(port: port)
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
        return await server.startAndWaitUntilListening(
            library: library,
            metaDB: metaDB,
            collectionStore: collectionStore,
            config: LocalFeedServer.Config(port: port),
            timeout: timeout
        )
    }

    func stopFeedServer() {
        let server = feedServer
        feedServer = nil
        Task { await server?.stop() }
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
            let missing = forceAll ? allIDs : allIDs.filter { !existing.contains($0) && !attempted.contains($0) }

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
        let batchSize = 50
        var pendingSuccess: [(AO3MetadataRecord, Int)] = []
        var pendingFailure: [AO3ExtractionDiagnostic] = []

        func flushBatch() async {
            guard !pendingSuccess.isEmpty || !pendingFailure.isEmpty else { return }
            let toInsertSuccess = pendingSuccess
            let toInsertFailure = pendingFailure
            pendingSuccess.removeAll()
            pendingFailure.removeAll()
            try? await metaDB.insertBatch(toInsertSuccess, diagnostics: toInsertFailure)
        }

        for (batchStart, id) in missing.enumerated() {
            if Task.isCancelled { break }
            var failureReason: String?
            var failureStatus = "skipped"
            var diagnosticEPUB: URL?
            var spineItemsChecked: Int?
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
                        let checkedItems = Array(parser.spine.prefix(5))
                        spineItemsChecked = checkedItems.count
                        for item in checkedItems {
                            let html = try parser.html(for: item, userCSS: "")
                            if let metadata = AO3MetadataExtractor.extract(from: html) {
                                return metadata
                            }
                        }
                        failureReason = "no dl.tags AO3 preface metadata in first \(min(parser.spine.count, 5)) spine items"
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
            if let metadata {
                pendingSuccess.append((metadata, id))
            } else {
                let diagnostic = AO3ExtractionDiagnostic(
                    calibreID: id,
                    status: failureStatus,
                    reason: failureReason ?? "unknown reason",
                    epubPath: diagnosticEPUB?.path,
                    epubFilename: diagnosticEPUB?.lastPathComponent,
                    spineItemsChecked: spineItemsChecked,
                    attemptedAt: ISO8601DateFormatter().string(from: Date())
                )
                pendingFailure.append(diagnostic)
                #if DEBUG
                print("[LibrarySession] AO3 extraction skipped calibreID=\(id): \(failureReason ?? "unknown reason")")
                #endif
            }
            DispatchQueue.main.async { [weak self] in
                self?.extractionProgress.completed += 1
            }
            // Flush and yield every batchSize books so read queries can cut in.
            if (batchStart + 1).isMultiple(of: batchSize) {
                await flushBatch()
                await Task.yield()
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
                print("[LibrarySession] AO3 tag seeds ready: \(counts.canonicalTags) canonical tags, \(counts.synonyms) synonyms, \(counts.hierarchyEdges) hierarchy edges")
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
