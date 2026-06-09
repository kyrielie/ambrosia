# Ambrosia — Database Migration Plan
## Collections + Annotations + Library Isolation + BookState Cleanup

This supersedes the SwiftData-based approach in Phase 19 of `projectplan3.md`
and the earlier draft migration plan. It incorporates decisions made during
design review covering library isolation, collection kinds, and BookState
field removal.

---

## Summary of changes

| What | Before | After |
|---|---|---|
| `Collection @Model` | SwiftData | Removed entirely |
| `collections` + `collection_members` | Did not exist | New tables in per-library `ambrosia_meta.db` |
| `BookState.annotationsData` | SwiftData JSON blob | `annotations` table in per-library `ambrosia_meta.db` |
| `BookState.isLiked` | SwiftData Bool | Removed — membership in `liked` collection is source of truth |
| `BookState.isHidden` | SwiftData Bool | Removed — membership in `hidden` collection is source of truth |
| `BookState.isRead` | SwiftData Bool | Removed — membership in automated `finished` collection is source of truth |
| `BookState.isPinnedToTop` | SwiftData Bool (never built) | Removed |
| `BookState.bookmarksData` | SwiftData Data (orphaned) | Removed |
| `BookState.highlightsData` | SwiftData Data (orphaned) | Removed |
| `AmbrosiaMetaDB` | Singleton (planned) | Per-library instance, lifecycle tied to `LibrarySession` |
| `ambrosia_meta.db` location | Single file in Application Support | One file per library, stored under a path-derived hash |

---

## Part 1 — Library isolation

### 1.1 The problem

All user-generated data in `ambrosia_meta.db` is keyed by `calibre_id`, an
integer from Calibre's `books.id`. That integer autoincrements from 1 in every
library. `calibre_id = 42` in Library A is a completely different book from
`calibre_id = 42` in Library B. A single shared `ambrosia_meta.db` would
silently mix collections, annotations, and reading state across libraries.

### 1.2 Solution: one database per library

Each library gets its own `ambrosia_meta.db`, stored at a path derived from
the library folder path:

```
~/Library/Application Support/Ambrosia/libraries/<hash>/ambrosia_meta.db
```

Where `<hash>` is a stable, filesystem-safe identifier derived from the
library path. Use the first 16 hex characters of the SHA-256 of the
resolved absolute path string:

```swift
import CryptoKit

func libraryHash(for libraryURL: URL) -> String {
    let resolved = libraryURL.resolvingSymlinksInPath().path
    let data = Data(resolved.utf8)
    let digest = SHA256.hash(data: data)
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    // e.g. "a3f7c2d1e9b04856"
}
```

`CryptoKit` is available on macOS 10.15+. No additional SPM dependency needed.

### 1.3 Library index

Maintain a small JSON index so the app can present known libraries to the
user and recover from path changes:

```
~/Library/Application Support/Ambrosia/libraries/index.json
```

Schema:

```json
[
  {
    "hash": "a3f7c2d1e9b04856",
    "lastKnownPath": "/Users/alice/Documents/Calibre Library",
    "displayName": "Calibre Library",
    "lastOpened": "2025-06-09T12:00:00Z"
  }
]
```

Update `lastKnownPath`, `displayName` (the folder's last path component),
and `lastOpened` every time a library is successfully opened. Write the
index file atomically (write to a `.tmp` file then `FileManager.moveItem`).

### 1.4 `AmbrosiaMetaDB` actor — per-library instance

`AmbrosiaMetaDB` is no longer a singleton. It is created when a library is
opened and closed when the library is switched or the app terminates.
`LibrarySession` owns it.

```swift
actor AmbrosiaMetaDB {
    // No longer `static let shared`
    let libraryHash: String
    private let db: Connection

    init(libraryURL: URL) throws {
        self.libraryHash = Ambrosia.libraryHash(for: libraryURL)
        let dir = try Self.databaseDirectory(for: libraryHash)
        let path = dir.appendingPathComponent("ambrosia_meta.db").path
        self.db = try Connection(path)  // read-write
        try Self.runMigrations(db: db)
    }

    private static func databaseDirectory(for hash: String) throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support
            .appendingPathComponent("Ambrosia")
            .appendingPathComponent("libraries")
            .appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: dir,
            withIntermediateDirectories: true)
        return dir
    }
}
```

`LibrarySession` replaces its `AmbrosiaMetaDB` instance on library switch,
exactly as it already replaces `CalibreLibrary`:

```swift
@Observable
class LibrarySession {
    var calibreLibrary: CalibreLibrary?
    var metaDB: AmbrosiaMetaDB?       // add this

    func openLibrary(at url: URL) async throws {
        calibreLibrary = try CalibreLibrary(root: url)
        metaDB = try await AmbrosiaMetaDB(libraryURL: url)
        LibraryIndexManager.shared.record(url: url)
    }

    func closeLibrary() {
        calibreLibrary = nil
        metaDB = nil  // actor deallocs, SQLite connection closes
    }
}
```

All callsites that previously used `AmbrosiaMetaDB.shared` must be updated
to use `librarySession.metaDB`. Pass `metaDB` as a parameter or access it
through the environment — do not re-introduce a singleton.

### 1.5 Path-change recovery

If the user moves or renames their Calibre library folder, Ambrosia will
compute a different hash and find no database at the new path, opening a
fresh empty one instead. The old database still exists under the old hash.

Recovery UI in **Preferences → Libraries**:

- List all entries from `index.json`.
- Each row shows display name, last known path, and whether the path is
  currently reachable (`FileManager.fileExists`).
- For unreachable entries: a "Re-link" button opens an `NSOpenPanel` to
  select the new library location. On confirmation, update `index.json`
  and move the database directory from the old hash path to the new one.

```swift
func relink(oldHash: String, newLibraryURL: URL) throws {
    let newHash = libraryHash(for: newLibraryURL)
    let base = librariesBaseDirectory()
    let oldDir = base.appendingPathComponent(oldHash)
    let newDir = base.appendingPathComponent(newHash)
    try FileManager.default.moveItem(at: oldDir, to: newDir)
    LibraryIndexManager.shared.update(oldHash: oldHash,
                                      newHash: newHash,
                                      newURL: newLibraryURL)
}
```

---

## Part 2 — Collections

### 2.1 DDL

Run inside `AmbrosiaMetaDB.runMigrations()` using `CREATE TABLE IF NOT EXISTS`.
All tables are created in the per-library database.

```sql
CREATE TABLE IF NOT EXISTS collections (
    id          TEXT    PRIMARY KEY,
    name        TEXT    NOT NULL,
    kind        TEXT    NOT NULL DEFAULT 'manual',
    is_system   INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT    NOT NULL,
    sort_order  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS collection_members (
    collection_id  TEXT    NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    calibre_id     INTEGER NOT NULL,
    added_at       TEXT    NOT NULL,
    PRIMARY KEY (collection_id, calibre_id)
);

CREATE INDEX IF NOT EXISTS idx_collection_members_calibre
    ON collection_members(calibre_id);
```

### 2.2 Collection kinds

`kind` is mutually exclusive per collection. Enforce at the call site.

| `kind` | Behaviour |
|---|---|
| `manual` | Default. User-managed membership. Supports bulk-add. |
| `readLater` | Toolbar shortcut. One canonical instance. Supports bulk-add. |
| `liked` | Feeds the ranking system. User-managed. Supports bulk-add. |
| `hidden` | Books suppressed from all library views. Visible only in Settings → Hidden Content. Skipped books go here. |
| `automated` | Membership managed by app rules, not user. Read-only in UI. No bulk-add. |

### 2.3 System collections

System collections (`is_system = 1`) cannot be renamed or deleted. They are
bootstrapped on first open of each library database, using fixed UUID
literals so they can be referenced by constant without a lookup:

```swift
// SystemCollectionID.swift
enum SystemCollectionID {
    static let readLater = "00000000-0000-0000-0000-000000000001"
    static let liked     = "00000000-0000-0000-0000-000000000002"
    static let skipped   = "00000000-0000-0000-0000-000000000003"
    static let finished  = "00000000-0000-0000-0000-000000000004"
    static let inProgress = "00000000-0000-0000-0000-000000000005"
    static let hasAnnotations = "00000000-0000-0000-0000-000000000006"
}
```

```sql
INSERT OR IGNORE INTO collections (id, name, kind, is_system, created_at, sort_order)
VALUES
    ('00000000-0000-0000-0000-000000000001', 'Read Later',       'readLater', 1, ?, 0),
    ('00000000-0000-0000-0000-000000000002', 'Liked',            'liked',     1, ?, 1),
    ('00000000-0000-0000-0000-000000000003', 'Skipped',          'hidden',    1, ?, 2),
    ('00000000-0000-0000-0000-000000000004', 'Finished',         'automated', 1, ?, 3),
    ('00000000-0000-0000-0000-000000000005', 'In Progress',      'automated', 1, ?, 4),
    ('00000000-0000-0000-0000-000000000006', 'Has Annotations',  'automated', 1, ?, 5);
```

`INSERT OR IGNORE` is idempotent — call this on every database open.
No `UserDefaults` guard needed; the `IF NOT EXISTS` / `OR IGNORE` pair
makes it safe to run repeatedly.

### 2.4 Automated collection sync

The three automated collections are driven by post-write hooks in
`BookStateManager` (for Finished and In Progress) and in the annotation
write/delete paths (for Has Annotations). Each hook calls:

```swift
func syncAutomatedCollection(
    collectionID: String,
    calibreID: Int,
    shouldBeMember: Bool
) async throws {
    if shouldBeMember {
        try db.run(
            "INSERT OR IGNORE INTO collection_members VALUES (?,?,?)",
            [collectionID, calibreID,
             ISO8601DateFormatter().string(from: .now)]
        )
    } else {
        try db.run(
            "DELETE FROM collection_members WHERE collection_id=? AND calibre_id=?",
            [collectionID, calibreID]
        )
    }
}
```

Trigger rules:

| Collection | `shouldBeMember = true` when | `shouldBeMember = false` when |
|---|---|---|
| Finished | `totalReadPercent >= 98` | `totalReadPercent < 98` (manual unread) |
| In Progress | `totalReadPercent > 0 AND < 98` | `totalReadPercent == 0 OR >= 98` |
| Has Annotations | annotation inserted for `calibre_id` | last annotation for `calibre_id` deleted |

Automated collection membership is read-only in the UI. No add button, no
remove button, no bulk-add.

### 2.5 Skipped books

The skip action (context menu or keyboard shortcut) inserts into the Skipped
collection and removes from Read Later if present:

```swift
func skipBook(calibreID: Int) async throws {
    let now = ISO8601DateFormatter().string(from: .now)
    try db.transaction {
        try db.run("INSERT OR IGNORE INTO collection_members VALUES (?,?,?)",
                   [SystemCollectionID.skipped, calibreID, now])
        try db.run(
            "DELETE FROM collection_members WHERE collection_id=? AND calibre_id=?",
            [SystemCollectionID.readLater, calibreID])
    }
}
```

Books in any `hidden` collection are filtered from all library queries.
The filter runs in `FilterBuilder` as a NOT IN subquery against
`collection_members` joined to `collections WHERE kind = 'hidden'`.

### 2.6 Bulk add

Applies to `manual`, `readLater`, and `liked` kinds only. The caller
resolves `calibreIDs` from the tag/author/series query before calling this.

```swift
func bulkAdd(calibreIDs: [Int], to collectionID: String) async throws {
    let now = ISO8601DateFormatter().string(from: .now)
    try db.transaction {
        for id in calibreIDs {
            try db.run(
                "INSERT OR IGNORE INTO collection_members VALUES (?,?,?)",
                [collectionID, id, now]
            )
        }
    }
}
```

`INSERT OR IGNORE` handles deduplication silently. Bulk-add is non-destructive
— it only inserts, never removes existing members.

### 2.7 Removing `Collection @Model` from SwiftData

Remove the `Collection` `@Model` class entirely. The existing crash-and-retry
mechanism in `AmbrosiaApp` (catches `ModelContainer` init error, deletes all
files matching `"Ambrosia"` in Application Support, retries) will fire on
first launch and wipe the SwiftData store. This is acceptable — no user has
production collection data in SwiftData.

If dev/test data needs preserving, run this migration once before removing
the model, guarded by `UserDefaults` key `"collectionsMigratedToSQLite"`:

```swift
func migrateCollectionsFromSwiftData(
    context: ModelContext,
    db: AmbrosiaMetaDB
) async throws {
    let legacy = try context.fetch(FetchDescriptor<Collection>())
    for c in legacy {
        let id = c.id?.uuidString ?? UUID().uuidString
        let calibreIDs = c.calibreIDsData
            .flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
        try await db.run(
            """
            INSERT OR IGNORE INTO collections
            (id, name, kind, is_system, created_at, sort_order)
            VALUES (?,?,?,?,?,?)
            """,
            [id, c.name, c.systemType ?? "manual",
             c.isSystem ? 1 : 0,
             ISO8601DateFormatter().string(from: c.createdAt ?? .now), 0]
        )
        for calibreID in calibreIDs {
            try await db.run(
                "INSERT OR IGNORE INTO collection_members VALUES (?,?,?)",
                [id, calibreID, ISO8601DateFormatter().string(from: .now)]
            )
        }
    }
}
```

---

## Part 3 — Annotations

### 3.1 DDL

```sql
CREATE TABLE IF NOT EXISTS annotations (
    id            TEXT    PRIMARY KEY,
    calibre_id    INTEGER NOT NULL,
    spine_index   INTEGER NOT NULL,
    start_char    INTEGER NOT NULL,
    end_char      INTEGER NOT NULL,
    selected_text TEXT    NOT NULL DEFAULT '',
    note          TEXT,
    color_hex     TEXT,
    created_at    TEXT    NOT NULL
);

-- start_char == end_char means bookmark (point annotation)
-- start_char != end_char means highlight (ranged annotation)

CREATE INDEX IF NOT EXISTS idx_annotations_calibre
    ON annotations(calibre_id);

CREATE INDEX IF NOT EXISTS idx_annotations_position
    ON annotations(calibre_id, spine_index, start_char);
```

Character offsets are UTF-16 code units, text nodes only, no HTML tags.
This is invariant 5 from `ambrosia_architecture.md` and applies to every
read and write of `start_char`/`end_char` without exception.

### 3.2 Migration from `BookState.annotationsData`

Retain `annotationsData: Data?` as a tombstone field for one SwiftData
schema version. After the migration runs it is never written again.
Do not remove it until the cleanup release (Part 5).

Migration — run in `applicationDidFinishLaunching` before the library
window appears, guarded by `UserDefaults` key
`"annotationsMigratedToSQLite"`. The migration targets the currently
open library's `metaDB` only — it must run again on first open of each
additional library if those libraries have `BookState` records.

```swift
func migrateAnnotationsFromSwiftData(
    context: ModelContext,
    db: AmbrosiaMetaDB
) async throws {
    struct LegacyAnnotation: Codable {
        var id: String
        var spineIndex: Int
        var startChar: Int
        var endChar: Int
        var selectedText: String
        var note: String?
        var colorHex: String?
        var createdDate: Date
    }

    let iso = ISO8601DateFormatter()
    let allStates = try context.fetch(FetchDescriptor<BookState>())

    for state in allStates {
        guard let data = state.annotationsData,
              let annotations = try? JSONDecoder()
                  .decode([LegacyAnnotation].self, from: data)
        else { continue }

        for a in annotations {
            try await db.run(
                """
                INSERT OR IGNORE INTO annotations
                (id, calibre_id, spine_index, start_char, end_char,
                 selected_text, note, color_hex, created_at)
                VALUES (?,?,?,?,?,?,?,?,?)
                """,
                [a.id, state.calibreID, a.spineIndex, a.startChar,
                 a.endChar, a.selectedText, a.note, a.colorHex,
                 iso.string(from: a.createdDate)]
            )
        }
    }
}
```

`INSERT OR IGNORE` is idempotent. Safe to re-run if the app is force-quit
mid-migration.

### 3.3 Read/write paths after migration

All annotation access goes through `AmbrosiaMetaDB`. `BookState.annotationsData`
is never written after migration day.

```swift
// Read — called by HighlightBridge on spine load
func annotations(for calibreID: Int, spineIndex: Int) async throws -> [Annotation] {
    let rows = try db.prepare(
        """
        SELECT id, spine_index, start_char, end_char,
               selected_text, note, color_hex, created_at
        FROM annotations
        WHERE calibre_id = ? AND spine_index = ?
        ORDER BY start_char
        """,
        [calibreID, spineIndex]
    )
    return rows.map { row in
        Annotation(
            id: row[0] as! String,
            spineIndex: Int(row[1] as! Int64),
            startChar: Int(row[2] as! Int64),
            endChar: Int(row[3] as! Int64),
            selectedText: row[4] as! String,
            note: row[5] as? String,
            colorHex: row[6] as? String,
            createdDate: iso.date(from: row[7] as! String) ?? .now
        )
    }
}

// Write — called on mouseup JS message via HighlightBridge
func insertAnnotation(_ a: Annotation, calibreID: Int) async throws {
    try db.run(
        """
        INSERT INTO annotations
        (id, calibre_id, spine_index, start_char, end_char,
         selected_text, note, color_hex, created_at)
        VALUES (?,?,?,?,?,?,?,?,?)
        """,
        [a.id.uuidString, calibreID, a.spineIndex, a.startChar,
         a.endChar, a.selectedText, a.note, a.colorHex,
         ISO8601DateFormatter().string(from: a.createdDate)]
    )
    // Sync automated Has Annotations collection
    try await syncAutomatedCollection(
        collectionID: SystemCollectionID.hasAnnotations,
        calibreID: calibreID,
        shouldBeMember: true
    )
}

// Delete
func deleteAnnotation(id: String, calibreID: Int) async throws {
    try db.run("DELETE FROM annotations WHERE id = ?", [id])
    // If no annotations remain for this book, remove from Has Annotations
    let count = try db.scalar(
        "SELECT COUNT(*) FROM annotations WHERE calibre_id = ?",
        [calibreID]
    ) as! Int64
    try await syncAutomatedCollection(
        collectionID: SystemCollectionID.hasAnnotations,
        calibreID: calibreID,
        shouldBeMember: count > 0
    )
}
```

### 3.4 Relationship to `saved_quotes`

`annotations` and `saved_quotes` (Phase 19) share the same coordinate
system (invariant 5) and `calibre_id` key. They are separate tables by
design. `annotations` are made while reading and rendered live in the
WKWebView. `saved_quotes` are curated excerpts managed from a separate
panel. A row can exist in both tables for the same position — intentional.

---

## Part 4 — BookState field removal

### 4.1 Fields being removed

The following fields are removed from `BookState` as part of this migration.
All require a SwiftData `SchemaMigrationPlan` (lightweight migration —
all removals, no type changes).

| Field | Reason |
|---|---|
| `isLiked: Bool` | Replaced by membership in the `liked` collection |
| `isHidden: Bool` | Replaced by membership in a `hidden` collection |
| `isRead: Bool` | Replaced by membership in the `finished` automated collection |
| `isPinnedToTop: Bool` | Feature was never built. Remove. |
| `annotationsData: Data?` | Migrated to `annotations` table in Part 3 |
| `bookmarksData: Data?` | Already orphaned. Never read or written. Remove. |
| `highlightsData: Data?` | Already orphaned. Never read or written. Remove. |
| `readingModeRaw: String` | Already legacy/inert. Remove. |

### 4.2 BookState after cleanup

```swift
@Model
class BookState {
    var calibreID: Int

    // Reading position
    var lastSpineIndex: Int
    var lastCharacterOffset: Int
    var lastScrollOffset: Double

    // Progress
    var totalReadPercent: Double       // 0.0–100.0; triggers automated collection at >= 98
    var totalReadingTimeSeconds: Int

    // ELO ranking (Phase 16)
    var eloScore: Double               // default 1000.0
    var eloMatchCount: Int             // default 0
}
```

This is the complete final shape. Nothing else belongs in SwiftData.

### 4.3 Migration plan

The removal of multiple fields in one `SchemaMigrationPlan` is a single
lightweight migration step. SwiftData lightweight migration handles field
removal with default values automatically.

```swift
// AmbrosiaSchemaV1 — current schema (with all legacy fields)
// AmbrosiaSchemaV2 — fields listed in 4.1 removed

enum AmbrosiaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [
        AmbrosiaSchemaV1.self,
        AmbrosiaSchemaV2.self,
    ]
    static var stages: [MigrationStage] = [
        .lightweight(fromVersion: AmbrosiaSchemaV1.self,
                     toVersion: AmbrosiaSchemaV2.self)
    ]
}
```

**Before removing any field:** run the annotations migration (Part 3) and
confirm the `UserDefaults` guard is set, so no annotation data is lost when
`annotationsData` disappears from `BookState`.

**The existing crash-and-retry mechanism must be removed or disabled** before
this migration ships. That mechanism deletes the entire SwiftData store on
schema error — it was a development convenience, not a production strategy.
With real user data in `BookState` (reading positions, ELO scores), silently
wiping the store on a migration failure is data loss. Replace it with a
proper error handler that surfaces the failure to the user.

### 4.4 Callsite updates

Every location that reads or writes the removed fields must be updated.
Audit with a project-wide search before submitting:

- `isLiked` → read/write `collection_members` for `SystemCollectionID.liked`
- `isHidden` → read/write `collection_members` for any `hidden` collection
- `isRead` → read `collection_members` for `SystemCollectionID.finished`; writes are now automated only
- `isPinnedToTop` → delete all references
- `annotationsData` → `AmbrosiaMetaDB.annotations(for:spineIndex:)`
- `bookmarksData`, `highlightsData`, `readingModeRaw` → delete all references

The `FilterBuilder` in-memory post-filter for `isLiked` and `isHidden` must
be rewritten to query `collection_members` in SQLite instead. This is an
improvement — it removes the two-stage SQL+in-memory split for these fields.

---

## Part 5 — Implementation sequence

Do not interleave parts within a single PR. Each part should be a
self-contained branch that compiles and passes tests before the next begins.

### PR 1 — Library isolation infrastructure
1. Add `libraryHash(for:)` function.
2. Create `LibraryIndexManager` (read/write `index.json`).
3. Refactor `AmbrosiaMetaDB` from singleton to per-library instance.
4. Update `LibrarySession.openLibrary` and `closeLibrary` to manage `metaDB` lifecycle.
5. Update all `AmbrosiaMetaDB.shared` callsites to use `librarySession.metaDB`.
6. Add Preferences → Libraries UI stub (list of known libraries with last-opened dates).
7. Compile and test: open two different libraries in sequence; confirm separate database files are created under `libraries/<hash>/`.

### PR 2 — Collections DDL and system bootstrap
1. Add `CREATE TABLE IF NOT EXISTS` for `collections` and `collection_members` in `AmbrosiaMetaDB.runMigrations()`.
2. Add `SystemCollectionID` constants.
3. Add system collection bootstrap (`INSERT OR IGNORE`) to `AmbrosiaMetaDB.init`.
4. Write `CollectionStore` — thin wrapper over `AmbrosiaMetaDB` exposing typed collection operations.
5. Remove `Collection @Model`. Run dev data migration if needed.
6. Implement `skipBook`, `bulkAdd`.
7. Implement automated collection sync hooks in `BookStateManager` for Finished and In Progress.
8. Update `FilterBuilder` to filter hidden books via SQL subquery against `collection_members`.
9. Compile and test: skip a book, verify it disappears from library view; open two libraries, verify collections are independent.

### PR 3 — Annotations migration
1. Add `annotations` DDL to `AmbrosiaMetaDB.runMigrations()`.
2. Write and test `migrateAnnotationsFromSwiftData`, guarded by `UserDefaults` flag.
3. Update `HighlightBridge` read path to use `AmbrosiaMetaDB.annotations(for:spineIndex:)`.
4. Update annotation write/delete to use `AmbrosiaMetaDB.insertAnnotation` and `deleteAnnotation`.
5. Wire Has Annotations automated collection sync into insert/delete paths.
6. Tombstone `annotationsData` — make setter a no-op, getter always return `nil`.
7. Verify Phase 15 (annotation panel) and Phase 20 (annotation export) compile and work correctly.
8. Compile and test: annotate a book, switch libraries, confirm annotation is absent, switch back, confirm annotation is present.

### PR 4 — BookState cleanup
1. Remove crash-and-retry mechanism from `AmbrosiaApp`. Replace with user-facing error alert.
2. Write `AmbrosiaSchemaV2` with all fields from section 4.1 removed.
3. Write `AmbrosiaMigrationPlan` lightweight migration.
4. Run full callsite audit (search for all removed field names).
5. Update `FilterBuilder` `isLiked`/`isHidden` in-memory filters to SQL collection membership queries.
6. Compile and test: launch with a V1 store, confirm migration completes without data loss to reading positions and ELO scores.

### PR 5 — Library re-link UI (follow-on)
1. Complete Preferences → Libraries panel with re-link flow.
2. Implement `relink(oldHash:newLibraryURL:)` with directory move.
3. Show stale/unreachable library entries with visual indicator.

---

## Key invariants

All invariants from `ambrosia_architecture.md` remain in force.
The following are most relevant to this migration:

- **Invariant 1** — bare Swift collections cannot be stored on `@Model`.
  After this migration, collections and annotations no longer live in
  SwiftData, so this constraint no longer applies to them. It still applies
  to any remaining `@Model` fields.
- **Invariant 5** — character offsets are UTF-16 code units, text nodes
  only, no HTML tags. `annotations.start_char` and `end_char` must satisfy
  this invariant. The migration function preserves existing offsets verbatim.
- **Invariant 7** — all SQLite.swift `db.prepare` calls use `[Binding?]`
  (optional array). Every new query in `AmbrosiaMetaDB` must follow this.
  Non-optional `[Binding]` resolves to the wrong overload and produces a
  compile error.
- **New invariant** — `AmbrosiaMetaDB` is never a singleton. It is always
  accessed through `LibrarySession`. Any code that stores a direct reference
  to an `AmbrosiaMetaDB` instance across a library switch will hold a
  reference to the closed database of the previous library.
