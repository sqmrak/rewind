/* rebuilds a fragmented m4a the way the app does, from byte ranges of the file;
   with a path it checks that file and writes the plain m4a next to it for ffprobe */
#include "rewind_fmp4.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

static uint8_t *load(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    uint8_t *data;
    long size;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    data = malloc((size_t)size);
    if (data && fread(data, 1, (size_t)size, f) != (size_t)size) {
        free(data);
        data = NULL;
    }
    fclose(f);
    *len = (size_t)size;
    return data;
}

static int convert(const uint8_t *src, size_t len, const char *out_path) {
    rewind_fmp4_t *file = NULL;
    size_t needed = 0, head_len = 64, i;
    rewind_fmp4_status_t status;

    /* grow the head the way the app retries a short range */
    while ((status = rewind_fmp4_open(src, head_len, &needed, &file)) == REWIND_FMP4_NEED_MORE) {
        CHECK(needed > head_len);
        if (needed <= head_len || needed > len) return 1;
        head_len = needed;
    }
    CHECK(status == REWIND_FMP4_OK);
    if (status != REWIND_FMP4_OK) return 1;
    CHECK(rewind_fmp4_fragment_count(file) > 0);

    for (i = 0; i < rewind_fmp4_fragment_count(file); ++i) {
        uint64_t offset = rewind_fmp4_fragment_offset(file, i);
        size_t probe = 256;
        CHECK(offset + rewind_fmp4_fragment_size(file, i) <= len);
        while ((status = rewind_fmp4_add_fragment(file, i, src + offset, probe, &needed)) == REWIND_FMP4_NEED_MORE) {
            CHECK(needed > probe);
            if (needed <= probe) break;
            probe = needed;
        }
        CHECK(status == REWIND_FMP4_OK);
        if (status != REWIND_FMP4_OK) return 1;
    }
    CHECK(rewind_fmp4_finish(file) == REWIND_FMP4_OK);

    size_t header_len;
    const uint8_t *header = rewind_fmp4_header(file, &header_len);
    uint64_t expected = header_len;
    for (i = 0; i < rewind_fmp4_chunk_count(file); ++i) {
        const rewind_fmp4_chunk_t *chunk = rewind_fmp4_chunk(file, i);
        CHECK(chunk->output_offset == expected);
        CHECK(chunk->source_offset + chunk->length <= len);
        expected += chunk->length;
    }
    CHECK(expected == rewind_fmp4_output_size(file));
    printf("fragments %zu chunks %zu header %zu output %llu duration %.2f\n",
           rewind_fmp4_fragment_count(file), rewind_fmp4_chunk_count(file), header_len,
           (unsigned long long)rewind_fmp4_output_size(file), rewind_fmp4_duration(file));

    if (out_path) {
        FILE *out = fopen(out_path, "wb");
        if (!out) return 1;
        fwrite(header, 1, header_len, out);
        for (i = 0; i < rewind_fmp4_chunk_count(file); ++i) {
            const rewind_fmp4_chunk_t *chunk = rewind_fmp4_chunk(file, i);
            fwrite(src + chunk->source_offset, 1, (size_t)chunk->length, out);
        }
        fclose(out);
    }
    rewind_fmp4_free(file);
    return 0;
}

static void test_rejects_garbage(void) {
    static const uint8_t junk[64] = { 0, 0, 0, 3, 'f', 't', 'y', 'p' };
    rewind_fmp4_t *file = NULL;
    size_t needed = 0;
    CHECK(rewind_fmp4_open(junk, sizeof(junk), &needed, &file) == REWIND_FMP4_INVALID);
    CHECK(file == NULL);
    CHECK(rewind_fmp4_open(junk, 4, &needed, &file) == REWIND_FMP4_NEED_MORE);
}

/* a stream prefetch calls this on whatever it already fetched, before the fragment's
   turn comes up in rewind_fmp4_add_fragment, so it must read the same box size that
   call would report through *needed for the identical bytes */
static void test_probe_box_size(void) {
    static const uint8_t moof[20] = {
        0, 0, 0, 20, 'm', 'o', 'o', 'f', 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
    };
    CHECK(rewind_fmp4_probe_box_size(moof, sizeof(moof)) == 20);
    /* only the header is present; the declared size still comes back whole */
    CHECK(rewind_fmp4_probe_box_size(moof, 8) == 20);
    /* fewer than 8 bytes: read_box cannot see the size field yet */
    CHECK(rewind_fmp4_probe_box_size(moof, 3) == 16);
    CHECK(rewind_fmp4_probe_box_size(NULL, 0) == 0);

    static const uint8_t malformed[8] = { 0, 0, 0, 2, 'm', 'o', 'o', 'f' };
    CHECK(rewind_fmp4_probe_box_size(malformed, sizeof(malformed)) == 0);
}

typedef struct {
    uint8_t bytes[1024];
    size_t used;
} fixture_t;

static void fixture_u32(fixture_t *f, uint32_t value) {
    CHECK(f->used + 4 <= sizeof(f->bytes));
    f->bytes[f->used++] = (uint8_t)(value >> 24);
    f->bytes[f->used++] = (uint8_t)(value >> 16);
    f->bytes[f->used++] = (uint8_t)(value >> 8);
    f->bytes[f->used++] = (uint8_t)value;
}

static void fixture_patch(fixture_t *f, size_t at, uint32_t value) {
    size_t saved = f->used;
    f->used = at;
    fixture_u32(f, value);
    f->used = saved;
}

static size_t fixture_box(fixture_t *f, const char *type) {
    size_t at = f->used;
    fixture_u32(f, 0);
    memcpy(f->bytes + f->used, type, 4);
    f->used += 4;
    return at;
}

static void fixture_close(fixture_t *f, size_t at) {
    fixture_patch(f, at, (uint32_t)(f->used - at));
}

static void test_fragment_tables(void) {
    fixture_t f = {{0}, 0};
    size_t moov = fixture_box(&f, "moov"), trak = fixture_box(&f, "trak");
    size_t mdia = fixture_box(&f, "mdia"), mdhd = fixture_box(&f, "mdhd"), i;
    fixture_u32(&f, 0); fixture_u32(&f, 0); fixture_u32(&f, 0);
    fixture_u32(&f, 44100); fixture_u32(&f, 0); fixture_u32(&f, 0);
    fixture_close(&f, mdhd);
    size_t minf = fixture_box(&f, "minf"), stbl = fixture_box(&f, "stbl");
    size_t stsd = fixture_box(&f, "stsd");
    fixture_u32(&f, 0); fixture_u32(&f, 1);
    size_t mp4a = fixture_box(&f, "mp4a");
    for (i = 0; i < 7; ++i) fixture_u32(&f, 0);
    fixture_close(&f, mp4a);
    fixture_close(&f, stsd); fixture_close(&f, stbl); fixture_close(&f, minf);
    fixture_close(&f, mdia); fixture_close(&f, trak);
    size_t mvex = fixture_box(&f, "mvex"), trex = fixture_box(&f, "trex");
    fixture_u32(&f, 0); fixture_u32(&f, 1); fixture_u32(&f, 1);
    fixture_u32(&f, 1024); fixture_u32(&f, 4); fixture_u32(&f, 0);
    fixture_close(&f, trex); fixture_close(&f, mvex); fixture_close(&f, moov);
    size_t sidx = fixture_box(&f, "sidx");
    fixture_u32(&f, 0); fixture_u32(&f, 1); fixture_u32(&f, 44100);
    fixture_u32(&f, 0); fixture_u32(&f, 0); fixture_u32(&f, 1);
    size_t reference = f.used;
    fixture_u32(&f, 0); fixture_u32(&f, 2048); fixture_u32(&f, 0);
    fixture_close(&f, sidx);
    size_t head_size = f.used, moof = fixture_box(&f, "moof"), traf = fixture_box(&f, "traf");
    size_t tfhd = fixture_box(&f, "tfhd");
    fixture_u32(&f, 0x020000); fixture_u32(&f, 1); fixture_close(&f, tfhd);
    size_t trun = fixture_box(&f, "trun");
    fixture_u32(&f, 1); fixture_u32(&f, 2);
    size_t data_offset = f.used;
    fixture_u32(&f, 0);
    fixture_close(&f, trun); fixture_close(&f, traf); fixture_close(&f, moof);
    size_t mdat = fixture_box(&f, "mdat");
    fixture_u32(&f, 0x11223344); fixture_u32(&f, 0x55667788); fixture_close(&f, mdat);
    fixture_patch(&f, reference, (uint32_t)(f.used - head_size));
    fixture_patch(&f, data_offset, (uint32_t)(mdat + 8 - moof));

    rewind_fmp4_t *file = NULL;
    size_t needed = 99, header_length;
    CHECK(rewind_fmp4_open(f.bytes, head_size - 1, &needed, &file) == REWIND_FMP4_NEED_MORE);
    CHECK(needed == head_size && file == NULL);
    CHECK(rewind_fmp4_open(f.bytes, head_size, &needed, &file) == REWIND_FMP4_OK);
    CHECK(needed == 0 && rewind_fmp4_fragment_count(file) == 1);
    CHECK(rewind_fmp4_fragment_start_ms(file, 0) == 0 && rewind_fmp4_fragment_start_ms(file, 2) == -1);
    CHECK(rewind_fmp4_fragment_offset(file, 0) == head_size);
    CHECK(rewind_fmp4_finish(file) == REWIND_FMP4_INVALID);
    CHECK(rewind_fmp4_add_fragment(file, 1, f.bytes + head_size, f.used - head_size, &needed) == REWIND_FMP4_INVALID);
    CHECK(rewind_fmp4_add_fragment(file, 0, f.bytes + head_size, 8, &needed) == REWIND_FMP4_NEED_MORE);
    CHECK(needed == mdat - moof);
    CHECK(rewind_fmp4_add_fragment(file, 0, f.bytes + head_size, mdat - moof, &needed) == REWIND_FMP4_OK);
    CHECK(rewind_fmp4_finish(file) == REWIND_FMP4_OK);
    CHECK(rewind_fmp4_duration(file) == 2048.0 / 44100.0);
    CHECK(rewind_fmp4_chunk_count(file) == 1);
    const rewind_fmp4_chunk_t *chunk = rewind_fmp4_chunk(file, 0);
    CHECK(chunk && chunk->source_offset == mdat + 8 && chunk->length == 8);
    CHECK(rewind_fmp4_header(file, &header_length) != NULL);
    CHECK(rewind_fmp4_output_size(file) == header_length + 8);
    CHECK(chunk && chunk->output_offset == header_length);
    rewind_fmp4_free(file);

    fixture_patch(&f, trun + 12, UINT32_MAX);
    CHECK(rewind_fmp4_open(f.bytes, head_size, &needed, &file) == REWIND_FMP4_OK);
    CHECK(rewind_fmp4_add_fragment(file, 0, f.bytes + head_size, f.used - head_size, &needed) == REWIND_FMP4_INVALID);
    rewind_fmp4_free(file);
    fixture_patch(&f, trun + 12, 2);
    fixture_patch(&f, data_offset, UINT32_MAX);
    CHECK(rewind_fmp4_open(f.bytes, head_size, &needed, &file) == REWIND_FMP4_OK);
    CHECK(rewind_fmp4_add_fragment(file, 0, f.bytes + head_size, f.used - head_size, &needed) == REWIND_FMP4_INVALID);
    rewind_fmp4_free(file);
    fixture_patch(&f, reference, 0);
    CHECK(rewind_fmp4_open(f.bytes, head_size, &needed, &file) == REWIND_FMP4_INVALID);
    CHECK(file == NULL);
    fixture_patch(&f, reference, (uint32_t)(f.used - head_size));
    fixture_patch(&f, mp4a + 4, 0x4f707573); /* Opus cannot enter an AAC sample table */
    CHECK(rewind_fmp4_open(f.bytes, head_size, &needed, &file) == REWIND_FMP4_INVALID);
    CHECK(file == NULL);
    CHECK(rewind_fmp4_open(NULL, 0, &needed, &file) == REWIND_FMP4_INVALID);
    CHECK(file == NULL && needed == 0);
    static const uint8_t oversized[] = {0xff, 0xff, 0xff, 0xff, 'm', 'o', 'o', 'v'};
    CHECK(rewind_fmp4_open(oversized, sizeof(oversized), &needed, &file) == REWIND_FMP4_INVALID);
}

int main(int argc, char **argv) {
    test_rejects_garbage();
    test_probe_box_size();
    test_fragment_tables();
    if (argc > 1) {
        size_t len = 0;
        uint8_t *src = load(argv[1], &len);
        CHECK(src != NULL);
        if (src) CHECK(convert(src, len, argc > 2 ? argv[2] : NULL) == 0);
        free(src);
    }
    if (failures) {
        fprintf(stderr, "test_fmp4: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_fmp4: ok\n");
    return 0;
}
