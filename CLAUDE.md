# Ambrosia docs index

Ambrosia is a native macOS EPUB reader for AO3-heavy Calibre libraries.
`ambrosia_architecture.md` at the repo root no longer exists as a single
file — its content has been split into the topic docs below under `docs/`,
each scoped to what an engineer needs for one system. **Read only the
doc(s) relevant to your task**, not this whole index cover-to-cover.

## Read this first if you're fixing something in...

- **Anything — start here if you're new to the codebase** → `docs/overview.md` (product shape and stack; every other doc assumes you've read it)
- **Calibre's `metadata.db` (schema, read-only access, book/author/series/tag queries)** → `docs/calibre-library.md`
- **`ambrosia_meta.db` (collections, annotations, AO3 metadata, tag tables), or any migration** → `docs/metadb-and-migrations.md`
- **`BookState`/`ReadingGoal` (the SwiftData store)** → `docs/swiftdata-store.md`
- **`LibrarySession` (library open/close, registry, `ReaderPreferences`)** → `docs/session-model.md`
- **Search-bar parsing (`SearchQueryParser`), the filter drawer, or the AO3-style filter popup** → `docs/search-and-filter.md`
- **LRU caches (`filterResultCache`/`pageCache`/`countCache`), or list-vs-email reload coordination** → `docs/caching.md`
- **The library window shell, list/email/ranking modes, or collections** → `docs/library-ui.md`
- **Row-selection behavior (multiselect, arrow-key navigation) specifically** → `docs/library-ui.md` (and see `docs/collections-management-selection-verification-checklist.md`, a still-open manual-verification checklist — see "Dangling references" below)
- **AO3 preface metadata extraction, tag canonicalization/synonyms** → `docs/ao3-metadata-extraction.md` (and see `docs/ao3_epub_html_reference.md` for the raw HTML shape this extractor parses)
- **`EPUBParser` (zip/OPF/spine parsing, merged HTML, offset contract)** → `docs/epub-parsing.md`
- **`ReaderViewController`/`ReaderWindowController`, scroll vs. paginated mode, the CSS preference pipeline** → `docs/reader.md`
- **Highlights, point annotations, `HighlightBridge`** → `docs/annotations.md`
- **`LocalFeedServer`, `RSSPublishView`, the served RSS/JSON-feed/OPML routes** → `docs/local-feed-server.md` (and see `docs/ambrosia-feed-transfer-phase0-findings.md` for the in-progress `.sqlite`/large-collection transfer route)
- **`NSHostingView` inside AppKit, or an `async` closure that won't compile where you expect** → `docs/swiftui-appkit-bridging.md`
- **Any Swift 6 actor/`Task`/`async let` compile error, or "why is this cached value stale"** → `docs/concurrency-invariants.md`
- **"Does feature X exist yet?"** → `docs/not-yet-built.md`

If nothing above fits, grep the codebase before assuming it's
undocumented — this split is complete as of the date below, but the
codebase moves faster than docs do. See "Keeping this current" below.

## Conventions every doc here follows

- **Confirmed-vs-inferred language.** These docs describe what the code
  currently does, verified by reading it — not what a comment claims, not
  what a variable name implies, not what's "supposed to" happen. Where a
  doc can't confirm something, it says so rather than asserting it.
- **Describes behavior, not grievances.** Known bugs/gaps are called out
  inline where relevant to understanding the system (see each doc's "Known
  Limitations" section where one exists), but this doc set is not a bug
  tracker or a TODO list.
- **Cross-references by filename**, e.g. `see caching.md`, not "see
  above/below" — these docs are meant to be read individually, not as
  chapters of one long file.
- **Numbered invariants are cited, not restated, outside their home doc.**
  Each invariant lives in exactly one doc (its most specific applicable
  system doc, or `docs/concurrency-invariants.md` for repo-wide
  concurrency/build rules); other docs reference it by number and filename
  instead of copying its text, so a future edit only has one place to land.

## Dangling references (confirmed, not yet resolved)

Grepping the codebase for planning-doc citations in comments turns up at
least eight references to plan files that do not exist anywhere in the
current tree: `ambrosia_caching_plan.md`, `ambrosia_cleanup_plan.md`,
`ambrosia_gap_closure_plan.md`, `ambrosia_series_fix_plan.md` (cited 9
times), `ambrosia-implementation-plan.md`, `ambrosia_reader_fix_plan.md`,
`plan.md`/`plan2`, and `collections-management-plan.md` (cited from
`docs/collections-management-selection-verification-checklist.md`). This is
the same anti-pattern Nectar's own doc set names and tracks explicitly: **a
missing plan doc is a missing citation, not missing evidence** — the code
and tests are the ground truth, and a stray reference doesn't mean the
described work never happened. Treat this as an open question, not a solved
mystery. If you're the one who resolves a specific citation (by recovering
the decision it referred to, or confirming the file is simply gone and
folding the relevant context into the nearest topic doc above), remove it
from this list as part of that change.

## Keeping this current

**Project file:** `Ambrosia.xcodeproj` is generated from `project.yml` via
`xcodegen generate` — see `project.yml`'s header comment for why (it
replaced a hand-edited pbxproj where 8 of 11 `AmbrosiaTests/` files had
silently fallen out of the Sources build phase and stopped running). Add or
remove a `.swift` file under `Ambrosia/` or `AmbrosiaTests/`, then run
`xcodegen generate` — do not hand-edit `project.pbxproj`.

**If you're an AI engineer (or anyone) making a change, update the
relevant doc(s) below as part of the same change — not as a follow-up,
not "someone will get to it."** A stale doc is worse than no doc, because
it's trusted by default. Specifically:

| If your change touches... | Update... |
| --- | --- |
| `CalibreLibrary`'s schema assumptions, read-only connection handling, or bulk-fetch queries | `docs/calibre-library.md` |
| `AmbrosiaMetaDB` schema, `runMigrations`, `CollectionStore`, system collection bootstrapping | `docs/metadb-and-migrations.md` |
| `BookState`, `ReadingGoal`, or the SwiftData `ModelContainer` | `docs/swiftdata-store.md` |
| `LibrarySession`'s open/close lifecycle, `LibraryRegistry`, `ReaderPreferences` | `docs/session-model.md` |
| `SearchQueryParser`, `FilterBuilder`, `FilterExpression`/`FilterRule`, the AO3 filter popup, `TagExpansionResolver` | `docs/search-and-filter.md` |
| `filterResultCache`/`pageCache`/`countCache`/`groupAwareCountCache`, `LibraryFilterDebug`, `suppressNextReloadToken` | `docs/caching.md` |
| `LibraryWindowController`, `LibraryRootView`, `EmailLibraryViewController`, `BookListRow`/`SeriesListRow`/`FlowLayout`, collections UI | `docs/library-ui.md` |
| `AO3MetadataExtractor`, `AO3MetadataRecord`, `canonical_tags`/`tag_synonyms`/`tag_parent_links` | `docs/ao3-metadata-extraction.md` |
| `EPUBParser` and its extensions, the UTF-16 offset contract | `docs/epub-parsing.md` |
| `ReaderViewController`, `ReaderWindowController`, `PaginationEngine`/`PaginationJS`, `ReaderPreferences.css` | `docs/reader.md` |
| `Annotation`, `AnnotationSidebarView`, `AnnotationPopover`, `HighlightBridge`, `AnnotationExportManager` | `docs/annotations.md` |
| `LocalFeedServer`, `RSSPublishView`, `GzipEncoder`, `TransferDatabaseBuilder` | `docs/local-feed-server.md` |
| `NSHostingView` usage, `sizingOptions`, any new async-closure-at-call-site pattern | `docs/swiftui-appkit-bridging.md` |
| Any new actor, `Task.detached`/`async let` usage, or a build-breaking refactor across multiple files | `docs/concurrency-invariants.md` |
| Shipping something previously listed as not-yet-built | `docs/not-yet-built.md` (remove the line) and whichever system doc now owns it |
| `.swiftlint.yml` rules (adding/disabling a rule, changing thresholds), or a new accepted force-unwrap exception | `docs/overview.md`'s "Repo-wide engineering rules" (Invariant 12) |

If a change doesn't fit any row above — new system, new cross-cutting
concern, or something genuinely new — **add a new doc** rather than
folding it into an unrelated one, and add a row to both the routing list
above and this table.

If you're an AI engineer and can't tell which doc(s) your change touches,
err toward updating more rather than fewer — a doc that mentions a system
in passing, even briefly, should still get its cross-reference or a
one-line note refreshed if that mention goes stale, not just the doc
that's "primarily about" that system.

**On the dangling-reference problem specifically:** if you're about to
cite a planning/spec doc in a comment (`// see ambrosia_whatever_plan.md`),
either (a) confirm the file exists in the tree first, or (b) fold the
relevant decision directly into the nearest doc above instead of citing a
scratch file that may not survive to the next snapshot. Eight-plus missing
citations in this codebase already is a sign this practice isn't working
as a durable record.

## Files not covered by any topic doc

As of this split, none — every system named in `ambrosia_architecture.md`
has a home above. This section exists to list any gap that turns up later,
not to leave a claim of completeness unverifiable; if a file or system
stops fitting any row above, name it here rather than leaving it silently
undocumented.

`ambrosia_architecture.md` itself is retired — deleted once this split was
verified to cover its full section list 1:1. It is not one of the "files
not covered" above; it simply no longer exists. If you find a stray
reference to it (comments, other docs, tooling), replace it with the
specific current topic doc from the routing table above, not with a
reference to this section.

`ambrosia_formatting_prompt_future.md` (repo root) is a forward-looking
feature brief for a not-yet-implemented theming/formatting layer, not a
description of current behavior — it intentionally isn't folded into any
topic doc above, since these docs describe confirmed current state, not
proposals. Treat it the way you'd treat any other design doc: read it
before starting that work, update `docs/reader.md` and `docs/library-ui.md`
once (and if) it ships, per the table above.
