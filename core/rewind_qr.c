#include "rewind_qr.h"

#include <string.h>

/* iso 18004 tables for versions 1 to 10, indexed [ecc][version] */
static const unsigned char ecc_codewords_per_block[4][REWIND_QR_MAX_VERSION + 1] = {
    { 0,  7, 10, 15, 20, 26, 18, 20, 24, 30, 18 },
    { 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26 },
    { 0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24 },
    { 0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28 },
};

static const unsigned char ecc_block_count[4][REWIND_QR_MAX_VERSION + 1] = {
    { 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4 },
    { 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5 },
    { 0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8 },
    { 0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8 },
};

/* format information stores the levels in this order, not in l m q h order */
static const int ecc_format_bits[4] = { 1, 0, 3, 2 };

/* version 10 has 346 raw codewords */
#define QR_MAX_CODEWORDS 346

typedef struct {
    int size;
    unsigned char dark[REWIND_QR_MAX_SIZE][REWIND_QR_MAX_SIZE];
    unsigned char function[REWIND_QR_MAX_SIZE][REWIND_QR_MAX_SIZE];
} qr_grid_t;

static int raw_data_modules(int version) {
    int result = (16 * version + 128) * version + 64;
    if (version >= 2) {
        int align = version / 7 + 2;
        result -= (25 * align - 10) * align - 55;
        if (version >= 7) result -= 36;
    }
    return result;
}

static int data_codewords(int version, int ecc) {
    return raw_data_modules(version) / 8 -
        ecc_codewords_per_block[ecc][version] * ecc_block_count[ecc][version];
}

static int alignment_positions(int version, int size, int out[7]) {
    int count, step, i, pos;
    if (version == 1) return 0;
    count = version / 7 + 2;
    step = (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2;
    out[0] = 6;
    for (i = count - 1, pos = size - 7; i >= 1; --i, pos -= step) out[i] = pos;
    return count;
}

static void set_function(qr_grid_t *g, int x, int y, int dark) {
    g->dark[y][x] = (unsigned char)(dark ? 1 : 0);
    g->function[y][x] = 1;
}

static void draw_finder(qr_grid_t *g, int cx, int cy) {
    int dx, dy;
    for (dy = -4; dy <= 4; ++dy) {
        for (dx = -4; dx <= 4; ++dx) {
            int x = cx + dx, y = cy + dy;
            int ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
            int dist = ax > ay ? ax : ay;
            if (x < 0 || y < 0 || x >= g->size || y >= g->size) continue;
            set_function(g, x, y, dist != 2 && dist != 4);
        }
    }
}

static void draw_alignment(qr_grid_t *g, int cx, int cy) {
    int dx, dy;
    for (dy = -2; dy <= 2; ++dy) {
        for (dx = -2; dx <= 2; ++dx) {
            int ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
            set_function(g, cx + dx, cy + dy, (ax > ay ? ax : ay) != 1);
        }
    }
}

static void draw_format(qr_grid_t *g, int ecc, int mask) {
    int data = (ecc_format_bits[ecc] << 3) | mask;
    int rem = data, bits, i, size = g->size;
    for (i = 0; i < 10; ++i) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    bits = ((data << 10) | rem) ^ 0x5412;

    for (i = 0; i <= 5; ++i) set_function(g, 8, i, (bits >> i) & 1);
    set_function(g, 8, 7, (bits >> 6) & 1);
    set_function(g, 8, 8, (bits >> 7) & 1);
    set_function(g, 7, 8, (bits >> 8) & 1);
    for (i = 9; i < 15; ++i) set_function(g, 14 - i, 8, (bits >> i) & 1);

    for (i = 0; i < 8; ++i) set_function(g, size - 1 - i, 8, (bits >> i) & 1);
    for (i = 8; i < 15; ++i) set_function(g, 8, size - 15 + i, (bits >> i) & 1);
    set_function(g, 8, size - 8, 1);
}

static void draw_version(qr_grid_t *g, int version) {
    long rem = version, bits;
    int i;
    if (version < 7) return;
    for (i = 0; i < 12; ++i) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    bits = ((long)version << 12) | rem;
    for (i = 0; i < 18; ++i) {
        int bit = (int)((bits >> i) & 1);
        int a = g->size - 11 + i % 3, b = i / 3;
        set_function(g, a, b, bit);
        set_function(g, b, a, bit);
    }
}

static void draw_function_patterns(qr_grid_t *g, int version, int ecc) {
    int pos[7], count, i, j;
    for (i = 0; i < g->size; ++i) {
        set_function(g, 6, i, i % 2 == 0);
        set_function(g, i, 6, i % 2 == 0);
    }
    draw_finder(g, 3, 3);
    draw_finder(g, g->size - 4, 3);
    draw_finder(g, 3, g->size - 4);
    count = alignment_positions(version, g->size, pos);
    for (i = 0; i < count; ++i) {
        for (j = 0; j < count; ++j) {
            if ((i == 0 && j == 0) || (i == 0 && j == count - 1) || (i == count - 1 && j == 0))
                continue;
            draw_alignment(g, pos[i], pos[j]);
        }
    }
    /* reserve the format area now; the real bits go in once the mask is known */
    draw_format(g, ecc, 0);
    draw_version(g, version);
}

static unsigned char gf_multiply(unsigned char x, unsigned char y) {
    int z = 0, i;
    for (i = 7; i >= 0; --i) {
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= ((y >> i) & 1) * x;
    }
    return (unsigned char)z;
}

static void rs_divisor(int degree, unsigned char *out) {
    unsigned char root = 1;
    int i, j;
    memset(out, 0, (size_t)degree);
    out[degree - 1] = 1;
    for (i = 0; i < degree; ++i) {
        for (j = 0; j < degree; ++j) {
            out[j] = gf_multiply(out[j], root);
            if (j + 1 < degree) out[j] ^= out[j + 1];
        }
        root = gf_multiply(root, 0x02);
    }
}

static void rs_remainder(const unsigned char *data, int len, const unsigned char *divisor,
                         int degree, unsigned char *out) {
    int i, j;
    memset(out, 0, (size_t)degree);
    for (i = 0; i < len; ++i) {
        unsigned char factor = (unsigned char)(data[i] ^ out[0]);
        memmove(out, out + 1, (size_t)(degree - 1));
        out[degree - 1] = 0;
        for (j = 0; j < degree; ++j) out[j] ^= gf_multiply(divisor[j], factor);
    }
}

static void append_bits(unsigned char *buf, int *bit_len, unsigned value, int count) {
    int i;
    for (i = count - 1; i >= 0; --i) {
        if ((value >> i) & 1) buf[*bit_len >> 3] |= (unsigned char)(0x80 >> (*bit_len & 7));
        ++*bit_len;
    }
}

/* data codewords in, interleaved data plus ecc codewords out */
static int add_ecc(const unsigned char *data, int version, int ecc, unsigned char *out) {
    int blocks = ecc_block_count[ecc][version];
    int block_ecc = ecc_codewords_per_block[ecc][version];
    int raw = raw_data_modules(version) / 8;
    int short_blocks = blocks - raw % blocks;
    int short_len = raw / blocks - block_ecc;
    unsigned char divisor[30];
    unsigned char ecc_bytes[8][30];
    int offsets[8];
    int b, i, n = 0, off = 0;

    rs_divisor(block_ecc, divisor);
    for (b = 0; b < blocks; ++b) {
        int len = short_len + (b >= short_blocks ? 1 : 0);
        offsets[b] = off;
        rs_remainder(data + off, len, divisor, block_ecc, ecc_bytes[b]);
        off += len;
    }
    for (i = 0; i <= short_len; ++i) {
        for (b = 0; b < blocks; ++b) {
            int len = short_len + (b >= short_blocks ? 1 : 0);
            if (i < len) out[n++] = data[offsets[b] + i];
        }
    }
    for (i = 0; i < block_ecc; ++i)
        for (b = 0; b < blocks; ++b) out[n++] = ecc_bytes[b][i];
    return n;
}

static void draw_codewords(qr_grid_t *g, const unsigned char *words, int count) {
    int bit = 0, right, vert, j;
    for (right = g->size - 1; right >= 1; right -= 2) {
        if (right == 6) right = 5;
        for (vert = 0; vert < g->size; ++vert) {
            for (j = 0; j < 2; ++j) {
                int x = right - j;
                int upward = ((right + 1) & 2) == 0;
                int y = upward ? g->size - 1 - vert : vert;
                if (g->function[y][x] || bit >= count * 8) continue;
                g->dark[y][x] = (unsigned char)((words[bit >> 3] >> (7 - (bit & 7))) & 1);
                ++bit;
            }
        }
    }
}

static int mask_hit(int mask, int x, int y) {
    switch (mask) {
        case 0: return (x + y) % 2 == 0;
        case 1: return y % 2 == 0;
        case 2: return x % 3 == 0;
        case 3: return (x + y) % 3 == 0;
        case 4: return (x / 3 + y / 2) % 2 == 0;
        case 5: return x * y % 2 + x * y % 3 == 0;
        case 6: return (x * y % 2 + x * y % 3) % 2 == 0;
        default: return ((x + y) % 2 + x * y % 3) % 2 == 0;
    }
}

static void apply_mask(qr_grid_t *g, int mask) {
    int x, y;
    for (y = 0; y < g->size; ++y)
        for (x = 0; x < g->size; ++x)
            if (!g->function[y][x] && mask_hit(mask, x, y)) g->dark[y][x] ^= 1;
}

static int module_at(const qr_grid_t *g, int x, int y, int column) {
    return column ? g->dark[x][y] : g->dark[y][x];
}

/* 1:3:1:1:1 finder shape with four light modules on either side */
static int finder_like(const qr_grid_t *g, int line, int start, int column) {
    static const unsigned char core[7] = { 1, 0, 1, 1, 1, 0, 1 };
    int i, before = 1, after = 1;
    for (i = 0; i < 7; ++i)
        if (module_at(g, start + i, line, column) != core[i]) return 0;
    for (i = 1; i <= 4; ++i) {
        int b = start - i, a = start + 6 + i;
        if (b >= 0 && module_at(g, b, line, column)) before = 0;
        if (a < g->size && module_at(g, a, line, column)) after = 0;
    }
    return before || after;
}

static long penalty(const qr_grid_t *g) {
    long score = 0;
    int size = g->size, line, i, x, y, dark = 0, column;
    for (column = 0; column < 2; ++column) {
        for (line = 0; line < size; ++line) {
            int run = 1;
            for (i = 1; i <= size; ++i) {
                if (i < size && module_at(g, i, line, column) == module_at(g, i - 1, line, column)) {
                    ++run;
                    continue;
                }
                if (run >= 5) score += 3 + (run - 5);
                run = 1;
            }
            for (i = 0; i + 7 <= size; ++i)
                if (finder_like(g, line, i, column)) score += 40;
        }
    }
    for (y = 0; y + 1 < size; ++y) {
        for (x = 0; x + 1 < size; ++x) {
            int c = g->dark[y][x];
            if (c == g->dark[y][x + 1] && c == g->dark[y + 1][x] && c == g->dark[y + 1][x + 1])
                score += 3;
        }
    }
    for (y = 0; y < size; ++y)
        for (x = 0; x < size; ++x) dark += g->dark[y][x];
    {
        long total = (long)size * size;
        long diff = (long)dark * 20 - total * 10;
        long k;
        if (diff < 0) diff = -diff;
        k = (diff + total - 1) / total - 1;
        if (k > 0) score += k * 10;
    }
    return score;
}

rewind_qr_status_t rewind_qr_encode(const unsigned char *data, size_t len,
                                    rewind_qr_ecc_t ecc, int mask, rewind_qr_t *out) {
    unsigned char codewords[QR_MAX_CODEWORDS];
    unsigned char final_words[QR_MAX_CODEWORDS];
    qr_grid_t grid, best;
    int version, capacity_bits = 0, count_bits, bit_len = 0, words, i, chosen;
    long best_score = -1;

    if (out) memset(out, 0, sizeof *out);
    if (!out || (!data && len) || (int)ecc < 0 || ecc > REWIND_QR_ECC_H || mask < -1 || mask > 7)
        return REWIND_QR_INVALID_ARGUMENT;

    for (version = 1; version <= REWIND_QR_MAX_VERSION; ++version) {
        count_bits = version <= 9 ? 8 : 16;
        capacity_bits = data_codewords(version, ecc) * 8;
        if (len <= (size_t)capacity_bits && 4 + count_bits + (long)len * 8 <= capacity_bits) break;
    }
    if (version > REWIND_QR_MAX_VERSION) return REWIND_QR_TOO_LONG;

    memset(codewords, 0, sizeof codewords);
    append_bits(codewords, &bit_len, 0x4, 4);
    append_bits(codewords, &bit_len, (unsigned)len, count_bits);
    for (i = 0; i < (int)len; ++i) append_bits(codewords, &bit_len, data[i], 8);
    append_bits(codewords, &bit_len, 0,
                capacity_bits - bit_len < 4 ? capacity_bits - bit_len : 4);
    if (bit_len % 8) append_bits(codewords, &bit_len, 0, 8 - bit_len % 8);
    for (i = 0; bit_len < capacity_bits; ++i) append_bits(codewords, &bit_len, i % 2 ? 0x11 : 0xEC, 8);

    words = add_ecc(codewords, version, ecc, final_words);

    memset(&grid, 0, sizeof grid);
    best = grid;
    grid.size = version * 4 + 17;
    draw_function_patterns(&grid, version, ecc);
    draw_codewords(&grid, final_words, words);

    chosen = mask;
    for (i = 0; i < 8; ++i) {
        qr_grid_t trial;
        long score;
        if (mask >= 0 && i != mask) continue;
        trial = grid;
        apply_mask(&trial, i);
        draw_format(&trial, ecc, i);
        score = mask >= 0 ? 0 : penalty(&trial);
        if (best_score < 0 || score < best_score) {
            best_score = score;
            best = trial;
            chosen = i;
        }
    }

    out->version = version;
    out->size = grid.size;
    out->mask = chosen;
    memcpy(out->modules, best.dark, sizeof out->modules);
    return REWIND_QR_OK;
}

int rewind_qr_module(const rewind_qr_t *qr, int x, int y) {
    if (!qr || x < 0 || y < 0 || x >= qr->size || y >= qr->size) return 0;
    return qr->modules[y][x] ? 1 : 0;
}
