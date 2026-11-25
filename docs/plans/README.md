# Ambrosia Engineering Plans & Architecture Index

This directory holds the engineering implementation plans, technical specifications, and historical architectural blueprints for Ambrosia.

---

## Planning Architecture & Lifecycle

Ambrosia organizes its architectural documentation across three tiers:

```
[docs/roadmap.md] ─────────────── Master architectural phases, invariants, and unbuilt feature register
       │
       ├─► [docs/plans/] ──────── Active implementation plans and proposals undergoing design/coding
       │          │
       │          ▼ (on ship)
       ├─► [docs/plans/finished/] Historical blueprints preserved for design rationale & forensic context
       │
       └─► [docs/*.md] ────────── Living system topic documentation (ground truth for shipped code)
```

1. **Master Roadmap ([docs/roadmap.md](../roadmap.md))**: The single source of truth for all strategic phases (Phases 1–14), dependency graphs, and the unbuilt capability matrix.
2. **Active Plans (`docs/plans/`)**: Focused, actionable implementation specifications for active workstreams. Each active plan names its target roadmap phase, milestones, and testing gates.
3. **Finished Plans (`docs/plans/finished/`)**: Preserved completed, superseded, or otherwise closed plans. They capture historical rationale; current behavior belongs in living topic docs.
4. **Living Topic Docs (`docs/*.md`)**: When a plan ships, its operational contracts, schemas, and invariants are folded directly into the relevant system topic doc. Topic docs reflect current code truth.

---

## Current Plans and Proposals

| Plan File | Roadmap Phase & Scope | Target Subsystem | Related Topic Doc |
| :--- | :--- | :--- | :--- |
| [`vibe-review-remediation-plan.md`](vibe-review-remediation-plan.md) | **Vibe Review Remediation (Shipped ✅)**<br/>CI workflow, package pin alignment, diagnostic delete fix, test hygiene, offset & annotation test coverage, preferences control split | Core App &bull; `Ambrosia/` &bull; `AmbrosiaTests/` &bull; `.github/` | [docs/overview.md](../overview.md) &bull; [docs/testing.md](../testing.md) |
| [`codebase-cleanup-plan.md`](codebase-cleanup-plan.md) | **Codebase Cleanup (Shipped ✅)**<br/>Dead code removal, legacy migration retirement, error log retention, doc hygiene | Core App &bull; `Ambrosia/` &bull; `docs/` | [docs/session-model.md](../session-model.md) &bull; [docs/metadb-and-migrations.md](../metadb-and-migrations.md) |
| [`epub-import-and-safe-trashing-plan.md`](epub-import-and-safe-trashing-plan.md) | **Phase 7 Milestone 5 (Active Priority 🚀)**<br/>EPUB Drag-and-Drop Import, Pre-Triage & Safe Reversible Trashing | `Ambrosia/Database/` &bull; `Ambrosia/LibraryUI/` | [docs/calibre-library.md](../calibre-library.md) |
| [`fulltext-semantic-search-and-external-ingestion-plan.md`](fulltext-semantic-search-and-external-ingestion-plan.md) | **Phase 12 Extension (Partially implemented 📋)**<br/>Paragraph-aware passage embeddings, portable SQLite database, external ingestion CLI | `Ambrosia/Database/Passages/` &bull; `scripts/` | [docs/calibre-fts.md](../calibre-fts.md) |
| [`phase7-ao3-lifecycle-deduplication-epub3-omnibus-plan.md`](phase7-ao3-lifecycle-deduplication-epub3-omnibus-plan.md) | **Phase 7 (Partially implemented)**<br/>Omnibus policy controls; Milestones 1–3 and builder shipped | `Ambrosia/Utilities/` &bull; `Ambrosia/Database/` | [docs/ao3-metadata-extraction.md](../ao3-metadata-extraction.md) |
| [`phase8-reader-experience-series-navigation-plan.md`](phase8-reader-experience-series-navigation-plan.md) | **Phase 8 (Partially implemented)**<br/>Reader Series Nav, Chapter Comments & Preface Styling | `Ambrosia/Reader/` | [docs/reader.md](../reader.md) |
| [`search-suggestions-fuzzy-and-relationship-overhaul-plan.md`](search-suggestions-fuzzy-and-relationship-overhaul-plan.md) | **Search & Suggestions Overhaul (Phase 1 shipped; remaining work proposed)**<br/>Shipped: Calibre-backed suggestion snapshot, typo tolerance, relationship matching. Remaining: engine fixes, typed-vocabulary freshness, AO3 popup routing, role unification | `Ambrosia/Database/` &bull; `Ambrosia/LibraryUI/` | [docs/search-and-filter.md](../search-and-filter.md) &bull; [docs/calibre-library.md](../calibre-library.md) |
| [`filter-ribbon-toolbar-and-tag-order-narrative-plan.md`](filter-ribbon-toolbar-and-tag-order-narrative-plan.md) | **Filter Ribbon & Tag-Order Overhaul (Shipped ✅)**<br/>Ribbon pill remove/include/exclude/copy actions, first-listed tag order in Relevance sort, first-listed row markers | `Ambrosia/LibraryUI/` &bull; `Ambrosia/Database/` | [docs/search-and-filter.md](../search-and-filter.md) &bull; [docs/library-ui.md](../library-ui.md) |
| [`first-listed-position-filters-plan.md`](first-listed-position-filters-plan.md) | **First-Listed Position Filters, Relationship Count, and Tag Variant Matching (Shipped ✅)**<br/>Revives B2 with JSON1 pushdown; `firstRelationship`, `firstCharacter`, `relationshipCount` fields, Invariant 30 cache tokens, Level 1 variant normalizer, drawer & ribbon controls | `Ambrosia/Database/` &bull; `Ambrosia/LibraryUI/` | [docs/search-and-filter.md](../search-and-filter.md) &bull; [docs/caching.md](../caching.md) &bull; [docs/library-ui.md](../library-ui.md) |
| [`tag-order-relevance-fixes-plan.md`](tag-order-relevance-fixes-plan.md) | **Tag-Order Relevance & Position Pushdown (Passes 1–4 Shipped ✅)**<br/>First-listed tag position ranking, SQLite JSON1 pushdown, RRF tie breaking | `Ambrosia/Database/` &bull; `Ambrosia/LibraryUI/` | [docs/search-and-filter.md](../search-and-filter.md) |
| [`fanfiction-archive-export-plan.md`](fanfiction-archive-export-plan.md) | **Fanfiction Archive Export (Active)**<br/>AO3-compatible EPUB export, metadata modernization, Calibre series preservation | `Ambrosia/Utilities/` &bull; `Ambrosia/Database/` | [docs/epub-export.md](../epub-export.md) |
| [`series-identity-flags-and-preload-plan.md`](series-identity-flags-and-preload-plan.md) | **Series Identity Flags & Preload (Active)**<br/>Series collection flags, version decoupling, adjacent-page preloading | `Ambrosia/Database/` &bull; `Ambrosia/LibraryUI/` | [docs/session-model.md](../session-model.md) |
| [`test-gap-closure-plan.md`](test-gap-closure-plan.md) | **Test Gap Closure & Docs Hygiene (Shipped ✅)**<br/>Direct suggestion engine tests, relevance wiring extraction, characterization suites | `Ambrosia/` &bull; `AmbrosiaTests/` &bull; `docs/` | [docs/testing.md](../testing.md) |
| [`theme-centralization-plan.md`](theme-centralization-plan.md) | **Phase 2 / 8 Styling (Active)**<br/>Centralize Corner Radii & Status Colors into `Theme.swift` | `Ambrosia/Theme.swift` (new) | [docs/library-ui.md](../library-ui.md) |
| [`settings-modernization-and-profiles-plan.md`](settings-modernization-and-profiles-plan.md) | **Settings Modernization & Profiles (Proposed)**<br/>Domain-grouped `Codable` preferences, `SettingsStorage` abstraction, schema migration, preset export/import, cascading per-work overrides | `Ambrosia/Reader/` &bull; `Ambrosia/Database/` | [docs/session-model.md](../session-model.md) &bull; [docs/testing.md](../testing.md) |
| [`ui-hig-and-usability-remediation-plan.md`](ui-hig-and-usability-remediation-plan.md) | **UI Usability & Apple HIG Remediation (Shipped ✅)**<br/>Menu bar deduplication, toolbar state feedback, search focus dismissal, floating AO3 filter access, unified sheet ownership & dismissal, floating reader panel clamping, Preferences sizing | `Ambrosia/App/` &bull; `Ambrosia/LibraryUI/` &bull; `Ambrosia/Reader/` &bull; `Ambrosia/Preferences/` | [docs/library-ui.md](../library-ui.md) &bull; [docs/reader.md](../reader.md) |
| [`annotation-engine-and-browser-plan.md`](annotation-engine-and-browser-plan.md) | **Annotation Engine, Non-Destructive Edits & Browser (Proposed 📋)**<br/>W3C hybrid selectors, `CSS.highlights` + `getClientRects()` hit-testing, `annotations_fts`, non-destructive text edits, cross-library browser | `Ambrosia/Reader/` &bull; `Ambrosia/Database/` &bull; `Ambrosia/LibraryUI/` &bull; `Tests/JS/` | [docs/reader.md](../reader.md) &bull; [docs/metadb-and-migrations.md](../metadb-and-migrations.md) |
| [`nectar-ambrosia-highlight-unification-plan.md`](nectar-ambrosia-highlight-unification-plan.md) | **Nectar & Ambrosia Highlight Unification (Proposed 📋)**<br/>Shared `<mark>` + `box-decoration-break: clone` CSS, 9 WCAG AA `HighlightPalette`s, overlap-underline rule, legacy hex migration, reference audit | `Ambrosia/Reader/` &bull; `Ambrosia/Theme/` &bull; `Nectar/Shared/` | [annotation-engine-and-browser-plan.md](annotation-engine-and-browser-plan.md) &bull; [ui-theming-and-palettes-plan.md](ui-theming-and-palettes-plan.md) |
| [`ui-theming-and-palettes-plan.md`](ui-theming-and-palettes-plan.md) | **UI Theming, Palettes & Appearance (Proposed 📋)**<br/>App appearance override, Accent/Surface/Badge/Highlight palettes, WCAG AA dark-mode contrast, live AppKit/SwiftUI/WKWebView pipeline, Settings previews | `Ambrosia/Theme/` &bull; `Ambrosia/Preferences/` &bull; `Ambrosia/LibraryUI/` &bull; `Ambrosia/Reader/` | [docs/library-ui.md](../library-ui.md) &bull; [docs/reader.md](../reader.md) |
| [`reader-search-hardening-and-ergonomics-plan.md`](reader-search-hardening-and-ergonomics-plan.md) | **In-Reader Search Hardening & Ergonomics (Proposed 📋)**<br/>Low-risk fixes (hit contrast, zero-width regex guard, `.withTransparentBounds`, inline-markup snippets, fixed-layout warning, media MIME types) + medium enhancements (`nearby-words`, `SearchIterator`, jump list, Float on Top) | `Ambrosia/Reader/` &bull; `Ambrosia/Database/CalibreFTS/` | [docs/reader.md](../reader.md) &bull; [docs/calibre-fts.md](../calibre-fts.md) |
| [`fts-resilience-and-icloud-safety-plan.md`](fts-resilience-and-icloud-safety-plan.md) | **Index Self-Healing, Temp Cleanup & iCloud Safety (Proposed 📋)**<br/>Orphaned temp extraction cleanup, derived-index `SQLITE_CORRUPT` auto-reset, `NSFileCoordinator` / `.icloud` eviction-aware scanning | `Ambrosia/App/` &bull; `Ambrosia/Database/` | [docs/calibre-fts.md](../calibre-fts.md) &bull; [docs/metadb-and-migrations.md](../metadb-and-migrations.md) |
| [`usb-ereader-sync-and-azw3-plan.md`](usb-ereader-sync-and-azw3-plan.md) | **USB E-Reader Sync & Pure-Swift AZW3 (Proposed 📋)**<br/>Direct Kindle MTP (`IOUSBHost`) & Kobo USB sync, pure-Swift EPUB 3 -> AZW3 conversion, manifest diffing | `Ambrosia/DeviceSync/` &bull; `Ambrosia/Utilities/` | [docs/epub-export.md](../epub-export.md) &bull; [docs/roadmap.md](../roadmap.md) |
| [`macos-system-integration-spotlight-intents-quicklook-plan.md`](macos-system-integration-spotlight-intents-quicklook-plan.md) | **macOS System Integration (Proposed 📋)**<br/>Core Spotlight metadata indexing, Book/Collection App Entities & Intents, Finder Quick Look EPUB extension | `Ambrosia/SystemIntegration/` &bull; `AmbrosiaQuickLook/` | [docs/session-model.md](../session-model.md) &bull; [docs/roadmap.md](../roadmap.md) |
| [`on-device-ai-reading-aids-plan.md`](on-device-ai-reading-aids-plan.md) | **On-Device Apple Intelligence Reading Aids (Proposed 📋)**<br/>macOS 26+ isolated `AIAssistantService`, WIP Chapter Recap, bounded passage Explain/Summarize with explicit save | `Ambrosia/Intelligence/` &bull; `Ambrosia/Reader/` | [docs/reader.md](../reader.md) &bull; [docs/local-dev-references.md](../local-dev-references.md) |
| [`obsidian-markdown-vault-export-plan.md`](obsidian-markdown-vault-export-plan.md) | **Idempotent Obsidian & Markdown Vault Export (Proposed 📋)**<br/>Phase 10 refinement: `NSOpenPanel` vault bookmark, YAML frontmatter, canonical wikilinks, non-destructive marker blocks | `Ambrosia/Utilities/` &bull; `Ambrosia/Annotations/` | [docs/annotations.md](../annotations.md) &bull; [docs/roadmap.md](../roadmap.md) |

---

## Finished Plan Archive (`docs/plans/finished/`)

### Recently closed plans

- [`database-performance-and-query-pipeline-plan.md`](finished/database-performance-and-query-pipeline-plan.md): Database performance, universal paging cache, and AO3 decoupling.
- [`epub-repair-and-archival-normalization-plan.md`](finished/epub-repair-and-archival-normalization-plan.md): EPUB repair, archival normalization, and Calibre zero-corruption architecture.
- [`library-descriptions-series-membership-and-paging-plan.md`](finished/library-descriptions-series-membership-and-paging-plan.md): Description previews, series-scoped Like/Save for Later, stable result snapshots, and paging.

- [`ao3-metadata-extraction-consolidation-plan.md`](finished/ao3-metadata-extraction-consolidation-plan.md): Consolidated `parseWorkID`, shared `absoluteAO3URL`, and unified `findBylineAuthors` scanning across native AO3, external frontmatter engines, and library writers.
- [`ambrosia_formatting_prompt_future.md`](finished/ambrosia_formatting_prompt_future.md): Superseded design brief based on older reader and preference assumptions.
- [`ao3-epub3-export-modernization-plan.md`](finished/ao3-epub3-export-modernization-plan.md): EPUB 3 normalization is implemented and wired into export.
- [`incremental-filter-evaluation-plan.md`](finished/incremental-filter-evaluation-plan.md): Implemented behind the release gate documented in `docs/search-and-filter.md`.
- [`library-gui-stability-plan.md`](finished/library-gui-stability-plan.md): Historical audit; its central correctness fixes are now represented by the current UI and concurrency invariants.
- [`library-list-hosted-nstableview-plan.md`](finished/library-list-hosted-nstableview-plan.md): Superseded; list mode now uses a `ScrollView`/`VStack`, not the `List` assumed by this plan.
- [`phase12-local-semantic-hybrid-and-precision-search-plan.md`](finished/phase12-local-semantic-hybrid-and-precision-search-plan.md): Core semantic, hybrid, and precision search shipped; remaining UI embellishments were not part of the completed core.

### 1. Core Architecture & Project Foundations
- [`project-ambrosia-origin-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/project-ambrosia-origin-plan.md): Initial project architecture plan (Native macOS EPUB reader for Calibre fanfiction).
- [`documentation-architecture-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/documentation-architecture-plan.md): Deconstructing the monolithic architecture doc into topic docs under `docs/`.
- [`quality-remediation-and-xcodegen-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/quality-remediation-and-xcodegen-plan.md): Adopting XcodeGen (`project.yml`), SwiftFormat, and CI test pipeline.
- [`untested-modules-test-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/untested-modules-test-plan.md): Adding unit tests for pure-logic modules (`MatchingSubqueryBuilder`, `LibraryFilterDebug`, `SeriesSpineMap`, `HTMLStripper`).
- [`homebrew-tap-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/homebrew-tap-plan.md): Distribution and packaging via Homebrew Cask.
- [`ambrosia-implementation-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/ambrosia-implementation-plan.md): Historical milestone implementation plan.
- [`ambrosia_cleanup_plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/ambrosia_cleanup_plan.md) & [`ambrosia_cleanup_plan2.md`](~/Documents/Applications/ambrosia/docs/plans/finished/ambrosia_cleanup_plan2.md): Codebase cleanup passes.

### 2. Database, State & Storage Consolidation
- [`phase1-database-consolidation-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/phase1-database-consolidation-plan.md): **Roadmap Phase 1** &mdash; Eliminating SwiftData, moving `BookState` to `AmbrosiaMetaDB`, busy timeouts.
- [`calibre-dependency-reduction-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/calibre-dependency-reduction-plan.md): Dual-database isolation (`metadata.db` read-only vs `ambrosia_meta.db` read/write).
- [`standalone-epub-folder-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/standalone-epub-folder-plan.md): Standalone reading mode without Calibre dependency.
- [`library-storage-diagnostics-and-relocation-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/library-storage-diagnostics-and-relocation-plan.md): Library path diagnostics, missing file repair, and relocation.
- [`phase4-state-concurrency-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/phase4-state-concurrency-plan.md): **Roadmap Phase 4** &mdash; `@Observable` migration and Swift 6 strict concurrency.

### 3. UI Presentation, Layout & Collections
- [`phase2-presentation-unification-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/phase2-presentation-unification-plan.md): **Roadmap Phase 2** &mdash; `LibraryDisplayController` unification across List and Email views.
- [`library-row-performance-fix-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/library-row-performance-fix-plan.md): Clamped description height, static tag layout, and image decode bounds.
- [`collections-management-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/collections-management-plan.md): Dynamic collections, sidebar UI, and selection tracking.
- [`phase6-app-lifecycle-monolith-deconstruction-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/phase6-app-lifecycle-monolith-deconstruction-plan.md): **Roadmap Phase 6** &mdash; Ghost window elimination and AppKit lifecycle refactoring.
- [`ambrosia-bug-remediation-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/ambrosia-bug-remediation-plan.md): Resolution blueprint for 10 UI/lifecycle tickets.

### 4. Search, Filtering & Caching
- [`phase5-search-facet-scalability-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/phase5-search-facet-scalability-plan.md): **Roadmap Phase 5** &mdash; Facet debouncing, JSON ID sets (`SQLIDList`), and multi-token search parsing.
- [`calibre-native-fts-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/calibre-native-fts-plan.md): Native Calibre FTS5 integration (`CalibreFTSLibrary`).
- [`search-and-filter-engine-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/search-and-filter-engine-plan.md): Search query compiler, filter drawer expressions, and pill syntax.
- [`library-load-performance-and-caching-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/library-load-performance-and-caching-plan.md) & [`ambrosia_caching_plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/ambrosia_caching_plan.md): Multi-tier LRU caching (`filterResultCache`, `pageCache`, `countCache`).
- [`filter-system-modernization-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/filter-system-modernization-plan.md) & [`filter-system-modernization-and-sidebar-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/filter-system-modernization-and-sidebar-plan.md): Normalizing tags into `book_tags` and sidebar integration.

### 5. Reader Engine, Formats & Feeds
- [`phase3-epub-reader-performance-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/phase3-epub-reader-performance-plan.md): **Roadmap Phase 3** &mdash; Single-pass SwiftSoup sanitization, parallel chapter extraction, CSS variables.
- [`ambrosia_reader_fix_plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/ambrosia_reader_fix_plan.md): Reader layout, font-size adjustments, and WebKit integration fixes.
- [`ambrosia_series_fix_plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/ambrosia_series_fix_plan.md): Multi-work series spine mapping and cross-work reading continuity.
- [`external-fanfiction-metadata-extraction-plan.md`](~/Documents/Applications/ambrosia/docs/plans/finished/external-fanfiction-metadata-extraction-plan.md): Metadata parsers for FanFicFare, FicLab, and FicHub EPUBs.
- [`ambrosia-feed-transfer-phase0-findings.md`](~/Documents/Applications/ambrosia/docs/plans/finished/ambrosia-feed-transfer-phase0-findings.md): Large-collection transfer protocol via SQLite.
