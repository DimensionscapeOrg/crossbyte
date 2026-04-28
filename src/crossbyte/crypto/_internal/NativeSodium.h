#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool crossbyte_crypto_sodium_available();
const char *crossbyte_crypto_sodium_status_message();
int crossbyte_crypto_ed25519_keypair(uint8_t *publicKey, uint8_t *secretKey);
int crossbyte_crypto_ed25519_sign_detached(uint8_t *signature, const uint8_t *message, int messageLength, const uint8_t *secretKey);
int crossbyte_crypto_ed25519_verify_detached(const uint8_t *signature, const uint8_t *message, int messageLength, const uint8_t *publicKey);

#ifdef __cplusplus
}
#endif
