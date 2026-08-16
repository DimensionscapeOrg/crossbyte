# Proposal 0013 — WebSocket read/write paths and accepted-connection limits

**Status:** Implemented on branch `main`

**Motivation:** This began as one question — what should a server do when
a peer stops reading? — and the WebSocket write path answered it two
different ways in two places, both wrong. The limits added in proposal
0006 also could not be reached on connections a server accepted, which is
exactly where they matter.

Writing tests for the fix then exposed two defects considerably worse
than the one it set out to correct: a server could not receive a client
message at all, and a socket closed mid-write took down the entire
runtime loop. Both are recorded below, because how they stayed hidden
matters as much as what they were.

---

## The bug: a full send buffer treated as two different things

`crossbyte._internal.websocket.WebSocket` wrote to its socket from two
sites, and they disagreed about what a blocked write meant.

- `__writeBytes` caught the blocked write and called `trace(e)`. The bytes
  were **discarded**. Nothing failed, nothing was logged above trace level,
  and the peer simply never received that frame.
- `__sendFrame` caught the same condition and called `__close(1006, null)`,
  **killing the session** and reporting an abnormal closure.

So a peer whose receive buffer filled for a moment — a phone on a weak
signal, a browser tab in the background, a client doing a slow render —
either lost messages silently or lost the connection. Which one depended
on nothing more than which code path had produced the bytes.

Neither is right. A non-blocking socket accepting fewer bytes than offered
is the *normal* signal that its send buffer is momentarily full. It is not
an error, and it is not permission to drop data. It means: keep the rest
and try again shortly.

### What replaced it

Both sites now funnel through one buffer:

- `__queueOutput` appends to a pending buffer and attempts a flush.
- `__flushPendingOutput` writes what the socket will take, keeps the
  remainder, and is retried from `__onTickProcess`. It honours the byte
  count a partial write returns rather than assuming all-or-nothing, and
  it closes only on a genuine I/O error.
- `maxOutputBufferSize` bounds the buffer. Past it the session is closed
  with 1011, because a buffer that only grows means the peer has stopped
  draining and will not resume.

Retention is unconditional up to that bound. Frames are never dropped to
stay under it — the session is given up on instead, which is a failure the
application can see rather than one it cannot.

`outputBufferLength` exposes what is still waiting, mirroring
`Socket.outputBufferLength`.

## Reaching the limits on accepted connections

Proposal 0006 left this as a seam, and it was the important half: an
application never sees a socket a server accepted until after the server
has written to it, so a per-connection limit was only reachable from the
server itself.

- **`HTTPServerConfig.maxOutputBufferSize` / `outputOverflowPolicy`** —
  applied to every socket `HTTPServer` accepts.
- **`ServerWebSocket.maxOutputBufferSize`** — applied to every session it
  accepts, before any application listener runs, so a session is never
  briefly unbounded.

Both default to `0`, unchanged behavior.

### One correction worth recording

`crossbyte.net.WebSocket` extends `Socket`, so it already inherited
`maxOutputBufferSize` — but it writes through its framing layer rather
than the inherited output buffer, so that inherited field governed a
buffer that stays empty. Setting it did nothing, silently.

`Socket.maxOutputBufferSize` and `outputBufferLength` are therefore now
properties rather than plain fields, and `WebSocket` overrides the
accessors to address its own buffer. This is source-compatible — callers
are unchanged — and it removes a trap that would have been worse than a
missing feature, since it looked like protection.

The accessors are deliberately **not** inlined: `inline` forbids
overriding, and the override is the entire point. They are read once per
flush, not per byte, so the virtual call costs nothing measurable.

## Testing

Two stress cases, which together pin the boundary between "retain" and
"give up":

- `tests/stress/WebSocketRetentionStress.hx` — 200 frames of 16 KB
  (3.2 MB, far past any loopback send buffer) to a peer that stalls and
  only then drains. Asserts every frame arrives, intact and in order, and
  the session survives. Verified to **fail on the pre-fix code**, where the
  session was destroyed mid-send and the next write raised
  `Operation attempted on invalid socket`.
- `tests/stress/WebSocketBufferLimitStress.hx` — the same fan-out at a peer
  that never reads, with a 256 KB limit. Asserts the buffer stays bounded
  (allowing one frame of overshoot, since the check runs after the write
  that crosses the line) and the session is closed. Observed: 183 of 400
  frames queued, 245 KB peak, closed by policy.

Frames carry a per-frame byte pattern rather than a counter in the first
bytes only, so a dropped frame surfaces as a wrong value at a known index
instead of merely a short count.

### The read path could not receive a client message at all

Adding a test for the read side turned up the largest defect here: **a
WebSocket server never successfully received a message from a client.**

The server-side handshake parses the HTTP request with
`raw.getString(start, headerLength)`, which reads without moving the
buffer cursor. The cleanup that followed called
`__validateInputPosition()`, which only clears the buffer when
`bytesAvailable` is zero — and it never was, because the request bytes
were still sitting there unconsumed.

So the buffer entered `OPEN` still holding the upgrade request. The first
frame the peer sent was appended after it, and frame parsing began at
offset zero: the `G` of `GET`. `0x47` has RSV1 set, so the very first
check in the frame loop closed the session with 1002 as a protocol error.
Every server-side session lost the client's first message and the
connection along with it.

The handshake bytes are now dropped unconditionally once the upgrade
completes, with pipelined data (the `extra` case, which was already
handled) preserved.

Why this survived, and a correction worth recording. My first assumption
was that the websocket echo sample would have caught it and simply was
never run in CI. That is **wrong**, and measurably so: built against the
pre-fix source the sample still passes, exit 0, echo intact.

The real reasons are narrower and more interesting:

- The frame-level tests construct sessions directly and feed frames in,
  skipping the handshake entirely, so they exercise the parser but never
  the buffer state it inherits from a handshake.
- Every end-to-end exercise used **CrossByte's own client** on both ends,
  and that client reaches the handshake buffer by a path which avoids the
  fault. Only a raw client — a hand-rolled request and frame, which is
  what a browser is — leaves the buffer in the state that breaks.

So the gap was not merely "samples are not run." It was that nothing
tested CrossByte against a client other than itself, which is precisely
the case every real deployment consists of.

`tests/stress/WebSocketFinalMessageStress.hx` closes it: a raw peer
completes an actual handshake, sends a masked text frame, and the server
must surface it. That case fails against the pre-fix code; the sample
does not.

### A closed socket mid-write took down the whole runtime loop

`WebSocketRetentionStress` passed alone and failed in the full suite,
throwing `Operation attempted on invalid socket` out of `pump()` before it
did any work. That difference was the finding, not a flake.

`Socket.flush()` schedules the retry half of a blocked write with
`Timer.delay(__tryFlush, 0)`. If the socket is closed before that timer
fires — peer disconnect, application close, or the overflow policy —
`__tryFlush` called `flush()` on a released socket, which raised.

The retry runs inside the runtime's tick dispatch, so the exception did
not fail that one connection. It escaped `pump()` and stopped the loop
serving **every** connection in the process. Reaching it needs only a
peer that disconnects while a write is blocked, which on a busy server is
routine rather than exotic.

`__tryFlush` now returns when the socket is gone: there is nothing left to
retry, and the connection has already been accounted for by whatever
closed it. `tests/stress/SocketDeferredFlushStress.hx` closes a socket
with a retry outstanding and asserts thirty subsequent pumps all complete.

Worth stating plainly: the preceding case in the suite is what exposed
this, because it left a closed socket with a pending retry and nothing
after it pumped. Cases sharing one process and one runtime is usually a
liability in a test suite; here it was the only reason the bug was
visible at all.

## Seams left open

| Growth item | Notes |
|---|---|
| **A drain event** | Still only overflow is signalled. A "buffer emptied" event would let a producer resume without polling `outputBufferLength`. |
| **Close frame on overflow** | The 1011 path closes the socket rather than sending a close frame first, matching the existing 1006 behaviour. A peer that has stopped reading would not see the frame anyway, but a peer that stopped reading *temporarily* would. |
| **Sensible non-zero defaults** | Every limit here still defaults to `0`. Choosing real defaults is a 1.0 decision, and needs a view on what the largest legitimate message is per protocol. |
| **Per-connection buffer metrics** | `outputBufferLength` is now available on WebSocket sessions too; binding it as a gauge still needs a cardinality-safe aggregate rather than one series per peer. |
| ~~**The websocket echo sample was compiled, never run**~~ | Closed: the Windows native job now runs the built binary. Be clear about what that buys, though — the sample passes against the pre-fix source, so it would **not** have caught the bug above. What it does give is the first end-to-end round trip CI has ever executed, which covers gross regressions in the handshake, the write path, and the deferred-flush crash. The sample now also checks the echoed payload instead of accepting any bytes back, and reports failure with an explicit exit status rather than a thrown error (an uncaught throw leaves hxcpp exiting 127, which reads as "command not found" in a build log). |
| **Nothing tests CrossByte against a non-CrossByte client** | The real gap the read-path bug exposed. Both ends of every end-to-end exercise are CrossByte, so a fault only a foreign client reaches stays invisible — and every real deployment is exactly that case. `WebSocketFinalMessageStress` is currently the only raw-client coverage; a small suite of hand-rolled conformance cases (fragmentation, control frames interleaved with data, pipelined frames, oversized payloads) would be worth more here than running the remaining samples. |
| **The other samples are still only compiled** | Ten sample tasks still stop at a build. Several are long-running servers with no natural exit, so each needs its own decision about what "ran successfully" means. The websocket echo sample was the easy one: it already drove both ends and terminated. |
| **The sample runs on Windows only** | It executes in the Windows native job, since that is where the samples are built. The path it covers is platform-independent, so the same run belongs on Linux and macOS; those jobs currently build only the crypto suite. |
| **Frame tests bypass the handshake** | The protocol-error suites construct sessions directly and feed frames in, so they exercise the parser but never the buffer state it inherits from a real handshake. That gap is exactly where this bug lived. |
| ~~**`trace()` in the WebSocket read loop**~~ | Closed. A normal disconnect used to print `Error Reason:,Eof` and `closed from remote host` through `trace` — unfilterable, and reading as an error when it is not one. Remote closes and heartbeat timeouts now go to `Logger.debug`, genuine read failures to `Logger.warn`. |
| **`trace()` elsewhere in the library** | This pass covered the WebSocket read loop only. A sweep for `trace(` across the rest of `src/` is worth doing before 1.0, since any of it is unfilterable in a deployed server. |
