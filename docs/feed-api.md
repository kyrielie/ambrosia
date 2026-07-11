# Ambrosia Local Feed Server — API Contract

Versioned reference for anyone consuming `LocalFeedServer`'s HTTP API from
outside the Ambrosia repo. Build against this document, not by reading
Swift source. If this document and the code ever disagree, that's a bug —
file it against the code, since this doc is the contract.

Server: an in-process HTTP server (FlyingFox) started from Ambrosia's
Preferences, off by default. One instance per open library, scoped to that
library's collections and metadata.

---

## 1. Routes

| Route | Formats | Notes |
|---|---|---|
| `GET /` | HTML | Index page listing every available feed as links. |
| `GET /feed/collection/<id>.xml` \| `.json` | RSS 2.0 / JSON Feed 1.1 | One item per book currently in the named collection. |
| `GET /feed/search.xml` \| `.json` | RSS 2.0 / JSON Feed 1.1 | The last-published current-search snapshot (see §7). |
| `GET /feed/random-daily.xml` \| `.json` | RSS 2.0 / JSON Feed 1.1 | One seeded-random book, stable per UTC calendar day. Opt-in; `404` if the user hasn't enabled it. |
| `GET /feeds.opml` | OPML 2.0 | Every non-excluded collection feed, plus the daily and search feeds when applicable. |

`.xml` is RSS 2.0. `.json` is JSON Feed 1.1. **These are two views of the
same underlying data, not a legacy/current split** — RSS is not going away,
and both are maintained routes.

Every route above except `/feeds.opml`'s child links resolves against the
currently-open library only. There is one server per open library; pairing
a second library means a second base URL/token, not a second route on the
same server.

**Known inconsistency:** `generateOPML` currently appends `?token=` to the
`xmlUrl` for collection and daily-story outlines, but not to the search
feed outline. Since every route requires the token (§2), the search feed
link exported via OPML will 401 as written. Flagging here rather than
silently documenting it as correct; this needs a code fix, not a doc
workaround.

---

## 2. Auth

Every route, **including `/`**, requires the per-library shared-secret
token. Supply it as either:

- Query parameter: `?token=<token>`
- Header: `X-Ambrosia-Token: <token>`

Missing or wrong token → `401 Unauthorized` with a plain-text body.

This is a **shared secret, not per-device identity.** There is no
revocation of a single device — regenerating the token invalidates it
for everyone who had it, all at once. Anyone with a URL containing a valid
token has full read access to that library's feeds (titles, summaries,
full merged chapter HTML, and all `_ambrosia` metadata below) until the
token is regenerated. Treat a feed URL like a password, not like a
bookmark.

The token is generated and persisted per-library the first time it's
needed (`FeedServerAuthToken.token(libraryHash:)`), stored in
`UserDefaults` under `feedServer.authToken.<hash>`. `FeedServerAuthToken.regenerate(libraryHash:)`
exists at the storage layer and rotates it immediately (no server restart
required — the token is read fresh from storage on every request), but as
of this writing **there is no UI entry point that calls it.** Any future
UI for token rotation should call this function rather than reimplementing
generation.

---

## 3. The `_ambrosia` JSON Feed extension

JSON Feed 1.1 has no book-specific fields, so all AO3/reading metadata
rides in a per-item `_ambrosia` object (the spec's underscore-prefixed
extension convention). Readers that don't recognize `_ambrosia` can ignore
it and still render a normal JSON Feed 1.1 item.

| Field | Type | Nullable | Notes |
|---|---|---|---|
| `word_count` | Int | yes | AO3-extracted count if present, else Calibre's own word-count column. |
| `chapter_current` | Int | yes | |
| `chapter_total` | Int | yes | |
| `is_complete` | Bool | yes | |
| `fandoms` | [String] | yes | |
| `relationships` | [String] | yes | |
| `characters` | [String] | yes | |
| `ratings` | [String] | yes | See "known-incomplete field" below. |
| `warnings` | [String] | yes | See "known-incomplete field" below. |
| `categories` | [String] | yes | |
| `series` | [{`name`, `index`, `ao3_id`}] | yes | `ao3_id` is nullable within each entry. |
| `date_modified` | String (ISO 8601) | yes | AO3's own last-updated date, when known. |

### Known-incomplete field — read this before rendering ratings/warnings

`ratings` and `warnings` are populated from the book's existing **Calibre
tags** (bucketed via `AO3TagBuckets`), not from fresh AO3-preface
extraction. For any book whose only metadata source is Ambrosia's own
on-device extraction (no matching Calibre tags), these fields will
legitimately come back `nil`/empty.

**Render an absent value as "not available," never as "confirmed none."**
Empty `warnings` does not mean the work has no warnings — it means Ambrosia
doesn't currently know. This is a correctness requirement for any client
timeline/detail UI, not a style preference.

### Schema version

The feed document itself (not each item) carries:

```json
"_ambrosia_schema_version": 1
```

Bump this integer only on a **breaking** change to the `_ambrosia` shape
(a field removed or repurposed). Adding a new optional field is not
breaking and does not bump the version. Clients should check this field
and fail loudly (or degrade explicitly) on an unrecognized version rather
than silently misreading fields under an assumed shape.

---

## 4. Pagination

JSON routes only — RSS has no pagination and returns every item in one
response.

- Query params: `page` (default `1`), `per_page` (default `100`, max `500`,
  clamped server-side).
- Response includes `next_url` (a fully-qualified URL for the next page)
  when more items exist; absent/`null` on the last page.

---

## 5. Caching

Every feed response (RSS and JSON) includes an `ETag` header. Send it back
as `If-None-Match` on subsequent polls; a match returns `304 Not Modified`
with no body.

**What the ETag covers:** collection membership (which books are in the
feed) and each book's `ao3.updatedDate` (AO3 re-extraction). **What it does
not cover:** a raw Calibre comment or tag edit made outside AO3 extraction
— there is no cheap "last modified" signal for that today, so such an edit
may not immediately invalidate the ETag. Good enough to skip re-rendering
on a no-op poll; not a substitute for a full content hash if that gap
starts to matter.

---

## 6. OPML

`/feeds.opml` embeds the per-library token in every `xmlUrl` (subject to
the search-feed exception noted in §1) — importing this OPML file is
sufficient to subscribe with auth wired in. Clients should not need to
separately manage the token after an OPML import, except after the token
is regenerated (§2).

Excluded collections (configured in Preferences > Data, and defaulted for
a few system collections — see the app's `ReaderPreferences` defaults) are
not served or listed in OPML; requesting an excluded collection's feed
directly returns `404`.

---

## 7. Current-search snapshot

`/feed/search.xml` / `.json` serves a **frozen snapshot**, not a live
re-query. The user explicitly publishes a search from Ambrosia's UI; that
snapshot (a list of calibre IDs, a label, and a publish timestamp) is what
the feed serves until the next publish. If no snapshot has ever been
published, the route returns an empty feed with an explanatory
title/message rather than a `404`.

---

## 8. Failure modes

- **Missing/invalid token → `401`.** Distinct from "server unreachable."
  A `401` means the token was regenerated or was simply wrong from the
  start; retrying the same request with the same token will never succeed.
  Clients should surface a "re-pair this library" prompt, not a silent
  retry loop.
- **Server unreachable** (Mac asleep, Ambrosia closed, feed server toggled
  off) is a distinct, expected, non-error state for a local-only server —
  clients should show cached content and retry with backoff rather than
  presenting a hard error.
- **Port already in use on the Mac, or the listener fails to bind within
  its startup timeout:** as of this writing, a plain server "Start" does
  not surface this failure distinctly on the Mac's own UI — the failure is
  only logged in debug builds. The one code path that does observe
  start failure (`startAndWaitUntilListening`) reports it as a boolean
  ("didn't finish listening within the timeout") without distinguishing
  "port in use" from "slow to bind" from any other startup error. This is a
  known gap, not something a client can work around; don't build
  client-side retry logic that assumes the Mac always knows when its own
  server failed to start.
- **Mac sleep/wake while the server is running:** not verified against the
  underlying FlyingFox listener's behavior across a sleep/wake cycle as of
  this writing — treat as unknown rather than assumed-fine. Until verified,
  clients should treat a suddenly-unresponsive server the same as "asleep"
  (retry with backoff) rather than assuming a wake always self-heals the
  listener.
