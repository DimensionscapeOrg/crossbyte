# Proposal 0008 — RS256 and ES256 signatures

**Status:** Implemented

**Motivation:** `JWT.make` threw `"RS256 signer not implemented"` at
runtime. That is the algorithm every mainstream OpenID Connect provider —
Google, Microsoft, Okta, Auth0 — signs its ID tokens with, so a CrossByte
service could not consume a token from any of them. `ES256` is the other
half: increasingly common in JWKS, and the signature scheme WebAuthn
authenticators use.

---

## What landed

### `crossbyte.crypto.PublicKeySignature`

RSA and ECDSA over SHA-256, built on the mbedTLS that **already ships with
hxcpp and is already linked for `sys.ssl`** — no new dependency, nothing
to vendor. Keys are PEM text, the form providers publish.

- `verify(publicKeyPem, message, signature, format)` — returns `false`
  for malformed keys, wrong-length signatures, and unavailable backends
  rather than throwing, so a hostile token cannot raise out of a
  verification path.
- `sign(privateKeyPem, message, format)`
- `keyType()` / `joseSignatureLength()` for validation and diagnostics.

`SignatureFormat` distinguishes the algorithm's own encoding (`NATIVE`:
PKCS#1 v1.5 for RSA, ASN.1 DER for ECDSA) from `JOSE`, the fixed-width
`r || s` that JWS carries for `ES256`. The conversion between them happens
in the native layer.

### `PkSigner` and JWT wiring

`JWTSigner` gains an `ES256` constructor, and both `RS256` and `ES256` now
resolve to a working signer. Verification keys are PEM public keys held by
`kid` — the shape a provider's JWKS converts into — and the private key is
optional, so a verify-only signer is the natural default for consuming
someone else's tokens.

Keys of the wrong kind (an EC key offered as `RS256`) are rejected at
construction rather than failing every verification later with no
indication why.

## Three findings worth recording

Each cost real debugging time and would cost it again:

1. **mbedTLS symbols are not linked unless something pulls in hxcpp's SSL
   module.** The fix is including `${HXCPP}/src/hx/libs/ssl/Build.xml`,
   which is `pragma once` and therefore safe alongside `sys.ssl`.
2. **hxcpp builds mbedTLS with `MBEDTLS_THREADING_C`**, and installs the
   platform mutex callbacks only inside its own `_hx_ssl_init()`. Without
   calling it, the first RSA sign fails with
   `MBEDTLS_ERR_THREADING_BAD_INPUT_DATA` (`-0x001C`) — an error whose
   text gives no hint that threading setup is the cause. The bridge calls
   that idempotent initializer before every entry point.
3. **mbedTLS's entropy pollers fail to seed in this build**
   (`MBEDTLS_ERR_CTR_DRBG_ENTROPY_SOURCE_FAILED`, `-0x0034`). Rather than
   work around the DRBG, signing draws directly from the operating
   system's CSPRNG (`BCryptGenRandom` / `/dev/urandom`). That is the
   stronger choice regardless: for ECDSA a predictable nonce leaks the
   private key outright.

## Testing

`tests/crossbyte/auth/jwt/PkJwtTest.hx`, with keys generated at test time
by the `openssl` CLI (`PkKeyFixture`) so nothing expirable is committed
and machines without OpenSSL skip rather than fail:

- RSA sign/verify, signature length equal to the modulus, tamper rejected.
- ECDSA in both `JOSE` and DER form, each verifying only under its own
  format — a DER signature read as raw `r||s` must fail.
- Full JWT round trips for both algorithms, with tampered-payload and
  expiry rejection.
- ECDSA determinism: hxcpp builds mbedTLS with
  `MBEDTLS_ECDSA_DETERMINISTIC`, so nonces follow RFC 6979 and signing the
  same payload twice is reproducible — the stronger property, since it
  removes the nonce-reuse failure mode that has leaked ECDSA private keys
  in the wild. Asserted alongside the check that different payloads still
  produce different signatures.
- Verify-only signers, wrong-key-kind rejection, unknown `signKeyId`,
  empty key sets, and algorithm confusion (an RS256 token offered to an
  ES256 verifier).

## Seams left open

| Growth item | Notes |
|---|---|
| **Key handle caching** | Keys are parsed on every call. Correct and leak-free, but a service verifying at high rates should cache by `kid`; a handle-based API would avoid re-parsing. |
| **JWKS ingestion** | Providers publish JSON Web Key Sets, not PEM. A JWKS-to-PEM converter (and key rotation polling) would complete the OIDC story. |
| **PS256 / RS384 / RS512 / ES384** | mbedTLS supports the primitives; only the algorithm plumbing is missing. |
| **WebAuthn** | ES256 verification is the cryptographic half. Attestation and assertion parsing (CBOR/COSE) remain. |
