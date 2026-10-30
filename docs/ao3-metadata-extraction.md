# AO3 metadata extraction

Scope: how AO3 preface HTML embedded in an EPUB is parsed into structured
metadata, and how tag canonicalization/synonym expansion is stored. For how
that metadata is used in search/filter, see `search-and-filter.md`. For the
EPUB container/HTML parsing this reads from, see `epub-parsing.md`. The raw
HTML shapes this extractor parses are described in
`docs/ao3_epub_html_reference.md`, a local-only file that is gitignored because
it contains non-open-source material (see `CLAUDE.md`, "Local-only files").
It may be absent from your checkout; do not copy its text into tracked files.

---

## AO3 Metadata and Tags

`AO3MetadataExtractor` parses AO3 EPUB preface HTML with SwiftSoup and returns `AO3MetadataRecord`. `LibrarySession` tries spine[0] first (AO3 EPUBs reliably place the preface there), falling back through the next four spine items for non-standard files, stores successful extraction in `ao3_metadata`, and stores skipped/failed attempts in `ao3_extraction_diagnostics`. Extraction runs concurrently via a capped `TaskGroup` (up to 8 books in flight at once), flushing to the DB every 10 books or every 2 seconds, whichever comes first, with `Task.yield()` between flushes so read queries can cut in.

Extracted fields include story URL, work ID, author username, kudos, word count, chapter counts, completion, language, dates, fandoms, relationships, characters, additional tags, categories, AO3 collections, and AO3 series.

Series metadata is cached in `series_cache`; Calibre series data is inserted as fallback.

### Tag Seeds & Synonym Resolution
Configured AO3 tag seed databases (`ao3_tag_seeds.db`) are queried **directly in read-only mode** via `AO3TagSeedDatabaseConfig.shared`. Tag seed rows are no longer duplicated into each library's `ambrosia_meta.db`, saving ~117 MB per library and eliminating duplicate tables (`canonical_tags`, `tag_synonyms`, `tag_parent_links`, `tag_subtag_sections`). Any legacy copies of these tables in existing `ambrosia_meta.db` files are automatically dropped and vacuumed on library open.

`canonicalTerm(for:)` and `expandedTerms(for:)` on `AmbrosiaMetaDB` delegate directly to `AO3TagSeedDatabaseConfig.shared`, providing canonicalization and synonym expansion across search and filter pipelines without redundant disk copies.

### Extraction Diagnostics & Debugging Failed Works
When extraction encounters a non-AO3 EPUB or malformed preface structure, the failure reason is recorded in `ao3_extraction_diagnostics (calibre_id, story_url, reason, attempted_at)`.

In **Settings ▸ Data**, users can view extraction progress (Extracted vs. Failed vs. Total) and click **"View Failed Works"** to open a diagnostic inspection sheet. The sheet displays the book title, author, and specific parsing error message (e.g. missing preface elements, malformed HTML, or unparseable metadata), with a button to open each failed book directly in the reader for inspection.

---


