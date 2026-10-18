# Calibre full-text search (FTS5) integration

Status: `fulltext:` queries a real FTS5 `MATCH` against Calibre's `books_fts` when the
file is opened in `native` mode. Written without a Swift toolchain: none of the Swift in
this subsystem has been compiled or run (see "Verification log"). Plan decisions are cited
as D1, D2 and so on; gates as G1, G2 and so on.

## Modes (D7)

`CalibreFTSLibrary` picks one mode when it opens `full-text-search.db` (and again whenever
it reopens the file, see "Working alongside Calibre"):

- `native`: tokenizer registered, `PRAGMA user_version == 1`, and `SELECT 1 FROM books_fts
  WHERE books_fts MATCH 'a' LIMIT 1` steps without error.
- `likeFallback`: `books_text` is usable but native mode could not be established. A
  literal substring `LIKE` scan over `searchable_text` (escaped, `ESCAPE '\'`).
- No library object (`init?` returns nil): the file is missing, cannot be opened
  read-only, or `books_text` lacks `id, book, format, searchable_text`.

The DEBUG log prints `mode=native|likeFallback reason=...` on every open.

## Query path

Phase 1, `searchBooks(_:token:)`: ids only, unranked, `SELECT DISTINCT bt.book FROM
books_fts JOIN books_text bt ON bt.id = books_fts.rowid WHERE books_fts MATCH ?`. No
`LIMIT` (D8), no format filter unless `FTSQuery.formats` is set (D9), no `ORDER BY` (D11).

- The query is `FTSQuery`: trimmed and NFKC-normalized (Calibre NFKC-normalizes queries;
  document text is never normalized by the tokenizer).
- The raw text is tried as FTS5 syntax first. On a syntax error it is retried once with
  `sanitizedMatchExpression`, an AND of quoted pieces (D10), and the result reports
  `usedSanitizedFallback`. Classification of "syntax error" is by message
  (`CalibreFTSLibrary.isFTSSyntaxMessage`): `fts5:` prefix, `unterminated string`,
  `no such column`, `malformed MATCH expression`, all result code 1.
- Error mapping (`mapError`): `SQLITE_INTERRUPT` or a stale token gives `.cancelled`;
  `SQLITE_BUSY` and `SQLITE_LOCKED` give `.busy`; extended codes are reduced to their
  primary code first; anything else is `.sqlite(code:message:)`, read-only failures
  included (D21).
- `stemmed: true` queries throw `.tokenizerUnavailable` until stemming exists (M6).

Phase 2, `snippets(bookID:query:token:snippetTokens:)`: one query per book, `snippet()`
with `\u{1D}` as both highlight markers and the token count clamped to 1...64, ordered by
`rank`. Native mode only. Built and tested, wired to no view yet. `FTSSnippet.textRowID` is
`books_text.id` and is session-local (D22).

`indexProgress()` counts `books_text` and `dirtied_formats`. Ambrosia's own derivation:
Calibre keeps its counters in memory.

## Cancellation (Invariant 24)

`beginSearch()` bumps a generation in `SearchControl` and calls `sqlite3_interrupt` on the
current handle. The actor re-checks the token at entry, every 256 rows, and at the end of
each statement. `LibrarySession.resolveFulltextIDs` wraps the call in
`withTaskCancellationHandler`, so cancelling the calling `Task` cancels the search. A
search that goes stale mid-flight is superseded by whoever called `beginSearch()` next, so
two overlapping `fulltext:` resolutions cancel each other; the later one wins.
SQLite documents that an interrupt with no running statement has no effect, which is what
keeps a late `begin()` from aborting the next search; that is documented behavior, not
something this repo has observed.

## Working alongside Calibre (D14, D19 to D21, D24)

- Connection: read-only, `busyTimeout = 10` s (Calibre uses 10 s). Calibre sets no
  `journal_mode`, so the mode is whatever the file already has; under a rollback journal
  a committing writer waits for readers (G9 measures this on a real library).
- Lock discipline: every statement is drained into an array and reset before anything
  else happens, with no `await` in between; no `BEGIN`, ever.
- File replacement: Calibre's re-index deletes `full-text-search.db` and recreates it.
  Every call stats the path and compares `(st_dev, st_ino)` with the value taken before
  the connection was opened; a mismatch reopens (full open sequence). A missing file
  throws `.sqlite` and is not cached. The index stamp is `(device, inode, data_version)`.
- Hot journals: Ambrosia never writes and never recovers a journal. A failure from one
  surfaces as `.sqlite` in `LibrarySession.lastFulltextError`. Opening the library in
  Calibre once clears it. The exact code is recorded by G9 (not run).
- Network or cloud-synced library folders: SQLite locking is unreliable there. Documented
  limitation, no code (D24).
- Vacuum: Calibre's `VACUUM fts_db` is user-initiated only (found by reading its source,
  not an exhaustive proof) and holds an exclusive lock while it runs; expect `.busy`.
- Disabling FTS in Calibre leaves the file in place, so a present file can be stale.

## Id-set binding (D18)

`SQLIDList` binds a whole id set as one JSON array: `col IN (SELECT value FROM
json_each(?))`. Converted sites: `CalibreLibrarySearch.whereClause`, both `restrictIDs`
sites, `bulkTitles`, `bulkCustomColumnInts`, `bookCount(ids:)` (all in `CalibreLibrary`),
and `AmbrosiaMetaDB.expandedSeriesMemberIDs` and `qualifyingSeriesNames`, which receive
the whole matched set. Audited and left alone: the `chunk` loops in `CalibreLibrary`
(900 per chunk) and the `AmbrosiaMetaDB` fetchers behind the id caches
(`fetchAO3Metadata`, `fetchAO3ExtractionDiagnostics`, `fetchSeriesEntries`,
`fetchSingletonNonLeadingSeriesEntries`), which are called with page-sized id lists
by their callers as far as this change could tell; the callers were not traced
exhaustively. Gate G7 decides the mechanism: if Apple's SQLite lacks `json_each`, change
only `SQLIDList.swift`.

## What exists

| Piece | Path |
| --- | --- |
| C tokenizer (ICU C API, no SQLite dependency) | `Database/CalibreFTS/C/calibre_tokenizer.c` and `.h` |
| Hand-written ICU C API declarations (the SDK has no `unicode/` headers) | `Database/CalibreFTS/C/ambrosia_icu_decls.h` |
| Swift face of the tokenizer | `Database/CalibreFTS/CalibreTokenizer.swift` |
| FTS5 registration (`SELECT fts5(?1)` pointer pattern) | `Database/CalibreFTS/C/calibre_fts5_register.c` and `.h` |
| FTS5 struct declarations (used only when the SDK header lacks them) | `Database/CalibreFTS/C/ambrosia_fts5.h` |
| `register(on:)` for a SQLite.swift `Connection` | `Database/CalibreFTS/CalibreTokenizerRegistration.swift` |
| Models: `SearchToken`, `FTSIndexStamp`, `FTSBookSet`, `FTSSnippet`, `FTSIndexProgress`, `FTSSearchError` | `Database/CalibreFTS/FTSModels.swift` |
| `FTSQuery` (pure: normalization, cache key, match expressions) | `Database/CalibreFTS/FTSQuery.swift` |
| `SearchControl` (generation plus interrupt handle) | `Database/CalibreFTS/SearchControl.swift` |
| `FulltextSearching` (test seam used by `LibrarySession`) | `Database/CalibreFTS/FulltextSearching.swift` |
| The actor | `Database/CalibreFTSLibrary.swift` |
| `SQLIDList` | `Database/SQLIDList.swift` |
| Fixture that builds a Calibre-shaped file | `AmbrosiaTests/FTSTestFixture.swift`, `AmbrosiaTests/calibre_fts_schema.sql` |
| Golden-corpus generator (needs Calibre; not run) | `scripts/gen_calibre_tokenizer_golden.py` |

`project.yml` links `libicucore.tbd` and sets `SWIFT_OBJC_BRIDGING_HEADER`. Run
`xcodegen generate` after pulling; the new Swift files and tests are picked up from the
folders automatically.

## Tokenizer behavior (read from Calibre's `sqlite_extension.cpp`)

- Input is decoded to UTF-16 with a byte offset per UTF-16 unit. Invalid bytes are
  dropped by the same DFA decoder Calibre uses, so offsets after a dropped run start at
  the first dropped byte.
- Text is split into script blocks by iterator language (Thai and Lao, Khmer, Myanmar,
  kana, Hangul, Han each get their own; everything else shares the root locale). Each
  block gets an ICU word break iterator.
- A segment is a token only if it holds a letter, digit, currency symbol, other symbol or
  private-use code point. The emitted token is the default case fold of the segment.
- At index time only (flags without QUERY or AUX), when `remove_diacritics` is on, a second
  colocated token is emitted if the diacritic-stripped, folded segment differs.
  Consequence: query `resume` matches documents containing `resume` or `r\u00E9sum\u00E9`;
  query `r\u00E9sum\u00E9` matches only documents containing the accented form.
- Document text is never NFKC-normalized by the tokenizer; Calibre normalizes queries to
  NFKC before binding them (D13 uses the same normalization for cache keys).
- Diacritics are removed with NFD, dropping Mn, Mc and Me, then NFC (D4). This is the rule
  of Calibre's transliterator `NFD; [:M:] Remove; NFC`, implemented without ICU's
  transliterator data.
- Stemming (the `porter` name) is not implemented; the options struct reserves the fields.

## Verification log

Confirmed means observed by running code in the environment named. Nothing below was run
on macOS, against Apple's `libsqlite3` or `libicucore`, or against a real Calibre library.

| Item | Result | Environment |
| --- | --- | --- |
| Calibre's six `test_fts_tokenize` cases reproduced exactly (text, byte offsets, colocated flag) | confirmed | C port built with gcc against ICU 74, Linux |
| Query mode emits no colocated token; Han splits from Latin with correct offsets; empty and whitespace-only input yields no tokens; 1 MB input tokenizes | confirmed | same |
| Registration through `SELECT fts5(?1)` works on a read-only connection, twice in a row, against a file built with Calibre's verbatim `fts_sqlite.sql` and triggers | confirmed | C harness with libsqlite3 3.45.1 (Ubuntu build), Linux |
| Without registration, `MATCH` fails with `no such tokenizer: calibre` | confirmed | same |
| Semantics: `resume` finds both spellings, `r\u00E9sum\u00E9` only the accented one, `cat` does not match `category` or `cats`, `\u4F60` alone matches a document where it is its own token, `\u4F60\u597D` matches `\u4F60\u597D\u4E16\u754C`, OR, `^`, `NEAR`, prefix and implicit AND all behave as FTS5 documents | confirmed | same |
| `EXPLAIN QUERY PLAN` for the phase-1 join shows `SCAN books_fts VIRTUAL TABLE INDEX 0:M1` then a rowid lookup on `books_text` | confirmed | same |
| Error texts for raw queries: `fts5: syntax error near "+"` (for `C++` and bare `AND`), `unterminated string` (for `a "b`), `no such column: foo` (for `foo:bar`), all with result code 1. Quoted punctuation-only phrases (`"--"`, `""`, `"C++"`) return zero rows with no error. A classifier keyed only on the `fts5:` prefix would miss two of these | confirmed | same |
| `fts5.h` upstream (current master) has the struct layout and flag values restated in `ambrosia_fts5.h` | confirmed by reading the header | not Apple's SQLite version |
| Ubuntu's `sqlite3.h` already embeds the FTS5 declarations under `_FTS5_H` | confirmed | whether Apple's SDK header does is unknown |
| SQLite.swift 0.16.0 (read from upstream source at tag 0.16.0): `Result` has `.error(message:code:statement:)` and `.extendedError(message:extendedCode:statement:)`; iterating a `Statement` with `for` uses a `try!`-based `next()`, while `failableNext()` and `step()` throw; `Connection.busyTimeout` is in seconds; `Connection.handle` is public | confirmed by reading | upstream source at tag 0.16.0, the version `THIRD_PARTY.md` lists; the revision resolved in the project was not compared |
| `SELECT ... WHERE id IN (SELECT value FROM json_each(?))` with a 40,000-element JSON array returns exactly the matching rows; empty array returns 0; duplicates and absent ids are handled | confirmed | Python `sqlite3`, SQLite 3.45.1, Linux. Apple's SQLite not tested (G7) |
| The sanitized expressions used by `FTSQuery` (`"C++"`, `"a" """b"`, `"--"`) parse without error; raw `C++` and `a "b` fail with the messages listed above; `^one`, `NEAR(one four)`, `moose OR one` and bare multi-word AND behave as described | confirmed | same SQLite, stock `unicode61` tokenizer, not the `calibre` tokenizer |
| Swift sources and XCTest files (wrapper, fixture, `FTSQuery`, `SearchControl`, `SQLIDList`, the actor, session changes, all new tests) compile and pass | NOT confirmed | no Swift toolchain was available; the only checks were brace and parenthesis balance and reading the SQLite.swift sources |
| `xcodebuild` build for `arch=x86_64` with the C sources (D25) | NOT run | |
| `xcodegen generate` accepts `sdk: libicucore.tbd` and the bridging header setting | NOT confirmed | |
| G1 Apple SQLite has FTS5 | NOT confirmed | |
| G2 ICU C headers in the macOS SDK | NOT available: Xcode reported `'unicode/ubrk.h' file not found` when compiling `calibre_tokenizer.c` | owner's Xcode build. Outcome pre-decided by the plan: prototypes and constants are declared in `ambrosia_icu_decls.h` |
| G2 ICU symbols exported unsuffixed by `libicucore.tbd` (`ubrk_open`, `u_strFoldCase`, `unorm2_normalize`, `uscript_getScript`, ...) | NOT confirmed | a link error naming one of these functions in the next build is the signal. `ambrosia_icu_decls.h` constants were written from ICU's public headers by memory of their values, not checked against a header in the sandbox (`syntax-only` gcc compile of the C file passes) |
| G3 `fts5.h` shipped, `fts5(?)` pointer lookup | NOT confirmed | |
| G4 stub tokenizer makes a real `full-text-search.db` queryable | NOT confirmed | needs an owner library copy |
| G6 golden corpus against Calibre's ICU | NOT run | needs `calibre-debug` to generate the JSON |
| G5 `data_version` changes on a read-only connection | NOT run | test exists (`testDataVersionChangesWhenAnotherConnectionCommits`), needs macOS |
| G7 Apple SQLite variable limit, `json_each`, temp tables on a read-only connection | NOT run | needs macOS; `SQLIDList` is the single seam if `json_each` is missing |
| G8 Apple's ICU and Unicode versions versus Calibre's 78.1 | NOT run | needs macOS |
| G9 to G13 | NOT run | need macOS and the owner's library |
| M7 benchmark numbers | NOT run | `CalibreFTSBenchmarkTests` is written and skipped without `AMBROSIA_FTS_BENCH_LIBRARY`; the 400 ms decision rule (D16) is undecided |
