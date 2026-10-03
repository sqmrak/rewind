#ifndef REWIND_QR_H
#define REWIND_QR_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* version 10 at level M holds 213 bytes, enough for any sign in url */
#define REWIND_QR_MAX_VERSION 10
#define REWIND_QR_MAX_SIZE    (REWIND_QR_MAX_VERSION * 4 + 17)

typedef enum {
    REWIND_QR_ECC_L = 0,
    REWIND_QR_ECC_M,
    REWIND_QR_ECC_Q,
    REWIND_QR_ECC_H
} rewind_qr_ecc_t;

typedef enum {
    REWIND_QR_OK = 0,
    REWIND_QR_INVALID_ARGUMENT,
    REWIND_QR_TOO_LONG
} rewind_qr_status_t;

typedef struct {
    int version;
    int size;
    int mask;
    unsigned char modules[REWIND_QR_MAX_SIZE][REWIND_QR_MAX_SIZE];
} rewind_qr_t;

/* byte mode only; mask -1 picks the lowest penalty mask */
rewind_qr_status_t rewind_qr_encode(const unsigned char *data, size_t len,
                                        rewind_qr_ecc_t ecc, int mask,
                                        rewind_qr_t *out);

/* 1 for a dark module, 0 for light or out of range */
int rewind_qr_module(const rewind_qr_t *qr, int x, int y);

#ifdef __cplusplus
}
#endif

#endif /* rewind_qr_h */
