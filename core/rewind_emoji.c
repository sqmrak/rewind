#include "rewind_emoji.h"
#include <string.h>

#define WINDOW_MAX 16u

static int compare(const uint32_t *points, size_t count, const rewind_emoji_entry *entry) {
    const uint32_t *other = rewind_emoji_points + entry->offset;
    size_t i, n = count < entry->length ? count : entry->length;
    for (i = 0; i < n; ++i) {
        if (points[i] != other[i]) return points[i] < other[i] ? -1 : 1;
    }
    if (count == entry->length) return 0;
    return count < entry->length ? -1 : 1;
}

int rewind_emoji_find(const uint32_t *points, size_t count, size_t *index) {
    size_t low = 0, high = rewind_emoji_entry_count;
    if (!points || count == 0 || count > rewind_emoji_longest) return 0;
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        int order = compare(points, count, &rewind_emoji_entries[mid]);
        if (order == 0) {
            if (index) *index = mid;
            return 1;
        }
        if (order < 0) high = mid;
        else low = mid + 1;
    }
    return 0;
}

static int starts_emoji(uint32_t point) {
    size_t low = 0, high = rewind_emoji_first_count;
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        if (rewind_emoji_first_points[mid] == point) return 1;
        if (point < rewind_emoji_first_points[mid]) high = mid;
        else low = mid + 1;
    }
    return 0;
}

/* one code point and the UTF-16 units it takes; a lone surrogate is passed over as itself */
static uint32_t next_point(const uint16_t *text, size_t at, size_t length, size_t *units) {
    uint16_t head = text[at];
    *units = 1;
    if (head >= 0xD800u && head < 0xDC00u && at + 1 < length && text[at + 1] >= 0xDC00u && text[at + 1] < 0xE000u) {
        *units = 2;
        return 0x10000u + (((uint32_t)head - 0xD800u) << 10) + ((uint32_t)text[at + 1] - 0xDC00u);
    }
    return head;
}

/* the status rules that keep ordinary text out: a sender who skipped the emoji selector on a text style sign keeps
   a sign */
static int acceptable(const rewind_emoji_entry *entry) {
    uint32_t first = rewind_emoji_points[entry->offset];
    if (entry->status != REWIND_EMOJI_STATUS_BARE || entry->length != 1) return 1;
    return first >= 0x80u && first != 0xA9u && first != 0xAEu && first != 0x2122u;
}

size_t rewind_emoji_scan(const uint16_t *text, size_t length, rewind_emoji_span *spans, size_t cap) {
    size_t at = 0, found = 0;
    if (!text || !spans) return 0;
    while (at < length && found < cap) {
        uint32_t points[WINDOW_MAX];
        size_t ends[WINDOW_MAX];
        size_t units, count = 0, pos = at, longest = rewind_emoji_longest < WINDOW_MAX ? rewind_emoji_longest : WINDOW_MAX, k;
        uint32_t first = next_point(text, at, length, &units);
        if (!starts_emoji(first)) {
            at += units;
            continue;
        }
        while (count < longest && pos < length) {
            size_t step;
            points[count] = next_point(text, pos, length, &step);
            pos += step;
            ends[count++] = pos;
        }
        for (k = count; k >= 1; --k) {
            size_t index;
            if (rewind_emoji_find(points, k, &index) && acceptable(&rewind_emoji_entries[index])) {
                spans[found].start = at;
                spans[found].length = ends[k - 1] - at;
                spans[found].entry = rewind_emoji_entries[index].canonical;
                ++found;
                at = ends[k - 1];
                break;
            }
        }
        if (k == 0) at += units;
    }
    return found;
}

int rewind_emoji_single(const uint16_t *text, size_t length, size_t *entry) {
    rewind_emoji_span spans[2];
    if (entry) *entry = 0;
    if (!text || !length || !entry || length > 2 * rewind_emoji_longest) return 0;
    if (rewind_emoji_scan(text, length, spans, 2) != 1 || spans[0].start || spans[0].length != length) return 0;
    *entry = spans[0].entry;
    return 1;
}

size_t rewind_emoji_encode(size_t entry, uint16_t *out, size_t cap) {
    const rewind_emoji_entry *e;
    size_t i, n = 0;
    if (!out || entry >= rewind_emoji_entry_count) return 0;
    e = &rewind_emoji_entries[entry];
    for (i = 0; i < e->length; ++i) {
        uint32_t point = rewind_emoji_points[e->offset + i];
        if (point >= 0x10000u) {
            if (n + 2 > cap) return 0;
            point -= 0x10000u;
            out[n++] = (uint16_t)(0xD800u + (point >> 10));
            out[n++] = (uint16_t)(0xDC00u + (point & 0x3FFu));
        } else {
            if (n + 1 > cap) return 0;
            out[n++] = (uint16_t)point;
        }
    }
    return n;
}

int rewind_emoji_alpha_bounds(const uint8_t *pixels, size_t capacity, size_t width, size_t height,
                              size_t stride, size_t bounds[4]) {
    size_t left = width, top = height, right = 0, bottom = 0;
    if (!bounds) return 0;
    memset(bounds, 0, 4 * sizeof(*bounds));
    if (!pixels || !width || !height || width > 512 || height > 512 || stride < width * 4 ||
        stride > SIZE_MAX / height || capacity < stride * height) return 0;
    for (size_t y = 0; y < height; ++y) {
        for (size_t x = 0; x < width; ++x) {
            if (pixels[y * stride + x * 4 + 3] < 16) continue;
            if (x < left) left = x;
            if (y < top) top = y;
            if (x + 1 > right) right = x + 1;
            if (y + 1 > bottom) bottom = y + 1;
        }
    }
    if (left >= right || top >= bottom) return 0;
    bounds[0] = left; bounds[1] = top; bounds[2] = right - left; bounds[3] = bottom - top;
    return 1;
}
