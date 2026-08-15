# Proposal 0001 — Server hardening: crypto expansion, shutdown hooks, real rate limiting

**Status:** In progress on branch `server-hardening`

**Motivation:** CrossByte is adopted as the backend runtime for a production
service that stores and routes end-to-end-encrypted content (initial
deployment: Windows Server, hxcpp x64). Auditing the framework against that
workload surfaced three gaps that are general server-hardening improvements,
not app-specific features. This change set closes them test-first.

---

## 1. libsodium bridge symbol expansion

### Problem

`crossbyte.crypto._internal.NativeSodium` binds exactly five symbols
(`sodium_init`, Ed25519 keypair/sign/verify, plus availability). The vendored
`libsodium.lib` (≥ 1.0.19 — it exports the `crypto_kdf_hkdf_sha256` family)
already contains every primitive a modern service needs; only the bindings are
missing. There is no AEAD, no key exchange, no password KDF, no HKDF, no
constant-time compare, and no secure wipe anywhere in the framework.

### Change

Extend `NativeSodium.{h,cpp,hx}` with the following symbol families, and add
small, focused public wrappers in `crossbyte.crypto`. Bind, never reimplement:
no cryptographic logic is written in Haxe or bridge C++ beyond argument
validation and buffer sizing.

| Public API | libsodium symbols | Purpose |
|---|---|---|
| `crossbyte.crypto.Aead` | `crypto_aead_xchacha20poly1305_ietf_{encrypt,decrypt}` | Authenticated encryption (XChaCha20-Poly1305-IETF, combined mode) |
| `crossbyte.crypto.X25519` | `crypto_scalarmult_curve25519{,_base}` | Raw Curve25519 scalar multiplication |
| `crossbyte.crypto.KeyExchange` | `crypto_kx_keypair`, `crypto_kx_{client,server}_session_keys` | Session-key agreement (rx/tx pairs) |
| `crossbyte.crypto.GenericHash` | `crypto_generichash` | BLAKE2b, optionally keyed, 16–64 byte output |
| `crossbyte.crypto.HKDF` | `crypto_kdf_hkdf_sha256_{extract,expand}` | RFC 5869 HKDF-SHA-256 |
| `crossbyte.crypto.password.Argon2id` | `crypto_pwhash`, `crypto_pwhash_str{,_verify,_needs_rehash}` | Password hashing + password-based key derivation |
| `crossbyte.crypto.ConstantTime` | `sodium_memcmp` | Timing-safe equality |
| `crossbyte.crypto.SecureMemory` | `sodium_memzero` | Best-effort secret wipe |

Conventions (matching `Ed25519`):

- Byte-size constants exposed as `inline final` on each class.
- `isAvailable()` gates on the shared sodium state; unsupported targets throw
  on use (or return `false`/`null` for verify/decrypt-shaped operations).
- Decrypt/verify failures return `null`/`false`; misuse (wrong key or nonce
  length, negative output size) throws.
- Random material (keys, nonces, salts) comes from `SecureRandom` — never
  `crossbyte.utils.Random`.
- Argon2id limit presets (`OPSLIMIT_INTERACTIVE`/`MODERATE`/`SENSITIVE` and
  matching `MEMLIMIT_*`) mirror libsodium's published values.

### Acceptance

- Known-answer tests: X25519 against RFC 7748 §6.1 vectors; BLAKE2b against
  RFC 7693 ("abc" and empty input); HKDF-SHA-256 against RFC 5869 A.1;
  XChaCha20-Poly1305 round-trip with tamper/wrong-key/truncation rejection.
- Property tests: kx client/server session keys agree crosswise; Argon2id
  `hash`/`verify` round-trip, wrong-password rejection, `needsRehash`
  behavior; deterministic raw derivation for a fixed salt; `ConstantTime`
  equal/unequal/length-mismatch; `SecureMemory.wipe` zeroes the buffer.
- All existing suites stay green; non-cpp targets keep compiling with the
  documented unavailable-target behavior.

### Out of scope (future work)

Linux/macOS libsodium vendoring (gates the Linux self-host story; the binding
layer added here is platform-agnostic, so vendoring is purely a build change).

---

## 2. Process shutdown hooks

### Problem

The framework has no signal or console-control handling at all. A CrossByte
server killed by service stop, `Ctrl+C`, or a deploy gets no chance to drain
sockets, flush workers, or close database connections. Windows Server
deployments need `SetConsoleCtrlHandler`/`SERVICE_CONTROL_STOP` semantics;
POSIX deployments need `SIGINT`/`SIGTERM`.

### Change

New `crossbyte.sys.ProcessLifecycle`:

- `installDefaultHandlers():Bool` — arms the native handler
  (`SetConsoleCtrlHandler` on Windows; `sigaction` for `SIGINT`/`SIGTERM` on
  POSIX cpp). The native handler only sets an atomic flag — it never calls
  into Haxe from the handler thread. A tick listener on the installing
  runtime observes the flag and dispatches on the runtime's own thread.
- `requestShutdown():Void` — programmatic trigger; same code path as a
  signal, usable from tests and from service-control wrappers.
- `shutdownRequested:Bool` — poll-style access.
- `onShutdown(callback):Void` — callbacks run exactly once, on the runtime
  thread, in registration order; exceptions in one callback do not skip the
  rest. After callbacks complete, `exitOnShutdown` (default `true`) calls
  `CrossByte.current().exit()`.

### Acceptance

- Programmatic path fully tested on interp and cpp: request → callbacks fire
  once, ordering respected, `shutdownRequested` latches, double-request does
  not re-fire, callback exception does not block later callbacks or exit.
- Native handler installation smoke-tested on Windows cpp (install succeeds,
  process state unchanged). Actually delivering a console control event is
  not automatable in-suite; covered by a manual verification note.

---

## 3. Real rate limiter

### Problem

`crossbyte.http.RateLimiter` is a fixed-window counter with a hard-coded
limit of 10 requests per window, a whole-map reset at the window edge (burst
of 2× at the boundary), and unbounded key growth within a window. It is also
HTTP-only in practice.

### Change

Rewrite `RateLimiter` as a token bucket, transport-agnostic:

- `new RateLimiter(maxRequests = 10, perSeconds = 60.0, ?clock)` — capacity
  `maxRequests`, continuous refill at `maxRequests/perSeconds`; injectable
  monotonic clock for deterministic tests. Defaults preserve the old
  effective policy (10 per minute).
- `isRateLimited(key):Bool` keeps the existing call-site contract
  (consume-and-check); `tryAcquire(key, cost = 1):Bool`, `remaining(key)`,
  and `reset(key)` added for non-HTTP callers (WebSocket sessions, RPC).
- Idle-bucket eviction bounds memory: buckets untouched for a full refill
  period are swept opportunistically.
- `HTTPServerConfig` continues to default-construct the limiter; existing
  429 behavior preserved.

### Acceptance

- Deterministic unit tests with a fake clock: burst up to capacity, deny at
  capacity+1, partial refill grants exactly the refilled amount, no boundary
  double-burst, per-key isolation, eviction removes idle buckets, cost > 1
  acquisition, existing HTTP 429 tests updated to the configurable API.

---

## Explicitly deferred (tracked, not in this change set)

- TLS on `ServerSocket`/`HTTPServer` via `FlexSocket` (wss on
  `ServerWebSocket` is the only TLS server path today).
- Linux/macOS libsodium vendoring.
- Asymmetric JWT signers (EdDSA becomes cheap once this lands; RS256/ES256
  need an mbedTLS bridge).
- WebAuthn primitives (P-256 ECDSA, COSE/CBOR) — candidate extension repo.
- DB connection pooling, async facade, binary Postgres marshaling.
- HTTP/2.
