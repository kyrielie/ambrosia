# SwiftData Store (Deprecated & Consolidated into SQLite)

Scope: Historical record of the legacy `BookState`/`ReadingGoal` SwiftData container and its consolidation into `ambrosia_meta.db`. For the current unified persistence architecture, see `metadb-and-migrations.md`.

---

### Migration & Deprecation Summary

Previously, Ambrosia used a global SwiftData `ModelContainer("Ambrosia")` storing `@Model class BookState` and `@Model class ReadingGoal`.

This architecture suffered from several critical flaws:
1. **Cross-Library Collision**: `BookState` only keyed rows by Calibre integer ID (`calibreID: Int`). Opening multiple Calibre libraries caused ID collisions where reading progress from Library A overwrote Library B.
2. **Dual-Store Fragmentation**: Progress and goals lived in SwiftData while annotations, reading history sessions, and collections lived in SQLite (`ambrosia_meta.db`), causing split-brain transactional updates.
3. **Threading & Concurrency Hazards**: Passing `ModelContext` across SwiftUI view hierarchies and into background tasks caused actor isolation violations and crash-prone faulting.

### Phase 1 Consolidation

In Phase 1 of the Database Consolidation plan:
- `BookState` and `ReadingGoal` were converted from SwiftData `@Model` classes to immutable/thread-safe `Sendable` value structs (`struct BookState: Identifiable, Sendable, Equatable, Hashable`).
- All reading state and reading goal persistence was migrated directly into per-library scoped `ambrosia_meta.db` SQLite databases (`book_state` and `reading_goals` tables).
- A zero-data-loss SQLite-level migration (`migrate_legacy_swiftdata_to_sqlite`) was implemented to read any existing `ZBOOKSTATE` / `ZREADINGGOAL` tables from legacy `default.store` / `Ambrosia.store` and copy records into `book_state`, converting CoreData Apple Reference Date timestamps (`+ 978307200.0`) to standard Unix epoch seconds.
- All `ModelContainer` and `ModelContext` parameters and environment injections were removed from `AmbrosiaApp`, `AppDelegate`, view controllers, and views.
