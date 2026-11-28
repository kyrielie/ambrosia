# Annotations

Scope: the unified point-annotation/highlight model, capture, storage, and
UI. For the reader surface these are captured inside, see `reader.md`. For
the storage layer, see `metadb-and-migrations.md`.

---

## Annotations

Unified `Annotation` represents point annotations and ranged highlights:

- `startChar == endChar`: point annotation.
- `startChar != endChar`: ranged annotation/highlight.

Annotations are persisted in `AmbrosiaMetaDB.annotations` (indexed by `annotations_fts` via SQLite `AFTER INSERT`/`UPDATE`/`DELETE` triggers), not SwiftData. JS selection capture (`HighlightBridge` + `AnnotationEngineJS`) computes UTF-16 offsets with a `TreeWalker`, capturing `spine_href`, 200-character `quote_prefix`/`quote_suffix` context, and `chapter_title` for both ranged highlights and point annotations. Highlights are restored in a single batched pass through `HighlightBridge`, resolving self-healing W3C quote+context anchors in full-spine coordinate space before paginated slicing and persisting any repaired offsets or `orphaned_at` states; sidebar UI is SwiftUI in an `NSPanel`, complemented by the cross-library `AnnotationsBrowserWindowController` (`⇧⌘A`, using `SentenceContext` via `NLTokenizer`).

### Non-Destructive Text Edits & Pre-Update Safety
- `Annotation` supports optional in-place text substitutions (`original_text`, `replacement_text`, `has_highlight`) rendered in-memory without modifying EPUB files on disk, with `TextReplacementOffsetShift` guarding against overlaps and shifting downstream offsets in descending order.
- Before `CalibreImportManager` overwrites an annotated book (`.updateExisting`/`.replaceExisting`), it flushes an `AnnotationBackupManager` snapshot, backfills missing `quote_prefix`/`quote_suffix` from the old EPUB via `EPUBParser.plainText(for:)`, and flags `needs_reanchor = 1` for automatic repair on next open.
- `AnnotationBackupManager` writes debounced per-book `annotations-snapshot.json` files outside the Calibre library (`~/Library/Application Support/Ambrosia/Backups/<library-id>/Annotations/`) with **File ▸ Export ▸ Restore Annotations from Backup…** recovery.

### Optimistic Persistence and Error Recovery

`AnnotationPersistence` (`Reader/AnnotationPersistence.swift`) coordinates asynchronous annotation saves and deletes initiated by the reader:
- Point annotations and text highlights are applied to in-memory state and the DOM immediately for responsive interaction.
- Asynchronous persistence is dispatched to `AmbrosiaMetaDB`.
- If database persistence fails, `AnnotationPersistence` rolls back local state (restoring deleted highlights to the DOM or removing unsaved additions), logs the error to `error_log` via `AmbrosiaMetaDB.logError`, and presents a non-fatal user alert via `NSAlert`.

`BookmarkManager` is a dead stub. All current bookmark behavior is handled by the annotation system. `BookmarkSidebarView` is also dead; it has no instantiation site and is superseded by `AnnotationSidebarView`.

## Export

`AnnotationExportManager` (`Utilities/AnnotationExportManager.swift`) exports every annotation in the current library to CSV: book title, authors, type (Highlight/Bookmark, derived the same way as `isPointAnnotation`), selected text, note, color, spine index, and created date. It reads via `AmbrosiaMetaDB.allAnnotations()` — the unbounded counterpart to `recentAnnotations(limit:)`, which the Activity Feed uses instead because that surface only needs a bounded recent-activity stream — then resolves book titles with one bulk `CalibreLibrary.booksForIDs` call, the same merge pattern `ActivityFeedView.load()` uses. Reachable from the library window's Export toolbar menu ("Export Annotations…") in both list and email view modes. Reuses `ExportManager`'s RFC 4180 CSV escaping (`csvRow`/`csvEscape`/`isoDate`) so both exporters format CSV identically.

---

