# CrossByte

<p align="center">
  <img src="crossbyte.png" alt="CrossByte logo" width="160" />
</p>

CrossByte is a cross-platform Haxe framework for networked, event-driven, and systems-oriented applications.

It is built for projects that want a strong runtime foundation without dragging in a giant engine shape: sockets, HTTP, RPC, timers, workers, files, crypto, compression, IPC, and a set of practical data structures all live in one coherent core.

CrossByte aims to stay modular. The core provides portable behavior first, while optional sibling haxelibs can add native-backed integrations when they are worth the extra dependency.

## Install

Release candidate target:

```sh
haxelib install crossbyte
```

If you are tracking the repo directly during RC validation:

```sh
haxelib git crossbyte https://github.com/dimensionscapeorg/crossbyte.git
```

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
- IPC primitives such as `LocalConnection`, `SharedChannel`, and `SharedObject`
- file APIs, `ByteArray`, `ByteArrayInput`, and `ByteArrayOutput`
- compression:
  - DEFLATE
  - GZIP
  - LZ4
  - Brotli
- crypto:
  - BLAKE3
  - Ed25519
  - secure random bytes
  - password hashing helpers
- workers, task pools, and native process helpers
- data structures and utility packages
- database surfaces for:
  - SQLite
  - MySQL
  - PostgreSQL
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
Both are IPv4 only. `LocalConnection`, `SharedChannel` and `SharedObject`, the
native crypto, ALPN (so HTTP/2 over TLS) and socket buffer sizes are native or
jvm features. On neko an `Int` is 31 bits, so a value past 0x3FFFFFFF is not
one there.

## Samples

The repository includes small runnable samples for:

- primordial applications
- TCP chat
- RPC
- LocalConnection, SharedChannel, and SharedObject IPC
- UDP and reliable datagrams
- HTTP serving
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

## CI

The repository CI covers:

- fast interpreter tests
- generated API documentation
- hxcpp API audit builds
- native smoke tests
- native sample builds
- the whole suite on HashLink and Neko, on Windows and Linux (`hl-neko.yml`)
- sibling extension jobs for the optional native modules

The CI is currently configured to use the `dimensionscape/hxcpp` `socket-fixes` branch so CrossByte can validate against the poll/index fixes it depends on.

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
