#include "rewind_fmp4.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    uint64_t source_offset;
    uint64_t length;
    size_t first_sample;
    size_t sample_count;
} rewind_run_t;

struct rewind_fmp4 {
    uint8_t *stsd;
    size_t stsd_len;
    uint32_t timescale;
    uint32_t trex_duration;
    uint32_t trex_size;

    size_t fragment_count;
    uint64_t *fragment_offsets;
    uint64_t *fragment_sizes;
    uint32_t *fragment_durations;
    uint32_t sidx_timescale;
    uint64_t sidx_start;
    size_t next_fragment;

    uint32_t *sample_sizes;
    uint32_t *sample_durations;
    size_t sample_count;
    size_t sample_capacity;

    rewind_run_t *runs;
    size_t run_count;
    size_t run_capacity;

    uint8_t *header;
    size_t header_len;
    rewind_fmp4_chunk_t *chunks;
    uint64_t output_size;
    uint64_t total_duration;
};

static uint32_t rd32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static uint64_t rd64(const uint8_t *p) {
    return ((uint64_t)rd32(p) << 32) | rd32(p + 4);
}

/* reads the box at p; *body and *end bound its payload within the buffer */
typedef struct {
    const uint8_t *start;
    const uint8_t *body;
    uint64_t size;
    char type[4];
} rewind_box_t;

/* 1 on a whole box, 0 when the buffer ends inside it (box->size still set), -1 when malformed */
static int read_box(const uint8_t *p, const uint8_t *end, rewind_box_t *box) {
    size_t avail = (size_t)(end - p);
    size_t header = 8;
    uint64_t size;
    if (avail < 8) {
        box->size = 16;
        return 0;
    }
    size = rd32(p);
    if (size == 1) {
        if (avail < 16) {
            box->size = 16;
            return 0;
        }
        size = rd64(p + 8);
        header = 16;
    } else if (size == 0) {
        size = avail;
    }
    if (size < header) return -1;
    box->start = p;
    box->body = p + header;
    box->size = size;
    memcpy(box->type, p + 4, 4);
    return size <= avail ? 1 : 0;
}

static int is_type(const rewind_box_t *box, const char *type) {
    return memcmp(box->type, type, 4) == 0;
}

/* finds the first child of the given type inside [p, end) */
static int find_child(const uint8_t *p, const uint8_t *end, const char *type, rewind_box_t *out) {
    rewind_box_t box;
    while (p < end && read_box(p, end, &box) == 1) {
        if (is_type(&box, type)) {
            *out = box;
            return 1;
        }
        p += box.size;
    }
    return 0;
}

static const uint8_t *box_end(const rewind_box_t *box) {
    return box->start + box->size;
}

static rewind_fmp4_status_t parse_moov(rewind_fmp4_t *file, const rewind_box_t *moov) {
    rewind_box_t trak, mdia, mdhd, minf, stbl, stsd, mvex, trex;
    if (!find_child(moov->body, box_end(moov), "trak", &trak) ||
        !find_child(trak.body, box_end(&trak), "mdia", &mdia) ||
        !find_child(mdia.body, box_end(&mdia), "mdhd", &mdhd) ||
        !find_child(mdia.body, box_end(&mdia), "minf", &minf) ||
        !find_child(minf.body, box_end(&minf), "stbl", &stbl) ||
        !find_child(stbl.body, box_end(&stbl), "stsd", &stsd))
        return REWIND_FMP4_INVALID;

    if (box_end(&mdhd) - mdhd.body < 24 || mdhd.body[0] > 1 ||
        (mdhd.body[0] == 1 && box_end(&mdhd) - mdhd.body < 36)) return REWIND_FMP4_INVALID;
    file->timescale = mdhd.body[0] == 1 ? rd32(mdhd.body + 20) : rd32(mdhd.body + 12);
    if (!file->timescale) return REWIND_FMP4_INVALID;
    if (box_end(&stsd) - stsd.body < 44 || rd32(stsd.body + 4) != 1 ||
        rd32(stsd.body + 8) < 36 || rd32(stsd.body + 8) > (uint64_t)(box_end(&stsd) - stsd.body - 8) ||
        memcmp(stsd.body + 12, "mp4a", 4) != 0) return REWIND_FMP4_INVALID;

    file->stsd_len = (size_t)stsd.size;
    file->stsd = malloc(file->stsd_len);
    if (!file->stsd) return REWIND_FMP4_NO_MEMORY;
    memcpy(file->stsd, stsd.start, file->stsd_len);

    if (find_child(moov->body, box_end(moov), "mvex", &mvex) &&
        find_child(mvex.body, box_end(&mvex), "trex", &trex) &&
        box_end(&trex) - trex.body >= 24) {
        file->trex_duration = rd32(trex.body + 12);
        file->trex_size = rd32(trex.body + 16);
    }
    return REWIND_FMP4_OK;
}

static rewind_fmp4_status_t parse_sidx(rewind_fmp4_t *file, const rewind_box_t *sidx,
                                       uint64_t sidx_end_offset) {
    const uint8_t *p = sidx->body;
    const uint8_t *end = box_end(sidx);
    uint64_t first_offset;
    uint64_t offset;
    uint32_t timescale;
    uint64_t earliest;
    size_t count, i;
    if (end - p < 12) return REWIND_FMP4_INVALID;
    if (p[0] > 1) return REWIND_FMP4_INVALID;
    if (p[0] == 0) {
        if (end - p < 24) return REWIND_FMP4_INVALID;
        timescale = rd32(p + 8);
        earliest = rd32(p + 12);
        first_offset = rd32(p + 16);
        p += 20;
    } else {
        if (end - p < 32) return REWIND_FMP4_INVALID;
        timescale = rd32(p + 8);
        earliest = rd64(p + 12);
        first_offset = rd64(p + 20);
        p += 28;
    }
    if (!timescale) return REWIND_FMP4_INVALID;
    count = (size_t)((p[2] << 8) | p[3]);
    p += 4;
    if (!count || count > 2048 || (size_t)(end - p) < count * 12 ||
        first_offset > UINT64_MAX - sidx_end_offset) return REWIND_FMP4_INVALID;

    file->fragment_offsets = calloc(count, sizeof(uint64_t));
    file->fragment_sizes = calloc(count, sizeof(uint64_t));
    file->fragment_durations = calloc(count, sizeof(uint32_t));
    if (!file->fragment_offsets || !file->fragment_sizes || !file->fragment_durations) return REWIND_FMP4_NO_MEMORY;
    file->fragment_count = count;
    file->sidx_timescale = timescale;
    file->sidx_start = earliest;

    offset = sidx_end_offset + first_offset;
    for (i = 0; i < count; ++i, p += 12) {
        uint32_t ref = rd32(p);
        if ((ref & 0x80000000u) || ref < 16 || offset > UINT64_MAX - ref)
            return REWIND_FMP4_INVALID;
        file->fragment_offsets[i] = offset;
        file->fragment_sizes[i] = ref & 0x7fffffffu;
        file->fragment_durations[i] = rd32(p + 4);
        offset += ref & 0x7fffffffu;
    }
    return REWIND_FMP4_OK;
}

rewind_fmp4_status_t rewind_fmp4_open(const uint8_t *head, size_t len, size_t *needed,
                                      rewind_fmp4_t **out) {
    const uint8_t *p = head;
    const uint8_t *end;
    rewind_fmp4_t *file;
    rewind_fmp4_status_t status = REWIND_FMP4_INVALID;
    int have_moov = 0;

    if (out) *out = NULL;
    if (needed) *needed = 0;
    if (!head || !out || len > 1024 * 1024) return REWIND_FMP4_INVALID;
    end = head + len;
    file = calloc(1, sizeof(*file));
    if (!file) return REWIND_FMP4_NO_MEMORY;

    while (p < end) {
        rewind_box_t box;
        int got = read_box(p, end, &box);
        if (got < 0) break;
        if (got == 0) {
            if (box.size > 1024 * 1024 - (size_t)(p - head)) {
                status = REWIND_FMP4_INVALID;
                break;
            }
            if (needed) *needed = (size_t)(p - head) + (size_t)box.size;
            status = REWIND_FMP4_NEED_MORE;
            break;
        }
        if (is_type(&box, "moov")) {
            status = parse_moov(file, &box);
            if (status != REWIND_FMP4_OK) break;
            have_moov = 1;
            status = REWIND_FMP4_INVALID;
        } else if (is_type(&box, "sidx")) {
            if (have_moov) status = parse_sidx(file, &box, (uint64_t)(box_end(&box) - head));
            break;
        } else if (is_type(&box, "moof")) {
            break;
        }
        p += box.size;
    }
    if (p >= end && status == REWIND_FMP4_INVALID) {
        /* the buffer stopped right at a box boundary before the sidx */
        if (needed) *needed = len + 16;
        status = REWIND_FMP4_NEED_MORE;
    }

    if (status != REWIND_FMP4_OK) {
        rewind_fmp4_free(file);
        return status;
    }
    *out = file;
    return REWIND_FMP4_OK;
}

void rewind_fmp4_free(rewind_fmp4_t *file) {
    if (!file) return;
    free(file->stsd);
    free(file->fragment_offsets);
    free(file->fragment_sizes);
    free(file->fragment_durations);
    free(file->sample_sizes);
    free(file->sample_durations);
    free(file->runs);
    free(file->header);
    free(file->chunks);
    free(file);
}

size_t rewind_fmp4_fragment_count(const rewind_fmp4_t *file) {
    return file ? file->fragment_count : 0;
}

uint64_t rewind_fmp4_fragment_offset(const rewind_fmp4_t *file, size_t index) {
    return file && index < file->fragment_count ? file->fragment_offsets[index] : 0;
}

uint64_t rewind_fmp4_fragment_size(const rewind_fmp4_t *file, size_t index) {
    return file && index < file->fragment_count ? file->fragment_sizes[index] : 0;
}

int64_t rewind_fmp4_fragment_start_ms(const rewind_fmp4_t *file, size_t index) {
    uint64_t ticks;
    size_t i;
    if (!file || index > file->fragment_count || !file->sidx_timescale) return -1;
    ticks = file->sidx_start;
    for (i = 0; i < index; ++i) ticks += file->fragment_durations[i];
    if (ticks > UINT64_MAX / 1000) return -1;
    return (int64_t)(ticks * 1000 / file->sidx_timescale);
}

static int reserve_samples(rewind_fmp4_t *file, size_t extra) {
    /* sample tables must stay bounded even when trun uses only default sizes */
    if (extra > 2000000 - file->sample_count) return 0;
    size_t want = file->sample_count + extra;
    if (want <= file->sample_capacity) return 1;
    size_t capacity = file->sample_capacity ? file->sample_capacity : 1024;
    while (capacity < want) capacity *= 2;
    uint32_t *sizes = realloc(file->sample_sizes, capacity * sizeof(uint32_t));
    if (!sizes) return 0;
    file->sample_sizes = sizes;
    uint32_t *durations = realloc(file->sample_durations, capacity * sizeof(uint32_t));
    if (!durations) return 0;
    file->sample_durations = durations;
    file->sample_capacity = capacity;
    return 1;
}

static int add_run(rewind_fmp4_t *file, uint64_t source, uint64_t length, size_t first, size_t count) {
    if (file->run_count &&
        file->runs[file->run_count - 1].source_offset + file->runs[file->run_count - 1].length == source) {
        file->runs[file->run_count - 1].length += length;
        file->runs[file->run_count - 1].sample_count += count;
        return 1;
    }
    if (file->run_count == file->run_capacity) {
        size_t capacity = file->run_capacity ? file->run_capacity * 2 : 64;
        rewind_run_t *runs = realloc(file->runs, capacity * sizeof(rewind_run_t));
        if (!runs) return 0;
        file->runs = runs;
        file->run_capacity = capacity;
    }
    file->runs[file->run_count].source_offset = source;
    file->runs[file->run_count].length = length;
    file->runs[file->run_count].first_sample = first;
    file->runs[file->run_count].sample_count = count;
    ++file->run_count;
    return 1;
}

static rewind_fmp4_status_t parse_traf(rewind_fmp4_t *file, const rewind_box_t *traf,
                                       uint64_t moof_offset, uint64_t fragment_end) {
    rewind_box_t tfhd, box;
    const uint8_t *p, *end;
    uint32_t flags;
    uint64_t base = moof_offset;
    uint32_t default_duration = file->trex_duration;
    uint32_t default_size = file->trex_size;
    uint64_t next_data;

    if (!find_child(traf->body, box_end(traf), "tfhd", &tfhd)) return REWIND_FMP4_INVALID;
    p = tfhd.body;
    end = box_end(&tfhd);
    if (end - p < 8) return REWIND_FMP4_INVALID;
    flags = rd32(p) & 0xffffff;
    p += 8;
    if (flags & 0x1) {
        if (end - p < 8) return REWIND_FMP4_INVALID;
        base = rd64(p);
        p += 8;
    }
    if (flags & 0x2) {
        if (end - p < 4) return REWIND_FMP4_INVALID;
        p += 4;
    }
    if (flags & 0x8) {
        if (end - p < 4) return REWIND_FMP4_INVALID;
        default_duration = rd32(p);
        p += 4;
    }
    if (flags & 0x10) {
        if (end - p < 4) return REWIND_FMP4_INVALID;
        default_size = rd32(p);
        p += 4;
    }
    next_data = base;

    p = traf->body;
    end = box_end(traf);
    while (p < end && read_box(p, end, &box) == 1) {
        if (is_type(&box, "trun")) {
            const uint8_t *q = box.body;
            const uint8_t *qend = box_end(&box);
            uint32_t tflags, count, i;
            uint64_t data = next_data;
            uint64_t length = 0;
            size_t first = file->sample_count;
            size_t per_sample;
            if (qend - q < 8) return REWIND_FMP4_INVALID;
            tflags = rd32(q) & 0xffffff;
            count = rd32(q + 4);
            q += 8;
            if (tflags & 0x1) {
                if (qend - q < 4) return REWIND_FMP4_INVALID;
                int64_t relative = (int32_t)rd32(q);
                if ((relative < 0 && base < (uint64_t)-relative) ||
                    (relative > 0 && base > UINT64_MAX - (uint64_t)relative)) return REWIND_FMP4_INVALID;
                data = relative < 0 ? base - (uint64_t)-relative : base + (uint64_t)relative;
                q += 4;
            }
            if (tflags & 0x4) {
                if (qend - q < 4) return REWIND_FMP4_INVALID;
                q += 4;
            }
            per_sample = ((tflags & 0x100) ? 4 : 0) + ((tflags & 0x200) ? 4 : 0) +
                         ((tflags & 0x400) ? 4 : 0) + ((tflags & 0x800) ? 4 : 0);
            if (q > qend || (uint64_t)(qend - q) < (uint64_t)count * per_sample) return REWIND_FMP4_INVALID;
            if (count > 2000000 - file->sample_count) return REWIND_FMP4_INVALID;
            if (!reserve_samples(file, count)) return REWIND_FMP4_NO_MEMORY;
            for (i = 0; i < count; ++i) {
                uint32_t duration = default_duration;
                uint32_t size = default_size;
                if (tflags & 0x100) { duration = rd32(q); q += 4; }
                if (tflags & 0x200) { size = rd32(q); q += 4; }
                if (tflags & 0x400) q += 4;
                if (tflags & 0x800) q += 4;
                if (!size || !duration) return REWIND_FMP4_INVALID;
                file->sample_sizes[file->sample_count] = size;
                file->sample_durations[file->sample_count] = duration;
                ++file->sample_count;
                file->total_duration += duration;
                length += size;
            }
            if (data < moof_offset || data > fragment_end || length > fragment_end - data)
                return REWIND_FMP4_INVALID;
            if (count && !add_run(file, data, length, first, count)) return REWIND_FMP4_NO_MEMORY;
            next_data = data + length;
        }
        p += box.size;
    }
    return REWIND_FMP4_OK;
}

rewind_fmp4_status_t rewind_fmp4_add_fragment(rewind_fmp4_t *file, size_t index,
                                              const uint8_t *buf, size_t len, size_t *needed) {
    rewind_box_t moof, traf;
    uint64_t offset, fragment_end;
    const uint8_t *p, *end;
    int got, found = 0;
    if (needed) *needed = 0;
    if (!file || !buf || index != file->next_fragment || index >= file->fragment_count)
        return REWIND_FMP4_INVALID;

    got = read_box(buf, buf + len, &moof);
    if (got < 0) return REWIND_FMP4_INVALID;
    if (got == 0) {
        if (moof.size > 1024 * 1024 || moof.size > file->fragment_sizes[index])
            return REWIND_FMP4_INVALID;
        if (needed) *needed = (size_t)moof.size;
        return REWIND_FMP4_NEED_MORE;
    }
    if (!is_type(&moof, "moof")) return REWIND_FMP4_INVALID;

    offset = file->fragment_offsets[index];
    fragment_end = offset + file->fragment_sizes[index];
    p = moof.body;
    end = box_end(&moof);
    while (p < end && find_child(p, end, "traf", &traf)) {
        rewind_fmp4_status_t status = parse_traf(file, &traf, offset, fragment_end);
        if (status != REWIND_FMP4_OK) return status;
        found = 1;
        p = box_end(&traf);
    }
    if (!found) return REWIND_FMP4_INVALID;
    ++file->next_fragment;
    return REWIND_FMP4_OK;
}

size_t rewind_fmp4_probe_box_size(const uint8_t *buf, size_t len) {
    rewind_box_t box;
    if (!buf || read_box(buf, buf + len, &box) < 0) return 0;
    return (size_t)box.size;
}

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
    int failed;
} rewind_buf_t;

static void put(rewind_buf_t *b, const void *src, size_t n) {
    if (b->failed) return;
    if (b->len + n > b->cap) {
        size_t cap = b->cap ? b->cap : 4096;
        while (cap < b->len + n) cap *= 2;
        uint8_t *data = realloc(b->data, cap);
        if (!data) {
            b->failed = 1;
            return;
        }
        b->data = data;
        b->cap = cap;
    }
    memcpy(b->data + b->len, src, n);
    b->len += n;
}

static void put32(rewind_buf_t *b, uint32_t v) {
    uint8_t x[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    put(b, x, 4);
}

static void put16(rewind_buf_t *b, uint16_t v) {
    uint8_t x[2] = { (uint8_t)(v >> 8), (uint8_t)v };
    put(b, x, 2);
}

static void put_zero(rewind_buf_t *b, size_t n) {
    static const uint8_t zeros[32];
    while (n) {
        size_t step = n < sizeof(zeros) ? n : sizeof(zeros);
        put(b, zeros, step);
        n -= step;
    }
}

static size_t open_box(rewind_buf_t *b, const char *type) {
    size_t at = b->len;
    put32(b, 0);
    put(b, type, 4);
    return at;
}

static void close_box(rewind_buf_t *b, size_t at) {
    uint32_t size = (uint32_t)(b->len - at);
    if (b->failed) return;
    b->data[at] = (uint8_t)(size >> 24);
    b->data[at + 1] = (uint8_t)(size >> 16);
    b->data[at + 2] = (uint8_t)(size >> 8);
    b->data[at + 3] = (uint8_t)size;
}

static void put_matrix(rewind_buf_t *b) {
    put32(b, 0x00010000); put32(b, 0); put32(b, 0);
    put32(b, 0); put32(b, 0x00010000); put32(b, 0);
    put32(b, 0); put32(b, 0); put32(b, 0x40000000);
}

int rewind_fmp4_truncate(rewind_fmp4_t *file, size_t count) {
    if (!file || !count || count > file->fragment_count || file->next_fragment != count) return 0;
    file->fragment_count = count;
    return 1;
}

rewind_fmp4_status_t rewind_fmp4_finish(rewind_fmp4_t *file) {
    rewind_buf_t b = { NULL, 0, 0, 0 };
    size_t moov, trak, mdia, minf, stbl, box, i;
    size_t stts_count_at, stsc_count_at, stco_at;
    uint32_t stts_entries = 0, stsc_entries = 0;
    uint32_t duration;
    uint64_t payload = 0, position;

    if (!file || file->next_fragment != file->fragment_count || !file->run_count)
        return REWIND_FMP4_INVALID;
    for (i = 0; i < file->run_count; ++i) payload += file->runs[i].length;
    if (file->total_duration > 0xffffffffu || payload > 0xffffffffu - 8) return REWIND_FMP4_INVALID;
    duration = (uint32_t)file->total_duration;

    box = open_box(&b, "ftyp");
    put(&b, "M4A ", 4); put32(&b, 0);
    put(&b, "M4A ", 4); put(&b, "mp42", 4); put(&b, "isom", 4);
    close_box(&b, box);

    moov = open_box(&b, "moov");
    box = open_box(&b, "mvhd");
    put32(&b, 0); put32(&b, 0); put32(&b, 0);
    put32(&b, file->timescale); put32(&b, duration);
    put32(&b, 0x00010000); put16(&b, 0x0100); put_zero(&b, 10);
    put_matrix(&b);
    put_zero(&b, 24);
    put32(&b, 2);
    close_box(&b, box);

    trak = open_box(&b, "trak");
    box = open_box(&b, "tkhd");
    put32(&b, 0x00000007); put32(&b, 0); put32(&b, 0);
    put32(&b, 1); put32(&b, 0); put32(&b, duration);
    put_zero(&b, 8); put16(&b, 0); put16(&b, 0); put16(&b, 0x0100); put16(&b, 0);
    put_matrix(&b);
    put32(&b, 0); put32(&b, 0);
    close_box(&b, box);

    mdia = open_box(&b, "mdia");
    box = open_box(&b, "mdhd");
    put32(&b, 0); put32(&b, 0); put32(&b, 0);
    put32(&b, file->timescale); put32(&b, duration);
    put16(&b, 0x55c4); put16(&b, 0);
    close_box(&b, box);
    box = open_box(&b, "hdlr");
    put32(&b, 0); put32(&b, 0); put(&b, "soun", 4); put_zero(&b, 12);
    put(&b, "SoundHandler", 13);
    close_box(&b, box);

    minf = open_box(&b, "minf");
    box = open_box(&b, "smhd");
    put32(&b, 0); put32(&b, 0);
    close_box(&b, box);
    {
        size_t dinf = open_box(&b, "dinf");
        size_t dref = open_box(&b, "dref");
        put32(&b, 0); put32(&b, 1);
        box = open_box(&b, "url ");
        put32(&b, 1);
        close_box(&b, box);
        close_box(&b, dref);
        close_box(&b, dinf);
    }

    stbl = open_box(&b, "stbl");
    put(&b, file->stsd, file->stsd_len);

    box = open_box(&b, "stts");
    put32(&b, 0);
    stts_count_at = b.len;
    put32(&b, 0);
    for (i = 0; i < file->sample_count;) {
        size_t j = i;
        while (j < file->sample_count && file->sample_durations[j] == file->sample_durations[i]) ++j;
        put32(&b, (uint32_t)(j - i)); put32(&b, file->sample_durations[i]);
        ++stts_entries;
        i = j;
    }
    close_box(&b, box);

    box = open_box(&b, "stsc");
    put32(&b, 0);
    stsc_count_at = b.len;
    put32(&b, 0);
    for (i = 0; i < file->run_count; ++i) {
        if (i && file->runs[i].sample_count == file->runs[i - 1].sample_count) continue;
        put32(&b, (uint32_t)(i + 1)); put32(&b, (uint32_t)file->runs[i].sample_count); put32(&b, 1);
        ++stsc_entries;
    }
    close_box(&b, box);

    box = open_box(&b, "stsz");
    put32(&b, 0); put32(&b, 0); put32(&b, (uint32_t)file->sample_count);
    for (i = 0; i < file->sample_count; ++i) put32(&b, file->sample_sizes[i]);
    close_box(&b, box);

    box = open_box(&b, "stco");
    put32(&b, 0); put32(&b, (uint32_t)file->run_count);
    stco_at = b.len;
    put_zero(&b, file->run_count * 4);
    close_box(&b, box);

    close_box(&b, stbl);
    close_box(&b, minf);
    close_box(&b, mdia);
    close_box(&b, trak);
    close_box(&b, moov);

    put32(&b, (uint32_t)(payload + 8));
    put(&b, "mdat", 4);
    if (b.failed) {
        free(b.data);
        return REWIND_FMP4_NO_MEMORY;
    }
    if (payload > UINT32_MAX - b.len) {
        free(b.data);
        return REWIND_FMP4_INVALID;
    }

    b.data[stts_count_at] = (uint8_t)(stts_entries >> 24);
    b.data[stts_count_at + 1] = (uint8_t)(stts_entries >> 16);
    b.data[stts_count_at + 2] = (uint8_t)(stts_entries >> 8);
    b.data[stts_count_at + 3] = (uint8_t)stts_entries;
    b.data[stsc_count_at] = (uint8_t)(stsc_entries >> 24);
    b.data[stsc_count_at + 1] = (uint8_t)(stsc_entries >> 16);
    b.data[stsc_count_at + 2] = (uint8_t)(stsc_entries >> 8);
    b.data[stsc_count_at + 3] = (uint8_t)stsc_entries;

    free(file->chunks);
    file->chunks = calloc(file->run_count, sizeof(rewind_fmp4_chunk_t));
    if (!file->chunks) {
        free(b.data);
        return REWIND_FMP4_NO_MEMORY;
    }
    position = b.len;
    for (i = 0; i < file->run_count; ++i) {
        uint8_t *at = b.data + stco_at + i * 4;
        at[0] = (uint8_t)(position >> 24);
        at[1] = (uint8_t)(position >> 16);
        at[2] = (uint8_t)(position >> 8);
        at[3] = (uint8_t)position;
        file->chunks[i].source_offset = file->runs[i].source_offset;
        file->chunks[i].output_offset = position;
        file->chunks[i].length = file->runs[i].length;
        position += file->runs[i].length;
    }

    free(file->header);
    file->header = b.data;
    file->header_len = b.len;
    file->output_size = position;
    return REWIND_FMP4_OK;
}

const uint8_t *rewind_fmp4_header(const rewind_fmp4_t *file, size_t *len) {
    if (len) *len = file ? file->header_len : 0;
    return file ? file->header : NULL;
}

uint64_t rewind_fmp4_output_size(const rewind_fmp4_t *file) {
    return file ? file->output_size : 0;
}

size_t rewind_fmp4_chunk_count(const rewind_fmp4_t *file) {
    return file && file->chunks ? file->run_count : 0;
}

const rewind_fmp4_chunk_t *rewind_fmp4_chunk(const rewind_fmp4_t *file, size_t index) {
    return file && file->chunks && index < file->run_count ? &file->chunks[index] : NULL;
}

double rewind_fmp4_duration(const rewind_fmp4_t *file) {
    return file && file->timescale ? (double)file->total_duration / file->timescale : 0.0;
}
