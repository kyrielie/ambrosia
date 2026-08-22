# EPUB parsing

Scope: `EPUBParser` — opening the EPUB zip, parsing the OPF manifest/spine,
and producing merged HTML plus offset-addressable plain text. For the
AO3-specific preface metadata extracted from this HTML, see
`ao3-metadata-extraction.md`. For how the merged HTML is loaded and
rendered, see `reader.md`.

---


`EPUBParser`:

1. Opens the EPUB zip.
2. Reads `META-INF/container.xml`.
3. Parses OPF manifest/spine/title via SAX.
4. Produces stripped, merged HTML with injected user CSS.
5. Provides plain text for offset arithmetic.
6. Extracts images to `/tmp/ambrosia/<calibreID>/`.

Offset contract everywhere: UTF-16 code units, text-node content only, no HTML tags.


---

## Key invariant

5. Character offsets are UTF-16 code units in text nodes only. This contract must be consistent across `EPUBParser`, `PaginationJS`, `HighlightBridge`, and any JS that reads or writes offsets.

15. Image temp directory lifetime is the app session; clean up on app termination.
