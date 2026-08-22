# Proposal 0012 — Deferred TLS handshake for accepted WebSocket sessions

**Status:** Implemented

**Motivation:** Proposal 0010 identified that `ServerWebSocket` had no
handshake timeout, so a peer that completed TCP and then stalled mid-TLS
held a socket on a `wss://` server with nothing to reclaim it — the
half-open exposure proposal 0002 closed for `ServerSocket`.

Fixing it turned out to need far less new machinery than expected, and
surfaced a second, more serious defect.

---

## The actual gap was one missing branch

The deferred, timeout-guarded TLS handshake **already existed**:
`__initSSLHandshake()` sets a deadline and installs a tick listener, and
`__onTickSSLHandshake()` steps the handshake each tick, retrying while it
is blocked and closing with 1015 when the deadline passes.

It was simply never reached for accepted sockets. `__initSocket()` branched
on whether it was given a socket:

```haxe
if (socket == null) {          // client: connect, then __onConnect()
    ...                        //         -> __initSSLHandshake() when secure
} else {                       // accepted: server side
    __socket = socket;
    __openConnection(null);    // <- straight past the TLS handshake
}
```

So a client `wss://` connection got a bounded handshake and an accepted one
did not: its TLS handshake happened implicitly on the first read inside
`sys.ssl.Socket`'s input, with no deadline attached. The fix is to take the
same branch the client path takes, keyed on `__socket.isSecure` rather than
`__secure` (an `AcceptedWebSocket` is constructed without host/secure
arguments, so only the socket knows).

## The second defect: a failed handshake read as a successful one

`__onTickSSLHandshake()` tracked a single `doClose` flag:

```haxe
try { __socket.handshake(); }
catch (e:Error)   { if (e == Error.Blocked) doClose = true; }
catch (e:Dynamic) { doClose = true; }

if (doClose) { if (timedOut) __close(1015); }
else         { __openConnection(...); }        // treated as success
```

The flag conflated "needs more data" with "give up", and its `else` branch
meant **any typed error that was not `Blocked` fell through to
`__openConnection()`** — a failed TLS handshake promoted to an open
session. Genuine failures also idled until the 3-second deadline instead
of closing at once.

Rewritten around three explicit outcomes — completed, needs more data,
failed — so a terminal error closes immediately and only a stalled peer
waits out the deadline. This affects the client path too, where it was
equally wrong.

## Two further defects the verification exposed

Neither would have been found without driving a real `wss://` client; both
were invisible to the unit suites.

### `ServerWebSocket.bind()` never resolved an ephemeral port

`ServerSocket.bind()` reports the port the operating system assigned when
asked for port 0. `ServerWebSocket.bind()` assigned the *requested* value,
so `localPort` stayed 0 and a caller had no way to learn where to connect.

This also silently weakened the drain tests: they bound to 0, read back 0,
and "rebound" the successor to 0 — which just picks another free port, so
the assertion that the listener had been released proved nothing. Fixed,
and the test now asserts `localPort > 0` first so the rebind check is
meaningful.

### `__openConnection()` conflated "retire a listener" with "act as client"

Its `tickListener` parameter did double duty: a non-null listener meant
both *remove this listener* and *send the client upgrade request*. The old
accepted path passed `null` and so stayed silent by accident rather than
by intent. Routing accepted TLS sessions through the handshake gave them a
listener to retire, and the server promptly sent a client-style
`GET null HTTP/1.1` at its own client — a regression this change
introduced and the harness caught immediately.

Now the role decides: only `__isClient != false` sends the upgrade
request, and listener retirement is independent. Keying on role rather
than on an incidental argument is what makes the accepted-TLS path
correct.

## Testing

A native harness runs a real `wss://` server against two peers at once:

- a genuine `sys.ssl.Socket` client that completes TLS and the WebSocket
  upgrade, confirming the deferred path did not break the working case
  (the server must answer `101 Switching Protocols`); and
- a peer that completes TCP and then goes silent, which is the case that
  used to hold a socket indefinitely.

Verifying the *timeout* itself is inherently a waiting test — the peer
must out-wait the deadline — so it is exercised in this harness rather
than added to the unit suites, matching how the socket-backpressure case
is handled.

## Seams left open

| Growth item | Notes |
|---|---|
| **Server-configured handshake timeout** | The deadline is a hardcoded 3 s in the WebSocket layer. `ServerWebSocket` inherits `handshakeTimeout` from `ServerSocket`, which currently does not reach it; plumbing it through `fromAcceptedSocket` would make the inherited property meaningful. |
| **Pending-handshake visibility** | `ServerSocket.pendingHandshakeCount()` counts its own queue; the WebSocket handshake is owned per-session, so a server-level count would need collecting from sessions. |
| **Backpressure on accepted sessions** | `Socket.maxOutputBufferSize` is still not applied to accepted WebSocket sessions, which is where a fan-out server wants it most. |
