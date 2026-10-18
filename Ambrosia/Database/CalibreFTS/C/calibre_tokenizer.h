/* SPDX-License-Identifier: GPL-3.0-only */
/*
 * Port of the tokenizer in calibre src/calibre/db/sqlite_extension.cpp, using the
 * ICU C API. No SQLite dependency, so it can be tested without FTS5.
 *
 * Derived from calibre src/calibre/db/sqlite_extension.cpp, Copyright (C) 2021 Kovid Goyal, GPL v3.
 */
#ifndef CALIBRE_TOKENIZER_H
#define CALIBRE_TOKENIZER_H

#ifdef __cplusplus
extern "C" {
#endif

/* Values mirror FTS5_TOKENIZE_* and FTS5_TOKEN_COLOCATED in SQLite's fts5.h.
 * calibre_fts5_register.c asserts the equality at compile time. */
#define CALIBRE_TOKENIZE_QUERY    0x0001
#define CALIBRE_TOKENIZE_PREFIX   0x0002
#define CALIBRE_TOKENIZE_DOCUMENT 0x0004
#define CALIBRE_TOKENIZE_AUX      0x0008
#define CALIBRE_TOKEN_COLOCATED   0x0001

/* Return codes, numerically equal to SQLITE_ERROR and SQLITE_NOMEM. */
#define CALIBRE_TOKENIZER_ERROR 1
#define CALIBRE_TOKENIZER_NOMEM 7

typedef struct calibre_tokenizer calibre_tokenizer;

typedef struct {
    int remove_diacritics;   /* default 1 */
    int stem_words;          /* reserved; ignored until stemming lands (plan M6) */
    char stem_language[16];  /* reserved; "en" */
} calibre_tokenizer_options;

/* Same shape as FTS5's xToken callback. A nonzero return stops tokenization and
 * is returned from calibre_tokenizer_tokenize. */
typedef int (*calibre_token_cb)(void *ctx, int flags, const char *token, int token_len,
                                int start_byte, int end_byte);

/* Fills opts with defaults, then applies FTS5 tokenizer arguments the way calibre does:
 * "remove_diacritics" followed by "0" disables it and any other value enables it;
 * "stem_words" followed by "0" disables it and any other value enables it. Unknown
 * arguments (for example the leading "calibre" in "porter calibre ...") are skipped. */
void calibre_tokenizer_options_parse(calibre_tokenizer_options *opts, const char **args, int nargs);

/* Returns NULL on allocation failure, or when remove_diacritics is requested and ICU
 * normalization data is unavailable. */
calibre_tokenizer *calibre_tokenizer_new(const calibre_tokenizer_options *opts);
void calibre_tokenizer_free(calibre_tokenizer *t);

/* Tokenizes utf8 (nbytes bytes; a negative value means NUL-terminated). Returns 0 on
 * success, a nonzero callback return value, or CALIBRE_TOKENIZER_ERROR/NOMEM. */
int calibre_tokenizer_tokenize(calibre_tokenizer *t, int fts5_flags, const char *utf8, int nbytes,
                               calibre_token_cb cb, void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* CALIBRE_TOKENIZER_H */
