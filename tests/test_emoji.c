#include "test_util.h"
#include "rewind_emoji.h"

/* utf-16 literals through code points keep the test independent of the compiler's source charset */
static size_t units(uint16_t *out, const uint32_t *points, size_t count) {
    size_t i, n = 0;
    for (i = 0; i < count; ++i) {
        uint32_t p = points[i];
        if (p >= 0x10000u) {
            p -= 0x10000u;
            out[n++] = (uint16_t)(0xD800u + (p >> 10));
            out[n++] = (uint16_t)(0xDC00u + (p & 0x3FFu));
        } else {
            out[n++] = (uint16_t)p;
        }
    }
    return n;
}

static size_t scan_points(const uint32_t *points, size_t count, rewind_emoji_span *spans, size_t cap, size_t *length) {
    uint16_t text[64];
    size_t n = units(text, points, count);
    if (length) *length = n;
    return rewind_emoji_scan(text, n, spans, cap);
}

static void test_find(void) {
    const uint32_t grin[] = {0x1F600}, none[] = {0x1F600, 0x1F600}, heart[] = {0x2764, 0xFE0F}, bare[] = {0x2764};
    size_t index = 0, other = 0;
    CHECK(rewind_emoji_find(grin, 1, &index));
    CHECK_EQ_INT(rewind_emoji_entries[index].status, REWIND_EMOJI_STATUS_FULL);
    CHECK_EQ_INT(rewind_emoji_entries[index].version, 10);
    CHECK_EQ_INT(rewind_emoji_entries[index].canonical, index);
    CHECK(!rewind_emoji_find(none, 2, &index));
    CHECK(!rewind_emoji_find(grin, 0, &index));
    CHECK(!rewind_emoji_find(NULL, 1, &index));
    CHECK(rewind_emoji_find(heart, 2, &index));
    CHECK(rewind_emoji_find(bare, 1, &other));
    CHECK_EQ_INT(rewind_emoji_entries[other].status, REWIND_EMOJI_STATUS_BARE);
    CHECK_EQ_INT(rewind_emoji_entries[other].canonical, index);
}

static void test_scan_basic(void) {
    rewind_emoji_span spans[8];
    uint16_t text[16] = {'H', 'i', ' '};
    const uint32_t grin[] = {0x1F600};
    size_t n = units(text + 3, grin, 1);
    text[3 + n] = '!';
    CHECK_EQ_INT(rewind_emoji_scan(text, 3 + n + 1, spans, 8), 1);
    CHECK_EQ_INT(spans[0].start, 3);
    CHECK_EQ_INT(spans[0].length, 2);
    CHECK_EQ_INT(rewind_emoji_scan(text, 3, spans, 8), 0);
    CHECK_EQ_INT(rewind_emoji_scan(NULL, 3, spans, 8), 0);
    CHECK_EQ_INT(rewind_emoji_scan(text, 0, spans, 8), 0);
    CHECK_EQ_INT(rewind_emoji_scan(text, 3 + n + 1, spans, 0), 0);
}

static void test_sequences(void) {
    rewind_emoji_span spans[8];
    size_t length;
    /* two flags are two spans, a lone regional indicator is nothing */
    const uint32_t flags[] = {0x1F1FA, 0x1F1F8, 0x1F1F7, 0x1F1FA};
    const uint32_t lone[] = {0x1F1FA};
    const uint32_t keycap[] = {0x31, 0xFE0F, 0x20E3};
    const uint32_t family[] = {0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467};
    const uint32_t tone[] = {0x1F44D, 0x1F3FD};
    const uint32_t text_sign[] = {0xA9, 0x20, 0xAE, 0x20, 0x2122};
    const uint32_t emoji_sign[] = {0xA9, 0xFE0F};
    const uint32_t digits[] = {0x31, 0x32, 0x23, 0x2A};
    CHECK_EQ_INT(scan_points(flags, 4, spans, 8, &length), 2);
    CHECK_EQ_INT(spans[0].length, 4);
    CHECK_EQ_INT(spans[1].start, 4);
    CHECK_EQ_INT(scan_points(lone, 1, spans, 8, NULL), 0);
    CHECK_EQ_INT(scan_points(keycap, 3, spans, 8, &length), 1);
    CHECK_EQ_INT(spans[0].length, 3);
    CHECK_EQ_INT(scan_points(family, 5, spans, 8, &length), 1);
    CHECK_EQ_INT(spans[0].length, length);
    CHECK_EQ_INT(scan_points(tone, 2, spans, 8, &length), 1);
    CHECK_EQ_INT(spans[0].length, 4);
    CHECK_EQ_INT(rewind_emoji_entries[spans[0].entry].tone, 1);
    CHECK_EQ_INT(scan_points(text_sign, 5, spans, 8, NULL), 0);
    CHECK_EQ_INT(scan_points(emoji_sign, 2, spans, 8, NULL), 1);
    CHECK_EQ_INT(scan_points(digits, 4, spans, 8, NULL), 0);
}

static void test_bare_heart_and_cap(void) {
    rewind_emoji_span spans[3];
    const uint32_t bare[] = {0x2764, 0x2764, 0x2764, 0x2764};
    CHECK_EQ_INT(scan_points(bare, 4, spans, 3, NULL), 3);
    /* a bare heart draws as the fully qualified one */
    CHECK_EQ_INT(rewind_emoji_entries[spans[0].entry].status, REWIND_EMOJI_STATUS_FULL);
    CHECK_EQ_INT(spans[0].entry, spans[1].entry);
}

static void test_lone_surrogates(void) {
    rewind_emoji_span spans[4];
    uint16_t text[8] = {0xD83D, 'a', 0xDE00, 0xD83D, 0xDE00};
    /* the first two halves are alone; the pair at the end is the grinning face */
    CHECK_EQ_INT(rewind_emoji_scan(text, 5, spans, 4), 1);
    CHECK_EQ_INT(spans[0].start, 3);
    CHECK_EQ_INT(spans[0].length, 2);
    text[0] = 0xD83D;
    CHECK_EQ_INT(rewind_emoji_scan(text, 1, spans, 4), 0);
}

/* every sequence the table knows must come back as one span of its own length, which proves the table is sorted
   for the search and the scanner and the encoder agree */
static void test_every_entry(void) {
    size_t i;
    for (i = 0; i < rewind_emoji_entry_count; ++i) {
        const rewind_emoji_entry *e = &rewind_emoji_entries[i];
        uint16_t text[40];
        rewind_emoji_span span;
        size_t n = rewind_emoji_encode(i, text, 40);
        size_t found = rewind_emoji_scan(text, n, &span, 1);
        uint32_t first = rewind_emoji_points[e->offset];
        int expected = !(e->status == REWIND_EMOJI_STATUS_BARE && e->length == 1 && (first < 0x80u || first == 0xA9u || first == 0xAEu || first == 0x2122u));
        CHECK(n > 0);
        CHECK_EQ_INT(found, expected ? 1 : 0);
        if (found) {
            CHECK_EQ_INT(span.start, 0);
            CHECK_EQ_INT(span.length, n);
            CHECK_EQ_INT(span.entry, e->canonical);
        }
        CHECK_EQ_INT(rewind_emoji_entries[e->canonical].status, REWIND_EMOJI_STATUS_FULL);
        CHECK(e->length <= rewind_emoji_longest);
    }
}

static void test_picker_and_images(void) {
    size_t i, group;
    CHECK_EQ_INT(rewind_emoji_group_start[0], 0);
    CHECK_EQ_INT(rewind_emoji_group_start[REWIND_EMOJI_GROUPS], rewind_emoji_picker_count);
    for (group = 0; group < REWIND_EMOJI_GROUPS; ++group) CHECK(rewind_emoji_group_start[group] < rewind_emoji_group_start[group + 1]);
    for (i = 0; i < rewind_emoji_picker_count; ++i) {
        const rewind_emoji_entry *e = &rewind_emoji_entries[rewind_emoji_picker[i]];
        CHECK_EQ_INT(e->status, REWIND_EMOJI_STATUS_FULL);
        CHECK_EQ_INT(e->tone, 0);
    }
    for (i = 0; i < rewind_emoji_entry_count; ++i) {
        const rewind_emoji_entry *e = &rewind_emoji_entries[i];
        if (e->image != REWIND_EMOJI_NO_IMAGE) {
            CHECK(e->image < rewind_emoji_image_count);
            CHECK_EQ_INT(e->status, REWIND_EMOJI_STATUS_FULL);
        } else {
            /* the app draws one set on every system, so only a form that is not canonical goes without its own picture */
            CHECK(e->status != REWIND_EMOJI_STATUS_FULL);
        }
    }
    CHECK_EQ_INT(rewind_emoji_encode(0, NULL, 4), 0);
    CHECK_EQ_INT(rewind_emoji_encode(rewind_emoji_entry_count, (uint16_t[4]){0}, 4), 0);
    CHECK_EQ_INT(rewind_emoji_encode(0, (uint16_t[1]){0}, 0), 0);
}

static void test_single_emoji(void) {
    static const uint32_t sequences[][8] = {
        {0x1F62D}, {0x2764, 0xFE0F}, {0x1F44D, 0x1F3FD},
        {0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467},
        {0x1F1F7, 0x1F1FA}, {'1', 0xFE0F, 0x20E3}
    };
    const size_t lengths[] = {1, 2, 2, 5, 2, 3};
    uint16_t text[64];
    for (size_t i = 0; i < sizeof(lengths) / sizeof(lengths[0]); ++i) {
        size_t length = units(text, sequences[i], lengths[i]), entry = 0;
        CHECK(rewind_emoji_single(text, length, &entry));
        CHECK(entry < rewind_emoji_entry_count);
        CHECK_EQ_INT(rewind_emoji_entries[entry].status, REWIND_EMOJI_STATUS_FULL);
        text[length] = ' ';
        CHECK(!rewind_emoji_single(text, length + 1, &entry));
        CHECK_EQ_INT(entry, 0);
        text[length] = 'x';
        CHECK(!rewind_emoji_single(text, length + 1, &entry));
    }
    size_t entry = 99;
    size_t length = units(text, (const uint32_t[]){0x1F600, 0x1F600}, 2);
    CHECK(!rewind_emoji_single(text, length, &entry));
    CHECK_EQ_INT(entry, 0);
    CHECK(!rewind_emoji_single(NULL, 0, &entry));
    CHECK(!rewind_emoji_single(text, 0, &entry));
    CHECK(!rewind_emoji_single(text, length, NULL));
    CHECK(!rewind_emoji_single((const uint16_t[]){0xD83D}, 1, &entry));
    CHECK(!rewind_emoji_single((const uint16_t[]){'1'}, 1, &entry));
    CHECK(!rewind_emoji_single((const uint16_t[]){0xA9}, 1, &entry));
}

int main(void) {
    test_single_emoji();
    test_find();
    test_scan_basic();
    test_sequences();
    test_bare_heart_and_cap();
    test_lone_surrogates();
    test_every_entry();
    test_picker_and_images();
    if (g_failures) {
        fprintf(stderr, "test_emoji: %d of %d checks failed\n", g_failures, g_checks);
        return 1;
    }
    printf("test_emoji: %d checks passed\n", g_checks);
    return 0;
}
