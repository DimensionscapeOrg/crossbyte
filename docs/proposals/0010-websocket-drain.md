# Proposal 0010 — ServerWebSocket drain, and the TLS convergence question

**Status:** Drain implemented on branch `main`; convergence assessed and
scoped, not yet done

**Motivation:** Proposal 0003 gave `HTTPServer` graceful shutdown, leaving
`ServerWebSocket` as the one server type that could only be severed. That
matters more for WebSockets than for HTTP: sessions are long-lived, so a
process restart drops every live connection at once, and clients cannot
tell an orderly shutdown from a network failure.

---

## What landed

### Client tracking

`ServerWebSocket` did not know its own clients. It now observes the
`CONNECT` event it already dispatches to itself once a handshake
completes, and drops each session on `CLOSE` — so the registry needs no
cooperation from `WebSocket` and nothing new to keep in sync.
`clientCount` exposes the total.

### `stopAccepting()`

Releases the listening socket while leaving sessions usable, freeing the
port for a successor process during a deploy. `close()` tolerates an
already-released listener, and both are idempotent. Mirrors
`ServerSocket`, overridden because `ServerWebSocket` owns a separate
listening socket.

### `drain(timeoutSeconds, ?onComplete, closeCode)`

A WebSocket session is long-lived by design, so unlike an HTTP request
there is nothing to "finish". Draining therefore means telling clients to
go away: every session gets a **close frame** (default code 1001, "going
away"), and sessions still open at the timeout are dropped.

Sending a close frame rather than severing the socket is the point — it
is what lets a client distinguish an orderly shutdown from a network
failure and reconnect sensibly instead of treating it as an error. The
new `WebSocket.closeWith(code, reason)` exposes that; the existing
`close()` is unchanged.

Repeat `drain()` calls are ignored, so a shutdown callback firing twice
cannot restart teardown or double-invoke the completion callback.

## The convergence question, answered

Investigating this corrected an assumption worth recording, because it
changes what "convergence" means:

**`crossbyte._internal.websocket.FlexSocket` is not a second
implementation.** It is a five-line typedef alias to
`crossbyte._internal.socket.FlexSocket`. Both servers already share one
TLS abstraction, so there is no duplication to remove.

What actually differs is **handshake handling**:

| | `ServerSocket` (proposal 0002) | `ServerWebSocket` |
|---|---|---|
| Certificate installed | before `bind()`, enforced | via `cert` setter |
| Handshake | deferred queue, stepped per tick | implicit, on first read |
| Handshake timeout | `handshakeTimeout`, default 10s | **none** |
| Queue depth visible | `pendingHandshakeCount()` | no |

The gap that matters is the **missing timeout**. A peer that completes
the TCP connection and then stalls mid-TLS occupies a socket on a `wss://`
server with nothing to reclaim it — the same half-open exposure proposal
0002 closed for `ServerSocket`. It is bounded by OS socket limits rather
than being unbounded, so it is a hardening gap rather than an outage
waiting to happen, but it is real.

That work is deliberately **not** bundled here: it means moving
`ServerWebSocket` onto the deferred-handshake accept path, which touches
the accept loop that the WebSocket upgrade depends on, and is worth doing
with its own tests rather than appended to a drain change.

## Testing

`tests/crossbyte/net/ServerWebSocketDrainTest.hx`: listener released and
idempotent, `close()` safe afterwards, immediate completion with no
clients, port rebindable by a successor, drain idempotent (callback fires
exactly once), and safety without a callback or on a server that never
listened.

Not covered: draining with live sessions attached, which needs a real
WebSocket client driving a handshake. Worth adding alongside the
handshake work.

## Seams left open

| Growth item | Notes |
|---|---|
| **Deferred handshake + timeout** | The convergence item above; closes the half-open `wss://` exposure. |
| **Drain with live sessions** | Needs a client harness; would also cover close-frame delivery end to end. |
| **`ServerWebSocket` metrics** | Sessions, handshake queue depth, and drain progress are all natural gauges now that a registry exists. |
| **Per-session backpressure** | `Socket.maxOutputBufferSize` is not applied to accepted sessions; a fan-out server wants it there most. |
