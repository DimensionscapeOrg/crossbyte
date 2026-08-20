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

**How much of the HTTP stack is portable.** The server is tier C. The request
and response *parsing* is not obviously platform-bound and would be worth
keeping in tier A, so that a browser client and a Node server share one
understanding of the protocol.

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

Subprocesses were listed as tier C and are now tier C in fact: `NativeProcess`
runs on Node. The threads it uses on a native build turned out not to be part
of the design -- they exist to keep a blocking pipe read off the runtime's
thread, and nothing about Node's streams blocks, so the same events fall out of
`child_process` with no worker at all.

Sockets are the honest gap. The browser has one, over the page WebSocket, and
it works. Node has none: the browser path needs the page API and the native
path needs `select()`. `crossbyte.net.Socket` throws there, naming what it
would take -- an implementation over `js.node.net`, which is a port and not a
gate. That is the next piece of work, and it is what would give Node parity.
