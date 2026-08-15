# Changelog

All notable changes to CrossByte will be documented in this file.

## Unreleased

### Added

- expanded the libsodium bridge beyond Ed25519 with `Aead` (XChaCha20-Poly1305-IETF), `X25519`, `KeyExchange` (crypto_kx), `GenericHash` (BLAKE2b), `HKDF` (HKDF-SHA-256), `Argon2id` password hashing/derivation, `ConstantTime.equals`, and `SecureMemory.wipe`, all backed by RFC/draft known-answer tests (`docs/proposals/0001-server-hardening.md`)
- `crossbyte.sys.ProcessLifecycle`: cooperative shutdown hooks fed by `SetConsoleCtrlHandler` on Windows and `SIGINT`/`SIGTERM` on POSIX cpp targets, with ordered once-only callback dispatch and optional runtime exit
- EdDSA (Ed25519) JWT signing and verification per RFC 8037 via the native Ed25519 backend, replacing the runtime `"not implemented"` throw; verified against the RFC 8037 appendix A JWS vector

### Changed

- rewrote `crossbyte.http.RateLimiter` as a configurable token bucket (burst capacity, continuous refill, per-key isolation, idle-bucket eviction, injectable clock) replacing the fixed-window placeholder with its hard-coded 10-request limit

### Fixed

- jvm: `PriorityQueue` produced invalid bytecode (`VerifyError` on Java 8) — a bound method reference inside the `@:generic` specialization; replaced with a capture-free comparator lambda
- jvm: `SwitchTable.make` dispatchers with mixed String/Int keys crashed with `ClassCastException` — a Dynamic-subject switch containing an Int case coerces the subject with `Jvm.toInt`; the macro now emits an if-chain through Dynamic-typed comparison/dispatch helpers
- jvm: `Vector` `every`/`some`/`filter` always returned false/empty — `Reflect.callMethod` arity-mismatch behavior differs on jvm, breaking the callback-arity fallback; the closure's real arity is now resolved reflectively and called directly
- with these fixes the jvm smoke suite passes fully on Java 8 (previously: 4 `VerifyError`s plus 2 failing tests)

## 1.0.0-rc.1 - 2026-04-28

This is the first CrossByte 1.0 release candidate.

### Added

- broader test coverage across core runtime, networking, HTTP, RPC, IO, IPC, crypto, math, and data-structure packages
- contract-driven RPC sample, TCP chat sample, IPC samples, UDP/RUDP samples, worker sample, and simple web server sample
- optional native extension integration paths for `crossbyte-libuv`, `crossbyte-brotli`, and `crossbyte-lz4`
- generated API documentation build in CI, published as the `crossbyte-api-docs` artifact

### Changed

- polished `README.md`, sample index, and release metadata for release-candidate consumption
- promoted Brotli support into the core compression/HTTP surface while keeping native acceleration modular
- refined RPC contract generation so shared interfaces describe logical handler signatures cleanly
- improved CI coverage for interpreter tests, native smoke tests, extension jobs, and sample builds

### Fixed

- multiple native/runtime integration issues shaken out by new samples and CI coverage
- HTTP request/response compression handling across `gzip`, `deflate`, `lz4`, and `br`
- sample build path consistency and native sample coverage in CI
- a broad set of public API doc placeholders and presentation rough edges
