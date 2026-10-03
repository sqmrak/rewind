#include "rewind_sabr.h"
#include "rewind_ump.h"
#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); ++failures; } } while (0)

/* two SIDX entries, each with two AAC samples at 44100 Hz */
static const uint8_t init[] = {
    0x00, 0x00, 0x00, 0xa4, 0x6d, 0x6f, 0x6f, 0x76, 0x00, 0x00, 0x00, 0x74, 0x74, 0x72, 0x61, 0x6b,
    0x00, 0x00, 0x00, 0x6c, 0x6d, 0x64, 0x69, 0x61, 0x00, 0x00, 0x00, 0x20, 0x6d, 0x64, 0x68, 0x64,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xac, 0x44,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x44, 0x6d, 0x69, 0x6e, 0x66,
    0x00, 0x00, 0x00, 0x3c, 0x73, 0x74, 0x62, 0x6c, 0x00, 0x00, 0x00, 0x34, 0x73, 0x74, 0x73, 0x64,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x24, 0x6d, 0x70, 0x34, 0x61,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28,
    0x6d, 0x76, 0x65, 0x78, 0x00, 0x00, 0x00, 0x20, 0x74, 0x72, 0x65, 0x78, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x73, 0x69, 0x64, 0x78, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0xac, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x44, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x44, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00
};
static const uint8_t fragment[] = {
    0x00, 0x00, 0x00, 0x34, 0x6d, 0x6f, 0x6f, 0x66, 0x00, 0x00, 0x00, 0x2c, 0x74, 0x72, 0x61, 0x66,
    0x00, 0x00, 0x00, 0x10, 0x74, 0x66, 0x68, 0x64, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x14, 0x74, 0x72, 0x75, 0x6e, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x00, 0x00, 0x3c, 0x00, 0x00, 0x00, 0x10, 0x6d, 0x64, 0x61, 0x74, 0x31, 0x32, 0x33, 0x34,
    0x35, 0x36, 0x37, 0x38
};

typedef struct { uint8_t bytes[4096]; size_t used; } response_t;

static void ump_integer(response_t *r, size_t value) {
    if (value < 128) r->bytes[r->used++] = (uint8_t)value;
    else {
        CHECK(value < 16384);
        r->bytes[r->used++] = (uint8_t)(0x80 | (value & 63));
        r->bytes[r->used++] = (uint8_t)(value >> 6);
    }
}

static void part(response_t *r, int type, const uint8_t *data, size_t length) {
    CHECK(r->used + length + 4 <= sizeof(r->bytes));
    ump_integer(r, (size_t)type);
    ump_integer(r, length);
    if (length) memcpy(r->bytes + r->used, data, length);
    r->used += length;
}

static void segment(response_t *r, int id, int number, const uint8_t *bytes, size_t size, int ended) {
    uint8_t header_bytes[128], time_bytes[32], media[1024];
    rewind_pb_writer_t header, time;
    rewind_pb_writer_init(&header, header_bytes, sizeof(header_bytes));
    CHECK(rewind_pb_write_varint_field(&header, 1, (uint64_t)id));
    CHECK(rewind_pb_write_varint_field(&header, 3, 140));
    CHECK(rewind_pb_write_varint_field(&header, 8, number == 0));
    CHECK(rewind_pb_write_varint_field(&header, 9, (uint64_t)number));
    CHECK(rewind_pb_write_varint_field(&header, 14, size));
    if (number) {
        rewind_pb_writer_init(&time, time_bytes, sizeof(time_bytes));
        CHECK(rewind_pb_write_varint_field(&time, 1, (uint64_t)(number - 1) * 2048));
        CHECK(rewind_pb_write_varint_field(&time, 2, 2048));
        CHECK(rewind_pb_write_varint_field(&time, 3, 44100));
        CHECK(rewind_pb_write_message_field(&header, 15, &time));
    }
    part(r, REWIND_UMP_MEDIA_HEADER, header.buf, header.len);
    if (size <= sizeof(media) - 1) {
        media[0] = (uint8_t)id;
        memcpy(media + 1, bytes, size);
        part(r, REWIND_UMP_MEDIA, media, size + 1);
        if (ended) part(r, REWIND_UMP_MEDIA_END, media, 1);
    }
}

static void test_complete_track(void) {
    response_t r = {{0}, 0};
    char redirect[128];
    uint8_t redirect_bytes[128];
    rewind_pb_writer_t url;
    rewind_sabr_t *s = rewind_sabr_create(140);
    rewind_pb_writer_init(&url, redirect_bytes, sizeof(redirect_bytes));
    CHECK(rewind_pb_write_string_field(&url, 1, "https://cdn.example/audio", 25));
    part(&r, REWIND_UMP_SABR_REDIRECT, url.buf, url.len);
    segment(&r, 0, 0, init, sizeof(init), 1);
    segment(&r, 255, 1, fragment, sizeof(fragment), 1);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_PROGRESS);
    CHECK(strcmp(redirect, "https://cdn.example/audio") == 0);
    CHECK(rewind_sabr_segment(s) == 1 && rewind_sabr_duration_ms(s) == 46);
    CHECK(rewind_sabr_file(s) == NULL && rewind_sabr_source(s) == NULL);
    r.used = 0;
    part(&r, REWIND_UMP_NEXT_REQUEST_POLICY, NULL, 0);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_NO_PROGRESS);
    CHECK(rewind_sabr_file(s) == NULL);
    r.used = 0;
    segment(&r, 0, 1, fragment, sizeof(fragment), 1);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_NO_PROGRESS);
    r.used = 0;
    segment(&r, 0, 2, fragment, sizeof(fragment), 1);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_READY);
    CHECK(rewind_sabr_file(s) != NULL && rewind_sabr_source(s) != NULL);
    CHECK(rewind_sabr_segment(s) == 2 && rewind_sabr_duration_ms(s) == 92);
    CHECK(rewind_fmp4_chunk_count(rewind_sabr_file(s)) == 2);
    CHECK(memcmp(rewind_sabr_source(s) + sizeof(init), fragment, sizeof(fragment)) == 0);
    rewind_sabr_free(s);
}

static void test_rejects_incomplete(void) {
    response_t r = {{0}, 0};
    char redirect[128];
    rewind_sabr_t *s = rewind_sabr_create(140);
    /* a segment may arrive before the ones in front of it, the prefix commits when they do */
    segment(&r, 0, 0, init, sizeof(init), 1);
    segment(&r, 1, 2, fragment, sizeof(fragment), 1);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_PROGRESS);
    CHECK(rewind_sabr_segment(s) == 0 && rewind_sabr_have_count(s) == 1 && rewind_sabr_file(s) == NULL);
    r.used = 0;
    segment(&r, 1, 1, fragment, sizeof(fragment), 1);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_READY);
    CHECK(rewind_sabr_segment(s) == 2 && rewind_sabr_duration_ms(s) == 92);
    rewind_sabr_free(s);
    s = rewind_sabr_create(140);
    r.used = 0;
    segment(&r, 0, 0, init, sizeof(init), 1);
    segment(&r, 1, 3, fragment, sizeof(fragment), 1);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_INVALID);
    CHECK(rewind_sabr_file(s) == NULL || rewind_sabr_have_count(s) == 0);
    rewind_sabr_free(s);
    s = rewind_sabr_create(140);
    r.used = 0;
    segment(&r, 0, 0, init, sizeof(init), 1);
    segment(&r, 1, 1, fragment, sizeof(fragment), 0);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_NO_PROGRESS);
    CHECK(rewind_sabr_segment(s) == 0 && rewind_sabr_file(s) == NULL);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used - 1, redirect, sizeof(redirect)) == REWIND_SABR_INVALID);
    rewind_sabr_free(s);
    s = rewind_sabr_create(140);
    r.used = 0;
    segment(&r, 0, 0, NULL, 4 * 1024 * 1024 + 1, 0);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_INVALID);
    rewind_sabr_free(s);
}

static void test_server_failures(void) {
    response_t r = {{0}, 0};
    char redirect[128];
    uint8_t protection[] = {8, 2};
    rewind_sabr_t *s = rewind_sabr_create(140);
    /* pending attestation still streams the first segments, only a required one stops the stream */
    part(&r, REWIND_UMP_STREAM_PROTECTION, protection, sizeof(protection));
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_NO_PROGRESS);
    protection[1] = 3;
    r.used = 0;
    part(&r, REWIND_UMP_STREAM_PROTECTION, protection, sizeof(protection));
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_AUTH_REQUIRED);
    CHECK(rewind_sabr_file(s) == NULL);
    r.used = 0;
    part(&r, REWIND_UMP_SABR_ERROR, NULL, 0);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_REMOTE_ERROR);
    protection[1] = 4;
    r.used = 0;
    part(&r, REWIND_UMP_STREAM_PROTECTION, protection, sizeof(protection));
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_INVALID);
    rewind_sabr_free(s);
}

static void test_prefix_preview(void) {
    response_t r = {{0}, 0};
    char redirect[128];
    rewind_sabr_t *s = rewind_sabr_create(140);
    rewind_fmp4_t *preview;
    CHECK(rewind_sabr_prefix(s, 1) == NULL);
    segment(&r, 0, 0, init, sizeof(init), 1);
    segment(&r, 1, 1, fragment, sizeof(fragment), 1);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_PROGRESS);
    CHECK(rewind_sabr_contiguous(s) == 1 && rewind_sabr_file(s) == NULL);
    CHECK(rewind_sabr_prefix(s, 2) == NULL);
    preview = rewind_sabr_prefix(s, 1);
    CHECK(preview != NULL);
    if (preview) {
        const rewind_fmp4_chunk_t *chunk;
        CHECK(rewind_fmp4_chunk_count(preview) == 1);
        chunk = rewind_fmp4_chunk(preview, 0);
        CHECK(memcmp(rewind_sabr_data(s) + chunk->source_offset, fragment + 60, 8) == 0);
        CHECK(rewind_fmp4_output_size(preview) > 8);
        rewind_fmp4_free(preview);
    }
    /* the stream still completes after a preview was cut from it */
    r.used = 0;
    segment(&r, 0, 2, fragment, sizeof(fragment), 1);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_READY);
    preview = rewind_sabr_prefix(s, 2);
    CHECK(preview != NULL && rewind_fmp4_chunk_count(preview) == 2);
    rewind_fmp4_free(preview);
    rewind_sabr_free(s);
}

static void test_request_plan(void) {
    response_t r = {{0}, 0};
    char redirect[128];
    rewind_sabr_request_t request;
    rewind_sabr_t *s = rewind_sabr_create(140);
    int attempt;
    CHECK(rewind_sabr_next_request(s, &request) == REWIND_SABR_PLAN_REQUEST && request.segment == 0 &&
          request.claimed_segments == 0);
    CHECK(rewind_sabr_next_request(s, &request) == REWIND_SABR_PLAN_WAIT);
    segment(&r, 0, 0, init, sizeof(init), 1);
    segment(&r, 1, 1, fragment, sizeof(fragment), 1);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_PROGRESS);
    request.segment = 0;
    rewind_sabr_request_done(s, &request);
    CHECK(rewind_sabr_expected(s) == 2);
    /* segment 1 is in hand, the next ask claims it and wants segment 2 */
    CHECK(rewind_sabr_next_request(s, &request) == REWIND_SABR_PLAN_REQUEST && request.segment == 2 &&
          request.claimed_segments == 1 && request.claimed_ms == 46);
    CHECK(rewind_sabr_next_request(s, &request) == REWIND_SABR_PLAN_WAIT);
    request.segment = 2;
    rewind_sabr_request_done(s, &request);
    for (attempt = 1; attempt < 3; ++attempt) {
        CHECK(rewind_sabr_next_request(s, &request) == REWIND_SABR_PLAN_REQUEST && request.segment == 2);
        rewind_sabr_request_done(s, &request);
    }
    CHECK(rewind_sabr_next_request(s, &request) == REWIND_SABR_PLAN_EXHAUSTED);
    r.used = 0;
    segment(&r, 1, 2, fragment, sizeof(fragment), 1);
    CHECK(rewind_sabr_feed(s, r.bytes, r.used, redirect, sizeof(redirect)) == REWIND_SABR_READY);
    CHECK(rewind_sabr_next_request(s, &request) == REWIND_SABR_PLAN_DONE);
    rewind_sabr_free(s);
    /* a bootstrap that never brings the init segment gives up after its attempts */
    s = rewind_sabr_create(140);
    for (attempt = 0; attempt < 3; ++attempt) {
        CHECK(rewind_sabr_next_request(s, &request) == REWIND_SABR_PLAN_REQUEST && request.segment == 0);
        rewind_sabr_request_done(s, &request);
    }
    CHECK(rewind_sabr_next_request(s, &request) == REWIND_SABR_PLAN_EXHAUSTED);
    rewind_sabr_free(s);
}

int main(void) {
    CHECK(rewind_sabr_create(0) == NULL);
    test_complete_track();
    test_rejects_incomplete();
    test_server_failures();
    test_request_plan();
    test_prefix_preview();
    if (failures) return 1;
    puts("all sabr checks passed");
    return 0;
}
