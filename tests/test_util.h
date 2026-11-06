#ifndef REWIND_TEST_UTIL_H
#define REWIND_TEST_UTIL_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* shared helpers need not use every assertion utility */
#define TEST_UNUSED __attribute__((unused))

TEST_UNUSED static int g_failures;
TEST_UNUSED static int g_checks;

#define CHECK(cond) do { \
    ++g_checks; \
    if (!(cond)) { \
        ++g_failures; \
        fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
    } \
} while (0)

#define CHECK_EQ_INT(a, b) do { \
    long long va_ = (long long)(a), vb_ = (long long)(b); \
    ++g_checks; \
    if (va_ != vb_) { \
        ++g_failures; \
        fprintf(stderr, "%s:%d: %s == %lld, expected %lld\n", __FILE__, __LINE__, #a, va_, vb_); \
    } \
} while (0)

#define CHECK_MEM(a, b, n) do { \
    ++g_checks; \
    if (memcmp((a), (b), (n)) != 0) { \
        ++g_failures; \
        fprintf(stderr, "%s:%d: bytes differ: %s vs %s\n", __FILE__, __LINE__, #a, #b); \
    } \
} while (0)

TEST_UNUSED static int test_hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

TEST_UNUSED static long test_hex(const char *hex, uint8_t *out, size_t cap) {
    size_t n = 0;
    int hi = -1;
    for (; *hex; ++hex) {
        int d;
        if (*hex == ' ' || *hex == '\n') continue;
        d = test_hex_digit(*hex);
        if (d < 0) return -1;
        if (hi < 0) {
            hi = d;
        } else {
            if (n >= cap) return -1;
            out[n++] = (uint8_t)((hi << 4) | d);
            hi = -1;
        }
    }
    return hi < 0 ? (long)n : -1;
}

TEST_UNUSED static int test_finish(const char *name) {
    if (g_failures) {
        fprintf(stderr, "%s: %d of %d checks failed\n", name, g_failures, g_checks);
        return 1;
    }
    printf("%s: %d checks passed\n", name, g_checks);
    return 0;
}

#endif
