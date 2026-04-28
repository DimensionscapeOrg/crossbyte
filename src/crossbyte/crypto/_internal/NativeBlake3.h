#ifndef CROSSBYTE_CRYPTO_INTERNAL_NATIVE_BLAKE3_H
#define CROSSBYTE_CRYPTO_INTERNAL_NATIVE_BLAKE3_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int crossbyte_crypto_blake3_hash(const uint8_t *input, int inputLength, uint8_t *output, int outputLength);
int crossbyte_crypto_blake3_simd_degree(void);

#ifdef __cplusplus
}
#endif

#endif
