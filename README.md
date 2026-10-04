# CrossByte

<p align="center">
  <img src="crossbyte.png" alt="CrossByte logo" width="160" />
</p>

CrossByte is a cross-platform Haxe framework for networked, event-driven, and systems-oriented applications.

It is built for projects that want a strong runtime foundation without dragging in a giant engine shape: sockets, HTTP, RPC, timers, workers, files, crypto, compression, IPC, and a set of practical data structures all live in one coherent core.

CrossByte aims to stay modular. The core provides portable behavior first, while optional sibling haxelibs can add native-backed integrations when they are worth the extra dependency.

## Install

```sh
haxelib install crossbyte
```

Or track the repository:

```sh
haxelib git crossbyte https://github.com/dimensionscapeorg/crossbyte.git
```

### Native targets

Native (hxcpp) builds need the `production` branch of the [`dimensionscape/hxcpp`](https://github.com/dimensionscape/hxcpp) fork:

```sh
haxelib git hxcpp https://github.com/dimensionscape/hxcpp.git production
```

It carries the socket, poll and TLS corrections CrossByte depends on, ALPN for HTTP/2, TLS session resumption and the bundled MySQL client, and it exposes hxcpp's mbedTLS to libraries, which CrossByte's RSA and ECDSA build against. hxcpp 4.3.2, the release on haxelib, has none of these and cannot build CrossByte's crypto. CI builds against the same branch.

The JVM, Node, HashLink, Neko and the interpreter need nothing else to install; Node needs `hxnodejs`. What a target cannot do it says at the member: the interpreter, for one, cannot start a child process (`NativeProcess.isSupported` is false there).

Install the published CrossByte task runner with:

```sh
haxelib install aedifex
```

## What CrossByte Is Good At

- evented applications and services
- TCP, WebSocket, and reliable datagram networking
- peer-to-peer connections through NAT, including WebRTC data channels to and from browsers
- HTTP clients and lightweight HTTP server flows, HTTP/1.1 and HTTP/2
- request/response RPC over live connections
- file, byte, and stream-heavy workflows
- headless runtimes, tools, and backend infrastructure
- cross-target foundations that still leave room for native extensions

## Core Surface

CrossByte currently includes:

- async runtime and timer scheduling
- event system and typed event classes
- HTTP and middleware
- URL loading and request utilities
- TCP, WebSocket, and RUDP transport layers
- NAT traversal and WebRTC:
  - `PeerConnection` and `DataChannel`, the full stack, ICE to SCTP over DTLS, interoperable with a browser's `RTCPeerConnection` in either signalling direction (CI proves both against headless Chrome)
  - `StunClient` and per-connection reflexive gathering, so a peer behind NAT can learn the address the world sees, and RFC 5780's tests (`classifyMapping`, `classifyFiltering`) for what kind of NAT is in the way
  - `TurnClient` and relayed candidates for the peers no direct path reaches, verified in CI against an independent TURN server
  - hole punching on the reliable datagram sockets, for the same problem without the browser, with a TURN relay to fall back on where punching fails (`ReliableDatagramServerSocket.allocateRelay`)
- RPC sessions, commands, handlers, and typed responses, see the
  [RPC guide](docs/rpc.md)
- IPC primitives such as `LocalConnection`, `SharedChannel`, and `SharedObject`, natively (cpp) on Windows, Linux and macOS; on every other target they say so with `isSupported` and throw when used
- file APIs, `ByteArray`, `ByteArrayInput`, and `ByteArrayOutput`
- compression:
  - DEFLATE
  - GZIP
  - LZ4
  - Brotli
- crypto:
  - natively (cpp) only, from libsodium and BLAKE3 compiled in: `Aead` (XChaCha20-Poly1305), `KeyExchange` and `X25519`, `GenericHash` (BLAKE2b), `HKDF`, `Ed25519` and `Blake3`; and from mbedTLS, RSA and ECDSA signatures (`PublicKeySignature`, `SignatureKey`). Elsewhere `isAvailable()` is false and they throw
  - `Argon2id` natively and on Node 24.7 or later; `BCrypt` everywhere, in Haxe
  - secure random bytes natively, on the jvm, on Node, in a browser and on PHP; not on the interpreter, neko or HashLink
- workers, task pools, and `NativeProcess`, which starts a child process and reads its output natively, on the jvm, HashLink, Neko and Node; not on the interpreter, whose process calls hold every thread while they wait, nor in a browser
- data structures and utility packages
- database surfaces for:
  - SQLite, natively, its statements prepared once and their parameters bound
  - every SQL driver's statements take `parameters` as `SQLValue`s, and read a result row by row and column by column with `executeEach` and `SQLRow`
  - MySQL and MariaDB: natively through hxcpp's bundled client, which logs in with `caching_sha2_password` or `mysql_native_password`, uses TLS when the server offers it (`MySQLConfig.sslMode`), bounds its waits and can `cancel()` a statement; on the jvm through Connector/J on the class path, without the TLS or limit settings
  - PostgreSQL: natively through libpq, loaded at run time, with bound parameters, statement and connect timeouts and `cancel()`; on php through PDO; no other target
  - MongoDB, through its wire protocol (OP_MSG, SCRAM, TLS, cursors, transactions) on hxcpp, the jvm, the interpreter, hl and neko; not on JavaScript, which cannot block

## Timers

Every CrossByte runtime schedules its timers with a min-heap, and for almost
everything that is the end of the story. It orders timers exactly, a
one-millisecond delay costs what a six-hour delay costs, and thirty thousand
recurring timers still leave it using well under a millisecond per frame. You
should not have to think about it.

The exception is a runtime holding thousands of *short* timers that it re-arms
constantly, a deadline per connection, a cooldown per entity. That is where
the heap's `O(log n)` starts to show, and CrossByte ships a timing wheel for
it:

```haxe
class MyServer extends ServerApplication {
	public function new() {
		super(WHEEL);
	}
}
```

The choice belongs to the runtime rather than the build, because a process
usually has more than one and they rarely want the same answer. A simulation
thread carrying a timer per entity and a network thread carrying a handful can
each have what suits them:

```haxe
var sim = CrossByte.make(DEFAULT, WHEEL);
var net = CrossByte.make(POLL, HEAP);
```

Measured with one recurring timer per entity, CPU spent per simulated second
at sixty ticks:

| timers | heap | wheel |
| --- | --- | --- |
| 1,000 | 1ms | under 1ms |
| 10,000 | 10ms | 2ms |
| 30,000 | 44ms | 7ms |

Arming and cancelling is roughly twice as fast.

Before you switch, the other side of it. The wheel covers a fixed span ahead of
now, and anything scheduled past that span waits in a list it rescans
periodically, so if your timers are mostly long, you are paying for work the
heap never does, and you should stay on the heap. Two smaller differences:
timers due in the same tick fire in bucket order rather than by exact time, and
a timer can be late by up to a tick. It will never be early; that one is
guaranteed.

The short version: reach for the wheel when you have actually seen the
scheduler in a profile and your timers are numerous and short. Otherwise the
default is already the right answer.

## Using more than one core

A runtime runs on one thread. Everything a server does, its sockets, its
handlers, its timers, runs on its runtime's thread, so a server on one
runtime uses one core however many the machine has. `CrossByte.make` makes a
runtime per thread, and a server can spread its connections over several:

```haxe
var server = new ServerSocket();
// Four runtimes, each a thread of its own polling its sockets.
server.runtimes = [for (_ in 0...4) CrossByte.make(POLL)];
server.addEventListener(ServerSocketConnectEvent.CONNECT, function(event) {
	// Runs on the runtime this connection was handed to, and so does
	// everything the connection does from here on.
	var socket = event.socket;
	socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
		socket.writeUTFBytes(socket.readUTFBytes(socket.bytesAvailable));
		socket.flush();
	});
});
server.bind(9000);
server.listen();
```

The listener stays on the runtime that called `listen()` and accepts. Each
connection it accepts is handed, before its TLS handshake, to one of
`runtimes`: each in turn, passing over one that has exited, and is that
runtime's for its whole life: its socket is polled there, its events and
deadlines run there, and so does the `connect` listener that receives it.
`runtimeCount = 4` makes the runtimes instead. `ServerWebSocket` takes the
same, and so does `HTTPServer`, through its configuration:

```haxe
var config = new HTTPServerConfig("0.0.0.0", 8080);
config.runtimeCount = 4;
config.middleware.push(router.middleware());
var server = new HTTPServer(config);
```

Each request is served on its connection's runtime, HTTP/1.1 and HTTP/2
alike. `maxConnections`, the rate limiter and the metrics count every
runtime's connections together, and `drain()`, `close()` and
`stopAccepting()` cover all of them.

What it buys, measured natively on Windows with small GETs from 64
kept-alive connections, the server held to eight logical CPUs and the
clients to eight others (`tests/scaling`):

| runtimes | HTTP/1.1 requests/s | HTTP/2 requests/s |
| --- | --- | --- |
| one (not spread) | 78,000 | 75,000 |
| 2 | 178,000 | 154,000 |
| 4 | 312,000 | 312,000 |

A server on one runtime pays nothing for the feature: the same server built
before it measured the same.

`selectRuntime` chooses the runtime instead, on the listener's runtime, from
the peer's address. A game server that runs each match on a runtime of its
own sends a player to the runtime that owns their match, so the match's
state is only ever touched from one thread:

```haxe
// What the matchmaker decided: the runtime each joining address's match runs on.
var joining:Map<String, CrossByte> = new Map();

var server = new ServerWebSocket();
server.runtimes = matchRuntimes;
server.selectRuntime = (address, port) -> joining.get(address);
server.addEventListener(ServerSocketConnectEvent.CONNECT, function(event) {
	// On the match's runtime: the match can be reached without a lock.
	matchOn(CrossByte.current()).join(cast event.socket);
});
```

An answer of `null`, or of a runtime that has exited, takes the next in
turn.

**What runs where, and what it must be.** Handlers that keep to their own
connection need nothing. What several runtimes' handlers share, a table of
players, a cache, a counter, a database pool, is touched from several
threads at once, and must be thread-safe or kept per runtime: reach the
runtime's own with `CrossByte.current()`, or hand work to one with
`runtime.post(...)`, the one thread-safe way into a runtime. In particular:

- `connect` listeners, an `HTTPServer`'s middleware, routes and hooks
  (`onError`, `onExpectContinue`, `rateLimitKey`), a `ServerWebSocket`'s
  `upgrade` and an SNI predicate run on each connection's runtime, several
  at once;
- `admit` and `selectRuntime` run on the listener's runtime alone;
- a `Router` is read-only once its routes are added, and safe to share;
- the server's own shared pieces are made safe for you: the limits and
  counts, `HTTPServerConfig.rateLimiter` (given a lock as the server starts),
  the metrics registry and the compression cache.

Add listeners and routes before `listen()`; `close()` on a connection from
any thread is handed to its runtime, as everywhere.

**On Linux**, `reusePort` gives each runtime a listening socket of its own on
the port (`SO_REUSEPORT`) and lets the kernel share connections out, so no
one runtime accepts for the others, worth it when connections arrive faster
than one thread accepts them. The kernel then decides where a connection
goes, so `selectRuntime` is not asked, and each runtime asks `admit` for
itself. macOS and the BSDs take the option without sharing anything out, and
Windows has nothing like it; setting it there throws.

**Where it works.** Natively and on the jvm each runtime is a thread and they
run at once. neko's threads run at once too but contend for its allocator:
the server above, on neko, answered 1.4 times as many requests on two
runtimes as on one, and no more on four. hl runs them on threads as well. On
the interpreter the runtimes take turns, two busy threads take twice as
long as one, so a spread server is served correctly and no faster. On Node
every runtime shares one thread, so a spread server is refused; run several
processes there (Node's `cluster`).

**When several processes are better.** Every runtime in a process shares one
garbage collector, and a collection stops all of them at once: at high
allocation rates the pauses, not the cores, bound the throughput, and a
latency-sensitive server sees every runtime's pause. A process also fails as
a whole, one handler's crash, one leak, takes every runtime down, and
shares one memory budget. Several processes behind a load balancer, or, on
Linux, a server in each with `reusePort` set, all on one port, give each
its own collector and its own fate, at the price of sharing nothing without
a network hop. Spread a process over
runtimes when connections need to reach shared state cheaply (a game world, a
cache); use processes when they do not.

## HTTP client limits and deadlines

What a server you call can cost you is bounded per request, on the
`URLRequest`, so one caller's settings never reach another's requests:

| `URLRequest` | Default | Bounds |
| --- | --- | --- |
| `idleTimeout` | 30 s | time with nothing arriving, and, off JavaScript, the wait for a load thread past `URLLoader.maxConcurrentLoads` |
| `headTimeout` | 300 s | the response's head, from the request having gone; bytes trickling in do not move it |
| `totalTimeout` | none | the whole load, from `load()` to `COMPLETE` |
| `maxBodySize` | 64 MB | the body on the wire; a larger `Content-Length` is refused before it is read |
| `maxDecompressedSize` | 64 MB | what the body decodes to |
| `maxResponseHeaderSize` | 64 KB | the status line and header fields, 1xx responses included |
| `maxRedirects` | 10 | redirects followed before the load fails |

`0` or less lifts any of them. An idle timeout alone does not bound a request:
a server sending a byte at a time resets it with every byte, so give a
request to a server you do not trust a `totalTimeout`:

```haxe
var request = new URLRequest("https://api.example.com/report");
request.totalTimeout = 60000;
request.maxBodySize = 4 * 1024 * 1024;
var loader = new URLLoader();
loader.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> trace(e.text));
loader.load(request);
```

A custom `HTTPBackend` reads the same limits from its `HTTPRequestContext`;
the loader cancels a request past its `totalTimeout` through the context's
`cancelToken`.

**Names.** A socket's connect by name, and every client request, looks the
name up on one of four threads the process keeps for it, a system lookup
cannot be stopped, so that is the most a wedged resolver can hold, and its
caller waits 30 s for the answer at most (less within a request's idle
timeout, and a cancel ends the wait at once). An answer is kept for 30 s, a
failure for 5, and callers asking for a name already being looked up share
the lookup.

**PHP.** `HTTPServerConfig.phpMaxResponseSize` (8 MiB) bounds a script's
response, whose CGI header block is held to 64 KiB and 100 lines besides,
and `phpMaxExchanges` (64) the requests a runtime has with its PHP backend
at once; more wait their turn within `phpTimeout`, and past 1,024 waiting
a request is refused.

## Extensions

CrossByte's extension story is intentional: features that benefit from native backends or external platform libraries can live in sibling haxelibs instead of bloating the core.

Current extension repos:

- `crossbyte-libuv`
  - native libuv-backed poll backend
- `crossbyte-brotli`
  - native Brotli backend
- `crossbyte-lz4`
  - native LZ4 backend

The core remains usable without these extensions. When installed, they can be enabled selectively for native-backed behavior where it matters.

## Build defines

All optional, all off unless you pass them.

| Define | Effect |
| --- | --- |
| `crossbyte_brotli_native` | Route Brotli through the native backend from the `crossbyte-brotli` haxelib instead of the bundled Haxe implementation. |
| `crossbyte_lz4_native` | Route LZ4 through the native backend from the `crossbyte-lz4` haxelib instead of the bundled Haxe implementation. |
| `crossbyte_libuv_native` | Build the libuv poll backend from the `crossbyte-libuv` haxelib (cpp only). Needs libuv's headers and library, and `LibuvPoll.install()` called before the first runtime is created; without the define `install()` returns false and the built-in backend is used. See that repository's README. |
| `crossbyte_no_http2` | Do not auto-register the bundled HTTP/2 backend. A backend registered explicitly through `HTTPBackendRegistry` still wins either way; this only stops the bundled one from being picked up on its own. |
| `http_debug` | Log each response line the HTTP client reads, through `Logger`, so it honours the configured level and sink. |
| `crossbyte_debug` | Keep `crossbyte.io.File` out of `@:noDebug`, so its frames appear in stack traces. |

For example:

```
haxe -lib crossbyte -lib crossbyte-lz4 -D crossbyte_lz4_native -main Main --cpp bin
```

One of hxcpp's own matters to a server that holds a lot in memory. hxcpp's
collector numbers its 32 KB blocks in two bytes, so a native process can hold
about 2 GB of objects and no more: past that, an allocation stops the process
with an access violation ("Memory exhausted" in a debug log). Build with
`-D HXCPP_GC_BIG_BLOCKS` for 64 KB blocks and twice that. The collector also
stops every thread while it marks, for a time that grows with what is live,
about 0.2 ms a megabyte of small objects, measured by the load harness's game
server at sixty ticks a second: pauses of 50-70 ms every few seconds with
300 MB live, about 200 ms every twenty seconds with 1.1 GB, up to 0.7 s with
2.4 GB. A runtime whose ticks must stay inside a frame wants its live heap
well under 100 MB, or the world held where the collector does not scan it.

Where a collection fits between two ticks, `CrossByte.collectWhenIdle` moves
it there: the runtime learns how often the collector runs and makes the
collection that is due in the gap before a tick instead. At thirty ticks a
second with 180 MB of small objects live, two collections in three left the
ticks for the gaps between them; a collection longer than two thirds of the
gap stays where it falls.

## HashLink and Neko

Both build and run the test suite, in CI on Windows and Linux. What they need,
and what they do not have:

**HashLink 1.13 or later, and say so.** Haxe 4.3 assumes HashLink 1.12 unless
told otherwise, and `crossbyte.utils.Random` uses `haxe.atomic`, which will not
compile for anything older, the build stops inside the standard library with
"Atomic operations require HL 1.13+". Pass the version you run on:

```
haxe -lib crossbyte -D hl-ver=1.13.0 -main Main --hl main.hl
```

**The `.hdll` files, next to `hl`.** HashLink resolves every native a program
was compiled with when it loads, not when one is called, so a missing library
stops the program before `main`, and on Windows it says so in a dialog box,
which on a service or a build machine nobody will ever click. Which ones a
program needs depends on what it compiles in:

| library | needed by |
| --- | --- |
| `ssl.hdll` | anything that uses the network, TLS or not: every socket type reaches `sys.ssl` |
| `fmt.hdll` | `haxe.crypto.Md5` and `Sha1` (the WebSocket handshake, TURN credentials) and `haxe.zip` |
| `sqlite.hdll` | `SQLiteConnection` |
| `mysql.hdll` | `MySQLConnection` |

The HashLink release for Windows ships all four. A Linux build from source
makes them with `make libhl hl fmt ssl sqlite mysql`, given mbedTLS, zlib,
libpng, libturbojpeg, libvorbis and SQLite's headers. A library a program
never calls can be skipped with `HL_DISABLED_LIBS=sqlite,mysql` (HashLink
1.14): its functions then throw when called rather than stopping the load.

**What is not there.** Neither target has a secure random source, so
`SecureRandom.isSupported` is false and everything that needs one refuses,
saying so: `BCrypt.hash`, PKCE, WebSocket clients, STUN, TURN, ICE and WebRTC.
Both are IPv4 only. `LocalConnection`, `SharedChannel` and `SharedObject` and
the libsodium, BLAKE3 and mbedTLS crypto are native features only; ALPN (so
HTTP/2 over TLS) is native or jvm; and a datagram socket's buffers cannot be sized (`DatagramSocket.bufferSizeSupported`
is false: they read 0 and setting them throws). On Linux, hl polls its sockets
through `select`, which cannot watch a descriptor numbered 1024 or above, and
hl has no poll natives to move to: a server there fails its polling once that
many descriptors are open. neko polls through its own natives and is not held
to it.

Two things about neko's numbers and clock. An `Int` there is 31 bits, and
`Array.sort` is a native merge sort that takes a comparator's answer too large
for one as "less", so a comparator written as a subtraction of large values
sorts wrongly there; answer -1, 0 or 1. And on Windows `haxe.Timer.stamp()` is
the time of day to the millisecond, moving once a system tick, so two readings
a few microseconds apart are usually equal.

## Samples

The repository includes small runnable samples for:

- primordial applications
- TCP chat
- RPC
- LocalConnection, SharedChannel, and SharedObject IPC
- UDP and reliable datagrams
- HTTP serving
- one HTTP server on several cores (`multicore`)
- worker/background tasks

See [samples/README.md](samples/README.md) for the current sample index and build commands.

## Testing

CrossByte uses [utest](https://lib.haxe.org/p/utest) for its test suite.

The repository root is now described by `Aedifex.hx`. That file is the source of truth for the library identity, task list, and generated `haxelib.json` metadata.

To refresh `haxelib.json` from `Aedifex.hx`, run:

```sh
aedifex haxelib sync <project-root>
```

Run the fast interpreted suite with Aedifex:

```sh
aedifex task interp-tests <project-root>
```

The raw compiler entrypoint still exists underneath:

```sh
haxe ci/interp-tests.hxml
```

Build the native smoke executable with Aedifex:

```sh
aedifex task native-tests <project-root>
```

The raw compiler entrypoint still exists underneath:

```sh
haxe ci/native-tests.hxml
```

Then run the produced executable:

```sh
./export/ci-native-tests/NativeSmokeMain
```

To inspect the registered CrossByte tasks, run:

```sh
aedifex tasks -json <project-root>
```

Generate docs through Aedifex with:

```sh
aedifex task docs-api <project-root>
aedifex task docs-site <project-root>
```

In the examples above, `<project-root>` is usually `.` when you are already in
the repository root.

### Benchmarks

A performance suite lives in `tests/bench` and covers the paths that run once
per unit of real work, per datagram, per connectivity check, per event, so
a regression there is a regression multiplied by traffic. Build and run it
natively:

```sh
haxe ci/bench.hxml
./export/bench/BenchMain.exe
```

It reports the best of several samples per case; the numbers compare shapes of
code on one machine in one sitting and are not comparable across machines. CI
runs it so it cannot rot, and ignores the numbers.

### Allocation budgets

`tests/crossbyte/AllocationBudgetTest.hx` measures how many bytes each common
operation allocates, an HTTP/1.1, HTTP/2 and TLS request, a WebSocket and a
TCP echo, a reliable and a plain datagram, an RPC call, an event, a timer, a post
and an idle frame, and fails when one passes its budget: what it measured when the
budget was set, plus about a quarter. It runs in the native and jvm suites,
the two targets with an allocation counter; `AllocationMeter` says how each is
read. A failure names the operation, what it allocated in each of three runs,
its budget and the figure the budget was set from. Natively the runs read the
same to the byte, so a failure that repeats when the class runs alone
(`-D gc_bisect`, `CB_ONLY=AllocationBudget`) is a path allocating more. To
rebaseline after a deliberate change, run the class alone with
`CB_ALLOC_REPORT=1` set, which prints every figure, natively on Windows and on
Linux and on the jvm, and set the measured figures, the budgets and the date
at the top of the class.

### Load and churn

`tests/load` runs CrossByte the way a server and a game server run it, for
minutes, at scale, with the clients in other processes, and reports what the
server costs and whether what it holds comes back down once the clients have
gone. Build it natively for the machine you are on, then run a scenario:

```sh
haxe ci/load.hxml
./export/load/LoadMain game  --clients 1000 --hz 60 --seconds 600
./export/load/LoadMain churn --plan 50:300,200:300,1000:300,0:120
./export/load/LoadMain idle  --clients 10000 --seconds 120
```

- `game`: a reliable-UDP game server ticking at `--hz`, sending every client
  a 100-400 byte snapshot each tick (sequenced, every fourth reliable) and
  taking an input from each every tick. Reports processor time per tick, tick
  time, input-to-acknowledgement latency, lost snapshots and retransmissions,
  and memory per session. What a session sends waits for its congestion
  window, up to `ReliableDatagramSocket.maxOutputBufferSize`: 256 KB by
  default, past which the session is ended with an `ioError` saying why,
  rather than held without end for a client that has stopped taking it. At
  1,000 clients and 60 Hz no session held anything waiting while the server
  kept its tick, and none more than 18 KB when it was starved of processor
  time. A game that sends more at once, a level, one large reliable
  message, raises the limit, or sets it to 0 for none.
- `churn`: HTTP/1.1 keep-alive, HTTP/2 and WebSocket clients, half over TLS,
  connecting, doing a few requests and leaving, at each concurrency of
  `--plan` (`concurrency:seconds,...`; end with a `0:` phase to watch memory
  come back). Its default clients are `tests/load/churn-client.js` and need
  Node 18 or later, whose TLS connections resume their sessions as browsers'
  do; `--client native` uses CrossByte's own clients instead, which do not
  resume and speak HTTP/2 in clear only.
- `idle`: that many WebSocket connections held open and quiet: memory per
  connection, and what holding them costs of a core.

Each prints `LOAD {json}` lines, a window every `--report` seconds, then a
summary, and exits 0 when every client saw what it should have. Useful
options: `--cpus 2-5 --client-cpus 6-15` keeps the server and its clients on
separate processors (a server sharing a core with its own clients measures
far more processor time a tick); `game --world-mb 1024` holds that much live
world data, to see the collector's pauses (see Build defines); `churn --ops
1000:1000 --think 0 --kinds h1 --tls-share 0` measures one runtime's
throughput for one protocol rather than its churn. On Linux, raise the
descriptor limit before a large idle run (`ulimit -n 65536`). To run
on crossbyte-libuv's backend, build with that library as its README says
(`-lib crossbyte-libuv -D crossbyte_libuv_native`, plus `LIBUV_INCLUDE`,
`LIBUV_LIB` and `LIBUV_STATIC` on Windows) and pass `--libuv`.
`ci/load-jvm.hxml` builds the game server for the jvm; give it `--bots` with
the native executable so only the server is the jvm's. Like the soak, CI does
not run any of this: the numbers are for reading, not gating.

## CI

The repository CI covers:

- fast interpreter tests
- generated API documentation
- hxcpp API audit builds
- the native suite on Windows, Linux and macOS
- native sample builds
- the whole suite on HashLink and Neko, on Windows and Linux (`hl-neko.yml`)
- sibling extension jobs for the optional native modules

CI builds against the `production` branch of the `dimensionscape/hxcpp` fork, which is also what a local native build should use: the poll/index fixes CrossByte depends on, and the fork's other corrections since. `socket-fixes` is the narrow branch the upstream pull request lives on; the note in `ci.yml` says why CI does not follow it.

Each CI run now also publishes a `crossbyte-api-docs` artifact containing the generated dox site for that revision.

## Design Direction

CrossByte is trying to be a serious runtime layer, not a grab-bag of unrelated helpers.

That means:

- portable core behavior first
- native acceleration as opt-in extensions
- efficient hot paths for network and byte-oriented code
- typed APIs where they add real leverage
- enough low-level access to stay useful in unusual projects

If you are building something network-heavy, service-oriented, or systems-adjacent in Haxe, CrossByte is meant to give you a lot of the unglamorous but important foundation work in one place.
