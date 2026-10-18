# Features to adopt from Nectar and Honeycrisp

This document compares Nectar's and Honeycrisp's documented reading-theme and
reader features with Ambrosia's product shape, and proposes a scoped adoption
order. It is a planning document, not a commitment to reproduce Nectar's RSS,
iOS, or AO3 account workflows, or Honeycrisp's standalone-reader scope.

Nectar reference docs live in `../nectar/docs/`: `theme-system.md`,
`nnwtheme-format.md`, `creating-a-theme.md`, `theme-gallery.md`,
`theme-anatomy.html`, `reading-progress.md`, `reading-stats.md`,
`reading-time.md`, `backup-restore.md`, and `annotations.md`.

Honeycrisp references are in `../honeycrisp/`: `README.md`,
`ARCHITECTURE.md`, `AUDIT.md`, and `docs/honeycrisp-settings-window-plan.md`.

## Product fit

Ambrosia is a macOS EPUB reader for AO3-heavy Calibre libraries. Calibre stays
the read-only source for books and metadata; Ambrosia owns reading state,
annotations, collections, and presentation. Nectar's most reusable ideas are
therefore reader presentation and management of app-owned data. Its feed
subscription, account sync, AO3 login, and mobile-specific behavior are outside
Ambrosia's current shape.

## Recommended order

### 1. Apply style-only reader changes live

**Recommendation: implement first.** Ambrosia currently interpolates values
into `ReaderPreferences.css` and reloads/re-parses the EPUB after every reader
preference change. Move typography, color, and spacing values to CSS custom
properties (for example `--ambrosia-font-size`, `--ambrosia-line-height`, and
`--ambrosia-page-background`). When a style preference changes, update those
properties in the active `WKWebView`. Keep full HTML reloads for reading-mode
switches and other structural changes.

This follows Nectar's separation between shared structural CSS and theme CSS,
while addressing a performance and interaction issue already documented in
`reader.md`. Preserve the current publisher CSS/script stripping and user
control over presentation.

### 2. Define a stable reader theme layer

**Recommendation: implement with the live-style work.** Separate Ambrosia's
reader CSS into:

1. Structural rules required for safe rendering and pagination.
2. A selected theme's presentation rules: typography, colors, margins, and
   optional decorative treatment.
3. User preferences that override theme defaults through documented CSS
   variables.

Keep the structure owned by Ambrosia so a theme cannot break navigation,
pagination, annotation anchors, or safety constraints. Start with bundled
themes and built-in controls. Do not add arbitrary HTML-template replacement
until there is a concrete need; Ambrosia renders EPUB content whose structure
comes from the book, unlike Nectar's generated article page.

### 3. Add a reader theme preview

**Recommendation: implement after the theme layer exists.** Show a sample EPUB
page using the same renderer and CSS pipeline as the real reader. Include
representative headings, paragraphs, links, images, and a highlight so users
can compare themes and accessibility settings without opening a book. Reuse
the same preview content for any future theme gallery or import screen.

### 4. Document CSS hooks and theme authoring

**Recommendation: ship alongside previews.** Document the CSS variables and
stable DOM hooks that Ambrosia supports, which rules remain structural, and
how themes should handle images, long titles, links, dark appearance, and
pagination. Include a minimal example stylesheet and a checklist for testing
scroll and paginated modes. Treat the rendered DOM contract as versioned app
behavior; avoid exposing incidental parser markup as a supported API.

### 5. Consider importable CSS theme bundles

**Recommendation: defer until built-in themes and preview feedback establish
demand.** If community themes are desired, use a small bundle containing a
stylesheet, metadata, and license/attribution text. Prefer CSS-only bundles.
Validate archive paths and file sizes before extraction; ignore or reject
scripts, executable resources, and unsupported HTML templates. Store installed
themes under Ambrosia's Application Support directory, never in the Calibre
library. Define how missing or deleted themes fall back before adding import.

A public gallery is a later distribution feature, dependent on a stable bundle
format, versioning policy, compatibility checks, and a maintenance owner.

### 6. Add backup and restore for Ambrosia-owned state

**Recommendation: evaluate as a separate reliability feature.** Nectar's
backup/restore approach is relevant because Ambrosia data is split across
SwiftData, per-library metadata databases, preferences, and potentially
installed themes. First define a portable archive format and a consistent
snapshot boundary. Include only Ambrosia-owned data; never copy or modify
Calibre's `metadata.db` or EPUB files. Specify conflict handling when restoring
into a library that already has state.

## Lower-priority product ideas

- **Saved searches:** already listed in `not-yet-built.md`; useful for repeat
  library queries and a better fit than Nectar's feed shelves.
- **FTS snippets and reader jumps:** complete the existing Calibre FTS flow by
  locating hits precisely and opening the reader at the match.
- **Reading statistics refinements:** Nectar tracks active time and progress
  with explicit session boundaries and caps implausible word credit. Ambrosia
  already tracks reading goals and activity; review those semantics before
  adding detailed stats, and make any new accounting behavior opt-in or
  clearly explained.
- **Works needing attention:** explore an incomplete/abandoned-work view only
  if Ambrosia can define reliable criteria from extracted metadata. Do not
  infer abandonment from missing or stale metadata alone.

## Ideas from Honeycrisp

Honeycrisp is a standalone macOS EPUB reader, while Ambrosia already manages
Calibre libraries and has a more capable reader. Several Honeycrisp features
are therefore useful as interaction patterns, but not all warrant a duplicate
implementation.

- **Saved reader themes and a quick theme switcher — adopt.** Honeycrisp lets
  readers save preferred formatting as named themes and switch from a reader
  popover. Ambrosia should build on the theme layer above: make named
  combinations of font, size, spacing, and colors, preview them, and switch
  without closing the book. Keep per-library or global scope as a product
  decision; avoid storing theme state in Calibre.
- **Cosmetic versus structural setting changes — adopt.** Honeycrisp
  distinguishes live cosmetic updates from structural changes that require
  rebuilding the rendered document. Ambrosia's reader docs identify the same
  boundary. Model this explicitly in preference notifications so visual
  adjustments do not trigger EPUB parsing, while pagination and mode changes
  use the appropriate reload path.
- **Settings reset and import/export — consider.** Honeycrisp provides a
  reset-to-defaults action and documents a settings snapshot export/import
  direction. Ambrosia has more distributed per-library state, so start with a
  clear reset scope and a versioned backup format. Do not conflate resetting
  preferences with deleting annotations or collections.
- **Key binding customization — consider.** Honeycrisp has user-rebindable
  shortcuts. Ambrosia has reader/library actions and existing shortcut
  preferences; a curated customization UI could help power users, provided
  conflicts with standard macOS menu shortcuts are detected and defaults are
  easy to restore.
- **Focus controls such as Float on Top — optional.** A per-window always-on-top
  toggle can help while reading alongside notes or reference material. This is
  a small standalone reader feature and should follow only if Ambrosia users
  request it; it is not core library functionality.
- **Reading history and position persistence — already covered in part.**
  Ambrosia records reading activity and positions. Honeycrisp's audit is a
  useful reminder to test that opening a book cannot overwrite its saved
  position before restoration reads it, especially across windows, series,
  and mode changes.
- **Multiple windows and tabs — verify current behavior before changing.**
  Ambrosia already opens readers in windows and supports reading a whole series
  in one window. Honeycrisp offers tabs as an alternate way to hold several
  books. Treat tabs as an optional window-management enhancement, not a reason
  to change Ambrosia's existing series-reading model.
- **In-book search, TOC, and pagination — retain Ambrosia's existing path.**
  These are core Honeycrisp reader features, but Ambrosia already provides
  search, a TOC panel, scroll/paginated modes, and series continuity. Compare
  implementation details for edge-case ideas rather than porting the feature
  wholesale.

Do not adopt Honeycrisp's no-library, no cross-book search, and
publisher-styling-stripped boundaries: those are deliberate constraints for a
standalone reader and do not match Ambrosia's product.

## Do not port directly

- RSS/Atom subscriptions, account sync, feed refresh scheduling, or iOS
  background refresh.
- AO3 authentication, kudos, and bookmark posting; these introduce online
  account behavior absent from Ambrosia's current local-reader scope.
- Nectar's HTML template tokens, AO3 page DOM transformations, and its
  `nnwtheme` bundle format as-is. Ambrosia's source is EPUB content and its
  parser/reader contract is different.
- Features whose only purpose is integrating with Nectar's feed protocol.

## Suggested milestones

1. **Reader styling foundation:** CSS custom properties, explicit cosmetic vs.
   structural updates, live updates for style-only settings, and verification
   that structural changes still take the correct path.
2. **Theme usability:** named saved themes, quick switching, at least one
   additional bundled theme, a live sample preview, and authoring docs for
   supported CSS hooks.
3. **Reader workflow:** prioritize saved searches and FTS snippets/jumps from
   Ambrosia's existing backlog; separately assess shortcut customization and
   always-on-top based on user demand.
4. **Portability and ecosystem:** define backup/restore and reset scopes, then
   assess third-party theme import and gallery support.

## Acceptance criteria for the first milestone

- Changing font, color, or spacing updates an open reader without re-parsing
  the EPUB or losing its reading position, selection, or annotation anchors.
- Switching scroll/paginated mode and changing structural layout still takes
  the correct reload/repagination path.
- CSS-variable values are safely encoded before being passed to JavaScript.
- Theme and preference CSS cannot disable required reader navigation or
  annotation behavior.
- The reader documentation describes the CSS layers and identifies which
  preference changes update live versus reload.
