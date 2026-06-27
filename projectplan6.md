Perfect. I have everything I need. Let me read a few more files before writing the prompts to make sure I have accurate file/method names for the engineer.Now I have everything. Writing the prompts.

---

## Prompt 1 — Random sort: wire up `sortedRandomly` in both list and email views

**Files:** `CalibreLibrary.swift`, `BookGridItem.swift`, `EmailLibraryViewController.swift`, `LibraryWindowController.swift`, `AppDelegate.swift` (or wherever the View menu is wired)

**Context:**

`CalibreLibrary` already has `reshuffleRandom()`, `randomSeed`, and `sortedRandomly(_ ids: [Int]) -> [Int]` (Xorshift64 + Fisher-Yates). `orderByClause(.random)` returns `b.title ASC` as a placeholder. The method `wordCountSortedPage` shows the exact pattern to follow: fetch all matching IDs via `fetchAllMatchingIDs`, sort/slice in Swift, hydrate only the page via `booksForIDs`. `sortedRandomly` is currently defined but never called.

**Tasks:**

1. **`CalibreLibrary.swift` — add `randomSortedPage`:**

   Model it on `wordCountSortedPage` directly. The method signature should be:
   ```swift
   func randomSortedPage(offset: Int, limit: Int,
                         query: SearchQuery, filter: FilterExpression?,
                         restrictIDs: [Int]?) -> (page: [CalibreBook], hasMore: Bool)
   ```
   Steps: call `fetchAllMatchingIDs(query:filter:restrictIDs:)` to get all IDs, call `sortedRandomly(_:)` on the result, slice `[offset..<offset+limit]`, hydrate via `booksForIDs`, return `(page, end < sortedIDs.count)`.

2. **`BookGridItem.swift` — handle `.random` in `loadPage()`:**

   The `.wordCount` branch at the top of `loadPage()` is the template. Before the `else if let result = toolbarState.activeFilterResult, result.isSQLBacked` chain, add an analogous `.random` branch. Resolve the same three filter states (SQL-backed / explicit IDs / unfiltered) to `restrictIDs` and `filterForSQL`, then call `library.randomSortedPage(...)`. The ascending/descending state is irrelevant for random order — ignore `toolbarState.ascending` in this branch.

3. **`EmailLibraryViewController.swift` — same change in `loadPage(reset:)`:**

   The email view has its own `loadPage` with the same filter-state branching pattern starting at line 786. Apply the identical `.random` branch there, routing through `library.randomSortedPage`.

4. **`LibraryWindowController.swift` — add "Reshuffle" to the View menu and disable sort direction for random:**

   - In `makeSortItem`, when the sort menu opens (`NSMenuDelegate.menuWillOpen`) update each sort field menu item's `.state` to `.on` if it matches `toolbarState?.sortField`. This also fixes the missing checkmarks for all sorts.
   - Set the Ascending and Descending items' `.isEnabled = toolbarState?.sortField != .random`.
   - Add `NSMenuItemValidation` conformance (or `validateMenuItem`) to `LibraryWindowController` to grey out "Reshuffle" when `toolbarState?.sortField != .random`.
   - Add a "Reshuffle" `NSMenuItem` to the **View menu** in the app's main menu (in the storyboard or programmatically in `AppDelegate`/`LibraryWindowController`). Its action should be `#selector(reshuffleSort)`. Implement `reshuffleSort` in `LibraryWindowController`:
     ```swift
     @objc private func reshuffleSort() {
         session?.library?.reshuffleRandom()
         // trigger a reload via toolbarState so both views react:
         toolbarState?.sortField = .random  // no-op if already random,
         // but we still need loadPage — bump via a no-op token or call
         // the view controller directly. Simplest: store a @Published
         // reshuffleToken in LibraryToolbarState and toggle it here.
     }
     ```
     The cleanest reload trigger: add `var reshuffleToken: Bool = false` to `LibraryToolbarState` (it's `@Observable`). In `reshuffleSort`, toggle it. In `BookGridItem.attachDataHandlers` add `.onChange(of: toolbarState.reshuffleToken) { loadPage() }`. In `EmailLibraryViewController.scheduleObservation` add `_ = ts.reshuffleToken` to the tracked properties and handle it in `toolbarStateDidChange` (it won't need a guard since it only acts when sort is already `.random`).

5. **`SortField` — remove `.lastOpened`:**

   Delete the `case lastOpened` from `SortField`. Remove its `label` entry. Remove its `orderByClause` case. Search for any remaining references and remove them. This sort was unimplemented (its `orderByClause` returned `b.title`).

---

## Prompt 2 — Star button scroll jump: add diagnostic logging

**Files:** `BookGridItem.swift`

**Context:**

Tapping the star calls `toggleLike(for book: CalibreBook)` which: writes to `collectionStore`, calls `session.bumpMembershipVersion()`, re-fetches `likedIDs`, then on `MainActor` sets `likedIDs` and conditionally calls `applyFilterRules()` only when `filterUsesLiked`. No `loadPage()` is called in the non-liked-filter path. However, `bumpMembershipVersion()` increments `session.membershipVersion` which is `@Observable` — anything observing it could trigger a reload or re-layout. It's not yet confirmed whether anything in `BookGridItem` or its parent observes `membershipVersion` directly or indirectly.

**Task:**

Add `print` diagnostics at every entry point that could cause a scroll-position change when a star is tapped outside a liked filter. Specifically:

1. At the top of `loadPage()`, add:
   ```swift
   print("[StarDiag] loadPage called — sort=\(toolbarState.sortField) page=\(currentPage)", Thread.callStackSymbols.prefix(6).joined(separator: "\n"))
   ```

2. At the top of `rebuildItems()`, add a similar print.

3. At the top of `refreshBookStates()`, add a similar print.

4. Inside `toggleLike(for book:)`, add prints before and after `session.bumpMembershipVersion()`:
   ```swift
   print("[StarDiag] toggleLike — before bumpMembershipVersion")
   session.bumpMembershipVersion()
   print("[StarDiag] toggleLike — after bumpMembershipVersion, filterUsesLiked will be checked")
   ```

5. In `attachDataHandlers`, inside each `onChange` handler that calls `loadPage()` or `rebuildItems()`, add a one-line print identifying which handler fired.

Tap the star on a book when no liked filter is active. If `loadPage` or `rebuildItems` prints fire, the call stack printed alongside will identify the trigger. Report the output — the fix will be targeted based on what fires.

---

## Prompt 3 — Read Later indicator in row view and email view

**Files:** `BookGridItem.swift`, `LibrarySession.swift`, `EmailLibraryViewController.swift`, `EmailSidebarViewController.swift`

**Context:**

In `BookGridItem`, `likedIDs: Set<Int>` is an `@State` property populated from `collectionStore?.likedIDs()` in `refreshBookStates()` and seeded from `session.cachedLikedIDs` on appear. `LibrarySession` has `cachedLikedIDs`, `cachedSkippedIDs`, `cachedSeriesOrMergedIDs`, `cachedAO3PublisherIDs` as `var` properties — a new `cachedReadLaterIDs` should follow the same pattern. `SystemCollectionID.readLater = "00000000-0000-0000-0000-000000000001"`. The star button in row view is a `Button` with `Image(systemName: isLiked ? "star.fill" : "star")` inside `titleRow`. `addToReadLater` already exists as a private method in `BookGridItem`.

In `EmailSidebarViewController`, `EmailBookCellView` has `likeButton: NSButton` constrained with `likeButton.trailingAnchor = trailingAnchor - 10` and `titleLabel.trailingAnchor = likeButton.leadingAnchor - 6`. The `configure(item:readPercent:ao3Metadata:isLiked:collectionPills:showCollectionPills:onToggleLiked:)` call site in `makeRow` needs a new `isInReadLater: Bool` and `onToggleReadLater` parameter.

**Tasks:**

**`LibrarySession.swift`:**
- Add `var cachedReadLaterIDs: Set<Int> = []` alongside the other cached sets. Zero it in `open()` and `close()`.

**`BookGridItem.swift`:**

1. Add `@State private var readLaterIDs: Set<Int> = []`.

2. In `refreshBookStates()`, add a concurrent fetch alongside `fetchedLiked`:
   ```swift
   async let fetchedReadLater = session.collectionStore?.members(of: SystemCollectionID.readLater)
   ```
   Assign `readLaterIDs = Set((try? await fetchedReadLater) ?? [])` and write back to `session.cachedReadLaterIDs`.

3. In `.onAppear`, seed `readLaterIDs = session.cachedReadLaterIDs` alongside the other cached sets.

4. In `toggleLike(for book:)`, after updating `likedIDs`, also update `readLaterIDs` (re-fetch members or do a local insert/remove — a local toggle is fine since `addToReadLater` is a one-way add, but a full re-fetch on toggle is safer for accuracy).

   Actually: `readLaterIDs` is changed by `addToReadLater` not by `toggleLike`. Add a new `toggleReadLater(for book: CalibreBook)` private function that calls `collectionStore?.toggleMembership(calibreID:collectionID:)` (check if this method exists; if not, use the add/remove pattern), then re-fetches and updates both `readLaterIDs` and `session.cachedReadLaterIDs`. The existing `addToReadLater` context-menu action can remain as-is.

5. In `titleRow` inside `BookRowView`, add a bookmark button immediately to the left of the star button:
   ```swift
   Button(action: onReadLaterToggle) {
       Image(systemName: isInReadLater ? "bookmark.fill" : "bookmark")
           .foregroundStyle(isInReadLater ? Color.accentColor : Color.secondary)
   }
   .buttonStyle(.borderless)
   .help(isInReadLater ? "Remove from Read Later" : "Add to Read Later")
   ```
   Add `isInReadLater: Bool` and `onReadLaterToggle: () -> Void` to `BookRowView`'s property list alongside `isLiked` and `onLikeToggle`. Wire them at the call site in `bookRow(_:)`:
   ```swift
   isInReadLater: readLaterIDs.contains(book.id),
   onReadLaterToggle: { toggleReadLater(for: book) },
   ```

**`EmailBookCellView` in `EmailSidebarViewController.swift`:**

1. Add `private let readLaterButton = NSButton()` alongside `likeButton`.

2. In `setupSubviews()`, configure `readLaterButton` the same way as `likeButton` (borderless, imageOnly, 18×18). Add it as a subview.

3. Update constraints: the chain becomes `titleLabel.trailing → readLaterButton.leading (-6) → likeButton.leading (-4) → trailing (-10)`. Keep `likeButton` at the far right; `readLaterButton` sits immediately to its left.

4. Add `private var onToggleReadLater: ((CalibreBook) -> Void)?`. Add `@objc private func toggleReadLater()` that calls `onToggleReadLater?(representedBook ?? ...)`.

5. Extend `configure(...)` with `isInReadLater: Bool` and `onToggleReadLater: @escaping (CalibreBook) -> Void`. Set the button image and tint, same pattern as `likeButton`.

6. In `EmailSidebarViewController.makeRow` (where `configure` is called), pass `isInReadLater: readLaterIDs.contains(...)`. Add `var readLaterIDs: Set<Int> = [] { didSet { reloadVisibleRows() } }` alongside `likedIDs`.

7. In `EmailLibraryViewController`, fetch Read Later members in `refreshCollectionSnapshots()` (or wherever `likedIDs` is fetched), assign to `sidebarVC?.readLaterIDs`. Add a `onToggleReadLater` callback on `sidebarVC` that calls the same `toggleReadLater` logic (write + re-fetch + update).

---

## Prompt 4 — Series row context menu: add missing actions

**Files:** `BookGridItem.swift`

**Context:**

`SeriesRowView` currently receives only `onLikeToggle: () -> Void` and `onOpen: () -> Void` as action callbacks, and its `.contextMenu` has only "Open Series" and "Show Individual Works". `BookRowView` has the full set: `onReadLater`, `onSkip`, `onMarkRead`, `onResetProgress`, `onCollectionChanged`, plus `showCollectionPicker` state. The call site for `SeriesRowView` in `seriesRow(_ series: SeriesGroup)` passes closures that call `toggleLike(for: series)` and `openReaderWindow`. All the private action functions (`addToReadLater`, `skip`, `markRead`, `resetProgress`) already accept `[CalibreBook]` — `series.works` can be passed directly.

**Tasks:**

1. **Add callbacks to `SeriesRowView`:**
   ```swift
   let onReadLater:      () -> Void
   let onSkip:           () -> Void
   let onMarkRead:       () -> Void
   let onResetProgress:  () -> Void
   let onCollectionChanged: () -> Void
   ```
   Add `@State private var showCollectionPicker = false` to `SeriesRowView`.

2. **Extend the `.contextMenu` in `SeriesRowView.body`:**
   ```swift
   .contextMenu {
       Button("Open Series", action: onOpen)
       Button("Show Individual Works") { showIndex = true }
       Divider()
       Button(isLiked ? "Unlike Series" : "Like Series", action: onLikeToggle)
       Button("Add Series to Read Later", action: onReadLater)
       Button("Mark Series as Read", action: onMarkRead)
       Button("Reset Series Reading Progress", action: onResetProgress)
       Button("Skip Series", action: onSkip)
       Divider()
       Button("Add to Collection...") { showCollectionPicker = true }
   }
   .popover(isPresented: $showCollectionPicker, arrowEdge: .trailing) {
       CollectionSearchPickerView(
           calibreIDs: series.works.map(\.id),
           onChange: { onCollectionChanged() },
           onComplete: { showCollectionPicker = false }
       )
   }
   ```

3. **Wire the new callbacks at the call site** in `seriesRow(_ series: SeriesGroup)` in the parent `BookGridItem`:
   ```swift
   onReadLater:     { addToReadLater(series.works) },
   onSkip:          { skip(series.works) },
   onMarkRead:      { markRead(series.works) },
   onResetProgress: { resetProgress(series.works) },
   onCollectionChanged: { refreshBookStates() },
   ```

---

## Prompt 5 — RSS feed: "Publish to RSS" popup with collection/search selection

**Files:** `LocalFeedServer.swift`, `LibraryWindowController.swift`, `LibrarySession.swift`

**Context:**

`LocalFeedServer` already has `handleCollectionFeed` (serves `/feed/collection/<id>.xml`) and `handleSearchFeed` (serves `/feed/search.xml`). The search feed reads from `CurrentSearchSnapshot.load()` — `CurrentSearchSnapshot.publish(calibreIDs:label:)` is defined but never called anywhere. `LibraryWindowController` has `triggerRSSFeed` which only starts/stops the server. The export menu (`makeExportMenu`) currently has: Export CSV, Export EPUBs, separator, Start/Stop RSS Feed Server. `toolbarState` is accessible in `LibraryWindowController` and has `filterExpression`, `searchText`, and `activeFilterResult`. `LibraryFilterDebug.summary(expression:)` produces a compact label string from a `FilterExpression`. `session?.feedServer` is the running `LocalFeedServer` actor.

**Tasks:**

1. **Rename and repurpose the existing RSS menu item:**

   Change `makeExportMenu`'s RSS item title to `"RSS Feed Server…"` always (drop the Start/Stop toggle from the title). Its action becomes `#selector(showRSSPanel)`.

2. **Implement `showRSSPanel` in `LibraryWindowController`:**

   This method presents an `NSAlert`-based panel (or a small `NSWindow` sheet) that does the following:

   a. If the feed server is not running, start it first (call `session?.startFeedServer()`), then after the 0.35 s delay (same as `triggerRSSFeed` currently uses) proceed.

   b. Fetch collection list synchronously via a `Task { await session?.feedServer?.collectionList() }` — add a helper to `LocalFeedServer` that returns `[(id: String, name: String)]` pulled from `collectionStore?.collections()`.

   c. Build an `NSPopUpButton` with entries:
      - "Current search results" (top, always present)
      - A separator
      - One entry per collection, labelled by `collection.name`

   d. Show an `NSAlert` with:
      - Message: `"Publish to RSS Feed"`
      - Informative text: `"Choose what to publish. The feed URL updates immediately and stays until you publish again."`
      - Accessory view: the `NSPopUpButton` (set `alert.accessoryView`)
      - Buttons: "Publish", "Copy Feed URL", "Cancel"

   e. On "Publish":
      - If "Current search results" is selected: build the label from `toolbarState`. Use `toolbarState?.searchText` if non-empty, otherwise use `LibraryFilterDebug.summary(expression: toolbarState.filterExpression)` if the expression has complete rules, otherwise `"All books"`. Collect the current book IDs — use `toolbarState?.activeFilterResult?.calibreIDs` if an explicit result exists; for SQL-backed results, call `session?.library?.fetchAllMatchingIDs(query:filter:restrictIDs:)` synchronously (it's fast). Call `CurrentSearchSnapshot.publish(calibreIDs: ids, label: label)`.
      - If a collection is selected: no snapshot write needed — the collection feed is already live at its URL.
      - Show a follow-up `NSAlert` or replace the informative text with the feed URL so the user can copy it.

   f. On "Copy Feed URL":
      - Same logic to determine URL: for current search, `http://<host>:<port>/feed/search.xml`; for a collection, `http://<host>:<port>/feed/collection/<id>.xml`.
      - Copy to `NSPasteboard.general`.

3. **Add `collectionList()` to `LocalFeedServer`:**
   ```swift
   func collectionList() async -> [(id: String, name: String)] {
       let rows = (try? await collectionStore?.collections()) ?? []
       return rows.map { ($0.id, $0.name) }
   }
   ```

4. **Update `makeExportMenu`/`refreshExportMenu`:** Remove the start/stop title toggle since the new flow always opens the panel. The menu item is always `"RSS Feed Server…"` regardless of running state. Keep `refreshExportMenu()` called on server start/stop to update other items if needed.