/* SPDX-License-Identifier: GPL-3.0-only */
/*
 * Minimal hand-written declarations for the subset of the ICU C API that
 * calibre_tokenizer.c uses, for linking against Apple's libicucore.
 *
 * Why this exists: the macOS SDK does not ship the ICU public headers
 * (unicode/ubrk.h and friends are not found), but libicucore.tbd does export the
 * functions, unsuffixed. The plan's gate G2 pre-decides this outcome: declare the
 * prototypes and copy the constant values from ICU's public headers.
 *
 * Rules for this file:
 *  - Nothing here may be included in the same translation unit as the real ICU
 *    headers. Only calibre_tokenizer.c includes it, and it includes no unicode/ header.
 *  - Enum values are ICU's public, ABI-stable values (utypes.h, uchar.h, uscript.h,
 *    ubrk.h). They are not guessed from names: if a value is ever in doubt, compare
 *    against the header of a full ICU distribution.
 *  - Function signatures match ICU's C API (ubrk.h, ustring.h, unorm2.h, uscript.h,
 *    uchar.h). Apple builds ICU with renaming disabled, so symbols carry no
 *    version suffix. This is NOT verified from the sandbox; a link error naming one of
 *    the functions below is the signal that it is wrong.
 */
#ifndef AMBROSIA_ICU_DECLS_H
#define AMBROSIA_ICU_DECLS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* utypes.h / umachine.h */
typedef uint16_t UChar;
typedef int32_t UChar32;

typedef enum UErrorCode {
    U_ZERO_ERROR = 0,
    U_ILLEGAL_ARGUMENT_ERROR = 1,
    U_MEMORY_ALLOCATION_ERROR = 7,
    U_BUFFER_OVERFLOW_ERROR = 15
} UErrorCode;

#define U_FAILURE(x) ((x) > U_ZERO_ERROR)

/* ubrk.h */
typedef struct UBreakIterator UBreakIterator;

typedef enum UBreakIteratorType {
    UBRK_CHARACTER = 0,
    UBRK_WORD = 1,
    UBRK_LINE = 2,
    UBRK_SENTENCE = 3
} UBreakIteratorType;

#define UBRK_DONE ((int32_t)-1)

UBreakIterator *ubrk_open(UBreakIteratorType type, const char *locale, const UChar *text,
                          int32_t textLength, UErrorCode *status);
void ubrk_close(UBreakIterator *bi);
void ubrk_setText(UBreakIterator *bi, const UChar *text, int32_t textLength, UErrorCode *status);
int32_t ubrk_first(UBreakIterator *bi);
int32_t ubrk_next(UBreakIterator *bi);

/* uchar.h: general categories, in ICU's UCharCategory order */
typedef enum UCharCategory {
    U_UNASSIGNED = 0,
    U_UPPERCASE_LETTER = 1,
    U_LOWERCASE_LETTER = 2,
    U_TITLECASE_LETTER = 3,
    U_MODIFIER_LETTER = 4,
    U_OTHER_LETTER = 5,
    U_NON_SPACING_MARK = 6,
    U_ENCLOSING_MARK = 7,
    U_COMBINING_SPACING_MARK = 8,
    U_DECIMAL_DIGIT_NUMBER = 9,
    U_LETTER_NUMBER = 10,
    U_OTHER_NUMBER = 11,
    U_SPACE_SEPARATOR = 12,
    U_LINE_SEPARATOR = 13,
    U_PARAGRAPH_SEPARATOR = 14,
    U_CONTROL_CHAR = 15,
    U_FORMAT_CHAR = 16,
    U_PRIVATE_USE_CHAR = 17,
    U_SURROGATE = 18,
    U_DASH_PUNCTUATION = 19,
    U_START_PUNCTUATION = 20,
    U_END_PUNCTUATION = 21,
    U_CONNECTOR_PUNCTUATION = 22,
    U_OTHER_PUNCTUATION = 23,
    U_MATH_SYMBOL = 24,
    U_CURRENCY_SYMBOL = 25,
    U_MODIFIER_SYMBOL = 26,
    U_OTHER_SYMBOL = 27
} UCharCategory;

int8_t u_charType(UChar32 c);

/* uscript.h: only the scripts calibre_tokenizer.c names */
typedef enum UScriptCode {
    USCRIPT_INVALID_CODE = -1,
    USCRIPT_COMMON = 0,
    USCRIPT_INHERITED = 1,
    USCRIPT_HAN = 17,
    USCRIPT_HANGUL = 18,
    USCRIPT_HIRAGANA = 20,
    USCRIPT_KATAKANA = 22,
    USCRIPT_KHMER = 23,
    USCRIPT_LAO = 24,
    USCRIPT_MYANMAR = 28,
    USCRIPT_THAI = 38,
    USCRIPT_SIMPLIFIED_HAN = 73,
    USCRIPT_TRADITIONAL_HAN = 74,
    USCRIPT_HAN_WITH_BOPOMOFO = 172
} UScriptCode;

UScriptCode uscript_getScript(UChar32 codepoint, UErrorCode *err);

/* ustring.h */
#define U_FOLD_CASE_DEFAULT 0

int32_t u_strFoldCase(UChar *dest, int32_t destCapacity, const UChar *src, int32_t srcLength,
                      uint32_t options, UErrorCode *pErrorCode);
char *u_strToUTF8(char *dest, int32_t destCapacity, int32_t *pDestLength, const UChar *src,
                  int32_t srcLength, UErrorCode *pErrorCode);

/* unorm2.h */
typedef struct UNormalizer2 UNormalizer2;

const UNormalizer2 *unorm2_getNFCInstance(UErrorCode *pErrorCode);
const UNormalizer2 *unorm2_getNFDInstance(UErrorCode *pErrorCode);
int32_t unorm2_normalize(const UNormalizer2 *norm2, const UChar *src, int32_t length, UChar *dest,
                         int32_t capacity, UErrorCode *pErrorCode);

/* utf16.h: the macros calibre_tokenizer.c uses (UTF-16 surrogate handling). */
#define U16_IS_LEAD(c) (((c) & 0xfffffc00) == 0xd800)
#define U16_IS_TRAIL(c) (((c) & 0xfffffc00) == 0xdc00)
#define U16_SURROGATE_OFFSET ((0xd800 << 10UL) + 0xdc00 - 0x10000)
#define U16_GET_SUPPLEMENTARY(lead, trail) \
    (((UChar32)(lead) << 10UL) + (UChar32)(trail) - U16_SURROGATE_OFFSET)
#define U16_LEAD(supplementary) ((UChar)(((supplementary) >> 10) + 0xd7c0))
#define U16_TRAIL(supplementary) ((UChar)(((supplementary) & 0x3ff) | 0xdc00))

/* Reads one code point at s[i], advancing i. An unpaired surrogate is returned as is. */
#define U16_NEXT(s, i, length, c)                                         \
    do {                                                                  \
        (c) = (s)[(i)++];                                                 \
        if (U16_IS_LEAD(c)) {                                             \
            uint16_t u16_next_c2_;                                        \
            if ((i) != (length) && U16_IS_TRAIL(u16_next_c2_ = (s)[(i)])) { \
                ++(i);                                                    \
                (c) = U16_GET_SUPPLEMENTARY((c), u16_next_c2_);           \
            }                                                             \
        }                                                                 \
    } while (0)

/* Writes c (assumed valid) at s[i], advancing i by one or two units. */
#define U16_APPEND_UNSAFE(s, i, c)                  \
    do {                                            \
        if ((uint32_t)(c) <= 0xffff) {              \
            (s)[(i)++] = (uint16_t)(c);             \
        } else {                                    \
            (s)[(i)++] = (uint16_t)U16_LEAD(c);     \
            (s)[(i)++] = (uint16_t)U16_TRAIL(c);    \
        }                                           \
    } while (0)

#ifdef __cplusplus
}
#endif

#endif /* AMBROSIA_ICU_DECLS_H */
