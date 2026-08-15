# Proposal 0003 — Graceful shutdown

**Status:** Implemented on branch `server-hardening`

**Motivation:** Proposal 0001 added `ProcessLifecycle`, which converts an
operating-system stop signal into an orderly callback on the runtime
thread. But it had nothing meaningful to call: servers could only be
`close()`d outright, which severs live requests mid-response. A deploy,
service restart, or `docker stop` would drop in-flight work.

---

## What landed

All additions; no existing signature or behavior changed.

### `ServerSocket.stopAccepting()`

Releases the listening socket while leaving established connections open
and usable. Any connection still completing a TLS handshake is dropped
(it has no application state to preserve).

Releasing the listener early matters for deploys: the port becomes
available to a successor process immediately, so a restart does not have
to wait for the old process to finish serving. Unlike `close()`, no
`close` event is dispatched and the server is not marked closed.

`close()` now tolerates an already-released listener, so
`stopAccepting()` followed by `close()` is safe. Both are idempotent.

### `HTTPServer.drain(timeoutSeconds = 30, ?onComplete)`

The full sequence:

1. `stopAccepting()` — no new connections, port freed.
2. Wait for in-flight requests, polling connection count each tick.
3. On reaching zero (or on timeout) close whatever remains and `close()`
   the server, then invoke `onComplete` on the runtime thread.

Supporting members: `activeConnections` and `draining`. Repeat `drain()`
calls are ignored, so a shutdown callback that fires more than once cannot
restart teardown or double-invoke the completion callback. With no active
connections, or `timeoutSeconds <= 0`, shutdown completes synchronously
rather than deferring a tick.

### Composed usage

```haxe
var server = new HTTPServer(config);

ProcessLifecycle.onShutdown(() -> server.drain(30, () -> Logger.info("bye")));
ProcessLifecycle.installDefaultHandlers();
```

`Ctrl+C`, a Windows service stop, or `SIGTERM` now finishes in-flight
responses instead of cutting them off.

## Testing

- `tests/crossbyte/net/ServerSocketDrainTest.hx`: listener released and
  the port genuinely rebindable by a successor; `stopAccepting()`
  idempotent and safe before `close()`; no-op on an unbound server, which
  remains usable afterwards.
- `tests/crossbyte/http/HTTPServerDrainTest.hx`: immediate completion with
  no traffic, state transitions, port rebindable after drain, idempotence
  (callback fires exactly once), and safety without a callback.

## Seams left open

| Growth item | Notes |
|---|---|
| **Connection-level drain semantics** | Today a draining server waits for connections to close. HTTP keep-alive connections may idle for their full timeout; sending `Connection: close` on in-flight responses would end them promptly. |
| **`ServerWebSocket` drain** | Needs its own notion of "in-flight" (a WebSocket is long-lived by design); likely a close-frame broadcast with a grace period. |
| **Automatic lifecycle binding** | `HTTPServer` could self-register with `ProcessLifecycle`. Left explicit so a process with several servers controls shutdown order. |
| **Drain progress reporting** | Only start and finish are logged; a metrics counter would suit long drains. |
