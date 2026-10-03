#include "rewind_qr.h"

#include <stdio.h>
#include <string.h>

static int g_fail;

static void ok(const char *name, int condition) {
    if (condition) return;
    fprintf(stderr, "FAIL %s\n", name);
    ++g_fail;
}

/* reference matrices from an independent encoder, byte mode, level m */
static const char *const k_device_v3_mask5[] = {
    "11111110011111110010101111111",
    "10000010111010010100101000001",
    "10111010100100101000101011101",
    "10111010110010110101101011101",
    "10111010011001110011101011101",
    "10000010010011101000101000001",
    "11111110101010101010101111111",
    "00000000101111000011100000000",
    "10000010101110110101011001110",
    "11011000001110100011000110110",
    "01101110011010000000100000000",
    "00110000100010111001011101000",
    "01101111001011100001101100001",
    "10110100100101100001101010011",
    "11000110010001111100001101100",
    "10111101111011101011010110101",
    "01111110001100110101000101100",
    "10000001000110001111001110111",
    "11101111110011101111000001001",
    "10010001100010111000111110000",
    "10110111110000001100111110111",
    "00000000101101001010100011000",
    "11111110011011111111101011100",
    "10000010010101000001100010010",
    "10111010011101011001111111000",
    "10111010010001001010010101110",
    "10111010000110100001111111110",
    "10000010011001110000011101101",
    "11111110101100100011001111100"
};

static const char *const k_activate_v7_mask2[] = {
    "111111100111100011010110010101111100101111111",
    "100000100100011110000101111111011101001000001",
    "101110101111000100101001000010011101001011101",
    "101110101100111101111011010000110001101011101",
    "101110101001001111011111100101100011101011101",
    "100000101100110001001000110111001000001000001",
    "111111101010101010101010101010101010101111111",
    "000000001110001000011000111110011000000000000",
    "101111100011111101001111101100110011001111100",
    "101100000000011000101111110001100001100011111",
    "010000110101100001110100101001001010111101110",
    "110010011110000110000001101100011010010010100",
    "110101101101110001110010100010110001011001001",
    "000000010111011010000011010111100000110100011",
    "111111110110101110011111111011001010101110110",
    "001010001001000110110010101011101111101011100",
    "111000110111001011100100000001110101000001001",
    "010110001000011111001101010101110001110100011",
    "001010100101001010011001111111001011011110110",
    "000101010011101110110000111010011111001011100",
    "101111111101010111101111101000110101111111001",
    "101110001011001111001000111101100001100011101",
    "110110101100011000101010100111001011101010110",
    "000110001110010011111000100110011000100011100",
    "111011111010101000101111111000110010111111010",
    "111100010100110001111110010111100000100001001",
    "011001101111110111000110001101001011010001010",
    "010011001110011000101100101100011111011001101",
    "110001101100000100000001100100110100101011011",
    "000100001101110100101011010101100000101000011",
    "001010110000011010110110111111001011100100110",
    "011110001010111010111101001011111111001101100",
    "001011111100100101011000000000110100101011001",
    "010111010101111011011011010101101001010000011",
    "000010100011101111100101011111011011110100110",
    "011110010100001110100001100010011111101111100",
    "100110100111101000111111110000110100111111001",
    "000000001111000101011000100101100001100011111",
    "111111100101111100111010110111001011101010110",
    "100000101001100010111000111110011001100011110",
    "101110101010110100101111111000110011111111000",
    "101110101111000001000100110001100101001010101",
    "101110101111001111101000001001001111100000010",
    "100000100100100001111101001010011110110101100",
    "111111101010101110010011100000110100011110010"
};

static int matches(const rewind_qr_t *qr, const char *const *rows, int size) {
    int x, y;
    if (qr->size != size) return 0;
    for (y = 0; y < size; ++y)
        for (x = 0; x < size; ++x)
            if (rewind_qr_module(qr, x, y) != (rows[y][x] == '1')) return 0;
    return 1;
}

static rewind_qr_status_t encode_text(const char *text, rewind_qr_ecc_t ecc, int mask,
                                      rewind_qr_t *qr) {
    return rewind_qr_encode((const unsigned char *)text, strlen(text), ecc, mask, qr);
}

int main(void) {
    static rewind_qr_t qr, forced;
    static unsigned char big[300];
    char activate[128];

    ok("device url encodes", encode_text("https://www.google.com/device", REWIND_QR_ECC_M, 5, &qr) == REWIND_QR_OK);
    ok("device url picks version 3", qr.version == 3 && qr.size == 29 && qr.mask == 5);
    ok("device url matches reference", matches(&qr, k_device_v3_mask5, 29));

    snprintf(activate, sizeof activate, "https://www.youtube.com/activate?rewind=%s",
             "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
    ok("version 7 encodes", encode_text(activate, REWIND_QR_ECC_M, 2, &qr) == REWIND_QR_OK);
    ok("version 7 carries version info", qr.version == 7 && matches(&qr, k_activate_v7_mask2, 45));

    ok("auto mask encodes", encode_text("https://www.google.com/device", REWIND_QR_ECC_M, -1, &qr) == REWIND_QR_OK);
    ok("auto mask is in range", qr.mask >= 0 && qr.mask <= 7);
    ok("auto mask equals forced mask",
       encode_text("https://www.google.com/device", REWIND_QR_ECC_M, qr.mask, &forced) == REWIND_QR_OK &&
       memcmp(qr.modules, forced.modules, sizeof qr.modules) == 0);

    ok("empty input fits version 1", encode_text("", REWIND_QR_ECC_H, -1, &qr) == REWIND_QR_OK && qr.version == 1);
    memset(big, 'a', sizeof big);
    ok("213 bytes fit version 10 at m",
       rewind_qr_encode(big, 213, REWIND_QR_ECC_M, -1, &qr) == REWIND_QR_OK &&
       qr.version == 10 && qr.size == REWIND_QR_MAX_SIZE);
    ok("214 bytes are too long at m", rewind_qr_encode(big, 214, REWIND_QR_ECC_M, -1, &qr) == REWIND_QR_TOO_LONG);
    ok("too long leaves an empty code", qr.size == 0 && rewind_qr_module(&qr, 0, 0) == 0);
    ok("null output is rejected", rewind_qr_encode(big, 1, REWIND_QR_ECC_M, -1, NULL) == REWIND_QR_INVALID_ARGUMENT);
    ok("null data is rejected", rewind_qr_encode(NULL, 1, REWIND_QR_ECC_M, -1, &qr) == REWIND_QR_INVALID_ARGUMENT);
    ok("bad mask is rejected", rewind_qr_encode(big, 1, REWIND_QR_ECC_M, 8, &qr) == REWIND_QR_INVALID_ARGUMENT);
    ok("bad level is rejected",
       rewind_qr_encode(big, 1, (rewind_qr_ecc_t)4, -1, &qr) == REWIND_QR_INVALID_ARGUMENT);
    encode_text("A", REWIND_QR_ECC_M, -1, &qr);
    ok("modules outside the code are light",
       rewind_qr_module(&qr, -1, 0) == 0 && rewind_qr_module(&qr, 0, qr.size) == 0);

    if (g_fail) {
        fprintf(stderr, "%d qr check(s) failed\n", g_fail);
        return 1;
    }
    puts("all qr checks passed");
    return 0;
}
