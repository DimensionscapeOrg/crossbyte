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

// XChaCha20-Poly1305-IETF, combined mode. `out` must hold messageLength + 16
// bytes for encrypt and ciphertextLength - 16 bytes for decrypt.
int crossbyte_crypto_aead_xchacha20poly1305_encrypt(uint8_t *out, const uint8_t *message, int messageLength, const uint8_t *additionalData, int additionalDataLength, const uint8_t *nonce, const uint8_t *key);
int crossbyte_crypto_aead_xchacha20poly1305_decrypt(uint8_t *out, const uint8_t *ciphertext, int ciphertextLength, const uint8_t *additionalData, int additionalDataLength, const uint8_t *nonce, const uint8_t *key);

// Curve25519 scalar multiplication.
int crossbyte_crypto_scalarmult_base(uint8_t *point, const uint8_t *scalar);
int crossbyte_crypto_scalarmult(uint8_t *point, const uint8_t *scalar, const uint8_t *peerPoint);

// crypto_kx session-key agreement.
int crossbyte_crypto_kx_keypair(uint8_t *publicKey, uint8_t *secretKey);
int crossbyte_crypto_kx_client_session_keys(uint8_t *rx, uint8_t *tx, const uint8_t *clientPublicKey, const uint8_t *clientSecretKey, const uint8_t *serverPublicKey);
int crossbyte_crypto_kx_server_session_keys(uint8_t *rx, uint8_t *tx, const uint8_t *serverPublicKey, const uint8_t *serverSecretKey, const uint8_t *clientPublicKey);

// BLAKE2b (crypto_generichash), optionally keyed.
int crossbyte_crypto_generichash(uint8_t *out, int outLength, const uint8_t *input, int inputLength, const uint8_t *key, int keyLength);

// HKDF-SHA-256 (RFC 5869).
int crossbyte_crypto_hkdf_sha256_extract(uint8_t *prk, const uint8_t *salt, int saltLength, const uint8_t *ikm, int ikmLength);
int crossbyte_crypto_hkdf_sha256_expand(uint8_t *out, int outLength, const uint8_t *info, int infoLength, const uint8_t *prk);

// Argon2id password hashing (crypto_pwhash, alg fixed to Argon2id v1.3).
int crossbyte_crypto_pwhash_derive(uint8_t *out, int outLength, const uint8_t *password, int passwordLength, const uint8_t *salt, int opslimit, int memlimit);
int crossbyte_crypto_pwhash_str(uint8_t *out128, const uint8_t *password, int passwordLength, int opslimit, int memlimit);
int crossbyte_crypto_pwhash_str_verify(const uint8_t *hashStr, const uint8_t *password, int passwordLength);
int crossbyte_crypto_pwhash_str_needs_rehash(const uint8_t *hashStr, int opslimit, int memlimit);

// Timing-safe comparison (0 when equal) and best-effort secret wipe.
int crossbyte_crypto_memcmp(const uint8_t *a, const uint8_t *b, int length);
void crossbyte_crypto_memzero(uint8_t *buffer, int length);

#ifdef __cplusplus
}
#endif
