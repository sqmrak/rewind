#include "rewind_ump.h"

#include <string.h>

int rewind_ump_read_varint(const uint8_t *buf, size_t len, size_t *pos, uint64_t *out) {
    size_t at = *pos;
    uint8_t first;
    size_t size, i, shift;
    uint64_t value;

    if (at >= len) return 0;
    first = buf[at];

    if ((first & 0x80) == 0x00) {
        size = 1;
        value = first;
    } else if ((first & 0xC0) == 0x80) {
        size = 2;
        value = (uint64_t)(first & 0x3F);
    } else if ((first & 0xE0) == 0xC0) {
        size = 3;
        value = (uint64_t)(first & 0x1F);
    } else if ((first & 0xF0) == 0xE0) {
        size = 4;
        value = (uint64_t)(first & 0x0F);
    } else if (first == 0xF0) {
        size = 5;
        value = 0;
    } else {
        return 0; /* all five top bits set: reserved, not a valid prefix */
    }

    if (at + size > len) return 0;

    /* the first byte's own bits (when it has any) sit at the bottom; each
       further byte is a full 8 bits, placed above whatever came before */
    shift = (size == 5) ? 0 : (8 - size);
    for (i = 1; i < size; ++i) {
        value |= ((uint64_t)buf[at + i]) << shift;
        shift += 8;
    }

    *pos = at + size;
    *out = value;
    return 1;
}

size_t rewind_ump_parse(const uint8_t *buf, size_t len,
                        void (*on_part)(const rewind_ump_part_t *part, void *ctx), void *ctx) {
    size_t pos = 0;

    for (;;) {
        size_t start = pos;
        uint64_t type = 0, size = 0;
        rewind_ump_part_t part;

        if (!rewind_ump_read_varint(buf, len, &pos, &type) ||
            !rewind_ump_read_varint(buf, len, &pos, &size) ||
            size > len - pos) {
            return start;
        }

        part.type = (uint32_t)type;
        part.data = buf + pos;
        part.length = (size_t)size;
        pos += (size_t)size;

        if (on_part) on_part(&part, ctx);
    }
}

/* standard proto2 wire format varint: 7 bits per byte, top bit means "more" */
static int rewind_pb_read_varint(const uint8_t *buf, size_t len, size_t *pos, uint64_t *out) {
    size_t at = *pos;
    uint64_t value = 0;
    unsigned shift = 0;

    while (at < len && shift <= 63) {
        uint8_t byte = buf[at++];
        if (shift == 63 && (byte & 0xfe)) return 0;
        value |= ((uint64_t)(byte & 0x7F)) << shift;
        if ((byte & 0x80) == 0) {
            *pos = at;
            *out = value;
            return 1;
        }
        shift += 7;
    }
    return 0;
}

static int rewind_pb_skip_field(const uint8_t *buf, size_t len, size_t *pos, unsigned wiretype) {
    uint64_t value;
    switch (wiretype) {
        case 0: /* varint */
            return rewind_pb_read_varint(buf, len, pos, &value);
        case 1: /* 64-bit */
            if (*pos + 8 > len) return 0;
            *pos += 8;
            return 1;
        case 2: /* length-delimited */
            if (!rewind_pb_read_varint(buf, len, pos, &value) || value > len - *pos) return 0;
            *pos += (size_t)value;
            return 1;
        case 5: /* 32-bit */
            if (*pos + 4 > len) return 0;
            *pos += 4;
            return 1;
        default:
            return 0;
    }
}

static int parse_time_range(const uint8_t *data, size_t len, int64_t *start_ms, int64_t *duration_ms) {
    size_t pos = 0;
    uint64_t start = 0, duration = 0, timescale = 0;
    int have_start = 0, have_duration = 0;
    while (pos < len) {
        uint64_t tag, value;
        if (!rewind_pb_read_varint(data, len, &pos, &tag) || !tag) return 0;
        if ((tag & 7) == 0) {
            if (!rewind_pb_read_varint(data, len, &pos, &value)) return 0;
            switch (tag >> 3) {
                case 1: start = value; have_start = 1; break;
                case 2: duration = value; have_duration = 1; break;
                case 3: timescale = value; break;
                default: break;
            }
        } else if (!rewind_pb_skip_field(data, len, &pos, (unsigned)(tag & 7))) return 0;
    }
    if (!have_start || !have_duration || !timescale || timescale > INT32_MAX ||
        start > INT64_MAX / 1000 || duration > INT64_MAX / 1000) return 0;
    *start_ms = (int64_t)(start * 1000 / timescale);
    *duration_ms = (int64_t)(duration * 1000 / timescale);
    return 1;
}

int rewind_ump_parse_media_header(const uint8_t *data, size_t len, rewind_ump_media_header_t *out) {
    size_t pos = 0;

    out->header_id = -1;
    out->itag = -1;
    out->is_init_segment = -1;
    out->segment_number = -1;
    out->segment_length_bytes = -1;
    out->start_ms = -1;
    out->duration_ms = -1;

    while (pos < len) {
        uint64_t tag, value;
        unsigned field, wiretype;

        if (!rewind_pb_read_varint(data, len, &pos, &tag) || !tag) return 0;
        field = (unsigned)(tag >> 3);
        wiretype = (unsigned)(tag & 7);

        if (wiretype == 0) {
            if (!rewind_pb_read_varint(data, len, &pos, &value)) return 0;
            switch (field) {
                case 1: out->header_id = (int64_t)value; break;
                case 3: out->itag = (int64_t)value; break;
                case 8: out->is_init_segment = (int64_t)value; break;
                case 9: out->segment_number = (int64_t)value; break;
                case 11: out->start_ms = (int64_t)value; break;
                case 12: out->duration_ms = (int64_t)value; break;
                case 14: out->segment_length_bytes = (int64_t)value; break;
                default: break;
            }
        } else if (field == 15 && wiretype == 2) {
            if (!rewind_pb_read_varint(data, len, &pos, &value) || value > len - pos ||
                !parse_time_range(data + pos, (size_t)value, &out->start_ms, &out->duration_ms)) return 0;
            pos += (size_t)value;
        } else if (!rewind_pb_skip_field(data, len, &pos, wiretype)) {
            return 0;
        }
    }
    return 1;
}

size_t rewind_ump_media_header_id(const uint8_t *data, size_t len, uint64_t *header_id) {
    if (!header_id) return 0;
    *header_id = 0;
    if (!data || !len) return 0;
    *header_id = data[0];
    return 1;
}

int rewind_ump_parse_stream_protection(const uint8_t *data, size_t len, uint32_t *status) {
    size_t pos = 0;
    int found = 0;
    if (!status) return 0;
    *status = 0;
    if (!data || !len) return 0;
    while (pos < len) {
        uint64_t tag, value;
        if (!rewind_pb_read_varint(data, len, &pos, &tag) || !tag) return 0;
        if (tag == 8) {
            if (!rewind_pb_read_varint(data, len, &pos, &value) || value > 3) return 0;
            *status = (uint32_t)value;
            found = 1;
        } else if (!rewind_pb_skip_field(data, len, &pos, (unsigned)(tag & 7))) return 0;
    }
    return found;
}

int rewind_ump_parse_sabr_error(const uint8_t *data, size_t len, rewind_ump_sabr_error_t *out) {
    size_t pos = 0;
    out->type[0] = '\0';
    out->code = -1;

    while (pos < len) {
        uint64_t tag, value;
        unsigned field, wiretype;

        if (!rewind_pb_read_varint(data, len, &pos, &tag)) return 0;
        field = (unsigned)(tag >> 3);
        wiretype = (unsigned)(tag & 7);

        if (field == 1 && wiretype == 2) {
            uint64_t strlen_v;
            size_t copy;
            if (!rewind_pb_read_varint(data, len, &pos, &strlen_v) || strlen_v > len - pos) return 0;
            copy = (size_t)strlen_v;
            if (copy >= sizeof(out->type)) copy = sizeof(out->type) - 1;
            memcpy(out->type, data + pos, copy);
            out->type[copy] = '\0';
            pos += (size_t)strlen_v;
        } else if (field == 2 && wiretype == 0) {
            if (!rewind_pb_read_varint(data, len, &pos, &value)) return 0;
            out->code = (int64_t)value;
        } else if (!rewind_pb_skip_field(data, len, &pos, wiretype)) {
            return 0;
        }
    }
    return 1;
}

int rewind_ump_parse_sabr_redirect(const uint8_t *data, size_t len, char *url, size_t url_cap) {
    size_t pos = 0;
    if (url_cap > 0) url[0] = '\0';

    while (pos < len) {
        uint64_t tag;
        unsigned field, wiretype;

        if (!rewind_pb_read_varint(data, len, &pos, &tag)) return 0;
        field = (unsigned)(tag >> 3);
        wiretype = (unsigned)(tag & 7);

        if (field == 1 && wiretype == 2) {
            uint64_t strlen_v;
            size_t copy;
            if (!rewind_pb_read_varint(data, len, &pos, &strlen_v) || strlen_v > len - pos) return 0;
            copy = (size_t)strlen_v;
            if (!url || !url_cap || !copy || copy >= url_cap || memchr(data + pos, 0, copy)) return 0;
            memcpy(url, data + pos, copy);
            url[copy] = '\0';
            return 1;
        }
        if (!rewind_pb_skip_field(data, len, &pos, wiretype)) return 0;
    }
    return 0;
}

size_t rewind_base64url_decoded_size(size_t encoded_len) {
    return (encoded_len / 4 + 1) * 3;
}

static int rewind_base64url_value(char c, uint8_t *value) {
    if (c >= 'A' && c <= 'Z') { *value = (uint8_t)(c - 'A'); return 1; }
    if (c >= 'a' && c <= 'z') { *value = (uint8_t)(c - 'a' + 26); return 1; }
    if (c >= '0' && c <= '9') { *value = (uint8_t)(c - '0' + 52); return 1; }
    if (c == '-') { *value = 62; return 1; }
    if (c == '_') { *value = 63; return 1; }
    return 0;
}

int rewind_base64url_decode(const char *text, size_t len, uint8_t *out, size_t out_cap,
                            size_t *out_len) {
    size_t i = 0, produced = 0;
    uint32_t group = 0;
    int in_group = 0;

    while (i < len && text[len - 1] == '=') --len; /* padding, if any, carries no data */

    for (i = 0; i < len; ++i) {
        uint8_t value;
        if (!rewind_base64url_value(text[i], &value)) return 0;

        group = (group << 6) | value;
        ++in_group;

        if (in_group == 4) {
            if (produced + 3 > out_cap) return 0;
            out[produced++] = (uint8_t)(group >> 16);
            out[produced++] = (uint8_t)(group >> 8);
            out[produced++] = (uint8_t)group;
            group = 0;
            in_group = 0;
        }
    }

    if (in_group == 1) return 0; /* one leftover character cannot decode to a byte */
    if (in_group >= 2) {
        unsigned pad = 4 - (unsigned)in_group;
        group <<= 6 * pad;
        if (produced + (in_group - 1) > out_cap) return 0;
        out[produced++] = (uint8_t)(group >> 16);
        if (in_group == 3) out[produced++] = (uint8_t)(group >> 8);
    }

    *out_len = produced;
    return 1;
}

void rewind_pb_writer_init(rewind_pb_writer_t *writer, uint8_t *buf, size_t cap) {
    writer->buf = buf;
    writer->len = 0;
    writer->cap = cap;
}

static int rewind_pb_put_byte(rewind_pb_writer_t *writer, uint8_t byte) {
    if (writer->len >= writer->cap) return 0;
    writer->buf[writer->len++] = byte;
    return 1;
}

static int rewind_pb_put_varint(rewind_pb_writer_t *writer, uint64_t value) {
    do {
        uint8_t byte = (uint8_t)(value & 0x7F);
        value >>= 7;
        if (value) byte |= 0x80;
        if (!rewind_pb_put_byte(writer, byte)) return 0;
    } while (value);
    return 1;
}

static int rewind_pb_put_tag(rewind_pb_writer_t *writer, uint32_t field, unsigned wiretype) {
    return rewind_pb_put_varint(writer, ((uint64_t)field << 3) | wiretype);
}

int rewind_pb_write_varint_field(rewind_pb_writer_t *writer, uint32_t field, uint64_t value) {
    rewind_pb_writer_t attempt = *writer;
    if (!rewind_pb_put_tag(&attempt, field, 0) || !rewind_pb_put_varint(&attempt, value)) return 0;
    *writer = attempt;
    return 1;
}

static int rewind_pb_write_lendelim(rewind_pb_writer_t *writer, uint32_t field,
                                    const uint8_t *data, size_t len) {
    rewind_pb_writer_t attempt = *writer;
    size_t i;
    if (!rewind_pb_put_tag(&attempt, field, 2) || !rewind_pb_put_varint(&attempt, (uint64_t)len)) return 0;
    for (i = 0; i < len; ++i) if (!rewind_pb_put_byte(&attempt, data[i])) return 0;
    *writer = attempt;
    return 1;
}

int rewind_pb_write_string_field(rewind_pb_writer_t *writer, uint32_t field,
                                 const char *data, size_t len) {
    return rewind_pb_write_lendelim(writer, field, (const uint8_t *)data, len);
}

int rewind_pb_write_message_field(rewind_pb_writer_t *writer, uint32_t field,
                                  const rewind_pb_writer_t *sub) {
    return rewind_pb_write_lendelim(writer, field, sub->buf, sub->len);
}
