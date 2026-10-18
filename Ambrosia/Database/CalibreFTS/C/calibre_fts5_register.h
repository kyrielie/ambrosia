/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef CALIBRE_FTS5_REGISTER_H
#define CALIBRE_FTS5_REGISTER_H

#include <sqlite3.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Registers the FTS5 tokenizer "calibre" on db. Must run before any statement that
 * touches a table declared with that tokenizer. Registering twice is allowed; the
 * newest registration wins. stemming_enabled is ignored until stemming lands (plan M6).
 * Returns SQLITE_OK, SQLITE_ERROR when the FTS5 API is missing or too old, or the
 * error code of the underlying call. */
int calibre_fts5_register(sqlite3 *db, int stemming_enabled);

#ifdef __cplusplus
}
#endif

#endif /* CALIBRE_FTS5_REGISTER_H */
