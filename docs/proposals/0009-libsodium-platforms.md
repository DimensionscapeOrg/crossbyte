# Proposal 0009 — libsodium on every platform

**Status:** Implemented (source vendoring). Supersedes the system-package
approach this proposal originally described.

**Motivation:** The libsodium bridge linked a prebuilt static library
guarded by `if="windows"` + `HXCPP_M64`. Everywhere else
`Ed25519.isAvailable()` returned `false` and every crypto call threw, so
the entire `crossbyte.crypto` surface — AEAD, X25519, key exchange,
Argon2id, Ed25519, BLAKE2b — existed only on Windows x64. Any Linux
deployment, containerized or not, had no crypto at all.

---

## What landed

**libsodium 1.0.21 is vendored as source and compiled by hxcpp**, exactly
as CrossByte already does for BLAKE3 and as hxcpp itself does for mbedTLS,
SQLite, PCRE2, and zlib.

- No external dependency on any platform. Nothing to `apt-get` or `brew
  install`, no opt-in build flag, no DLL to ship.
- The prebuilt `libsodium.lib` is **deleted**. A 2.7 MB opaque binary is
  replaced by 2.3 MB of readable source — smaller, and reviewable in a
  diff.
- Windows ARM64 and 32-bit work by construction, closing a gap this
  proposal previously listed as unsupported.

The version is deliberately 1.0.21: byte-for-byte the same release the
committed `.lib` was built from (verified by exact size match against the
official MSVC distribution), so this is a build change with no change in
crypto behavior.

## Why it was less fiddly than expected

Three properties of libsodium's source make it well suited to this, and
each removed a step I had assumed would be necessary:

1. **No autotools configuration.** Not one libsodium source includes a
   generated `config.h`.
2. **`version.h` ships pregenerated.** Upstream carries the generated MSVC
   copy at `builds/msvc/version.h`, so nothing needs `configure`.
3. **Architecture-specific sources self-guard.** Every AVX2, SSSE3,
   AES-NI, and NEON file wraps its entire body in `HAVE_*INTRIN_H` checks
   that libsodium's own `private/common.h` sets by compiler and target
   detection. On a target lacking the instruction set they reduce to empty
   translation units — so a single file list is correct for every
   architecture, with no per-file compiler flags and no exclusions.

## Layout and maintenance

Sources live at
`src/crossbyte/crypto/_internal/vendor/libsodium/src/`, mirroring the
upstream `src/libsodium/` tree so an update is a clean re-copy.
`NativeSodiumBuild.xml` enumerates all 135 sources and is **generated from
the tree** — regenerate it after updating rather than editing by hand.

The tradeoff to be honest about: carrying a cryptographic library in-tree
means its security updates are now a deliberate action here, not something
a distribution package delivers. That is the cost of the zero-dependency
build, and it argues for tracking libsodium releases rather than pinning
and forgetting.

## Testing

- Windows x64: the crypto suite passes against the source build — 435
  assertions including every RFC known-answer vector
  (XChaCha20-Poly1305 from draft-irtf-cfrg-xchacha-03, X25519 from
  RFC 7748, BLAKE2b from RFC 7693, HKDF from RFC 5869, plus Argon2id
  round-trips). These now exercise code compiled here rather than a
  vendor binary.
- Linux and macOS: `ci/posix-crypto-tests.hxml` and the
  `Core | Crypto (Linux / macOS)` matrix job build and run the same
  suites with no install step. Still unverified locally — a Windows
  machine cannot build them — so the CI run remains the proof.

## Seams left open

| Growth item | Notes |
|---|---|
| **Tracking upstream releases** | No mechanism watches for new libsodium versions; worth a reminder or a scheduled check given this is crypto. |
| **Trimming the source set** | All 135 sources compile, including primitives CrossByte does not bind. Pruning would cut build time but makes updates a merge rather than a copy — probably not worth it. |
| **Build time** | Adds a one-time compile of 135 C files to a clean build; hxcpp's object caching absorbs it on rebuilds. |
