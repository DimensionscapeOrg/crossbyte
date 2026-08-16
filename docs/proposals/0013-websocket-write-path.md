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

Why this survived is mundane, and the answer only looks interesting if
you measure it wrong — which I did, twice, before getting it right.

- The frame-level tests construct sessions directly and feed frames in,
  skipping the handshake entirely, so they exercise the parser but never
  the buffer state it inherits from a handshake.
- The one exercise that *did* cover the real path — the websocket echo
  sample — was compiled in CI and never run.

That is all it took. Built against the pre-fix source the sample fails
outright: `FAIL: no echo received within 5s.`, exit 1. Executing it at
any point would have caught this on the commit that introduced it.

**A retracted claim.** In between I asserted the opposite here: that the
sample passed against pre-fix code, and therefore that the real gap was
CrossByte only ever being tested against itself. That was an artifact of
a broken experiment. I had been building "pre-fix" by putting an old copy
of one file on an earlier `-cp` ahead of `-cp src`, which does not shadow
anything — Haxe compiled `src` and ignored the override, so every such
run silently tested the fixed code and passed. A deliberate syntax error
in the override still compiled cleanly, which is what exposed it.

The working method is to copy the whole `src` tree, replace the file in
the copy, and build with only that copy on the classpath. Validated
against a known-failing control before trusting any result from it.

Two things worth keeping from the detour. Test-methodology notes are in
`tests/stress/README.md`, because a reverted build that is not actually
reverted looks exactly like a test with no teeth. And a conformance suite
driven by a foreign client is still worth having on its own merits — not
because CrossByte's client is blind to this fault, since it is not, but
because a hand-written client can send what no cooperating client will.

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
| ~~**The websocket echo sample was compiled, never run**~~ | Closed: the Windows native job runs the built binary. This is the check that was missing — the sample fails against the pre-fix source, so running it would have caught the read-path bug immediately. It now also compares the echoed payload instead of accepting any bytes back, and reports failure with an explicit exit status rather than a thrown error (an uncaught throw leaves hxcpp exiting 127, which reads as "command not found" in a build log). |
| ~~**Only CrossByte's own client exercised the server**~~ | Closed by `tests/crossbyte/net/WebSocketConformanceTest.hx`: fourteen cases driven through a real handshake by `RawWebSocketClient`, which composes frames by hand. Covers fragmentation, a control frame between fragments, pipelined frames in one write, a frame split across writes, extended lengths, and every rejection RFC 6455 requires. Eight of the fourteen fail against the pre-fix source. Its value is not that CrossByte's client is blind to that particular fault — it is not — but that a hand-written client can send what no cooperating client will. |
| **Six conformance cases pass against the pre-fix source** | The rejection cases that assert 1002 passed even with the read path broken, because a broken server closed *everything* with 1002. They were right for the wrong reason. Asserting a specific close code is weaker than it looks when one code is also the failure mode; pairing each rejection with a positive case on the same session would tighten it. |
| **Conformance coverage is server-side only** | The suite drives CrossByte's *server* with a foreign client. The mirror case — CrossByte's client against a foreign server — is still untested, and the client parser has its own masking and continuation rules. A recorded byte-stream fixture would cover it without needing a second implementation to talk to. |
| **The other samples are still only compiled** | Ten sample tasks still stop at a build. Several are long-running servers with no natural exit, so each needs its own decision about what "ran successfully" means. The websocket echo sample was the easy one: it already drove both ends and terminated. |
| **The sample runs on Windows only** | It executes in the Windows native job, since that is where the samples are built. The path it covers is platform-independent, so the same run belongs on Linux and macOS; those jobs currently build only the crypto suite. |
| **Frame tests bypass the handshake** | The protocol-error suites construct sessions directly and feed frames in, so they exercise the parser but never the buffer state it inherits from a real handshake. That gap is exactly where this bug lived. |
| ~~**`trace()` in the WebSocket read loop**~~ | Closed. A normal disconnect used to print `Error Reason:,Eof` and `closed from remote host` through `trace` — unfilterable, and reading as an error when it is not one. Remote closes and heartbeat timeouts now go to `Logger.debug`, genuine read failures to `Logger.warn`. |
| **`trace()` elsewhere in the library** | This pass covered the WebSocket read loop only. A sweep for `trace(` across the rest of `src/` is worth doing before 1.0, since any of it is unfilterable in a deployed server. |
