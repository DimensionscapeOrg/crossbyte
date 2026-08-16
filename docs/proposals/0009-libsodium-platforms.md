# Proposal 0009 — libsodium beyond Windows

**Status:** Implemented, pending CI verification on Linux and macOS

**Motivation:** The libsodium bridge linked a vendored static library
guarded by `if="windows"` + `HXCPP_M64`. Everywhere else
`Ed25519.isAvailable()` returned `false` and every crypto call threw, so
the entire `crossbyte.crypto` surface — AEAD, X25519, key exchange,
Argon2id, Ed25519 — existed only on Windows x64. Any Linux deployment,
including a containerized one, had no crypto at all.

---

## What landed

**Windows keeps the vendored static library.** Nothing to install, and
the behavior is byte-for-byte what it was; the native crypto suite still
passes (435 assertions).

**Other platforms link the system libsodium**, enabled with
`-D crossbyte_sodium_system`:

```
linux:  apt-get install libsodium-dev     # or the distro equivalent
macos:  brew install libsodium
```

The flag is opt-in rather than automatic because a build must not fail on
a machine that has not installed the library. Both paths converge on a
single `CROSSBYTE_SODIUM_ENABLED` define, which is what switches
`NativeSodium.cpp` between its real implementation and its stub — so
there is one condition to reason about instead of a growing chain of
platform tests.

**CI proves it.** A new `Core | Crypto (Linux / macOS)` matrix job
installs libsodium, builds `ci/posix-crypto-tests.hxml`, and runs the full
crypto and auth suites — including the RFC known-answer vectors — on both
platforms.

## Why not vendored binaries

Committing prebuilt `.a`/`.dylib` files for several platforms and
architectures would mean carrying binaries that cannot be reviewed in a
diff, that need re-vendoring for every new architecture, and whose
provenance a reader has to take on trust. Linking the system package
keeps the repository auditable and lets the distribution handle security
updates. Building libsodium from source in-tree (as BLAKE3 already is)
remains open as a third option if a zero-dependency Linux build becomes
important; it is a much larger vendoring job.

## Honest status

The Windows path is verified locally. **The Linux and macOS paths are
written but not yet executed** — they cannot be built on a Windows
development machine. The CI job is the verification, and the first run on
a pull request is what will confirm it. Expect the usual first-run
friction: package names, whether the linker needs an explicit
`-L/opt/homebrew/lib` on Apple Silicon, and whether hxcpp passes
`-lsodium` through unchanged.

## Seams left open

| Growth item | Notes |
|---|---|
| **Automatic detection** | The flag is manual. A configure-style probe could set it when libsodium is present, at the cost of build-time magic. |
| **Homebrew prefix on Apple Silicon** | `/opt/homebrew` is not on the default search path for every toolchain; may need an explicit `-L`. |
| **In-tree source build** | The zero-dependency option, matching how BLAKE3 is handled. |
| **Windows arm64** | Still unsupported: the vendored library is x64 only. |
