/* SPDX-License-Identifier: GPL-3.0-only */
/*
 * Derived from calibre src/calibre/db/sqlite_extension.cpp, Copyright (C) 2021 Kovid Goyal, GPL v3.
 * The fts5_api lookup is SQLite's documented "SELECT fts5(?1)" pointer-passing pattern,
 * the same one calibre uses.
 */
#include "calibre_fts5_register.h"

#include <stddef.h>

#include "ambrosia_fts5.h" /* after sqlite3.h, see header comment */
#include "calibre_tokenizer.h"

_Static_assert(CALIBRE_TOKENIZE_QUERY == FTS5_TOKENIZE_QUERY, "flag mismatch");
_Static_assert(CALIBRE_TOKENIZE_PREFIX == FTS5_TOKENIZE_PREFIX, "flag mismatch");
_Static_assert(CALIBRE_TOKENIZE_DOCUMENT == FTS5_TOKENIZE_DOCUMENT, "flag mismatch");
_Static_assert(CALIBRE_TOKENIZE_AUX == FTS5_TOKENIZE_AUX, "flag mismatch");
_Static_assert(CALIBRE_TOKEN_COLOCATED == FTS5_TOKEN_COLOCATED, "flag mismatch");

static int fts5_api_from_db(sqlite3 *db, fts5_api **ppApi) {
    sqlite3_stmt *stmt = NULL;
    *ppApi = NULL;
    int rc = sqlite3_prepare_v2(db, "SELECT fts5(?1)", -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        sqlite3_bind_pointer(stmt, 1, (void *)ppApi, "fts5_api_ptr", NULL);
        (void)sqlite3_step(stmt);
        rc = sqlite3_finalize(stmt);
    }
    return rc;
}

static int tok_create(void *user_data, const char **azArg, int nArg, Fts5Tokenizer **ppOut) {
    (void)user_data;
    calibre_tokenizer_options opts;
    calibre_tokenizer_options_parse(&opts, azArg, nArg);
    /* NULL covers allocation failure and missing ICU normalization data. */
    calibre_tokenizer *t = calibre_tokenizer_new(&opts);
    if (!t) return SQLITE_NOMEM;
    *ppOut = (Fts5Tokenizer *)t;
    return SQLITE_OK;
}

static void tok_delete(Fts5Tokenizer *p) {
    calibre_tokenizer_free((calibre_tokenizer *)p);
}

static int tok_tokenize(Fts5Tokenizer *p, void *ctx, int flags, const char *text, int nText,
                        int (*xToken)(void *, int, const char *, int, int, int)) {
    return calibre_tokenizer_tokenize((calibre_tokenizer *)p, flags, text, nText, xToken, ctx);
}

int calibre_fts5_register(sqlite3 *db, int stemming_enabled) {
    (void)stemming_enabled;
    fts5_api *api = NULL;
    int rc = fts5_api_from_db(db, &api);
    if (rc != SQLITE_OK) return rc;
    if (api == NULL || api->iVersion < 2) return SQLITE_ERROR;
    fts5_tokenizer tok = {tok_create, tok_delete, tok_tokenize};
    return api->xCreateTokenizer(api, "calibre", (void *)api, &tok, NULL);
}
