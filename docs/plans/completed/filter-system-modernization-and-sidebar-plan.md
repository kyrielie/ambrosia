# Filter System Modernization & Integrated Sidebar Plan

## Executive Summary

Ambrosia features two filtering front-ends backed by a single query engine:
1. **AO3-Style Filter**: Modeled after Archive of Our Own (`_filters.html.erb`).
2. **Filter Library Panel**: A general-purpose boolean query builder with nested AND/OR groups.

This plan addresses two core architectural directives:
- **In-Window AO3 Filter Sidebar (Default)**: Transition the AO3-style filter from a detached popout window into an integrated, collapsible in-window sidebar in `LibraryRootView`, matching how AO3's web sidebar sits beside work listings. An optional "Detach" button allows users to pop it into a floating window when desired.
- **Surface Modernization Alignment**:
  - **AO3 Filter Surface**: Keep the layout 100% faithful to AO3's web interface (Include/Exclude accordions, checkboxes, rating radio group), but bring in authentic AO3 web features: inline tag autocomplete search boxes inside tag accordions, authentic "From / To" word count inputs under More Options, and lossless passthrough of drawer rules.
  - **Filter Library Panel**: Modernize the macOS power-user boolean query builder: draft-and-commit sheet lifecycle, unified numeric range inputs (Word Count & Kudos with `between`), rich contextual tag search with work counts, and card-based visual hierarchy.

---

## 1. Architectural Architecture & Invariants

### 1.1 Invariants
- **Invariant 12**: Zero force unwraps (`!`). All bindings and optional states must use safe unwrapping, default values, or guarded returns.
- **Invariant 17**: Explicit tag expansion threading.
- **Invariant 24**: Correlated `NOT EXISTS` subqueries for negative matching (never `NOT IN`).
- **Invariant 25**: In-memory post-filtering order (`matchingIDsForGroup`).
- **Build Gate (Invariant 21)**: `swiftlint lint --strict` must report 0 violations; `./test.sh` must pass 100%.

### 1.2 Surface Separation of Concerns
```
┌────────────────────────────────────────────────────────────────────────┐
│                          LibraryWindowController                       │
│                                                                        │
│  Toolbar: [Sidebar Toggle ⊞]   [Search Bar 🔍]   [Filter Library ⑆]   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
           ┌────────────────────────┴────────────────────────┐
           ▼                                                 ▼
┌───────────────────────────────┐               ┌────────────────────────┐
│ LibraryRootView (List Mode)   │               │ FilterDrawerView       │
│                               │               │ (Sheet / Drawer)       │
│ ┌──────────────┬────────────┐ │               │                        │
│ │ AO3 Sidebar  │ Book List  │ │               │ • Boolean Groups       │
│ │ (Collapsible)│ (Paginated)│ │               │ • AND / OR Conjunction │
│ │              │            │ │               │ • Range & Field Ops    │
│ │ • Include/   │            │ │               │ • Draft Lifecycle      │
│ │   Exclude    │            │ │               └────────────────────────┘
│ │ • Tag Search │            │ │
│ │ • Word Count │            │ │
│ └──────────────┴────────────┘ │
└───────────────────────────────┘
```

---

## 2. Phase 1: In-Window AO3 Filter Sidebar

### 2.1 Problem
Currently, clicking the sidebar toggle in List mode invokes `AO3FilterPopupWindowController.open(...)`, launching an auxiliary `NSWindowController`. This disconnects the filter from the library content, requires window management on macOS, and diverges from the web experience where the filter panel lives directly in the page.

### 2.2 Design
1. **Integrated Sidebar in `LibraryRootView`**:
   - Wrap the main library layout in an `HStack(spacing: 0)`:
     - Left (or Right): `AO3FilterSidebarView` (width: 320–360pt, resizable or fixed, collapsible).
     - Divider: Vertical `Divider()`.
     - Center: The existing book list / item list content.
   - Smooth slide-in/out transition using `withAnimation(.easeInOut(duration: 0.2))`.
2. **State & Toolbar Integration**:
   - Add `var showAO3FilterSidebar: Bool` to `LibraryToolbarState`.
   - Persist preference in `ReaderPreferences` or `UserDefaults` (`libraryShowAO3Sidebar`).
   - In `LibraryWindowController.triggerSidebarToggle()`:
     - When `toolbarState.viewMode == .list`: toggle `toolbarState.showAO3FilterSidebar`.
     - When `toolbarState.viewMode == .email`: toggle `toolbarState.toggleEmailSidebar`.
3. **Detach / Attach Window Affordance**:
   - Provide a small detach icon button (`Image(systemName: "arrow.up.right.square")`) in the header of the sidebar.
   - Clicking Detach: hides the inline sidebar and invokes `AO3FilterPopupWindowController.open(...)`.
   - The popout window gets an "Attach to Window" button to return it to the sidebar.
4. **Facet Controller Lifecycle in Sidebar**:
   - The sidebar observes `toolbarState.filterExpression` and `session.membershipVersion`.
   - Reuses `AO3FilterFacetController.make` with debounced facet calculation (`DebounceTimer(delay: 0.15)`).

---

## 3. Phase 2: Faithful AO3 Web Enhancements (AO3 Sidebar)

### 3.1 Authenticity Guidelines
Do not alter the core AO3 web structure:
- Keep "Sort and Filter" button + Sort By at the top.
- Keep separate "Include" and "Exclude" sections.
- Keep Radio buttons for Include Rating, Checkboxes for Exclude Rating.
- Keep Accordions for Warnings, Categories, Fandoms, Characters, Relationships, Freeforms, and Authors.

### 3.2 Add Authentic AO3 "Word Count: From / To"
- AO3's web interface features numeric inputs under More Options:
  ```
  Word Count:
  From: [         ]  To: [         ]
  ```
- Add `wordsFrom: Int?` and `wordsTo: Int?` to `AO3FilterPopupState`.
- Render numeric `TextField`s labeled "From:" and "To:" inside the "More Options" accordion.
- In `buildExpression()`, map `wordsFrom` to `FilterRule(field: .wordCountGT, op: .equals, value: "\(wordsFrom)")` and `wordsTo` to `FilterRule(field: .wordCountLT, op: .equals, value: "\(wordsTo)")`.

### 3.3 Add Authentic AO3 Inline Tag Search Boxes
- On the AO3 website, each expandable tag section has a search box (e.g. *"Search other tags to include"*).
- Add a lightweight `TextField` at the top of each accordion (Fandom, Character, Relationship, Freeform, Author):
  - Typing in the box invokes `AmbrosiaMetaDB.searchTags(query:field:fandomContext:limit:)`.
  - Shows an inline suggestion popover or dropdown with matching tags and work counts.
  - Clicking a tag adds it to the user's selected tags for that direction (Include or Exclude).

### 3.4 Lossless Passthrough of Drawer Rules
- When initializing the AO3 state or running `buildExpression()`, collect rules that do not correspond to AO3 fields (e.g. custom `title`, `comment`, `collection` rules configured in the drawer) into `passthroughRules: [FilterRule]`.
- When the user clicks "Sort and Filter", these rules are appended back into the applied expression so the drawer's custom rules are not erased.

---

## 4. Phase 3: Modernize Filter Library Boolean Groups (`FilterDrawerView`)

### 4.1 Draft State Lifecycle (Fixing Sheet Mutation Leak)
- **Problem**: `FilterDrawerView` binds directly to `toolbarState.filterExpression`. If a user edits rules and presses Escape or closes the sheet, the expression in `toolbarState` is left mutated in a half-configured state.
- **Solution**:
  - `FilterDrawerView` initializes with `@State private var draftExpression: FilterExpression`.
  - On appear, `draftExpression = expression`.
  - The UI edits only `draftExpression`.
  - "Apply" (and `Cmd+Return`) copies `draftExpression` back to `expression`, triggers `onApply()`, and dismisses.
  - Cancel (`xmark.circle.fill` and `Escape`) simply dismisses without committing.

### 4.2 Unified Numeric Range Rules (Word Count & Kudos)
- **Problem**: Filtering 10k–50k words currently requires creating two independent rules (`wordCountGT` and `wordCountLT`) inside an AND group.
- **Solution**:
  - Unify `wordCountGT` and `wordCountLT` into a primary `wordCount` field (retaining serialization compatibility with existing saved rules).
  - Add operators:
    - `greater than` (`>`)
    - `less than` (`<`)
    - `is between` (renders two text boxes: `[Min] and [Max]`)
  - Support human-friendly input formats (`50k`, `1.5m`, `10,000`).

### 4.3 Modernize Autocomplete & Popover Anchor
- **Problem**: `FilterValueTextField` currently spawns an unmanaged `NSPanel` at `level = .popUpMenu` with custom mouse tracking monitors and requires an embedded zero-size `WindowAccessorView` hack.
- **Solution**:
  - Replace the custom `NSPanel` overlay with a native SwiftUI `.popover(isPresented:arrowEdge:)`.
  - Connect autocomplete queries to `AmbrosiaMetaDB.searchTags(query:field:limit:)` to display tag frequency counts alongside suggestions.
  - Keep debounce (`DebounceTimer(delay: 0.15)`) for smooth typing.

### 4.4 Card-Based Boolean Visual Hierarchy
- Style `FilterGroup` containers as distinct macOS card elements:
  - Background: `Color(NSColor.controlBackgroundColor)`.
  - Corner radius: `10pt` with subtle stroke border.
  - Header: Clear group numbering (`Group 1`, `Group 2`) and prominent pill selector for `ALL (AND)` vs `ANY (OR)`.
  - Intersperse multiple groups with a distinct badge connector (`AND` / `OR`).

---

## 5. Implementation Roadmap & Test Plan

### Step 1: In-Window Sidebar Architecture
- Add `showAO3FilterSidebar` to `LibraryToolbarState`.
- Update `LibraryWindowController.triggerSidebarToggle()` to toggle this state in `.list` mode.
- Embed `AO3FilterPopupView` into `LibraryRootView` inside an animated `HStack`.
- Add Detach/Attach buttons.

### Step 2: Faithful AO3 Web Enhancements
- Add `wordsFrom` / `wordsTo` to `AO3FilterPopupState` and UI under "More Options".
- Add inline tag search input inside tag accordions using `AmbrosiaMetaDB.searchTags`.
- Implement `passthroughRules` preservation in `AO3FilterPopupState`.

### Step 3: Filter Library Drawer Modernization
- Refactor `FilterDrawerView` to use draft state lifecycle (`draftExpression`).
- Implement unified `Word Count` and `Kudos` range operators (`between`, `>`, `<`).
- Replace `FilterValueTextField`'s child `NSPanel` with SwiftUI `.popover` and link to `AmbrosiaMetaDB.searchTags`.
- Update visual styling for group cards.

### Step 4: Verification & Quality Gate
- Run `swiftlint lint --strict` (0 violations).
- Run full test suite `./test.sh` (100% pass rate).
- Update documentation in `docs/search-and-filter.md` and `docs/library-ui.md`.
