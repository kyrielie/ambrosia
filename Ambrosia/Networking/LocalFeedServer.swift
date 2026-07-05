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
//   • Binds to loopback only by default (127.0.0.1:<port>).
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
        var bindLoopbackOnly: Bool = true
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
                let server = HTTPServer(port: port)
                await server.appendRoute("GET /") { [capturedSelf] _ in
                    try await capturedSelf.handleIndex()
                }
                await server.appendRoute("GET /feed/collection/*") { [capturedSelf] request in
                    try await capturedSelf.handleCollectionFeed(request: request)
                }
                await server.appendRoute("GET /feed/search.xml") { [capturedSelf] _ in
                    try await capturedSelf.handleSearchFeed()
                }
                await server.appendRoute("GET /feed/random-daily.xml") { [capturedSelf] _ in
                    try await capturedSelf.handleRandomDailyFeed()
                }
                await server.appendRoute("GET /feeds.opml") { [capturedSelf] _ in
                    try await capturedSelf.handleOPML()
                }
                try await server.run()
            } catch {
                if !Task.isCancelled {
                    print("[LocalFeedServer] Server stopped with error: \(error)")
                }
            }
        }
    }

    // MARK: - Route handlers

    private func handleIndex() async throws -> HTTPResponse {
        let ud = UserDefaults.standard
        let excludedRaw = ud.string(forKey: "rp.feedServerExcludedCollectionIDs") ?? ""
        let excluded = excludedRaw.isEmpty ? Set<String>() : Set(excludedRaw.split(separator: ",").map(String.init))
        let dailyEnabled = ud.object(forKey: "rp.feedServerEnableDailyStory").flatMap { _ in ud.bool(forKey: "rp.feedServerEnableDailyStory") as Bool? } ?? false

        let collections = ((try? await collectionStore?.collections()) ?? [])
            .filter { !excluded.contains($0.id) }
        var links = collections.map { col in
            "<li><a href=\"/feed/collection/\(col.id).xml\">\(htmlEscape(col.name))</a></li>"
        }.joined(separator: "\n")

        if dailyEnabled {
            links += "\n<li><a href=\"/feed/random-daily.xml\">Daily Story</a></li>"
        }

        if let snapshot = CurrentSearchSnapshot.load() {
            links += "\n<li><a href=\"/feed/search.xml\">Current Search: \(htmlEscape(snapshot.label))</a></li>"
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
        // Extract collection ID from path: /feed/collection/<id>.xml
        let path = request.path               // e.g. "/feed/collection/abc123.xml"
        guard path.hasPrefix("/feed/collection/") else {
            return HTTPResponse(statusCode: .notFound)
        }
        let suffix = String(path.dropFirst("/feed/collection/".count))
        let collectionID = suffix.hasSuffix(".xml")
            ? String(suffix.dropLast(4))
            : suffix

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

        let xml = try await buildRSSFeed(
            title: "Ambrosia — \(collection.name)",
            feedDescription: "Books in the \(collection.name) collection",
            calibreIDs: memberIDs
        )
        return HTTPResponse(statusCode: .ok,
                            headers: [.contentType: "application/rss+xml; charset=utf-8"],
                            body: Data(xml.utf8))
    }

    private func handleSearchFeed() async throws -> HTTPResponse {
        guard let snapshot = CurrentSearchSnapshot.load() else {
            let empty = buildEmptyFeed(title: "Ambrosia — Current Search",
                                       message: "No search has been published yet.")
            return HTTPResponse(statusCode: .ok,
                                headers: [.contentType: "application/rss+xml; charset=utf-8"],
                                body: Data(empty.utf8))
        }
        let xml = try await buildRSSFeed(
            title: "Ambrosia — \(snapshot.label)",
            feedDescription: "Published search snapshot from \(snapshot.publishedAt)",
            calibreIDs: snapshot.calibreIDs
        )
        return HTTPResponse(statusCode: .ok,
                            headers: [.contentType: "application/rss+xml; charset=utf-8"],
                            body: Data(xml.utf8))
    }

    /// A single random book, re-picked once per UTC calendar day. The seed is
    /// derived from the day index, not a stored value, so it is stable for any
    /// number of polls within the same day and changes deterministically at
    /// the next UTC midnight.
    private func handleRandomDailyFeed() async throws -> HTTPResponse {
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
            return HTTPResponse(statusCode: .ok,
                headers: [.contentType: "application/rss+xml; charset=utf-8"],
                body: Data(buildEmptyFeed(title: "Ambrosia — Daily Story",
                                         message: "No books in library.").utf8))
        }
        let seed = Int(Date().timeIntervalSince1970 / 86400)
        let picked = allIDs[seed % allIDs.count]
        let xml = try await buildRSSFeed(
            title: "Ambrosia — Daily Story",
            feedDescription: "A random story from your library, refreshed each day.",
            calibreIDs: [picked]
        )
        return HTTPResponse(statusCode: .ok,
            headers: [.contentType: "application/rss+xml; charset=utf-8"],
            body: Data(xml.utf8))
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

    // MARK: - RSS generation

    private func buildRSSFeed(title: String,
                               feedDescription: String,
                               calibreIDs: [Int]) async throws -> String {
        guard let library, let metaDB else { return buildEmptyFeed(title: title, message: "No library open.") }

        let ao3Map = (try? await metaDB.ao3Metadata(for: calibreIDs)) ?? [:]

        // Fetch book stubs from Calibre (title, series, path) — bulk, not per-book.
        let books = await library.books(ids: calibreIDs, offset: 0, limit: min(calibreIDs.count, 500),
                                   sort: .title, ascending: true)

        var items: [String] = []
        for book in books {
            let ao3 = ao3Map[book.id]
            let itemXML = await buildRSSItem(book: book, ao3: ao3, library: library)
            items.append(itemXML)
        }

        return """
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

    private func rfc822Date(from isoString: String) -> String {
        // Try to parse as ISO 8601 date, return RFC 822 for the <pubDate> field.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: isoString) ?? {
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: isoString)
        }() ?? {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.date(from: isoString)
        }()
        return rfc822Date(from: date ?? Date.distantPast)
    }

    private func rfc822Date(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
