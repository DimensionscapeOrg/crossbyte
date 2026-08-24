# Proposal 0002 — Direct TLS termination in `ServerSocket`

**Status:** Implemented (prototype scope)

**Motivation:** `ServerWebSocket` could serve `wss://`, but `ServerSocket`
and everything built on it — including `HTTPServer` — were plaintext-only.
A server framework that cannot serve HTTPS without a front proxy has a
credibility gap, and some deployments want a single binary with no proxy at
all.

---

## What landed

- `new ServerSocket(secure = true)` allocates an `sys.ssl.Socket` listener.
  Because `sys.ssl.Socket` extends `sys.net.Socket`, the existing
  `select()`/`accept()` paths are unchanged.
- `setCertificate(cert, key)` and `addSNICertificate(match, cert, key)`
  install TLS material. Both throw on a plain server and after `bind()` —
  the stdlib materializes the TLS configuration during `bind()`, so later
  changes would silently not apply. `listen()` throws when a secure server
  has no certificate, so a listener can never be live with a handshake that
  cannot succeed.
- `requireClientCertificate(ca)` opts into mutual TLS: clients must present
  a certificate signed by `ca` or fail the handshake before any `connect`
  event.
- **Server sockets do not request client certificates by default.**
  `sys.ssl.Socket` leaves `verifyCert` at `null`, which the stdlib maps to
  mbedTLS `VERIFY_REQUIRED`; on a *server* configuration that demands a
  client certificate, so every ordinary HTTPS client fails the handshake
  with "No client certification received". A secure listener therefore sets
  `verifyCert = false` at construction, and mTLS is opt-in through
  `requireClientCertificate()`. (This also explains the same assignment in
  `ServerWebSocket` — it is required for a server that is not doing mTLS,
  not a weakened default.)
- **Non-blocking handshake queue.** An accepted TLS connection is *not*
  dispatched as `connect`. It enters a pending queue, and each tick calls
  `handshake()` once per pending connection: a blocked error means "resume
  next tick", success promotes it to a normal `connect` event, and failure
  or `handshakeTimeout` (default 10s) closes it silently. The runtime loop
  is never blocked by a slow or hostile peer, and half-open connections
  cannot accumulate.
- `pendingHandshakeCount()` exposes queue depth for tests and metrics.
- `HTTPServerConfig.tlsCertificatePath` / `.tlsKeyPath` (and derived
  `tlsEnabled`) turn `HTTPServer` into an HTTPS server. These are plain
  fields rather than constructor parameters, so the existing positional
  constructor stays source-compatible.
- jvm: secure construction throws — `sys.ssl.Socket` does not compile there
  (see `_internal/socket/_jvm/JvmSsl`). Plain servers are unaffected.

## Deliberate non-goals (the seams left open)

The prototype is intentionally small. Each item below has a defined
insertion point so it can land without reworking what exists:

| Growth item | Where it plugs in |
|---|---|
| **ACME / auto-certificates** | A cert provider that calls `setCertificate()` before `listen()` and re-installs on renewal. Needs a listener-level cert-swap path (today certificates are immutable once listening) plus an HTTP-01/ALPN-01 challenge responder. This is what would remove Caddy from the self-host stack. |
| ~~**ALPN** (`h2`, `http/1.1` negotiation)~~ | Done. The passthrough Haxe's stdlib does not expose is a native bridge, as this row expected -- `AlpnSocket` and `NativeAlpn` alongside the sodium and blake3 ones. `ServerSocket.setALPN()` offers protocols, `Socket.alpnProtocol` reports what a peer agreed to, and `ServerSocket.alpnSupported` says where that reaches the handshake rather than being accepted and ignored. It was the prerequisite named here, and HTTP/2 followed it. |
| **mTLS peer inspection** | `requireClientCertificate()` enforces client certificates today, but the accepted `crossbyte.net.Socket` does not yet surface `peerCertificate()`, so applications cannot read the verified client identity. |
| **Handshake fairness under load** | Today every pending handshake is stepped each tick. At thousands of concurrent handshakes this wants a per-tick budget and a readiness-driven queue (poll for readable before stepping) rather than a linear sweep. |
| **Session resumption / tickets** | mbedTLS supports it; needs stdlib or bridge exposure. Meaningful only once measured. |
| **`ServerWebSocket` convergence** | It carries its own TLS wiring and a separate `FlexSocket`. Once this path is proven, the two should share one implementation. |

## Testing

- Unit (`tests/crossbyte/net/ServerSocketTLSTest.hx`): plain-server
  defaults, TLS-configuration rejection on a plain server, certificate
  required before `listen()`, TLS material immutable once bound, jvm
  rejection.
- End-to-end: a real handshake against a real `sys.ssl.Socket` client with
  application bytes flowing both directions, asserting the tick loop is
  never stalled and the pending queue drains. Uses a throwaway self-signed
  certificate generated at test time via the `openssl` CLI
  (`tests/crossbyte/net/TLSTestFixture.hx`), cached in the temp directory
  and skipped when no toolchain is present — nothing expirable is committed.

## Operational note

Direct TLS does not make the reverse proxy obsolete for the hosted
deployment: Caddy still supplies automatic certificate issuance and renewal,
HTTP/2 and HTTP/3 at the edge, and redirect handling. This change serves the
proxy-free single-binary case and closes the capability gap.
