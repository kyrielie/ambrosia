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

    /// The path of the currently open library.
    private(set) var activePath: String?

    /// True while a library is open and ready to query.
    var isOpen: Bool { library != nil }

    /// Error from the last open attempt, shown in the UI if non-nil.
    private(set) var lastError: String?

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

    // MARK: - Opening / closing

    /// Open a Calibre library at the given URL.
    func open(url: URL) {
        lastError = nil
        do {
            let hash = Ambrosia.libraryHash(for: url)
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first!
            let metaDBPath = support
                .appendingPathComponent("Ambrosia")
                .appendingPathComponent("libraries")
                .appendingPathComponent(hash)
                .appendingPathComponent("ambrosia_meta.db")
                .path
            let newLibrary = try CalibreLibrary(root: url, metaDBPath: metaDBPath)
            let newMetaDB = try AmbrosiaMetaDB(libraryURL: url)
            library    = newLibrary
            metaDB = newMetaDB
            collectionStore = CollectionStore(db: newMetaDB)
            activePath = url.path
            totalCount = newLibrary.bookCount()
            ftsLibrary = CalibreFTSLibrary(libraryURL: url)
            resolvedFulltextCache.removeAll()
            resolvedFulltextCacheOrder.removeAll()           // §7
            filterResultCache.removeAll()                    // §7
            membershipVersion = 0                            // §7
            cachedLikedIDs = []
            cachedSkippedIDs = []
            cachedSeriesOrMergedIDs = []
            cachedAO3PublisherIDs = []
            LibraryRegistry.shared.register(url)
            LibraryIndexManager.shared.record(url: url)
            importAO3TagSeeds()
            startAO3Extraction()
            seedCalibreSeriesCache()
            // Load persisted search history for this library.
            SearchActivityLog.shared.load(libraryHash: Ambrosia.libraryHash(for: url))
            // §4: Restart feed server with new library if it was already running
            if let server = feedServer {
                let cs = collectionStore!
                Task { await server.updateLibrary(newLibrary, metaDB: newMetaDB, collectionStore: cs) }
            }
            print("[LibrarySession] Opened \(url.lastPathComponent) — \(totalCount) books")
        } catch {
            lastError = "Could not open library: \(error.localizedDescription)"
            print("[LibrarySession] Open failed: \(error)")
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
        SearchActivityLog.shared.clear()
        cachedAO3PublisherIDs = []
        stopFeedServer()                                     // §4
    }

    // MARK: - Count refresh

    func refreshCount(query: SearchQuery = SearchQuery(tagTerms: [], authorTerms: [], titleTerms: [], plainTerms: [])) {
        guard let library else { return }
        if query.isEmpty {
            totalCount = library.bookCount()
        } else {
            totalCount = library.bookCount(query: query)
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
            print("[LibrarySession] fulltext search unavailable for phrase=\"\(trimmed)\"")
            return []
        }
        let limit = max(library?.bookCount() ?? 0, 1)
        let ids = await Task.detached(priority: .userInitiated) {
            fts.search(query: trimmed, limit: limit) ?? []
        }.value
        if ids.isEmpty {
            print("[LibrarySession] fulltext search returned no matches for phrase=\"\(trimmed)\"")
        }
        rememberResolvedFulltext(ids: ids, key: key)
        return ids
    }

    /// Attempts FTS resolution for explicit fulltext only.
    /// Shared between list view and email view — single source of truth.
    func resolvedQuery(_ query: SearchQuery) -> SearchQuery {
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
            print("[LibrarySession] fulltext search unavailable for phrase=\"\(phrase)\"")
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
        guard let ftsIDs = fts.search(query: phrase), !ftsIDs.isEmpty else {
            print("[LibrarySession] fulltext search returned no matches for phrase=\"\(phrase)\"")
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
        let server = feedServer!
        Task {
            await server.start(
                library: library,
                metaDB: metaDB,
                collectionStore: collectionStore,
                config: LocalFeedServer.Config(port: port)
            )
        }
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

    func reopenIfNeeded() {
        guard library == nil,
              let path = LibraryRegistry.shared.activePath,
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard LibraryRegistry.shared.isValid(path) else {
            print("[LibrarySession] Saved path no longer valid: \(path)")
            return
        }
        open(url: url)
    }

    func reextractAO3Metadata() {
        guard metaDB != nil else { return }
        extractionTask?.cancel()
        Task {
            do {
                try await metaDB?.clearAO3Metadata()
                await MainActor.run {
                    self.seedCalibreSeriesCache()
                    self.startAO3Extraction(forceAll: true)
                }
            } catch {
                print("[LibrarySession] AO3 metadata reset failed: \(error)")
            }
        }
    }

    private func startAO3Extraction(forceAll: Bool = false) {
        extractionTask?.cancel()
        guard let library, let metaDB else { return }

        extractionProgress.completed = 0
        extractionProgress.total = 0
        extractionProgress.isRunning = true

        extractionTask = Task(priority: .background) { [weak self, library, metaDB] in
            let allIDs = library.allBookIDs()
            let existing = (try? await metaDB.existingAO3MetadataIDs()) ?? []
            let attempted = (try? await metaDB.attemptedAO3ExtractionIDs()) ?? []
            let missing = forceAll ? allIDs : allIDs.filter { !existing.contains($0) && !attempted.contains($0) }

            DispatchQueue.main.async { [weak self] in
                self?.extractionProgress.total = missing.count
                self?.extractionProgress.completed = 0
                self?.extractionProgress.isRunning = !missing.isEmpty
            }

            guard !missing.isEmpty else { return }

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
            let metadata = autoreleasepool { () -> AO3MetadataRecord? in
                guard let epub = library.epubURL(calibreID: id) else {
                    failureReason = "no EPUB found"
                    return nil
                }
                diagnosticEPUB = epub
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
                print("[LibrarySession] AO3 extraction skipped calibreID=\(id): \(failureReason ?? "unknown reason")")
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
            await self?.syncSeriesOrMergedCollection()
        }
    }

    private func importAO3TagSeeds() {
        guard let metaDB else { return }
        Task.detached(priority: .background) {
            do {
                try await metaDB.importConfiguredAO3TagSeedsIfNeeded()
                guard AO3TagSeedDatabaseConfig.shared.isEnabled else { return }
                let counts = try await metaDB.ao3TagSeedCounts()
                print("[LibrarySession] AO3 tag seeds ready: \(counts.canonicalTags) canonical tags, \(counts.synonyms) synonyms, \(counts.hierarchyEdges) hierarchy edges")
            } catch {
                print("[LibrarySession] AO3 tag seed import failed: \(error)")
            }
        }
    }

    private func seedCalibreSeriesCache() {
        guard let library, let metaDB else { return }
        Task.detached(priority: .background) { [weak self, library, metaDB] in
            let entries = library.allCalibreSeriesEntries()
            do {
                try await metaDB.insertCalibreSeriesFallback(entries)
                await self?.syncSeriesOrMergedCollection()
            } catch {
                print("[LibrarySession] Calibre series cache seed failed: \(error)")
            }
        }
    }

    func syncSeriesOrMergedCollection() async {
        guard let library, let metaDB, let collectionStore else { return }
        do {
            var ids = try await metaDB.collapsedSeriesMemberIDs()
            ids.formUnion(library.anthologyBookIDs())
            try await collectionStore.replaceMembers(of: SystemCollectionID.seriesOrMerged, with: ids)
            await MainActor.run {
                NotificationCenter.default.post(name: .seriesOrMergedCollectionDidChange, object: nil)
            }
        } catch {
            print("[LibrarySession] Series or Merged sync failed: \(error)")
        }
    }
}
