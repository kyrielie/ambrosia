# Annotations

Scope: the unified point-annotation/highlight model, capture, storage, and
UI. For the reader surface these are captured inside, see `reader.md`. For
the storage layer, see `metadb-and-migrations.md`.

---

## Annotations

Unified `Annotation` represents point annotations and ranged highlights:

- `startChar == endChar`: point annotation.
- `startChar != endChar`: ranged annotation/highlight.

Annotations are persisted in `AmbrosiaMetaDB.annotations`, not SwiftData. JS selection capture computes UTF-16 offsets with a TreeWalker. Highlights are restored through `HighlightBridge`; sidebar UI is SwiftUI in an `NSPanel`.

### Optimistic Persistence and Error Recovery

`AnnotationPersistence` (`Reader/AnnotationPersistence.swift`) coordinates asynchronous annotation saves and deletes initiated by the reader:
- Point annotations and text highlights are applied to in-memory state and the DOM immediately for responsive interaction.
- Asynchronous persistence is dispatched to `AmbrosiaMetaDB`.
- If database persistence fails, `AnnotationPersistence` rolls back local state (restoring deleted highlights to the DOM or removing unsaved additions), logs the error to `error_log` via `AmbrosiaMetaDB.logError`, and presents a non-fatal user alert via `NSAlert`.

`BookmarkManager` is a dead stub. All current bookmark behavior is handled by the annotation system. `BookmarkSidebarView` is also dead; it has no instantiation site and is superseded by `AnnotationSidebarView`.

## Export

`AnnotationExportManager` (`Utilities/AnnotationExportManager.swift`) exports every annotation in the current library to CSV: book title, authors, type (Highlight/Bookmark, derived the same way as `isPointAnnotation`), selected text, note, color, spine index, and created date. It reads via `AmbrosiaMetaDB.allAnnotations()` — the unbounded counterpart to `recentAnnotations(limit:)`, which the Activity Feed uses instead because that surface only needs a bounded recent-activity stream — then resolves book titles with one bulk `CalibreLibrary.booksForIDs` call, the same merge pattern `ActivityFeedView.load()` uses. Reachable from the library window's Export toolbar menu ("Export Annotations…") in both list and email view modes. Reuses `ExportManager`'s RFC 4180 CSV escaping (`csvRow`/`csvEscape`/`isoDate`) so both exporters format CSV identically.

---

