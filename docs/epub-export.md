# EPUB Export & Modernization

## Overview
Ambrosia provides two export paths for books in a Calibre library:
1. **Direct Copy (Archival Default)**: Performs a 1:1 byte-faithful copy of the source EPUB file directly from the Calibre library, preserving original assets and structure.
2. **Modernized EPUB 3 Export (Gated via Preference)**: Normalizes legacy EPUB 2 files into modern EPUB 3.0 packages with rich metadata, semantic structural markup, and polished e-reader stylesheets, while keeping the author's written content strictly unaltered.

Governed by `ReaderPreferences.shared.enableAdvancedEPUBExport`.

---

## Archival Invariants & Philosophy

1. **Written Content is Invariant**: The author's written words, punctuation, dialogue, straight quotes, and ASCII/markdown formatting are canonical fanfiction artifacts. Ambrosia **never** runs automated typography transformations (such as Standard Ebooks straight-to-curly quote substitution, dash alteration, or ellipses replacement).
2. **HTML Scaffolding is Mutable**: Calibre's legacy EPUB 2 markup (`<div class="calibre">` soup) can be upgraded to semantic EPUB 3 markup (`<section epub:type="chapter" role="doc-chapter">`, `<header>`, `<main epub:type="bodymatter">`, `<div class="meta">`).
3. **Stylesheets & Metadata are Mutable**: Stylesheets (`stylesheet.css`, `page_styles.css`) and OPF package metadata can be modernized for modern e-readers, dark mode, and standards compliance.
4. **Original AO3 Preface & Hyperlink Preservation**: When normalizing AO3 EPUBs, the authentic original AO3 preface (`split_000.xhtml`) is preserved in `preface.xhtml` as the canonical frontmatter item. This retains all live AO3 hyperlinks (works, tags, fandoms, relationships, series) and the familiar AO3 card layout without duplicating prefaces or generating stacked headings.
5. **No Synthetic Covers or Spurious Cover Properties**: Ambrosia strictly avoids synthesizing, injecting, or tagging images with `properties="cover-image"`. Fanfiction works without author-provided cover images remain typography and metadata first. Embedded illustrations are preserved in `EPUB/images/` and referenced via relative `../images/<filename>` paths from chapter text.
6. **Flat Subject Taxonomy**: `<dc:subject>` metadata tags mirror the flat, un-prefixed taxonomy of the original AO3 EPUB (e.g. `<dc:subject>General Audiences</dc:subject>`, `<dc:subject>Doctor Who</dc:subject>`). Spurious category prefixes (`Fandom -- `, `Rating -- `) are intentionally rejected to maintain compatibility with existing user libraries and Calibre tag spaces.

7. **In-Library Immobility vs. Downstream Export**: Ambrosia never reformats or converts EPUB files in the user's Calibre library on disk. Original AO3 downloads remain untouched in their authentic EPUB 2 state. When reading inside Ambrosia, HTML cleanup and card formatting occur entirely in memory on the fly via `EPUBParser.sanitise()`. Modernized EPUB 3 generation is strictly an on-demand export path for external hardware e-readers (e.g. Kobo, Kindle, Apple Books) that lack Ambrosia's Swift runtime and rely entirely on bundled stylesheets and valid XHTML packaging.
8. **EPUB 3 ID Uniqueness & Section Scaffolding**: To avoid XML duplicate ID collisions under EPUBCheck, the normalized frontmatter section wrapper uses `<section class="preface" epub:type="preface">` (without `id="preface"`), ensuring the inner authentic AO3 `<div id="preface">` remains the sole, unambiguous ID target for DOM and anchor lookups.

---

## EPUB 3 Container Structure & Packaging

Normalized EPUB 3 exports and multi-work omnibus editions conform strictly to the EPUB 3.0 packaging standard:

- **Root Container Directory**: `EPUB/` is the standard OCF content root (`META-INF/container.xml` references `full-path="EPUB/content.opf"`).
- **Directory Layout**:
  - `EPUB/content.opf`: Package manifest, spine, and refined Dublin Core metadata.
  - `EPUB/toc.xhtml`: EPUB 3 Navigation Document (`<nav epub:type="toc">`) linking to relative `text/` targets.
  - `EPUB/toc.ncx`: EPUB 2 NCX fallback for legacy e-ink devices.
  - `EPUB/text/`: XHTML chapter and frontmatter files (`imprint.xhtml`, `preface.xhtml`, `chapter_*.xhtml`, `afterword.xhtml`).
  - `EPUB/css/`: Modern stylesheets (`stylesheet.css`, `page_styles.css`).
  - `EPUB/images/`: Story illustrations and image assets.
- **Uniform Work Identifier**: `package[unique-identifier="pub-id"]` with `<dc:identifier id="pub-id">https://archiveofourown.org/works/<work_id></dc:identifier>`.
- **Scoped Stylesheet & Semantic Containers**: Chapter text is wrapped in `<div id="workskin" class="userstuff">` matching AO3's semantic container model. Scoped CSS rules provide readable typography, responsive blockquotes, and automatic dark mode support (`@media (prefers-color-scheme: dark)`) while preserving styling for original AO3 `<dl class="tags">` and `.byline` cards.

---

## Calibre Single-Series Limitation & Multi-Series Handling

### The Problem
Calibre's core database schema (`books` table in `metadata.db`) and its OPF parser (`calibre/src/calibre/ebooks/metadata/opf3.py:805-845`) **strictly support only a single series per work**.
- When an EPUB has multiple series in `belongs-to-collection` or `<meta name="calibre:series">`, Calibre reads only the **first** series and discards the rest.
- If a user runs Calibre's "Polish" or "Embed Metadata", Calibre wipes all existing series metadata and writes only its single primary series.

### Ambrosia's Solution
Because OPF metadata cannot reliably store multiple series in Calibre:
1. **Human-Readable Frontmatter**: In `imprint.xhtml`, all series memberships are explicitly listed in the metadata definition list:
   `Part 1 of Series A; Part 4 of Series B`
   This guarantees that human readers and e-readers see all series memberships losslessly.
2. **Filesystem Organization**:
   - When exporting with "Group by Series" enabled, a book belonging to multiple series is copied into **each** series directory:
     `<destination>/<SeriesA>-<ID>/01 - <Title>-<ID>.epub`
     `<destination>/<SeriesB>-<ID>/04 - <Title>-<ID>.epub`
   - In each folder, the filename prepends the specific zero-padded index for that series so narrative reading order is preserved in filesystem browsers.
   - For standalone works (no series), `seriesIndexPrefix` is `nil`, ensuring standalone fics are placed directly in the destination folder without any spurious `00 - ` prefix.
3. **Context-Sensitive OPF Series**:
   - In the generated `package.opf`, Ambrosia sets the primary `<meta name="calibre:series">` and EPUB 3 `<meta property="belongs-to-collection" id="series_01">` to match the active series directory the file is being exported into.

---

## Credits & References

1. **Timothy Cyrus (`tcyrus`)**:
   - Creator of **`epub-otwarchive`** ([AO3 Work 89438831](https://archiveofourown.org/works/89438831), [GitLab](https://gitlab.com/epub-otwarchive/epub-otwarchive)).
   - Authored the research, ERB templates, and CSS specifications detailing the flaws in default Calibre/AO3 downloads and proposing direct EPUB 3 generation with proper metadata refines and BCP-47 language tag normalization.
2. **Nectar (`../nectar`)**:
   - Provided the baseline Swift EPUB 3 generation engine, landmark navigation patterns, and dark-mode CSS contrast safety guards.
