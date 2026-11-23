## How filtering works

**One engine, three front ends.** The search box, the drawer and the AO3 builder all produce a `FilterExpression`: groups of `FilterRule`s, with AND/OR inside a group and one conjunction between groups. The ribbon is a view over that same expression. `LibraryDisplayController.applyFilterRules()` evaluates it, and a page load then uses the active sort.

**Search box**
- Typing only keeps a draft. Return, or picking a suggestion, commits it.
- At commit, text is parsed by `SearchQueryParser`:
  - More than one scoped token with no plain text becomes several `FilterRule`s.
  - A single `tag:` token has its tag resolved to the canonical form (`canonicalTerm`) and becomes one rule.
  - The search field is cleared whenever a token becomes a rule.
  - Anything else stays live as the committed query: plain title text (fuzzy LIKE), `fulltext:` and `semantic:`.
- Suggestions come from an in-memory snapshot. They are ranked by match class first and frequency second.
- Live queries use a separate SQL path (`CalibreLibrarySearch`) that reads Calibre's own tag, author and series tables.

**Drawer**
- It is a generic rule builder with 19 field types and a draft/Apply lifecycle. Modal width is 720 pt.
- Evaluation branches:
  - **Branch A, SQL-pageable.** Only when every rule is a plain SQL-able field (title, comment, word count or kudos with a custom column). The database does the filtering and paging.
  - **Branch B.** A result cache keyed on the expression and visibility versions.
  - **Branch C, full evaluation.** Tag, rating, warning and category rules read `book_tags`, with a Calibre-side fallback for books without AO3 data. Author uses `book_authors`, series uses `series_cache`, and collection, status, liked and crossover use in-memory sets. Position filters (`firstRelationship`, `firstCharacter`) and `relationshipCount` use SQLite JSON1 pushdown (`json_each`) over `ao3_metadata` with candidate pre-filtering against `book_tags` and Decision 4 exclusion semantics. Fulltext goes through FTS.
- Adding one AND rule can narrow the previous result instead of recomputing. This is behind a flag that defaults off in release.
- Tag values are expanded through the synonym database at filter time, with optional Level 1 variant normalizer matching.

**Ribbon**
- Each rule appears as a pill with remove, include/exclude toggle (only where the opposite operator exists), copy, edit in drawer, clear all, and role-aware conversions (convert between plain tag and first-listed relationship/character, and toggle tag variants).
- It changes the expression and triggers the same apply path.

**AO3-style builder**
- Its state is sets of included and excluded values. `buildExpression()` turns them into:
  - an include group of ANDed `.equals` rules;
  - an exclude group of ANDed `.notEquals` rules, which matches AO3's "must not have any" semantics;
  - word-count and status rules, plus any non-AO3 drawer rules carried through unchanged.
- Facet counts come from raw `json_each` tag tallies merged by canonical name, so counts can exceed the filtered work count. The doc explains this.

**After filtering.** Results pass through the visibility policy and the sort path (title, word count, kudos, random, relevance). Page, count and sorted-ID caches sit on top, and an extraction batch clears them.