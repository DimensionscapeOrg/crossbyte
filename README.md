# CrossByte

<p align="center">
  <img src="crossbyte.png" alt="CrossByte logo" width="160" />
</p>

CrossByte is a cross-platform Haxe framework for networked, event-driven, and systems-oriented applications.

It is built for projects that want a strong runtime foundation without dragging in a giant engine shape: sockets, HTTP, RPC, timers, workers, files, crypto, compression, IPC, and a set of practical data structures all live in one coherent core.

CrossByte aims to stay modular. The core provides portable behavior first, while optional sibling haxelibs can add native-backed integrations when they are worth the extra dependency.

## What CrossByte Is Good At

- evented applications and services
- TCP, WebSocket, and reliable datagram networking
- HTTP clients and lightweight HTTP server flows
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
- RPC sessions, commands, handlers, and typed responses
- IPC primitives such as `LocalConnection` and `SharedObject`
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

## Extensions

CrossByte's extension story is intentional: features that benefit from native backends or external platform libraries can live in sibling haxelibs instead of bloating the core.

Current extension repos:

- `crossbyte-libuv`
  - native libuv-backed poll backend
- `crossbyte-brotli`
  - native Brotli oracle / backend
- `crossbyte-lz4`
  - native LZ4 oracle / backend

The core remains usable without these extensions. When installed, they can be enabled selectively for native-backed behavior where it matters.

## Testing

CrossByte uses [utest](https://lib.haxe.org/p/utest) for its test suite.

Run the fast interpreted suite with:

```sh
haxe test.hxml
```

Run the native smoke build with:

```sh
haxe ci/native-tests.hxml
```

Then run the produced executable:

```sh
./export/ci-native-tests/NativeSmokeMain
```

## CI

The repository CI covers:

- fast interpreter tests
- hxcpp API audit builds
- native smoke tests
- sibling extension jobs for the optional native modules

The CI is currently configured to use the `dimensionscape/hxcpp` `socket-fixes` branch so CrossByte can validate against the poll/index fixes it depends on.

## Design Direction

CrossByte is trying to be a serious runtime layer, not a grab-bag of unrelated helpers.

That means:

- portable core behavior first
- native acceleration as opt-in extensions
- efficient hot paths for network and byte-oriented code
- typed APIs where they add real leverage
- enough low-level access to stay useful in unusual projects

If you are building something network-heavy, service-oriented, or systems-adjacent in Haxe, CrossByte is meant to give you a lot of the unglamorous but important foundation work in one place.
