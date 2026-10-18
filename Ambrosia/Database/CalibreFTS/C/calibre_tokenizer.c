/* SPDX-License-Identifier: GPL-3.0-only */
/*
 * Derived from calibre src/calibre/db/sqlite_extension.cpp, Copyright (C) 2021 Kovid Goyal, GPL v3.
 *
 * Behavior ported from the C++ Tokenizer class: UTF-8 to UTF-16 with a per-unit byte
 * offset map, script blocks keyed by break-iterator language, ICU word breaking per
 * block, token filtering, default case folding, and (at index time) a colocated
 * diacritic-stripped token.
 *
 * Differences from the C++ source, all intentional:
 *  - the ICU C API is used instead of the C++ API;
 *  - the diacritic remover is NFD, drop general categories Mn/Mc/Me, NFC, which is the
 *    rule of calibre's transliterator "NFD; [:M:] Remove; NFC", without utrans data;
 *  - stemming is not implemented here yet.
 */
#include "calibre_tokenizer.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* The macOS SDK has no unicode/ headers (G2); the ICU C API subset used here is
 * declared by hand and resolved from libicucore at link time. */
#include "ambrosia_icu_decls.h"

/* UTF-8 decode taken from https://bjoern.hoehrmann.de/utf-8/decoder/dfa/ via calibre. */
static const uint8_t ct_utf8_data[] = {
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 00..1f
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 20..3f
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 40..5f
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 60..7f
    1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 80..9f
    7,   7,   7,   7,   7,   7,   7,   7,   7,   7,   7,   7,   7,   7,   7,   7,   7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // a0..bf
    8,   8,   2,   2,   2,   2,   2,   2,   2,   2,   2,   2,   2,   2,   2,   2,   2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // c0..df
    0xa, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x4, 0x3, 0x3,                                                 // e0..ef
    0xb, 0x6, 0x6, 0x6, 0x5, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8,                                                 // f0..ff
    0x0, 0x1, 0x2, 0x3, 0x5, 0x8, 0x7, 0x1, 0x1, 0x1, 0x4, 0x6, 0x1, 0x1, 0x1, 0x1,                                                 // s0..s0
    1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1, 0, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, // s1..s2
    1,   2,   1,   1,   1,   1,   1,   2,   1,   2,   1,   1,   1,   1,   1,   1,   1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, // s3..s4
    1,   2,   1,   1,   1,   1,   1,   1,   1,   2,   1,   1,   1,   1,   1,   1,   1, 1, 1, 1, 1, 1, 1, 3, 1, 3, 1, 1, 1, 1, 1, 1, // s5..s6
    1,   3,   1,   1,   1,   1,   1,   3,   1,   3,   1,   1,   1,   1,   1,   1,   1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // s7..s8
};

enum { CT_UTF8_ACCEPT = 0, CT_UTF8_REJECT = 1 };

static uint32_t ct_decode_utf8(uint32_t *state, uint32_t *codep, uint8_t byte) {
    uint32_t type = ct_utf8_data[byte];
    *codep = (*state != CT_UTF8_ACCEPT) ? (byte & 0x3fu) | (*codep << 6) : (0xffu >> type) & (byte);
    *state = ct_utf8_data[256 + *state * 16 + type];
    return *state;
}

#define CT_MAX_ITERATORS 8
#define CT_LANG_MAX 16

typedef struct {
    char language[CT_LANG_MAX];
    UBreakIterator *iterator;
} ct_iterator_slot;

struct calibre_tokenizer {
    int remove_diacritics;
    int stem_words;
    char stem_language[16];

    const UNormalizer2 *nfd;
    const UNormalizer2 *nfc;

    UChar *u16;
    int32_t u16_cap;
    int32_t u16_len;
    int32_t *byte_off;
    int32_t byte_off_cap;

    ct_iterator_slot iterators[CT_MAX_ITERATORS];
    int n_iterators;

    UChar *fold_buf;     /* folded original segment, kept while the colocated token is built */
    int32_t fold_cap;
    UChar *scratch1;
    int32_t scratch1_cap;
    UChar *scratch2;
    int32_t scratch2_cap;
    char *utf8_buf;
    int32_t utf8_cap;

    calibre_token_cb cb;
    void *cb_ctx;
};

typedef struct {
    const char *language;
    UScriptCode script;
} ct_iter_desc;

/* ---- buffers ---- */

static int ct_grow_u16(UChar **buf, int32_t *cap, int32_t need) {
    if (need <= *cap) return 1;
    int32_t ncap = *cap * 2;
    if (ncap < need) ncap = need;
    if (ncap < 64) ncap = 64;
    UChar *p = (UChar *)realloc(*buf, (size_t)ncap * sizeof(UChar));
    if (!p) return 0;
    *buf = p;
    *cap = ncap;
    return 1;
}

/* ---- options ---- */

void calibre_tokenizer_options_parse(calibre_tokenizer_options *opts, const char **args, int nargs) {
    opts->remove_diacritics = 1;
    opts->stem_words = 0;
    strncpy(opts->stem_language, "en", sizeof(opts->stem_language) - 1);
    opts->stem_language[sizeof(opts->stem_language) - 1] = 0;
    for (int i = 0; i < nargs; i++) {
        if (!args[i]) continue;
        if (strcmp(args[i], "remove_diacritics") == 0) {
            i++;
            if (i < nargs && args[i] && strcmp(args[i], "0") == 0) opts->remove_diacritics = 0;
        } else if (strcmp(args[i], "stem_words") == 0) {
            i++;
            if (i < nargs && args[i] && strcmp(args[i], "0") == 0) opts->stem_words = 0;
            else opts->stem_words = 1;
        }
    }
}

/* ---- lifecycle ---- */

calibre_tokenizer *calibre_tokenizer_new(const calibre_tokenizer_options *opts) {
    calibre_tokenizer *t = (calibre_tokenizer *)calloc(1, sizeof(*t));
    if (!t) return NULL;
    t->remove_diacritics = opts ? opts->remove_diacritics : 1;
    t->stem_words = opts ? opts->stem_words : 0;
    if (opts) {
        strncpy(t->stem_language, opts->stem_language, sizeof(t->stem_language) - 1);
    } else {
        strcpy(t->stem_language, "en");
    }
    if (t->remove_diacritics) {
        UErrorCode e = U_ZERO_ERROR;
        t->nfd = unorm2_getNFDInstance(&e);
        t->nfc = unorm2_getNFCInstance(&e);
        if (U_FAILURE(e) || !t->nfd || !t->nfc) {
            free(t);
            return NULL;
        }
    }
    return t;
}

void calibre_tokenizer_free(calibre_tokenizer *t) {
    if (!t) return;
    for (int i = 0; i < t->n_iterators; i++) {
        if (t->iterators[i].iterator) ubrk_close(t->iterators[i].iterator);
    }
    free(t->u16);
    free(t->byte_off);
    free(t->fold_buf);
    free(t->scratch1);
    free(t->scratch2);
    free(t->utf8_buf);
    free(t);
}

/* ---- UTF-8 to UTF-16 with byte offsets ---- */

/* Mirrors populate_icu_string: on a rejected byte the state resets and, if a multi-byte
 * sequence was in progress, the offending byte is reprocessed. Offsets of later code
 * points therefore start at the first byte of any dropped run. */
static int ct_populate(calibre_tokenizer *t, const char *text, int text_sz) {
    if (!ct_grow_u16(&t->u16, &t->u16_cap, text_sz + 1)) return 0;
    if (t->byte_off_cap < text_sz + 2) {
        int32_t ncap = t->byte_off_cap * 2;
        if (ncap < text_sz + 2) ncap = text_sz + 2;
        int32_t *p = (int32_t *)realloc(t->byte_off, (size_t)ncap * sizeof(int32_t));
        if (!p) return 0;
        t->byte_off = p;
        t->byte_off_cap = ncap;
    }
    uint32_t state = CT_UTF8_ACCEPT, prev = CT_UTF8_ACCEPT, codep = 0;
    int32_t n = 0;
    int pos = 0;
    for (int i = 0; i < text_sz; i++) {
        switch (ct_decode_utf8(&state, &codep, (uint8_t)text[i])) {
            case CT_UTF8_ACCEPT: {
                int32_t before = n;
                if (codep <= 0xFFFF) {
                    t->u16[n++] = (UChar)codep;
                } else {
                    t->u16[n++] = (UChar)U16_LEAD(codep);
                    t->u16[n++] = (UChar)U16_TRAIL(codep);
                }
                for (int32_t x = before; x < n; x++) t->byte_off[x] = pos;
                pos = i + 1;
            } break;
            case CT_UTF8_REJECT:
                state = CT_UTF8_ACCEPT;
                if (prev != CT_UTF8_ACCEPT && i > 0) i--;
                break;
            default: break;
        }
        prev = state;
    }
    t->byte_off[n] = text_sz;
    t->u16_len = n;
    return 1;
}

/* ---- script blocks ---- */

static const char *ct_language_for_script(UScriptCode s) {
    switch (s) {
        case USCRIPT_THAI:
        case USCRIPT_LAO: return "th_TH";
        case USCRIPT_KHMER: return "km_KH";
        case USCRIPT_MYANMAR: return "my_MM";
        case USCRIPT_HIRAGANA:
        case USCRIPT_KATAKANA: return "ja_JP";
        case USCRIPT_HANGUL: return "ko_KR";
        case USCRIPT_HAN:
        case USCRIPT_SIMPLIFIED_HAN:
        case USCRIPT_TRADITIONAL_HAN:
        case USCRIPT_HAN_WITH_BOPOMOFO: return "zh";
        default: return "";
    }
}

static int ct_at_script_boundary(ct_iter_desc *cur, UChar32 cp) {
    UErrorCode err = U_ZERO_ERROR;
    UScriptCode s = uscript_getScript(cp, &err);
    if (s == USCRIPT_COMMON || s == USCRIPT_INVALID_CODE || s == USCRIPT_INHERITED || cur->script == s) return 0;
    const char *lang = ct_language_for_script(s);
    if (strcmp(cur->language, lang) == 0) return 0;
    cur->script = s;
    cur->language = lang;
    return 1;
}

static UBreakIterator *ct_iterator_for(calibre_tokenizer *t, const char *lang) {
    for (int i = 0; i < t->n_iterators; i++) {
        if (strcmp(t->iterators[i].language, lang) == 0) return t->iterators[i].iterator;
    }
    if (t->n_iterators >= CT_MAX_ITERATORS || strlen(lang) >= CT_LANG_MAX) return NULL;
    UErrorCode status = U_ZERO_ERROR;
    UBreakIterator *it = ubrk_open(UBRK_WORD, lang, NULL, 0, &status);
    if (U_FAILURE(status) || !it) {
        if (it) ubrk_close(it);
        status = U_ZERO_ERROR;
        it = ubrk_open(UBRK_WORD, NULL, NULL, 0, &status);
        if (U_FAILURE(status)) {
            if (it) ubrk_close(it);
            return NULL;
        }
    }
    ct_iterator_slot *slot = &t->iterators[t->n_iterators++];
    strcpy(slot->language, lang);
    slot->iterator = it;
    return it;
}

/* ---- token helpers ---- */

static int ct_is_token_char(UChar32 ch) {
    switch (u_charType(ch)) {
        case U_UPPERCASE_LETTER:
        case U_LOWERCASE_LETTER:
        case U_TITLECASE_LETTER:
        case U_MODIFIER_LETTER:
        case U_OTHER_LETTER:
        case U_DECIMAL_DIGIT_NUMBER:
        case U_LETTER_NUMBER:
        case U_OTHER_NUMBER:
        case U_CURRENCY_SYMBOL:
        case U_OTHER_SYMBOL:
        case U_PRIVATE_USE_CHAR: return 1;
        default: return 0;
    }
}

static int ct_has_token_char(const UChar *s, int32_t start, int32_t end) {
    int32_t i = start;
    while (i < end) {
        UChar32 c;
        U16_NEXT(s, i, end, c);
        if (ct_is_token_char(c)) return 1;
    }
    return 0;
}

/* Default case folding into *buf. Returns the length, or -1 on failure. */
static int32_t ct_fold(UChar **buf, int32_t *cap, const UChar *src, int32_t len) {
    UErrorCode e = U_ZERO_ERROR;
    int32_t n = u_strFoldCase(*buf, *cap, src, len, U_FOLD_CASE_DEFAULT, &e);
    if (e == U_BUFFER_OVERFLOW_ERROR) {
        if (!ct_grow_u16(buf, cap, n + 1)) return -1;
        e = U_ZERO_ERROR;
        n = u_strFoldCase(*buf, *cap, src, len, U_FOLD_CASE_DEFAULT, &e);
    }
    return U_FAILURE(e) ? -1 : n;
}

static int32_t ct_normalize(const UNormalizer2 *norm, UChar **buf, int32_t *cap, const UChar *src, int32_t len) {
    UErrorCode e = U_ZERO_ERROR;
    int32_t n = unorm2_normalize(norm, src, len, *buf, *cap, &e);
    if (e == U_BUFFER_OVERFLOW_ERROR) {
        if (!ct_grow_u16(buf, cap, n + 1)) return -1;
        e = U_ZERO_ERROR;
        n = unorm2_normalize(norm, src, len, *buf, *cap, &e);
    }
    return U_FAILURE(e) ? -1 : n;
}

static int ct_send(calibre_tokenizer *t, const UChar *s, int32_t len, int32_t start_unit, int32_t end_unit, int flags) {
    if (t->utf8_cap < 3 * len + 1) {
        int32_t ncap = 3 * len + 1;
        if (ncap < 128) ncap = 128;
        char *p = (char *)realloc(t->utf8_buf, (size_t)ncap);
        if (!p) return CALIBRE_TOKENIZER_NOMEM;
        t->utf8_buf = p;
        t->utf8_cap = ncap;
    }
    UErrorCode e = U_ZERO_ERROR;
    int32_t out = 0;
    u_strToUTF8(t->utf8_buf, t->utf8_cap, &out, s, len, &e);
    if (U_FAILURE(e)) return CALIBRE_TOKENIZER_ERROR;
    return t->cb(t->cb_ctx, flags, t->utf8_buf, out, t->byte_off[start_unit], t->byte_off[end_unit]);
}

/* Emits the folded token for [start, end) and, when indexing, the colocated token built
 * from the diacritic-stripped original if it differs. */
static int ct_emit_segment(calibre_tokenizer *t, int32_t start, int32_t end, int for_query_or_aux) {
    const UChar *seg = t->u16 + start;
    int32_t seg_len = end - start;
    int32_t flen = ct_fold(&t->fold_buf, &t->fold_cap, seg, seg_len);
    if (flen < 0) return CALIBRE_TOKENIZER_NOMEM;
    int rc = ct_send(t, t->fold_buf, flen, start, end, 0);
    if (rc != 0) return rc;
    if (for_query_or_aux || !t->remove_diacritics) return 0;

    int32_t n = ct_normalize(t->nfd, &t->scratch1, &t->scratch1_cap, seg, seg_len);
    if (n < 0) return CALIBRE_TOKENIZER_NOMEM;
    int32_t j = 0;
    for (int32_t i = 0; i < n;) {
        UChar32 c;
        U16_NEXT(t->scratch1, i, n, c);
        int8_t cat = u_charType(c);
        if (cat == U_NON_SPACING_MARK || cat == U_COMBINING_SPACING_MARK || cat == U_ENCLOSING_MARK) continue;
        U16_APPEND_UNSAFE(t->scratch1, j, c);
    }
    int32_t m = ct_normalize(t->nfc, &t->scratch2, &t->scratch2_cap, t->scratch1, j);
    if (m < 0) return CALIBRE_TOKENIZER_NOMEM;
    int32_t slen = ct_fold(&t->scratch1, &t->scratch1_cap, t->scratch2, m);
    if (slen < 0) return CALIBRE_TOKENIZER_NOMEM;
    if (slen == flen && memcmp(t->scratch1, t->fold_buf, (size_t)slen * sizeof(UChar)) == 0) return 0;
    return ct_send(t, t->scratch1, slen, start, end, CALIBRE_TOKEN_COLOCATED);
}

static int ct_tokenize_block(calibre_tokenizer *t, int32_t block_start, int32_t block_limit, const char *lang, int for_query_or_aux) {
    UBreakIterator *it = ct_iterator_for(t, lang);
    if (!it) return CALIBRE_TOKENIZER_ERROR;
    UErrorCode status = U_ZERO_ERROR;
    ubrk_setText(it, t->u16 + block_start, block_limit - block_start, &status);
    if (U_FAILURE(status)) return CALIBRE_TOKENIZER_ERROR;
    int32_t tstart = ubrk_first(it) + block_start;
    int32_t tend;
    int rc = 0;
    do {
        int32_t n = ubrk_next(it);
        tend = (n == UBRK_DONE) ? block_limit : n + block_start;
        if (tend > tstart && ct_has_token_char(t->u16, tstart, tend)) {
            rc = ct_emit_segment(t, tstart, tend, for_query_or_aux);
            if (rc != 0) return rc;
        }
        tstart = tend;
    } while (tend < block_limit);
    return rc;
}

int calibre_tokenizer_tokenize(calibre_tokenizer *t, int fts5_flags, const char *utf8, int nbytes,
                               calibre_token_cb cb, void *ctx) {
    if (!t || !cb) return CALIBRE_TOKENIZER_ERROR;
    if (!utf8) nbytes = 0;
    else if (nbytes < 0) nbytes = (int)strlen(utf8);
    t->cb = cb;
    t->cb_ctx = ctx;
    if (!ct_populate(t, utf8 ? utf8 : "", nbytes)) return CALIBRE_TOKENIZER_NOMEM;

    const int for_qa = (fts5_flags & (CALIBRE_TOKENIZE_QUERY | CALIBRE_TOKENIZE_AUX)) != 0;
    ct_iter_desc st = {"", USCRIPT_COMMON};
    const char *block_lang = "";
    int32_t block_start = 0;
    int32_t offset = 0;
    int rc = 0;
    while (offset < t->u16_len) {
        UChar32 ch;
        int32_t next = offset;
        U16_NEXT(t->u16, next, t->u16_len, ch);
        if (ct_at_script_boundary(&st, ch)) {
            if (offset > block_start) {
                rc = ct_tokenize_block(t, block_start, offset, block_lang, for_qa);
                if (rc != 0) return rc;
            }
            block_start = offset;
            block_lang = st.language;
        }
        offset = next;
    }
    if (offset > block_start) rc = ct_tokenize_block(t, block_start, offset, block_lang, for_qa);
    return rc;
}
