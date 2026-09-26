#pragma once

// Guarded because this header is pulled into generated code by `@:include`,
// which has already had hxcpp.h through the precompiled header. Including it
// again makes gcc resolve <hxcpp.h> a second time, and the first thing on the
// include path is hxcpp's own __pch directory, which holds hxcpp.h.gch rather
// than hxcpp.h. See NativeAlpn.h, where this broke the Linux build.
#ifndef HXCPP_H
#include <hxcpp.h>
#endif

#include <stdint.h>

// Asymmetric signatures over mbedTLS's generic public-key layer, covering both
// RSA (RS256) and ECDSA (ES256).
//
// A PEM key is parsed once, into a key object the GC owns: the parsed context
// lives in native memory and is freed -- and wiped, since mbedtls_pk_free
// zeroes the key material -- by the object's finalizer, or at once by
// crossbyte_pk_key_dispose. Parsing on every call left a copy of the private
// key in freed memory per signature and rebuilt EC tables every time.
//
// Signing and verifying run in a GC-free zone, since RSA-4096 signing alone
// takes tens of milliseconds. Operations on one key are serialized: mbedTLS
// builds an EC key's comb table on first use, inside the shared context.
//
// Return values: 0 on success, negative on failure.

// Reports whether the native backend is compiled in.
bool crossbyte_pk_available();

// Parses `pem`, a private key when `isPrivate`, else a public key. Returns the
// key object, or null with the mbedTLS error in `error`.
::Dynamic crossbyte_pk_key_load(const uint8_t *pem, int pemLength, bool isPrivate, int *error);

// Key type: 0 unknown or disposed, 1 RSA, 2 ECDSA/EC.
int crossbyte_pk_key_type(::Dynamic key);

// Size in bytes of one ECDSA coordinate, half the JOSE raw signature length
// (32 for P-256). Negative for anything but a live EC key.
int crossbyte_pk_key_coordinate_size(::Dynamic key);

// Signs the SHA-256 `hash` with a private key, writing at most `outCapacity`
// bytes into `out` and the produced length into `outLength`.
// `signatureFormat`: 0 = as-is (PKCS#1 v1.5 for RSA, ASN.1 DER for ECDSA),
// 1 = JOSE raw r||s (ECDSA only), which is what JWS carries.
int crossbyte_pk_key_sign_sha256(::Dynamic key, const uint8_t *hash, uint8_t *out, int outCapacity, int *outLength, int signatureFormat);

// Verifies `signature` over the SHA-256 `hash`. `signatureFormat` matches sign.
int crossbyte_pk_key_verify_sha256(::Dynamic key, const uint8_t *hash, const uint8_t *signature, int signatureLength, int signatureFormat);

// Frees and wipes the parsed key now. Later operations on it fail.
void crossbyte_pk_key_dispose(::Dynamic key);

// Human-readable text for an mbedTLS error code, so failures surface as
// diagnosis rather than a bare number.
::String crossbyte_pk_error_message(int code);

// How many PEM documents have been parsed in this process. For tests of the
// parse-once contract.
int crossbyte_pk_parse_count();
