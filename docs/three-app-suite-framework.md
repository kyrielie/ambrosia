# Three-app suite framework

## Purpose

This document defines how Honeycrisp, Ambrosia, and Nectar fit together as a
suite. They are separate products with different levels of responsibility and
integration, not editions of one application and not a required upgrade path.
Users should be able to choose the app that fits how they already find,
organize, and read books.

The suite's organizing principle is **progressive responsibility with
preserved user control**: each app can take on more of the reading workflow,
but increased convenience should not require giving up ownership of files,
library structure, or app-owned data.

## The responsibility spectrum

| App | Starts with | The app is responsible for | User's primary freedom |
|---|---|---|---|
| **Honeycrisp** | EPUB files selected by the user, including files reached through existing folders or Calibre | Opening, rendering, navigating, and remembering reading state for an individual book | Keep the user's existing filing and library workflow; open a book directly with little setup |
| **Ambrosia** | A Calibre library the user already maintains | Finding, organizing, and reading books within that library, plus Ambrosia-owned reading state and annotations | Use richer collection and reading tools while retaining Calibre as the authority for books and metadata |
| **Nectar** | Web sources, feeds, and fetched reading material | Discovering, fetching, updating, presenting, and annotating material from connected sources | Choose sources and fetching behavior; keep fetched content and reader customizations under user control |

This is a spectrum of **workflow integration**, not a feature ranking. Nectar
does not replace a folder-oriented reader for every user; Ambrosia does not
need to become an acquisition service; Honeycrisp does not need to grow a
catalog to be useful. A user may use one app, several apps, or switch based on
the task.

Short descriptions:

- **Honeycrisp reads the EPUBs you already have.**
- **Ambrosia organizes and reads the library you maintain.**
- **Nectar brings web reading material into a managed reading workflow.**

## Product boundaries and ownership

### Honeycrisp: file-level reading

Honeycrisp should remain the lowest-friction entry point. The user selects a
file or opens one from a folder/library workflow they already trust. Honeycrisp
may keep local reading position, history, and presentation preferences, but it
does not need to index or reorganize the user's collection. It should be a
good companion to Calibre precisely because it can read an EPUB without
claiming ownership of the Calibre library.

Its boundary is individual-book reading. Features that require a persistent
catalog, cross-book workflows, or web-source management belong in Ambrosia or
Nectar unless a narrowly scoped reader interaction clearly improves the
standalone experience.

### Ambrosia: library-level management and reading

Ambrosia begins with an existing Calibre library. Calibre remains authoritative
for book records and EPUB files; Ambrosia provides discovery, collections,
reading, annotations, and app-owned metadata around that library. It must not
silently rewrite Calibre's database or book files to provide its own features.

Ambrosia is the natural home for substantial local-library workflows: search,
collections, series-aware reading, reading state across a collection, and
annotations that can be browsed and exported in library context. It can adopt
Nectar's annotation and editing capabilities because those improve the reading
surface, even though Ambrosia does not adopt Nectar's feed and fetching model.

### Nectar: source-level integration and fetching

Nectar starts with web sources and takes responsibility for bringing material
into a reading environment. Source connectors, refresh policy, source identity,
and web-specific presentation belong here. Its annotation system is a mature
reference for richer reading interactions, but Nectar's database, HTML
template, web-source identity, and platform assumptions are not automatically
shared contracts for EPUB or macOS apps.

If Nectar gains a macOS app, it should reuse suite concepts and compatible
formats where that yields real user value, while retaining its own source and
fetching workflows.

## What should be consistent across the suite

Consistency is most valuable at the user-facing seams and at durable data
boundaries. It does not require a shared codebase or database.

### Reader interaction concepts

Where an app supports the same interaction, align the meaning and basic
behavior of:

- Reading position and progress, including what counts as a page or location.
- Highlights, notes, and other annotations; color meaning and keyboard/accessibility behavior.
- Reader themes, typography, spacing, color, and appearance changes.
- Search, table of contents, and navigation conventions where applicable.
- Undo, revert, and confirmation for any action that changes displayed text.

An app can expose only the subset that fits its scope. Shared vocabulary and
predictable behavior matter more than identical controls.

### User agency and reversibility

All apps should make state changes understandable and recoverable:

- Explain which content is source material and which changes are overlays or app-owned state.
- Keep original source content intact by default.
- Provide a clear way to inspect, edit, disable, revert, export, or delete app-owned changes.
- Preserve user data when removing an app; any destructive cleanup should be explicit.
- Never infer permission to fetch, publish, or modify external data from permission to read it.

### Local data, portability, and accessibility

Use local-first behavior where the product permits it. Document storage locations
and backup boundaries. Prefer exportable formats for user-created state, and
make keyboard navigation, VoiceOver labels, Dynamic Type-equivalent sizing,
contrast, and reduced-motion behavior part of reader feature design.

## What should remain app-specific

- **Persistence:** Honeycrisp's per-book history, Ambrosia's per-library state,
  and Nectar's account/source database have different lifecycles and ownership.
- **Content identity:** a file URL/book identity, a Calibre book ID, and a web
  work/article key are not interchangeable. Any cross-app identifier mapping
  must be explicit and resilient to moved files or refreshed HTML.
- **Acquisition and sync:** web fetches, AO3/account actions, and refresh
  scheduling belong to Nectar. Local reading must not depend on Nectar being
  installed or available.
- **Library authority:** Calibre integration belongs to Ambrosia (and file
  opening to Honeycrisp), not to a suite-wide library abstraction that implies
  ownership over every user's files.
- **Rendering implementation:** EPUB spine rendering and article HTML
  rendering differ. Share behavior or pure algorithms only where the contracts
  genuinely match; do not force one renderer, DOM template, or theme package
  onto all content types.
- **Release cadence and platform UI:** each app can ship independently and use
  native controls appropriate to its platform.

## Ambrosia: adopting Nectar's annotations and text editing

Ambrosia already has ranged highlights, point annotations, notes, colors,
annotation browsing, and CSV export. Nectar's annotation work suggests a
substantial next step: model annotations as reversible overlays on canonical
source text, then allow deliberate text replacement without rewriting the
underlying article or EPUB. This is a product capability to adapt, not a
commitment to share Nectar's database schema or code as-is.

Nectar's documented implementation combines exact quote and surrounding
context with offsets, resolves anchors after content changes, allows a row to
carry both a highlight and a text edit, adjusts later annotation anchors when
replacement length changes, and provides rule-driven replacements with review
and revert paths. See Nectar's `docs/annotations.md` for implementation
reference. Ambrosia's current annotation model is EPUB-oriented and stores
offsets against spine content in `AmbrosiaMetaDB`; it needs an EPUB-specific
anchor and rendering design.

### Principles for Ambrosia

1. **Do not rewrite EPUB files or Calibre records.** Store replacements and
   annotations in Ambrosia-owned metadata; compose them when rendering.
2. **Keep edits explicit and reversible.** Manual edits should be visibly
   marked as edits, offer a way to compare with source text, and support
   reverting one edit without losing unrelated annotations.
3. **Separate edit state from highlight state.** A replacement can exist
   without a highlight; a user may optionally retain a highlight on an edited
   span.
4. **Protect annotation anchors.** Use a selector with quote and context
   information as well as a location within a specific EPUB spine item. Treat
   offsets as a fast path, not as a globally durable identity.
5. **Make automation opt-in and reviewable.** Rule-driven typo fixes or
   reader-insert substitutions should be disabled or clearly explained by
   default for new users, be previewable, and be reversible. They must never
   change the source EPUB.
6. **Handle conflicts honestly.** If an edit overlaps another annotation or
   cannot be anchored confidently after a content update, surface the conflict
   for resolution instead of silently moving or dropping it.
7. **Keep the EPUB renderer's structure under Ambrosia's control.** Text edits
   must not permit arbitrary scripts or HTML templates to replace the reader's
   navigation, pagination, or safety behavior.

### Proposed delivery sequence

1. **Audit and model:** document current anchor coordinate semantics for
   paginated and scroll modes, spine identity, annotations spanning DOM nodes,
   and EPUB content changes. Decide how quote/context selectors coexist with
   current UTF-16 offsets and `spineIndex`.
2. **Anchor resilience:** add quote plus prefix/suffix context to Ambrosia's
   annotation model and implement deterministic re-resolution against a spine
   item. Report unresolved or ambiguous anchors in the annotation UI.
3. **Manual text edits:** add an edit overlay stored in app-owned metadata,
   rendered without modifying the parsed EPUB text. Initially reject
   overlapping edits/highlights when shifting them cannot be done safely.
4. **Edit review and revert:** expose edit state in the annotation sidebar,
   show original and replacement text, allow a kept highlight to be toggled
   separately, and provide per-edit revert with correct anchor adjustment.
5. **Rule-based assistance:** only after manual edits are reliable, add
   optional typo or reader-insert rules with preview, scoped settings, a
   reviewable edit list, and a single-action way to revert generated edits.
6. **Portability:** extend annotation export/backup formats to include anchor
   context and edit fields, with a format version and clear conflict policy.
   Never include or rewrite Calibre data unless a separate, explicit
   integration is designed.

The phases are a proposed order, not a commitment to implement every rule
category in Nectar. Manual, reversible correction and robust anchors are the
core capability; automatic transformations need demonstrated demand and
careful defaults.

## Sharing and interoperability strategy

Use the least coupled option that solves a demonstrated problem:

1. **Shared product principles and terminology** first.
2. **Documented interchange formats** for user-owned data (annotations,
   themes, backups) when users need to move or back up that data.
3. **Small shared pure libraries** only for stable algorithms with matching
   semantics and compatible platform needs.
4. **Direct app-to-app integration or shared services** only for an explicit
   workflow, with clear offline behavior and no mandatory dependency between
   apps.

Do not make the apps share a database, require one another to be installed,
or synchronize edits automatically as an early architecture choice. If users
later need to move annotations or reading state, define an export/import
contract first. A cross-app identity must preserve source attribution and
report unresolved anchors rather than guessing.

## Decision guide for future features

For each proposed feature, ask:

1. Does it help with opening/reading an existing file, managing a maintained
   library, or acquiring/updating web material? Put it in the app whose
   responsibility it advances.
2. Does it improve a shared reading interaction or durable user-data boundary?
   Align semantics and export behavior across apps where feasible.
3. Does it require new ownership of external files, accounts, or sources?
   Keep that responsibility explicit and app-specific.
4. Can the feature be disabled, inspected, undone, and backed up?
5. Can one app deliver it independently without making another app a runtime
   dependency?

If a feature does not fit cleanly, prefer a clear one-app implementation and
document the boundary rather than expanding the suite abstraction prematurely.

## Open decisions

- Which Ambrosia annotation fields and anchor selectors are needed for robust
  EPUB text edits across reader modes and parser/rendering changes?
- Should rule-driven edits be global, per library, per book, or a combination?
- What annotation export format should be portable between the three apps, if
  any, and how should incompatible or ambiguous anchors be presented?
- If Nectar ships on macOS, which parts of its reader behavior should match
  the native apps, and which remain specific to web-source reading?
- Which suite-level data conventions merit a separate shared package versus
  documentation and independent implementations?
