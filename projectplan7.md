# Ambrosia — Implementation Plan

---

## 1. EPUB Formatting

### 1.1 Remove redundant "Preface" heading

**Problem.** AO3 EPUBs emit a heading element (`<h1 class="heading">Preface</h1>` or equivalent) at the top of the first spine item. Once rendered in Ambrosia the label is redundant — the spine item is the preface by definition.

**Where to fix.** `EPUBParser.extractBodyContent(from:)`. This static method already strips publisher CSS before returning the body chunk. Add one extra regex pass immediately after the existing strip block, applied only when the spine index is 0. The pattern is tight: match an `<h1>` whose text content is exactly "Preface" (case-insensitive, with optional surrounding whitespace), optionally carrying any class or id attributes. Do not match headings that contain other text.

```swift
// Inside extractBodyContent — apply only for spine item 0
s = s.replacingOccurrences(
    of: #"<h1[^>]*>\s*[Pp]reface\s*</h1>"#,
    with: "",
    options: .regularExpression)
```

`extractBodyContent` does not currently receive a spine index. Add a parameter:

```swift
private static func extractBodyContent(from xhtml: String, isFirstSpineItem: Bool) -> String
```

Update the call site in `mergedHTML(userCSS:)` to pass `item.index == 0`.

**Note on the future `AO3PrefaceRenderer`.** When the renderer described in the formatting brief is implemented it will replace the entire first spine item's body chunk, so this regex strip will become unreachable for AO3 EPUBs with a record in the database. It does no harm to leave it in place as a fallback for EPUBs that failed extraction or have `useAO3PrefaceRenderer` toggled off.

---

### 1.2 End-of-book links: work URL, comment link, series links

**Problem.** AO3 EPUBs include a "Leave a comment" link at the end of the last spine item pointing to the work on AO3. Ambrosia currently has no equivalent. We also want to surface the series links.

**Data available.** `AO3MetadataRecord` already holds:
- `storyURL` — absolute `https://archiveofourown.org/works/<id>` URL
- `workID` — bare numeric string
- `series` — array of `SeriesEntry(name:, index:, ao3ID:?)` where `ao3ID` is the series numeric ID when extraction succeeded

**Where to fix.** `EPUBParser.mergedHTML(userCSS:)`. The method currently does not accept an `AO3MetadataRecord`. Add an optional parameter:

```swift
func mergedHTML(userCSS: String, ao3Record: AO3MetadataRecord? = nil) throws -> String
```

After the `bodyChunks` loop, before assembling the final `<html>` string, check whether `ao3Record` is non-nil and append an endmatter chunk:

```swift
if let record = ao3Record, let workURL = record.storyURL {
    bodyChunks.append(buildAO3Endmatter(record: record, workURL: workURL))
}
```

`buildAO3Endmatter` is a private method on `EPUBParser` returning a plain HTML string. It emits:

```html
<section class="ao3-endmatter">
  <hr>
  <p><a href="https://archiveofourown.org/works/XXXXX">Read on AO3</a></p>
  <p><a href="https://archiveofourown.org/works/XXXXX#add_comment_field">Leave a comment</a></p>
  <!-- one <p> per series where ao3ID is non-nil -->
  <p>Part N of <a href="https://archiveofourown.org/series/YYYYY">Series Name</a></p>
</section>
```

Omit series links where `ao3ID` is nil (extraction did not find the series ID). Do not omit the work and comment links — `storyURL` is extracted from the `<a href>` in the preface so it is reliably present whenever extraction succeeded.

**Threading the record into `mergedHTML`.** `ReaderViewController.reloadHTML()` calls `parser?.mergedHTML(userCSS:)`. The `parser` is an `EPUBParser` stored on `ReaderViewController`. `ReaderViewController` already holds `book: CalibreBook` and uses `AppDelegate.shared?.session?.metaDB` in other places. The cleanest approach: store an optional `AO3MetadataRecord` on `ReaderViewController`, populated asynchronously after the parser loads (same pattern as how `bookStates` are fetched). Pass it into `mergedHTML` on `reloadHTML`. Default to `nil` so the no-record path is unchanged.

---

### 1.3 Future: AO3PrefaceRenderer (from formatting brief)

No immediate code changes. The brief in `ambrosia_formatting_prompt.md` is complete. When implementing:

- `AO3PrefaceRenderer.render(_:preferences:)` replaces the first spine body chunk entirely, so the regex strip in 1.1 becomes a no-op for that path.
- The endmatter from 1.2 is unaffected — it appends after the last spine item regardless of what the first spine item contains.
- Thread `AO3MetadataRecord` into `mergedHTML` as described in 1.2; `AO3PrefaceRenderer` uses the same record, so no additional threading is needed.

---

## 2. RSS Feed

### 2.1 Fix dates showing Dec 31, 2000

**Root cause.** Calibre stores `2000-12-31 00:00:00+00:00` as its sentinel for "no publication date set." `CalibreLibrary.parseDate` parses this successfully into a `Date`, so it passes the `if let calibreDate = book.publishedDate` guard in `buildRSSItem`. The result is an RFC 822 date of "Sat, 31 Dec 2000 00:00:00 +0000" in every item whose book lacks a real pubdate.

**Fix in `LocalFeedServer.buildRSSItem`.** Define the sentinel once and filter it out:

```swift
// Calibre's null-pubdate sentinel: 2000-12-31 00:00:00 UTC
private static let calibrePubdateSentinel: Date = {
    var c = DateComponents()
    c.year = 2000; c.month = 12; c.day = 31
    c.hour = 0; c.minute = 0; c.second = 0
    c.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: c)!
}()
```

Then in `buildRSSItem`, replace the Calibre date branch:

```swift
} else if let calibreDate = book.publishedDate,
          calibreDate > Self.calibrePubdateSentinel {
    pubDateStr = rfc822Date(from: calibreDate)
}
```

The AO3 date branch (string path) is already correct since `rfc822Date(from:isoString:)` has the `yyyy-MM-dd` formatter fallback. Verify that AO3 extraction is succeeding for the affected books by checking whether `ao3?.publishedDate` is populated — if extraction failed the code falls through to the Calibre sentinel, which is the source of the symptom.

---

### 2.2 Add work URL `<link>` and author to RSS items

Currently `buildRSSItem` emits `<title>`, `<guid>`, `<description>`, `<pubDate>`, and `<content:encoded>` but no `<link>` and no `<author>`. Feed readers use `<link>` to make items clickable and `<author>` for attribution.

In `buildRSSItem`, after the `<guid>` line:

```swift
if let workURL = ao3?.storyURL {
    xml += "\n      <link>\(xmlEscape(workURL))</link>"
}
if !book.authors.isEmpty {
    xml += "\n      <author>\(xmlEscape(book.authors.joined(separator: ", ")))</author>"
}
```

Both fields are optional — items without an AO3 record still render correctly.

---

### 2.3 Add `<lastBuildDate>` to channel

`buildRSSFeed` currently emits `<title>`, `<description>`, and `<generator>` on the channel but no date. Feed readers use `<lastBuildDate>` to skip re-fetching unchanged feeds.

In `buildRSSFeed`, add to the channel block:

```swift
<lastBuildDate>\(rfc822Date(from: Date()))</lastBuildDate>
```

This reflects the time the feed was generated, which is the correct semantics — the collection feed re-queries on every GET so the build date is always "now."

---

### 2.4 RSS feed collection selection UI

**Problem.** `presentRSSChoicePanel` uses `NSPopUpButton` inside `NSAlert.accessoryView`. With dozens of collections the dropdown is a long scrolling menu with no filtering.

**Fix.** Replace `presentRSSChoicePanel` with a dedicated `NSPanel` (or `NSWindowController`) hosting a SwiftUI `List` with a search field. The panel is presented as a sheet on the library window.

Structure:

```swift
struct RSSPublishView: View {
    let collections: [(id: String, name: String)]
    let onPublish: (RSSPublishTarget) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""
    @State private var selected: RSSPublishTarget = .currentSearch

    enum RSSPublishTarget {
        case currentSearch
        case collection(id: String, name: String)
    }
    
    // filtered collections based on searchText
    // List with a "Current search results" row at top, then filtered collection rows
    // Publish / Copy Feed URL / Cancel buttons at bottom
    // Warning text below buttons (see 2.5)
}
```

Present it as `NSHostingController` in a sheet:

```swift
private func showRSSPublishSheet() {
    guard let feedServer = session?.feedServer else { return }
    Task { @MainActor in
        let collections = await feedServer.collectionList()
        let host = NSHostingController(rootView: RSSPublishView(
            collections: collections,
            onPublish: { [weak self] target in self?.handleRSSPublish(target: target, feedServer: feedServer) },
            onCancel:  { [weak self] in self?.window?.endSheet(...) }
        ))
        window?.beginSheet(host.window ?? NSWindow())
    }
}
```

The existing logic in `presentRSSChoicePanel` after the `NSAlert` response (snapshot building, URL construction, copy-to-clipboard) moves into `handleRSSPublish(target:feedServer:)` unchanged.

---

### 2.5 OPML export

**New method on `LocalFeedServer`.**

```swift
func generateOPML(baseURL: String) async -> String
```

Implementation:

```swift
func generateOPML(baseURL: String) async -> String {
    let collections = (try? await collectionStore?.collections()) ?? []
    let now = ISO8601DateFormatter().string(from: Date())

    var outlines = collections.map { col in
        """
        <outline type="rss"
                 text="\(xmlEscape(col.name))"
                 title="\(xmlEscape(col.name))"
                 xmlUrl="\(xmlEscape("\(baseURL)/feed/collection/\(col.id).xml"))"/>
        """
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
```

**New route.** In `restartServerTask`, register:

```swift
await server.appendRoute("GET /feeds.opml") { [capturedSelf] _ in
    try await capturedSelf.handleOPML()
}
```

`handleOPML`:

```swift
private func handleOPML() async throws -> HTTPResponse {
    let baseURL = localNetworkURLSync ?? "http://localhost:\(_port)"
    let opml = await generateOPML(baseURL: baseURL)
    return HTTPResponse(
        statusCode: .ok,
        headers: [.contentType: "text/x-opml; charset=utf-8"],
        body: Data(opml.utf8)
    )
}
```

**Export button in `RSSPublishView`.** Add an "Export OPML..." button alongside "Publish" and "Copy Feed URL". On tap:

```swift
func exportOPML(feedServer: LocalFeedServer) {
    Task { @MainActor in
        let baseURL = feedServer.localNetworkURLSync ?? "http://localhost:\(feedServer.port)"
        let opml = await feedServer.generateOPML(baseURL: baseURL)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambrosia-feeds.opml")
        try? opml.write(to: tmp, atomically: true, encoding: .utf8)
        let picker = NSSharingServicePicker(items: [tmp as NSURL])
        picker.show(relativeTo: .zero, of: exportButton, preferredEdge: .minY)
    }
}
```

`NSSharingServicePicker` handles AirDrop, Mail, Messages, and everything else the system offers. No custom AirDrop code needed.

**Warning copy.** In `RSSPublishView`, below the action buttons, always show:

```
Feed URLs are tied to this Mac's current local network address. They will 
break if the address changes, the network changes, or the server is restarted. 
Re-export this file from Ambrosia if feeds stop working.
```

Style it as `.caption` / `.secondary` foreground so it reads as a note rather than an error. Show it regardless of which action the user is about to take — it applies equally to copying a single URL or exporting the OPML.

---

### 2.6 Random daily story feed

**New route.** `GET /feed/random-daily.xml`.

**Implementation.** In `handleRandomDailyFeed`:

1. Compute a day seed: `Int(Date().timeIntervalSince1970 / 86400)`. This is stable for a full calendar day in UTC.
2. Fetch all Calibre IDs from the library (a lightweight query — IDs only, no metadata).
3. Shuffle deterministically using the seed. Swift's `shuffle(using:)` takes an RNG — implement a simple seeded LCG or use the seed to pick an index directly: `let index = seed % allIDs.count`.
4. Call `buildRSSFeed` with that single ID.

```swift
private func handleRandomDailyFeed() async throws -> HTTPResponse {
    guard let library else {
        return HTTPResponse(statusCode: .serviceUnavailable)
    }
    let allIDs = library.allBookIDs()  // new lightweight method on CalibreLibrary
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
```

`CalibreLibrary.allBookIDs()` is a new method: `SELECT id FROM books` — no joins, no metadata, just IDs. Add it to `CalibreLibrary`.

Register the route in `restartServerTask` and add it to both `handleIndex` and `generateOPML` (as a permanent entry — it has no collection ID, just a stable path).

---

## 3. Email View

### 3.1 White flash when loading book in dark mode

**Root cause.** `WKWebView` initialises with a white background. The container `NSView` has `layer?.backgroundColor` set to the reader background color at construction time in `ReaderViewController.loadView()`, but the `WKWebView` itself sits on top and is opaque white until the first HTML load completes and the CSS background color takes effect.

**Fix.** In `ReaderViewController.loadView()`, immediately after `webView = ReaderMenuWebView(frame: .zero, configuration: config)`, set the web view's own background:

```swift
if let bg = Self.nsColor(hex: ReaderPreferences.shared.readerBackgroundColor) {
    webView.underPageBackgroundColor = bg   // macOS 12+ — fills the scroll area
    webView.setValue(false, forKey: "drawsBackground")  // suppress white default draw
}
```

`underPageBackgroundColor` is the correct API for the letterbox area that shows outside the content. Setting `drawsBackground` to false and relying on the container layer color is an alternative, but `underPageBackgroundColor` is the cleaner approach and publicly documented.

**Keep it current on preference changes.** `subscribeToPreferences()` already triggers `reloadHTML()` on any preference change, which reloads the HTML with updated CSS. But `underPageBackgroundColor` is not updated by a CSS reload — it must be set imperatively. Add a line inside the `prefsCancellable` sink, before or after `reloadHTML()`:

```swift
if let bg = Self.nsColor(hex: ReaderPreferences.shared.readerBackgroundColor) {
    self?.webView.underPageBackgroundColor = bg
    self?.view.layer?.backgroundColor = bg.cgColor
}
```

**In `EmailLibraryViewController.makeRightVC()`.** The appearance is already set via `rvc.view.appearance = ReaderPreferences.shared.resolvedLibraryNSAppearance`. No change needed here — the fix in `ReaderViewController.loadView()` fires before the view is ever added to any hierarchy, so the web view already has the correct background by the time it appears.

---

### 3.2 Performance: slow book load when switching between email and row view

**Symptom.** 1-2 second delay when selecting a book in email view or switching back to email view from row view.

**Diagnosis first.** Before changing any code, profile with Instruments Time Profiler with the "Email view" scenario. The two most likely hotspots are:

1. The `[StarDiag]` and `[FlashDiag]` print statements in `BookGridItem.swift` (already flagged as high severity in `ambrosia_audit.md`). Seven of them include `Thread.callStackSymbols.prefix(6)` which allocates a full stack trace on every call. These fire on every `refreshBookStates()` which runs on every book selection in email view. **Remove all `[StarDiag]` and `[FlashDiag]` print statements unconditionally.** This is a correctness fix as much as a performance fix — they should never have shipped outside `#if DEBUG`.

2. `replaceRightPane(with:)` removes and re-inserts an `NSSplitViewItem` on every book selection, which triggers a full `NSSplitView` layout pass. This is inherent to the current architecture. The mitigation is to check whether the selected book is already loaded before replacing:

```swift
private func selectBook(_ book: CalibreBook) {
    guard book.id != selectedBook?.id else { return }
    selectedBook = book
    // ... existing teardown and makeRightVC() call
}
```

If the user clicks the same row twice this short-circuits the entire replace path.

**If profiling shows the database fetch is the bottleneck.** `loadPage(reset:)` re-queries on every mode switch. A simple cache: store the last `(searchText, filterToken, page)` tuple and the resulting `[CalibreBook]` array. On mode switch back to email view, render stale data immediately from the cache and fire a background refresh. The stale window is at most the duration of the mode switch, which is acceptable.

---

## 4. Preferences Window

### 4.1 Scrolling in Data tab is not smooth

**Root cause.** `DataTab.body` wraps a `Form` inside a `ScrollView`. On macOS 14, `SwiftUI.Form` with `.grouped` style is internally scrollable — the outer `ScrollView` creates two scroll contexts fighting each other, which causes janky layout recalculations on every scroll event.

**Fix.** Remove the outer `ScrollView`:

```swift
var body: some View {
    Form {
        // ... all existing sections unchanged
    }
    .formStyle(.grouped)
    .padding(.bottom, 8)
    .onAppear {
        reloadKnownLibraries()
        tagSeedConfig.refreshValidation()
        loadAvailableColumns()
    }
}
```

`Form` with `.grouped` style on macOS 14 handles its own scrolling. Verify that the `ReaderTab` and `LibraryTab` use the same pattern — if they also have `ScrollView { Form { } }`, fix them too for consistency. This is a one-line removal per tab.

---

### 4.2 Closing the window is not smooth

**Root cause.** When the preferences window closes, SwiftUI tears down `PreferencesRootView` while `@ObservedObject private var prefs = ReaderPreferences.shared` is still live. The `objectWillChange` publisher fires once during teardown (any lingering `@Published` property change), triggering a layout pass on a view hierarchy that is mid-deallocation.

The secondary cause is `DataTab.onAppear` firing tasks (`reloadKnownLibraries`, `loadAvailableColumns`) that may still be in flight when the window closes, completing and attempting to write to `@State` properties on the disappeared view.

**Fix 1.** The tasks in `onAppear` should be tracked and cancelled in `onDisappear`:

```swift
@State private var loadTask: Task<Void, Never>?

.onAppear {
    loadTask = Task {
        await reloadKnownLibraries()
        tagSeedConfig.refreshValidation()
        await loadAvailableColumns()
    }
}
.onDisappear {
    loadTask?.cancel()
    loadTask = nil
}
```

Both `reloadKnownLibraries` and `loadAvailableColumns` need to check `Task.isCancelled` at their yield points, or wrap their `@State` writes in `guard !Task.isCancelled else { return }`.

**Fix 2.** If the close animation is still janky after Fix 1, set the window's `animationBehavior`:

```swift
window.animationBehavior = .documentWindow
```

in `PreferencesWindowController.init`. The default behavior for a non-document window can cause a mismatched animation style that looks like a stutter.

**Profile before shipping Fix 2.** Use Instruments "Animation Hitches" template on the close gesture to confirm whether the jank is a layout pass (fix the task cancellation) or an animation mismatch (fix the animationBehavior).

---

## 5. Files Modified

| File | Changes |
|---|---|
| `Reader/EPUBParser.swift` | `extractBodyContent(from:isFirstSpineItem:)` — add param + Preface strip; `mergedHTML(userCSS:ao3Record:)` — add optional record param + endmatter emission; `buildAO3Endmatter(record:workURL:)` — new private method |
| `Reader/ReaderViewController.swift` | `loadView()` — set `underPageBackgroundColor` and `drawsBackground`; `prefsCancellable` sink — update background color on pref change; store optional `ao3Record: AO3MetadataRecord?`; pass it to `mergedHTML` in `reloadHTML()` |
| `LibraryUI/Email/EmailLibraryViewController.swift` | `selectBook(_:)` — add early-return guard for same book; remove or gate `[StarDiag]`/`[FlashDiag]` print statements |
| `LibraryUI/BookGridItem.swift` | Remove all `[StarDiag]` and `[FlashDiag]` print statements |
| `Networking/LocalFeedServer.swift` | `buildRSSItem` — sentinel date guard, `<link>`, `<author>`; `buildRSSFeed` — add `<lastBuildDate>`; `generateOPML(baseURL:)` — new method; `handleOPML()` — new handler; `handleRandomDailyFeed()` — new handler; register new routes in `restartServerTask`; `calibrePubdateSentinel` — new static constant |
| `Database/CalibreLibrary.swift` | `allBookIDs()` — new lightweight method returning `[Int]` |
| `LibraryUI/LibraryWindowController.swift` | Replace `presentRSSChoicePanel` with `showRSSPublishSheet` + `handleRSSPublish(target:feedServer:)`; new `exportOPML(feedServer:)` method |
| `LibraryUI/RSSPublishView.swift` | **New file.** SwiftUI view for publish sheet — searchable collection list, target selection, warning copy, Publish / Copy URL / Export OPML buttons |
| `Preferences/PreferencesWindowController.swift` | `DataTab` — remove outer `ScrollView`; `onAppear`/`onDisappear` task tracking; verify same pattern in `ReaderTab` and `LibraryTab` |
