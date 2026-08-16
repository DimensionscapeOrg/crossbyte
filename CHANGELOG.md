# Changelog

All notable changes to CrossByte will be documented in this file.

## Unreleased

### Added

- expanded the libsodium bridge beyond Ed25519 with `Aead` (XChaCha20-Poly1305-IETF), `X25519`, `KeyExchange` (crypto_kx), `GenericHash` (BLAKE2b), `HKDF` (HKDF-SHA-256), `Argon2id` password hashing/derivation, `ConstantTime.equals`, and `SecureMemory.wipe`, all backed by RFC/draft known-answer tests (`docs/proposals/0001-server-hardening.md`)
- `crossbyte.sys.ProcessLifecycle`: cooperative shutdown hooks fed by `SetConsoleCtrlHandler` on Windows and `SIGINT`/`SIGTERM` on POSIX cpp targets, with ordered once-only callback dispatch and optional runtime exit
- EdDSA (Ed25519) JWT signing and verification per RFC 8037 via the native Ed25519 backend, replacing the runtime `"not implemented"` throw; verified against the RFC 8037 appendix A JWS vector
- direct TLS termination in `ServerSocket` (`new ServerSocket(true)` + `setCertificate`/`addSNICertificate`, plus `requireClientCertificate()` for mutual TLS), with handshakes advanced across ticks so a slow or hostile peer never blocks the runtime loop, a `handshakeTimeout` guard against half-open connections, and `pendingHandshakeCount()` for metrics; `HTTPServerConfig.tlsCertificatePath`/`tlsKeyPath` turn `HTTPServer` into an HTTPS server (`docs/proposals/0002-direct-tls.md`)

- graceful shutdown: `ServerSocket.stopAccepting()` releases the listening socket while established connections keep working (freeing the port for a successor process), and `HTTPServer.drain(timeout, ?onComplete)` stops accepting, waits for in-flight requests, then closes — pairs with `ProcessLifecycle` so a service stop finishes live responses instead of severing them (`docs/proposals/0003-graceful-shutdown.md`)
- `crossbyte.core.Config`: layered service configuration from defaults, `key=value` files, and environment variables (with prefix stripping), with case- and separator-insensitive keys, typed accessors (`getInt`/`getFloat`/`getBool`/`getList`), and `require()` for values a service cannot start without; malformed numbers are rejected outright rather than silently truncated
- structured logging: `Logger` gains severity levels (`LogLevel`), `key=value` structured fields, optional JSON output, optional timestamps, and a replaceable `sink`; the existing `info`/`error`/`separator` helpers keep their exact output
- `crossbyte.db.ConnectionPool<T>`: driver-agnostic connection pooling — lazy creation to a fixed ceiling, reuse, acquire timeout, optional health validation, `discard()`, and a `withConnection()` scope that returns the connection even when the body throws; works with every driver without them needing a shared interface
- `crossbyte.db.AsyncDatabase<T>`: runs database work on a `TaskPool` worker holding a pooled connection and delivers the resulting `Task` completion back on the submitting runtime thread, so synchronous drivers no longer block the event loop; includes a `transaction(begin, commit, rollback, body)` scope (`docs/proposals/0004-db-pooling-and-async.md`)
- `crossbyte.metrics`: thread-safe `Counter`, `Gauge` (including gauges bound to a provider function), and `Histogram` (cumulative buckets, plus `time()` which records even when the body throws), a get-or-create `Metrics` registry with Prometheus-grammar validation, and `toPrometheus()` text exposition output (`docs/proposals/0005-metrics.md`)
- socket write backpressure: `Socket.maxOutputBufferSize` bounds how much undrained data may accumulate for a peer that has stopped reading, `outputOverflowPolicy` chooses between closing the connection (default) and throwing, and `outputBufferLength` exposes the current depth; opt-in, so existing behavior is unchanged (`docs/proposals/0006-socket-backpressure.md`)
- `ci/stress-tests.hxml`: a concurrency stress suite covering TaskPool drain completeness, ConnectionPool contention, Metrics registry contention, Timer id allocation, and socket backpressure — races the single-threaded interpreter suites cannot see; wired into the Windows native CI job (`tests/stress/README.md`)
- `HTTPRequestHandler.respond()`: middleware can now answer a request itself (health checks, metrics, auth replies, small API routes) instead of only calling `next()` or failing with a status
- `crossbyte.metrics.MetricsEndpoint`: middleware serving a registry in Prometheus text format, rejecting non-`GET`/`HEAD` with 405 and never letting a failed render break the request path
- opt-in `HTTPServer` instrumentation via `HTTPServerConfig.metrics`/`metricsPrefix`: request counts labelled by status class, a request-duration histogram, and a connection gauge bound to the server's live counter (`docs/proposals/0007-metrics-wiring.md`)
- `crossbyte.crypto.PublicKeySignature`: RSA and ECDSA over SHA-256 via the mbedTLS that already ships with hxcpp, including conversion between ASN.1 DER and the raw `r||s` form JWS carries
- `RS256` and `ES256` JWT signers, replacing the runtime `"not implemented"` throw — this is what lets a service verify OpenID Connect tokens from Google, Microsoft, and other providers; `JWTSigner` gains an `ES256` constructor (`docs/proposals/0008-asymmetric-signatures.md`)

### Changed

- rewrote `crossbyte.http.RateLimiter` as a configurable token bucket (burst capacity, continuous refill, per-key isolation, idle-bucket eviction, injectable clock) replacing the fixed-window placeholder with its hard-coded 10-request limit

### Fixed

- jvm: `PriorityQueue` produced invalid bytecode (`VerifyError` on Java 8) — a bound method reference inside the `@:generic` specialization; replaced with a capture-free comparator lambda
- jvm: `SwitchTable.make` dispatchers with mixed String/Int keys crashed with `ClassCastException` — a Dynamic-subject switch containing an Int case coerces the subject with `Jvm.toInt`; the macro now emits an if-chain through Dynamic-typed comparison/dispatch helpers
- jvm: `Vector` `every`/`some`/`filter` always returned false/empty — `Reflect.callMethod` arity-mismatch behavior differs on jvm, breaking the callback-arity fallback; the closure's real arity is now resolved reflectively and called directly
- with these fixes the jvm smoke suite passes fully on Java 8 (previously: 4 `VerifyError`s plus 2 failing tests)
- `haxe.Timer` allocated its id from a static counter outside the lock guarding the timer map, so two threads creating timers concurrently could take the same id and the second registration evicted the first — a timer that silently never fired
- `HTTPBackendRegistry` mutated a shared array without synchronization while `resolve()` read it from request threads; mutation now publishes a new array under a lock and lookups iterate a stable snapshot
- `ProcessLifecycle` guards its callback list, so registering from a worker thread while the runtime thread dispatches can no longer drop or double-run a callback

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
