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
  - `PeerConnection` and `DataChannel` -- the full stack, ICE to SCTP over DTLS, interoperable with a browser's `RTCPeerConnection` in either signalling direction (CI proves both against headless Chrome)
  - `StunClient` and per-connection reflexive gathering, so a peer behind NAT can learn the address the world sees
  - `TurnClient` and relayed candidates for the peers no direct path reaches, verified in CI against an independent TURN server
  - hole punching on the reliable datagram sockets, for the same problem without the browser
- RPC sessions, commands, handlers, and typed responses
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
  - MongoDB

## Timers

Every CrossByte runtime schedules its timers with a min-heap, and for almost
everything that is the end of the story. It orders timers exactly, a
one-millisecond delay costs what a six-hour delay costs, and thirty thousand
recurring timers still leave it using well under a millisecond per frame. You
should not have to think about it.

The exception is a runtime holding thousands of *short* timers that it re-arms
constantly — a deadline per connection, a cooldown per entity. That is where
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
periodically — so if your timers are mostly long, you are paying for work the
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

## CI

The repository CI covers:

- fast interpreter tests
- generated API documentation
- hxcpp API audit builds
- native smoke tests
- native sample builds
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
