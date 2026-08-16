#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Asymmetric signature verification and signing over mbedTLS's generic
// public-key layer, covering both RSA (RS256) and ECDSA (ES256).
//
// Keys are passed as PEM text on every call and parsed there: the bridge
// holds no state, so there are no handles to leak or invalidate. Callers
// that verify at high rates should cache at a higher level.
//
// Return values: 0 on success, negative on failure.

// Reports whether the native backend is compiled in.
bool crossbyte_pk_available();

// Verifies `signature` over the SHA-256 `hash` of a message.
// `signatureFormat`: 0 = as-is (PKCS#1 v1.5 for RSA, ASN.1 DER for ECDSA),
// 1 = JOSE raw r||s (ECDSA only), which is what JWS carries.
int crossbyte_pk_verify_sha256(const uint8_t *publicKeyPem, int publicKeyLength, const uint8_t *hash, const uint8_t *signature, int signatureLength,
	int signatureFormat);

// Signs the SHA-256 `hash`, writing at most `outCapacity` bytes into `out`
// and the produced length into `outLength`. `signatureFormat` matches
// verify.
int crossbyte_pk_sign_sha256(const uint8_t *privateKeyPem, int privateKeyLength, const uint8_t *hash, uint8_t *out, int outCapacity, int *outLength,
	int signatureFormat);

// Human-readable text for an mbedTLS error code, so failures surface as
// diagnosis rather than a bare number.
const char *crossbyte_pk_error_message(int code);

// Key type of a PEM key: 0 unknown, 1 RSA, 2 ECDSA/EC.
int crossbyte_pk_key_type(const uint8_t *keyPem, int keyLength, bool isPrivate);

// Size in bytes of one ECDSA coordinate for a PEM EC key, i.e. half the
// JOSE raw signature length (32 for P-256). Negative on failure.
int crossbyte_pk_ec_coordinate_size(const uint8_t *keyPem, int keyLength, bool isPrivate);

#ifdef __cplusplus
}
#endif
