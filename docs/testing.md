# Testing conventions

Scope: how `AmbrosiaTests/` is organized and what belongs in it. See
`docs/metadb-and-migrations.md` for `AmbrosiaMetaDB`-specific migration test
conventions (already established by `AmbrosiaMetaDBMigrationTests.swift`)
rather than duplicating them here.

## Wiring a new test file into the build

`Ambrosia.xcodeproj` is generated from `project.yml` via `xcodegen generate`
(see `CLAUDE.md`'s "Keeping this current" section). `project.yml`'s
`AmbrosiaTests` target uses a folder-based `sources: - path: AmbrosiaTests`,
so any `.swift` file physically present under `AmbrosiaTests/` is picked up
automatically the next time someone runs `xcodegen generate` — there is no
per-file list to remember to update. Adding a test file therefore means:

1. Add the file under `AmbrosiaTests/`.
2. Run `xcodegen generate` (regenerates `Ambrosia.xcodeproj`, which is
   gitignored — do not hand-edit `project.pbxproj`).
3. Run `./test.sh` and confirm the new file's test class actually appears
   in the output, not just that the suite as a whole passed.

Step 3 matters: this is exactly how 8 of 11 `AmbrosiaTests/` files went
unnoticed for a period — the suite reported green because the 3 files that
were wired in passed, while the other 8 silently never compiled. A green
`./test.sh` run only tells you the wired-in tests passed, not that every
file on disk is wired in.

## What to unit test directly vs. what needs a fixture

Two patterns already exist in this codebase; extend the matching one rather
than inventing a third:

- **Pure logic, no actor/AppKit/WebKit dependency** — drive it directly, no
  fixture needed. `PagingOffsetStateNavigationIntentTests.swift` is the
  template: its own header comment notes `PagingOffsetState` "has no
  SwiftUI/actor dependency, so these tests drive it directly rather than
  standing up `LibraryRootView`." `KeyBinding.swift`'s `validate(_:for:against:)`
  makes the same claim explicitly in its doc comment ("Pure, UI/NSEvent-free
  so it's unit-testable alongside `LibraryVisibilityPolicyTests`") — that
  claim didn't have a test file to back it up until this pass; see
  `KeyBindingValidationTests.swift`.
- **Needs a real `AmbrosiaMetaDB`/`CalibreLibrary`** — use
  `CalibreTestFixture.swift`'s pattern: a real actor instance against a
  disposable temp-directory library path, exercised through the actor
  rather than mocked, since the actor boundary and the SQL are usually
  exactly what's under test. `CollectionStoreTests.swift` and
  `ErrorLogTests.swift` both follow this.

Views (`LibraryRootView`, `ReaderViewController`, etc.) and anything that
needs a live `WKWebView` (`PaginationEngine`, `HighlightBridge`) are out of
scope for unit tests here — no test infrastructure in this repo stands up a
window or a web view, and adding one is a bigger decision than a single test
file. If a bug lives in one of those, look for a pure sub-piece that can be
pulled out and tested the way `SeriesSpineMap` and `PagingOffsetState`
already were.

## Untested pure-logic modules (as of this doc)

Confirmed by grepping `AmbrosiaTests/` for each type name — these have no
test coverage at all:

- `SearchQueryParser.swift` — all `tag:`/`author:`/`title:`/`series:`/
  `status:`/`fulltext:` prefix parsing and `asSingleFilterRule`.
- `AO3MetadataExtractor.swift` / `AO3MetadataExtractor+Authors.swift` — see
  `docs/ao3_epub_html_reference.md` for ready-made fixture HTML shapes.
- `CacheTypes.swift`'s `LRUCache` — note its eviction is insertion-order,
  not access-order: reading a key via the `subscript` getter does not move
  it to the back of `order`, only `set(_:for:)` does. That is worth a test
  precisely because "LRU" is the type's name, and a future reader is likely
  to assume `get` refreshes recency.
- `TagExpansionResolver.swift` and `MatchingSubqueryBuilder` (in
  `FilterBuilder.swift`) — SQL fragment builders; test by asserting exact
  string output.
- `GzipEncoder.swift` — hand-rolled RFC 1952 framing; see
  `GzipEncoderTests.swift` for a round-trip approach via
  `compression_decode_buffer` (the decode counterpart to the
  `compression_encode_buffer` call already in `rawDeflate`).
- `HTMLStripper.swift`, `SeriesSpineMap.swift`, `DebounceTimer.swift`,
  `CustomColumnConfig.swift`, `LibraryIndexManager.swift`,
  `AO3TagSeedDatabaseConfig.swift`, `ExtractionProgress.swift`.

## CI test-completeness gap

CI's `macos-tests` job (`.github/workflows/swift.yml`) runs `xcodebuild test`
and uploads the `.xcresult` bundle on failure, but nothing currently parses
that bundle to confirm every `.swift` file under `AmbrosiaTests/` that
defines an `XCTestCase` subclass actually produced a result. The "sanity
check file count" step added alongside this doc is a weak placeholder (it
only confirms files exist on disk, not that they ran) — a real check needs
someone to inspect `xcrun xcresulttool get --format json --path
<bundle>`'s actual schema on a real Xcode install first, since that schema
isn't something to guess at. Until that lands, step 3 above (read the
`./test.sh` output, don't just check its exit code) is the only guard.

## Local git hooks

A pre-commit hook (SwiftLint only, not the full suite — see the file's own
comment for why) lives at `scripts/git-hooks/pre-commit` but is not wired in
by default. Opt in once per clone:

```
git config core.hooksPath scripts/git-hooks
```
