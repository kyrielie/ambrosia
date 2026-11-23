# Not Yet Built: Feature Gap Register

Scope: Tracked, intentional gaps and unbuilt capabilities across Ambrosia.
This register is unified with the [Ambrosia Architectural Roadmap](roadmap.md).
See [CLAUDE.md](../CLAUDE.md) for which topic doc to update when one of these ships.

---

## Unbuilt Capabilities Mapped to Roadmap Phases

| Feature / Gap | Target Phase & Blueprint | Primary System Doc | Status |
| :--- | :--- | :--- | :--- |
| **EPUB Drag-and-Drop Ingestion & Safe Trashing** | [Phase 7 Roadmap](roadmap.md#phase-7) &bull; [`epub-import-and-safe-trashing-plan.md`](plans/epub-import-and-safe-trashing-plan.md) | [docs/calibre-library.md](calibre-library.md) | **Active Plan** 📋 |
| **Chapter-Level Comments & Next-in-Series Nav** | [Phase 8 Roadmap](roadmap.md#phase-8) &bull; [`phase8-reader-experience-series-navigation-plan.md`](plans/phase8-reader-experience-series-navigation-plan.md) | [docs/reader.md](reader.md) | **Partially built; remaining work active** 📋 |
| **UI Theme & Status Color Centralization** | [Phase 2/8 Roadmap](roadmap.md#phase-2) &bull; [`theme-centralization-plan.md`](plans/theme-centralization-plan.md) | [docs/library-ui.md](library-ui.md) | **Active Plan** 📋 |
| **Smart Searches & Hierarchical Collections** | [Phase 9 Roadmap](roadmap.md#phase-9) | [docs/metadb-and-migrations.md](metadb-and-migrations.md) | **Planned** 🗓️ |
| **Favourite Authors & Author Subscriptions** | [Phase 9 Roadmap](roadmap.md#phase-9) | [docs/library-ui.md](library-ui.md) | **Planned** 🗓️ |
| **Saved Quotes & Annotations Vault** | [Phase 10 Roadmap](roadmap.md#phase-10) | [docs/annotations.md](annotations.md) | **Planned** 🗓️ |
| **Ranking UI & ELO Matchup Workflow** | [Phase 11 Roadmap](roadmap.md#phase-11) | [docs/metadb-and-migrations.md](metadb-and-migrations.md) | **Planned** 🗓️ |
| **Full-Text Corpus Semantic Search & External Ingestion** | [Phase 12 Roadmap](roadmap.md#phase-12) &bull; [`fulltext-semantic-search-and-external-ingestion-plan.md`](plans/fulltext-semantic-search-and-external-ingestion-plan.md) | [docs/search-and-filter.md](search-and-filter.md) &bull; [docs/calibre-fts.md](calibre-fts.md) | **Active Plan** 📋 |
| **FTS Results Snippet Panel & Reader Jump** | [Phase 12 Roadmap](roadmap.md#phase-12) &bull; (requires pure hit locator) | [docs/calibre-fts.md](calibre-fts.md) | **Planned** 🗓️ |
| **OPDS Catalog Server & Mobile Reading Bridge** | [Phase 13 Roadmap](roadmap.md#phase-13) | [docs/local-feed-server.md](local-feed-server.md) | **Planned** 🗓️ |
| **AO3 Account Bridge (Kudos, Bookmarks, Read Later)**| [Phase 14 Roadmap](roadmap.md#phase-14) | [docs/ao3-metadata-extraction.md](ao3-metadata-extraction.md) | **Planned** 🗓️ |

---

## Technical Performance & Low-Level Gaps

- **Progressive FTS grid updates**: Build only if benchmark in `CalibreFTSBenchmarkTests` shows warm p95 > 400 ms on a real library.
- **Index-completeness warning in UI**: `CalibreFTSLibrary.indexProgress()` exists; needs presentation indicator in library status bar.
- **Stemmed index (`books_fts_stemmed`) support**: Tokenizer supports stemming; query compiler currently targets unstemmed index.
- **Music integration**: Ambient soundscape / reading audio bridge (deferred to companion audio suite).
