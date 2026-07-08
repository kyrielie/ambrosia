import Foundation
import Darwin
import FlyingFox

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
// A tiny UserDefaults key: "feedServer.currentSearchSnapshot"
// Stored as JSON: { "ids": [Int], "timestamp": ISO8601 String, "label": String }
// Explicitly a snapshot — not re-queried on every poll.

struct CurrentSearchSnapshot: Codable {
    let calibreIDs: [Int]
    let publishedAt: String     // ISO 8601
    let label: String           // e.g. "tag: Horror" — displayed in the feed title
}

extension CurrentSearchSnapshot {
    private static let defaultsKey = "feedServer.currentSearchSnapshot"

    static func load() -> CurrentSearchSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CurrentSearchSnapshot.self, from: data)
    }

    func save() {
        let data = try? JSONEncoder().encode(self)
        UserDefaults.standard.set(data, forKey: CurrentSearchSnapshot.defaultsKey)
    }

    static func publish(calibreIDs: [Int], label: String) {
        let snapshot = CurrentSearchSnapshot(
            calibreIDs: calibreIDs,
            publishedAt: ISO8601DateFormatter().string(from: Date()),
            label: label.isEmpty ? "Current Search" : label
        )
        snapshot.save()
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
    private var htmlCache: [HTMLCacheKey: String] = [:]

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
               config: Config = Config()) {
        self.library = library
        self.metaDB  = metaDB
        self.collectionStore = collectionStore
        self.config  = config
        _port = config.port
        restartServerTask()
        _isRunning = true
    }

    /// Stop the server and release library references.
    func stop() {
        serverTask?.cancel()
        serverTask = nil
        _isRunning = false
        library = nil
        metaDB  = nil
        collectionStore = nil
        htmlCache.removeAll()
    }

    /// Replace library references on a library switch without restarting the task.
    func updateLibrary(_ library: CalibreLibrary,
                       metaDB: AmbrosiaMetaDB,
                       collectionStore: CollectionStore) {
        self.library = library
        self.metaDB  = metaDB
        self.collectionStore = collectionStore
        htmlCache.removeAll()   // stale EPUB cache
    }

    // MARK: - Private: server task

    private func restartServerTask() {
        serverTask?.cancel()
        let capturedSelf = self
        let port = config.port
        serverTask = Task {
            do {
                let server = HTTPServer(address: .inet(port: port))
                await server.appendRoute("GET /") { [capturedSelf] _ in
                    try await capturedSelf.handleIndex()
                }
                await server.appendRoute("GET /feed/collection/*") { [capturedSelf] request in
                    try await capturedSelf.handleCollectionFeed(request: request)
                }
                await server.appendRoute("GET /feed/search.xml") { [capturedSelf] request in
                    try await capturedSelf.handleSearchFeed(format: .rss, request: request)
                }
                await server.appendRoute("GET /feed/search.json") { [capturedSelf] request in
                    try await capturedSelf.handleSearchFeed(format: .json, request: request)
                }
                await server.appendRoute("GET /feed/random-daily.xml") { [capturedSelf] request in
                    try await capturedSelf.handleRandomDailyFeed(format: .rss, request: request)
                }
                await server.appendRoute("GET /feed/random-daily.json") { [capturedSelf] request in
                    try await capturedSelf.handleRandomDailyFeed(format: .json, request: request)
                }
                await server.appendRoute("GET /feeds.opml") { [capturedSelf] _ in
                    try await capturedSelf.handleOPML()
                }
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
    }

    private func handleIndex() async throws -> HTTPResponse {
        let ud = UserDefaults.standard
        let excludedRaw = ud.string(forKey: "rp.feedServerExcludedCollectionIDs") ?? ""
        let excluded = excludedRaw.isEmpty ? Set<String>() : Set(excludedRaw.split(separator: ",").map(String.init))
        let dailyEnabled = ud.object(forKey: "rp.feedServerEnableDailyStory").flatMap { _ in ud.bool(forKey: "rp.feedServerEnableDailyStory") as Bool? } ?? false

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

        if let snapshot = CurrentSearchSnapshot.load() {
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
        let format: FeedFormat = suffix.hasSuffix(".json") ? .json : .rss
        let collectionID: String
        if suffix.hasSuffix(".json") {
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
        let excludedRaw = UserDefaults.standard.string(forKey: "rp.feedServerExcludedCollectionIDs") ?? ""
        let excluded = excludedRaw.isEmpty ? Set<String>() : Set(excludedRaw.split(separator: ",").map(String.init))
        guard !excluded.contains(collectionID) else {
            return HTTPResponse(statusCode: .notFound)
        }
        let memberIDs = (try? await collectionStore?.members(of: collectionID)) ?? []

        switch format {
        case .rss:
            let result = try await buildRSSFeed(
                title: "Ambrosia — \(collection.name)",
                feedDescription: "Books in the \(collection.name) collection",
                calibreIDs: memberIDs,
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/rss+xml; charset=utf-8") { Data($0.utf8) }
        case .json:
            let baseURL = localNetworkURLSync ?? "http://localhost:\(_port)"
            let page = Int(request.query["page"] ?? "") ?? 1
            let perPage = Int(request.query["per_page"] ?? "") ?? Self.jsonFeedDefaultPerPage
            let result = try await buildJSONFeed(
                title: "Ambrosia — \(collection.name)",
                feedDescription: "Books in the \(collection.name) collection",
                calibreIDs: memberIDs,
                feedURL: "\(baseURL)/feed/collection/\(collectionID).json",
                page: page,
                perPage: perPage,
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/feed+json; charset=utf-8") { $0 }
        }
    }

    private func handleSearchFeed(format: FeedFormat, request: HTTPRequest) async throws -> HTTPResponse {
        guard let snapshot = CurrentSearchSnapshot.load() else {
            switch format {
            case .rss:
                let empty = buildEmptyFeed(title: "Ambrosia — Current Search",
                                           message: "No search has been published yet.")
                return HTTPResponse(statusCode: .ok,
                                    headers: [.contentType: "application/rss+xml; charset=utf-8"],
                                    body: Data(empty.utf8))
            case .json:
                let empty = buildEmptyJSONFeed(title: "Ambrosia — Current Search",
                                               feedDescription: "No search has been published yet.",
                                               feedURL: "\(localNetworkURLSync ?? "http://localhost:\(_port)")/feed/search.json")
                return HTTPResponse(statusCode: .ok,
                                    headers: [.contentType: "application/feed+json; charset=utf-8"],
                                    body: empty)
            }
        }
        switch format {
        case .rss:
            let result = try await buildRSSFeed(
                title: "Ambrosia — \(snapshot.label)",
                feedDescription: "Published search snapshot from \(snapshot.publishedAt)",
                calibreIDs: snapshot.calibreIDs,
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/rss+xml; charset=utf-8") { Data($0.utf8) }
        case .json:
            let baseURL = localNetworkURLSync ?? "http://localhost:\(_port)"
            let page = Int(request.query["page"] ?? "") ?? 1
            let perPage = Int(request.query["per_page"] ?? "") ?? Self.jsonFeedDefaultPerPage
            let result = try await buildJSONFeed(
                title: "Ambrosia — \(snapshot.label)",
                feedDescription: "Published search snapshot from \(snapshot.publishedAt)",
                calibreIDs: snapshot.calibreIDs,
                feedURL: "\(baseURL)/feed/search.json",
                page: page,
                perPage: perPage,
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/feed+json; charset=utf-8") { $0 }
        }
    }

    /// A single random book, re-picked once per UTC calendar day. The seed is
    /// derived from the day index, not a stored value, so it is stable for any
    /// number of polls within the same day and changes deterministically at
    /// the next UTC midnight.
    private func handleRandomDailyFeed(format: FeedFormat, request: HTTPRequest) async throws -> HTTPResponse {
        let ud = UserDefaults.standard
        let dailyEnabled = ud.object(forKey: "rp.feedServerEnableDailyStory").flatMap { _ in ud.bool(forKey: "rp.feedServerEnableDailyStory") as Bool? } ?? false
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
                    body: Data(buildEmptyFeed(title: "Ambrosia — Daily Story",
                                             message: "No books in library.").utf8))
            case .json:
                let empty = buildEmptyJSONFeed(title: "Ambrosia — Daily Story",
                                               feedDescription: "No books in library.",
                                               feedURL: "\(localNetworkURLSync ?? "http://localhost:\(_port)")/feed/random-daily.json")
                return HTTPResponse(statusCode: .ok,
                    headers: [.contentType: "application/feed+json; charset=utf-8"],
                    body: empty)
            }
        }
        let seed = Int(Date().timeIntervalSince1970 / 86400)
        let picked = allIDs[seed % allIDs.count]
        switch format {
        case .rss:
            let result = try await buildRSSFeed(
                title: "Ambrosia — Daily Story",
                feedDescription: "A random story from your library, refreshed each day.",
                calibreIDs: [picked],
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/rss+xml; charset=utf-8") { Data($0.utf8) }
        case .json:
            let baseURL = localNetworkURLSync ?? "http://localhost:\(_port)"
            let result = try await buildJSONFeed(
                title: "Ambrosia — Daily Story",
                feedDescription: "A random story from your library, refreshed each day.",
                calibreIDs: [picked],
                feedURL: "\(baseURL)/feed/random-daily.json",
                ifNoneMatch: ifNoneMatchHeader(request)
            )
            return httpResponse(for: result, contentType: "application/feed+json; charset=utf-8") { $0 }
        }
    }

    /// Generates an OPML 2.0 outline of every collection feed, plus the
    /// current-search snapshot feed when one has been published. The random
    /// daily feed is a permanent entry — it has no collection ID and is
    /// always available once a library is open.
    func generateOPML(baseURL: String) async -> String {
        let ud = UserDefaults.standard
        let excludedRaw = ud.string(forKey: "rp.feedServerExcludedCollectionIDs") ?? ""
        let excluded = excludedRaw.isEmpty ? Set<String>() : Set(excludedRaw.split(separator: ",").map(String.init))
        let dailyEnabled = ud.object(forKey: "rp.feedServerEnableDailyStory").flatMap { _ in ud.bool(forKey: "rp.feedServerEnableDailyStory") as Bool? } ?? false

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

        if let snapshot = CurrentSearchSnapshot.load() {
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
    private func fetchFeedBooks(calibreIDs: [Int]) async -> [(book: CalibreBook, ao3: AO3MetadataRecord?)] {
        guard let library, let metaDB, !calibreIDs.isEmpty else { return [] }
        let ao3Map = (try? await metaDB.ao3Metadata(for: calibreIDs)) ?? [:]
        // No cap here — callers decide how many IDs to pass in. RSS passes the
        // full list (no pagination protocol exists for RSS); JSON Feed passes
        // one page's worth (see buildJSONFeed's page/per_page handling).
        let books = await library.books(ids: calibreIDs, offset: 0, limit: calibreIDs.count,
                                   sort: .title, ascending: true)
        return books.map { ($0, ao3Map[$0.id]) }
    }

    /// A cheap ETag over the fetched pairs plus any pagination/format params that
    /// affect the response shape. Reflects collection-membership changes (the pair
    /// list itself) and AO3 re-extraction (`ao3.updatedDate`) — it does not reflect
    /// a bare Calibre comment/tag edit made outside AO3 extraction, since that has
    /// no cheap-to-read "last modified" signal available here. Good enough to skip
    /// the expensive per-item work on a repeat poll where nothing relevant changed;
    /// not a substitute for a real content-hash if that gap matters later.
    private func computeFeedETag(pairs: [(book: CalibreBook, ao3: AO3MetadataRecord?)],
                                  extra: String) -> String {
        var combined = extra
        for (book, ao3) in pairs {
            combined += "|\(book.id):\(ao3?.updatedDate ?? "")"
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

    private func httpResponse<Body>(for result: FeedBuildResult<Body>,
                                     contentType: String,
                                     toData: (Body) -> Data) -> HTTPResponse {
        switch result {
        case .notModified(let etag):
            return HTTPResponse(statusCode: .notModified, headers: [.eTag: etag])
        case .body(let etag, let data):
            return HTTPResponse(statusCode: .ok,
                                headers: [.contentType: contentType, .eTag: etag],
                                body: toData(data))
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

        let pairs = await fetchFeedBooks(calibreIDs: calibreIDs)
        let etag = computeFeedETag(pairs: pairs, extra: "rss")
        if let ifNoneMatch, ifNoneMatch == etag {
            return .notModified(etag: etag)
        }

        var items: [String] = []
        for (book, ao3) in pairs {
            let itemXML = await buildRSSItem(book: book, ao3: ao3, library: library)
            items.append(itemXML)
        }

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
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
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let jsonFeedDefaultPerPage = 100
    private static let jsonFeedMaxPerPage = 500

    private func buildJSONFeed(title: String,
                                feedDescription: String,
                                calibreIDs: [Int],
                                feedURL: String,
                                page: Int = 1,
                                perPage: Int = jsonFeedDefaultPerPage,
                                ifNoneMatch: String?) async throws -> FeedBuildResult<Data> {
        guard let library else {
            return .body(etag: "\"empty\"",
                        data: buildEmptyJSONFeed(title: title, feedDescription: "No library open.", feedURL: feedURL))
        }

        // Cheap SQL fetch returns every matching book, title-sorted. Only the
        // current page's slice gets the expensive per-item work below (full
        // merged EPUB HTML), so payload size stays bounded no matter how large
        // the underlying collection is.
        let allPairs = await fetchFeedBooks(calibreIDs: calibreIDs)
        let clampedPerPage = min(max(perPage, 1), Self.jsonFeedMaxPerPage)
        let clampedPage = max(page, 1)
        let start = (clampedPage - 1) * clampedPerPage
        let pagePairs: [(book: CalibreBook, ao3: AO3MetadataRecord?)]
        if start < allPairs.count {
            pagePairs = Array(allPairs[start..<min(start + clampedPerPage, allPairs.count)])
        } else {
            pagePairs = []
        }

        let hasMore = start + clampedPerPage < allPairs.count
        let etag = computeFeedETag(pairs: pagePairs, extra: "json:\(allPairs.count):\(clampedPage):\(clampedPerPage):\(hasMore)")
        if let ifNoneMatch, ifNoneMatch == etag {
            return .notModified(etag: etag)
        }

        var items: [JSONFeedItem] = []
        for (book, ao3) in pagePairs {
            items.append(await buildJSONFeedItem(book: book, ao3: ao3, library: library))
        }

        let nextURL: String?
        if hasMore {
            let separator = feedURL.contains("?") ? "&" : "?"
            nextURL = "\(feedURL)\(separator)page=\(clampedPage + 1)&per_page=\(clampedPerPage)"
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

    private func buildJSONFeedItem(book: CalibreBook,
                                    ao3: AO3MetadataRecord?,
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

        let ambrosiaExtension = JSONFeedAmbrosiaExtension(
            word_count: ao3?.wordCount ?? book.wordCount,
            chapter_current: ao3?.chapterCurrent,
            chapter_total: ao3?.chapterTotal,
            is_complete: ao3?.isComplete,
            fandoms: ao3?.fandoms.flatMap { $0.isEmpty ? nil : $0 },
            relationships: ao3?.relationships.flatMap { $0.isEmpty ? nil : $0 },
            characters: ao3?.characters.flatMap { $0.isEmpty ? nil : $0 },
            ratings: buckets.ratings.isEmpty ? nil : buckets.ratings,
            warnings: buckets.warnings.isEmpty ? nil : buckets.warnings,
            categories: categories.isEmpty ? nil : categories,
            series: ao3?.series.map { JSONFeedSeriesEntry(name: $0.name, index: $0.index, ao3_id: $0.ao3ID) },
            date_modified: dateModified
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
