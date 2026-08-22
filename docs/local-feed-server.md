# Local feed server

Scope: `LocalFeedServer`, the off-by-default local-network RSS/OPML server
built on FlyingFox, and the `RSSPublishView` sheet that drives it. This is
the one system in Ambrosia most directly analogous to what Nectar
*consumes* — Ambrosia serves feeds; Nectar/NetNewsWire-style clients read
them.

---

- Local RSS feed server via FlyingFox (`LocalFeedServer`), off by default; when running, always binds `.inet` (all interfaces) so other devices on the local network can connect — there is no loopback-only mode and no authentication. Serves `GET /` (HTML index of available feeds), `GET /feed/collection/<id>.xml` (one item per collection member), `GET /feed/search.xml` (last-published current-search snapshot, persisted as `CurrentSearchSnapshot` in `UserDefaults`), `GET /feed/random-daily.xml` (one seeded-random book per UTC day, opt-in), and `GET /feeds.opml` (OPML 2.0 export of every non-excluded collection feed plus the daily and search feeds). `RSSPublishView` is the SwiftUI publish sheet (searchable collection list, current-search/single-collection target selection, Publish / Copy Feed URL / Export OPML actions) presented as a sheet from `LibraryWindowController`. All routes are GET-only and read-only; there is no write-back path from a feed reader into Ambrosia yet (see `not-yet-built.md`, and Invariant 26 below on the server's current auth posture).

---

## Key invariant

26. `LocalFeedServer` always binds `.inet(port:)` in `restartServerTask()` — there is no loopback-only mode or config flag for it. All routes are unauthenticated; the per-library shared-secret token that used to gate them (`FeedServerAuthToken`, `isAuthorized(_:)`) has been removed, so anyone on the local network who knows or guesses a feed URL can read it. Do not reintroduce a `bindLoopbackOnly`-style toggle without also adding real authentication; a network-scope toggle with no auth behind it is security theater, not a control. `localNetworkURLSync`'s LAN URL is always accurate under this invariant since there is only one bind mode.
