# Phase 0 — Verification findings

Checked against the actual dump (`ambrosia.xml`) rather than assumed. One item
could not be verified from the dump and is flagged as a stop-and-flag for a
human/Xcode check before Phase 1 lands.

## FlyingFox response API — CONFIRMED

`LocalFeedServer.swift` already constructs `HTTPResponse` with a custom
`headers:` dictionary in multiple places (`handleIndex`, `httpResponse(for:)`,
the ETag/`If-None-Match` handling), e.g.:

```swift
return HTTPResponse(statusCode: .ok,
                    headers: [.contentType: contentType, .eTag: etag],
                    body: toData(data))
```

and a custom header key is already read via `HTTPHeader("If-None-Match")` in
`ifNoneMatchHeader(_:)`. So: arbitrary custom headers (needed for
`Content-Encoding: gzip`) are already supported by the version of FlyingFox in
use — no new capability needed for Phase 1.

`Range`/file-serving support was not found anywhere in the dump. Not needed
for v1 (per the plan), so left unconfirmed — flag before ever adding
resumable `.sqlite` downloads later.

## Compression APIs — PARTIALLY CONFIRMED, ONE GOTCHA FOUND

Nothing in the dump imports `Compression` or `zlib`, or does any gzip/deflate
work anywhere today — this is new ground, not a reuse of an existing helper.

For the **LZFSE** side (Phase 2), the Wire Contract's reference implementation
is directly confirmed against Nectar's existing code
(`CloudKitArticlesZone.swift` / `CloudKitArticlesZoneDelegate.swift`), which
uses `NSData.compressed(using:)` / `.decompressed(using:)` — plain Foundation,
no `Compression` import. Ambrosia is Swift/Foundation on macOS, so the same
API is available; used as-is in Phase 2.

For the **gzip** side (Phase 1) there is a real gotcha, not just a library
choice: `NSData.compressed(using: .zlib)` (the other Foundation-native
option) produces a **zlib-framed** deflate stream (RFC 1950 — 2-byte header,
Adler-32 trailer), **not** a gzip-framed stream (RFC 1952 — 10-byte header
with magic bytes `1f 8b`, CRC-32 + ISIZE trailer). `URLSession` on the Nectar
side only transparently decodes a response advertised as
`Content-Encoding: gzip` if the bytes are actually gzip-framed; feeding it
zlib-framed bytes under that header will fail to decode (or decode garbage)
client-side, silently, since nothing round-trip-tests this locally.

Resolution used in Phase 1 (see that commit): raw-deflate via
`compression_encode_buffer` (`COMPRESSION_ZLIB` — Apple's naming for raw
zlib/deflate, confusingly not gzip-framed either) from the `Compression`
framework, manually wrapped in a minimal gzip envelope (10-byte header +
CRC-32 + little-endian ISIZE trailer) so the bytes are real RFC 1952 gzip.
This is a small, self-contained utility (`GzipEncoder.swift`) with no third
-party dependency.

**Not independently confirmed:** whether `Compression` (`compression_encode_
buffer`) is linkable as-is on the Ambrosia macOS target without adding it to
the Xcode target's linked frameworks — this needs an actual build, which
isn't possible from a source dump alone. Flagging this as the one Phase 0 item
still open before Phase 1 merges: **do a clean build after adding
`import Compression` to confirm no linker error.** If it fails to link, the
fallback is to build gzip framing over `compression_encode_buffer`'s sibling
`COMPRESSION_LZFSE`... no — LZFSE doesn't help here, gzip specifically needs
deflate. The fallback in that case is vendoring a small raw-deflate
implementation or adding `zlib` via SPM; either is a bigger change than this
plan scopes, so a linker failure here should come back as a stop-and-flag,
not a silent substitution.

## SQLite.swift usage pattern — CONFIRMED

`AmbrosiaMetaDB.init` does exactly `Connection(writePath)` / `Connection(path:
readonly:)` against a plain file path with no other setup beyond `PRAGMA
journal_mode`/`synchronous` and its own migrations. `Connection(path:)` does
not assume anything about schema — confirmed by reading `SQLite.swift`'s
usage here, there is nothing library-specific tying a `Connection` to
`ambrosia_meta.db`'s particular tables. A fresh `Connection` against a new
temp-file path for the transfer DB's own `items` table works the same way.

No read/write split is needed for the transfer DB (single write-then-close
lifecycle, no concurrent readers) — Phase 2a uses one `Connection`, not the
read/write pair `AmbrosiaMetaDB` uses for its own long-lived database.

## `fetchFeedBooks`/`LibraryVisibilityPolicy.swift` — CONFIRMED: NOT already excluded

`LocalFeedServer.fetchFeedBooks` gets its candidate ID list from
`CollectionStore.members(of:)`:

```swift
func members(of collectionID: String) async throws -> [Int] {
    let rows = try await db.prepare(
        "SELECT calibre_id FROM collection_members WHERE collection_id = ? ORDER BY added_at, calibre_id ASC",
        [collectionID]
    )
    ...
}
```

This is a raw, unfiltered `collection_members` query — it does not consult
`LibraryVisibilityPolicy` (which is wired into the *app's own* library
browsing paths — `LibraryQueryHelpers.visibleIDs`, `CalibreLibrary`'s sorted
page fetchers — not into `CollectionStore`/`LocalFeedServer`). The existing
`.xml`/`.json` feed routes therefore already include skipped-collection books
today if a skipped book also happens to be a member of the collection being
served (skipped and normal collections aren't mutually exclusive).

Conclusion for Wire Contract's `skipped` exclusion: this needs **new,
explicit filtering** in the `.sqlite` route — it does not fall out of reusing
`fetchFeedBooks` unchanged. Implemented in Phase 2a by intersecting the
fetched pair list against `collectionStore.members(of: SystemCollectionID.
skipped)` before building rows (see that commit).

## LZFSE API confirmation — CONFIRMED available

`NSData.compressed(using:)`/`.decompressed(using:)` are plain Foundation API
present since macOS 10.15, which predates every macOS version Ambrosia (a
current Swift/Foundation macOS app) could plausibly still target. No
`import Compression` needed for this half, matching the Wire Contract's
reference implementation exactly.

## One item found that the plan itself didn't anticipate: BookState access from LocalFeedServer

The Wire Contract's `reading_progress` column needs `BookState.
totalReadPercent`, which is SwiftData, not `AmbrosiaMetaDB`/SQLite. But
`LocalFeedServer` (an `actor`, started via `LibrarySession.startFeedServer`)
is never given a `ModelContainer` anywhere in the dump — `LibrarySession`
itself doesn't hold one either. The only places a `ModelContainer` exists
today are `AmbrosiaApp.init()` (`sharedModelContainer`) and call sites that
already have one threaded through (`ReaderWindowController`,
`LibraryWindowController`, `ActivityFeedView`, `EmailLibraryViewController`).

This is Ambrosia-side plumbing, not a Wire Contract concern, so it's handled
locally rather than flagged to the Nectar side: `LibrarySession` gains a
`modelContainer: ModelContainer?` property, set once from `AmbrosiaApp.init()`
right alongside `appDelegate.modelContainer = container`, and threaded into
`LocalFeedServer.start(...)` so Phase 2a can open a `ModelContext` for the
status/progress columns. See the Phase 2a commit.
