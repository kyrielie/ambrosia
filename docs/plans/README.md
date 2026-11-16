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
       ├─► [docs/plans/completed/] Historical blueprints preserved for design rationale & forensic context
       │
       └─► [docs/*.md] ────────── Living system topic documentation (ground truth for shipped code)
```

1. **Master Roadmap ([docs/roadmap.md](~/Documents/Applications/ambrosia/docs/roadmap.md))**: The single source of truth for all strategic phases (Phases 1–14), dependency graphs, and the unbuilt capability matrix.
2. **Active Plans (`docs/plans/`)**: Focused, actionable implementation specifications for active workstreams. Each active plan names its target roadmap phase, milestones, and testing gates.
3. **Completed Blueprints (`docs/plans/completed/`)**: Preserved historical blueprints from completed phases and major refactors. They capture "why" a system was designed, benchmarks, and alternative designs considered.
4. **Living Topic Docs (`docs/*.md`)**: When a plan ships, its operational contracts, schemas, and invariants are folded directly into the relevant system topic doc. Topic docs reflect current code truth.

---

## Master Index of Active Engineering Plans

| Plan File | Roadmap Phase & Scope | Target Subsystem | Related Topic Doc |
| :--- | :--- | :--- | :--- |
| [`phase7-ao3-lifecycle-deduplication-epub3-omnibus-plan.md`](~/Documents/Applications/ambrosia/docs/plans/phase7-ao3-lifecycle-deduplication-epub3-omnibus-plan.md) | **Phase 7 (Active)**<br/>AO3 Work Lifecycle, Deduplication & Series Omnibus Engine | `Ambrosia/Utilities/` &bull; `Ambrosia/Database/` | [docs/ao3-metadata-extraction.md](~/Documents/Applications/ambrosia/docs/ao3-metadata-extraction.md) |
| [`ao3-epub3-export-modernization-plan.md`](~/Documents/Applications/ambrosia/docs/plans/ao3-epub3-export-modernization-plan.md) | **Phase 7 (Active)**<br/>Modernized EPUB 3 Packaging (`epub-otwarchive`) | `Ambrosia/Exporters/` | [docs/epub-parsing.md](~/Documents/Applications/ambrosia/docs/epub-parsing.md) |
| [`epub-import-and-safe-trashing-plan.md`](~/Documents/Applications/ambrosia/docs/plans/epub-import-and-safe-trashing-plan.md) | **Phase 7 / 15 (Active)**<br/>EPUB Drag-and-Drop Import, Pre-Triage & Safe Reversible Trashing | `Ambrosia/Database/` &bull; `Ambrosia/LibraryUI/` | [docs/calibre-library.md](~/Documents/Applications/ambrosia/docs/calibre-library.md) |
| [`phase8-reader-experience-series-navigation-plan.md`](~/Documents/Applications/ambrosia/docs/plans/phase8-reader-experience-series-navigation-plan.md) | **Phase 8 (Active)**<br/>Reader Series Nav, Chapter Comments & Preface Styling | `Ambrosia/Reader/` | [docs/reader.md](~/Documents/Applications/ambrosia/docs/reader.md) |
| [`phase12-local-semantic-hybrid-and-precision-search-plan.md`](~/Documents/Applications/ambrosia/docs/plans/phase12-local-semantic-hybrid-and-precision-search-plan.md) | **Phase 12 (Active)**<br/>CoreML/ANE Embeddings, SIMD Cosine Search & Calibre Query Parity | `Ambrosia/Database/` &bull; `Ambrosia/LibraryUI/` | [docs/search-and-filter.md](~/Documents/Applications/ambrosia/docs/search-and-filter.md) |
| [`fulltext-semantic-search-and-external-ingestion-plan.md`](~/Documents/Applications/ambrosia/docs/plans/fulltext-semantic-search-and-external-ingestion-plan.md) | **Phase 12 Extension (Proposed)**<br/>Full-Text Corpus Semantic Search & External Headless Ingestion | `Ambrosia/Database/` &bull; `Ambrosia/LibraryUI/FTS/` &bull; `scripts/` | [docs/search-and-filter.md](~/Documents/Applications/ambrosia/docs/search-and-filter.md) &bull; [docs/calibre-fts.md](~/Documents/Applications/ambrosia/docs/calibre-fts.md) |
| [`fanfiction-archive-export-plan.md`](~/Documents/Applications/ambrosia/docs/plans/fanfiction-archive-export-plan.md) | **Phase 7 / 9 (Active)**<br/>Library Sharing, Bundled Collections & Archive Export | `Ambrosia/Exporters/` &bull; `Ambrosia/Collections/` | [docs/metadb-and-migrations.md](~/Documents/Applications/ambrosia/docs/metadb-and-migrations.md) |
| [`incremental-filter-evaluation-plan.md`](~/Documents/Applications/ambrosia/docs/plans/incremental-filter-evaluation-plan.md) | **Phase 5 Addendum (Built/Gated)**<br/>Incremental Narrowing of Filter Expressions | `Ambrosia/LibraryUI/FilterDrawer/` | [docs/search-and-filter.md](~/Documents/Applications/ambrosia/docs/search-and-filter.md) |
| [`library-gui-stability-plan.md`](~/Documents/Applications/ambrosia/docs/plans/library-gui-stability-plan.md) | **Phase 2 Correctness (Active)**<br/>Zero-Match Export, Search Loop & Overlapping Page Loads | `Ambrosia/LibraryUI/` &bull; `LibraryDisplayController` | [docs/library-ui.md](~/Documents/Applications/ambrosia/docs/library-ui.md) |
| [`theme-centralization-plan.md`](~/Documents/Applications/ambrosia/docs/plans/theme-centralization-plan.md) | **Phase 2 / 8 Styling (Active)**<br/>Centralize Corner Radii & Status Colors into `Theme.swift` | `Ambrosia/Theme.swift` (new) | [docs/library-ui.md](~/Documents/Applications/ambrosia/docs/library-ui.md) |
| [`library-list-hosted-nstableview-plan.md`](~/Documents/Applications/ambrosia/docs/plans/library-list-hosted-nstableview-plan.md) | **Phase 2 Standby (Plan B)**<br/>Hosted NSTableView Replacement for List Mode | `Ambrosia/LibraryUI/` | [docs/library-ui.md](~/Documents/Applications/ambrosia/docs/library-ui.md) |

---

## Master Index of Completed Blueprints (`docs/plans/completed/`)

### 1. Core Architecture & Project Foundations
- [`project-ambrosia-origin-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/project-ambrosia-origin-plan.md): Initial project architecture plan (Native macOS EPUB reader for Calibre fanfiction).
- [`documentation-architecture-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/documentation-architecture-plan.md): Deconstructing the monolithic architecture doc into topic docs under `docs/`.
- [`quality-remediation-and-xcodegen-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/quality-remediation-and-xcodegen-plan.md): Adopting XcodeGen (`project.yml`), SwiftFormat, and CI test pipeline.
- [`untested-modules-test-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/untested-modules-test-plan.md): Adding unit tests for pure-logic modules (`MatchingSubqueryBuilder`, `LibraryFilterDebug`, `SeriesSpineMap`, `HTMLStripper`).
- [`homebrew-tap-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/homebrew-tap-plan.md): Distribution and packaging via Homebrew Cask.
- [`ambrosia-implementation-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/ambrosia-implementation-plan.md): Historical milestone implementation plan.
- [`ambrosia_cleanup_plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/ambrosia_cleanup_plan.md) & [`ambrosia_cleanup_plan2.md`](~/Documents/Applications/ambrosia/docs/plans/completed/ambrosia_cleanup_plan2.md): Codebase cleanup passes.

### 2. Database, State & Storage Consolidation
- [`phase1-database-consolidation-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/phase1-database-consolidation-plan.md): **Roadmap Phase 1** &mdash; Eliminating SwiftData, moving `BookState` to `AmbrosiaMetaDB`, busy timeouts.
- [`calibre-dependency-reduction-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/calibre-dependency-reduction-plan.md): Dual-database isolation (`metadata.db` read-only vs `ambrosia_meta.db` read/write).
- [`standalone-epub-folder-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/standalone-epub-folder-plan.md): Standalone reading mode without Calibre dependency.
- [`library-storage-diagnostics-and-relocation-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/library-storage-diagnostics-and-relocation-plan.md): Library path diagnostics, missing file repair, and relocation.
- [`phase4-state-concurrency-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/phase4-state-concurrency-plan.md): **Roadmap Phase 4** &mdash; `@Observable` migration and Swift 6 strict concurrency.

### 3. UI Presentation, Layout & Collections
- [`phase2-presentation-unification-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/phase2-presentation-unification-plan.md): **Roadmap Phase 2** &mdash; `LibraryDisplayController` unification across List and Email views.
- [`library-row-performance-fix-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/library-row-performance-fix-plan.md): Clamped description height, static tag layout, and image decode bounds.
- [`collections-management-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/collections-management-plan.md): Dynamic collections, sidebar UI, and selection tracking.
- [`phase6-app-lifecycle-monolith-deconstruction-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/phase6-app-lifecycle-monolith-deconstruction-plan.md): **Roadmap Phase 6** &mdash; Ghost window elimination and AppKit lifecycle refactoring.
- [`ambrosia-bug-remediation-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/ambrosia-bug-remediation-plan.md): Resolution blueprint for 10 UI/lifecycle tickets.

### 4. Search, Filtering & Caching
- [`phase5-search-facet-scalability-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/phase5-search-facet-scalability-plan.md): **Roadmap Phase 5** &mdash; Facet debouncing, JSON ID sets (`SQLIDList`), and multi-token search parsing.
- [`calibre-native-fts-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/calibre-native-fts-plan.md): Native Calibre FTS5 integration (`CalibreFTSLibrary`).
- [`search-and-filter-engine-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/search-and-filter-engine-plan.md): Search query compiler, filter drawer expressions, and pill syntax.
- [`library-load-performance-and-caching-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/library-load-performance-and-caching-plan.md) & [`ambrosia_caching_plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/ambrosia_caching_plan.md): Multi-tier LRU caching (`filterResultCache`, `pageCache`, `countCache`).
- [`filter-system-modernization-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/filter-system-modernization-plan.md) & [`filter-system-modernization-and-sidebar-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/filter-system-modernization-and-sidebar-plan.md): Normalizing tags into `book_tags` and sidebar integration.

### 5. Reader Engine, Formats & Feeds
- [`phase3-epub-reader-performance-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/phase3-epub-reader-performance-plan.md): **Roadmap Phase 3** &mdash; Single-pass SwiftSoup sanitization, parallel chapter extraction, CSS variables.
- [`ambrosia_reader_fix_plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/ambrosia_reader_fix_plan.md): Reader layout, font-size adjustments, and WebKit integration fixes.
- [`ambrosia_series_fix_plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/ambrosia_series_fix_plan.md): Multi-work series spine mapping and cross-work reading continuity.
- [`external-fanfiction-metadata-extraction-plan.md`](~/Documents/Applications/ambrosia/docs/plans/completed/external-fanfiction-metadata-extraction-plan.md): Metadata parsers for FanFicFare, FicLab, and FicHub EPUBs.
- [`ambrosia-feed-transfer-phase0-findings.md`](~/Documents/Applications/ambrosia/docs/plans/completed/ambrosia-feed-transfer-phase0-findings.md): Large-collection transfer protocol via SQLite.
