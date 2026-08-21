# Proposal 0020 — JavaScript and Node targets

**Status:** Implemented (baseline)

**Motivation:** CrossByte runs on cpp, hl, neko, jvm and eval. All of those are
desktop or server. A client written against CrossByte cannot be delivered to a
browser, so a product that wants both a web client and a desktop one writes the
client twice — and the half that matters most for sharing, the application's own
logic, is the half that has no reason to differ.

The goal is not "CrossByte in the browser" in the sense of every subsystem. It is
that the parts which *can* run in a browser do, the parts which need a real
operating system run on Node, and everything else says so plainly rather than
appearing to work.

---

## What the codebase already looks like

Measured rather than assumed:

| | |
|---|---|
| source files | 375 |
| lines | 98,916 |
| files touching `sys.io`, `sys.net`, `sys.thread`, `sys.db`, `sys.FileSystem`, `sys.ssl` or `Sys.` | 60 |
| files with no platform dependency at all | 313 (83%) |
| files using `sys.thread` | 30 |
| files containing a blocking wait | 5 |

Three things fall out of that, and they are the reason this is worth doing now
rather than being a rewrite.

**The host-driven seam already exists.** `HostApplication` is documented as "the
canonical way to embed CrossByte into another application framework that already
owns the main thread and frame/update cycle." A browser is exactly that host:
it owns the loop and hands out frames through `requestAnimationFrame`. The
runtime already supports being pumped instead of owning the loop, `pump(delta)`
already takes its delta from the caller, and `TickEvent` already documents that
a pumped runtime reports the caller's figure. Nothing in the frame model needs
inventing.

**Blocking is confined to subsystems that would not run in a browser anyway.**
JavaScript cannot block a thread, and every blocking wait in the tree is in
`SQLiteConnection`, `LocalConnection`, `NativeProcess`, `Task` or `TaskPool` —
database, inter-process, subprocess and thread-pool code, all of which are
Node-or-nothing regardless. The portable core never blocks; it is already
event- and pump-driven.

**Someone has begun already.** `Socket.hx` carries `#if (js && html5)` branches
and `ByteArray.hx` carries `#if js` ones. The direction is not new to the
codebase.

---

## The three real blockers

### 1. No threads with shared memory

CrossByte's model is one runtime per thread, with `Mutex`, `Tls` and `Deque`
holding it together. A browser has one thread; Web Workers are message-passing
with no shared state, so they are not the same thing and cannot be made to be.

The answer is that on a single-threaded target the guards are guarding nothing.
`Mutex` becomes a no-op, `Tls` becomes a plain field, and `Deque` becomes an
array with a non-blocking read. That is not a weakening — there is no second
thread for them to exclude. `Thread.create` and anything requiring a real
worker (`TaskPool`, `Task`) throws.

Node has worker threads, but they are also message-passing. Node therefore gets
the same single-runtime treatment; what it gains over the browser is the
operating system, not concurrency.

### 2. No blocking

Nothing in the portable core blocks, so this costs nothing there. Where it does
appear it is inside a Node-only subsystem, and those keep their current
implementation under `#if nodejs`.

### 3. No sockets or filesystem in a browser

A browser has no TCP, no UDP, no filesystem and no TLS of its own to offer. It
has WebSocket, `fetch`, and origin-private storage. Node has all of it.

---

## Layering

Four tiers, gated `#if (js && !nodejs)` for browser and `#if nodejs` for Node,
which is how Haxe already separates them.

**A — portable.** Runs everywhere, including the browser, unchanged: events,
collections, math, utilities, `ByteArray`, the URL and MIME parsing, the timer
schedulers (`TimerHeap` and `TimerWheel` are pure), and the runtime itself in
host-driven mode. This is the 83% and it is the whole point: an application's
logic, its event graph, its timers and its data structures move as they are.

**B — browser, through web APIs.** A WebSocket client backed by the browser's
own, an HTTP client backed by `fetch`, and persistence backed by IndexedDB or
OPFS. These are CrossByte's existing interfaces with a different engine
underneath, so calling code does not change shape.

**C — Node only.** TCP and UDP, the filesystem, TLS, the database drivers, the
HTTP *server*, subprocesses and IPC. Real implementations over `hxnodejs`.

**D — unsupported on JavaScript at all.** Shared-memory threading and blocking
IO. There is no browser or Node equivalent, and pretending otherwise is the
failure mode this proposal most wants to avoid.

---

## Stubs must fail loudly

The rule for tier C on the browser and tier D everywhere:

```haxe
throw new IllegalOperationError("Socket is not available in a browser; use WebSocket, or run this on Node.");
```

Never a silent no-op, never a method that returns as though it worked. This
codebase has spent a long week on exactly one class of bug — a layer reporting
something it could not do as done. `maxDelta` discarded a measurement and said
nothing. `Eof` reported a half-closed peer as a dead one. `stat` reported a 3 GB
file as empty and the server served it. A `save()` that quietly does nothing in
a browser is that same bug, and it would be shipped deliberately.

A stub that throws is a five-minute fix for whoever hits it. A stub that lies is
a bug report from a user, six months later, about data that was never written.

---

## Open questions

**`haxe.Timer`.** CrossByte vendors a shim that drives timers off ticks and
throws without a primordial runtime. On JavaScript `haxe.Timer` is native and
backed by `setTimeout`. Keeping the shim means one timing model everywhere and
means a browser app must pump; deferring to the native one means a browser app
that never pumps still gets timers, at the cost of two behaviours. The first is
more consistent and is the recommendation, but it is a real decision.

**Compression.** Three files under `_internal/brotli` and `_internal/zlib` touch
`sys`. `ByteArray.compress` is part of tier A on every other target, so either
those paths get a JavaScript implementation or `compress` moves to tier B/C —
which changes what "portable" means for `ByteArray`.

**How much of the HTTP stack is portable.** Settled. The rules -- supported
versions, conflicting framing, header name and value sanitising -- are in
`_internal.http.HttpSyntax`, which is tier A and compiles for the browser.
`Http` is the client and stays tier C, keeping its four methods as forwards so
there is still one implementation. The server is tier C and now runs on Node.

---

## Staging

Each step is independently useful and independently testable.

1. **Compile tier A for `js`.** No new behaviour: gate what does not belong,
   and prove the 313 neutral files build. This unlocks everything after it.
2. **Single-thread shims.** No-op `Mutex`/`Tls`, non-blocking `Deque`, throwing
   `Thread`. Small, and mostly deletion under a gate.
3. **`HostApplication` on `requestAnimationFrame`.** The browser bootstrap. At
   this point a CrossByte application runs in a browser with timers and events.
4. **Browser transport.** WebSocket and `fetch`.
5. **Node.** `hxnodejs`, then TCP/UDP, filesystem and TLS behind the existing
   interfaces, then the Node-only subsystems.

Steps 1–3 are the ones that decide whether this works. If a browser can run the
runtime, the timers and the event graph, the rest is transport work with a known
shape.

---

## Testing

The suite is the risk. It runs on cpp, interp and jvm today and much of it
assumes a filesystem, real sockets and threads. Tier A needs its own run — the
313 neutral files, compiled to `js` and executed under Node — so that "portable"
is a fact the build checks rather than a claim in this document. Without it,
tier A rots on the first commit that adds a `Sys.` call to a file nobody thought
was platform-bound.

---

## What landed

Both targets compile the whole library, checked by `ci/js-build.hxml` and
`ci/node-build.hxml` in CI. cpp, interp and jvm are unchanged.

The three tiers turned out to be four, because Node is not one of them. It has
a filesystem and a process environment through hxnodejs, but no `sys.thread`,
no `sys.db`, and a `sys.net.Socket` without `select()` -- so it sits between
the browser and a native build rather than beside either. Every gate is
therefore one of three shapes, and which one is a statement about the target:

- `#if (js && !nodejs)` -- the browser only. Node keeps the real thing.
- `#if !js` -- neither JavaScript target. Threads, databases, native bindings.
- `#if !(js && !nodejs)` -- Node keeps it, the browser does not. Files, the
  environment, subprocess-free filesystem work.

Step 3 turned out not to need `HostApplication` at all. The plan was a
browser bootstrap that pumped the runtime from `requestAnimationFrame`, which
would have left a web build with a different entry point from a desktop one --
and the point of the exercise is that they are the same program. What actually
stood in the way was narrower than "CrossByte cannot own the loop in a
browser": the loop is a `while` that never returns, and a JavaScript runtime
whose thread never comes back delivers nothing. Taking one turn at a time
removes that without changing whose loop it is, so `Application` runs unchanged
on both targets and `HostApplication` goes back to being what it says -- for a
host that genuinely owns the frame.

Two things about that are worth writing down, because neither is obvious from
the desktop targets. A browser paces the runtime rather than the other way
round: `requestAnimationFrame` arrives on the display's schedule, so a `tps`
above the refresh rate cannot be delivered and one below it is kept by dropping
the turns that arrive early. And a page that is not visible is given no frames
at all -- the callback is simply held -- so a timer is armed beside the frame
request and whichever arrives first takes the turn. Without it a backgrounded
tab would stop the runtime dead: no timers, no socket handling, a connection
left to time out while the user looked at something else.

Subprocesses were listed as tier C and are now tier C in fact: `NativeProcess`
runs on Node. The threads it uses on a native build turned out not to be part
of the design -- they exist to keep a blocking pipe read off the runtime's
thread, and nothing about Node's streams blocks, so the same events fall out of
`child_process` with no worker at all.

Sockets are no longer the gap they were. The browser has one over the page
WebSocket; Node has one over `js.node.net`, and a `ServerSocket` over
`js.node.net.Server` to accept with. What an accepted connection needs in order
to be indistinguishable from a dialled one lives in `Socket` rather than in
`ServerSocket`, because on Node there is nothing to register for polling and
what is left is only the state of a connected socket -- so both paths set it in
one place.

Two things about the Node server do not line up with a native one, and are
written down rather than smoothed over. Node has no bind that is separate from
listening, so a refused address arrives as a `close` event instead of an
exception out of `bind()`, and a port of `0` reads as `0` until `listen()` has
had a chance to ask what was assigned. And a secure server refuses -- for a
reason worth stating precisely, because the obvious one is wrong. Node
terminates TLS perfectly well: `tls.createServer` takes a key and a certificate
as PEM and presents them. What it has not got is `sys.ssl`, and
`setCertificate()` takes `sys.ssl.Certificate` and `sys.ssl.Key`. So this is a
question of how certificate material is named, not of whether Node can serve
it, and it is the one refusal on this list that is a missing abstraction rather
than a missing capability.

The HTTP server followed straight from it -- a server *is* a `ServerSocket`,
and the request handler wanted a filesystem, which Node has. Two features
refuse, and where they refuse is the point: `validate()`, so a misconfigured
server fails at startup rather than when the first request finds out. TLS needs
`sys.ssl`. PHP needs more explanation, because the obvious reasons are no
longer the real one: launching php-cgi works now that `NativeProcess` runs on
Node, and reaching a FastCGI listener works now that `Socket` does. What is
left is the signature. `PHPBridge.execute()` returns a response, and Node has
no synchronous socket read to produce one with -- hxnodejs ships a blocking
`sys.net.Socket`, but it has no output side at all and its wait needs
`deasync`, a native npm addon.

The way round that is to stop returning a response. A bridge that hands its
result to a callback works everywhere, and CrossByte is already shaped for it:
middleware is `(HTTPRequestHandler, ?Dynamic->Void) -> Void` and responses
already stream. It would also stop a PHP request stalling a native runtime for
its whole duration, which is what a blocking call inside a tick does today. It
is a change to the request handler on every target, so it wants its own
proposal rather than arriving as a side effect of a Node port.

The WebSocket client went the same way, and is the clearest case yet of what
these ports actually cost. The framing -- masking, fragment reassembly, ping and
pong, close codes, a thousand lines of it -- is not platform code and did not
move. What moved was the transport underneath: four call sites, plus the two
tick handlers that exist only to poll a non-blocking socket for a connect that
has completed and a read that would not block. Node reports both as events, so
on Node there is no connect poll, no TLS pump and no drain loop, and the tick
keeps only its sending half. `wss` works there even though a secure
`ServerSocket` does not -- a client has to verify a certificate, a server has to
present one, and Node will do the first without `sys.ssl`.

It also turned up a real gap. `SecureRandom` threw on both JavaScript targets,
so a WebSocket could not be constructed at all: a client masks every frame with
a fresh key, and the key comes from there. Node has `crypto.randomBytes` and a
browser has Web Crypto, both genuine CSPRNGs, and both are now used. The
existing rule -- throw rather than fall back to something that only looks
random -- is kept for the case a browser page has no `crypto` object, which is
what being served over plain http from anywhere but localhost gets you.

UDP went the same way, and brought the reliable layer with it: sequencing,
acknowledgement and retransmission are protocol code over a datagram socket and
needed no port at all. That turned out to be worth running rather than
assuming. It compiled on the first try and then would not start, because
`ReliableDatagramSocket` resolved a host through `sys.net.Host` -- and
hxnodejs resolves one synchronously through `deasync`, a native npm addon.
Requiring it is enough to stop the program loading, whether or not a name is
ever passed.

Which exposed something in the datagram socket underneath it. Node's extern
predates `dgram`'s own `connect()`, so a connected socket is emulated here: the
remote is remembered, `send()` names it every time, and a datagram from
anywhere else is dropped. That filter compares the address a datagram reports
against the one `connect()` was given -- so a name kept as given would match
nothing and the socket would silently receive none of its peer's traffic. Both
now refuse a name and say why, rather than accepting one and going quiet.

The WebSocket server closed the last of it. Nothing is now excluded from Node
for any reason except that Node genuinely lacks the thing -- `sys.thread`,
`sys.db`, `sys.ssl` as a *server*, native bindings -- rather than because the
implementation happened to be written against a socket that polls.

Which is the shape of the whole exercise, stated plainly. Very little of what
looked platform-bound was. The HTTP request handler, the WebSocket framing, the
reliable datagram protocol, the router, the rewrite engine: none of it moved.
What moved, every time, was a handful of calls at the bottom -- connect, read,
write, close -- and the tick handlers that exist only because a non-blocking
socket has to be asked. Node answers those questions with events, so the asking
goes away and the code above it does not notice.

The exceptions divide into two kinds, and it is worth keeping them apart.

Genuine limits: a browser has no filesystem, no socket and no threads, and
`File`, `ServerSocket` and `Thread` say so. Node has no `sys.thread` and no
`sys.db`.

Unfinished work wearing a limit's clothes, which is the more dangerous
category, because a refusal reads as final whether it is or not. Two are on the
list. A secure server on Node refuses because `setCertificate()` takes
`sys.ssl` types, not because Node cannot present a certificate -- it can, and
the fix is a way to name PEM material that does not route through `sys.ssl`.
And PHP waits on a bridge that hands its result to a callback instead of
returning it, which is proposal 0021.

Both were first written down here as though Node lacked the capability. It does
not, in either case, and the difference matters: one of these is a week of
someone's time and the other is a paragraph in a document telling them not to
bother.
