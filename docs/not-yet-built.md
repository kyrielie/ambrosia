# Not yet built

Scope: tracked, intentional gaps — features known to be absent, not bugs.
See `CLAUDE.md` for which doc to update when one of these ships.

---

- Ranking UI and ELO matchup workflow.
- AO3 login, kudos, and AO3 bookmark posting.
- Saved searches.
- Favourite authors.
- Saved quotes.
- Standalone mode without Calibre.
- FTS results panel with snippets and reader jump (needs a pure hit locator first; the snippet API exists in `CalibreFTSLibrary.snippets`, see `calibre-fts.md`).
- Progressive FTS grid updates (build only if the benchmark in `CalibreFTSBenchmarkTests` shows warm p95 above 400 ms on a real library).
- Index-completeness warning in the UI (`CalibreFTSLibrary.indexProgress()` exists; nothing displays it).
- Stemmed index (`books_fts_stemmed`) support.
- Music integration.

---

