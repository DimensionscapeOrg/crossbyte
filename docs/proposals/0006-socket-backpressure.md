# Proposal 0006 — Socket write backpressure

**Status:** Implemented on branch `main`

**Motivation:** `Socket` buffers writes until the operating system accepts
them, and that buffer had no ceiling. A peer that stops reading — a phone
that slept, a half-open connection, a deliberately slow client — makes it
grow until the process runs out of memory. On a server fanning out to many
connections, a single such peer can take the whole process down while
every other connection looks healthy.

`flush()` already handled partial writes and blocked sockets correctly;
what it lacked was a bound. The source carried a standing
`// TODO: see if flush backpressure is an issue`.

---

## What landed

Three additive members on `crossbyte.net.Socket`:

- **`maxOutputBufferSize`** — bytes allowed to accumulate before the
  policy fires. Defaults to `0` (no limit), preserving existing behavior
  exactly.
- **`outputOverflowPolicy`** — `CLOSE` (default) dispatches
  `IOErrorEvent.IO_ERROR` and closes the connection; `THROW` raises
  `IOError` from `flush()` and leaves the connection open. `CLOSE` is the
  right server default: a peer that has stopped reading will not recover,
  and dropping it reclaims memory without every write site needing error
  handling. `THROW` suits producers that can shed load or pause instead.
- **`outputBufferLength`** — bytes still waiting. A value climbing across
  flushes means the peer is not draining as fast as this side produces;
  it is a natural metrics gauge and a signal to stop enqueueing.

The limit is enforced after a flush has moved whatever the OS would
accept, so what remains is genuinely undrained data rather than a normal
in-flight write. It is also checked when a flush is skipped because an
earlier one is still blocked, since callers may keep enqueueing while it
drains.

### On the default

The limit is opt-in rather than a built-in ceiling. Unbounded growth is a
real hazard, but silently closing connections in an application that
legitimately buffers large messages would be a breaking change, and this
is an rc. Services should set a limit sized to their largest legitimate
message with headroom — a few megabytes suits most protocols.

Making some finite default the 1.0 behavior is worth revisiting, together
with `HTTPServer` and `ServerWebSocket` setting sensible limits on the
connections they accept.

## Testing

`tests/stress/SocketBackpressureStress.hx` connects a peer that never
reads a byte, then writes 25 MB at it through a socket limited to 256 KB.
The invariants: the buffer stays bounded (allowing one chunk of overshoot,
since the check runs after the write that crosses the line) and the
connection is closed by policy. Without the limit that same harness
buffers the full payload in memory.

## Seams left open

| Growth item | Notes |
|---|---|
| ~~**Default limits on accepted connections**~~ | Landed in proposal 0013: `HTTPServerConfig.maxOutputBufferSize` and `ServerWebSocket.maxOutputBufferSize` apply to every connection those servers accept. Still opt-in — the defaults remain `0`. |
| **A drain event** | Only overflow is signalled. A "buffer emptied" event would let producers resume cleanly rather than polling `outputBufferLength`. |
| **High/low watermarks** | A single threshold means a producer resumes at the same point it stopped. Separate watermarks avoid oscillating at the boundary. |
| **Per-connection metrics** | `outputBufferLength` is pollable; binding it as a gauge per connection needs a cardinality-safe aggregate (max or histogram across connections, never one series per peer). |
