# Email Library Selection Semantics — Implementation Summary

Concise reference for the implementing engineer. Read alongside `ambrosia_architecture.md`.

## What we're changing

`EmailSidebarViewController` currently drives the detail pane via `onSelect(CalibreBook?)`. The semantics are wrong: multi-selection leaves a stale book open. We are making selection count the authoritative signal for what the right pane shows.

## Detail pane state model

Model the right pane as an enum, not as sibling views with `isHidden` toggling. `isHidden` fights SwiftUI layout and causes sizing artifacts with `NSHostingController` under Auto Layout (`sizingOptions = []` is load-bearing — see invariant 10).

```swift
enum DetailState {
    case empty               // 0 rows selected
    case book(CalibreBook)   // exactly 1 row selected
    case multipleSelection   // 2+ rows selected
}
```

Drive the `NSHostingController` root view from this enum directly.

## Callback shape

Do **not** change the callback signature to expose raw `[CalibreBook]` upward. Resolve the count logic inside `EmailSidebarViewController` and report a single `CalibreBook?` across the AppKit/SwiftUI seam, exactly as before. Callers must not re-implement the count rule.

The mapping is:

| `selectedRowIndexes.count` | `onSelect` argument | `DetailState` |
|---|---|---|
| 0 | `nil` | `.empty` |
| 1 | the book | `.book(book)` |
| 2+ | `nil` | `.multipleSelection` |

`nil` now means "zero or multiple" — not "nothing clicked yet." That is the only semantic change to the callback.

## Selection preservation across reloads

Reloads come from three distinct sources. Each has different selection behavior:

| Update source | Selection behavior |
|---|---|
| Full fetch (search/filter/sort change) | Preserve single selection by Calibre ID if book is still present; otherwise clear to `.empty`. Never restore a prior multi-selection — always collapse to single or nothing. |
| `BookState` update (progress, liked, ELO) | Pure data refresh. Zero selection side effects. Do not call `reloadData()` — update the diffable snapshot only. |
| `CollectionStore` snapshot refresh | Same as `BookState`. Membership changed; book list did not. No selection touch. |

## Library switch

`LibrarySession.open(url:)` replaces `CalibreLibrary` wholesale. Calibre IDs are only stable within a library session. On library switch:

- Clear `selectedBook` immediately.
- Set detail pane to `.empty`.
- Do not attempt to preserve or remap the prior selection.

Failing to handle this will produce a stale-book display or crash when the user switches libraries.

## AppKit/SwiftUI containment discipline

`LibrarySession` is `@Observable @MainActor`. Any property change on it triggers re-renders in observing SwiftUI views. If `EmailLibraryViewController` rebuilds its `NSHostingController` on those re-renders, selection resets silently. To prevent this:

- `EmailSidebarViewController` owns `NSTableView` selection state entirely.
- Only the diffable data source is updated on reloads — the view controller itself is never rebuilt.
- `DetailState` is a property on `EmailLibraryViewController` that the hosting controller reads; it is updated by the sidebar callback, not by SwiftUI observation.

## Context menu

Right-click behavior is unchanged. Context menus act on the current `selectedRowIndexes` or the clicked fallback row. This is independent of `DetailState`.

## Test cases

| Scenario | Expected result |
|---|---|
| Click one book | Row selected, right pane shows that book |
| Click another book | Previous row deselects, right pane switches |
| Command-click a second book | Both rows selected, right pane shows "Multiple selection" |
| Shift-select a range | Range selected, right pane shows "Multiple selection" |
| Command-click to deselect the only selected row (1 → 0) | Right pane clears to empty state |
| Deselect all | Right pane shows empty state |
| Right-click selected rows | Context menu applies to selected group |
| Search/filter reload, open book still visible | Selection preserved, right pane unchanged |
| Search/filter reload, open book removed | Selection cleared, right pane shows empty state |
| `BookState` or collection update | Selection unchanged |
| Switch library while a book is open | Right pane clears, no crash |

## What not to do

- Do not expose raw `[CalibreBook]` from the sidebar callback.
- Do not use `isHidden` toggling to switch between detail pane states.
- Do not touch selection in `BookState` or collection update paths.
- Do not attempt to restore multi-selections after a reload.
- Do not rely on Calibre IDs being stable across library switches.
