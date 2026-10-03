/* sabr's ump framing and the bits of proto2 wire format it carries; the media_header
   and sabr_error fixtures below are bytes actually returned by a real sabr endpoint,
   captured while reverse engineering the protocol, not invented */
#include "rewind_ump.h"

#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

static void test_varint_sizes(void) {
    static const struct { uint8_t bytes[5]; size_t len; uint64_t expect; } cases[] = {
        { {0x05}, 1, 5 },                               /* 1 byte */
        { {0xaa, 0x0c}, 2, 810 },                        /* 2 bytes, real: a selectableFormats part size */
        { {0xc1, 0x00, 0x04}, 3, 32769 },                /* 3 bytes, real: a media part size */
        { {0xe0, 0xb4, 0xc4, 0x04}, 4, 5000000 },        /* 4 bytes, constructed to exercise this width */
        /* 5 bytes ignores the first byte's low bits entirely and reads a plain
           32-bit little-endian integer, so the value must fit in 32 bits */
        { {0xf0, 0x00, 0x5e, 0xd0, 0xb2}, 5, 3000000000ULL },
    };
    size_t i;
    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        size_t pos = 0;
        uint64_t value = 0;
        int ok = rewind_ump_read_varint(cases[i].bytes, cases[i].len, &pos, &value);
        CHECK(ok);
        CHECK(pos == cases[i].len);
        CHECK(value == cases[i].expect);
    }
}

static void test_varint_truncated(void) {
    static const uint8_t two_byte_prefix_only[] = {0xaa};
    size_t pos = 0;
    uint64_t value = 0;
    CHECK(!rewind_ump_read_varint(two_byte_prefix_only, sizeof(two_byte_prefix_only), &pos, &value));
    CHECK(pos == 0); /* on failure the caller's position must not move */
}

static void test_varint_reserved_prefix(void) {
    static const uint8_t reserved[] = {0xF8, 0, 0, 0, 0, 0};
    size_t pos = 0;
    uint64_t value = 0;
    CHECK(!rewind_ump_read_varint(reserved, sizeof(reserved), &pos, &value));
}

typedef struct { uint32_t types[8]; size_t lengths[8]; size_t count; } recorded_parts_t;

static void record_part(const rewind_ump_part_t *part, void *ctx) {
    recorded_parts_t *rec = (recorded_parts_t *)ctx;
    if (rec->count >= 8) return;
    rec->types[rec->count] = part->type;
    rec->lengths[rec->count] = part->length;
    ++rec->count;
}

static void test_parse_walks_complete_parts(void) {
    /* type=22 (MEDIA_END) size=1 data=0x00, then type=20 size=3 data="abc" */
    static const uint8_t buf[] = { 22, 1, 0x00, 20, 3, 'a', 'b', 'c' };
    recorded_parts_t rec;
    memset(&rec, 0, sizeof(rec));

    size_t consumed = rewind_ump_parse(buf, sizeof(buf), record_part, &rec);

    CHECK(consumed == sizeof(buf));
    CHECK(rec.count == 2);
    CHECK(rec.types[0] == REWIND_UMP_MEDIA_END && rec.lengths[0] == 1);
    CHECK(rec.types[1] == REWIND_UMP_MEDIA_HEADER && rec.lengths[1] == 3);
}

static void test_parse_stops_at_partial_tail(void) {
    /* a whole part, then a part claiming a 50 byte body with only 2 bytes present:
       sabr responses end like this whenever the segment continues in another request */
    static const uint8_t buf[] = { 22, 1, 0x00, 21, 50, 'x', 'y' };
    recorded_parts_t rec;
    memset(&rec, 0, sizeof(rec));

    size_t consumed = rewind_ump_parse(buf, sizeof(buf), record_part, &rec);

    CHECK(consumed == 3); /* only the first part was whole */
    CHECK(rec.count == 1);
    CHECK(rec.types[0] == REWIND_UMP_MEDIA_END);
}

static void test_media_header_id(void) {
    static const uint8_t body[] = { 0x01, 'a', 'u', 'd', 'i', 'o' };
    uint64_t header_id = 99;
    size_t media_start = rewind_ump_media_header_id(body, sizeof(body), &header_id);
    CHECK(media_start == 1);
    CHECK(header_id == 1);
    CHECK(memcmp(body + media_start, "audio", 5) == 0);
    static const uint8_t large_id[] = {0xff, 'a'};
    CHECK(rewind_ump_media_header_id(large_id, sizeof(large_id), &header_id) == 1);
    CHECK(header_id == 255);
}

/* captured media_header body: header_id=1, video_id="dQw4w9WgXcQ", itag=140,
   is_init_segment=false, segment_length_bytes=162083 */
static void test_parse_real_media_header(void) {
    static const uint8_t body[] = {
        0x08, 0x01, 0x12, 0x0b, 0x64, 0x51, 0x77, 0x34, 0x77, 0x39, 0x57, 0x67,
        0x58, 0x63, 0x51, 0x18, 0x8c, 0x01, 0x20, 0xef, 0x94, 0x9c, 0xe2, 0x97,
        0xe1, 0x91, 0x03, 0x30, 0xfb, 0x07, 0x40, 0x00, 0x48, 0x01, 0x50, 0xe9,
        0x7e, 0x6a, 0x0c, 0x08, 0x8c, 0x01, 0x10, 0xef, 0x94, 0x9c, 0xe2, 0x97,
        0xe1, 0x91, 0x03, 0x70, 0xa3, 0xf2, 0x09, 0x7a, 0x0a, 0x08, 0x00, 0x10,
        0x80, 0xf0, 0x1a, 0x18, 0xc4, 0xd8, 0x02
    };
    rewind_ump_media_header_t header;
    CHECK(rewind_ump_parse_media_header(body, sizeof(body), &header));
    CHECK(header.header_id == 1);
    CHECK(header.itag == 140);
    CHECK(header.is_init_segment == 0);
    CHECK(header.segment_number == 1);
    CHECK(header.segment_length_bytes == 162083);
    /* the same capture carries time_range in field 15, with ticks at 44100 hz */
    CHECK(header.start_ms == 0);
    CHECK(header.duration_ms == 9984);
}

/* captured sabr_error body: a request missing video_playback_ustreamer_config */
static void test_parse_real_sabr_error(void) {
    static const uint8_t body[] = {
        0x0a, 0x15, 's', 'a', 'b', 'r', '.', 'm', 'a', 'l', 'f', 'o', 'r', 'm',
        'e', 'd', '_', 'c', 'o', 'n', 'f', 'i', 'g', 0x10, 0x02, 0x1a, 0x02,
        0x20, 0x04
    };
    rewind_ump_sabr_error_t error;
    CHECK(rewind_ump_parse_sabr_error(body, sizeof(body), &error));
    CHECK(strcmp(error.type, "sabr.malformed_config") == 0);
    CHECK(error.code == 2);
}

static void test_parse_sabr_redirect(void) {
    static const uint8_t body[] = { 0x0a, 0x04, 'h', 't', 't', 'p' };
    char url[8];
    CHECK(rewind_ump_parse_sabr_redirect(body, sizeof(body), url, sizeof(url)));
    CHECK(strcmp(url, "http") == 0);
    CHECK(!rewind_ump_parse_sabr_redirect(body, sizeof(body), url, 4));
}

static void test_base64url_decode(void) {
    static const char text[] = "SGVsbG8sIHdvcmxkIQ"; /* "Hello, world!", no padding */
    uint8_t out[32];
    size_t out_len = 0;
    CHECK(rewind_base64url_decode(text, strlen(text), out, sizeof(out), &out_len));
    CHECK(out_len == 13);
    CHECK(memcmp(out, "Hello, world!", 13) == 0);
}

static void test_base64url_decode_dash_underscore(void) {
    /* bytes 0xfb 0xff encode to "-_-" in the url-safe alphabet ("+/+" with
       standard base64 characters): exercises both substituted characters */
    static const char text[] = "-_-";
    uint8_t out[8];
    size_t out_len = 0;
    static const uint8_t expect[] = { 0xfb, 0xff };
    CHECK(rewind_base64url_decode(text, strlen(text), out, sizeof(out), &out_len));
    CHECK(out_len == 2);
    CHECK(memcmp(out, expect, 2) == 0);
}

static void test_base64url_decode_rejects_bad_character(void) {
    static const char text[] = "abc!";
    uint8_t out[8];
    size_t out_len = 0;
    CHECK(!rewind_base64url_decode(text, strlen(text), out, sizeof(out), &out_len));
}

static void test_base64url_decode_rejects_overflow(void) {
    static const char text[] = "SGVsbG8sIHdvcmxkIQ";
    uint8_t out[4]; /* far smaller than the 13 decoded bytes */
    size_t out_len = 0;
    CHECK(!rewind_base64url_decode(text, strlen(text), out, sizeof(out), &out_len));
}

static void test_writer_round_trip(void) {
    uint8_t inner_buf[32];
    uint8_t outer_buf[64];
    rewind_pb_writer_t inner, outer;

    rewind_pb_writer_init(&inner, inner_buf, sizeof(inner_buf));
    CHECK(rewind_pb_write_varint_field(&inner, 1, 140));
    CHECK(rewind_pb_write_string_field(&inner, 3, "en", 2));

    rewind_pb_writer_init(&outer, outer_buf, sizeof(outer_buf));
    CHECK(rewind_pb_write_varint_field(&outer, 28, 0));
    CHECK(rewind_pb_write_message_field(&outer, 19, &inner));

    /* expected wire bytes; field numbers 19 and 28 both need a two-byte tag
       varint since (field << 3) already exceeds 127 */
    static const uint8_t expect[] = {
        0xe0, 0x01, 0x00,             /* field 28, varint 0 */
        0x9a, 0x01, 0x07,             /* field 19, length-delimited, 7 bytes */
        0x08, 0x8c, 0x01,             /* field 1, varint 140 */
        0x1a, 0x02, 'e', 'n'          /* field 3, string "en" */
    };
    CHECK(outer.len == sizeof(expect));
    CHECK(outer.len == sizeof(expect) && memcmp(outer.buf, expect, sizeof(expect)) == 0);
}

static void test_writer_reports_overflow(void) {
    uint8_t tiny[1];
    rewind_pb_writer_t writer;
    rewind_pb_writer_init(&writer, tiny, sizeof(tiny));
    CHECK(!rewind_pb_write_string_field(&writer, 1, "too long for one byte", 22));
    CHECK(writer.len == 0); /* a failed write must not leave partial bytes behind */
}

int main(void) {
    test_varint_sizes();
    test_varint_truncated();
    test_varint_reserved_prefix();
    test_parse_walks_complete_parts();
    test_parse_stops_at_partial_tail();
    test_media_header_id();
    test_parse_real_media_header();
    test_parse_real_sabr_error();
    test_parse_sabr_redirect();
    test_base64url_decode();
    test_base64url_decode_dash_underscore();
    test_base64url_decode_rejects_bad_character();
    test_base64url_decode_rejects_overflow();
    test_writer_round_trip();
    test_writer_reports_overflow();

    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
