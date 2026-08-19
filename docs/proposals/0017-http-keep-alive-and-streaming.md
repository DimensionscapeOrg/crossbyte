# Proposal 0017 — HTTP keep-alive and streaming responses

**Status:** Implemented

**Motivation:** The server's response lifecycle is buffer everything, write,
close. `Connection: close` is hardcoded into every response path — the three
builders in `HTTPRequestHandler` and the 503 the server writes at capacity —
so every request pays TCP connection setup, and a full TLS handshake when
`tlsEnabled` is set, to be answered. And because `__serveFile` calls
`file.load()` before writing, a response body exists in memory twice — once
as the loaded file, once copied into the socket's output buffer — for as
long as the peer takes to drain it. A 2 GB download is 2 GB of resident
memory per concurrent request, and if `maxOutputBufferSize` is configured
the transfer is killed mid-flight for exceeding a limit the server itself
filled in one call.

These are one design problem, not two. Keep-alive means a response has to
end without the connection ending, which forces the same discipline —
explicit framing, explicit completion — that streaming needs. Doing either
alone means designing the response lifecycle twice.

---

## Connection lifecycle

A handler today is one-shot: parse, respond, close. It becomes a loop —
reading, dispatching, responding, idle — with the connection surviving the
response when all of these hold:

- the client is HTTP/1.1 without `Connection: close`, or HTTP/1.0 with an
  explicit `keep-alive` token;
- the response carries `Content-Length` (every current path does) — a
  response of unknown length forces close until chunked encoding exists;
- the response is not one after which handler state is suspect: 408, 413,
  400 and the 500 class close, matching what the error paths already do.
  A routine 404 keeps the connection, because a browser fetching a page
  with a missing favicon should not pay a new handshake for it.

Configuration: `keepAlive:Bool = true`, `keepAliveTimeout:Float = 5`,
`keepAliveMaxRequests:Int = 100`. Defaulting on is deliberate: it is what
HTTP/1.1 specifies, what every client already expects, and the reason the
whole class of per-request handshake cost disappears without anyone
touching their client code. `keepAlive = false` restores today's behavior
exactly.

Idle enforcement rides the receive-deadline sweep that proposal-adjacent
work just added (`requestTimeout`): between requests the connection's
deadline is `keepAliveTimeout`; the first byte of a next request re-arms
`requestTimeout`. One sweep, two meanings of the same timestamp, and an
idle fleet of persistent connections still costs one walk four times a
second.

## The buffer hazard this design exists to avoid

`__dispatchResponseBytes` ends with `__incomingBuffer.clear()`. Under
close-per-request that discards nothing that matters; under keep-alive it
discards the next request. A client that pipelines — sends request two
before response one returns — has bytes sitting in that buffer at clear
time, and clearing turns them into a hang: the client waits for a response
the server will never produce, then times out blaming the wrong end.

So per-request state reset becomes explicit and enumerated: headers, method,
path, query, encodings, body bookkeeping, and the header-scan carry — reset
per request, while `__incomingBuffer` keeps its unconsumed tail and parsing
resumes immediately if a complete next request is already sitting there.
Responses stay strictly serial; pipelining is honored by preservation, not
by concurrency.

`__beginRequestTiming` moves with this: it currently stamps at connection
accept, which under keep-alive would bill request N for the idle time since
request N-1. The stamp belongs at request start.

## Streaming file responses

`__serveFile` stops loading. Headers are written from `file.size` exactly as
now; the body is pumped through a `FileStream` in bounded slices — read a
slice, write it into the socket, continue when the socket has drained below
a watermark, close the stream at end. Peak memory per transfer becomes the
watermark, not the file.

The drain signal is the open design question, with two candidates:

1. The write-queue the registry already drains every pump: a socket whose
   flush could not complete re-queues itself; a handler hook on that path
   knows exactly when to feed the next slice. Right mechanism, but today it
   fires only on `Blocked` — a fully-drained buffer that never blocked
   produces no signal, so the handler would also feed slices from its own
   tick until blocked. Workable: feed until `flushFull`, resume on the
   writable callback.
2. A per-tick pump on the server sweep. Simpler, but couples slice cadence
   to tick rate and wastes sweeps on idle transfers.

Option 1 is the proposal. It uses machinery that exists, and its cost lands
only on connections actually mid-transfer.

Range requests stream the same way with an offset and a remaining count.
`HEAD` is untouched. Compressed responses keep buffering — `compress()` is
whole-buffer, and compressing a file that large is a choice the caller makes
with `Content-Encoding`, not a default — so streaming applies to identity
responses, which is where the memory problem lives anyway.

## Drain interplay

`drain()` improves for free: a keep-alive connection that is idle is between
requests and can be closed immediately, so drain waits only for connections
with a request actually in flight. That requires the server to distinguish
idle from in-flight, which the lifecycle state gives it, and it makes
`activeConnections` honest in the same breath.

## What this refuses to do

- **HTTP/2.** Different framing, different problem. The `HTTPBackendRegistry`
  seam exists for that.
- **Concurrent responses to pipelined requests.** Preserved and answered in
  order, never interleaved.
- **Chunked responses.** Until something produces an unknown-length body,
  absent `Content-Length` means close. Chunked earns its complexity when
  streaming middleware responses exist, not before.
- **Trailers, `Upgrade`, `Expect` beyond the existing 100-continue path.**

## Test plan

- Two requests over one socket, asserting a single connect and both bodies.
- A pipelined pair written in one flush: both answered, in order.
- Idle past `keepAliveTimeout` closes; mid-request idle past
  `requestTimeout` still 408s. `keepAlive = false` closes after one.
- A file several times the watermark served with peak
  `Socket.pendingOutputBytes` bounded by the watermark, not the file size —
  the assertion that proves streaming is streaming.
- Range and HEAD unchanged against the streaming path.
- Drain with one idle and one in-flight connection: idle closes at once,
  in-flight completes.
- Native suite for all of it; jvm for everything the interpreter guard
  allows.
