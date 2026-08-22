# AO3 metadata extraction

Scope: how AO3 preface HTML embedded in an EPUB is parsed into structured
metadata, and how tag canonicalization/synonym expansion is stored. For how
that metadata is used in search/filter, see `search-and-filter.md`. For the
EPUB container/HTML parsing this reads from, see `epub-parsing.md`.

---

## AO3 Metadata and Tags

`AO3MetadataExtractor` parses AO3 EPUB preface HTML with SwiftSoup and returns `AO3MetadataRecord`. `LibrarySession` tries spine[0] first (AO3 EPUBs reliably place the preface there), falling back through the next four spine items for non-standard files, stores successful extraction in `ao3_metadata`, and stores skipped/failed attempts in `ao3_extraction_diagnostics`. Extraction runs concurrently via a capped `TaskGroup` (up to 8 books in flight at once), flushing to the DB every 10 books or every 2 seconds, whichever comes first, with `Task.yield()` between flushes so read queries can cut in.

Extracted fields include story URL, work ID, author username, kudos, word count, chapter counts, completion, language, dates, fandoms, relationships, characters, additional tags, categories, AO3 collections, and AO3 series.

Series metadata is cached in `series_cache`; Calibre series data is inserted as fallback.

Configured AO3 tag seed databases can be imported into `canonical_tags`, `tag_synonyms`, `tag_parent_links`, and `tag_subtag_sections`. Synonym expansion is present at the storage layer but UI coverage is incomplete.

**Fixed.** `AO3TagSearchResolver` has been removed. `canonicalTerm(for:)` and `expandedTerms(for:)` are now actor-isolated methods on `AmbrosiaMetaDB` itself, called through `LibrarySession.metaDB` from the search and filter pipeline. No code path opens an independent connection to `ambrosia_meta.db` for tag resolution anymore.

---


