# Overview and stack

Scope: the one-paragraph product shape and the concrete framework/package
list an engineer needs before touching anything else. Every other doc in
this index assumes you've read this one. For user-facing feature
description and build/install instructions, see `README.md` at the repo
root instead — this doc is the engineer-facing complement, not a
replacement.

---

## Product Shape

Ambrosia is a native macOS EPUB reader for AO3-heavy Calibre libraries.

- Target: macOS 14.0+.
- Calibre is the source of truth for book metadata and EPUB files.
- Calibre `metadata.db` is opened read-only and never modified.
- App-owned state is stored outside the Calibre library.
- Publisher CSS/scripts are stripped; reader styling is app/user controlled.
- Reader is custom `WKWebView` plus injected JavaScript. No Readium.
- No sandboxing, cloud sync, OPDS, or packaged release flow.


---

## Stack

- App lifecycle/windowing: SwiftUI `App` plus AppKit `NSApplicationDelegate`, `NSWindowController`, and `NSViewController`.
- UI: AppKit shell with SwiftUI content hosted through `NSHostingView`/`NSHostingController`.
- Calibre DB: SQLite.swift 0.15.3, read-only.
- App SwiftData store: `BookState` and `ReadingGoal`.
- Per-library app DB: `AmbrosiaMetaDB` actor, writable SQLite (WAL mode), under `~/Library/Application Support/Ambrosia/libraries/<hash>/ambrosia_meta.db`.
- EPUB parsing: ZIPFoundation 0.9.19 and `NSXMLParser`.
- AO3 HTML parsing: SwiftSoup 2.13.5.
- Rendering: `WKWebView`.
- Packages: SQLite.swift, ZIPFoundation, SwiftSoup, FlyingFox 0.26.2.

---

## Repo-wide engineering rules

12. Force-unwraps are prohibited in any code path reachable from database read results. Use `guard let` with a logged fallback, or propagate the error. Enforced by `.swiftlint.yml`'s `force_unwrapping` rule (not disabled) and CI's `swiftlint lint --strict` step. Fixed known instance: `LibrarySession.extractOneBook`'s `indexedRecord!` (see `swiftdata-store.md`/`LibrarySession.swift`) now uses `guard let` with a diagnostic-logged failure outcome. This does not apply to implicitly-unwrapped `NSView`/`NSViewController` properties set up in `loadView`/`viewDidLoad` (e.g. `ReaderViewController.webView: ReaderMenuWebView!`, `EmailSidebarViewController.tableView: NSTableView!`) — that is standard AppKit view-lifecycle practice, not a DB-read-reachable force-unwrap, and is an accepted, intentional exception to this rule.

13. All diagnostic `print` calls must be wrapped in `#if DEBUG` or removed before shipping. `Thread.callStackSymbols` must never be called outside `#if DEBUG` blocks.

14. Do not hand-edit `Package.resolved`; add packages through the Xcode/SPM workflow.

---

