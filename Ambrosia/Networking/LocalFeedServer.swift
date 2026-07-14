import Foundation
import Darwin
import FlyingFox
import SwiftData

// MARK: - §9 / §4: LocalFeedServer
//
// Lightweight RSS 2.0 + `content:encoded` feed server backed by FlyingFox.
// Serves three routes:
//   GET /                             — HTML index listing all available feeds
//   GET /feed/collection/<id>.xml     — one item per book in the named collection
//   GET /feed/search.xml              — the last-published current-search snapshot
//
// Lifecycle:
//   • Started from the Preferences toggle (off by default).
//   • Torn down and recreated on library switch (same pattern as AmbrosiaMetaDB).
//   • The server runs inside a Task owned by this actor; cancelling that task
//     stops FlyingFox immediately.
//
// Security posture:
//   • Binds to all network interfaces (.inet) so other devices on the LAN can connect.
//   • No auth — this is a local-only feed for a single user's library.
//   • Off by default; user must enable in Preferences.
//
// Thread safety:
//   • This is a Swift actor — all mutable state is actor-isolated.
//   • FlyingFox handlers fire on their own Tasks; they call back into this actor
//     via async methods.

// MARK: - Current-search snapshot persistence (§4 point 8)
//
// A tiny UserDefaults key, namespaced per-library: "feedServer.currentSearchSnapshot.<hash>"
// Stored as JSON: { "ids": [Int], "timestamp": ISO8601 String, "label": String }
// Explicitly a snapshot — not re-queried on every poll.
//
// Namespaced by libraryHash so switching libraries doesn't surface a stale
// snapshot published from a different library's search.

struct CurrentSearchSnapshot: Codable {
    let calibreIDs: [Int]
    let publishedAt: String     // ISO 8601
    let label: String           // e.g. "tag: Horror" — displayed in the feed title
}

extension CurrentSearchSnapshot {
    private static let defaultsKeyBase = "feedServer.currentSearchSnapshot"

    private static func defaultsKey(libraryHash: String) -> String {
        "\(defaultsKeyBase).\(libraryHash)"
    }

    static func load(libraryHash: String) -> CurrentSearchSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(libraryHash: libraryHash)) else { return nil }
        return try? JSONDecoder().decode(CurrentSearchSnapshot.self, from: data)
    }

    func save(libraryHash: String) {
        let data = try? JSONEncoder().encode(self)
        UserDefaults.standard.set(data, forKey: CurrentSearchSnapshot.defaultsKey(libraryHash: libraryHash))
    }

    static func publish(calibreIDs: [Int], label: String, libraryHash: String) {
        let snapshot = CurrentSearchSnapshot(
            calibreIDs: calibreIDs,
            publishedAt: ISO8601DateFormatter().string(from: Date()),
            label: label.isEmpty ? "Current Search" : label
        )
        snapshot.save(libraryHash: libraryHash)
    }
}

// MARK: - Per-item HTML cache (§4 point 6)
//
// Keyed by (calibreID, epub file mtime). Invalidated only when the EPUB file changes,
// not on every poll. In-memory — no new SQLite table.

private struct HTMLCacheKey: Hashable {
    let calibreID: Int
    let epubMtime: Date
}

// MARK: - LocalFeedServer actor

actor LocalFeedServer {

    // MARK: Configuration

    struct Config {
        var port: UInt16 = 8765
    }

    // MARK: Stored state

    private(set) var config: Config
    private var serverTask: Task<Void, Never>?
    private var httpServer: HTTPServer?
    private var htmlCache: [HTMLCacheKey: String] = [:]
    private var htmlCacheOrder: [HTMLCacheKey] = []       // oldest first, for eviction
    private var htmlCacheTotalBytes: Int = 0
    private let htmlCacheMaxBytes = 2_000_000_000          // ~2GB budget

    /// Calibre's null-pubdate sentinel: 2000-12-31 00:00:00 UTC.
    /// `CalibreLibrary.parseDate` parses this successfully into a `Date`, so any
    /// book with no real pubdate set still produces a non-nil `publishedDate`.
    /// Items must be filtered against this value or every undated book renders
    /// a "Sat, 31 Dec 2000" pubDate.
    private static let calibrePubdateSentinel: Date = {
        var c = DateComponents()
        c.year = 2000; c.month = 12; c.day = 31
        c.hour = 0; c.minute = 0; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    // MARK: - MainActor-readable mirrors
    //
    // `isRunning` and `localNetworkURLSync` are read synchronously from @MainActor
    // code (toolbar menu, alert). Because LocalFeedServer is an actor those
    // properties are normally actor-isolated. These nonisolated(unsafe) mirrors are
    // written only from within actor methods (start/stop) so there is no data race
    // in practice — the tiny lag between Task spawn and mirror update is fine for UI.

    nonisolated(unsafe) private var _isRunning: Bool = false
    nonisolated(unsafe) private var _port: UInt16 = Config().port

    /// Synchronous read for @MainActor UI. May lag one run-loop behind actor state.
    nonisolated var isRunning: Bool { _isRunning }
    nonisolated var port: UInt16 { _port }

    /// Synchronous URL for the started-server alert. Returns nil when not running.
    nonisolated var localNetworkURLSync: String? {
        guard _isRunning else { return nil }
        if let ip = Self.localLANIP() { return "http://\(ip):\(_port)" }
        return "http://localhost:\(_port)"
    }

    // Injected at start — replaced on library switch.
    private var library: CalibreLibrary?
    private var metaDB: AmbrosiaMetaDB?
    private var collectionStore: CollectionStore?

    /// App-scoped, not library-scoped — unlike `library`/`metaDB`/
    /// `collectionStore` this isn't replaced by `updateLibrary(_:metaDB:
    /// collectionStore:)` on a library switch, since the SwiftData store
    /// backing `BookState` is shared across every library. Used only by the
    /// Phase 2 `.sqlite` route to read `totalReadPercent` for the wire
    /// schema's `reading_progress` column. Optional because `LibrarySession`
    /// itself may not have one yet in edge-case startup ordering; the
    /// `.sqlite` route treats a nil container as "no progress data
    /// available" rather than failing the whole request.
    private var modelContainer: ModelContainer?

    /// Per-library namespace for UserDefaults-backed prefs (excluded
    /// collections, daily-story toggle, search snapshot).
    /// Empty when no library is set (server shouldn't be running then anyway).
    private var libraryNamespace: String {
        library.map { libraryHash(for: $0.root) } ?? ""
    }

    // MARK: - Init

    init(config: Config = Config()) {
        self.config = config
    }

    /// Best-guess local network IPv4 address by scanning en0/en1 interfaces.
    private static func localLANIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let ifa = current.pointee
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                // en0 = Wi-Fi, en1 = Ethernet on most Macs; skip loopback (lo0).
                if name.hasPrefix("en") {
                    var addr = ifa.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(&addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(NI_MAXHOST),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        if !ip.isEmpty && ip != "127.0.0.1" {
                            return ip
                        }
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Start the server. Safe to call while already running (no-op if port unchanged).
    func start(library: CalibreLibrary,
               metaDB: AmbrosiaMetaDB,
               collectionStore: CollectionStore,
               modelContainer: ModelContainer? = nil,
               config: Config = Config()) {
        self.library = library
        self.metaDB  = metaDB
        self.collectionStore = collectionStore
        self.modelContainer = modelContainer
        self.config  = config
        _port = config.port
        restartServerTask()
        _isRunning = true
    }

    /// Start the server and suspend until the socket is actually bound and
    /// listening (or `timeout` elapses). Replaces the previous pattern of a
    /// fixed `asyncAfter` delay before reading `isRunning`/`localNetworkURLSync`,
    /// which could read stale state under port contention or slow network-stack
    /// init (design-philosophy audit, Finding 4). Returns `true` once actually
    /// listening, `false` if the timeout elapsed first.
    @discardableResult
    func startAndWaitUntilListening(library: CalibreLibrary,
                                     metaDB: AmbrosiaMetaDB,
                                     collectionStore: CollectionStore,
                                     modelContainer: ModelContainer? = nil,
                                     config: Config = Config(),
                                     timeout: TimeInterval = 5) async -> Bool {
        start(library: library, metaDB: metaDB, collectionStore: collectionStore,
              modelContainer: modelContainer, config: config)
        guard let server = httpServer else { return _isRunning }
        do {
            try await server.waitUntilListening(timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    /// Stop the server and release library references.
    func stop() {
        serverTask?.cancel()
        serverTask = nil
        httpServer = nil
        _isRunning = false
        library = nil
        metaDB  = nil
        collectionStore = nil
        htmlCache.removeAll()
        htmlCacheOrder.removeAll()
        htmlCacheTotalBytes = 0
    }

    /// Replace library references on a library switch without restarting the task.
    func updateLibrary(_ library: CalibreLibrary,
                       metaDB: AmbrosiaMetaDB,
                       collectionStore: CollectionStore) {
        self.library = library
        self.metaDB  = metaDB
        self.collectionStore = collectionStore
        htmlCache.removeAll()   // stale EPUB cache
        htmlCacheOrder.removeAll()
        htmlCacheTotalBytes = 0
    }

    // MARK: - Private: server task

    private func restartServerTask() {
        serverTask?.cancel()
        let capturedSelf = self
        let port = config.port
        serverTask = Task {
            do {
                // Starting the server always makes it reachable on the local
                // network — that's the whole point of "Start". A loopback-only
                // mode was tried and removed: it let Start silently not do
                // that, which contradicted the feature's own contract.
                let server = HTTPServer(address: .inet(port: port))
                httpServer = server

                // All routes are unauthenticated. Anything on the local
                // network that knows (or guesses) a feed URL can fetch it —
                // see Invariant 24 in the architecture doc.
                await server.appendRoute("GET /", handler: { [capturedSelf] _ in
                    try await capturedSelf.handleIndex()
                })
                await server.appendRoute("GET /feed/collection/*", handler: { [capturedSelf] request in
                    try await capturedSelf.handleCollectionFeed(request: request)
                })
                await server.appendRoute("GET /feed/search.xml", handler: { [capturedSelf] request in
                    try await capturedSelf.handleSearchFeed(format: .rss, request: request)
                })
                await server.appendRoute("GET /feed/search.json", handler: { [capturedSelf] request in
                    try await capturedSelf.handleSearchFeed(format: .json, request: request)
                })
                await server.appendRoute("GET /feed/random-daily.xml", handler: { [capturedSelf] request in
                    try await capturedSelf.handleRandomDailyFeed(format: .rss, request: request)
                })
                await server.appendRoute("GET /feed/random-daily.json", handler: { [capturedSelf] request in
                    try await capturedSelf.handleRandomDailyFeed(format: .json, request: request)
                })
                // Phase 2: SQLite transfer routes (Wire Contract). Additive
                // only, alongside the .xml/.json siblings above — those are
                // untouched.
                //
                // /feed/collection/<id>.sqlite is dispatched from inside
                // handleCollectionFeed (the existing "GET /feed/collection/*"
                // route above), not a second wildcard route registered here:
                // FlyingFox's route-matching precedence between two
                // overlapping wildcard patterns ("*" vs "*.sqlite") isn't
                // confirmed anywhere in the dump, so adding a second wildcard
                // risks silently never firing (or shadowing the existing one)
                // depending on match order — extending the one proven route's
                // own suffix-dispatch is the safe option here.
                //
                // /feed/search.sqlite and /feed/random-daily.sqlite have no
                // such ambiguity — the existing .xml/.json routes for these
                // are exact literal paths, not wildcards, so a third exact
                // path alongside them is unambiguous.
                await server.appendRoute("GET /feed/search.sqlite", handler: { [capturedSelf] request in
                    try await capturedSelf.handleSearchSQLiteFeed(request: request)
                })
                await server.appendRoute("GET /feed/random-daily.sqlite", handler: { [capturedSelf] request in
                    try await capturedSelf.handleRandomDailySQLiteFeed(request: request)
                })
                await server.appendRoute("GET /feeds.opml", handler: { [capturedSelf] _ in
                    try await capturedSelf.handleOPML()
                })
                try await server.run()
            } catch {
                if !Task.isCancelled {
                    #if DEBUG
                    print("[LocalFeedServer] Server stopped with error: \(error)")
                    #endif
                }
            }
        }
    }

    // MARK: - Route handlers

    /// Serialization format for a feed route. `.rss` keeps the existing hand-rolled
    /// XML string builder; `.json` uses the Codable-based JSON Feed 1.1 builder.
    /// Both consume the same book/AO3-metadata fetch — see `fetchFeedBooks(calibreIDs:)`.
    private enum FeedFormat {
        case rss
        case json
        case sqlite
    }

    private func handleIndex() async throws -> HTTPResponse {
        let ud = UserDefaults.standard
        let excludedRaw = ud.string(forKey: "rp.feedServerExcludedCollectionIDs.\(libraryNamespace)") ?? ""
        let excluded = excludedRaw.isEmpty ? Set<String>() : Set(excludedRaw.split(separator: ",").map(String.init))
        let dailyEnabled = ud.object(forKey: "rp.feedServerEnableDailyStory.\(libraryNamespace)").flatMap { _ in ud.bool(forKey: "rp.feedServerEnableDailyStory.\(libraryNamespace)") as Bool? } ?? false

        let collections = ((try? await collectionStore?.collections()) ?? [])
            .filter { !excluded.contains($0.id) }
        var links = collections.map { col in
            "<li><a href=\"/feed/collection/\(col.id).xml\">\(htmlEscape(col.name))</a> " +
            "(<a href=\"/feed/collection/\(col.id).json\">JSON</a>)</li>"
        }.joined(separator: "\n")

        if dailyEnabled {
            links += "\n<li><a href=\"/feed/random-daily.xml\">Daily Story</a> " +
                     "(<a href=\"/feed/random-daily.json\">JSON</a>)</li>"
        }

        if let snapshot = CurrentSearchSnapshot.load(libraryHash: libraryNamespace) {
            links += "\n<li><a href=\"/feed/search.xml\">Current Search: \(htmlEscape(snapshot.label))</a> " +
                     "(<a href=\"/feed/search.json\">JSON</a>)</li>"
        }

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Ambrosia Feeds</title></head>
        <body>
        <h1>Ambrosia Library Feeds</h1>
        <ul>
        \(links)
        </ul>
        <p><a href="/feeds.opml">Export all feeds as OPML</a></p>
        </body>
        </html>
        """
        return HTTPResponse(statusCode: .ok,
                            headers: [.contentType: "text/html; charset=utf-8"],
                            body: Data(html.utf8))
    }

    private func handleCollectionFeed(request: HTTPRequest) async throws -> HTTPResponse {
        // Extract collection ID and format from path: /feed/collection/<id>.xml|.json
        let path = request.path               // e.g. "/feed/collection/abc123.xml"
        guard path.hasPrefix("/feed/collection/") else {
            return HTTPResponse(statusCode: .notFound)
        }
        let suffix = String(path.dropFirst("/feed/collection/".count))
        let format: FeedFormat
        if suffix.hasSuffix(".sqlite") {
            format = .sqlite
        } else if suffix.hasSuffix(".json") {
            format = .json
        } else {
            format = .rss
        }
        let collectionID: String
        if suffix.hasSuffix(".sqlite") {
            collectionID = String(suffix.dropLast(7))
        } else if suffix.hasSuffix(".json") {
            collectionID = String(suffix.dropLast(5))
        } else if suffix.hasSuffix(".xml") {
            collectionID = String(suffix.dropLast(4))
        } else {
            collectionID = suffix
        }

        guard !collectionID.isEmpty else {
            return HTTPResponse(statusCode: .notFound)
        }

        let collections = (try? await collectionStore?.collections()) ?? []
        guard let collection = collections.first(where: { $0.id == collectionID }) else {
            return HTTPResponse(statusCode: .notFound)
        }

        // Return 404 if this collection has been excluded in Preferences.
        let excludedRaw = UserDefaults.standard.string(forKey: "rp.feedServerExcludedCollectionIDs.\(libraryNamespace)") ?? ""
        let excluded = excludedRaw.isEmpty ? Set<String>() : Set(excludedRaw.split(separator: ",").map(String.init))
        guard !excluded.contains(collectionID) else {
            return HTTPResponse(statusCode: .notFound)
        }
        let memberIDs = (try? await collectionStore?.members(of: collectionID)) ?? []

        switch format {
        case .rss:
            let result = try await buildRSSFeed(
                title: "\(collection.name)",
                feedDescription: "Books in the \(collection.name) collection",
                calibreIDs: memberIDs,
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/rss+xml; charset=utf-8") { Data($0.utf8) }
        case .json:
            let baseURL = localNetworkURLSync ?? "http://localhost:\(_port)"
            let page = request.query["page"].flatMap { Int($0) } ?? 1
            // per_page is still parsed for backward source-compatibility but no
            // longer controls page size — see jsonFeedMaxBooksPerPage in
            // buildJSONFeed for why (a client-supplied item count no longer
            // bounds per-request EPUB-parse work once grouping can multiply the
            // cost of a single item).
            let perPage: Int? = request.query["per_page"].flatMap { Int($0) }
            let result = try await buildJSONFeed(
                title: "\(collection.name)",
                feedDescription: "Books in the \(collection.name) collection",
                calibreIDs: memberIDs,
                feedURL: "\(baseURL)/feed/collection/\(collectionID).json",
                page: page,
                perPage: perPage,
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/feed+json; charset=utf-8") { $0 }
        case .sqlite:
            return try await buildSQLiteTransferResponse(calibreIDs: memberIDs)
        }
    }

    private func handleSearchFeed(format: FeedFormat, request: HTTPRequest) async throws -> HTTPResponse {
        guard let snapshot = CurrentSearchSnapshot.load(libraryHash: libraryNamespace) else {
            switch format {
            case .rss:
                let empty = buildEmptyFeed(title: "Current Search",
                                           message: "No search has been published yet.")
                return HTTPResponse(statusCode: .ok,
                                    headers: [.contentType: "application/rss+xml; charset=utf-8"],
                                    body: Data(empty.utf8))
            case .json:
                let empty = buildEmptyJSONFeed(title: "Current Search",
                                               feedDescription: "No search has been published yet.",
                                               feedURL: "\(localNetworkURLSync ?? "http://localhost:\(_port)")/feed/search.json")
                return HTTPResponse(statusCode: .ok,
                                    headers: [.contentType: "application/feed+json; charset=utf-8"],
                                    body: empty)
            case .sqlite:
                // Never reached: the .sqlite route is served by
                // handleSearchSQLiteFeed, not this function.
                assertionFailure("handleSearchFeed(.sqlite) — use handleSearchSQLiteFeed")
                return HTTPResponse(statusCode: .notFound)
            }
        }
        switch format {
        case .rss:
            let result = try await buildRSSFeed(
                title: "\(snapshot.label)",
                feedDescription: "Published search snapshot from \(snapshot.publishedAt)",
                calibreIDs: snapshot.calibreIDs,
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/rss+xml; charset=utf-8") { Data($0.utf8) }
        case .json:
            let baseURL = localNetworkURLSync ?? "http://localhost:\(_port)"
            let page = request.query["page"].flatMap { Int($0) } ?? 1
            let perPage: Int? = request.query["per_page"].flatMap { Int($0) }
            let result = try await buildJSONFeed(
                title: "\(snapshot.label)",
                feedDescription: "Published search snapshot from \(snapshot.publishedAt)",
                calibreIDs: snapshot.calibreIDs,
                feedURL: "\(baseURL)/feed/search.json",
                page: page,
                perPage: perPage,
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/feed+json; charset=utf-8") { $0 }
        case .sqlite:
            assertionFailure("handleSearchFeed(.sqlite) — use handleSearchSQLiteFeed")
            return HTTPResponse(statusCode: .notFound)
        }
    }

    /// A single random book, re-picked once per UTC calendar day. The seed is
    /// derived from the day index, not a stored value, so it is stable for any
    /// number of polls within the same day and changes deterministically at
    /// the next UTC midnight.
    private func handleRandomDailyFeed(format: FeedFormat, request: HTTPRequest) async throws -> HTTPResponse {
        let ud = UserDefaults.standard
        let dailyEnabled = ud.object(forKey: "rp.feedServerEnableDailyStory.\(libraryNamespace)").flatMap { _ in ud.bool(forKey: "rp.feedServerEnableDailyStory.\(libraryNamespace)") as Bool? } ?? false
        guard dailyEnabled else {
            return HTTPResponse(statusCode: .notFound)
        }
        guard let library else {
            return HTTPResponse(statusCode: .serviceUnavailable)
        }
        let allIDs = await library.allBookIDs()
        guard !allIDs.isEmpty else {
            switch format {
            case .rss:
                return HTTPResponse(statusCode: .ok,
                    headers: [.contentType: "application/rss+xml; charset=utf-8"],
                    body: Data(buildEmptyFeed(title: "Daily Story",
                                             message: "No books in library.").utf8))
            case .json:
                let empty = buildEmptyJSONFeed(title: "Daily Story",
                                               feedDescription: "No books in library.",
                                               feedURL: "\(localNetworkURLSync ?? "http://localhost:\(_port)")/feed/random-daily.json")
                return HTTPResponse(statusCode: .ok,
                    headers: [.contentType: "application/feed+json; charset=utf-8"],
                    body: empty)
            case .sqlite:
                assertionFailure("handleRandomDailyFeed(.sqlite) — use handleRandomDailySQLiteFeed")
                return HTTPResponse(statusCode: .notFound)
            }
        }
        let seed = Int(Date().timeIntervalSince1970 / 86400)
        let picked = allIDs[seed % allIDs.count]
        switch format {
        case .rss:
            let result = try await buildRSSFeed(
                title: "Daily Story",
                feedDescription: "A random story from your library, refreshed each day.",
                calibreIDs: [picked],
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/rss+xml; charset=utf-8") { Data($0.utf8) }
        case .json:
            let baseURL = localNetworkURLSync ?? "http://localhost:\(_port)"
            let result = try await buildJSONFeed(
                title: "Daily Story",
                feedDescription: "A random story from your library, refreshed each day.",
                calibreIDs: [picked],
                feedURL: "\(baseURL)/feed/random-daily.json",
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/feed+json; charset=utf-8") { $0 }
        case .sqlite:
            assertionFailure("handleRandomDailyFeed(.sqlite) — use handleRandomDailySQLiteFeed")
            return HTTPResponse(statusCode: .notFound)
        }
    }

    // MARK: - Phase 2: SQLite transfer route handlers
    //
    // Unlike the RSS/JSON Feed routes, there is no series-grouping pass here —
    // the Wire Contract's `items` table is deliberately one flat row per book
    // (Phase 2a: "populate one row per book"); Nectar's client does its own
    // presentation-level grouping if it wants any, this route just hands over
    // the raw per-book data.

    private func handleSearchSQLiteFeed(request: HTTPRequest) async throws -> HTTPResponse {
        guard let snapshot = CurrentSearchSnapshot.load(libraryHash: libraryNamespace) else {
            return try await buildSQLiteTransferResponse(calibreIDs: [])
        }
        return try await buildSQLiteTransferResponse(calibreIDs: snapshot.calibreIDs)
    }

    private func handleRandomDailySQLiteFeed(request: HTTPRequest) async throws -> HTTPResponse {
        let ud = UserDefaults.standard
        let dailyEnabled = ud.object(forKey: "rp.feedServerEnableDailyStory.\(libraryNamespace)").flatMap { _ in ud.bool(forKey: "rp.feedServerEnableDailyStory.\(libraryNamespace)") as Bool? } ?? false
        guard dailyEnabled else {
            return HTTPResponse(statusCode: .notFound)
        }
        guard let library else {
            return HTTPResponse(statusCode: .serviceUnavailable)
        }
        let allIDs = await library.allBookIDs()
        guard !allIDs.isEmpty else {
            return try await buildSQLiteTransferResponse(calibreIDs: [])
        }
        // Same daily-seed derivation as handleRandomDailyFeed — kept in sync
        // by both reading from the day-index seed rather than a stored value,
        // so a client polling both the .json and .sqlite routes on the same
        // UTC day always gets the same picked book from either.
        let seed = Int(Date().timeIntervalSince1970 / 86400)
        let picked = allIDs[seed % allIDs.count]
        return try await buildSQLiteTransferResponse(calibreIDs: [picked])
    }
    /// current-search snapshot feed when one has been published. The random
    /// daily feed is a permanent entry — it has no collection ID and is
    /// always available once a library is open.
    func generateOPML(baseURL: String) async -> String {
        let ud = UserDefaults.standard
        let excludedRaw = ud.string(forKey: "rp.feedServerExcludedCollectionIDs.\(libraryNamespace)") ?? ""
        let excluded = excludedRaw.isEmpty ? Set<String>() : Set(excludedRaw.split(separator: ",").map(String.init))
        let dailyEnabled = ud.object(forKey: "rp.feedServerEnableDailyStory.\(libraryNamespace)").flatMap { _ in ud.bool(forKey: "rp.feedServerEnableDailyStory.\(libraryNamespace)") as Bool? } ?? false

        let collections = ((try? await collectionStore?.collections()) ?? [])
            .filter { !excluded.contains($0.id) }
        let now = ISO8601DateFormatter().string(from: Date())

        var outlines = collections.map { col in
            """
            <outline type="rss"
                     text="\(xmlEscape(col.name))"
                     title="\(xmlEscape(col.name))"
                     xmlUrl="\(xmlEscape("\(baseURL)/feed/collection/\(col.id).xml"))"/>
            """
        }

        if dailyEnabled {
            outlines.append("""
            <outline type="rss"
                     text="Daily Story"
                     title="Daily Story"
                     xmlUrl="\(xmlEscape("\(baseURL)/feed/random-daily.xml"))"/>
            """)
        }

        if let snapshot = CurrentSearchSnapshot.load(libraryHash: libraryNamespace) {
            outlines.append("""
            <outline type="rss"
                     text="\(xmlEscape("Search: \(snapshot.label)"))"
                     title="\(xmlEscape("Search: \(snapshot.label)"))"
                     xmlUrl="\(xmlEscape("\(baseURL)/feed/search.xml"))"/>
            """)
        }

        let body = outlines.isEmpty
            ? "<!-- No collections or search snapshot to export. -->"
            : outlines.joined(separator: "\n    ")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Ambrosia Library Feeds</title>
            <dateCreated>\(now)</dateCreated>
            <docs>Feed URLs are tied to this Mac's current local network address and may break if the address changes or the server restarts. Re-export from Ambrosia to get updated URLs.</docs>
          </head>
          <body>
            \(body)
          </body>
        </opml>
        """
    }

    private func handleOPML() async throws -> HTTPResponse {
        let baseURL = localNetworkURLSync ?? "http://localhost:\(_port)"
        let opml = await generateOPML(baseURL: baseURL)
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/x-opml; charset=utf-8"],
            body: Data(opml.utf8)
        )
    }

    // MARK: - Shared feed data fetch (used by both RSS and JSON Feed builders)

    /// Bulk-fetches Calibre book stubs plus their AO3 metadata for a set of
    /// calibre IDs. Both `buildRSSFeed` and `buildJSONFeed` serialize this same
    /// pairing differently — this is the one place that touches Calibre/AmbrosiaMetaDB.
    /// Callers fetch this once, use it to compute an ETag, and only proceed to the
    /// (expensive — full merged HTML per item) builder call if the client's
    /// `If-None-Match` doesn't already match.
    /// Named once so RSS and JSON Feed generation (and their shared ETag/pagination
    /// helpers) don't each repeat a three-element tuple type. `seriesEntries` is
    /// every `series_cache` row for this book — legitimately zero, one, or more
    /// (a work can be a non-leading member of more than one series at once; see
    /// `AmbrosiaMetaDB.singletonNonLeadingSeriesEntries`), fetched once per feed
    /// build rather than per item.
    private typealias FeedBookPair = (book: CalibreBook, ao3: AO3MetadataRecord?, seriesEntries: [SeriesCacheEntry])

    /// `context` is a short caller label (e.g. "feed:collection/<id>",
    /// "feed:search", "feed:random-daily") forwarded to
    /// `CalibreLibrary.books(ids:...)` so its `books.page.end` debug log can
    /// be attributed to this feed build rather than lumped in with the app's
    /// own concurrent UI browsing.
    private func fetchFeedBooks(calibreIDs: [Int], context: String) async -> [FeedBookPair] {
        guard let library, let metaDB, !calibreIDs.isEmpty else { return [] }
        let ao3Map = (try? await metaDB.ao3Metadata(for: calibreIDs)) ?? [:]
        // Batched the same way as ao3Map above — one query for every book in this
        // build rather than a per-item lookup — so per-book series membership is
        // available to both the RSS and JSON Feed item builders without either of
        // them touching series_cache directly.
        let seriesRows = (try? await metaDB.seriesEntries(for: calibreIDs)) ?? []
        let seriesByBook = Dictionary(grouping: seriesRows, by: \.calibreID)
        // No cap here — callers decide how many IDs to pass in. RSS passes the
        // full list (no pagination protocol exists for RSS); JSON Feed passes
        // one page's worth (see buildJSONFeed's book-count page cap,
        // jsonFeedMaxBooksPerPage).
        let books = await library.books(ids: calibreIDs, offset: 0, limit: calibreIDs.count,
                                   sort: .title, ascending: true, context: context)
        return books.map { ($0, ao3Map[$0.id], seriesByBook[$0.id] ?? []) }
    }

    // MARK: - Series grouping for feeds
    //
    // Mirrors LibraryRootView/EmailLibraryViewController's "Group series" toggle
    // (ReaderPreferences.shared.groupBySeries, backed by UserDefaults key
    // "groupBySeries") using the same buildSeriesGroups(...) function
    // (Ambrosia/LibraryUI/SeriesGroupBuilder.swift) they use, so a feed's item
    // count matches the app's own series-card count for the same collection.
    //
    // Unlike the UI path, there is no `.orphanedSeriesEntry` case here: a feed
    // item is either one book or one whole series group. A book that's a solo,
    // non-leading member of a series with no group (no other visible members)
    // simply falls through to `.book`, since a feed has no UI-only "flag this
    // membership" concept worth inventing. Multi-series leadership is not
    // special-cased either — a book leading two series produces two grouped
    // feed items, matching assignSeriesItems' behavior.

    /// A page-resident book, or the series group it anchors (when it leads a
    /// >1-member series and grouping is on). Serialization-agnostic — consumed by
    /// both the JSON Feed and RSS builders.
    private enum FeedDisplayUnit {
        case book(FeedBookPair)
        case series(SeriesGroup, members: [FeedBookPair])
    }

    /// Groups `pairs` into display units when `groupBySeries` is on; otherwise
    /// returns one `.book` unit per pair, unchanged.
    ///
    /// `members` on the `.series` case carries every group member's own
    /// `FeedBookPair` (book + its ao3 record + its own seriesEntries), not just
    /// `SeriesGroup.works` ([CalibreBook] only) — content-HTML concatenation and
    /// tag-bucket reconstruction both need each member's AO3 record, which
    /// `SeriesGroup` itself doesn't carry.
    private func groupedDisplayUnits(from pairs: [FeedBookPair]) async -> [FeedDisplayUnit] {
        guard UserDefaults.standard.bool(forKey: "groupBySeries"), let library, let metaDB else {
            return pairs.map { .book($0) }
        }

        let pairByID = Dictionary(uniqueKeysWithValues: pairs.map { ($0.book.id, $0) })
        let entries = pairs.flatMap { $0.seriesEntries }
        let anthologyIDs = Set(pairs.filter { $0.book.isDescriptionAnthology }.map { $0.book.id })

        let groupedByKey = Dictionary(
            grouping: entries.filter { !anthologyIDs.contains($0.calibreID) },
            by: \.seriesKey
        )
        // Sorted rather than raw `.keys`: Dictionary iteration order isn't part of
        // Swift's contract, and this feeds into which series get grouped in what
        // order on every next_url page of a paginated refresh -- same class of
        // non-determinism as the SQL ORDER BY tiebreak above, just at the
        // series-grouping layer instead of the row-ordering layer.
        let seriesKeys = Array(groupedByKey.keys).sorted()
        guard !seriesKeys.isEmpty else { return pairs.map { .book($0) } }

        let allEntries = (try? await metaDB.seriesEntries(keys: seriesKeys)) ?? []
        let allIDs = Array(Set(allEntries.map(\.calibreID)))
        // A group's members can extend beyond this page/collection (e.g. book 3
        // of a 5-book series where only 1, 2, 4, 5 matched the feed's collection
        // filter) — fetch every member so the group is complete, not just the
        // page-local subset.
        let allBooks = await library.booksForIDs(allIDs)
        let byID = Dictionary(uniqueKeysWithValues: allBooks.map { ($0.id, $0) })
        let seriesMetadata = (try? await metaDB.ao3Metadata(for: allIDs)) ?? [:]

        let seriesByKey = buildSeriesGroups(
            allEntries: allEntries,
            byID: byID,
            seriesMetadata: seriesMetadata,
            anthologyIDs: anthologyIDs
        )

        // Members resolved only via allBooks/seriesMetadata (i.e. outside the
        // original `pairs`/collection filter) need a synthesized FeedBookPair so
        // downstream item-building has a uniform (book, ao3, seriesEntries) shape
        // regardless of whether the member was already present in `pairs`.
        let allSeriesEntriesByBook = Dictionary(grouping: allEntries, by: \.calibreID)
        func pairFor(_ book: CalibreBook) -> FeedBookPair {
            pairByID[book.id] ?? (book, seriesMetadata[book.id], allSeriesEntriesByBook[book.id] ?? [])
        }

        // Precomputed once, outside the loop, rather than re-deriving an
        // unordered `groupedByKey.values.flatMap.filter` slice per pair:
        //   - Correctness: `.values` iteration order isn't part of Swift's
        //     Dictionary contract, so a book leading two+ series could see its
        //     entries in a different relative order between calls, changing
        //     which series-group item gets emitted first and shifting that
        //     book across a page boundary on a later next_url fetch. Sorting
        //     by seriesKey (with seriesIndex as tiebreak) fixes the order.
        //   - Performance: avoids an O(entries) rescan of the full grouped
        //     set for every one of `pairs`, i.e. O(pairs x entries) overall.
        let sortedEntriesByBookID: [Int: [SeriesCacheEntry]] = Dictionary(
            grouping: groupedByKey.values.flatMap { $0 },
            by: \.calibreID
        ).mapValues { entries in
            entries.sorted {
                $0.seriesKey != $1.seriesKey
                    ? $0.seriesKey < $1.seriesKey
                    : $0.seriesIndex < $1.seriesIndex
            }
        }

        var emittedSeriesKeys = Set<String>()
        var units: [FeedDisplayUnit] = []

        // A series group is only emitted as a `.series` unit when its leading
        // work is itself present in `pairs` — matching the existing, correct
        // behavior for a leader excluded from this page/collection (its
        // followers still fall through to standalone `.book` units in that
        // case, since the group can't be represented without a leader).
        // Precompute which groups clear that bar, and the full set of member
        // IDs those groups will consume, *before* the per-pair pass below.
        // This has to happen up front rather than incrementally during the
        // pass, since `pairs` is title-sorted, not series-order — a follower
        // can be iterated before its leader, so there's no single forward
        // pass that can both discover a group and suppress its followers'
        // standalone emission at the same time.
        //
        // Before this existed: every non-leading series member fell through
        // to `if !emittedAny { units.append(.book(pair)) }` regardless of
        // whether its group had already been (or was about to be) emitted,
        // because the condition above only ever matches a *leader* against
        // itself. Followers were counted twice — once nested in the group's
        // `members`, once as their own top-level unit — which is why grouped
        // totals came out at or above the raw candidate count instead of
        // collapsing multi-member series into one item apiece.
        var consumedMemberIDs = Set<Int>()
        for group in seriesByKey.values {
            guard let leader = group.works.first, pairByID[leader.id] != nil else { continue }
            for work in group.works { consumedMemberIDs.insert(work.id) }
        }

        // Diagnostic only, alongside the emission loop below — does not
        // change what gets emitted. `consumedMemberIDs` only suppresses the
        // standalone `.book` fallback for a follower whose *own* leading
        // group got emitted; it does not stop that same follower from also
        // being pulled into a second, *different* emitted group's `members`
        // list when it's a non-leading member of more than one series at
        // once (e.g. a crossover work). That case is legitimate per
        // assignSeriesItems' multi-series behavior, but it's
        // indistinguishable downstream from an actual duplication bug —
        // both put the same calibre ID on two different feed pages — so log
        // which one actually happened instead of requiring it to be
        // reconstructed by hand from paginated `ids=` lines later.
        var memberSeriesKeys: [Int: Set<String>] = [:]

        for pair in pairs {
            let bookEntries = sortedEntriesByBookID[pair.book.id] ?? []
            var emittedAny = false
            for entry in bookEntries {
                guard let group = seriesByKey[entry.seriesKey],
                      !emittedSeriesKeys.contains(entry.seriesKey),
                      group.works.first?.id == pair.book.id else { continue }
                let memberPairs = group.works.map(pairFor)
                units.append(.series(group, members: memberPairs))
                emittedSeriesKeys.insert(entry.seriesKey)
                emittedAny = true
                for member in memberPairs { memberSeriesKeys[member.book.id, default: []].insert(entry.seriesKey) }
            }
            if !emittedAny && !consumedMemberIDs.contains(pair.book.id) {
                units.append(.book(pair))
            }
        }

        let crossSeriesDuplicates = memberSeriesKeys.filter { $0.value.count > 1 }
        if !crossSeriesDuplicates.isEmpty {
            LibraryFilterDebug.log("feed.grouping.crossSeriesMember", [
                "count": crossSeriesDuplicates.count,
                "ids": crossSeriesDuplicates.keys.sorted().map(String.init).joined(separator: ","),
                "detail": crossSeriesDuplicates.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key):\($0.value.sorted().joined(separator: "+"))" }
                    .joined(separator: ",")
            ])
        }
        return units
    }

    /// A cheap ETag over the fetched pairs plus any pagination/format params that
    /// affect the response shape. Reflects collection-membership changes (the pair
    /// list itself), AO3 re-extraction (`ao3.updatedDate`), and series_cache changes
    /// that can happen independently of re-extraction (e.g. a Calibre-fallback series
    /// row inserted later, or the anthology-hide toggle) — it does not reflect a bare
    /// Calibre comment/tag edit made outside AO3 extraction, since that has no
    /// cheap-to-read "last modified" signal available here. Good enough to skip the
    /// expensive per-item work on a repeat poll where nothing relevant changed; not a
    /// substitute for a real content-hash if that gap matters later.
    /// Folds in `groupBySeries` plus enough of each unit's identity (member
    /// calibre ids and their `ao3.updatedDate`, plus the series key for grouped
    /// units) that toggling the setting or a group-membership change invalidates
    /// the ETag, per the confirmed decision to fold grouping identity into the
    /// cache key.
    private func computeFeedETag(units: [FeedDisplayUnit], extra: String) -> String {
        var combined = extra
        combined += "|groupBySeries:\(UserDefaults.standard.bool(forKey: "groupBySeries"))"
        for unit in units {
            switch unit {
            case .book(let pair):
                combined += "|b:\(pair.book.id):\(pair.ao3?.updatedDate ?? "")"
                for entry in pair.seriesEntries.sorted(by: { $0.seriesName < $1.seriesName }) {
                    combined += ":\(entry.seriesName):\(entry.ao3SeriesID ?? ""):\(entry.isAnthology)"
                }
            case .series(let group, let members):
                combined += "|s:\(group.seriesKey)"
                for pair in members {
                    combined += ":\(pair.book.id):\(pair.ao3?.updatedDate ?? "")"
                }
            }
        }
        return "\"\(String(combined.hashValue, radix: 16))\""
    }

    private func ifNoneMatchHeader(_ request: HTTPRequest) -> String? {
        request.headers[HTTPHeader("If-None-Match")]
    }

    /// Result of a feed build: either the client's `If-None-Match` already
    /// matched (skip re-rendering entirely) or here's the freshly built body.
    private enum FeedBuildResult<Body> {
        case notModified(etag: String)
        case body(etag: String, data: Body)
    }

    /// Phase 1: gzip every `.xml`/`.json` feed body before it goes on the wire
    /// (Wire Contract → Compression). `URLSession` on the Nectar side decodes
    /// `Content-Encoding: gzip` transparently — no client-side coordination
    /// needed, this is standard HTTP, unlike the `.sqlite` route's LZFSE
    /// (Phase 2), which deliberately does NOT set this header.
    ///
    /// If compression fails for any reason, falls back to serving the
    /// uncompressed body with no `Content-Encoding` header rather than
    /// dropping the response — a slightly bigger response beats a broken one.
    private func httpResponse<Body>(for result: FeedBuildResult<Body>,
                                     contentType: String,
                                     toData: (Body) -> Data) -> HTTPResponse {
        switch result {
        case .notModified(let etag):
            return HTTPResponse(statusCode: .notModified, headers: [.eTag: etag])
        case .body(let etag, let data):
            let uncompressed = toData(data)
            guard let gzipped = try? GzipEncoder.gzip(uncompressed) else {
                return HTTPResponse(statusCode: .ok,
                                    headers: [.contentType: contentType, .eTag: etag],
                                    body: uncompressed)
            }
            return HTTPResponse(statusCode: .ok,
                                headers: [
                                    .contentType: contentType,
                                    .eTag: etag,
                                    HTTPHeader("Content-Encoding"): "gzip",
                                ],
                                body: gzipped)
        }
    }

    // MARK: - RSS generation

    private func buildRSSFeed(title: String,
                               feedDescription: String,
                               calibreIDs: [Int],
                               ifNoneMatch: String?) async throws -> FeedBuildResult<String> {
        guard let library else {
            return .body(etag: "\"empty\"", data: buildEmptyFeed(title: title, message: "No library open."))
        }

        // RSS has no pagination protocol (unlike JSON Feed) — the full list is
        // always passed in, so grouping here has no page-cap interaction to
        // worry about. Concatenating every member's HTML for a large grouped
        // item is an accepted tradeoff (infrequent fetches, no objection to long
        // load times) rather than something this patch needs to bound.
        let pairs = await fetchFeedBooks(calibreIDs: calibreIDs, context: "feed:rss:\(title)")
        let units = await groupedDisplayUnits(from: pairs)

        // One line per RSS build — there's no page loop to summarize later, so
        // this is both the per-response and "walk complete" log in one. See the
        // matching "feed.page.end" / "feed.walk.complete" pair on the JSON Feed
        // side for the paginated equivalent.
        LibraryFilterDebug.log("feed.rss.end", [
            "feed": title,
            "candidates": calibreIDs.count,
            "groupedTotal": units.count,
            "rawBooks": rawBookCount(in: units),
            "ids": flatItemIDs(in: units).map(String.init).joined(separator: ",")
        ])

        let etag = computeFeedETag(units: units, extra: "rss")
        if let ifNoneMatch, ifNoneMatch == etag {
            return .notModified(etag: etag)
        }

        var items: [String] = []
        for unit in units {
            switch unit {
            case .book(let pair):
                items.append(await buildRSSItem(book: pair.book, ao3: pair.ao3, seriesEntries: pair.seriesEntries, library: library))
            case .series(let group, let members):
                items.append(await buildGroupedRSSItem(group: group, members: members, library: library))
            }
        }

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:ambrosia="https://ambrosia.app/rss-extension">
          <channel>
            <title>\(xmlEscape(title))</title>
            <description>\(xmlEscape(feedDescription))</description>
            <generator>Ambrosia</generator>
            <lastBuildDate>\(rfc822Date(from: Date()))</lastBuildDate>
            \(items.joined(separator: "\n    "))
          </channel>
        </rss>
        """
        return .body(etag: etag, data: xml)
    }

    private func buildEmptyFeed(title: String, message: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>\(xmlEscape(title))</title>
            <description>\(xmlEscape(message))</description>
          </channel>
        </rss>
        """
    }

    private func buildRSSItem(book: CalibreBook,
                               ao3: AO3MetadataRecord?,
                               seriesEntries: [SeriesCacheEntry],
                               library: CalibreLibrary) async -> String {
        // §4 point 3: description = stripped comment + AO3 stats line
        let strippedComment = book.comment.map { HTMLStripper.strip($0) } ?? ""
        let statsLine = buildStatsLine(book: book, ao3: ao3)
        let description = [strippedComment, statsLine]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        // §4 point 3: content:encoded = full merged HTML from EPUB (CDATA-wrapped)
        // §4 point 6: cache keyed by (calibreID, epub mtime)
        let contentEncoded = await cachedMergedHTML(book: book, library: library)

        // §4 point 3: pubDate = ao3 published_date if present, else Calibre pubdate
        let pubDateStr: String
        if let ao3Date = ao3?.publishedDate, !ao3Date.isEmpty {
            pubDateStr = rfc822Date(from: ao3Date)
        } else if let calibreDate = book.publishedDate,
                  calibreDate > Self.calibrePubdateSentinel {
            pubDateStr = rfc822Date(from: calibreDate)
        } else {
            pubDateStr = ""
        }

        var xml = """
            <item>
              <title>\(xmlEscape(book.displayTitle))</title>
              <guid isPermaLink="false">ambrosia-book-\(book.id)</guid>
        """
        if let workURL = ao3?.storyURL {
            xml += "\n      <link>\(xmlEscape(workURL))</link>"
        }
        xml += "\n      <description>\(xmlEscape(description))</description>"
        if !book.authors.isEmpty {
            xml += "\n      <author>\(xmlEscape(book.authors.joined(separator: ", ")))</author>"
        }
        if !pubDateStr.isEmpty {
            xml += "\n      <pubDate>\(pubDateStr)</pubDate>"
        }
        if !contentEncoded.isEmpty {
            xml += "\n      <content:encoded><![CDATA[\(contentEncoded)]]></content:encoded>"
        }
        // Read-state identity for clients that need to dedup a book across feeds/
        // re-subscriptions — never repurposes <guid> itself, since ao3.workID may
        // only become known after a later re-extraction, and changing <guid> once
        // set would look like a brand-new article to any client polling this feed.
        if let workID = ao3?.workID, !workID.isEmpty {
            xml += "\n      <ambrosia:workID>\(xmlEscape(workID))</ambrosia:workID>"
        }
        if let anthologyEntry = anthologySeriesEntry(for: book, seriesEntries: seriesEntries) {
            xml += "\n      <ambrosia:isAnthology>true</ambrosia:isAnthology>"
            if let seriesID = anthologyEntry.ao3SeriesID, !seriesID.isEmpty {
                xml += "\n      <ambrosia:ao3SeriesID>\(xmlEscape(seriesID))</ambrosia:ao3SeriesID>"
            } else {
                xml += "\n      <ambrosia:seriesName>\(xmlEscape(anthologyEntry.seriesName))</ambrosia:seriesName>"
            }
        }
        xml += "\n    </item>"
        return xml
    }

    /// RSS analog of buildGroupedJSONFeedItem. Same <hr/>-joined HTML
    /// concatenation and no-per-member-failure-handling rationale (see that
    /// function's doc comment). RSS gets no tags field for grouped items, same
    /// as singleton RSS items today (buildRSSItem has no tag/category concept at
    /// all) — this is not a gap introduced by grouping, it matches existing RSS
    /// shape and was an explicit confirmed decision (normal RSS readers won't
    /// support tags anyway).
    private func buildGroupedRSSItem(
        group: SeriesGroup,
        members: [FeedBookPair],
        library: CalibreLibrary
    ) async -> String {
        var htmlParts: [String] = []
        for pair in members {
            let html = await cachedMergedHTML(book: pair.book, library: library)
            if html.isEmpty {
                #if DEBUG
                print("[LocalFeedServer] grouped RSS item \(group.seriesKey): member \(pair.book.id) (\"\(pair.book.displayTitle)\") produced empty merged HTML")
                #endif
            }
            htmlParts.append(html)
        }
        let contentEncoded = htmlParts.joined(separator: "\n<hr/>\n")

        let description = group.allDescriptions.joined(separator: "\n\n")

        var xml = """
            <item>
              <title>\(xmlEscape(group.seriesName))</title>
              <guid isPermaLink="false">ambrosia-series-\(group.seriesKey)</guid>
        """
        let leaderAO3 = members.first?.ao3
        // Same url fallback as the JSON Feed path: real AO3 series URL when
        // ao3:-keyed, else the leading work's own story URL for calibre:-keyed
        // groups (not a constructed URL, not omitted).
        let link: String?
        if group.seriesKey.hasPrefix("ao3:") {
            link = "https://archiveofourown.org/series/\(group.seriesKey.dropFirst("ao3:".count))"
        } else {
            link = leaderAO3?.storyURL
        }
        if let link {
            xml += "\n      <link>\(xmlEscape(link))</link>"
        }
        xml += "\n      <description>\(xmlEscape(description))</description>"
        if !group.allAuthors.isEmpty {
            xml += "\n      <author>\(xmlEscape(group.allAuthors.joined(separator: ", ")))</author>"
        }
        if let latest = group.latestUpdated {
            xml += "\n      <pubDate>\(rfc822Date(from: latest))</pubDate>"
        }
        if !contentEncoded.isEmpty {
            xml += "\n      <content:encoded><![CDATA[\(contentEncoded)]]></content:encoded>"
        }
        // No <ambrosia:workID> — a group has no single AO3 work id.
        xml += "\n    </item>"
        return xml
    }

    // MARK: - JSON Feed generation
    //
    // JSON Feed 1.1 (https://www.jsonfeed.org/version/1.1/), served as an additional
    // route alongside RSS — same routes, `.json` instead of `.xml` — not a replacement.
    // Reuses `fetchFeedBooks` for the Calibre/AO3 fetch; only the serializer differs.
    // Two things this gets us that hand-rolled RSS strings can't cleanly express:
    //   - `authors` as a real array of `{name, url}` objects instead of one
    //     comma-joined string in a single RSS <author> tag.
    //   - `tags` as a real array (fandoms/relationships/characters/additional tags/
    //     categories/Calibre tags), where the RSS builder has no tag/category field
    //     at all today.
    // `JSONEncoder` also removes the hand-rolled `xmlEscape` class of bug (its four-
    // character escape list) for this route — JSON string escaping is handled by
    // the encoder, not by us.
    //
    // JSON Feed 1.1 has no book-specific fields, so word count, chapter progress,
    // completion, AO3 rating/warnings/categories, series, and date_modified ride
    // in a per-item `_ambrosia` extension object (the spec's underscore-prefixed
    // convention for reader-specific data) rather than being flattened into prose
    // inside `summary`. Readers that don't recognize `_ambrosia` just ignore it.

    private struct JSONFeedAuthor: Codable {
        var name: String?
        var url: String?
    }

    private struct JSONFeedSeriesEntry: Codable {
        var name: String
        var index: Int
        var ao3_id: String?
    }

    /// Ambrosia-specific metadata that has no JSON Feed 1.1 field of its own.
    /// Sent under the spec's `_`-prefixed extension convention — readers that
    /// don't recognize `_ambrosia` ignore it; ones that do get real structured
    /// data instead of the prose stats line baked into `summary`.
    private struct JSONFeedAmbrosiaExtension: Codable {
        var word_count: Int?
        var chapter_current: Int?
        var chapter_total: Int?
        var is_complete: Bool?
        var fandoms: [String]?
        var relationships: [String]?
        var characters: [String]?
        var ratings: [String]?
        var warnings: [String]?
        var categories: [String]?
        var series: [JSONFeedSeriesEntry]?
        var date_modified: String?
        // Read-state identity fields (client-side cross-feed/re-subscription dedup;
        // not part of JSON Feed 1.1 itself). Deliberately separate from the item's
        // own `id`, which stays "ambrosia-book-<calibre_id>" forever: `ao3_work_id`
        // may only become known after a later re-extraction, and an `id` that can
        // change would look like a brand-new article to any client polling this feed.
        var ao3_work_id: String?
        // True only when this Calibre book's own description is a merge-plugin
        // "Anthology containing:" comment — i.e. this book IS an entire compiled
        // series, not a normal work that happens to belong to one. Unrelated to
        // series_cache's own per-series-name anthology-hide display setting.
        var is_anthology: Bool?
        // Populated only when is_anthology is true. ao3_series_id is preferred;
        // series_name is the Calibre-derived fallback when no AO3 series id exists.
        var ao3_series_id: String?
        var series_name: String?
    }

    private struct JSONFeedItem: Codable {
        var id: String
        var url: String?
        var title: String?
        var content_html: String?
        var summary: String?
        var date_published: String?
        var authors: [JSONFeedAuthor]?
        var tags: [String]?
        var _ambrosia: JSONFeedAmbrosiaExtension?
    }

    private struct JSONFeedDocument: Codable {
        var version = "https://jsonfeed.org/version/1.1"
        var title: String
        var description: String?
        var home_page_url: String?
        var feed_url: String?
        var next_url: String?
        var items: [JSONFeedItem]
    }

    private static let jsonFeedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Cap on cumulative *underlying book count* per page, not item count. A
    /// grouped item can hide an arbitrary number of member EPUB-parses (one
    /// series with 40 members is one item), so capping by item count alone could
    /// still reintroduce the FlyingFox 15s-timeout risk this was designed around,
    /// just hidden behind a small-looking per_page number. Applied
    /// unconditionally — a client-supplied `per_page` no longer directly bounds
    /// page size once grouping can multiply the per-item cost; this constant is
    /// the real bound on server-side work per request instead.
    private static let jsonFeedMaxBooksPerPage = 30

    /// Splits `units` into pages bounded by cumulative underlying book count
    /// (`maxBooksPerPage`), not item count. A single unit that alone exceeds the
    /// cap (e.g. a 40-member series) still gets its own page rather than being
    /// split — a feed item must stay whole — so a page can exceed the cap by at
    /// most one unit's worth of books; the cap prevents *accumulating* many such
    /// units onto one page, not a single oversized one.
    private func paginate(_ units: [FeedDisplayUnit], page: Int, maxBooksPerPage: Int) -> (units: [FeedDisplayUnit], hasMore: Bool) {
        func bookCount(_ unit: FeedDisplayUnit) -> Int {
            switch unit {
            case .book: return 1
            case .series(_, let members): return members.count
            }
        }

        var pages: [[FeedDisplayUnit]] = []
        var current: [FeedDisplayUnit] = []
        var currentCount = 0
        for unit in units {
            let count = bookCount(unit)
            if !current.isEmpty && currentCount + count > maxBooksPerPage {
                pages.append(current)
                current = []
                currentCount = 0
            }
            current.append(unit)
            currentCount += count
        }
        if !current.isEmpty { pages.append(current) }

        let index = max(page, 1) - 1
        guard index < pages.count else { return ([], false) }
        return (pages[index], index + 1 < pages.count)
    }

    // MARK: - Feed logging helpers

    /// Sum of underlying books represented by `units` — 1 per `.book`,
    /// `members.count` per `.series`. Same accounting as `paginate`'s local
    /// `bookCount`, exposed here for logging so the two never drift apart.
    private func rawBookCount(in units: [FeedDisplayUnit]) -> Int {
        units.reduce(0) { total, unit in
            switch unit {
            case .book: return total + 1
            case .series(_, let members): return total + members.count
            }
        }
    }

    /// Every `calibreID` represented in `units` — the book itself for `.book`,
    /// every member for `.series` — so a log line can answer "is this ID on
    /// this page" without re-deriving it from the response body.
    private func flatItemIDs(in units: [FeedDisplayUnit]) -> [Int] {
        units.flatMap { unit -> [Int] in
            switch unit {
            case .book(let pair): return [pair.book.id]
            case .series(_, let members): return members.map { $0.book.id }
            }
        }
    }

    /// Per-feed-walk state accumulated across paginated JSON Feed requests,
    /// keyed by `feedWalkKey(for:)`. Each page of a `next_url` walk is an
    /// independent HTTP request, so this is the only place that can answer
    /// "how did this whole refresh add up" — flushed and removed by
    /// `flushFeedWalkSummary` once a page comes back with `hasMore == false`.
    private var feedWalkAccumulators: [String: (pages: Int, groupedItems: Int, rawBooks: Int)] = [:]

    /// Caches the expensive fetch+group result for one pagination walk so that
    /// `buildJSONFeed` does the full-collection `fetchFeedBooks` +
    /// `groupedDisplayUnits` work exactly once per walk instead of once per
    /// page. Before this cache existed, every `next_url` page re-fetched and
    /// re-grouped the *entire* candidate set (full CalibreBook rows, authors,
    /// tags, comments, AO3 metadata for every ID) only to discard all but one
    /// page's worth — for a 763-book collection paginated in ~30-book pages,
    /// that's ~41x the necessary DB work per full refresh, and per-page latency
    /// climbed with it until slow pages started missing the client's 15s
    /// timeout, aborting the walk partway through (see `isPartial` handling on
    /// the NetNewsWire side).
    ///
    /// Keyed by `feedWalkKey(for:)` (the feed URL with `page`/`per_page`
    /// stripped) — the same key `feedWalkAccumulators` uses — so this lives and
    /// dies with the same walk.
    private struct FeedUnitsCacheEntry {
        let candidateIDs: Set<Int>   // fingerprint: which IDs this grouping was computed from
        let units: [FeedDisplayUnit]
        var lastAccessedAt: Date     // sliding TTL anchor — see groupedUnitsForWalk
    }

    private var feedUnitsCache: [String: FeedUnitsCacheEntry] = [:]

    /// Walk cache entries idle longer than this are treated as stale and
    /// recomputed rather than reused — protects against serving a page from a
    /// walk that never finished (client crashed, network dropped) indefinitely.
    ///
    /// This is a *sliding* window measured from the entry's last access, not
    /// its creation: `groupedUnitsForWalk` bumps `lastAccessedAt` on every hit.
    /// An earlier version measured from creation time only, which meant a
    /// walk slow enough to take longer than the TTL to page through (observed
    /// in practice: a 763-book/41-page collection walk interleaved with a
    /// 453-book/28-page search walk on the same connection) would have its
    /// entry expire mid-walk even though it was being actively read every few
    /// hundred milliseconds. That forced a silent recompute partway through
    /// pagination — wasteful on its own, but worse, nothing guarantees
    /// `groupedDisplayUnits` reproduces the exact same ordering on a second
    /// call (SQLite tie-breaking among same-titled books, etc.), so pages
    /// straddling the recompute boundary could duplicate or skip items
    /// relative to the client's already-fetched pages. A sliding TTL means an
    /// actively-progressing walk never expires on its own; only a genuinely
    /// abandoned one does.
    private static let feedUnitsCacheTTL: TimeInterval = 120

    /// `feedURL` with any `page=`/`per_page=` query stripped, so every page of
    /// the same walk accumulates under one key regardless of which page
    /// number is embedded in its own `feedURL`.
    private func feedWalkKey(for feedURL: String) -> String {
        guard let qIndex = feedURL.firstIndex(of: "?") else { return feedURL }
        return String(feedURL[..<qIndex])
    }

    private func recordFeedWalkPage(key: String, pageItems: Int, rawBooks: Int) {
        var entry = feedWalkAccumulators[key] ?? (pages: 0, groupedItems: 0, rawBooks: 0)
        entry.pages += 1
        entry.groupedItems += pageItems
        entry.rawBooks += rawBooks
        feedWalkAccumulators[key] = entry
    }

    private func flushFeedWalkSummary(key: String, feed: String) {
        guard let entry = feedWalkAccumulators.removeValue(forKey: key) else { return }
        feedUnitsCache.removeValue(forKey: key)
        LibraryFilterDebug.log("feed.walk.complete", [
            "feed": feed,
            "feedURL": key,
            "pages": entry.pages,
            "groupedItems": entry.groupedItems,
            "rawBooks": entry.rawBooks
        ])
    }

    /// Returns the full grouped `FeedDisplayUnit` list for `calibreIDs`, reusing
    /// a cached result from an earlier page of the same walk when one exists,
    /// still matches `calibreIDs`, and isn't stale. Falls through to the full
    /// `fetchFeedBooks` + `groupedDisplayUnits` computation (and caches the
    /// result) on a cache miss, a candidate-set change (collection/search
    /// membership shifted between pages of the same walk), or an expired entry.
    ///
    /// Known limitation (documented, not fixed here): if two overlapping
    /// pagination walks of the *same* feed run concurrently (the NetNewsWire-side
    /// concurrent-refresh issue observed separately), the second walk's page-1
    /// request will recompute and overwrite the cache entry the first walk's
    /// later pages are relying on. This doesn't break correctness — the first
    /// walk's next page will just also get a (possibly slightly different,
    /// since the collection could have changed) cache miss and recompute — but
    /// it does mean the cache benefit degrades under concurrent duplicate
    /// walks. This should be fixed on the client side (NetNewsWire's
    /// `LocalAccountRefresher` re-entrancy guard) rather than by adding locking
    /// here, since locking here would only convert "wasted recompute" into
    /// "one walk blocking on another's full recompute," which is worse for
    /// latency.
    private func groupedUnitsForWalk(walkKey: String, calibreIDs: [Int]) async -> [FeedDisplayUnit] {
        let candidateSet = Set(calibreIDs)
        let now = Date()

        if var cached = feedUnitsCache[walkKey] {
            let age = now.timeIntervalSince(cached.lastAccessedAt)
            if cached.candidateIDs == candidateSet, age < Self.feedUnitsCacheTTL {
                cached.lastAccessedAt = now
                feedUnitsCache[walkKey] = cached
                LibraryFilterDebug.log("feed.unitsCache", [
                    "walkKey": walkKey,
                    "hit": true,
                    "candidateCount": calibreIDs.count,
                    "ageSeconds": age
                ])
                return cached.units
            }
            // Miss with an existing entry: distinguish *why* for anyone reading
            // the log later — a candidate-set change and a TTL expiry look
            // identical as a bare "hit=false" and used to be logged the same
            // way, which made this exact bug (TTL expiring mid-walk) invisible
            // without manually diffing candidateCount across surrounding lines.
            let reason = cached.candidateIDs != candidateSet ? "candidateChanged" : "ttlExpired"
            LibraryFilterDebug.log("feed.unitsCache", [
                "walkKey": walkKey,
                "hit": false,
                "reason": reason,
                "candidateCount": calibreIDs.count,
                "previousCandidateCount": cached.candidateIDs.count,
                "ageSeconds": age
            ])
            let allPairs = await fetchFeedBooks(calibreIDs: calibreIDs, context: "feed:json:\(walkKey)")
            let allUnits = await groupedDisplayUnits(from: allPairs)
            feedUnitsCache[walkKey] = FeedUnitsCacheEntry(candidateIDs: candidateSet, units: allUnits, lastAccessedAt: now)
            pruneStaleFeedUnitsCacheEntries(now: now)
            return allUnits
        }

        let allPairs = await fetchFeedBooks(calibreIDs: calibreIDs, context: "feed:json:\(walkKey)")
        let allUnits = await groupedDisplayUnits(from: allPairs)
        feedUnitsCache[walkKey] = FeedUnitsCacheEntry(candidateIDs: candidateSet, units: allUnits, lastAccessedAt: now)
        pruneStaleFeedUnitsCacheEntries(now: now)
        LibraryFilterDebug.log("feed.unitsCache", [
            "walkKey": walkKey,
            "hit": false,
            "reason": "newWalk",
            "candidateCount": calibreIDs.count
        ])
        return allUnits
    }

    /// Bounds cache growth for walks that never reach `hasMore == false` (client
    /// disconnects mid-walk, crashes, etc.) — `flushFeedWalkSummary` already
    /// evicts on a clean finish; this is the backstop for the unclean case.
    /// Uses the same sliding `lastAccessedAt` as `groupedUnitsForWalk`, so an
    /// actively-progressing walk is never pruned out from under itself.
    private func pruneStaleFeedUnitsCacheEntries(now: Date) {
        feedUnitsCache = feedUnitsCache.filter { now.timeIntervalSince($0.value.lastAccessedAt) < Self.feedUnitsCacheTTL }
    }

#if DEBUG
    // MARK: - Test hooks (AmbrosiaTests only, via @testable import)
    //
    // FeedDisplayUnit and FeedUnitsCacheEntry are both `private` (correctly —
    // they're implementation details of grouping/caching), so they can't be
    // named outside this file. These hooks expose only Int/Bool, which keeps
    // that encapsulation intact while still letting tests assert on cache
    // hit/miss/invalidate/evict behavior without reaching into actor-private
    // storage directly.

    var feedUnitsCacheEntryCount: Int { feedUnitsCache.count }

    func feedUnitsCacheContainsKey(_ walkKey: String) -> Bool {
        feedUnitsCache[walkKey] != nil
    }

    /// Runs `groupedUnitsForWalk` and returns only the resulting count, so
    /// tests can assert cache behavior (call counts, entry identity) without
    /// needing to name `FeedDisplayUnit` outside this file.
    func testHook_groupedUnitCount(walkKey: String, calibreIDs: [Int]) async -> Int {
        await groupedUnitsForWalk(walkKey: walkKey, calibreIDs: calibreIDs).count
    }
#endif

    private func buildJSONFeed(title: String,
                                feedDescription: String,
                                calibreIDs: [Int],
                                feedURL: String,
                                page: Int = 1,
                                // Accepted for backward source-compatibility with existing call
                                // sites/query-string parsing, but intentionally unused for page
                                // sizing (see jsonFeedMaxBooksPerPage) — confirmed decision: the
                                // book-count cap applies unconditionally, so a client-supplied
                                // per_page no longer controls page size even when grouping is off.
                                perPage: Int? = nil,
                                ifNoneMatch: String?) async throws -> FeedBuildResult<Data> {
        guard let library else {
            return .body(etag: "\"empty\"",
                        data: buildEmptyJSONFeed(title: title, feedDescription: "No library open.", feedURL: feedURL))
        }

        // Cheap SQL fetch returns every matching book, title-sorted. Then, when
        // groupBySeries is on, series members collapse into single display units
        // before pagination — see groupedDisplayUnits. Only the current page's
        // slice gets the expensive per-item work below (full merged EPUB HTML per
        // book, concatenated across every member for a grouped item), so payload
        // size and per-request parse cost stay bounded no matter how large the
        // underlying collection or an individual series is. `perPage` is
        // deliberately unused for the page-size cap now (see
        // jsonFeedMaxBooksPerPage) since a client-supplied item count no longer
        // bounds per-request EPUB-parse work once a single item can represent an
        // arbitrary number of books.
        let walkKey = feedWalkKey(for: feedURL)
        let allUnits = await groupedUnitsForWalk(walkKey: walkKey, calibreIDs: calibreIDs)
        let clampedPage = max(page, 1)
        let (pageUnits, hasMore) = paginate(allUnits, page: clampedPage, maxBooksPerPage: Self.jsonFeedMaxBooksPerPage)

        // One structured line per page response — this is the one place that
        // simultaneously knows the page number, pre/post-grouping counts,
        // hasMore, and exactly which book/series-member IDs are in this
        // response, so a "did page 3 actually contain what it should"
        // question can be answered by grepping this one line instead of
        // manually cross-referencing FlyingFox's access log with
        // books.page.end.
        let pageRawBooks = rawBookCount(in: pageUnits)
        LibraryFilterDebug.log("feed.page.end", [
            "feed": title,
            "feedURL": feedURL,
            "page": clampedPage,
            "candidates": calibreIDs.count,
            "groupedTotal": allUnits.count,
            "pageItems": pageUnits.count,
            "pageBooks": pageRawBooks,
            "hasMore": hasMore,
            "ids": flatItemIDs(in: pageUnits).map(String.init).joined(separator: ",")
        ])
        recordFeedWalkPage(key: walkKey, pageItems: pageUnits.count, rawBooks: pageRawBooks)
        if !hasMore {
            flushFeedWalkSummary(key: walkKey, feed: title)
        }

        let etag = computeFeedETag(units: pageUnits, extra: "json:\(allUnits.count):\(clampedPage):\(hasMore)")
        if let ifNoneMatch, ifNoneMatch == etag {
            return .notModified(etag: etag)
        }

        var items: [JSONFeedItem] = []
        for unit in pageUnits {
            switch unit {
            case .book(let pair):
                items.append(await buildJSONFeedItem(book: pair.book, ao3: pair.ao3, seriesEntries: pair.seriesEntries, library: library))
            case .series(let group, let members):
                items.append(await buildGroupedJSONFeedItem(group: group, members: members, library: library))
            }
        }

        let nextURL: String?
        if hasMore {
            let separator = feedURL.contains("?") ? "&" : "?"
            nextURL = "\(feedURL)\(separator)page=\(clampedPage + 1)"
        } else {
            nextURL = nil
        }

        let doc = JSONFeedDocument(
            title: title,
            description: feedDescription,
            home_page_url: nil,
            feed_url: feedURL,
            next_url: nextURL,
            items: items
        )
        let data = (try? Self.jsonFeedEncoder.encode(doc)) ?? buildEmptyJSONFeed(title: title, feedDescription: feedDescription, feedURL: feedURL)
        return .body(etag: etag, data: data)
    }

    private func buildEmptyJSONFeed(title: String, feedDescription: String, feedURL: String) -> Data {
        let doc = JSONFeedDocument(title: title, description: feedDescription, home_page_url: nil, feed_url: feedURL, items: [])
        return (try? Self.jsonFeedEncoder.encode(doc)) ?? Data("{}".utf8)
    }

    // MARK: - Phase 2: SQLite transfer route (build + compress + serve)

    /// One flat `items` row per book — no series grouping here (unlike the
    /// RSS/JSON Feed builders), per Phase 2a. `library`/`metaDB` guards mirror
    /// `buildRSSFeed`'s "no library open" handling: an empty-but-valid
    /// transfer DB rather than an error, so a client polling this route while
    /// no library is open gets a well-formed (empty) response, not a 5xx.
    private func buildSQLiteTransferResponse(calibreIDs: [Int]) async throws -> HTTPResponse {
        guard let library, let metaDB else {
            return try await sqliteResponse(for: [])
        }

        // Wire Contract: skipped books are excluded from `items` entirely.
        // fetchFeedBooks/CollectionStore.members(of:) does NOT already filter
        // these out (confirmed against the dump — see
        // docs/ambrosia-feed-transfer-phase0-findings.md), so it's done
        // explicitly here rather than assumed.
        let skippedIDs = Set((try? await collectionStore?.members(of: SystemCollectionID.skipped)) ?? [])
        let filteredIDs = calibreIDs.filter { !skippedIDs.contains($0) }
        guard !filteredIDs.isEmpty else {
            return try await sqliteResponse(for: [])
        }

        let pairs = await fetchFeedBooks(calibreIDs: filteredIDs, context: "feed:sqlite")

        // Status columns: collection membership, batched the same way
        // fetchFeedBooks batches ao3Map/seriesRows above — one membership
        // query per system collection for this whole build, not per book.
        let readLaterIDs = Set((try? await collectionStore?.members(of: SystemCollectionID.readLater)) ?? [])
        let likedIDs = Set((try? await collectionStore?.members(of: SystemCollectionID.liked)) ?? [])
        let finishedIDs = Set((try? await collectionStore?.members(of: SystemCollectionID.finished)) ?? [])
        let progressByID = await readingProgressByCalibreID(for: filteredIDs)

        var rows: [TransferDatabaseBuilder.Row] = []
        rows.reserveCapacity(pairs.count)
        for pair in pairs {
            rows.append(await transferRow(
                for: pair,
                library: library,
                isReadLater: readLaterIDs.contains(pair.book.id),
                isLiked: likedIDs.contains(pair.book.id),
                isFinished: finishedIDs.contains(pair.book.id),
                readingProgress: progressByID[pair.book.id]
            ))
        }

        LibraryFilterDebug.log("feed.sqlite.end", [
            "candidates": calibreIDs.count,
            "filtered": filteredIDs.count,
            "rows": rows.count,
        ])

        return try await sqliteResponse(for: rows)
    }

    /// `BookState.totalReadPercent` for a batch of calibre IDs, keyed by
    /// calibre ID. Returns an empty map (not a thrown error) when there's no
    /// `ModelContainer` yet or the fetch fails — a missing SwiftData store
    /// means "no progress data available," not "fail the whole route."
    private func readingProgressByCalibreID(for calibreIDs: [Int]) async -> [Int: Double] {
        guard let modelContainer, !calibreIDs.isEmpty else { return [:] }
        let idSet = Set(calibreIDs)
        return await Task.detached(priority: .utility) {
            let context = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<BookState>(
                predicate: #Predicate { idSet.contains($0.calibreID) }
            )
            descriptor.propertiesToFetch = [\.calibreID, \.totalReadPercent]
            guard let states = try? context.fetch(descriptor) else { return [:] }
            return states.reduce(into: [Int: Double]()) { partial, state in
                partial[state.calibreID] = state.totalReadPercent
            }
        }.value
    }

    /// Builds one `items` row. Field-for-field mirrors `buildJSONFeedItem`'s
    /// mapping (same source data: `CalibreBook`, `AO3MetadataRecord`,
    /// `AO3TagBuckets`, `anthologySeriesEntry`) so the two wire formats never
    /// silently disagree about what a given book's metadata is — the only
    /// difference is JSON arrays are Swift `[String]` there and
    /// pre-serialized JSON-text columns here (Wire Contract: `*_json`
    /// columns), since SQLite has no native array type.
    private func transferRow(for pair: FeedBookPair,
                              library: CalibreLibrary,
                              isReadLater: Bool,
                              isLiked: Bool,
                              isFinished: Bool,
                              readingProgress: Double?) async -> TransferDatabaseBuilder.Row {
        let book = pair.book
        let ao3 = pair.ao3

        let summary = book.comment.map { HTMLStripper.strip($0) } ?? ""
        let contentHTML = await cachedMergedHTML(book: book, library: library)

        let datePublished: String?
        if let ao3Date = ao3?.publishedDate, !ao3Date.isEmpty {
            datePublished = iso8601DateString(from: ao3Date)
        } else if let calibreDate = book.publishedDate,
                  calibreDate > Self.calibrePubdateSentinel {
            datePublished = iso8601DateString(from: calibreDate)
        } else {
            datePublished = nil
        }
        let dateModified = ao3?.updatedDate.flatMap { $0.isEmpty ? nil : iso8601DateString(from: $0) }

        let authors: [JSONFeedAuthor] = book.authors.map { name in
            let url = (book.authors.count == 1 ? ao3?.authorUsername : nil)
                .map { "https://archiveofourown.org/users/\($0)" }
            return JSONFeedAuthor(name: name, url: url)
        }

        let buckets = AO3TagBuckets.from(tags: book.tags)
        var seenTags = Set<String>()
        var tags: [String] = []
        for tag in buckets.regular + (ao3?.additionalTags ?? []) {
            if seenTags.insert(tag).inserted { tags.append(tag) }
        }
        func dedup(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        let categories = dedup(buckets.categories + (ao3?.categories ?? []))
        let anthologyEntry = anthologySeriesEntry(for: book, seriesEntries: pair.seriesEntries)
        let seriesEntries = ao3?.series.map { JSONFeedSeriesEntry(name: $0.name, index: $0.index, ao3_id: $0.ao3ID) } ?? []

        func json<T: Encodable>(_ value: T) -> String {
            (try? String(data: Self.jsonFeedEncoder.encode(value), encoding: .utf8)) ?? "[]"
        }

        return TransferDatabaseBuilder.Row(
            calibreID: book.id,
            ao3WorkID: ao3?.workID.flatMap { $0.isEmpty ? nil : $0 },
            isAnthology: anthologyEntry != nil,
            ao3SeriesID: anthologyEntry?.ao3SeriesID,
            seriesName: anthologyEntry != nil && (anthologyEntry?.ao3SeriesID?.isEmpty ?? true) ? anthologyEntry?.seriesName : nil,
            url: ao3?.storyURL,
            title: book.displayTitle,
            contentHTML: contentHTML,
            summary: summary.isEmpty ? nil : summary,
            datePublished: datePublished,
            dateModified: dateModified,
            authorsJSON: json(authors),
            tagsJSON: json(tags),
            wordCount: ao3?.wordCount ?? book.wordCount,
            chapterCurrent: ao3?.chapterCurrent,
            chapterTotal: ao3?.chapterTotal,
            isComplete: ao3?.isComplete,
            fandomsJSON: json(ao3?.fandoms.compactMap { $0.isEmpty ? nil : $0 } ?? []),
            relationshipsJSON: json(ao3?.relationships.compactMap { $0.isEmpty ? nil : $0 } ?? []),
            charactersJSON: json(ao3?.characters.compactMap { $0.isEmpty ? nil : $0 } ?? []),
            ratingsJSON: json(buckets.ratings),
            warningsJSON: json(buckets.warnings),
            categoriesJSON: json(categories),
            seriesJSON: json(seriesEntries),
            isReadLater: isReadLater,
            isLiked: isLiked,
            isFinished: isFinished,
            readingProgress: readingProgress
        )
    }

    /// Writes `rows` to a fresh temp-file SQLite DB, LZFSE-compresses the
    /// file's raw bytes, and returns the HTTP response. Per the Wire
    /// Contract: no `Content-Encoding` header — LZFSE isn't a registered
    /// HTTP content-coding, so this is a deliberate route-specific payload
    /// contract, not content negotiation. A failed build/compress is a hard
    /// error (503) here, not a silent empty-body fallback, since a
    /// truncated/garbled `.sqlite` payload the client can't tell apart from a
    /// valid one is worse than an explicit failure.
    private func sqliteResponse(for rows: [TransferDatabaseBuilder.Row]) async throws -> HTTPResponse {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia-feed-transfer-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try TransferDatabaseBuilder.build(rows: rows, at: tempURL)
        } catch {
            #if DEBUG
            print("[LocalFeedServer] sqlite transfer build failed: \(error)")
            #endif
            return HTTPResponse(statusCode: .internalServerError)
        }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: tempURL)
        } catch {
            return HTTPResponse(statusCode: .internalServerError)
        }

        // NSData.compressed(using:), per the Wire Contract's reference
        // implementation (matches Nectar's CloudKitArticlesZone.swift
        // exactly) — plain Foundation, no `import Compression` needed for
        // this half (unlike Phase 1's gzip work). Unlike the reference's
        // `try?`-swallowed-failure pattern, a failed compress here is a hard
        // error, not a silent fallback (Wire Contract: Compression section).
        let nsData = fileData as NSData
        guard let compressed = try? nsData.compressed(using: .lzfse) else {
            return HTTPResponse(statusCode: .internalServerError)
        }

        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/x-ambrosia-feed-transfer"],
            body: compressed as Data
        )
    }

    private func buildJSONFeedItem(book: CalibreBook,
                                    ao3: AO3MetadataRecord?,
                                    seriesEntries: [SeriesCacheEntry],
                                    library: CalibreLibrary) async -> JSONFeedItem {
        // summary is just the stripped comment now — word count, chapters,
        // completion, fandoms/rating/warnings/categories/series all ride as
        // structured data in `_ambrosia` instead of a prose stats line.
        let summary = book.comment.map { HTMLStripper.strip($0) } ?? ""

        let contentHTML = await cachedMergedHTML(book: book, library: library)

        let datePublished: String?
        if let ao3Date = ao3?.publishedDate, !ao3Date.isEmpty {
            datePublished = iso8601DateString(from: ao3Date)
        } else if let calibreDate = book.publishedDate,
                  calibreDate > Self.calibrePubdateSentinel {
            datePublished = iso8601DateString(from: calibreDate)
        } else {
            datePublished = nil
        }

        // Real author array — one JSONFeedAuthor per author name, unlike RSS's
        // single comma-joined <author>. Only attach an AO3 profile URL when there's
        // exactly one author, since `authorUsername` is a single AO3 field and
        // guessing which of several co-authors it belongs to would be wrong.
        let authors: [JSONFeedAuthor]? = book.authors.isEmpty ? nil : book.authors.map { name in
            let url = (book.authors.count == 1 ? ao3?.authorUsername : nil)
                .map { "https://archiveofourown.org/users/\($0)" }
            return JSONFeedAuthor(name: name, url: url)
        }

        // Plain tag list is freeform only now: Calibre's regular tags (ratings/
        // warnings/categories classified out via AO3TagBuckets) plus AO3's own
        // "Additional Tags" field, which AO3 itself treats as freeform. Fandoms,
        // relationships, characters, ratings, warnings, and categories are all
        // structured entity types, not freeform tags, so they move to `_ambrosia`
        // as their own typed arrays instead of being flattened into `tags`.
        let buckets = AO3TagBuckets.from(tags: book.tags)
        var seenTags = Set<String>()
        var tags: [String] = []
        for tag in buckets.regular + (ao3?.additionalTags ?? []) {
            if seenTags.insert(tag).inserted { tags.append(tag) }
        }

        func dedup(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        let categories = dedup(buckets.categories + (ao3?.categories ?? []))

        let dateModified = ao3?.updatedDate.flatMap { $0.isEmpty ? nil : iso8601DateString(from: $0) }
        let anthologyEntry = anthologySeriesEntry(for: book, seriesEntries: seriesEntries)

        let ambrosiaExtension = JSONFeedAmbrosiaExtension(
            word_count: ao3?.wordCount ?? book.wordCount,
            chapter_current: ao3?.chapterCurrent,
            chapter_total: ao3?.chapterTotal,
            is_complete: ao3?.isComplete,
            fandoms: ao3?.fandoms.compactMap { $0.isEmpty ? nil : $0 },
            relationships: ao3?.relationships.compactMap { $0.isEmpty ? nil : $0 },
            characters: ao3?.characters.compactMap { $0.isEmpty ? nil : $0 },
            ratings: buckets.ratings.isEmpty ? nil : buckets.ratings,
            warnings: buckets.warnings.isEmpty ? nil : buckets.warnings,
            categories: categories.isEmpty ? nil : categories,
            series: ao3?.series.map { JSONFeedSeriesEntry(name: $0.name, index: $0.index, ao3_id: $0.ao3ID) },
            date_modified: dateModified,
            ao3_work_id: ao3?.workID.flatMap { $0.isEmpty ? nil : $0 },
            is_anthology: anthologyEntry != nil ? true : nil,
            ao3_series_id: anthologyEntry?.ao3SeriesID,
            series_name: anthologyEntry != nil && (anthologyEntry?.ao3SeriesID?.isEmpty ?? true) ? anthologyEntry?.seriesName : nil
        )

        return JSONFeedItem(
            id: "ambrosia-book-\(book.id)",
            url: ao3?.storyURL,
            title: book.displayTitle,
            content_html: contentHTML.isEmpty ? nil : contentHTML,
            summary: summary.isEmpty ? nil : summary,
            date_published: datePublished,
            authors: authors,
            tags: tags.isEmpty ? nil : tags,
            _ambrosia: ambrosiaExtension
        )
    }

    /// One JSON Feed item for a whole series group. Sourced from `SeriesGroup`'s
    /// aggregation fields (word/chapter totals, dates, isComplete) plus each
    /// member's own `FeedBookPair` (for merged HTML and raw tags, neither of
    /// which `SeriesGroup` itself carries).
    private func buildGroupedJSONFeedItem(
        group: SeriesGroup,
        members: [FeedBookPair],
        library: CalibreLibrary
    ) async -> JSONFeedItem {
        // Concatenate every member's merged HTML in group order, joined by <hr/>.
        // No per-member failure handling: cachedMergedHTML already swallows parse
        // errors into "" internally and never throws to its caller, so there is
        // no per-book exception to propagate here. Log the empty-result case so a
        // genuinely corrupt EPUB in a series is traceable instead of silently
        // just missing from the concatenated text.
        var htmlParts: [String] = []
        for pair in members {
            let html = await cachedMergedHTML(book: pair.book, library: library)
            if html.isEmpty {
                #if DEBUG
                print("[LocalFeedServer] grouped item \(group.seriesKey): member \(pair.book.id) (\"\(pair.book.displayTitle)\") produced empty merged HTML")
                #endif
            }
            htmlParts.append(html)
        }
        let contentHTML = htmlParts.joined(separator: "\n<hr/>\n")

        let summary = group.allDescriptions.joined(separator: "\n\n")

        // Tag buckets: recompute from the union of every member's raw Calibre
        // tags via AO3TagBuckets.from(tags:) — the same function
        // buildJSONFeedItem uses for singletons — rather than reusing
        // SeriesGroup.allTags/allRatings/allWarnings/allCategories, which are
        // classified via the UI's separate AO3TagKind.classify pipeline and are
        // not guaranteed bucket-exclusive the same way. Reusing SeriesGroup's own
        // fields would let ratings/warnings/categories leak into a grouped
        // item's plain `tags` array while also appearing correctly bucketed in
        // `_ambrosia`, inconsistent with every singleton item in the same feed.
        let unionTags = members.flatMap { $0.book.tags }
        let buckets = AO3TagBuckets.from(tags: unionTags)
        var seenTags = Set<String>()
        var tags: [String] = []
        for tag in buckets.regular + group.allAdditionalTags {
            if seenTags.insert(tag).inserted { tags.append(tag) }
        }
        func dedup(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        let categories = dedup(buckets.categories + group.allCategories)

        let leaderAO3 = members.first?.ao3
        let datePublished = group.earliestPublished.map { iso8601DateString(from: $0) }
        let dateModified = group.latestUpdated.map { iso8601DateString(from: $0) }

        let authors: [JSONFeedAuthor]? = group.allAuthors.isEmpty ? nil : group.allAuthors.map { name in
            let url = (group.allAuthors.count == 1 ? leaderAO3?.authorUsername : nil)
                .map { "https://archiveofourown.org/users/\($0)" }
            return JSONFeedAuthor(name: name, url: url)
        }

        // url: the real AO3 series URL when this group is ao3:-keyed. For a
        // calibre:-keyed group (no AO3 series id), fall back to the leading
        // work's own story URL rather than a constructed URL or nil — per the
        // confirmed decision, since non-AO3 books essentially don't form these
        // groups in practice.
        let url: String?
        if group.seriesKey.hasPrefix("ao3:") {
            let ao3SeriesID = String(group.seriesKey.dropFirst("ao3:".count))
            url = "https://archiveofourown.org/series/\(ao3SeriesID)"
        } else {
            url = leaderAO3?.storyURL
        }

        // series: omitted entirely for grouped items. JSONFeedSeriesEntry.index
        // is a per-work index that has no group-level meaning, and this item's
        // own id/title/url already carry the group's series identity — a
        // single-element series array embedding a placeholder index would be
        // misleading rather than merely redundant, per the confirmed decision.
        let ambrosiaExtension = JSONFeedAmbrosiaExtension(
            word_count: group.totalWordCount,
            chapter_current: group.chapterCurrentTotal,
            chapter_total: group.chapterTotalTotal,
            is_complete: group.isComplete,
            fandoms: group.allFandoms.isEmpty ? nil : group.allFandoms,
            relationships: group.allRelationships.isEmpty ? nil : group.allRelationships,
            characters: group.allCharacters.isEmpty ? nil : group.allCharacters,
            ratings: buckets.ratings.isEmpty ? nil : buckets.ratings,
            warnings: buckets.warnings.isEmpty ? nil : buckets.warnings,
            categories: categories.isEmpty ? nil : categories,
            series: nil,
            date_modified: dateModified,
            ao3_work_id: nil,   // a group has no single AO3 work id
            is_anthology: nil,  // group members are already filtered clear of anthology rows
            ao3_series_id: group.seriesKey.hasPrefix("ao3:") ? String(group.seriesKey.dropFirst(4)) : nil,
            series_name: group.seriesKey.hasPrefix("ao3:") ? nil : group.seriesName
        )

        return JSONFeedItem(
            id: "ambrosia-series-\(group.seriesKey)",
            url: url,
            title: group.seriesName,
            content_html: contentHTML.isEmpty ? nil : contentHTML,
            summary: summary.isEmpty ? nil : summary,
            date_published: datePublished,
            authors: authors,
            tags: tags.isEmpty ? nil : tags,
            _ambrosia: ambrosiaExtension
        )
    }

    /// The `series_cache` row to treat as "the series this book is" for read-state
    /// identity purposes — distinct from ordinary series *membership* (a normal
    /// standalone work that happens to be "Part 3 of Series X"), which must NOT be
    /// used to key read-state, since different parts of a series are different
    /// works with independent read progress.
    ///
    /// Only relevant when `book.isDescriptionAnthology` is true — i.e. Calibre's
    /// EPUB-merge plugin wrote this book's own description, meaning this specific
    /// Calibre row is an entire merged series compiled into one file with no single
    /// AO3 work URL of its own. Do not confuse this with `SeriesCacheEntry.isAnthology`,
    /// which is an unrelated per-series-name *display* toggle (hides individual-work
    /// entries in list views once a merged compilation exists to replace them) and
    /// says nothing about which book the compilation actually is.
    ///
    /// A merged-compilation book is expected to have exactly one meaningful series
    /// row. If more than one somehow exists, take the first by `seriesIndex` and log
    /// rather than silently guessing — this hasn't been observed and may indicate a
    /// bug in how the row got created.
    private func anthologySeriesEntry(for book: CalibreBook, seriesEntries: [SeriesCacheEntry]) -> SeriesCacheEntry? {
        guard book.isDescriptionAnthology else { return nil }
        let sorted = seriesEntries.sorted { $0.seriesIndex < $1.seriesIndex }
        if sorted.count > 1 {
            print("[LocalFeedServer] anthology book \(book.id) has \(sorted.count) series_cache rows; using \(sorted[0].seriesName)")
        }
        return sorted.first
    }

    private func buildStatsLine(book: CalibreBook, ao3: AO3MetadataRecord?) -> String {
        var parts: [String] = []
        if let wc = ao3?.wordCount ?? book.wordCount, wc > 0 {
            parts.append(book.displayWordCount)
        }
        if let fandoms = ao3?.fandoms, !fandoms.isEmpty {
            parts.append(fandoms.prefix(3).joined(separator: ", "))
        }
        if let ao3 {
            // §5: use new case names
            let status = ao3.isComplete
                ? AO3CompletionStatus.complete.rawValue
                : AO3CompletionStatus.workInProgress.rawValue
            parts.append(status)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - §4 point 6: per-item HTML cache

    private func cachedMergedHTML(book: CalibreBook, library: CalibreLibrary) async -> String {
        guard let epubURL = book.epubURL(libraryRoot: library.root) else { return "" }
        let mtime = (try? epubURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
        let cacheKey = HTMLCacheKey(calibreID: book.id, epubMtime: mtime)

        if let cached = htmlCache[cacheKey] { return cached }

        // Parse off-actor so we don't block the server task.
        let html = await Task.detached(priority: .utility) {
            do {
                var parser = EPUBParser(epubURL: epubURL)
                try parser.parse()
                return try parser.mergedHTML(userCSS: "")
            } catch {
                return ""
            }
        }.value

        htmlCache[cacheKey] = html
        htmlCacheOrder.append(cacheKey)
        htmlCacheTotalBytes += html.utf8.count

        // Evict oldest entries until we're back under budget, so a long-running
        // server (client stalls, retries, or an unusually large refresh) can't
        // grow this cache without bound and starve SQLite's own page cache.
        while htmlCacheTotalBytes > htmlCacheMaxBytes, !htmlCacheOrder.isEmpty {
            let evictKey = htmlCacheOrder.removeFirst()
            if let evicted = htmlCache.removeValue(forKey: evictKey) {
                htmlCacheTotalBytes -= evicted.utf8.count
            }
        }

        return html
    }

    // MARK: - UI helpers (called from LibraryWindowController)

    /// Returns all collections. ManageFeedsView uses this for its picker;
    /// per-collection exclusion display is handled in the view using ReaderPreferences.
    func collectionList() async -> [(id: String, name: String)] {
        let rows = (try? await collectionStore?.collections()) ?? []
        return rows.map { ($0.id, $0.name) }
    }

    // MARK: - Helpers

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func htmlEscape(_ s: String) -> String { xmlEscape(s) }

    /// Tries ISO 8601 with fractional seconds, then without, then a bare
    /// yyyy-MM-dd date. Shared by both the RSS (RFC 822) and JSON Feed (ISO 8601)
    /// date formatters below so there's one parsing chain, not two.
    private func parseFlexibleDate(_ isoString: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: isoString) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: isoString) { return date }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: isoString)
    }

    private func rfc822Date(from isoString: String) -> String {
        rfc822Date(from: parseFlexibleDate(isoString) ?? Date.distantPast)
    }

    private func rfc822Date(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private func iso8601DateString(from isoString: String) -> String {
        iso8601DateString(from: parseFlexibleDate(isoString) ?? Date.distantPast)
    }

    private func iso8601DateString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
