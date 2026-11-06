#include "rewind_text_class.h"

#define CP_MAX 0x10FFFFu

rewind_cp_class rewind_cp_class_of(uint32_t cp) {
    if (cp > CP_MAX) return REWIND_CP_PLAIN;
    /* the soft hyphen has no shape and sits inside the Latin-1 range below */
    if (cp == 0x00AD) return REWIND_CP_ATTACH;
    /* controls, ASCII, Latin-1 and the Latin letters, which Inter and every system font draw */
    if (cp <= 0x024F) return REWIND_CP_PLAIN;
    /* the combining diacritics Inter has, and the Cyrillic block */
    if (cp >= 0x0300 && cp <= 0x036F) return REWIND_CP_PLAIN;
    if (cp >= 0x0400 && cp <= 0x04FF) return REWIND_CP_PLAIN;
    /* general punctuation: spaces and the usual marks are plain, the formatting characters have no shape and join the run */
    if (cp >= 0x2000 && cp <= 0x200A) return REWIND_CP_PLAIN;
    if (cp >= 0x200B && cp <= 0x200F) return REWIND_CP_ATTACH;
    if (cp >= 0x2010 && cp <= 0x2027) return REWIND_CP_PLAIN;
    if (cp >= 0x2028 && cp <= 0x202E) return REWIND_CP_ATTACH;
    if (cp >= 0x202F && cp <= 0x205F) return REWIND_CP_PLAIN;
    if (cp >= 0x2060 && cp <= 0x206F) return REWIND_CP_ATTACH;
    /* variation selectors, the byte order mark and the tag characters */
    if (cp >= 0xFE00 && cp <= 0xFE0F) return REWIND_CP_ATTACH;
    if (cp == 0xFEFF) return REWIND_CP_ATTACH;
    if (cp >= 0xE0000 && cp <= 0xE007F) return REWIND_CP_ATTACH;
    if (cp >= 0xE0100 && cp <= 0xE01EF) return REWIND_CP_ATTACH;
    /* the object replacement character stands for an emoji picture the layout draws itself */
    if (cp == 0xFFFC) return REWIND_CP_PLAIN;
    /* a lone surrogate has no glyph in any font */
    if (cp >= 0xD800 && cp <= 0xDFFF) return REWIND_CP_PLAIN;
    return REWIND_CP_CHECK;
}

size_t rewind_utf16_next(const uint16_t *units, size_t len, size_t index, uint32_t *cp) {
    uint32_t first;
    if (cp) *cp = 0;
    if (!units || index >= len) return 0;
    first = units[index];
    if (first >= 0xD800 && first <= 0xDBFF && index + 1 < len) {
        uint32_t second = units[index + 1];
        if (second >= 0xDC00 && second <= 0xDFFF) {
            if (cp) *cp = 0x10000u + ((first - 0xD800u) << 10) + (second - 0xDC00u);
            return 2;
        }
    }
    if (cp) *cp = first;
    return 1;
}
