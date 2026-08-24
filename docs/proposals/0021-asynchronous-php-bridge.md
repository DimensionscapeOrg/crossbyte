# Proposal 0021 — An asynchronous PHP bridge

**Status:** Implemented. Step 5 measured: reuse is not justified, streaming remains open.

**Motivation:** `PHPBridge.execute()` returns a response. Everything below
follows from that one decision, and none of it is a PHP problem.

---

## What the bridge does today

Measured from `src/crossbyte/_internal/php/PHPBridge.hx`, not assumed.

`execute(req:PHPRequest):PHPResponse` does the whole exchange between the call
and the return:

1. opens a **new blocking socket** to php-fpm or php-cgi, one per request
2. writes the FastCGI `BEGIN_REQUEST`, `PARAMS` and `STDIN` records
3. **blocks** in a read loop until `END_REQUEST`
4. closes the socket
5. parses the CGI headers and body into a `PHPResponse`

The socket is never made non-blocking, never registered with the socket
registry, and never given a timeout — `connect()` is preceded by
`setFastSend(true)` and nothing else. Between step 1 and step 4 the runtime
thread is parked.

## Three problems, one cause

**It stalls the runtime.** A CrossByte runtime serves every one of its
connections from a single tick. `execute()` is called from inside that tick, so
for as long as PHP is thinking, nothing else on that runtime runs: no other
request is read, no response is written, no timer advances, no socket is
polled. `maxConnections` defaults to 256, so one slow script can hold up 255
other clients that have nothing to do with it.

**It has no bound.** There is no timeout on the FastCGI socket, and
`requestTimeout` does not cover this window — the handler sets
`__receiveDeadline = 0` the moment a request is fully received, on the
principle that "whatever time the response takes is the server's own". So a
php-fpm that accepts a connection and then never replies parks the runtime
permanently. Not slowly, not until a deadline: permanently. That is a
denial-of-service against a server from its own backend.

**It cannot exist on Node.** Nothing else stands in the way any more.
`NativeProcess` launches php-cgi there, and `crossbyte.net.Socket` reaches a
FastCGI listener. What is missing is a synchronous socket read, and Node has
none — hxnodejs ships a blocking `sys.net.Socket`, but it has no output side at
all and its wait is `deasync`, a native npm addon. So `phpEnabled` refuses at
`validate()` on Node today.

The first two are bugs on the targets PHP already runs on. The third is why
this was noticed. Fixing the signature fixes all three.

## What is already the right shape

This is not a new pattern for the codebase to adopt.

| | |
|---|---|
| middleware | `(HTTPRequestHandler, ?Dynamic->Void) -> Void` — already a continuation |
| responses | already stream, in chunks, across ticks (proposal 0016) |
| sockets | already non-blocking and driven from the registry |
| the handler | already answers one request across many ticks |

The request handler is asynchronous from the socket up. `execute()` is the one
place in the HTTP path that stops and waits, and it is the only place that
needs a blocking read to exist at all.

## The change

`execute()` stops returning a response and hands back a `Future` for one:

```haxe
public function execute(req:PHPRequest):Future<PHPResponse>
```

This proposal was drafted with a callback pair -- `onResponse` and `onError` as
arguments -- and that is not what was built. `crossbyte.Future<T>` exists now,
promoted out of `RPCResponse` where the same shape had already been written
once. Taking callbacks here would have given the framework two ways of saying
"later", differing only in which part of the codebase you were standing in. The
handler consumes it as `.then(onResponse, onError)`, so the call site reads
almost exactly as drafted; what changed is that the value has a name.

Underneath, the bridge keeps a table of in-flight exchanges. Each holds its
socket, its accumulated `STDOUT`, and a deadline. On the native targets the
socket is non-blocking and registered, and the tick drains whatever has
arrived and completes an exchange when `END_REQUEST` lands. On Node the socket
delivers through events and there is no tick work at all — the same split every
other transport in the framework now has.

The FastCGI framing does not change. It is byte work over a stream, and byte
work over a stream is not what is wrong here.

### What the handler has to do

Very little, which is the point. `__servePhp` is the single consumption point:
one call to `execute()`, and everything after it builds the response and
dispatches. That tail becomes the callback. The four call sites — the three in
the routing decision and one in the POST path — are all already tail calls that
hand the request over and return.

Two things do need care:

**The one-response guard.** `__responded` already exists and already guards
against two responses on one request. A callback arriving after the connection
has been closed under it — a client that gave up, a `drain()` in progress — must
find that guard rather than write into a socket that has moved on to the next
request. This is the same hazard streaming responses already have and already
handle; it needs testing, not inventing.

**Keep-alive ordering.** A pipelined second request must not be answered before
the PHP response to the first. The handler serialises on `__responded` today
because the response was always produced before the next request could be
looked at; with an asynchronous response that ordering has to be kept
deliberately.

### The timeout that does not exist yet

Every in-flight exchange gets a deadline, swept from the tick like the
request-receive deadline. A backend that stops answering fails one request with
`504 Gateway Timeout` instead of parking the server. This is not a side effect
of going asynchronous — it is only *possible* once the read stops blocking, and
it is the half of this proposal that matters most for a server already in
production.

## What it costs

The blocking implementation is simpler to read, and this trades that for
correctness under load. A pending-exchange table, a deadline sweep and a
callback are more moving parts than a straight line.

It also changes a public-ish signature. `PHPBridge` is `_internal`, so nothing
outside the framework is entitled to call it, and `HTTPRequestHandler` is the
only caller — but a fork with its own bridge would notice.

And it is a change on every target, not a Node accommodation. cpp, hl, neko,
jvm and eval all get the new path. That is the reason this is a proposal rather
than a commit.

## Open questions

**Connection reuse.** Today every request opens and closes its own connection
to php-fpm. FastCGI supports multiplexing several exchanges over one, and
php-fpm supports keeping the connection. Reuse would cut a connect per request;
it also makes the pending table a genuine multiplexer rather than a list.
Worth measuring before choosing, and easy to leave for later — one connection
per exchange is exactly what happens now.

**Streaming the response.** `STDOUT` arrives in records and is accumulated
whole before anything is sent. The handler can already stream, so a large PHP
response could begin reaching the client before PHP has finished producing it.
That is a real improvement and a separate one; doing both at once would make it
impossible to say which change caused a regression.

**`Launch` mode and process lifetime.** `stop()` kills a php-cgi this bridge
started. With exchanges in flight, stopping should presumably fail them
explicitly rather than let their sockets error, so the caller gets `503` rather
than `502`. Small, but it needs deciding rather than falling out.

**stderr.** The read loop reads `FCGI_STDERR` records and discards them; the
logging is commented out. A rewrite should either log them or say why not, and
"it was commented out" is not a reason.

## Staging

1. ~~**The deadline, on the blocking bridge.**~~ Done. `phpTimeout` defaults to
   30 seconds, the FastCGI socket carries it, and an exchange that runs past it
   answers `504 Gateway Timeout` instead of never answering. The clock decides
   what a failed read meant, because the socket cannot: a read expiring on
   `SO_RCVTIMEO` surfaces as `Eof`, which is exactly what a peer hanging up
   looks like. Covered by a test whose peer is a listening socket that accepts
   and never replies -- no PHP needed to reproduce the outage. Without the
   deadline that test does not fail, it hangs: the suite was killed at 45
   seconds and finishes in 14 with it.
2. ~~**`execute()` returns a `Future`; the native bridge drives from the tick.**~~
   Done, with one correction to the plan above: "every existing PHP test must
   pass unchanged" could not hold, because the deadline test from step 1 was
   written against a call that threw. It now pumps the runtime until the future
   settles -- and gained the two assertions the blocking bridge made impossible:
   that `execute()` returns before the deadline elapses, and that the runtime
   goes on ticking while an exchange is outstanding. Parsing moved to
   `PHPExchange`, which is fed bytes and knows nothing about where they came
   from; that is what lets the native and Node transports share one parser.
3. ~~**`__servePhp`'s tail becomes the callback.**~~ Done. Handler-side only, as
   drafted.
4. ~~**Node.**~~ Done. The refusal in `HTTPServerConfig.validate()` is gone, and
   with it the last thing the `Launch` path needed from `sys.io.Process` --
   Node uses `crossbyte.sys.NativeProcess` instead, which this framework already
   ships. PHP is served on Node end to end, against a FastCGI backend stood up
   in the suite.
5. **Reuse and streaming**, separately, if measurement justifies them. The
   measurement is now taken, and it splits the two apart.

   ~~**Connection reuse.**~~ Not justified, and not merely undone. Opening and
   discarding a loopback TCP connection costs **0.062 ms**, measured over 500
   of them against a backend that answers immediately -- the floor, since a
   real script only makes the connection a smaller share. A PHP page taking
   5 ms spends 1.2% of its time on the connection; at 50 ms, 0.1%. Pooling
   FastCGI connections would buy that back and pay for it in state: a pool has
   a size, an idle policy, and a way to be wrong about whether a socket the
   backend has since closed is still usable. For a backend on loopback or a
   unix socket -- which is where php-fpm lives -- the trade is not worth
   making. It would look different for a backend across a network, where a
   connection is a round trip rather than a memcpy, and that is the condition
   to re-measure under rather than a reason to build it now.

   **Response streaming** stays open, and the measurement above says nothing
   about it. It is not a latency question: a PHP response is accumulated whole
   in `PHPExchange.stdout` before anything is written to the client, so the
   cost is memory proportional to the largest response, and the fix is the one
   `__serveFile` already applies to static files. That is worth doing when
   something needs to serve a large PHP response, and is bounded by the same
   watermark machinery rather than needing anything new.

Step 1 is independently valuable and independently shippable. Steps 2 and 3
have to land together to keep the suite green. Step 4 is the one this proposal
started from and the one that changes the least.

## Testing

The existing PHP tests are the regression net for steps 2 and 3, and they must
pass without being rewritten — a test that has to change to accommodate the new
shape is not evidence that the shape preserved behaviour.

What is not covered today and has to be:

- a backend that accepts and never replies — must be one `504`, not a stalled
  server. Testable with a socket that accepts and does nothing, no PHP needed.
- a second request arriving on the same keep-alive connection while a PHP
  response is outstanding — must be answered after it, not before.
- a client that closes mid-exchange — the callback must find the guard.
- a FastCGI record header split across two reads. The current loop does
  `readBytes(hdr, 0, 8)` and throws "FastCGI short header" if it gets fewer
  than 8, which a blocking socket may legitimately return when a header spans
  two segments. Rare on loopback, real over a network. The asynchronous reader
  has to accumulate rather than assume, and this is worth a test whichever way
  the rest of the proposal goes.

CI runs the HTTP suite on cpp only (`#if cpp` in `TestSuites.addHttp`), so
these belong there, and a run on interp or jvm will not see them.

### What the tests ended up proving

All four are covered, but not equally, and the difference is worth recording.

- **A backend that accepts and never replies.** Covered on both transports, and
  the native case fails loudly rather than hanging: without the deadline the
  suite does not go red, it stops.
- **A record header split across two reads.** Covered on Node, torn at three
  bytes -- inside the eight-byte header, which is the split that breaks a parser
  assuming it can always read a whole one.
- **A second request pipelined while PHP is outstanding.** Covered, and load
  bearing: with the handler's request-boundary guard disabled the static
  response overtakes the PHP one and the test goes red. The first version of
  this test did **not** have that property -- it sent both requests in a single
  write, which the parse loop defers anyway, so it passed with the guard
  disabled and proved nothing. Sending the second request as its own segment,
  after PHP is genuinely in flight, is what puts a fresh parse in front of an
  unanswered request.
- **A client that closes mid-exchange.** Covered as a survival property -- the
  server still answers a later client -- but *not* load bearing: with the
  staleness guard removed it still passes, because a write into a socket that
  has already gone is absorbed rather than fatal. Recorded here rather than
  quietly counted as coverage.

The general point, which cost a rebuild to learn: a test written against an
asynchronous hazard can pass for reasons that have nothing to do with the
hazard. Disabling the guard is the cheapest way to find out which kind you
wrote.
