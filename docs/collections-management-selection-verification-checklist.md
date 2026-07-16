# Library row selection — manual verification checklist

Companion to collections-management-plan.md §6b/§6c. Both items are
verification passes against already-correct-by-construction mechanisms
(`List(items, selection: $selectedItemIDs)`), not implementation tasks — per
the plan, code should only be added here if manual testing finds an actual
gap, rather than guessing at a fix for a mechanism that may already work.

## §6b — Multiselect (Shift / Cmd) and arrow-key navigation

- [ ] Cmd-click and Shift-click across mixed `.book` and `.series` items in
      the same list (grouping on). `selectedItemIDs` is a flat `Set<String>`
      of `LibraryItem.id`, so `List` itself should handle this transparently
      — confirm the *derived* `selectedIDs` (book IDs expanded from a series
      selection, `LibraryRootView.swift` ~line 14938) is complete and
      non-duplicated after a Shift-range-select spanning both book and
      series rows. A book that's both individually selected and a member of
      a selected series should be fine (`Set<Int>` dedupes), but confirm
      with a regression test if a gap turns up.
- [ ] Arrow-key navigation across a page boundary: pressing Down at the last
      row of the current page. `List` has no built-in concept of this app's
      custom pagination (`PagingOffsetState`). Confirm with whoever filed
      the original report which behavior is intended:
      - genuine gap: needs an `.onMoveCommand`/`.onKeyPress` hook to load
        the next page and select its first row, or
      - intentional stop: document it as such instead of changing anything.
      Do not guess and ship a fix for the wrong interpretation.

## §6c — "Stop selecting" (deselect to zero)

- [ ] Confirm whether Escape reaches `List(items, selection: $selectedItemIDs)`
      in `LibraryRootView.swift` (~line 16487–16490) at all. No
      `.onExitCommand` (or equivalent) currently exists on this List (verified
      against the current source — there is no `onExitCommand`,
      `onMoveCommand`, or `onKeyPress` anywhere in `LibraryRootView.swift`).
      Two things could be intercepting or blocking it before it arrives:
      - `.listStyle(.plain)` rows here fill the available width edge-to-edge
        (`listRowInsets`), so there may be no clickable empty area below the
        last row for a click-to-deselect gesture.
      - Escape is already bound elsewhere in the app (`FindBarView.swift`
        ~line 381, `AnnotationSidebarView`/dismiss patterns) — confirm no
        global handler swallows it first.
- [ ] **If verification shows Escape does not reach the List**, add:

  ```swift
  .onExitCommand { selectedItemIDs.removeAll() }
  ```

  directly on the `List` (~line 16487–16490), matching the Finder/Mail
  convention this list's selection binding already leans on elsewhere in
  the file.

Not implemented in this pass: doing so without being able to drive the
running app would mean guessing whether the gap in each bullet actually
exists, which the plan explicitly calls out as worse than leaving it as a
checklist.
