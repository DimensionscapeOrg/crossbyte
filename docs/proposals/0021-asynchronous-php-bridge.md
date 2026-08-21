# Proposal 0021 — An asynchronous PHP bridge

**Status:** Draft

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

`execute()` stops returning a response and hands it to a callback:

```haxe
public function execute(req:PHPRequest, onResponse:PHPResponse->Void, onError:String->Void):Void
```

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

1. **The deadline, on the blocking bridge.** A socket timeout and a `504` are
   worth having on their own, and they land without touching the signature.
   This is the availability fix and it should not wait for the rest.
2. **`execute()` takes callbacks; the native bridge drives from the tick.**
   No new capability, same behaviour, asynchronously. The suite is the check:
   every existing PHP test must pass unchanged.
3. **`__servePhp`'s tail becomes the callback.** Handler-side only.
4. **Node.** The transport underneath, and lifting the refusal in
   `HTTPServerConfig.validate()`.
5. **Reuse and streaming**, separately, if measurement justifies them.

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
