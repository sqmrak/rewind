#include "rewind_audio.h"

#include <string.h>

static int read_number(const char **text, uint64_t *out) {
    const char *p = *text;
    uint64_t value = 0;
    if (*p < '0' || *p > '9') return 0;
    do {
        unsigned digit = (unsigned)(*p - '0');
        if (value > (UINT64_MAX - digit) / 10) return 0;
        value = value * 10 + digit;
        ++p;
    } while (*p >= '0' && *p <= '9');
    *text = p;
    *out = value;
    return 1;
}

int rewind_audio_index_range(const char *text, uint64_t *start, uint64_t *end) {
    uint64_t a = 0, b = 0;
    if (start) *start = 0;
    if (end) *end = 0;
    if (!text || !start || !end || !read_number(&text, &a) || *text++ != '-' ||
        !read_number(&text, &b) || *text || b < a) return 0;
    *start = a;
    *end = b;
    return 1;
}

int rewind_audio_video_id(const char *text) {
    size_t i;
    if (!text) return 0;
    for (i = 0; i < 11; ++i) {
        unsigned char c = (unsigned char)text[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-')) return 0;
    }
    return text[11] == 0;
}

int rewind_audio_content_range(const char *text, uint64_t start, uint64_t end,
                                size_t length, uint64_t *total) {
    uint64_t a, b, size;
    if (total) *total = 0;
    if (!text || end < start || end - start == UINT64_MAX || length != end - start + 1 ||
        strncmp(text, "bytes ", 6) != 0) return 0;
    text += 6;
    if (!read_number(&text, &a) || *text++ != '-' || !read_number(&text, &b) ||
        *text++ != '/' || !read_number(&text, &size)) return 0;
    while (*text == ' ' || *text == '\t') ++text;
    if (*text || a != start || b != end || b >= size) return 0;
    if (total) *total = size;
    return 1;
}

int rewind_audio_mp4(const uint8_t *data, size_t length) {
    uint32_t size;
    if (!data || length < 16 || memcmp(data + 4, "ftyp", 4) != 0) return 0;
    size = ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16) |
           ((uint32_t)data[2] << 8) | data[3];
    return size >= 16 && size <= length;
}

int rewind_audio_segment(const uint8_t *data, size_t length) {
    size_t tags = 0;
    if (!data) return 0;
    /* youtube's packed aac starts with an ID3 transport stream timestamp */
    while (length >= 10 && memcmp(data, "ID3", 3) == 0) {
        size_t size;
        if (++tags > 4 || data[3] < 3 || data[3] > 4 ||
            (data[6] | data[7] | data[8] | data[9]) & 0x80) return 0;
        size = 10 + ((size_t)data[6] << 21) + ((size_t)data[7] << 14) +
               ((size_t)data[8] << 7) + data[9];
        if (data[3] == 4 && (data[5] & 0x10)) size += 10;
        if (size > length) return 0;
        data += size;
        length -= size;
    }
    if (length >= 376 && data[0] == 0x47 && data[188] == 0x47) return 1;
    if (length >= 7 && data[0] == 0xff && (data[1] & 0xf6) == 0xf0) return 1;
    return rewind_audio_mp4(data, length);
}

static int copy_uri(const char *text, size_t length, char *out, size_t capacity) {
    size_t i;
    if (!length || length >= capacity) return 0;
    for (i = 0; i < length; ++i)
        if ((unsigned char)text[i] <= 0x20 || text[i] == '"') return 0;
    memcpy(out, text, length);
    out[length] = 0;
    return 1;
}

static int attribute(const char *text, size_t length, const char *name,
                      const char **value, size_t *value_length) {
    size_t pos = 0, name_length = strlen(name);
    while (pos < length) {
        size_t key = pos, key_length, start;
        while (pos < length && text[pos] != '=' && text[pos] != ',') ++pos;
        if (pos == length || text[pos] != '=') return 0;
        key_length = pos++ - key;
        if (pos < length && text[pos] == '"') {
            start = ++pos;
            while (pos < length && text[pos] != '"') ++pos;
            if (pos == length) return 0;
            *value_length = pos - start;
            ++pos;
        } else {
            start = pos;
            while (pos < length && text[pos] != ',') ++pos;
            *value_length = pos - start;
        }
        if (key_length == name_length && memcmp(text + key, name, name_length) == 0) {
            *value = text + start;
            return 1;
        }
        if (pos < length && text[pos++] != ',') return 0;
    }
    return 0;
}

rewind_audio_hls_kind_t rewind_audio_hls(const char *text, size_t length,
                                        char *first, size_t first_capacity,
                                        char *last, size_t last_capacity) {
    size_t pos = 0, segments = 0;
    int audio = 0, ended = 0, duration = 0;
    if (first && first_capacity) first[0] = 0;
    if (last && last_capacity) last[0] = 0;
    if (!text || !first || !first_capacity || !last || !last_capacity || length > 512 * 1024 ||
        length < 7 || memcmp(text, "#EXTM3U", 7) != 0 || memchr(text, 0, length))
        return REWIND_AUDIO_HLS_INVALID;
    while (pos < length) {
        size_t start = pos, len;
        const char *value;
        size_t value_length;
        while (pos < length && text[pos] != '\n') ++pos;
        len = pos - start;
        if (pos < length) ++pos;
        if (len && text[start + len - 1] == '\r') --len;
        if (!len) continue;
        if (start == 0) {
            if (len != 7) return REWIND_AUDIO_HLS_INVALID;
            continue;
        }
        if (len >= 13 && memcmp(text + start, "#EXT-X-MEDIA:", 13) == 0) {
            if (!attribute(text + start + 13, len - 13, "TYPE", &value, &value_length) ||
                value_length != 5 || memcmp(value, "AUDIO", 5) != 0) continue;
            if (!attribute(text + start + 13, len - 13, "URI", &value, &value_length)) continue;
            if (!audio && !copy_uri(value, value_length, first, first_capacity))
                return REWIND_AUDIO_HLS_INVALID;
            audio = 1;
        } else if (len == 14 && memcmp(text + start, "#EXT-X-ENDLIST", 14) == 0) {
            ended = 1;
        } else if (len >= 8 && memcmp(text + start, "#EXTINF:", 8) == 0) {
            duration = 1;
        } else if ((len >= 11 && memcmp(text + start, "#EXT-X-MAP:", 11) == 0) ||
                   (len >= 12 && memcmp(text + start, "#EXT-X-KEY:", 11) == 0) ||
                   (len >= 17 && memcmp(text + start, "#EXT-X-BYTERANGE:", 17) == 0)) {
            /* ios 5 needs ordinary aac or transport stream segments */
            return REWIND_AUDIO_HLS_INVALID;
        } else if (text[start] != '#') {
            if (audio) continue;
            if (!duration || ended || ++segments > 10000 ||
                (!first[0] && !copy_uri(text + start, len, first, first_capacity)) ||
                !copy_uri(text + start, len, last, last_capacity))
                return REWIND_AUDIO_HLS_INVALID;
            duration = 0;
        }
    }
    if (audio) return REWIND_AUDIO_HLS_MASTER;
    return segments && ended && !duration ? REWIND_AUDIO_HLS_MEDIA : REWIND_AUDIO_HLS_INVALID;
}
