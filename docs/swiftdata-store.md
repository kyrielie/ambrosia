# SwiftData store

Scope: the `BookState`/`ReadingGoal` SwiftData model container. For the
larger app-owned database (collections, annotations, AO3 metadata), see
`metadb-and-migrations.md`.

---

### SwiftData

`AmbrosiaApp` creates a persistent `ModelContainer("Ambrosia")` with exactly two model types:

- `BookState`: keyed by `calibreID`, stores reading progress, reading position (UTF-16 offset), total reading time, and ELO fields.
- `ReadingGoal`: reading-goal state.

SwiftData does not store collections, annotations, or any AO3 metadata. The `Bookmark` and `Highlight` structs in `BookState.swift` are safe to delete; they were never stored as `@Model` properties and no migration depends on them.

On SwiftData store init failure, the app shows an alert and falls back to in-memory recovery. It does not delete existing support files.


---

## Key invariant

4. The SwiftData schema contains only `BookState` and `ReadingGoal`. Do not add `@Model` types without a versioned migration plan. Do not store bare Swift collections on `@Model`; use scalar columns, delimited strings, or JSON data.
