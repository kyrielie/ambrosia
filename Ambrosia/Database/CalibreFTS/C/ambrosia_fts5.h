/* SPDX-License-Identifier: GPL-3.0-only */
/*
 * Declarations of the FTS5 extension API, copied from the public SQLite header
 * ext/fts5/fts5.h. Only the leading members of fts5_api that this project uses
 * are declared; the layout up to and including xCreateFunction is identical in
 * iVersion 2 and 3. xCreateFunction's function pointer type is simplified to
 * void * because it is never called here and only has to keep the layout.
 *
 * The SDK is not known to ship fts5.h, so the structs are restated. Some sqlite3.h
 * files (Ubuntu's, for one) already embed the same declarations under the include
 * guard _FTS5_H; in that case this header declares nothing and the SDK's copy is
 * used. Include sqlite3.h before this header. This header is internal to the C
 * sources and is not imported into Swift.
 */
#ifndef AMBROSIA_FTS5_H
#define AMBROSIA_FTS5_H

#ifdef __cplusplus
extern "C" {
#endif

#ifndef _FTS5_H

typedef struct Fts5Tokenizer Fts5Tokenizer;
typedef struct fts5_tokenizer fts5_tokenizer;

struct fts5_tokenizer {
    int (*xCreate)(void *, const char **azArg, int nArg, Fts5Tokenizer **ppOut);
    void (*xDelete)(Fts5Tokenizer *);
    int (*xTokenize)(Fts5Tokenizer *, void *pCtx, int flags, const char *pText, int nText,
                     int (*xToken)(void *pCtx, int tflags, const char *pToken, int nToken,
                                   int iStart, int iEnd));
};

#define FTS5_TOKENIZE_QUERY    0x0001
#define FTS5_TOKENIZE_PREFIX   0x0002
#define FTS5_TOKENIZE_DOCUMENT 0x0004
#define FTS5_TOKENIZE_AUX      0x0008

#define FTS5_TOKEN_COLOCATED   0x0001

typedef struct fts5_api fts5_api;
struct fts5_api {
    int iVersion; /* must be >= 2 for the members used here */
    int (*xCreateTokenizer)(fts5_api *, const char *zName, void *pUserData,
                            fts5_tokenizer *pTokenizer, void (*xDestroy)(void *));
    int (*xFindTokenizer)(fts5_api *, const char *zName, void **ppUserData,
                          fts5_tokenizer *pTokenizer);
    int (*xCreateFunction)(fts5_api *, const char *zName, void *pUserData, void *xFunction,
                           void (*xDestroy)(void *));
};

#endif /* _FTS5_H */

#ifdef __cplusplus
}
#endif

#endif /* AMBROSIA_FTS5_H */
