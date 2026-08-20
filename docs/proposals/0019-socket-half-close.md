# Proposal 0019 — Socket half-close

**Status:** Implemented

**Motivation:** `crossbyte.net.Socket` collapses two different facts into one.
When a read ends, the reason is discarded:

```haxe
} catch (e:Eof) {
    doClose = true;
```

`Eof` means the peer sent FIN — it will send nothing further. It does not mean
the connection is over. A peer that half-closes its write side to say "that is
my whole request" is still there, still reading, still waiting for an answer.
CrossByte answers by calling `__cleanSocket()` and dispatching `Event.CLOSE`,
which reaches `HTTPRequestHandler.__onStreamSocketGone` and aborts the transfer
with the comment "the response is unfinishable" — about a peer that is perfectly
capable of finishing it.

This is the same defect the runtime had in `maxDelta`: a measurement discarded
inside the framework, unrecoverable by the consumer, with no signal that
anything was withheld. The consumer cannot opt out of a fact it is never told.

Half-close is not an exotic idiom. "Send the request, shut the write side, read
until EOF" is how a great many hand-rolled TCP protocols mark end-of-request,
and it is the one framing signal available to a protocol that does not want to
length-prefix. CrossByte is a general-purpose networking framework — HTTP is one
consumer of the socket, not its definition — and a socket that cannot express
half-close cannot host those protocols at all.

---

## What the platform actually does

Measured, not assumed, on Windows/cpp through the vendored `sys.net.Socket`
(`docs/proposals/0019-probe.md` reproduces it):

| | peer half-closes (`shutdown(false, true)`) | peer fully closes |
|---|---|---|
| server read terminates with | `Eof` | `Eof` |
| server write after that | **succeeds** | **succeeds** |
| peer receives it | **yes** | no |

Two findings, and the second is the one that shapes the design.

**Half-close works.** The server read `PING`, took `Eof`, wrote
`PONG-AFTER-PEER-FIN`, and the half-closed client received it. The capability is
real; only CrossByte's handling of it is missing.

**`Eof` is ambiguous.** A departed peer produces the identical `Eof`, and the
first write after it *also* succeeds — it lands in the kernel send buffer, and
the RST only surfaces on a later write. So at the moment of `Eof` there is no
signal, and no cheap probe, that separates "half-closed and waiting" from
"gone".

That rules out the obvious fix. "Stop closing on `Eof`" would hold every
departed connection open too, for as long as nothing else wrote to it — a
connection leak dressed as a feature. Which direction is right is not knowable
from the socket, so it is not the socket's decision to make.

---

## Design

A policy the consumer owns, following `outputOverflowPolicy`, which already
exists on this class for the same shape of question.

```haxe
public var peerShutdownPolicy:PeerShutdownPolicy = CLOSE;
```

- **`CLOSE`** (default) — a peer FIN ends the connection. Exactly today's
  behaviour, so nothing that exists changes.
- **`HALF_OPEN`** — a peer FIN ends the read direction only. The socket stops
  reading, reports it, and stays writable until the consumer closes it.

Alongside it:

- **`peerShutdown:Bool`** — whether the peer has stopped sending. Readable under
  either policy, so a `CLOSE` consumer can still tell a graceful end from an
  error one.
- **`Event.PEER_CLOSE`** — dispatched when FIN arrives under `HALF_OPEN`,
  instead of `Event.CLOSE`. Under `CLOSE`, behaviour is unchanged and only
  `Event.CLOSE` fires.
- **`shutdown(read:Bool, write:Bool)`** — surfaced from the vendored socket,
  which already implements it on every target. Without it the framework can
  receive a half-close but not perform one, which is half an API.

### The caveat is load-bearing, not a footnote

`HALF_OPEN` keeps dead connections open exactly as readily as live ones, because
nothing distinguishes them. Any consumer selecting it **must** bound the
remaining lifetime itself — a deadline, a response that completes, a sweep. This
belongs in the doc comment on the enum value, not buried in a proposal, because
choosing `HALF_OPEN` without a bound is how a server runs out of descriptors.

### Why a policy and not a listener check

`__dispatchTick` gates on `hasEventListener`, and the same trick would work here:
keep the socket open if someone is listening for `PEER_CLOSE`. It is rejected
because it makes connection lifetime depend on whether a listener happens to be
attached, which is invisible at the call site and changes if a listener is
removed. `outputOverflowPolicy` is the established idiom for a lifecycle
decision the consumer owns, and it says what it does.

---

## HTTP is deliberately left on `CLOSE`

HTTP/1.1 frames every request body with `Content-Length` or chunked encoding, so
a client's FIN carries nothing the server did not already know, and half-close is
incompatible with keep-alive — you cannot reuse a socket whose write side is
shut. The clients that half-close are one-shot raw-socket clients, already on the
close path.

`HTTPRequestHandler` could later opt a streaming response into `HALF_OPEN` and
finish the transfer, bounded by the stream's own completion. That is a real
improvement for a narrow case and a separate change; it is not the reason this
proposal exists. The reason is that the socket layer should not decide, on behalf
of every protocol anyone builds on it, that a half-closed peer is a dead one.

---

## Testing

- half-closed peer under `HALF_OPEN` receives a response written after its FIN
- half-closed peer under `CLOSE` sees today's behaviour exactly
- `peerShutdown` is set under both policies
- `PEER_CLOSE` fires under `HALF_OPEN`; `CLOSE` fires under `CLOSE`; never both
- a departed peer under `HALF_OPEN` does not wedge the runtime — the socket
  survives until closed, which is the documented hazard rather than a bug

Each verified against the unmodified code first, since a test that passes
without its fix pins nothing.
