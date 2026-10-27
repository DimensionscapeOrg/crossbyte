# Changelog

All notable changes to CrossByte will be documented in this file.

## 2.0.0 - Unreleased

### Changed

Entries marked "(Upgrading)" can need code changed; the Upgrading section
says how.

#### Platform

- `LocalConnection`, `SharedChannel`, `local://` and `SharedObject` run
  on native-ipc, a library of their native code that CrossByte now
  depends on, which other frameworks share: a Lime application's
  `LocalSocket` and a CrossByte program can be either end of one
  connection. Its `PROTOCOL.md` says what goes over one, and what each
  OS object is called. (Upgrading)
- A local connection begins with a hello from each end, carrying the
  protocol's version, so two programs that cannot understand each other
  say so: a `connect` to a listener of another version throws an
  `IOError` that names it, where the two read each other's bytes as
  frames until one looked invalid. A `connect` now waits, within
  `connectTimeout`, for the listener to answer, where on Linux and macOS
  it returned once the socket connected, before a listener busy with
  another peer had taken it. (Upgrading)
- A local name's socket is `/tmp/native-ipc-<uid>/<name>` on Linux and
  macOS, where it was `/tmp/crossbyte-<uid>/<name>`, and its pipe
  `\\.\pipe\native-ipc-<SID>-<name>` on Windows, where it was
  `\\.\pipe\crossbyte-<SID>-<name>`. A `SharedObject` region is
  `native-ipc-shm-…` where it was `CrossByteSharedObject_…` (Windows) or
  `crossbyte_shared_object_…` (Linux), and on macOS `/nipc_<hash>` with
  `/tmp/nipc_<hash>.lock` where it was `cbso_`. (Upgrading)
- WebSocket's protocol (the opening handshake, framing, the closing
  handshake, permessage-deflate's negotiation and the heartbeat's
  decisions) is wsproto's, a Haxe library CrossByte now depends on, which
  other frameworks share: Lime's `lime.net.WebSocket` speaks it from the
  same code. CrossByte's sessions extend wsproto's and keep their own
  transport, buffers and pooling, so a message costs what it did.
  (Upgrading)

### Upgrading from 1.0

#### Platform

- Install the native-ipc haxelib, which CrossByte's native IPC is compiled
  from: `haxelib install native-ipc`.
- Install the wsproto haxelib, which CrossByte's WebSocket is built on:
  `haxelib install wsproto`. A build that adds CrossByte's `src` to its
  class path rather than `-lib crossbyte` adds `-lib wsproto` beside
  `-lib emitter`.
- A program built with CrossByte 2.0.0 and one built with 1.0 cannot
  meet over a local name: their names differ, and 1.0 sends no hello.
  Rebuild both ends.
- A program of your own that opened a local name's pipe or socket
  directly must follow the new names, and send and answer the hello
  (native-ipc's `PROTOCOL.md`).
- Handle a `connect` that throws `IOError` for a listener of another
  protocol version as you would one that found nothing listening.

## 1.0.1 - Unreleased

### Changed

Entries marked "(Upgrading)" can need code changed; the Upgrading section
says how.

#### Runtime

- A failed start ends the program. An `Event.INIT` listener that throws
  leaves its runtime half started, so once INIT's other listeners have
  run the runtime exits with code 1, as a program whose startup fails
  does, and an application whose main loop CrossByte runs exits the
  process with it, where a server could run on with nothing listening.
  Failures after startup are contained as before. `CrossByte.exit(code)`
  takes the program's exit code, and every runtime keeps it as
  `exitCode`. (Upgrading)

### Fixed

#### RPC

- A wide `RPCStruct` loads on neko. Its reader held every field's locals
  in one scope, so a structure of forty fields, twenty of them optional,
  passed what neko's loader allows one function and the program did not
  load. Each field is now read in a scope of its own. An anonymous
  structure still takes a local per field, so on neko one of more than
  about a hundred fields is refused: `docs/targets.md` says so.

#### Data

- Work asked of an asynchronous `SQLiteConnection` after its open failed,
  before that failure is dispatched, is refused by its `SQLErrorEvent`
  (a statement's by its own), after the open's, as work asked a moment
  earlier is. Once the worker had stopped it threw `IllegalOperationError`
  instead, so the same call threw or reported by event as one thread or
  the other came first. A synchronous call still throws, without waiting.
- On PHP, `KVCodecs.text` refuses a value that is not well-formed UTF-8
  as it is written, with an `ArgumentError`, as such a key is refused. It
  was stored and then refused when it was read.

#### Platform

- A local connection's frames are little-endian whatever
  `ByteArray.defaultEndian` is. Their lengths were written and read in
  that order, so a program that set it to `BIG_ENDIAN` could not talk to
  one that had not. Little-endian is its default, so programs that left
  it alone meet as before. (Upgrading)
- Reading an HXSF object on PHP takes time in proportion to its text. It
  cut each string it held by characters counted from the start of the
  text, so an object of many strings took time that grew with the square
  of its size: three seconds for half a megabyte of them. Two megabytes
  now read in a fifth of a second.
- On PHP, a `File`, `FileStream`, file `Store` or SQLite error says why in
  one line. Its message carried PHP's stack trace as well, the exception's
  text, after the reason.
- `File.canonicalize` follows a junction or a symbolic link on PHP under
  Windows, where it corrected only the case of each name: PHP's
  `realpath` follows them there.
- `docs/targets.md` says that HashLink, client and server, the
  interpreter, as a client, and Neko 2.3 accept TLS 1.0 and 1.1, which
  their TLS has no setting to refuse. Natively, on the jvm and on Node a
  connection takes TLS 1.2 at least, and tests now hold each target to
  its own: certificates expired, not yet valid, for another host or from
  an authority nobody trusts are refused through every client and by a
  server requiring client certificates.
- `File`'s documentation says what PHP does on Windows with a file open in
  `FileStream`: as on Node, the file can be moved and deleted, and a
  directory with one inside it is then refused as not empty until it is
  closed. `FileTest` runs in the PHP lane.

### Upgrading from 1.0.0

#### Runtime

- An `Event.INIT` listener that throws ends its runtime with exit code 1,
  and an application's process with it, where it was logged and the
  runtime ran on. To carry on past a failure in startup, catch it inside
  the listener.

#### Platform

- Programs that set `ByteArray.defaultEndian` to `BIG_ENDIAN` and talk
  over a local name to each other: rebuild both ends with 1.0.1, since a
  1.0.0 one frames in that order and a 1.0.1 one does not.

## 1.0.0 - 2026-10-15

### Highlights

Everything since 1.0.0-rc.1. If you are upgrading from it, read
"Upgrading from 1.0.0-rc.1", at the end of this section, first.

- **Reliable UDP for games.** Reliable, unreliable and sequenced delivery
  on one session; congestion control you can replace; selective
  acknowledgements and RACK loss recovery; join cookies against forged
  joins; sessions that follow a player to a new address; opt-in
  ChaCha20-Poly1305 encryption; TURN fallback; and one message prepared
  once for many sessions.
- **WebRTC data channels.** `crossbyte.net.rtc.PeerConnection` puts ICE,
  DTLS, SCTP and data channels, reliable and partially reliable, behind one
  class, and interoperates with Chrome. With it come STUN, TURN over UDP,
  TCP and TLS, ICE restart and consent freshness, and `PeerConnectionHost`
  for many peers on one UDP port.
- **HTTP/2 and a fuller HTTP server.** HTTP/2 client and server, with ALPN,
  HPACK and the Rapid Reset defence; HTTP/1.1 keep-alive and pipelining;
  streamed responses and server-sent events; a router, compression, rate
  limiting, request limits and Prometheus metrics; one server spread over
  several cores.
- **TLS 1.3 natively.** The hxcpp fork native builds use carries mbedTLS
  3.6.7, so native TLS negotiates 1.3 with every peer that offers it and
  servers resume returning clients with session tickets. The jvm and Node
  speak it through their own TLS. On all three, `tls://` hosts and
  connections take one `TLSOptions`, a client can present a certificate
  to a server that asks for one, and a running server takes a renewed
  certificate without a restart.
- **Typed RPC.** Compiled contracts carry arrays, structures, maps, enums,
  `Null<T>` and compact numbers, generated with no reflection; the runtime
  lane has typed calls; a request can hand its answer to a receiver and
  allocate nothing; calls get deadlines, handlers can answer later and
  refuse with an error code, `@:rpcLimit` caps a method's call rate and
  argument size, clients redial (through a connection you make, with
  `dialWith`), and a hello versions the protocol.
- **Typed state replication.** `RPCPatch<T>` sends a structure as the
  fields that differ from a base both ends hold, and `RPCMapPatch<V>` a map
  of entities as the entries removed, added and changed; `@:quantize` and
  `@:range` pack fields into bits; `@:reuse` reads arguments into
  instances the session keeps; and a map patch can be filled within a byte
  budget, in your order of priority, the rest following on later ticks. A
  game's per-player tick of 17 ships is 437 bytes, or 276 quantized,
  against 613 through protobuf. `SpatialGrid` and `SparseSpatialGrid`, for
  worlds with no bounds, find who is near whom.
- **Databases.** MongoDB over its wire protocol, with BSON; a native MySQL
  client with TLS and MySQL 8 logins; Postgres parameter binding,
  cancellation and timeouts; SQLite with an asynchronous worker, attached
  databases and schemas; `ConnectionPool`, `AsyncDatabase` and
  `SchemaMigrator`; and a key/value store with revisions, compare-and-set,
  scans and transactions (`crossbyte.db.kv`), kept in memory, SQLite or
  Postgres, with typed records and an asynchronous form.
- **Crypto.** libsodium, vendored (AEAD, X25519, key exchange, BLAKE2b,
  HKDF, Ed25519, Argon2id); RSA and ECDSA signatures; JWT with RS256, ES256
  and EdDSA, JWKS, claims of your own and revocation by `jti`; OAuth PKCE; asynchronous password
  hashing.
- **Every target.** Node runs the networking stack: sockets, TLS,
  WebSocket, UDP and the HTTP server. The jvm runs the whole suite, TLS
  included. PHP is tested for what it is built for: SQLite and migrations,
  `BCrypt`, `Argon2id`, `Ed25519` and JWT, `ConfigTree` and `Secret`, with
  the same hashes, keys and signatures as the native builds. HashLink and
  Neko build and run again. The native suite runs on Windows, Linux and
  macOS.
- **Runtime and operations.** `Future` and `Completer`, work posted between
  threads, timers on a heap or a timing wheel, loop-health measures, a
  structured `Logger`, layered `Config` and nested `ConfigTree`, secrets
  that configuration names read from the environment or a file
  (`Secret.resolve`), durable `Store`, graceful shutdown and Windows service
  control, and `crossbyte.metrics`.
- **Events on Emitter.** CrossByte's events and dispatchers are those of
  Emitter 2, the event library Graphaxe builds on too: one kind of event,
  and one way to listen, for a program that uses both. Beside the
  ActionScript names, every dispatcher has Emitter's verbs under `events`:
  `events.on` and `events.once` answer with a `Subscription` that removes
  even a lambda.
- **Hardened and faster.** Every server bounds what one peer can make it
  hold or spend; the wire parsers are fuzzed; and natively, sending or
  receiving a message over TCP, UDP, reliable UDP or WebSocket allocates
  nothing once a connection is under way, but the text a WebSocket
  listener asks for.

### Added

#### Runtime

- CrossByte's events are built on Emitter 2.0 (the `emitter` haxelib, a
  dependency): `crossbyte.events.Event` extends `emitter.Event`,
  `EventDispatcher` extends `emitter.Emitter`, and `EventType` and
  `IEventDispatcher` are Emitter's `EventType` and `IEmitter`. A listener
  written for `emitter.Event` takes CrossByte's events, and a framework
  built on Emitter shares them. Every dispatcher keeps the ActionScript
  names and has Emitter's verbs under `events`: `events.on` and
  `events.once` answer with a `Subscription` whose `cancel()` removes that
  listener, a lambda included; `events.has(type, listener)` asks about one
  listener; `events.clear`, `events.dispatch`, and typed signals
  (`events.emit`). A dispatch to one listener takes 6 ns natively, where
  it took 12, and 2 on the jvm, where it took 4, allocating nothing.
  `docs/events.md` describes them. (Upgrading)
- `crossbyte.Future<T>` and `crossbyte.Completer<T>`: `then`, `map`,
  `flatMap`, `all`, `catchError`, `Future.resolved` and `Future.failed`,
  with the failure itself as `cause`. `RPCResponse` extends `Future`.
- `CrossByte.post(callback)` runs a callback on a runtime's own thread,
  from any thread, and wakes the runtime for it. It returns `false` once
  the runtime has exited.
- `CrossByte.make(loopType, timers, configure)`: `configure` runs before
  the child runtime's thread starts, and `timers` picks the scheduler.
  `TimerStrategy.WHEEL` is a timing wheel for many timers re-armed often;
  the heap stays the default.
- Loop health: `CrossByte.loopLag`, `frameOverruns`,
  `droppedScheduleDebt`, `postQueueDepth`, `timerBacklog`, `timerLag` and
  `timerOverruns`. The two overrun counts are `Float`s, exact to 2^53, so
  a runtime that keeps overrunning cannot wrap one past 2^31 into a
  negative number.
- `CrossByte.collectWhenIdle`, off by default: natively, a runtime running
  its own loop collects garbage in the gap before its next tick when a
  collection is due, rather than in the middle of a tick.
- `CrossByte.defaultSocketCapacity` (1024) sizes the poll backend's first
  allocation, and `ServerApplication.defaultTicksPerSecond` sets a server's
  tick rate before `INIT`.
- `UncaughtErrorEvent.UNCAUGHT_ERROR`: what a timer, a tick listener, a
  socket handler or a posted callback throws is logged and dispatched here,
  and the runtime carries on.
- `-D crossbyte_check_events` poisons an event or payload once its
  listener call returns, to find code that keeps one, and
  `-D crossbyte_fresh_events` makes every arrival afresh. See Upgrading.
- `Logger`: levels (`LogLevel`), `key=value` fields, JSON output,
  timestamps, a `sink` and a `recordSink` that receives each record whole,
  and categories (`Logger.category(name)`, `Logger.setLevel(category,
  level)`, inherited along the dots).
- Log fields in the order given: `Logger`'s and `LogCategory`'s methods
  take `LogFields`, a `Map<String, String>` or an array of `LogField`s
  (`[{key: "realmId", value: id}, {key: "port", value: port}]`), written in
  the array's order in text and in JSON, each value as `Std.string` writes
  it. Either is passed as it is, not copied: a call with no fields costs
  91 ns and 320 bytes natively and 30 ns and 224 bytes on the jvm, with a
  sink that keeps nothing, and one with two fields costs 230 ns natively as
  an array against 320 ns as a map. `LogRecord.fields` is a `LogFields`
  too, which reads as a map does (`get`, `exists`, `keys`, iteration in
  order) and converts to one.
- `crossbyte.core.Config`: configuration layered from defaults, `key=value`
  files and environment variables, with typed getters and `require()`.
- `Secret.resolve(ref)` reads a secret that configuration names rather
  than holds: `env:NAME` from the environment, `file:PATH` from a file (a
  Docker or Kubernetes secret, its trailing line break taken off), and any
  other text as itself. A variable that is not set, a file that cannot be
  read and a secret that is empty all throw an `ArgumentError` naming where
  it was looked for, never the value, so a service cannot start on an empty
  key. On PHP too.
- `crossbyte.core.ConfigTree`, nested configuration: JSON documents and
  files (`fromJson`, `withJson`, `withJsonFile`; bad JSON throws, naming the
  file, line and column), defaults merged in at every depth
  (`withDefaults`), and environment variables with a prefix and a separator
  (`withEnvironment`): `APP_REALM__ENDPOINTS__0__PUBLIC_PORT` reaches
  `realm.endpoints[0].publicPort`, matching a key by its letters in any
  case. Typed getters as strict as `Config`'s (`getString`, `getInt`,
  `getFloat`, `getBool`, `getArray`, `getStrings`), `section` and
  `sections` for parts of the tree, `require`, and `secret`, which reads the
  value through `Secret.resolve`. Objects merge key by key and arrays are
  replaced whole. It reads JSON with a reader of its own, the same on every
  target, PHP included.
- `crossbyte.metrics`: `Counter`, `Gauge`, `Histogram` and a `Metrics`
  registry with Prometheus text output, and `MetricsEndpoint` to serve it.
- `TypedWorker<In, Out, Progress>`, a `Worker` whose messages have types,
  and `Worker.maxMessagesPerTick` (256).
- Game-server pieces: `crossbyte.ds.SpatialGrid` and `SpatialGrid3D` for
  moving entities, `InterestSet` for what entered and left a view,
  `SequenceRing` and `crossbyte.io.ByteDelta` for delta snapshots,
  `crossbyte.io.BitWriter` and `BitReader`, `crossbyte.core.FixedStep`,
  `crossbyte.ds.IdList`, `IntPriorityQueue` and `ExpiringMap`. The
  `arena` sample builds a server from them.
- `IdList.copyFrom(other)` and `IdList.addAll(other)`, so a pooled list
  (one per tick in a `SequenceRing<IdList>`) takes a view's ids in order
  and keeps its storage, allocating nothing once it has grown.
- `crossbyte.ds.SparseSpatialGrid`, `SpatialGrid` with no bounds: a spatial
  hash, whose cells exist only where something is, found by their
  coordinates in an open-addressing table and let go when they empty. For a
  world with no edge, one too large for an array entry per cell, or crowds
  far apart: what it holds grows with the ids and the cells they are in,
  never with where they are, and one entity a long way off is one more
  cell. The same `set`, `remove`, `has`, `queryCircle`, `queryCircleIds`,
  `queryRect`, `queryRectIds` and `clear`, with `cellCount`; a query over
  more cells than are held walks those held. Cells run `MAX_CELL` (2^30)
  either way from the origin, a position past that filed at the limit. A
  sibling rather than a mode, so the dense grid's code is as it was. On the
  arena sample's workload grown to 250,000 entities, moving costs 6.8 ns an
  entity a step natively (the dense grid 6.2) and a view 479 ns (422);
  nothing is allocated once warm, natively and on the jvm.
- `crossbyte.cluster`: `SnowflakeId`, `Rendezvous` hashing, `Membership`
  and `NodeChannel`, low-level pieces for running as more than one node.
- `SnowflakeId.format(id)` and `parse(text)`, an identifier as text for a
  store or a URL: 16 lowercase hexadecimal digits, so sorting the texts
  sorts the identifiers in the order they were minted, the ones minted
  after the time's top bit becomes the sign bit (69.7 years after the
  epoch) included. `parse` takes exactly 16 hex digits, in either case, and
  throws an `ArgumentError` for anything else.
- Data structures: `BitSet.nextSetBit`, `nextClearBit`, iteration,
  `isEmpty`, `clone` and the set operations; `RadixTree.longestPrefix` and
  `longestPrefixLength`; `QuadTree.queryCircle`; `Deque` with a starting
  capacity, `iterator()` and `clear()`; `BloomFilter.clear`, `addInt`,
  `containsInt`, `addBytes` and `containsBytes`; `Array2D.fill`.
- `DispatchTable`, for linking ids to their handlers on a hot path: a
  class implementing it, its methods marked `@:case(key)`, gets a `call`
  inlined as a `switch` where it is written, calling the method directly.
  Sixteen opcodes cost 3 ns a dispatch natively, 5 to 7 on the jvm, 2 on
  Node and 8 on HashLink, as the `switch` written out does and below an
  `Array` of functions on each (9, 8, 7 and 9). It has `exists`, `get`,
  `keys`, `size` and a `@:default`, and its cases' arguments, its keys'
  type and duplicate keys are checked as it compiles.
- `crossbyte.utils.Checksum` (CRC-32, Adler-32, MD5, SHA-1 and XOR) and
  `crossbyte.utils.IntParse`, which reads an integer the same way on every
  target.
- `ByteArrayInput.require(count)` throws the `EOFError` a short read
  throws unless `count` bytes remain, so a record of several fields can be
  checked whole before any of it is read.
- Length-prefixed bytes: `ByteArrayOutput.writeVarBytes(value, offset,
  length)` writes a varuint length and then the bytes, and
  `ByteArrayInput.readVarBytes(maxLength)` reads them back as a copy. The
  length is checked against `maxLength` (1 MiB unless given) and against
  the bytes remaining before anything is allocated, so five bytes claiming
  2 GB are refused, and a failed read leaves `position` where it was, as
  `readVarUtf` does. `ByteArray` has neither, as it has no `readVarUtf`.
- `crossbyte.sys.System.sleep(seconds)`, which returns on the interpreter
  on Windows, where `Sys.sleep` can sleep for days.
- `GlobalTimer.setTimeout` and `setInterval` take a `Void->Void` function
  directly.

#### TCP

- TLS on both ends of a `Socket`. A client sets `secure` before
  `connect()`, and checks the server with `verifyCert` and
  `certAuthority`. A server is `new ServerSocket(true)` with
  `setCertificate`, `addSniCertificate` and `requireClientCertificate()`,
  stepped across ticks under `handshakeTimeout`. Natively, on the jvm and
  on Node.
- `crossbyte.net.Certificate` and `crossbyte.net.Key`, loaded with
  `fromFile` or `fromPem`, a key in any form it comes in (PKCS#1, SEC1,
  PKCS#8, encrypted or not). A `Key` prints as `[Key: redacted]`.
- ALPN: `ServerSocket.setAlpn()` and `Socket.alpnProtocol`.
- A running TLS server takes a new certificate: `setCertificate` (and a
  `ServerWebSocket`'s `cert`) on a server already listening is presented
  to every handshake from then on, and each connection already up keeps
  the one it began with, so a certificate renewed while the server runs is
  taken without a restart. `addSniCertificate` likewise, with
  `clearSniCertificates()` to replace a set; `setCertificate` on a
  `tls://` or `wss://` `NetHost` (`INetHost`); and
  `HTTPServer.reloadCertificate()`, which reads its configured files
  again. A server spread over runtimes presents it on every one, a
  `reusePort` listener each included. Natively, on the jvm and on Node,
  neko and HashLink.
- Native TLS servers resume returning clients with session tickets; build
  with `-D HXCPP_SSL_NO_TICKETS` to turn that off. With the hxcpp fork on
  mbedTLS 3.6.7, TLS 1.3 is negotiated with every peer that offers it.
- Client certificates: `Socket.setCertificate(certificate, key)` (and so a
  `wss://` `WebSocket`'s) presents a certificate to a server that asks for
  one, to go with `ServerSocket.requireClientCertificate`, natively, on the
  jvm and on Node. `Socket.peerCertificate` is the certificate the other
  end presented: a server's to its client, and a client's to the server
  that asked. `Certificate.commonName` and `Certificate.der` say what a
  certificate is, read the same way on every target.
- Limits on a server: `ServerSocket.admit(address, port)`, asked before
  any TLS work; `maxAcceptsPerTick` (64); `maxPendingHandshakes` (256);
  `maxConnections` (10,000); `maxPendingHandshakesPerAddress` (16);
  `connectionCount`, the connections open, also on `ServerWebSocket` (its
  sessions) and `HTTPServer`; and the counts `refusedConnections`,
  `acceptFailures` and `handshakeFailures`. They are `Float`s, as
  `PeerConnection.refusedChannels` is, exact to 2^53, so a flood that goes
  on for long enough cannot wrap one past 2^31 into a negative number.
- `ServerSocket.maxConnectionsPerAddress`, the most connections one
  address may hold open at once (nginx's `limit_conn`), off unless set. One
  past it is closed as it is accepted, before any TLS work, and counted in
  `refusedConnections`; neither it nor one `admit` refuses is counted in
  `handshakeFailures`. Its place comes back as it closes, or as its
  handshake fails. Addresses are keyed as `RateLimiter.addressKey` keys
  them, so an IPv6 client is counted by its /64. A `ServerWebSocket` counts
  its sessions against it and an `HTTPServer` its connections, natively,
  on the jvm and on Node.
- Limits on a connection: `Socket.maxOutputBufferSize`,
  `outputOverflowPolicy` and `outputBufferLength` for what waits for a
  peer, and `maxInputBufferSize` (16 MiB) with `inputOverflowPolicy`
  (`PAUSE` or `CLOSE`) for what the application has not read.
- `Socket.receiveBufferSize` and `sendBufferSize`, also on `ServerSocket`
  for the connections it accepts, natively and on the jvm
  (`Socket.bufferSizeSupported`).
- `Socket.peerShutdownPolicy`: `HALF_OPEN` keeps a connection writable
  after its peer half-closes, with `Event.PEER_CLOSE`, `peerShutdown` and
  `shutdown(read, write)`.
- `OutputProgressEvent.OUTPUT_PROGRESS` is dispatched as written bytes
  reach the network, with `bytesPending`.
- `ServerSocket.stopAccepting()` releases the port while open connections
  carry on.
- One server on several cores, natively, on the jvm, hl, neko and the
  interpreter: `ServerSocket.runtimes`, `runtimeCount` and
  `selectRuntime` hand each accepted connection to a runtime, and
  `reusePort` gives each runtime its own listener on Linux, natively and
  on the jvm from Java 9. A runtime that exits gives back
  the places its connections held under `maxConnections`, on a
  `ServerSocket`, an `HTTPServer` or a `ServerWebSocket`.
- `IOErrorEvent.TIMEOUT_ERROR_ID` marks a connect that timed out, and a
  `NetConnection` reports it as `Reason.Timeout`.
- `Reason.Overflow`, for a connection its transport closed because what
  waited for its peer passed the limit (`maxOutputBufferSize`, a reliable
  UDP session's queue, a local connection's `maxQueuedBytes`), told apart
  without reading a message. Such an `ioError` carries
  `IOErrorEvent.OVERFLOW_ERROR_ID`. (Upgrading)
- What a `NetConnection` holds for a slow peer: `bytesPending` says how
  many bytes sent have not gone yet, over TCP, WebSocket, reliable UDP and
  local IPC. `outputHighWater` and `outputLowWater` call `onOutputHigh`
  once a backlog reaches the first and `onOutputDrained` once it falls to
  the second (Netty's water marks, Node's `highWaterMark` and `drain`), so
  a server can skip updates for a client that has fallen behind and resync
  it. With no marks set a send costs nothing more and allocates nothing.
- `userData` on `Socket`, `ReliableDatagramSocket`, `DataChannel` and
  `NetConnectionBase`, for an application's state that should go when the
  connection goes.
- `crossbyte.net.RateLimiter`, a token bucket with `tryAcquire`,
  `secondsUntil`, `addressKey` and a bound on keys (`maxKeys`), and
  `crossbyte.net.ConcurrencyLimiter` for how many at once.
- Rate limits shared by several processes: a `RateLimiter` given a
  `RateLimitStore` (`new RateLimiter(5, 60, store)`) keeps its buckets
  there, so the limiters of PHP's requests, or of a service behind a load
  balancer, limit together, each check one read and one compare-and-set.
  `crossbyte.db.kv.KVRateLimitStore` keeps them in a `KVStore` (SQLite on
  PHP and natively) and sweeps away those full again. `RateLimiter.consume`
  answers a `RateLimitResult` (`limit`, `remaining`, `retryAfter`,
  `resetAfter`) for the `RateLimit` and `Retry-After` headers.
- `crossbyte.net.TrustedProxies`: the client's address behind trusted
  proxies (addresses, CIDR blocks, `loopback`, `linklocal` and
  `uniquelocal`), read from RFC 7239 `Forwarded` or `X-Forwarded-For` as
  the right-most hop not trusted, as Express's `trust proxy` reads it.
- `crossbyte.net.FrameCodec`: length-prefixed messages over a stream, with
  `maxFrameSize` checked on the header.
- `maxConnectionsPerAddress` and `maxPendingHandshakesPerAddress` on
  `NetHost` (`INetHost`): a TCP or WebSocket host's are its server's, and a
  reliable datagram host counts its sessions by address itself.
- `crossbyte.net.LocalAddress` and `ReflexiveAddress`, and on `INetHost`
  `localAddressFor`, `discoverPublicAddress`, `dial` and `canDial`.
- A `NetHost` URI on port 0 listens on a port the system picks.
- `tls://` for `NetHost` and `NetConnection`, TCP with TLS beside
  `wss://`, and one options type for both: `TLSOptions` (`certificate`,
  `key`, `certAuthority`, `verifyCert`, `clientAuthority`), named as
  `Socket` and `HTTPTLSOptions` name them. A `tls://` or `wss://` host,
  given them as its constructor's `tls`, reads its certificate and key and
  the authority clients' certificates must come from; a connection reads
  what to trust, whether to verify and what to present.

#### UDP

- `DatagramSocket.receiveBufferSize` and `sendBufferSize`, and
  `bufferSizeSupported`.
- `DatagramSocket` on Node.
- `crossbyte.net.StunClient`: what address the outside world sees a socket
  as, asked through the socket you give it, and the NAT's behaviour by RFC
  5780 (`classifyMapping`, `classifyFiltering`, `probe`).

#### Reliable UDP

- Delivery modes, `crossbyte.net.DeliveryMode`: `RELIABLE` (the default),
  `UNRELIABLE` and `sequenced(channel)`, which drops anything older than
  the newest message on its channel (0 to 255).
- Congestion control you can replace: `CongestionControl` (Reno, the
  default), `LossTolerantCongestionControl` for lossy radio paths,
  `ReliableDatagramSocket.congestionControl` and the server's
  `congestionControlFor(address, port)` hook.
- Measurements: `roundTripTime`, `roundTripVariation`,
  `retransmitTimeout`, `minRoundTripTime` and `framesDelivered`.
- Limits and timing: `maxMessageSize` (8 MB), `maxOutputBufferSize`
  (256 KB), `outputOverflowPolicy`, `bufferedAmount`, `ackDelay` (25 ms),
  `keepAliveInterval` (15 s), `idleTimeout` (60 s) and `closeTimeout`
  (10 s); `abort()` ends a session at once.
- A payload on the CONNECT, up to 1,200 bytes, shown to
  `admit(address, port, payload)` before anything is allocated and kept as
  `connectPayload`. `maxPendingConnections` (256) bounds half-open
  sessions, and `ReliableDatagramServerSocket.sessionCount` counts those
  open.
- Join cookies: `ReliableDatagramServerSocket.joinValidation`
  (`UNDER_PRESSURE` by default, `ALWAYS`, `NEVER`) and
  `joinValidationThreshold` (64) answer a CONNECT with a stateless cookie,
  as TCP's SYN cookies and QUIC's Retry do. `maxResetsPerSecond` (1,000)
  bounds the resets a process sends.
- `ReliableDatagramServerSocket.allowRebind`, off by default: a session
  follows its player to a new address or port, proved with a key the
  session was given. "Resuming a player" in the class documentation shows
  how to take back one whose session was reset.
- Encrypted sessions, opt-in and keyed by the application:
  `ReliableDatagramSocket.encryptionKey`, the server's
  `encryptionKeyFor(address, port, payload)` hook and an `encryptionKey`
  argument on its `connect` and `connectRelayed`. Every datagram after the
  CONNECT is sealed with ChaCha20-Poly1305 under per-direction keys derived
  with HKDF-SHA-256, with a 1,024-packet replay window; sealing adds 21
  bytes (`ENCRYPTION_OVERHEAD`). Natively, on the jvm and on Node.
  `isEncryptionSupported`, `encrypted`, `unauthenticatedDatagrams`,
  `replayedDatagrams` and `lateDatagrams` report on it.
- One message to many sessions: `PreparedDatagram.of(bytes, offset,
  length)` copies it once, and `ReliableDatagramSocket.sendPrepared` and
  `ReliableDatagramServerSocket.broadcast(message, ?sessions, delivery)`
  send it in any delivery mode without a copy per session.
- Peer to peer: `ReliableDatagramServerSocket.connect()` (and
  `INetHost.dial()`) opens a session from the server's own port,
  `discoverPublicAddress()` asks STUN through it, and `attachIceAgent()`
  runs ICE over it.
- TURN fallback for peers hole punching cannot reach: `allocateRelay`,
  `relayedCandidate`, `connectRelayed`, `permitRelayedPeer` and
  `releaseRelay`, over UDP, TCP or TLS (`relayCertAuthority`,
  `relayVerifyCert`). `onDatagram` and `sendDatagram` carry a protocol of
  your own on the same port.
- Reliable UDP on Node.

#### WebSocket

- `ServerWebSocket.upgrade(request)` decides on each session from its
  `WebSocketRequest` (path, query, headers, cookies, `Origin`,
  subprotocols, address), and can refuse it or choose its subprotocol. A
  session keeps it as `WebSocket.request`.
- `sendText` and `sendBinary`; `WebSocketMessageEvent.MESSAGE` delivers
  each message whole; `WebSocket.protocols` and `protocol`; `ping()`,
  `pong()`, `pingInterval` (30 s) and `idleTimeout` (60 s).
- permessage-deflate (RFC 7692), opt in with `perMessageDeflate` on the
  server or the client, above `compressionThreshold` (1,024 bytes).
- `PreparedMessage`, `WebSocket.sendPrepared` and
  `ServerWebSocket.broadcast(message, ?sessions)`: one message encoded and
  framed once, and compressed once, for many sessions.
- Limits: `maxConnections` (10,000; a 503 past it),
  `maxPendingHandshakesPerAddress` (16), `refusedConnections`,
  `maxHeaderSize` (16 KiB; a 431 past it), and per server or session
  `maxMessageSize` (1 MiB), `closeTimeout` (5 s) and
  `maxOutputBufferSize` (8 MiB).
- Graceful shutdown: `stopAccepting()`, `drain(timeout, ?onComplete,
  closeCode)`, `connectionCount`, `draining` and `WebSocket.closeWith(code,
  reason)`. `publishMetrics()` adds session counts to a `Metrics`
  registry.
- `runtimes`, `runtimeCount`, `selectRuntime` and `reusePort`, as on
  `ServerSocket`.
- A client checks a `wss://` server's certificate with `verifyCert` and
  `certAuthority`, and dials IPv6 literals.
- Client and server on Node.

#### WebRTC

- `crossbyte.net.rtc.PeerConnection`: ICE, DTLS, SCTP and DCEP over one
  UDP socket, with `PeerDescription` and `SessionDescription` (SDP) for
  signalling, which stays the application's. Checked against Chrome in both
  directions.
- `DataChannel` and `DataChannelSet`, reliable or partially reliable
  (`maxRetransmits`, `maxPacketLifeTime`, RFC 3758), with SCTP flow and
  congestion control and `bufferedAmount`. A peer advertising a receive
  window of 2 GiB or more, as some do to mean no limit, is sent to as one
  with that much room.
- ICE: `IceAgent`, whose `established` resolves with the pair it
  selects, consent freshness (RFC 7675), role conflicts, ICE
  restart (`restartIce()`), trickle (`onLocalCandidate`,
  `addRemoteCandidate`) and `onSelectedPairChanged`. A check arriving from
  somewhere the peer never advertised makes a peer-reflexive candidate with
  the priority the check carries (RFC 8445 section 7.3.1.3), so both ends
  order its pairs alike.
- `PeerConnectionHost`: many peer connections on one UDP port, driven by
  one tick.
- STUN and TURN: `gatherReflexive`, `gatherRelayed` and
  `gatherRelayedFrom(servers)` with failover; `TurnClient` over UDP, TCP or
  TLS (`TurnTransport`), with RFC 8656 channels (`useChannels`), IPv6
  (`requestIpv6`), RFC 8489's SHA-256 credentials and 300 redirects;
  `setRelayCredentials` for expiring credentials. A relay granting a
  lifetime of 2^31 seconds or more keeps the allocation that long.
- `readyTimeout` (30 s), `maxPeerChannels` (512), `maxLabelSize`
  (1,024 bytes), `refusedChannels`, `maxMessageSize`, `onClose`, `closed`
  and `closeReason`.
- DTLS needs mbedTLS, so `DtlsCertificate` and `PeerConnection` work
  natively only.

#### HTTP

- HTTP/2, client and server. A server sets `HTTPServerConfig.http2Enabled`
  and serves both versions on one listener (ALPN over TLS, prior knowledge
  in cleartext); a client sets `URLRequest.httpVersion`. The server has the
  Rapid Reset defence (`http2MaxResetStreams`, `http2ResetWindowSeconds`)
  and bounds request bodies per connection
  (`http2MaxRequestBodyBuffer`, 4 MB). The client shares its connections
  per origin and closes one after 90 s with nothing in flight, also when the
  program has stopped making requests; `HTTP2Backend.settings`, an
  `HTTP2Settings`, says what it advertises. `-D crossbyte_no_http2` leaves
  it out of a build.
- HTTP/1.1 keep-alive and pipelining: `keepAlive` (on),
  `keepAliveTimeout` (5 s) and `keepAliveMaxRequests` (1,000).
- `crossbyte.http.Router`: method and path routing with `:param` and
  `*rest`, as middleware.
- Answers from middleware: `HTTPRequestHandler.respond()` and
  `respondBytes()`, and `beginResponse(status, contentType, headers)` for a
  body written as it is produced (`HTTPResponseStream`), with `onDrain`,
  `Event.CLOSE` and `connected`.
- HTTPS: `HTTPServerConfig.tlsCertificatePath` and `tlsKeyPath`.
- Request limits: `requestTimeout` (60 s; a 408), `maxRequestBodySize`
  (1 MB; a 413), a 64 KB header block (a 431), `maxConnections` (10,000)
  and `maxOutputBufferSize` (8 MB).
- `onExpectContinue(handler)` decides on `Expect: 100-continue`, and
  `onError(handler, error)` answers a failed request yourself.
- Rate limiting answers `429` with `Retry-After`, keyed by
  `rateLimitKey(handler)` where the client's address is not the key.
  `HTTPRequestHandler.remoteAddress` is public.
- Compression: `HTTPServerConfig.compression` (`HTTPCompression`) sets
  what is compressed and how hard, keeps compressed static files, and
  serves a precompressed `.br` or `.gz` beside a file. Streamed responses
  are compressed as they go. `fileCacheSize` (16 MB) keeps small static
  files in memory.
- `HTTPServer.drain(timeout, ?onComplete)` finishes in-flight requests
  before closing, and `connectionCount` says how many connections are
  open.
- Metrics: `HTTPServerConfig.metrics` and `metricsPrefix`.
- One server on several cores: `HTTPServerConfig.runtimes`,
  `runtimeCount` and `reusePort`.
- PHP: `phpTimeout` (30 s; a 504), `phpMaxResponseSize` (8 MiB; a 502)
  and `phpMaxExchanges` (64), and PHP served on Node.
- `serveDotFiles`, off by default.
- Client limits and deadlines per request: `URLRequest.responseHeaderTimeout`
  (5 min), `loadTimeout`, `maxBodySize` (64 MB), `maxDecompressedSize`
  (64 MB), `maxRedirects` (10) and `maxResponseHeaderSize` (64 KB).
- Client TLS per request: `URLRequest.verifyCert`, `certAuthority`,
  `clientCertificate` with `clientKey`, and `pinnedPublicKeys`
  (`pin-sha256`).
- The client keeps connections for the next request, manages cookies
  across redirects (`manageCookies`), refuses `https` to `http` redirects
  unless `followInsecureRedirects` is set, and cancels with
  `HTTPCancelToken` or `URLLoader.close()`. Loads share a pool of
  `URLLoader.maxConcurrentLoads` (16) threads.
- `URLLoader` on Node and in a browser.
- For an `HTTPBackend`: `HTTPRequestBody`, `HTTPRequestContext.onHeaders`,
  `followInsecureRedirects`, `manageCookies`, `onRedirect` and `tls`.
- OAuth: PKCE (`createCodeVerifier()`, `codeChallenge()`),
  `OAuthConfig.clientAuthentication` (`SECRET_BASIC` or `SECRET_POST`),
  `OAuthToken.idToken`, extra authorization parameters, `OAuth.timeout`
  (30 s) and an `onError` callback.

#### RPC

- Compiled-lane types: `Array<T>`, structures (a class implementing
  `crossbyte.rpc.RPCStruct`, or an anonymous structure), enums with or
  without arguments, `Null<T>` of each, `haxe.Int64`, and compact numbers
  (`crossbyte.rpc.Float32`, `Int8`, `UInt8`, `Int16`, `UInt16`). An
  abstract over a carried type is carried as that type. Each is generated
  at compile time with no reflection; a type the lane cannot carry fails
  the build.
- Maps on the compiled lane: `Map<String, T>` and `Map<Int, T>` (and
  `StringMap<T>`, `IntMap<T>`), `T` any kind the lane carries, as
  arguments, answers, structure fields and array elements: a count, then
  each key and value as their kinds are written, in the keys' order (`Int`
  ascending; `String` by UTF-16 code unit, as RFC 8785 orders JSON names),
  so one map is the same bytes however it was built. The count is checked
  against what the frame holds before a map is made. Natively a map of
  numbers or strings boxes nothing for them. Its kind in a signature is
  `[utf8:i32]`. Against protobuf's `map<string, int32>` and
  `map<string, string>` of 8 and 256 entries, measured as the README's gRPC
  figures were, a call is fewer bytes on the wire and less processor time
  than grpc-go's and grpc-js's, natively and on Node (`docs/performance.md`,
  "Maps beside gRPC"); the RPC bench has the map calls (`--kinds`).
- `VarUInt` and `VarInt`, compact `Int`s for the compiled lane: an
  unsigned LEB128 varint (protobuf's `uint32`), or zigzagged first
  (`sint32`), one byte up to 127 (or -64 to 63), at most five, where an
  `Int` always takes four. For ticks, acknowledgements and input sequences.
  All 32 bits arrive, so a tick that has wrapped past 2^31 - 1 (as
  `SequenceRing` orders them) carries on, in five bytes. Each is an `Int`
  wherever one is wanted. Kinds `vu` and `vi` in a signature.
- Typed runtime calls: `RPCSession.runtimeCall(op)` and
  `runtimeRequest(op)` write values straight into the frame, and
  `registerArgs(op, handler)` reads them through `RPCArgs`.
- Handlers can answer later by returning `Future<T>`;
  `RPCSession.maxCallsWaiting` (256) bounds the calls waiting.
- Deadlines: `RPCResponse.within(seconds)`, `RPCSession.requestTimeout` and
  `answerTimeout`; a call past its deadline fails with `RPCTimeoutError`.
  `within(seconds)` on a commands class gives the next call a deadline of
  its own, a call made with a receiver included
  (`commands.within(2).joinThen(room, receiver)`). Every deadline
  waits in one heap a session, under one timer, so a call's deadline
  allocates nothing, whatever its length.
- `RPCCommands.delivery(mode)` sends the next call in a `DeliveryMode` of
  its own over reliable UDP (`UNRELIABLE`, or `sequenced(channel)`), for
  snapshots and deltas that the next one replaces; over TCP, WebSocket and
  local IPC it is ignored. Only the next call takes it, as with `within`,
  and a call given nothing costs nothing more. Such a call must fit one
  datagram: a larger one throws, a request failing `Unsent`.
- Deadlines and cancellation reach the handler, as gRPC's do: a call's
  deadline goes with it, and a call its caller cancels (`cancelCall`) or
  times out is cancelled on the other side. A handler reads its call as
  `RPCHandler.currentCall` (`RPCSession.currentCall` for a runtime
  handler), an `RPCCall` with `deadline`, `timeRemaining`, `cancelled`, `reason`
  and `onCancel`; one answering later stops counting against
  `maxCallsWaiting` once its caller has stopped waiting, and is not
  answered. Negotiated in the hello, so a peer without it is sent neither;
  a call whose handler never reads `currentCall` costs nothing for it.
- Calls that allocate nothing: each request method has a twin ending in
  `Then` (`joinThen(room, receiver)`) that hands its answer to a receiver
  instead of returning an `RPCResponse`: `RPCIntReceiver`,
  `RPCFloatReceiver`, `RPCBoolReceiver`, `RPCStringReceiver`,
  `RPCInt64Receiver` or `RPCValueReceiver<T>`, with failures as an
  `RPCFailure`. A number (an `Int64` among them) or `Bool` answer
  allocates nothing at either end, natively or on the JVM.
  `RPCSession.cancelCall(id)` stops waiting for a call.
- `RPCSession.dial(uri, ?commands, ?handler)`: a client that redials, from
  0.25 to 30 seconds apart, until `close()`, with `onUp`, `onDown` and
  `up`. The wait goes back to the shortest only once the peer's hello has
  come, and a connection closed before it counts as a failed attempt, so a
  peer that accepts and closes in a loop is dialled at the doubling waits
  of a refused connect.
- `RPCSession.dialWith(connect)` dials as `dial` does, redialling with its
  waits, through a function that makes each connection, so a session can
  dial `tls://` with `TLSOptions` (a private authority, a client
  certificate) or a connection a test builds; one that throws is an attempt
  that failed. `backOff()` ends the connection and counts it as a failed
  attempt, for a peer that says hello and is then refused by the
  application: the wait goes on doubling while each connection is backed
  off.
- Errors: `crossbyte.rpc.RPCError`, whose message reaches the caller, and
  `RPCSession.onHandlerError` and `onUnreadableFrame`. `RPCResponse.failure`
  says why a future's call failed as the `RPCFailure` a receiver is told
  (`TimedOut`, `Cancelled`, `Stopped`, `Disconnected`, `Unsent`,
  `Unreadable`), and a refusal says what refused it: `Refused(message)` for
  the handler's own `RPCError`, and `UnknownMethod`, `UnreadableArguments`,
  `Busy`, `NoHandler`, `HandlerTimedOut` and `HandlerFailed` for the
  session's own refusals, carried as a code after the error answer's
  message and passed on by a handler that answers with a refused call.
  A handler refuses with those cases itself, as a gRPC handler answers with
  a status code, through `RPCError.refusal(Busy, "Slow down.")`. (Upgrading)
- Error codes cross the wire: an `RPCError` thrown, returned from
  `beforeCall` or failing a future with an id (`new RPCError("No such
  room.", 3)`) reaches its caller as `RPCFailure.Refused(message, code)`,
  and the `RPCError` its future fails with has the id as its `errorId`, on
  both lanes and passed on by a handler that answers with a refused call.
  `code` is optional, so `case Refused(message):` matches a refusal with
  or without one. On the wire the id follows the refusal code 0 after the
  message, and an id of 0 sends nothing after it (`docs/rpc.md`, "On the
  wire").
- Hooks: `RPCHandler.beforeCall` and `afterCall`, and for runtime handlers
  `RPCSession.beforeRuntimeCall` and `afterRuntimeCall`.
- Limits per method: `@:rpcLimit(calls = 10, seconds = 1, bytes = 2048)` on
  a handler's method gives each session a token bucket for it, as
  `RateLimiter` keeps one, and caps the bytes of its arguments; on the
  handler class it is the limit of every method without one of its own, and
  `@:rpcLimit()` takes a method out of it. A call over its rate is refused
  `Busy` (`RPCError.RATE_LIMITED_MESSAGE`), and one over its size
  `TooLarge` before its arguments are read, both before `beforeCall`.
  `byAddress = field` spends from a `RateLimiter` the handler holds as
  well, by the session's remote address (an IPv6 client by its /64), so
  more connections do not buy a client more calls. A handler with no limit
  is generated as before, and a limited call allocates nothing: a one-way
  call takes 45 ns natively where it takes 38, and 25 on the jvm where it
  takes 19 (`docs/rpc.md`, "Limits per method").
- `RPCCall.data`, a slot for state that belongs to one call (a request
  context, a start time), set in `beforeCall` or the method and read in
  `afterCall`. It stays with the call when it answers later through a
  `Future`, and `afterCall` then runs with that call as its `currentCall`
  and its session as `session`. A plain field: a call whose handler never
  reads `currentCall` pays nothing for it, and a number stored there is
  boxed natively and on the jvm, so a hot path keeps an object it has
  already.
- Contracts, handlers and commands classes can extend others of their
  kind.
- A hello as each connection starts: `RPCSession.PROTOCOL_VERSION`,
  `peerVersion`, `peerCapabilities`, `peerCallsFingerprint`,
  `peerAnswersFingerprint` and `onHello`. A session given its handler or
  commands after it was made says hello again when they change its
  fingerprints, so the other side's are what it really has, and `onHello`
  is called again there.
- `RPCSession.maxFrameSize` (8 MiB) and `RPCHandler.session`, the
  session whose call is running.
- `RPCSession.maxInboundFrameSize` limits the frames a session reads
  apart from `maxFrameSize`, which then limits only what it sends, so a
  server can refuse large calls in (a request is answered `TooLarge`,
  naming the limit) without blocking its own large answers and snapshots
  out. It reads as `maxFrameSize` until set; `-1` makes it follow again.
- Large answers in pieces: an answer longer than `RPCSession.chunkLength`
  (64 KiB) goes in pieces between the frames sent while it goes, as HTTP/2's
  DATA frames do, so a small call behind a large answer is not held up for
  the whole of it. Natively over loopback TCP, with a 64 MB answer in flight
  a small call took 3 ms (p50) and 15 ms (p99) where it took 56 and 98, the
  large answer going as fast; over reliable UDP, behind an 8 MB answer,
  2.7 ms where it took 22. Over a WebSocket an answer past its 1 MiB
  `maxMessageSize` now arrives, where it closed the connection, and over
  reliable UDP one past its 256 KB `maxOutputBufferSize`, where it ended
  the session. Up to four answers go at once; what waits
  counts toward `maxOutputPending`, and each answer toward the reader's
  `maxFrameSize`. Negotiated in the hello, so a peer without it gets whole
  answers. Calls keep their order; an answer in pieces can complete after a
  frame sent later, and `chunkLength = 0` sends every answer whole. The
  guide's "On the wire" describes every frame. An answer of one `Bytes` is
  put together in that `Bytes`, and a large frame is written in storage
  the runtime keeps: on the jvm an 8 MB answer over TCP, both ends
  counted, allocates its size once, where whole it allocated 3.5 times.
  Over a WebSocket an 8 MB answer goes faster than whole (940 MB/s against
  720 on the jvm, 1,140 against 860 natively).
- `RPCSession.maxOutputPending` (16 MiB): over TCP or WebSocket, a peer that
  sends calls and never reads their answers is closed once that much waits
  unsent for it, where every answer waited in memory without end (one such
  client took a server past 2 GB in twelve seconds).
- A typed `session` in handlers: `extends RPCHandler<ListenerCommands, Player>`
  makes `session` an `RPCSession<ListenerCommands, Player>`, so a handler
  calls its client back through typed stubs and reads `session.data` as a
  `Player`. A session whose commands are of another class refuses such a
  handler with an `ArgumentError`. (Upgrading)
- Structures sent as what changed: an argument or an answer of type
  `RPCPatch<T>`, `T` a class that implements `RPCStruct`, carries the
  fields of a value that differ from a base both ends hold: a bit for each
  field, then each that differs whole, a nested structure as a patch of its
  own. The sender calls `patch.diff(base, current)` (a `null` base sends
  the patch from the structure as its constructor makes it, `isFull`, which
  applies to anything); the receiver calls `patch.apply(base, into)`.
  Fields are compared at the precision they are sent (a `Float32` at single
  precision, NaN equal to NaN). Writing allocates nothing, and the session
  reads every call's patch into one it keeps, valid during the call, as a
  socket's event is. Up to 64 fields; kind `~{...}` in a signature, so a
  peer without patches finds no method. `write(out)` and `read(input)` give
  a patch as bytes of its own, for a recording or a patch carried in a
  `Bytes` argument. Stellar's per-player tick (its own ship and 16 others,
  driven by its simulation) is 437 bytes with today's field types and 276
  quantized, against 546 through Yggdrasil's codec and 613 through
  protobuf, made in 0.82 us and read in 0.82 us natively, against 5.6 and
  6.3 us and 3.7 and 3.5 us (`docs/performance.md`, "Replication beside
  Yggdrasil's codec and protobuf"; the benches in `tests/perf/replication`).
  The RPC guide's "Replicating state" shows the whole of it.
- Keyed maps sent as what changed: `RPCMapPatch<V>` and
  `RPCStringMapPatch<V>`. A map of entity ids (or `String` keys) to
  structures goes as the keys removed, the entries added (each a patch from
  the default) and patches of the entries both ends hold whose values
  differ; an entry that is the same bytes is not sent. `diff(base,
  current)` takes two maps; `diffKeys(baseValues, baseKeys, currentValues,
  currentKeys)` takes views of shared frames (one map of values per tick,
  an `IdList` of ids per observer, in any order) and allocates nothing.
  Keys go ascending, the first as a zigzag varint and each next as its
  distance from the one before: a byte for ids that sit close together,
  where an `Int` is four. The receiver calls `apply(base, into, recycle)`,
  or `applyKeys` with the maps' key lists, which allocates nothing: values
  already in `into` are patched in place, and with `recycle` dropped values
  serve the next adds. A wrong base is refused naming the key; counts past
  the frame, keys out of order and keys past 2^31 - 1 are unreadable.
  `sizeBound()` bounds the bytes, for a call that must fit a datagram.
  Kinds `~[i32:{...}]` and `~[utf8:{...}]`.
- Map patches within a budget: `RPCMapPatch.diffKeysWithin(baseValues,
  base, currentValues, currentKeys, maxBytes, sent)`, and
  `RPCStringMapPatch`'s. The view's keys come in the caller's order of
  priority, and entries are carried while the patch stays within `maxBytes`;
  from the first that does not fit on, the rest wait, as Unreal's
  replication stops where a connection is saturated, so an entry never goes
  ahead of one ranked higher. `deferred` lists what waits, in order, and
  `isPartial` says there is some. Removals always go: a byte or two each,
  and one left out would leave a ghost. The base is an `RPCMapBaseline`
  (`RPCStringMapBaseline`), the record of what the observer holds, which
  the diff reads and writes: the keys it holds once the patch arrives, and
  a copy of the older value it still has for each update left out, so an
  entry left out is owed until a later patch carries it, against
  acknowledged baselines in a `SequenceRing` as for any patch, or one
  baseline written over itself over a reliable connection. Every entry is
  weighed exactly: its key as its group codes it, by a Fenwick tree of the
  chosen, and its patch by a size the RPC macros generate beside the
  codec's writer, which adds up what the writer writes without writing it;
  a budget that fits everything writes `diffKeys`' bytes and measures
  nothing. Nothing is allocated once warm, natively and on the jvm. On
  Stellar's tick, the other ships' patch per observer within 180 bytes is
  168 bytes against 375, in 1.3 us against 0.71 natively.
- `@:quantize(min, max, bits)` and `@:range(min, max)` on structure
  fields. A quantized `Float` or `Float32` goes as one of 2^bits evenly
  spaced points from `min` to `max` (clamped; NaN refused), a ranged
  integer in the bits its range needs (outside it refused, and a read past
  it unreadable), in a bit section before the structure's other fields,
  laid out as `BitWriter` lays its bits, so a section reads back with a
  `BitReader`. Stellar's remote ship is 13 bytes whole, where its `Float32`
  form is 24, and 7 as a patch of three fields. Patches compare quantized
  fields by their step, so jitter below one sends nothing. Bounds are
  literals or static inline constants of a class (`ShipRules.MAX_HEAT`),
  and `+ - * /` of those. The bounds and widths are in the structure's
  layout, `b{...}` in a signature: a peer built with others finds no
  method.
- The bit layout: `@:rpcBits`, presence bits, and arrays as one run. A
  structure marked `@:rpcBits`, or with a `@:quantize` or `@:range` field,
  puts a `Bool` in one bit and says whether a field that may be absent is
  there with one bit where the byte layout spends a byte, in its bit
  section; a quantized or ranged field may be absent too. An array of such
  a class whose fields are all bits is one run of bits for every element,
  padded once: Stellar's last four inputs, 22 bits each, are 17 bytes of
  arguments with the tick and the acknowledgement.
- `@:reuse`: arguments read into what the session keeps. On a handler's
  argument, on a contract method (`@:reuse(recent)`, naming its arguments,
  since a typed interface keeps no argument metadata) or on the handler
  class (every structure, array and map argument), the argument is read
  into one instance the session keeps, valid during the call, as a
  socket's event is: a structure's fields set in place (its nested
  structures and arrays too), an array's element instances kept, a map
  cleared and refilled. The last four inputs of a tick allocate nothing,
  natively and on the jvm. Nothing changes on the wire. Under
  `-D crossbyte_check_events` what was kept is set to garbage once the call
  returns (numbers 0xDBDBDBDB, floats NaN, strings a marker), so a handler
  that keeps one shows it at once; `-D crossbyte_fresh_events` reads each
  call's afresh. An anonymous structure marked `@:reuse` fails the build:
  it is made each call.
- `RPCCodec<T>` and `RPCCodecs.of(Type)`, the generated code of a
  structure as an interface generic code can hold: `make`, `copy` (nested
  structures and arrays into those held, so nothing is shared), `equals`
  (as the bytes would compare), `write` and `read` (into a value held, or a
  new one), `writePatch` and `readPatch`, and `name`, `fieldCount`,
  `maxSize` and `layout` (the hash of its layout, for a stored baseline).
  `RPCCodecs.of` on anything but such a class fails the build.
- RPC on Node and in a browser.
- An RPC guide, `docs/rpc.md`.

#### Data

- MongoDB over its wire protocol, natively, on the jvm, the interpreter, hl
  and neko: `mongodb://` strings, replica sets, TLS, SCRAM-SHA-256,
  SCRAM-SHA-1, X.509 and PLAIN, cursors, write concern, transactions and
  `MongoError`. With it, `crossbyte.db.mongodb.bson` (BSON on every target,
  with `BsonDocument` keeping field order) and `ExtendedJson`.
- MySQL, natively: TLS (`MySQLConfig.sslMode`, `sslCa`), MySQL 8's
  `caching_sha2_password`, `connectTimeout` (10 s), `readTimeout`,
  `writeTimeout` and TCP keepalive, `MySQLConnection.cancel()`, `ping()`,
  `escape()` and `quote()`, and `MySQLError` with `code` and `sqlState`.
- Postgres: `PostgresConnection.requestParams(sql, params)` and
  `PostgresStatement.executeParams(params)` with `PostgresParameter`;
  `PostgresConfig.statementTimeout`, keepalive settings,
  `tcpUserTimeout`, `connectionParameters` and `libraryPath`;
  `PostgresSSLMode` for `sslMode`; and `PostgresConnection.cancel()`. A
  `PostgresResultSet`'s `getResult`, `getIntResult` and `getFloatResult`
  read the first row before any `next()`, without moving past it, as
  Haxe's SQLite result set does, so
  `request("SELECT count(*) FROM t").getIntResult(0)` works as it does with
  the other drivers.
- SQLite: `attach()`, `detach()`, `loadSchema()` with
  `getSchemaResult()`, and `queueTimeout` (10 s) for an asynchronous
  connection.
- `fromString` on `SynchronousMode`, `TempStoreMode` and
  `PostgresSSLMode`, for modes read from configuration: the names in any
  case (`normal`, `verify-full`, or `VERIFY_FULL`), and for the SQLite modes
  the numbers their pragmas take. Anything else throws an `ArgumentError`
  rather than becoming another mode, as `JournalMode.fromString` now does
  too. `MySQLSSLMode.fromString` and `IsolationLevel.fromString` are the
  same for MySQL's modes and for isolation levels.
- For every driver: `SQLRow` and `executeEach` read a result row by row
  without an object per row; `itemClass` makes each row an instance of a
  class; `crossbyte.db.ITransactionalConnection`.
- `crossbyte.db.ConnectionPool<T>`, which rolls back a transaction left
  open; `crossbyte.db.AsyncDatabase<T>`, which runs work on a worker with a
  bounded queue; and `crossbyte.db.SchemaMigrator` for versioned
  migrations.
- `SchemaMigrator.sqlite()` and `SchemaMigrator.postgres()`, migrators
  with every seam filled in, for those connections or classes extending
  them: statements through `request()`, the default bookkeeping table, the
  record written with bound values and the server's UTC time, and each
  migration in a transaction (`BEGIN IMMEDIATE` on SQLite). The PostgreSQL
  one holds an advisory lock across the run (`SchemaMigrator.lockKey(table)`
  says which), so service instances starting together migrate one at a
  time. Natively and on PHP. `docs/data.md` has a Migrations section.
- `crossbyte.db.kv`, a store of records by string key, each with a
  revision, in the shape etcd and Consul keep theirs. `KVStore` has `get`,
  `put`, `compareAndSet` (written only at the revision read, or with 0 only
  where there is none), `delete` and `compareAndDelete`, which leave a
  tombstone the revision goes on from, `scan` of a prefix or a range in key
  order a page at a time (`KVScanOptions`, `KVPage`), `purgeTombstones`,
  and `begin`, `commit` and `rollback`. Keys sort by code point, the order
  of their UTF-8, on every target. `KVOptions` bounds keys (1 KiB), values
  (1 MiB), scans (1,000 records) and pages (4 MiB of values).
  `MemoryKVStore` keeps the records in memory on every target, for any
  thread. `SQLiteKVStore` keeps them in an SQLite table, natively and on
  PHP, which it makes through `SchemaMigrator.sqlite()`; each write is one
  upsert with its revision check in its `WHERE`, and a page of a scan is
  one statement that reads no value it does not return. `PostgresKVStore`
  keeps them in PostgreSQL, natively, its table made through
  `SchemaMigrator.postgres()` with its key in the "C" collation and every
  value bound. `KVRepo<T>` reads and writes typed values under a key prefix
  through a `KVCodec<T>`, keeping its `schema` beside each value and
  refusing a record of another (`KVError` `SchemaMismatch`): JSON
  (`KVCodecs.json`), an `RPCStruct` class's binary codec with its layout as
  the schema (`KVCodecs.rpc(RPCCodecs.of(Ship))`), text and bytes.
  `AsyncKVStore` and `AsyncKVRepo` run each call on a worker with a store
  from a `ConnectionPool`, through `AsyncDatabase`, and answer with a
  `Future` on the runtime that made it; `transaction` runs a body on one
  store inside `begin()` and `commit()`; `maxQueuedBytes` (64 MiB) bounds
  the values its writes not yet done hold, beside `AsyncDatabase`'s bound
  on how many wait. `docs/data.md` has a section on it.
- Compression: `CompressionAlgorithm.LZ4_FRAME` and `ZLIB`, and
  `ByteArray.uncompress(algorithm, maxOutputSize)`.
- Crypto from libsodium: `AEAD` (XChaCha20-Poly1305), `X25519`,
  `KeyExchange`, `GenericHash` (BLAKE2b), `HKDF`, `Argon2id`,
  `ConstantTime.equals` and `SecureMemory.wipe`, each with `isSupported`
  and `unsupportedReason`, as every crypto class has.
- `PublicKeySignature` and `SignatureKey`: RSA and ECDSA over SHA-256.
- JWT: `RS256`, `ES256` and `EdDSA` signers; `JWKSet` and `JWK`;
  `JWT.verify`, which says why a token was refused (`JWTRejection`);
  `maxTokenLength`, `acceptedTypes`, `requireType` and `updateKeys`; and
  claims of your own (`claim`, `hasClaim`, `setClaim`).
- JWT verification options: `JWT.expectedIssuers` accepts a token from any
  of several issuers (beside `expectedIssuer`, compared exactly).
  `JWT.requireIssuedAt` refuses a token without `iat`
  (`MISSING_ISSUED_AT`) or whose `exp` is not after it
  (`EXPIRY_NOT_AFTER_ISSUE`). `JWT.verifySignature(token)` makes every
  check but those of the times, for a caller that judges them itself, such
  as one revoking a token until it would have expired. `JWT`, `JWKSet` and
  their tests run on PHP as well.
- JWT revocation: `JWTRevocationList` refuses tokens by `jti` until their
  own `exp` and a `leeway` (60 s), and drops each as its time passes, the
  soonest first. Given one as `JWT.revocations`, `verify` refuses a listed
  token as `JWTRejection.REVOKED`, checked last, and `JWT.revoke(token)`
  lists a token once its signature and claims check, so only a verifier's
  own tokens fill it. Bounded by `maxEntries` (100,000): past it the entry
  expiring soonest makes room and the list fails closed, refusing every
  token that expires no later until that time has passed, so a revoked
  token is never taken again. It works on its own too (`revoke(jti, exp)`,
  `isRevoked`), is safe across threads, runs on PHP, and is kept in memory:
  `entries()` gives a snapshot for an application to keep and revoke again
  as it starts.
- Ed25519 keys in JWK Sets, and sets written out: `JWKSet.parse` reads RFC
  8037's `OKP` keys (`crv` `Ed25519`; other curves are listed in
  `ignored`), `JWK.ed25519PublicKey()` gives the 32 bytes, and
  `JWKSet.signer(EdDSA)` makes the verify-only signer. `JWK.ofEd25519(kid,
  publicKey)` makes such a key, and `JWKSet.ofKeys(keys).toJson()` (and
  `JWK.toJson()`) write a set out, the same text on every target, so an
  issuer can publish its current and next keys for rotation.
- Ed25519 and EdDSA tokens on PHP: `Ed25519` signs and verifies through
  PHP's sodium extension, which is libsodium as the native builds are, so
  keys and signatures are the same bytes on both and RFC 8032's vectors
  hold on each. `JWTSigner.EdDSA` works there too: a PHP service can mint
  tokens that native servers verify holding only the public key.
  `isSupported` is true on PHP when the extension is loaded, and
  `unsupportedReason` says to load it when it is not.
- `Ed25519.keypairFromSeed(seed)`, the pair a 32-byte seed makes
  (`SEED_BYTES`): the private key as RFC 8032 writes it and a JWK's `d`
  carries it, natively and on PHP. A service can keep only the seed as its
  secret.
- Argon2id on PHP, through the sodium extension: `hash`, `verify`,
  `needsRehash` and `derive` write and accept the same `$argon2id$` strings
  and tags as the native builds and Node, so a password set through a PHP
  service verifies on a native server. `isSupported` and
  `unsupportedReason` as for `Ed25519`; the async forms run in the call
  there, as PHP has no threads.
- `BCrypt.hashAsync` and `verifyAsync`, the same on `Argon2id`, and
  `dummyHash` on both. Argon2id also runs on Node 24.7 and later.
  `BCrypt.dummyHash` keeps its hash in a static, which a PHP process
  serving one request rarely still has, so there the sign-in it protects
  pays for a hash as well as the verify; its docs show a fixed hash to
  verify against on PHP instead.
- `BCrypt.isSupported` and `unsupportedReason`, for `hash`, whose salt comes
  from `SecureRandom`; `verify` works everywhere.
- `SecureRandom.isSupported`, and `SecureRandom` on Node and in a browser.
- `SecureRandom.fill(bytes, offset, length)` fills part of a `ByteArray`
  you keep, allocating nothing natively and on Node; a WebSocket client
  draws its frame masks into a pool it keeps this way.
- `Vector` loops: `for (item in vector)` and `for (index => item in
  vector)`, at about what an `Array`'s loop costs. `Vector.ofArray` and
  `toArray` copy between a `Vector` and an `Array`.

#### Platform

- Node runs `Socket`, `ServerSocket` (with TLS), `WebSocket`,
  `ServerWebSocket`, `DatagramSocket`, reliable UDP, `HTTPServer`,
  `NetConnection`, `NetHost`, RPC, `NativeProcess`, `FileStream` and
  `URLLoader`; an `Application` drives itself there and in a browser.
- The jvm has TLS (with ALPN, SNI and client certificates) and runs the
  whole suite; HashLink and Neko build and run it too.
- A PHP test lane: `ci/php-tests.hxml` runs the classes that claim PHP
  (SQLite and `SchemaMigrator`, `BCrypt`, `Argon2id`, `Ed25519`, JWT and
  `JWKSet`, `SecureRandom`, HMAC-SHA256, `ConfigTree` and `Secret`) on PHP
  8, and CI runs it on Linux with Ubuntu's PHP 8.3. `docs/targets.md` says
  what PHP has.
- `crossbyte.io.Store`: durable key/value storage on every target,
  IndexedDB in a browser and files elsewhere.
- `crossbyte.sys.ProcessLifecycle`: graceful shutdown on SIGINT, SIGTERM
  and SIGHUP, Windows console events, and the Windows Service Control
  Manager (`installServiceControl(name)`). The `windows-service` sample
  shows a server draining on `sc stop`.
- `System.applicationId`, set with `-D crossbyte_app_id`, names an
  application's storage directory.
- `File.openWithDefaultApplication()`.
- `SharedObject.remove(name)` and `SharedObject.lockWaitTimeout`;
  `LocalConnection.maxQueuedBytes` (16 MB) and `bytesPending`.
- `NativeProcess` on the jvm, hl and neko.
- A child process's directory and environment:
  `NativeProcessStartupInfo.workingDirectory` starts the child in another
  directory (one that is not there is an `ArgumentError`), and
  `environment` adds variables to this program's, sets over them, or takes
  one out with a null, so a child need not see a secret its parent holds;
  `inheritEnvironment = false` gives it those variables alone. A relative
  path to the program is still read from this program's directory.
  Natively (through a spawner of CrossByte's own when either is set, as
  hxcpp's cannot set them), on the jvm and on Node; HashLink and neko throw
  an `IllegalOperationError` for either.
- A child's output by line: `NativeProcessEvent.STANDARD_OUTPUT_LINE` and
  `STANDARD_ERROR_LINE` carry each line, without its `\n` or `\r\n`,
  however the reads cut it, the last as the stream closes. A line longer
  than `NativeProcess.maxLineLength` (64 Ki characters) arrives in pieces
  of that length, so a child that never writes a line break is held to
  that much. Dispatched only while listened for, on every target with
  `NativeProcess`.
- Test harnesses: a load and churn harness (`ci/load.hxml`), a soak
  (`ci/soak.hxml`), fuzzing of the wire parsers, a performance suite and
  allocation budgets. `docs/testing.md` describes them.

### Changed

Entries marked "(Upgrading)" can need code changed; the Upgrading section
says how.

#### Runtime

- A listener added again for a type it already listens for is not added
  again, as in ActionScript: it keeps its place, runs once, and one removal
  takes it out. The runtime, which holds a tick listener for each
  connection, timer and task, keeps each add as before (`allowDuplicates`),
  so adding one is not a search through the others. (Upgrading)
- Every way of adding or removing a listener reaches what a class does
  about it, `events.on`, `events.once` and `removeAllListeners()`
  included: a
  `DatagramSocket` polls while anything listens for `DATA`, a
  `ServerSocket` accepts while anything listens for `connect` (and a spread
  server hands its runtimes the `connect` listeners added or removed after
  `listen()`, a `once` listener for one connection), a `WebSocket` reports
  output progress while anything listens for it, and a request handler
  tells a `CLOSE` listener added after its client left. `removeAllListeners()` left a socket polling, and a server
  accepting, for nobody.
- An event's `target` and `currentTarget` are `emitter.EventTarget`s, not
  `Object`s: each is still assigned to the dispatcher class it is, and no
  longer to anything else. (Upgrading)
- `SQLEvent` and `SQLErrorEvent` give the connection or statement that
  dispatched them as their `target`, which was null.
- Every duration is a `Float` of seconds. The members that took
  milliseconds have new names (a socket's `connectTimeout`, the HTTP
  client's `readTimeout`, `responseHeaderTimeout` and `loadTimeout`,
  SQLite's `lockWaitTimeout`, RPC's `pingInterval` and `idleTimeout`), and
  `GlobalTimer` takes its delay first; wire formats that define
  milliseconds (MongoDB's `maxTimeMS`, a WebRTC channel's
  `maxPacketLifeTime`) keep them. (Upgrading)
- A failure in a callback no longer ends the process. What a timer, a tick
  listener, a socket handler or a posted callback throws is logged with
  `Logger.error` and dispatched as `UncaughtErrorEvent.UNCAUGHT_ERROR`; a
  recurring timer stays armed, a stream socket whose handler threw is
  closed, and every other connection carries on. `HostApplication.advance`
  and `CrossByte.pump` report such failures the same way rather than
  rethrowing them. (Upgrading)
- Work posted from another thread runs as soon as the runtime is free,
  not at its next tick: natively at twelve ticks a second, the mean wait
  fell from about 40 ms to under 0.1 ms. `exit()` from another thread stops
  the loop at once.
- `tps` delivers the rate it names (60 ticks a second measured 56.6 and now
  59.9), and the frame wait sleeps once rather than a millisecond at a
  time. `ServerApplication`'s `POLL` loop waits inside poll, so a socket
  that becomes ready is served at once, not at the next tick.
- Every timer due in a frame fires in that frame; the cap of 256 a frame is
  gone, and a burst is spread only when it would overrun the frame.
  `haxe.Timer` and `GlobalTimer.setInterval` run at the rate they are given,
  on the runtime of the thread that made them, where each period was
  rounded up to whole ticks.
- `haxe.Timer.stamp()` is monotonic natively (`CLOCK_MONOTONIC`, or
  QueryPerformanceCounter on Windows) and on the jvm (`System.nanoTime`),
  and every deadline in CrossByte is measured on it, so setting the time of
  day no longer moves them.
- Arming, clearing, pausing and resuming a timer allocates nothing, and the
  heap scheduler keeps each timer's position on the timer: at 30,000
  timers, a simulated second costs 40 ms of CPU where it cost 499 ms.
- A timer interval of zero or less is refused with an `ArgumentError` on
  every build. A debug build threw a `String`, and any other ran the
  timer once, as a timeout. (Upgrading)
- A `haxe.Timer`, or a `GlobalTimer.setInterval`, that has fallen more than
  an interval behind owes one run, not every one it missed. One shorter
  than a frame fell further behind every frame, and once frames came
  faster (a host pumping faster, a higher `tps`) ran at every one: ten
  times its rate, for as long as the debt lasted.
- Natively, a runtime has SIGPIPE ignored, unless the application set it
  otherwise, as Node, the jvm and Python do: a write to a stdout nobody
  reads any more (piped into `head`, a log shipper that died) fails as any
  other write does, where it ended the process with exit code 141. Logging
  there, and the runtime's flush of what was logged, let the failure go
  rather than throwing into the frame. Sockets never raised it. (Upgrading)
- Dispatching an event costs about half what it did, and adding or removing
  a listener copies the list only while a dispatch is walking it. A
  dispatcher keeps its first few types in a short chain rather than a map
  (eight natively, four on JavaScript), so natively it halves again,
  whichever of its types is asked about: a dispatch to one listener takes
  9 ns where it took 20, `hasEventListener` 1 ns where it took 12, and a
  dispatcher with one listener 184 bytes where it took 264.
- `CrossByte.current()` answers the calling thread's own runtime on every
  threaded target, and throws on a thread no runtime belongs to.
  `CrossByte.make()` no longer takes over the calling thread's timers, and a
  child runtime exits with the runtime that made it. (Upgrading)
- `Worker`, `TaskPool` and `Task` run their work on other threads on the
  jvm and the interpreter too, where it ran inline on the caller's thread.
  `System.processorCount` answers on every target. A `Worker` delivers up
  to `maxMessagesPerTick` messages a tick, where it delivered one.
- The events and payloads a socket hands out for each arrival are reused
  for the next arrival. (Upgrading)
- Every socket starts in `ByteArray.defaultEndian`, little-endian unless
  changed, as `ByteArray` does. (Upgrading)
- `writeObject` frames HXSF and JSON with a 32-bit length, so an object is
  no longer limited to 65,535 bytes of text, and `readObject` bounds what
  it makes: `ByteArray.maxObjectValues` values, nested at most 256 deep
  (128 in AMF). (Upgrading)
- Event-type constants are typed (`EventType<T>`), so a listener of the
  wrong event is refused at compile time. (Upgrading)
- `ByteArray` reads and writes integers a word at a time (`readInt` 526 to
  889 MB/s), appends without zeroing what it overwrites, and
  `ByteArray.fromBytes` no longer allocates a 64 KB buffer only to drop
  it.
- `Logger` writes timestamps in UTC with milliseconds, escapes control
  characters in messages and fields so a client cannot forge a log line,
  and writes JSON fields in a fixed order. (Upgrading)
- `Vector` is an abstract that works on every target, with typed callbacks
  (`VectorCallback`), `sort` taking a comparator and `concat` taking
  vectors, and `map` giving a vector of what its callback returns.
  (Upgrading)
- Natively, `Vector` reads and writes about fifteen times faster than it
  did where the code using it names its element type: an element of a
  `Vector<Int>` takes about 1.2 ns rather than 18 to 21, where each one was
  boxed through a dynamic array (an `Array<Int>` takes 0.6). `pop`, `shift`
  and `removeAt` take an element without boxing it or making an array, so a
  push and a pop cost 8 ns rather than 43, and 20 for an `Array`.
- `Vector`'s `every`, `filter`, `forEach`, `map` and `some` put a callback
  written where it is passed into the loop itself, and call any other typed
  function directly: natively `forEach` costs 2 ns an element rather than
  34, and on the jvm 1 rather than 4. (Upgrading)
- `Vector.sort` is stable on every target, where the interpreter's and the
  jvm's `Array.sort` are not (the jvm's is a quicksort, quadratic at
  worst), and a comparator that throws leaves the vector as it was, but on
  JavaScript. Natively a comparator written in place goes into the sort
  itself: 62 ns an element for a thousand rather than 150, and `sort()` of
  a `Vector<Int>` 7 rather than 330; on the jvm `sort()` of one costs 13
  rather than 88.
- `SlotHandle` carries 20 index bits and 11 generation bits, and `SlotMap`
  and `PackedSlotMap` reuse the slot freed longest ago, so a stale handle
  no longer comes to name a new entity within seconds. (Upgrading)
- `ObjectPool` keeps at most `maxFree` free objects, 10,000 unless set.
  (Upgrading)
- `BitSet` refuses a negative index, and a negative `length`, with a
  `RangeError`, as it refuses a bit past `MAX_INDEX`, where it threw the
  String "Index out of bounds". (Upgrading)
- `Version` compares part by part, so a part past 999 orders as written
  (2024.10.1 came after 2025.1.0, each held to 999), reads `v1.2.3` as
  1.2.3, and has `Version.compare` for sorting. `new Version` takes a part
  past 999 and refuses one below zero, as the setters now do. (Upgrading)
- `Random.reseed` spreads its seed over the generator's count, so seeds
  next to each other draw unrelated sequences, and a seeded sequence of the
  shared generator differs from before. (Upgrading)
- `MathUtil.lerp` takes and answers `Float`, so `lerp(0, 10, 0.5)`
  compiles. (Upgrading) `MathUtil.wrap` makes no `Int64` on JavaScript,
  eval and neko: 30 times faster on Node and over a hundred times on eval
  and neko.
- `SwitchTable` is `DispatchTable`, and `SwitchTable.make` is
  `Dispatch.make`, which builds a `switch`, typed by its handlers, where it
  compared each key dynamically in turn and called the handler through
  `Reflect`: a dispatch among sixteen opcodes costs 17 ns natively rather
  than 138, 7 on the jvm rather than 45, 5 on Node rather than 36 and 9 on
  HashLink rather than 964. Its keys are constants of one type, its
  handlers take the same arguments, and a dispatch is typed, all checked as
  it compiles. (Upgrading)
- `TaskPool.submit` returns `Task<Any>`, `UncaughtErrorEvent.origin` is
  `Any`, and `EnumUtil`, `ListedMap.KeyValuePair`, `Object.entries()` and
  `TypedObject.entries()` use classes rather than anonymous structures.
  (Upgrading)
- `Object` and `TypedObject` give their entries through one iterator
  class, `ObjectEntries`, which a loop calls directly. Natively a walk of
  four fields, by `entries()` or by `for (name => value in object)`, takes
  68 ns rather than 182 for an `Object` (192 bytes rather than 808), and
  for a `TypedObject`, which made an anonymous structure for every field
  and an array of them first, 68 rather than 100 to 110 (192 bytes rather
  than 680). On the jvm a `TypedObject`'s walk takes 34 ns rather than 74
  (72 bytes rather than 248), and on Node 28 rather than 38.
- On JavaScript, text is encoded and decoded through the platform's
  `TextEncoder` and `TextDecoder`, about ten times faster, and a NUL byte no
  longer ends a string read from bytes (on HashLink too).
- `ByteArray.writeUtfBytes` and `writeUtf` write ASCII text without making
  bytes of it first: natively by one copy (`writeUtf` of twelve characters
  in 15 ns rather than 62), and on JavaScript a character at a time for
  text of up to 256 characters (twelve characters on Node in 56 ns rather
  than 690). On Node all other text is written straight into the
  `ByteArray`, by a loop up to 16 characters and past that by
  `TextEncoder.encodeInto`, where `TextEncoder` made a buffer of it first:
  eleven characters with accents in 48 ns rather than 770, and 200 ASCII
  characters in 130 rather than 1,400; `ByteArrayOutput`'s string writes
  likewise, twelve characters in 43 ns rather than 715. Natively text held
  as UTF-16 is sized and encoded straight in, where `Bytes.ofString` made
  a buffer of it to copy (eleven accented characters in 30 ns rather than
  84), and `ByteArrayOutput` copies text held a byte a character straight
  in as `ByteArray` does (twelve characters in 7.8 ns rather than 49). On the jvm
  ASCII text of up to 256 characters (64 for `writeUtf`) is copied
  straight in by `String.getBytes`, allocating nothing, where a loop wrote
  it a character at a time: 200 characters in 83 ns rather than 146. On HashLink
  strings are decoded in one pass, ASCII four bytes at a time, where
  `getString` made three: `ByteArray`
  reads of 200 characters take 790 ns rather than 1,530. There `ByteArray`
  writes text from the string's own units straight into its buffer, where
  HashLink's encoder made a buffer and a `Bytes` of it to copy in:
  `writeUtfBytes` of twelve characters in 15 ns rather than 62, eleven
  with accents in 31 rather than 64, and 200 in 175 rather than 235. On Node
  `ByteArrayInput` and `ByteArrayOutput` strings go through the platform's
  decoder and encoder, 144 ns rather than 1,456 for 200 characters, though
  a short string past ASCII read through `ByteArrayInput` costs about
  30 ns more (153 rather than 121 for eleven characters).
- `ByteArray` reads and writes numbers straight from and to its memory
  natively and on HashLink, and through its `DataView` on JavaScript,
  rather than a byte at a time: natively `readDouble` takes 3.9 ns rather
  than 20.7 and `writeInt` 3.0 rather than 9.3, and on HashLink a
  big-endian `writeDouble` 23 rather than 70. Building a 98-byte message
  takes 161 ns natively rather than 468, 125 on the jvm rather than 225,
  2.2 µs on Node rather than 10.4, and 1.0 on HashLink rather than 2.1. A
  `ByteArray` grows by half again what it holds, and to at least 64 bytes,
  so a 98-byte message written into a new one allocates three times rather
  than six, and copies only what is readable as it does. Bytes copied into
  a new one (`writeBytes`, or `readBytes` into it) make it exactly their
  size, as that is mostly all it will hold. On the jvm and HashLink a new
  one is not zeroed a second time. The bounds kept since
  (see Fixed) cost an index read 0.3 ns on Node, and reading `position`
  and `bytesAvailable` 1 ns on HashLink.
- `TypedObject<T>` converts from and to its `T` and nothing else: a
  `String`, an `Int` or a `TypedObject` of another type no longer compiles
  as one, nor does one as an `Int`. A `Dynamic`, as `Json.parse` gives,
  still converts, and `for (field in typed)` compiles. (Upgrading)
- A null `String` in a `PrimitiveValue` stays null, where it became `""`:
  `isNull()` is true of it, and it converts as null does, to 0, `0.0`,
  `false` and back to a null `String`, where `toInt` threw and `toFloat`
  was NaN. A null value's `toString()` is null, not `"null"`. (Upgrading)
- `PrimitiveValue` throws CrossByte's own errors, as every other refusal
  does: a `RangeError` for a number outside the range of the type asked
  for (`"4294967296"` or `3e9` as an `Int`), and an `ArgumentError` for
  text that is not a number, a value that is not a primitive, and
  `fromDynamic` given one, where it threw a `String`. (Upgrading)
- `PrimitiveValue.toBool` of NaN is `false`, as JavaScript's
  `Boolean(NaN)` is, where it was `true`. (Upgrading)
- A NaN `Float` in a `PrimitiveValue` stays NaN, as it does through
  `fromDynamic`, where it became `0.0`: `toFloat()` is NaN, `isFloat()`
  true and `toInt()` an `ArgumentError`, where they were `0.0`, `false`
  and `0`. (Upgrading)
- `Object` has ActionScript's `hasOwnProperty`, `propertyIsEnumerable`,
  `isPrototypeOf`, `valueOf`, `toString` and `toLocaleString`, and they
  answer the same on every target. Called through the object's own
  fields, as they were, they answered only on JavaScript, whose objects
  have them on their prototype, and threw everywhere else; natively, on a
  null `Object`, the process ended. (Upgrading)
- An `Object` is read and written by a number, `object[i]`, where only a
  `String` compiled in brackets: an `Array`'s element (null outside it; a
  write past the end grows it, and a negative index is a `RangeError`),
  or of anything else the field named by the number, as ActionScript
  reads `object[0]`.
- `FieldStruct`'s `exists`, `get`, `delete` and `clear` are methods,
  `fields.exists(name)`, as `keys`, `values` and `entries` are, where they
  were static and `fields.exists(name)` read the key `exists` and did not
  compile. `delete` says whether there was a field. (Upgrading)

#### TCP

- A URI that `NetConnection`, `NetHost` or `parseUrl` cannot use throws an
  `ArgumentError` naming it, with what is wrong or the schemes that would
  work, where it threw a bare string such as "Protocol error" or
  "missing host". (Upgrading)
- On the jvm a select allocates nothing, under Java 8 and from Java 11:
  under Java 8 the selector puts the sockets it finds ready in an array
  CrossByte gives it, as Netty does, and from Java 11 it hands each to
  CrossByte as it finds it (`Selector.select` with an action), where it
  added each to a set. A TCP echo, a datagram and a reliable UDP message
  allocate 0 to 48 B where they took 72 to 160 (on Java 17, 0 where they
  took 72 to 144). The JDK's own selector still boxes a socket's
  descriptor past 127 each time it is ready, 16 B, which a busy server's
  sockets all are; HotSpot's `-XX:AutoBoxCacheMax=65536` removes that.
- Natively a TCP message allocates nothing once a connection is under way,
  and an idle connection lets go of its buffers' storage after five quiet
  seconds: 1.7 KB where it kept 51 KB after a 16 KB message each way.
- Natively and on the jvm a socket or WebSocket output grown past 64 KB
  takes its storage from a pool its runtime keeps, by size, and gives it
  back when it empties, where it grew anew for each burst: a connection
  sent 1 MB bursts allocates 16 KB for each megabyte where it took
  2.4 MB, at a third of the CPU or less. A backlog is moved down in place
  rather than into a new buffer.
- Input past 64 KB takes its storage from the same pool, natively and on
  the jvm: a socket's, a WebSocket session's, and a WebSocket message's,
  given back once read or handed out. A connection receiving 1 MB bursts
  allocates 17 KB for each megabyte where it took 2.4 MB, at a third of
  the CPU or less; 1 MB WebSocket messages 32 KB where they took 3.4 MB.
  A socket moves what it has not read down only once a quarter of its
  input has been read: an application reading 64 KB a pass behind an
  8 MB backlog spent 4.5 ms of CPU a megabyte moving it, and spends 0.37.
- The pool's sizes are a quarter apart, four to each doubling from 64 KB
  to 32 MB, where they were powers of two, so a buffer holds at most a
  quarter more than it needs: a 9 MB backlog 10 MB where it held 16,
  4.5 MB 5 MB where it held 8. A buffer takes at once the size its last
  burst needed rather than growing through the sizes below it, and a
  connection that closes gives its storage back. An output that grows
  while part of it has been sent lets go of the sent part first, so a
  slow reader's output holds its backlog rather than up to twice it.
- The socket read buffer is 64 KB, shared per thread, and arrivals are
  appended to the input rather than rebuilding it, so a reader that falls
  behind no longer costs the square of its backlog. Draining an output
  backlog is linear too: 16 MB took 2.4 s of copying and takes 1.5 ms.
- Each socket reads at most a megabyte a pass and the loop polls again, so
  a fast sender no longer holds the runtime or the server's memory. A TLS
  socket reads more than one record a pass: an upload over TLS went from
  16 to 410 MB/s.
- Listeners, connects in flight and TLS handshakes are in the poll set:
  at twelve ticks a second on eval and the jvm, connect to accept went from
  41 to 57 ms to under a millisecond.
- A TCP `NetConnection` writes what a pass sent in one system call: RPC
  over TCP at twenty calls a tick went from 7.0 to 0.5 µs of CPU a call.
- Host names are looked up off the runtime's thread, on four threads the
  process keeps, with answers cached for 30 seconds and failures for 5. A
  name that does not resolve is an `ioError` after `connect()` returns.
  (Upgrading)
- A server out of descriptors no longer spins: after a failed accept the
  listener is set aside for 5 ms, doubling to a second. Natively on Linux
  and macOS the soft descriptor limit is raised to the hard one at start
  (`-D crossbyte_keep_nofile` keeps it), and on Windows a listen backlog
  can reach 65,535 where it stopped at 200. (Upgrading)
- With the hxcpp fork on mbedTLS 3.6.7, a full TLS handshake costs a
  native server about a quarter of the CPU it did, AES-GCM uses AES-NI in
  MSVC builds, and TLS 1.0 and 1.1 are refused. (Upgrading)
- A `NetConnection` ends the same way over TCP, WebSocket and reliable
  UDP: `onError`, then `onClose` once with the reason. A WebSocket close
  reports its code as `Reason.Code`. (Upgrading)
- `RateLimiter` lives in `crossbyte.net` and is a token bucket; IPv6
  clients are keyed by their /64. (Upgrading)
- `Socket.close()` sends what was written before it, and a
  `Socket.connectTimeout` of 0 is no deadline natively too, as on Node.
- On the jvm: one `ByteBuffer` per array rather than one per read or
  write, a selector per thread, registrations kept between selects, reads
  that copy nothing (about 1,200 to 3,000 MB/s over loopback), and a
  connect that no longer holds the runtime's thread.

#### UDP

- On Linux, natively, a `DatagramSocket` reads with `recvmmsg` (up to 64 a
  call) once datagrams queue, and reliable UDP sends with `sendmmsg` and
  UDP segmentation offload: a bulk send costs 1.15 ms of CPU a megabyte
  where it cost 2.9.
- A socket reads up to 1,024 datagrams each time it is found readable,
  where it read 64, keeps its own address, and sends a fifth faster
  natively. On the jvm a send allocates nothing.
- `DatagramSocket.connect()` and `send()` to a name look it up off the
  runtime's thread, and a send keeps the answer for a minute. (Upgrading)
- `DatagramSocket.send` is an inline forwarder, so it boxes nothing on the
  jvm. (Upgrading)
- A datagram too large to send says so, with the size and the limit.
- On the jvm a runtime with one socket, as a UDP server has, keeps it
  registered with its selector rather than registering it afresh every
  frame: a datagram sent and received allocates 72 B where it took 312.
- Natively a socket gathers what a pass sends in 64 KB chunks that its
  runtime pools and lets go of when quiet, where one buffer grew to twice
  the largest pass and was kept for good: after a 1 KB broadcast to
  10,000 peers, 10 MB is held while broadcasting and 0.2 MB once quiet,
  where 17 MB was held either way. What a pass no longer needs waits one
  quiet interval (five seconds) as spare, so a burst after a short pause
  allocates nothing.

#### Reliable UDP

- On the jvm CrossByte's own socket reads and writes no longer box their
  offsets and lengths (an `Integer`, allocated past 127, for every
  argument with a default): an HTTP/1.1 GET allocates 264 bytes rather
  than 280, a POST of 4 KB 4,664 rather than 4,724, and a 200-byte
  reliable UDP message 128 rather than 144.
  `ReliableDatagramSocket.send` is `inline`, as `DatagramSocket.send` is,
  so a caller's own arguments are not boxed either. (Upgrading)
- A session sends at the rate the path carries: a retransmission timeout
  measured as RFC 6298 has it (200 ms to 10 s), a window that starts at ten
  frames and halves on loss, selective acknowledgements with RACK loss
  detection (RFC 8985) and a tail probe. Frames a pass produces go out
  bundled, and sessions ask for a megabyte of socket buffer each way
  (`WINDOW_BUFFER_SIZE`). Natively over loopback, 1,000-byte messages
  under 1% loss went from 0.35 to 58 MB/s, and 100-byte messages from
  45,000 to 258,000 a second.
- A server asks for a 7 MiB receive buffer
  (`ReliableDatagramServerSocket.RECEIVE_BUFFER_SIZE`), as QUIC servers do,
  since every session reads from its one socket, and logs once if the
  system grants less, naming the setting to raise (`net.core.rmem_max` on
  Linux). On Linux at 2,000 clients a 1 MiB buffer dropped 369,000
  datagrams in ten seconds and calls took 6.7 s at p99; with 4 MiB, none
  and 51 ms. A `receiveBufferSize` that is set is kept.
- A session holds an acknowledgement up to `ackDelay` (25 ms) for
  something it sends to carry it, halving a game server's datagrams.
  (Upgrading)
- `maxOutputBufferSize` is 256 KB by default, where it was unbounded.
  (Upgrading)
- `close()` delivers everything sent before it and waits for the peer's
  acknowledgement; `abort()` is the old immediate close. (Upgrading)
- A quiet session sends a keepalive every 15 seconds and closes after 60
  seconds of silence, where it sent none and closed between 75 and 150
  seconds in.
- The wire: a 1.0 CONNECT carries an extension (flag `0x08`, padded to 29
  bytes), and frame type 7, `PATH`, carries join cookies and rebinds. A
  peer on 1.0.0-rc.1 ignores both. (Upgrading)
- An idle session holds about 2.7 KB natively, where it held 14 KB; a
  message allocates nothing natively once a session is under way; and a
  session a server accepts no longer opens a socket of its own.
- In `DATAGRAM` mode a message larger than one frame arrives as one
  message, and `flush()` works there too.
- A `connectTimeout` of 0 is no deadline, where it failed the attempt at
  once.

#### WebSocket

- The process-wide settings are gone: `maxMessageSize` (1 MiB),
  `closeTimeout` (5 s) and `pingInterval` are set per server or session, and
  a frame may be as long as its message, where frames over 64 KiB were
  refused. (Upgrading)
- A `ServerWebSocket` bounds what waits for each session at 8 MiB
  (`maxOutputBufferSize`), closing with 1011 past it. (Upgrading)
- A session pings a peer it has not heard from for 30 seconds and closes
  with 1006 after 60, where a vanished peer was held for good. An accepted
  subprotocol is echoed.
- `closeWith()` and `drain()` carry out the closing handshake, with the code
  and reason in the frame, and wait up to `closeTimeout` for the answer.
- A peer flooding pings is owed one pong, the newest, rather than one each.
- Sessions are read when their socket is readable, so 10,000 idle sessions
  no longer make a hundred thousand system calls a second; what a pass
  sends goes in one write (relaying a chat room: 485 to 107 µs of CPU a
  message natively); and a server receives large messages 45 times faster
  (19 to 650-930 MB/s).
- Natively a message allocates nothing to send or receive but the `text` a
  listener asks for, and an idle session holds less (an accepted one 3.8 KB
  where it held 6.6), letting go of its buffers after a quiet heartbeat.
- Over TLS a session no longer reads past what arrived, a read that failed
  every time: an RPC call over `wss://` allocates nothing natively where it
  took 64 B, and 6.2 KB on the jvm where it took 10.8, and takes 28% less
  time natively and 53% less on the jvm.
- On the jvm, framing and masking a message boxes nothing: a 100-byte
  echo allocates 396 B where it took 428.
- A `wss://` client checks the server's certificate. (Upgrading)
- A client's failed connect ends one way: `ioError`, then `close` with 1006.
  Its `connectTimeout` bounds the whole connect: lookup, TCP, TLS and
  upgrade.
- `ServerWebSocket.verifyCert` is gone, and `certAuthority` asks every
  client for a certificate. `cert` and `certAuthority` take
  `crossbyte.net.Certificate` and `Key`, and are set before `bind()`.
  (Upgrading)
- `WebSocket.shutdown()` throws `IllegalOperationError`: a session has no
  half-close. (Upgrading)

#### HTTP

- Server defaults are safer: no `rootDirectory` serves no files, the
  address is `127.0.0.1`, dot files are refused, `tryFiles` has no
  `/index.html` fallback and `rewrites` is empty. (Upgrading)
- Server limits are on by default: `maxConnections` 10,000 (was 256), 240
  requests a minute per client (was 10), `maxOutputBufferSize` 8 MB (was
  unbounded), `requestTimeout` 60 s, keep-alive, `phpTimeout` 30 s and
  `phpMaxResponseSize` 8 MiB. (Upgrading)
- The server compresses only what is worth it (1 KB or more, a text-like
  type, not an error), sends `Vary: Accept-Encoding`, prefers gzip to
  Brotli at equal preference unless Brotli is native, and treats the
  `deflate` coding as zlib (RFC 9110). Natively gzip and deflate come from
  hxcpp's zlib: 64 KB of JSON compresses in 235 µs to 6.0 KB, where it took
  743 µs and came to 8.3 KB. (Upgrading)
- A request's path is normalised once, before middleware, and files and
  rewrites are resolved only after the middleware lets a request through.
  A malformed escape or an encoded NUL is answered 400, and `+` in a path is
  a plus. (Upgrading)
- CORS no longer grants credentials to every origin, and a preflight is
  answered with the configured methods and headers. (Upgrading)
- Faster serving: a static file is looked up with one system call (79-byte
  file: 345 to 125 µs of CPU), header lines are parsed where they lie, the
  `Date` header is formatted once a second, and the access log is written
  by a thread of its own under the category `http.access`.
- The access log writes each response as four fields, `method`, `path`,
  `status` and `client`: logfmt pairs in text, members of the object in
  JSON, and the record's fields for a `Logger.recordSink`. (Upgrading)
- A kept-alive HTTP/1.1 GET allocates 152 B natively where it allocated
  1,344, and 208 B on the jvm where it took 3,728: the head and a text
  body are written into bytes the thread keeps, which the socket copies,
  rather than into strings and bytes of their own, and the request and
  header lines are read where they lie.
  `HTTPResponseStream.writeText` allocates nothing for ASCII text
  natively, where a line of server-sent events took 584 B.
- An HTTP/2 GET allocates 592 B natively where it allocated 3,400, 424 B on
  the jvm where it took 2,016, and 5.8 KB on Node where it took 10.5 KB,
  and is answered a fifth faster on Node. A stream's handler is kept by its
  connection and given a later stream once its response has ended, as an
  HTTP/1.1 connection keeps its one handler; the response head is encoded a
  field at a time into a buffer the connection keeps; frames are read where
  they lie; and a text body goes out from the thread's buffer, with only
  what flow control holds back copied.
- Large responses: static files over 256 KB stream in 64 KB slices, a
  response larger than the output buffer goes out in bursts as the client
  reads, and a client that stops reading for 30 seconds is let go.
- PHP no longer holds the runtime: the bridge connects off the runtime's
  thread and reads replies as they arrive (a reply waited 49 to 53 ms for
  the next tick, and now 0.5 ms). A script is given every request header as
  `HTTP_*`, the client every response header the script sets.
- `HTTPRequestContext`, `RewriteRule` and `RewriteCondition` are classes,
  and a middleware's `next` takes `?error:Any`. (Upgrading)
- The client reads a response a buffer at a time and keeps connections for
  the next request; a body grows as it arrives rather than being allocated
  from its declared length; loads share a thread pool; and
  `HTTP_RESPONSE_STATUS` is dispatched on every target with the final
  response's headers and URL.
- A redirect to another origin drops `Authorization`,
  `Proxy-Authorization` and a hand-set `Cookie`, and `https` to `http` is
  refused unless `followInsecureRedirects` is set. (Upgrading)
- `URLRequest.readTimeout = 0` is no idle limit natively too. (Upgrading)
- `OAuth.getAccessToken` and `refreshAccessToken` go through `URLLoader`,
  so they no longer block the runtime. (Upgrading)
- The native client's process-wide limits (`Http.MAX_*`) are per-request
  settings on `URLRequest`. (Upgrading)

#### RPC

- A string argument is written straight into the frame: on Node a short
  one in 22 to 45 ns rather than 660 to 910, and 200 characters in 130
  rather than 2,000; on the jvm ASCII is copied in at once, still
  allocating nothing, 200 characters in 93 ns rather than 148. Natively
  one held as UTF-16 is encoded in place: eleven accented characters in
  24 ns rather than 78, and 200 mostly ASCII in 224 rather than 832.
- An RPC session over reliable UDP no longer copies each message that
  arrives: the connection hands a reader that keeps nothing (a session
  reading its frames) the message itself. An RPC call there and its answer
  allocate nothing natively or on the JVM, where they allocated 344 and
  168 bytes.
- A frame larger than its reader takes is refused and read past, and the
  connection goes on: a call past the reader's `maxFrameSize` or past what
  its TCP socket holds (`maxInputBufferSize`), which waited for good there,
  fails `RPCFailure.TooLarge` at once, as does an answer past the caller's
  limit, or past what the answering side's local IPC carries. A call over a
  WebSocket larger than 64 KiB goes as several messages, where one past the
  peer's 1 MiB `maxMessageSize` closed the connection; one over reliable UDP
  past its `maxOutputBufferSize`, or over local IPC past its 8 MiB message,
  fails `Unsent` as it is made, where it ended the session or went nowhere.
  A frame past the reader's `maxFrameSize` ended the connection.
- `RPCSession.onUnreadableFrame` is a property, and the reason it is told
  is made only once it is set: a call for a method the other side has not
  got, refused to a receiver, allocates nothing where it allocated 240 bytes
  natively and 1,208 on the JVM.
- A `NetConnection` wrapping an `INetConnection` of your own stamps
  `outTimestamp` with its runtime's clock as it sends, as CrossByte's own
  transports do, rather than reading the wrapped connection's: on the jvm
  that read was reflection, 24 bytes a send, and an RPC call over such a
  connection now allocates nothing there.
- A compiled call is named on the wire by a hash of its method's signature,
  not its name alone, so two builds with different signatures no longer
  read each other's bytes as their own. (Upgrading)
- A frame a session cannot read is answered or passed over, and the
  connection carries on: an unknown method is answered
  `RPCError.UNKNOWN_METHOD_MESSAGE`, arguments that do not read
  `UNREADABLE_MESSAGE`.
- A handler that throws is answered with an error and the connection
  carries on; anything but an `RPCError` is answered
  `RPCError.INTERNAL_MESSAGE`, so internal details no longer reach the
  caller. (Upgrading)
- Every session answers pings, the heartbeat runs on any session, and a
  heartbeat timeout closes the connection as `Reason.Timeout`. (Upgrading)
- One handler can serve many sessions: each call is answered on the
  connection it came in on, and `RPCHandler.session` names it.
- Faster calls: frames are written into one buffer each session keeps, and
  natively a request and its answer take 133 ns where they took 233, and a
  round trip with a `Future` answer 405 ns where it took 928.
- Lighter requests: an `RPCResponse` takes 128 bytes natively and 80 on the
  JVM, where it took 152 on both, and a request with its answer allocates
  152 and 96 where it allocated 176 on both. Every `Future` is smaller:
  88 bytes natively and 48 on the JVM, where it was 112 and 120, since on
  the JVM it no longer makes a lock of its own.
- A handler's `@:rpc` method is no longer held to eight arguments.

#### Data

- Counts and ids are `Float`s, exact past 2^31: SQLite's, MySQL's,
  Postgres's and MongoDB's. (Upgrading)
- Natively, MySQL and SQLite column values come back exact: large integers
  as `haxe.Int64`, `DECIMAL` as a `String`, dates in UTC. (Upgrading)
- A statement or transaction the server refuses throws an `SQLError` on
  every driver, after the `SQLErrorEvent` it already dispatched. MySQL
  throws `MySQLError` and no longer puts the statement's text in the
  message. (Upgrading)
- Statement parameters are typed (`FieldStruct<SQLValue>`), and each value
  is sent as its type. (Upgrading)
- A native MySQL connection uses TLS whenever the server offers it
  (`sslMode` `PREFERRED`). (Upgrading)
- `SQLiteConnection.lockWaitTimeout` is 5 seconds as a connection opens.
  (Upgrading)
- SQLite statements are prepared once and kept (64 texts): a statement with
  six values runs in 0.8 to 2.2 µs where it took 4.0 to 7.3. Postgres
  results come from the bridge as a binary block rather than JSON, 0.32 to
  0.42 µs a row of 8 columns where it took 2.7 to 3.9.
- A native MySQL statement reads its rows a page at a time, as asked for,
  where a result was read whole first.
- MongoDB and PostgreSQL connections keep TCP keepalive on with MySQL's
  timings (60 s, then every 10 s, 6 probes).
- Inflating goes through zlib natively, on Node and on the jvm (a 437-byte
  message: 27 to 84 µs natively, now about 2), and Node compresses with its
  own zlib and Brotli. `ByteArray.uncompress` throws `IOError` for bad data
  and `RangeError` past its limit. (Upgrading)
- `BCrypt.hash` makes `$2b$` hashes at cost 12 by default. (Upgrading)
- JWT HS256 verification and signing cost about a quarter of what they did.
  JWT times are `Float` seconds, and its data types are classes.
  (Upgrading)
- `JWT.verify` and `verifyToken` are each two functions, with a time and
  without, rather than one taking an optional time, which natively and on
  the jvm was boxed on its way in; without one they read `Sys.time()`
  where they made a `Date`. A verification allocates 24 B less natively
  and on the jvm, and on the jvm 1.7 KB less without a time. A time of NaN,
  by which no token was expired, is refused with an `ArgumentError`.
  (Upgrading)
- Off native cpp, crypto and IPC classes throw `IllegalOperationError`.
  (Upgrading)
- libsodium built by gcc and clang uses 64-bit arithmetic and the CPU's SIMD
  code (X25519 41 to 24 µs, Argon2id at its interactive limits 72 to 45 ms),
  BLAKE3 uses SSE2, SSE4.1 and AVX2 (977 to 3,459 MB/s), and natively
  `SecureRandom` draws small amounts from a per-thread pool.

#### Platform

- A member's name spells an acronym after its first word as a word
  (`writeUtfBytes`, `getJson`, `responseUrl`, `parseUrl`, `setAlpn`), as
  `requestId` and `lastInsertRowId` do; a type's name keeps its capitals
  (`URLRequest`). (Upgrading)
- `File.applicationStorageDirectory`, and every `Store` in it, is the
  application's own directory. (Upgrading)
- `File.applicationDirectory`, `System.appDir` and `Resources` are the
  program's own directory, not the working directory. (Upgrading)
- `File` takes paths literally (no `%NAME%` expansion), and
  `File.resolvePath` normalises and never climbs out of the file system's
  root or the application storage directory. (Upgrading)
- `LocalConnection`, `SharedChannel` and `SharedObject` names are each
  user's own. (Upgrading)
- `LocalConnection` and `SharedChannel` write what a pass sent in one
  write and deliver up to 2 ms of messages a pass, where they delivered 32
  a tick: 4 KB messages went from 20 to 120 MB/s.
- On Windows, a `LocalConnection`'s reader wakes as data arrives rather
  than at its next look, 1 to 10 ms later: the writer rings an event the
  reader waits on, as a Linux or macOS reader waits on its socket. An RPC
  round trip over local IPC takes 0.1 ms (p50) where it took 2.9 (TCP over
  loopback: 0.05), and an idle connection costs nothing more.
- `System` asks the operating system directly rather than starting a
  process, and throws where nothing answers. (Upgrading)
- A native Windows build no longer raises its process to
  `HIGH_PRIORITY_CLASS`. (Upgrading)
- A child process's output is read at most `NativeProcess.MAX_OUTPUT_AHEAD`
  (256 KB) ahead of the runtime.
- The hxcpp fork's `production` branch brings changes an application can
  see. (Upgrading)
- On Node, gzip, deflate and Brotli use Node's zlib, and log records go to
  stdout in one write a turn of the event loop.

### Fixed

Fixes to code new in this release are not listed.

#### Runtime

- A timer handle kept after its timer ended no longer cancels another
  timer that reuses the slot; a runtime numbers its timers and holds at
  most 524,288 at once.
- A NaN delay or interval is refused with an `ArgumentError`, where one
  NaN timer stopped every timer on its runtime.
- A timer whose callback runs a frame of its own and then resumes itself
  is no longer lost; a timer paused or rescheduled from its own callback
  runs at its new time.
- `Timer.fromWallClock` and `toWallClock` no longer put wall times off by
  the runtime's age.
- Timers due at the same time fire in the order they were armed, as
  JavaScript's and ActionScript's do. Three `haxe.Timer.delay`,
  `GlobalTimer.setTimeout` or `Timer.setTimeout` calls with one delay ran
  the first, then the third, then the second. Natively the heap fires a
  timer 15% faster where timers' times differ, and 11% slower where many
  are due at once.
- A `GlobalTimer` timer whose runtime exits is let go. A timeout still
  waiting on a child runtime that exited held its id, and whatever its
  function held, for as long as the process ran.
- `haxe.Timer.delay`, `GlobalTimer.setTimeout` and `setInterval` give a
  timer its function before handing it to a runtime on another thread,
  which could run it once with none first.
- `removeEventListener(type, this.handler)` removes the listener on eval and
  the jvm, where a bound method never compared equal.
- A listener that dispatches its event on to another dispatcher no longer
  changes it under the listeners after it: they see their own dispatcher
  as its `currentTarget`, where they saw the one it was sent on to.
- A `Task` made on a thread with no runtime always calls its handlers, a
  `Worker` cancelled after its work completed ends `CANCELLED`, and a
  throwing task listener no longer stops the others.
- `pump()` on a runtime that has exited no longer claims the calling thread.
- A `Logger.sink` or `recordSink` that throws no longer throws into
  whoever logged, error handlers included: the record goes to standard
  output, after one line saying the sink failed, and the next record is
  offered to the sink again. A sink that logs no longer recurses until the
  stack runs out: a record logged from inside it goes to standard output,
  on that thread only.
- `CrossByte.cpuLoad` counts a `POLL` loop's socket handlers.
- A native host loop that only calls `pump()` reaches a garbage-collection
  safe point, where it stalled every other thread.
- Native debug builds with `hxcpp-debug-server` no longer die before
  `main`.
- On neko, posts to a runtime, a `Task`'s first listener and a cancel are
  no longer occasionally lost.
- Reading an object is bounded: a twelve-byte HXSF array no longer
  allocates 840 MB, a negative length is refused, and an object nested
  thousands deep no longer ends the process. AMF reads only what has
  arrived.
- Bounds checks that could overflow are fixed in `ByteArray`,
  `ByteArrayOutput`, `DatagramSocket.send` and `ReliableDatagramSocket.send`;
  `ByteArrayOutput.writeIntAt` no longer writes past a chunk; and varint
  readers keep their bounds in `-D final` builds.
- Writing past the end of a `ByteArray` zeroes the gap, where it could
  expose earlier contents (on eval too).
- A multi-byte read that cannot be satisfied throws without moving
  `position`, `readDouble` and `readUtf` included (each moved it part of
  the way).
- A `ByteArray` read with the position far past the end is an `EOFError`:
  near 2^31 the check wrapped and passed, and natively the read answered 0
  as if the bytes were there, where eval and the jvm threw errors of their
  own. A write whose end would pass 2^31 - 1 bytes is a `RangeError`,
  refused before any room is made for it, where natively it grew the
  buffer toward 2 GB a byte at a time, and on JavaScript text grew it past
  2 GB first (which a browser refuses with an allocation error of its own).
  A position of 2^31 or more is refused with a `RangeError`.
- `ByteArray`'s `[]` reads 0 outside its bytes, where past `length` it
  read what was there before the array was shortened (natively and on the
  jvm), and a negative index written is a `RangeError`. `bytesAvailable`
  is 0 with the position past the end, not about four billion.
- Writing a string that ends in half of a surrogate pair, either half, no
  longer crashes HashLink (its encoder ran past the end of the string), and
  natively no longer throws "Invalid UTF16": the half is written as U+FFFD,
  as on JavaScript. On HashLink a `ByteArray` writes one inside a string as
  U+FFFD too, where HashLink's encoder took the character after it with it. A malformed UTF-8 sequence reads as U+FFFD on HashLink and
  eval, where HashLink dropped everything from it on and eval kept the
  bytes, which the next operation on the string aborted the process over.
- `ByteArrayInput.readBytes` refuses a destination range that does not fit
  in every build: a large offset wrapped the check, and natively the copy
  went 2 GB past the buffer. Its strings read as `ByteArray`'s do (a NUL is
  a character on JavaScript and HashLink too, and a string ends where its
  length says), are bounded in `final` builds, and one cut short leaves
  `position` alone, as does a `ByteDelta` cut short.
- `ByteArrayInput`'s fixed-size reads no longer go past the buffer in
  `-D final` builds (Lime's release builds define it): their bounds check
  was compiled out, so natively a payload shorter than its fields was read
  past its end. `readByte`, `readShort`, `readInt`, `readFloat`,
  `readDouble`, `readBytes` and the `position` setter are checked in every
  build now, and `ci/final-tests.hxml` runs the readers' tests built that
  way. The check costs a native read loop about 0.2 ns a read (a 19-byte
  record of five fields read in 3.8 ns rather than 2.9 ns), and the jvm's
  about 0.04 ns; an RPC call measured no different on either.
- `ByteArrayOutput` writes strings as `ByteArray` does, refuses a source
  range outside the source before making room for it, and `writeIntAt`
  checks its range in every build without wrapping. What it becomes is
  marked little-endian, as it is written, whatever `defaultEndian` is, and
  `copy()` is available on it.
- `BitWriter.writeQuantized` refuses a range whose span overflows, which
  quantized everything to 0 and could spoil the next field, and the bit
  readers and writers count past 256 MB.
- The varint writers write every 32-bit value (bit 31 set went out as one
  byte), and the readers refuse a value past 32 bits.
- `writeUtf` refuses a string over 65,535 bytes with a `RangeError`, where
  the length wrapped.
- `ByteArrayOutput` grows in every writer, and `reserve` no longer
  reallocates on every call.
- `EOFError` keeps the message it is given, and `Error.getCallStack()`
  returns the error's own stack.
- `ListedMap`, `DenseSet`, `OrderedMap`, `IndexedMap` and `PackedSlotMap`
  can have the entry a loop is on removed.
- A loop over a `DenseSet` allocates nothing natively, where each loop
  allocated its iterator (40 bytes), and looks for a moved element only
  after a removal: over 1,000 elements 730 ns rather than 1,720 natively
  and 2,160 rather than 2,620 on Node.
- Adding, removing and finding an element of a `DenseSet` box no position,
  natively and on the jvm, where a position past 255 natively, or 127 on
  the jvm, was boxed at each: at 1,000 elements a removal and an addition
  allocate 40 bytes rather than 99 natively (the map's own entry) and take
  79 ns rather than 101, and allocate nothing rather than 44 bytes on the
  jvm. `toString()` lists the elements, where it printed their positions.
- A `for` loop over an `OrderedMap`'s values, keys or pairs allocates
  nothing natively or on the jvm, and `for (key => value in map)` walks it
  (`keyValueIterator()`). `iterator()`, `keysIterator()` and
  `keyValuePairs()` answered an `Iterator` structure, through which
  natively every `hasNext` and `next` made a closure: over eight entries a
  loop took 16 ns rather than 144 and allocates nothing rather than 728
  bytes. They answer iterator classes, which fit where an `Iterator` is
  asked for. Natively a lookup boxes no String key, or Int key past 255:
  `get` of a String key 13 ns rather than 18, and nothing rather than 32
  bytes.
- `ExpiringMap.get`, `touch`, `exists`, `set` and `sweep` allocate nothing
  natively on the map's own clock, where each asked it through a closure
  that boxed its answer and boxed a String key, 56 bytes a `get` (39 ns
  where it took 54 at 1,000 entries). `sweep()` and `sweep(now)` are two
  functions rather than one with an optional time, so no time is boxed on
  its way in however it is given, natively or on the jvm (24 bytes a
  sweep given a field or a call's answer). Neither is a value to pass on:
  pass `() -> map.sweep()`.
- `ConcurrencyLimiter` and `Membership` allocate nothing for the time,
  natively or on the jvm. Their default clock is asked without a closure,
  whose answer natively was boxed (24 bytes a call), and
  `ConcurrencyLimiter.sweep`, `Membership.heard` and `Membership.sweep`
  are each two functions, with a time and without, where an optional time
  was boxed on its way in (24 bytes).
- A `ListedMap` boxes no key or index natively, nor an index on the jvm:
  natively a `get` of a String key takes 22 ns rather than 27 at 1,000
  keys and allocates nothing rather than 32 bytes, and a replaced value
  32 ns and nothing rather than 56 ns and 82 bytes; on the jvm a replaced
  value allocates nothing rather than 14 bytes.
- An `IndexedMap` boxes no key or index, natively or on the jvm: at 1,000
  keys a `get` takes 4.0 ns rather than 8.6 natively and 3.1 rather than
  6.4 on the jvm, allocating nothing rather than 18 and 14 bytes, and a
  removal and an addition allocate nothing on the jvm rather than 61
  bytes, and natively only the map's own entry for the key (24 bytes
  rather than 65).
- `RadixTree` finds the child to follow by a binary search through a
  node's children past the first eight, where it passed over them all:
  with a thousand children under one node a lookup takes 23 ns rather
  than 389 natively, 22 rather than 418 on the jvm and 26 rather than 620
  on Node, and with a few no longer.
- Natively a `RadixTree` finds keys holding characters past the Basic
  Multilingual Plane (emoji, the rarer CJK ideographs): two such
  characters sharing the first of their two UTF-16 halves split a label
  between the halves, which natively turned each into U+FFFD, and the
  keys under it were lost. Labels now end only between characters, and a
  node's children are told apart by code point.
- `QuadTree.clear` keeps the quads it takes down, and the next build uses
  them again in the order they were made, so a tree rebuilt each tick
  allocates nothing once it has held as many as a tick needs, where every
  rebuild made them anew: 1,000 points in 7.8 us rather than 13.5
  natively, 11.2 rather than 12.4 on the jvm (61 KB a rebuild before), and
  a third faster on neko. On JavaScript, where a new quad measured the
  cheaper, it is made anew as before.
- `BitmapData.fromByteArray` and `toByteArray` say what they read and
  write: `fromByteArray` reads from the start of the ByteArray, whatever
  its position, and leaves the position after the last pixel. `Deque` says
  what a number costs a push natively and on the jvm, which its
  documentation had only in part.
- `Stack` and `ObjectPool` refuse a negative size with an `ArgumentError`,
  where the interpreter ended the process, the jvm ignored it and
  JavaScript threw its own `RangeError`.
- `BitSet` refuses a bit past `MAX_INDEX` with a `RangeError`, where
  growing to it overflowed: a segfault on the interpreter, a write past the
  set on the jvm, and every bit lost on JavaScript. A negative size is
  refused, and clearing a bit past the end no longer grows the set.
- A `PriorityQueue` whose comparator throws stays whole, every element held
  once, where it held one twice and lost another. A `null` element is
  refused.
- `IntPriorityQueue.clear()` gives back the room a spike took, where every
  later clear cost what clearing the spike did.
- `BloomFilter` hashes a string as its UTF-8 bytes on every target, where a
  string past ASCII set different bits on each, and refuses a byte range
  outside its bytes.
- A `SlotHandle` with the sign bit set, `SlotHandle.INVALID` among them,
  reaches no entry of a `SlotMap` or `PackedSlotMap`, where it read, set or
  removed the live entry its low bits named.
- `SlotMap.clear()` and `PackedSlotMap.clear()` put the slots they free
  behind those already free, so a slot cleared and filled each tick no
  longer comes round to an old handle's generation after 2048 ticks;
  `PackedSlotMap.clear()` costs what it holds rather than its capacity.
- `PackedSlotMap.slotAtDense` refuses an index outside its entries with a
  `RangeError`, a `SlotMap` with a `growthChunk` near 2^31 still grows, and
  on the jvm a `PackedSlotMap` insert and remove no longer allocate 64 bytes
  between them.
- `BitmapData`: `fillRect`, `copyPixels` and `threshold` clip to the
  bitmaps, as Flash's do, where they threw part way through; a copy within
  one bitmap whose regions overlap moves the region whole, where it smeared;
  a negative size, or one of more pixels than an `Int` counts, is refused;
  and a pixel of no alpha holds no colour however it is set.
- `WeightedGraph` refuses NaN as a node, which equals nothing and added
  another node at every use.
- `SpatialGrid`, `SpatialGrid3D` and `InterestSet` refuse an id past
  `MAX_ID` (16,777,215) with an `ArgumentError`. Their arrays grew to fit
  the largest id, which at the largest `Int` wrapped: a segfault on the
  interpreter, an index out of bounds on the jvm, and on Node arrays of
  2^31 entries until the heap ran out. Bounds smaller than one cell still
  make a grid of one.
- A loop over an `InterestSet` skips an id its body forgets, where it
  returned it next, and ends at a `commit` or `clear` in its body, as
  documented, where it carried on into the new view.
- `QuadTree.query` and `queryCircle` find a point in the sliver past a
  quad's rounded far edge, where it was filed but never found; a circle
  about a NaN centre answers at once; a capacity below 1 is an
  `ArgumentError`.
- `Array2D.get` and `set` refuse a cell outside the grid with a
  `RangeError`, where the same read gave null, 0 or undefined by target and
  a write past a row's end grew that row alone.
- `ObjectRecycler` refuses an object it already holds on every build,
  where a release build kept it twice and handed it to the next two
  callers at once; `recycle` answers whether it took the object. A
  recycled object is reset once, where `drain` reset it again.
- `Version`'s `!=` agrees with `==` (`"1.2" != new Version(1, 2, 0)` was
  true), and `==` and `!=` take `null`, where comparing one threw.
- `Random.chooseWeighted` refuses a weight that is infinite or not a
  number, where it returned the last item every time; `float` stays below
  its maximum, which rounding reached where the range is small beside its
  ends; `fillBytes` refuses a range outside the bytes with a `RangeError`;
  and `randomString` draws an alphabet past ASCII a character at a time,
  where it drew halves of a character (UTF-16) or bytes of one (neko).
- `EnumUtil.getValue` answers a copy on eval and neko, where changing it
  changed the enum value.
- `PriorityQueue` serves equal priorities first come, first served.
- `QuadTree.insert` never refuses a point inside its bounds, and stops
  subdividing 32 levels down.
- `Array2D.clear()` empties the grid for every reference to it, and
  `BitmapData.threshold` works.
- `WeightedGraph` finds nodes by hashing, `RadixTree` lookups allocate
  nothing, and `BloomFilter` sets the same bits on every target.
- `Random.int` draws from all of a range wider than 2^31 values, the
  unseeded start no longer repeats between runs on the jvm, hl and neko,
  and a seed gives the same sequence on JavaScript as elsewhere.
- `crossbyte.utils.Hash` gives the same answers on JavaScript as elsewhere,
  as does `MathUtil.nextPow2` above 2^30.
- `Seq32` wraps at 32 bits on JavaScript and prints as unsigned on the jvm.
- `Seq32` comparisons wrap as its arithmetic does, so on a target whose
  `Int` does not (Python, PHP, Lua) a sequence behind another by less than
  half the range no longer reads as ahead of it.
- `PrimitiveValue.toInt`, `Version` and every number a peer sends are read
  the same way on every target, through `IntParse`.
- `PrimitiveValue.toFloat` reads text the same way on every target, where
  `"0x10"` was 16 natively and on neko and 0 elsewhere, and `"Infinity"`
  NaN on eval and the jvm; and on eval and neko an `Int` it gives adds past
  2^31 without wrapping. (Upgrading)
- A `FieldStruct` is walked by `for (name => value in fields)`, as its
  documentation said, where the loop did not compile. So are an `Object`,
  where the loop compiled and threw on every target as it began, and a
  `TypedObject`.
- An `Object` holding an `Array`, a `String`, a number, a `Bool` or a
  function has no fields on any target: its `keys()`, `values()`,
  `entries()` and loops are empty, where each target listed its own
  internals (an `Array`'s `length` and `__a` on the jvm, its indices on
  Node, `array` and `allowReinterpret` on HashLink; a `String`'s `value`
  and `hash` on the jvm and its characters on Node). On Node they read
  through `Object.keys`, so `keys()` takes 7% less time, `values()` 8%
  and `entries()` 13%. (Upgrading)
- A null name no longer ends the process natively: `Object.get` reads
  null, `exists` and `remove` answer false and `set` throws an
  `ArgumentError`, on every target (but `get` on JavaScript, where a null
  name is a `TypeError`), and `TypedObject`'s the same. On Node
  `exists(null)` found, and `remove(null)` deleted, a field named
  `"null"`.
- `PrimitiveValue.isInt`, `isFloat` and `getValueType` take a whole
  `Float` within `Int`'s range (`1.0`) as an `Int` on every target, as
  JavaScript, the jvm and native did, where eval and neko called it a
  `Float`.
- A null `Object` or `TypedObject` answers as an empty one on every
  target, where `exists` threw on the jvm and Node, `keys`, `values` and
  `entries` on the jvm, and `remove` on Node and neko.
- On JavaScript, `Object` and `TypedObject` read `__proto__` and
  `constructor` as the object's own fields, and set `__proto__` as one, as
  every other target does. `get("__proto__")` read the prototype every
  plain object shares, so a path of names a peer chose, walked with `get`
  and ended with `set`, gave every object in the process that field.
- `GlobalTimer` hands out unique ids on every threaded target.
- On the jvm, `PriorityQueue` and `Vector`'s `every`, `some` and `filter`
  work.
- `Vector`: a negative length is refused with a `RangeError`, where the
  interpreter ended the process and the jvm dropped elements; `splice` with
  a negative start puts its items where the removal began; `removeAt`
  counts a negative index back from the end, as ActionScript's does, and
  refuses one outside the vector rather than answering `null` past the end
  or taking the first element; a callback that shortens the vector is no
  longer handed elements past its end; and on the jvm a method reached
  through `Reflect` is called with the arguments it takes.
- A `Map<Int, T>` miss on the jvm costs what a hit does (a Haxe 4.3.7
  `IntMap` fault).

#### TCP

- A peer's data that arrives with its FIN is delivered before `CLOSE`,
  where reading it in the listener killed the runtime loop.
- A socket closed while a write was blocked no longer stops the runtime
  loop, and a socket that blocked twice in a row no longer strands what it
  held.
- A client connect that completes at once no longer reports a healthy
  connection as failed, and a connection is announced closed once.
- A refused connect is reported at once as an `ioError` ("Connection
  refused") on every system, where Windows waited out the timeout and
  Linux and macOS announced a connect and then a close.
- A client that connects and resets before it is accepted no longer ends a
  native server on Linux.
- `bind`, `connect`, `send` and `close` failures say what failed, and a
  `bind` that fails is reported rather than taken for a success.
- `ServerSocket.listen()` on a server never bound is an `IOError` on every
  target. (Upgrading)
- A server out of descriptors reports it once and keeps listening, where
  the jvm closed the server and native code said nothing.
- Writing before a connect has finished is no longer an error natively,
  and `Socket.close()` sends what was written first.
- A closed connection is let go of, where the socket registry kept it
  reachable, with its buffers and `userData`.
- `localAddress`, `remoteAddress` and their ports read null and 0 when a
  socket has no such end, where they threw.
- A `Socket` built with port 65535 works, and `writeBytes` and the
  constructor refuse arguments out of range. (Upgrading)
- On Windows a client turns Nagle's algorithm off before it connects, where
  it stayed on.
- On Linux and macOS, accepted sockets are close-on-exec, so a child process
  no longer inherits a client's connection; on Windows the fork's sockets
  are not inheritable.
- A native connection reset read a byte at a time is a failure, not the
  end of the stream.
- Natively, a TLS connection accepted before its listener closed no longer
  reads freed memory, and `alpnProtocol` still names what was agreed.
- On neko and HashLink too, a TLS connection keeps working after its server
  closes, as a draining server's do: its next read failed, and on neko 2.3
  on Windows one still in its handshake crashed the process. Each accepted
  connection there has a TLS configuration of its own.
- On Linux and macOS a process with more than about a thousand descriptors
  can still connect and accept.
- Socket errors on eval can be caught, where a reset or a port in use ended
  the interpreter.
- On neko a runtime services more than 64 sockets, and a `ServerSocket`
  can listen.
- On the jvm, a refused connect is reported as refused, the listen backlog
  is the system's maximum rather than 50, `sys.net.Socket.setTimeout` works,
  addresses are reported compressed (`::1`), and repeated selects no longer
  exhaust the machine's ephemeral ports.
- On the interpreter a second `close()` does nothing, and `readByte` at
  the end of a connection throws `Eof`.
- `NetConnection.close()` on a connection that has already ended does
  nothing, and a `NetConnection`'s timestamps come from its own runtime.
- A `NetConnection` over TCP, WebSocket or reliable UDP reads `connected` as
  `false` inside its `onClose`, in a page as natively, where one that closed
  itself still read `true` there.
- A URL port too large for an `Int` is refused the same way on every target.
- IPv6 addresses are written in RFC 5952 form on every target.
- On the jvm, a TLS client no longer takes a certificate past its
  validity period because it was pinned as its own authority (a
  self-signed `certAuthority`): PKIX checks no trust anchor's dates. Every
  certificate a peer presents is held to its dates, as natively and on
  Node, and a server checks a client's the same way.
- On Node, `close()` on a `ServerSocket` that never listened no longer
  throws.
- On the interpreter a plain TCP send no longer waits for the peer to read:
  what the system has no room for waits in the socket's buffer, where
  `maxOutputBufferSize`, the high and low water marks and
  `RPCSession.maxOutputPending` see it, as on the other targets. A slow
  peer held up the whole runtime, and a client and server in one
  interpreter could wait on each other for good.

#### UDP

- One failed send, or one ICMP "port unreachable" report on Windows, no
  longer stops a `DatagramSocket` receiving for good. Anyone could deafen a
  reliable UDP server on Windows this way.
- A connected `DatagramSocket` sends on macOS and the BSDs.
- On Linux, two datagram sockets are no longer given the same port (the
  hxcpp fork sets `SO_REUSEADDR` on stream sockets only), and on neko and
  hl a bound port is checked.
- `DatagramSocket.isSupported` answers truthfully on neko, where UDP works
  again.

#### Reliable UDP

- `close()` delivers what was sent before it: a FIN overtook lost frames,
  and a client writing 300 messages and closing had 10 of them heard.
- A session connects when the last message of its handshake is lost, where
  one connection in ten failed at 10% loss; a repeated HANDSHAKE no longer
  skips frames on their way.
- A peer that crashes and returns on the same address gets back in within
  about three seconds, a server's `close()` tells its peers, and a peer
  with no session is told at once.
- A spoofed CONNECT no longer makes the server retransmit at the address it
  names, and half-open sessions are bounded (`maxPendingConnections`).
- A session is no longer closed when its socket's send buffer is
  momentarily full.
- A `NetConnection` over reliable UDP reports deadlines as `Reason.Timeout`.
- A reliable UDP server out of processor time slows its tick, as one over
  TCP does, where it let what arrived wait in the system's buffer: its socket
  read 1,024 datagrams a pass for all its sessions, so the rest were read a
  frame later behind everything since. It now reads eight a session (1,024
  at the least). Natively, one runtime at 60 ticks a second and 1,000 game
  clients each sending three calls a tick: a call's round trip 21 ms (p50)
  and 39 ms (p99) where it was 350 ms and 2.5 s; on the jvm 20 and 37 where
  it was 342 ms and 2.6 s.
- A `NetConnection` over a reliable UDP session in `STREAM` mode hands
  `onData` the stream's own input, as one over TCP does, so what a reader
  leaves unread is there at the next arrival. Each arrival was handed over
  in a buffer of its own, and the unread part went with it: an RPC call
  larger than a datagram ended the connection as one whose framing was lost.
- Closing a session from its own `DATA` handler no longer reports an error.
- On neko, hl and the interpreter a session's clock never runs backwards.

#### WebSocket

- In a browser `NetConnection` takes `ws://` and `wss://`, so a page reaches
  an RPC server at the URI it listens on; both threw "Protocol error".
- A server receives a client's first message: the handshake's bytes stayed
  in the buffer and every session closed with 1002.
- The last message before a disconnect is delivered, and a full send buffer
  no longer drops bytes or closes the session with 1006.
- A TLS handshake that failed is no longer taken for a successful one, and
  a session whose handshake fails or times out closes its socket.
- `handshakeTimeout` closes stalled upgrades, TLS included, and
  `stopAccepting()`, `drain()` and `close()` let go of sessions still
  upgrading.
- An upgrade request is read to 16 KiB at most, where one endless header
  could hold hundreds of megabytes; a frame header claiming a huge payload
  is refused on its header.
- Close codes are checked against RFC 6455's ranges.
- `ServerWebSocket.bind(0)` reports the port it got, a secure server's
  sessions say they are `secure`, and `pendingHandshakeCount()` and
  `handshakeFailures` count.
- `ServerWebSocket` takes the TLS methods it inherits (`setCertificate`,
  `addSniCertificate`, `setAlpn`, `requireClientCertificate`), which
  crashed natively.
- `ServerWebSocket.listen()` on a server never bound throws an `IOError`,
  and a server survives accepts the system refuses.
- `writeBytes` and `sendBinary` refuse a range outside the bytes given;
  `socketData`'s `bytesLoaded` counts the message that arrived; and the
  output limit honours `outputOverflowPolicy`.
- A server accepts sessions on eval, hl and neko, and a jvm server no
  longer stops the runtime while idle.
- A client dials IPv6 literals; a normal disconnect no longer prints
  through `trace`.

#### HTTP

- Request smuggling: a `Content-Length` too large for an `Int`, an
  obs-fold header line, whitespace before a colon or a line with no colon
  is refused with 400, and a chunk size is bounded before it is parsed.
- A limit set near the largest `Int` holds: the server's
  `maxRequestBodySize` against a chunk size, its output cap against a
  response or a streamed write, and the client's `maxBodySize`, where what
  was held and what arrived added past 2^31, wrapped and fitted.
- A URL can no longer add a header or a request: control characters are
  refused and the request target, `Host` and other headers are sanitised.
- A request path can no longer forge a field in the access log. Its
  decoded text went into the line unquoted, so `GET /a%20status=500`
  answered 404 read to a logfmt collector as a status of 500. The path is
  now a field, quoted when it holds a space, a quote or an equals sign.
- A percent-encoded NUL in a path no longer slips past `blacklist`; with PHP
  off, `.php` source is no longer served as a static file; and on Windows a
  path naming an environment variable no longer reaches a file outside the
  root.
- `blacklist` and `whitelist` hold for every method and for rewrites, where
  a blacklisted script ran for a `POST`.
- A rewrite's `$1` to `$9` are expanded in one pass, so a request cannot
  rewrite the target; rules are compiled once; a `POST` follows rewrites;
  `Header` conditions match in any case; and `$uri` works in later
  `tryFiles` entries.
- A request body is bounded as it is decoded (413), and more than two
  codings are refused (415).
- Pipelined requests are answered in order, and requests behind one being
  answered no longer turn its answer into a 413.
- A response too large for the output buffer is sent whole, where a 12 MB
  `respond()` went out cut short and logged as a 200.
- A request carried on from a later tick is answered 500 when it throws,
  and a response whose head has gone is never answered twice.
- Error answers to `HEAD` carry no body; 1xx, 204 and 304 carry no
  `Content-Length`; `405` reads "Method Not Allowed"; and
  `errorDocument` is used.
- A precompressed `.gz` is sent to a client that also takes Brotli, and gzip
  no longer names a file `data`.
- A conditional request dated after 2038 is answered 304.
- The client honours its idle timeout (the default 30 s waited over eight
  hours), holds a response's header section to 64 KB, refuses a
  `Content-Length` past its limit before allocating, and bounds
  decompression while it decodes.
- A request body over 16 KB reaches the server whole over `https`, where
  the rest of the first TLS record was dropped.
- Cancelling a load ends it at once on every target, and `URLLoader.close()`
  mid-request no longer crashes a native build.
- A `COMPLETE` or `IO_ERROR` listener can start the loader's next load; a
  `URLVariables` is sent as a form on every target; a HEAD stays a HEAD
  through a redirect; and a failed connect says why.
- Cookies across a redirect match their host in any case and are kept per
  host; IPv6 hosts keep their brackets.
- On the jvm, each load no longer leaves two sockets open.
- The PHP bridge sends request bodies over 64 KB whole, passes binary
  responses through untouched, keeps every cookie a script sets, answers a
  backend that never replies with 504, and names a failing backend.
- `OAuth.getAuthorizationUrl` keeps a query the endpoint carries, and a
  rejected token exchange reaches an `onError` callback.
- `HTTPBackendRegistry` is thread-safe, and the server logs the port it
  bound.

#### RPC

- A contract may name a method `input` or `requestId`, and an argument
  `requestId` or `framed`: the build failed ("ByteArrayInput cannot be
  called", a duplicate argument, or the frame written as the argument).
- The first `RPCSession.sessionId` is 1 on every target, so 0 is never a
  session: natively and on the jvm it was 0, the counter there answering
  its value from before the add.
- `onHandlerError`'s default report says a handler that ran out of time
  (its `answerTimeout`, or a call it forwarded) did not answer in time,
  where it said the handler threw.
- A frame that names a count or length larger than itself is refused before
  anything is allocated, and a frame too short for what it carries no longer
  reads into the next frame.
- A call fails when its connection closes or cannot carry it, where it
  waited for good; its `cause` is the connection's `Reason`.
- A `pingInterval` of zero or less is no heartbeat. It sent one ping
  and then stopped for good, so a peer that vanished was held, and a debug
  build threw from `start()`.
- An `idleTimeout` of zero or less never times the peer out, and the
  pings go on. It closed the connection at the first beat.
- The heartbeat no longer closes healthy connections: pings were never
  answered.
- A method returning `Null<T>` answers correctly, where the first answer that
  was not null closed the connection.
- A call to a session with no handler is answered rather than left
  waiting, and a frame over `maxFrameSize` is refused before it is sent.
- A session on a listening `LocalConnection` answers every client, not only
  the first.
- On the JVM a handler of more than about twenty methods, or commands of
  more than about sixty requests, builds and loads: its generated dispatch
  or reader passed the 32 KB of bytecode the JVM backend can branch across,
  failing the build (`IO.Overflow`) or the class at load (`VerifyError`).
  Then past about 160 methods, the method through which the JVM backend
  reaches a class's fields did the same: a commands class or handler now
  loads with some 300 methods (the generated helpers are static or inlined
  away), and one past what the JVM can load fails the build, saying how to
  split its contract.
- Natively, a handler of some 300 methods ended the process at its first
  call: every method's decoder was inlined into its dispatch, whose frame
  grew past the stack. Past 32 methods each is a call of its own, which is
  also quicker there (a one-way call to a handler of 70 methods 58-68 ns,
  where it took 70-83).
- `RPCResponse.respond()` replaces the responder, as documented.
  (Upgrading)
- A contract extending another carries the parent's methods; a handler
  extending another builds; types named through an import alias or private
  typedef in another module build; and two methods whose ops collide fail
  the build.

#### Data

- MySQL, from the hxcpp fork: statements with non-ASCII text are no longer
  cut short (an `UPDATE` changed the wrong row); a write is no longer
  reported as failed after it ran; escaping follows
  `NO_BACKSLASH_ESCAPES` when it changes; one hostile packet no longer ends
  the process; MySQL 8's default collation works; and `FLOAT` reads the
  same in any locale.
- MySQL: `timeZone` and `sqlMode` work, savepoints can be referred to
  again, `isolationLevel` reads on older servers, and a statement given its
  connection before `open()` runs.
- Postgres: connections no longer share one result buffer, which could hand
  a query another query's rows; queries no longer stall garbage collection;
  `autocommit = false` takes effect (Upgrading); `ping()` asks the server;
  `inTransaction` follows SQL text; libpq loads on macOS; `escape` no longer
  doubles backslashes; and a malformed result block no longer crashes the
  process.
- SQLite: an asynchronous connection survives a failure and gives each
  statement every row; a synchronous or asynchronous `cancel()` stops the
  statement and keeps the connection; `deanalyze()` removes statistics
  rather than reopening the database; `autoCompact` shrinks the file;
  `SQLiteMode.READ` cannot write (Upgrading); a failed statement no longer
  fails the next; and rowids past 2^31 read back whole.
- SQLite on PHP runs a statement that returns no rows once, where it ran
  every one twice. PHP's `SQLite3Result`, read for a statement with no
  result columns, runs it again, and a statement read its result to count
  the rows it changed: an INSERT inserted twice and a BEGIN failed with
  "cannot start a transaction within a transaction". Such a result is now
  answered from SQLite's `changes()` and never read.
  `SQLiteConnection.isSupported` is true on PHP, and `docs/data.md` says
  what SQLite does there.
- An SQLite connection opening a file another connection is writing waits
  for it, up to `lockWaitTimeout` (5 s), as its statements do once open.
  The open's own pragmas ran before that wait was set, and failed at once
  with "database is locked": a pool's connections opening together on one
  file did.
- `JournalMode.fromString` throws an `ArgumentError` for a name it does not
  know, as the other modes' `fromString` do, where it read it as `DELETE`:
  a misspelt journal mode in a configuration file turned the journal mode
  it named into SQLite's default without a word. (Upgrading)
- A transaction begun as SQL text, or by turning autocommit off, is seen by
  `inTransaction`, so a pool can roll it back.
- A failed COMMIT is no longer reported as committed.
- A null parameter is written as `NULL`, and `:name` is not substituted
  inside comments, quoted identifiers, dollar-quoted strings or `E''`
  strings.
- Every statement honours `itemClass`, and results paged ahead come back in
  order with only the last marked complete.
- On the jvm, MySQL and SQLite failures arrive as `SQLError` or `IOError`,
  not a `ClassCastException`; on hl, a MySQL open that cannot connect no
  longer corrupts the heap.
- deflate, gzip and LZ4 compress, where all three wrote stored blocks larger
  than their input.
- Brotli: a four-byte stream no longer hangs the decoder, a truncated
  stream no longer crashes it, first use from several threads is safe,
  decoding takes memory in proportion to its output, compression costs in
  proportion to its input, and hl's output is correct.
- gzip reads every RFC 1952 header and several members; an LZ4 block cut
  short is refused; LZ4 decodes in a browser; and the native Brotli and LZ4
  backends stop at `maxOutputSize`.
- BCrypt adds the key's terminating NUL, so its hashes verify elsewhere and
  others verify here; hashes made before still verify. A cost of 31 runs.
- `BCrypt` on PHP answers what every other target answers. It wrote new
  hashes as `$2y$`, which `needsRehash` on any other target flags, and
  asked PHP whether a hash needed rehashing, so it never flagged `$2y$`;
  hashes stored by earlier versions natively did not verify there; and the
  Haxe implementation's arithmetic overflowed PHP's integers. New hashes on
  PHP are written `$2b$` (the same algorithm), `needsRehash` is the same
  everywhere, earlier versions' hashes verify, and the vectors pass.
- JWT times past 2038 are judged the same on every target; `verifyToken`
  accepts any `typ` in `acceptedTypes` (`JWT` and `at+jwt`) and none;
  `secureCompare` answers `false` for a null; a header with `crit` is
  refused; and a deeply nested token no longer ends the process.
- A null name no longer ends the process natively in `JWTPayload`:
  `claim` reads null, `hasClaim` answers false and `setClaim` throws an
  `ArgumentError`, on every target, where on Node `setClaim` set a claim
  named `"null"`.
- BCrypt on a worker thread no longer stalls garbage collection, and
  `SecureRandom` initialises safely from two threads.

#### Platform

- `File`: `copyTo` and `moveTo` refuse to copy a file onto itself, which
  emptied it; `moveTo` renames within a volume; `cancel()` cancels;
  `canonicalize()` follows links; `size` and the dates are read when asked
  for; `creationDate` is the file's birth time; `file:` URLs are read;
  `spaceAvailable`, `isHidden` and the user directories answer correctly;
  `openWithDefaultApplication()` works; `clone()` copies no listeners;
  `deleteDirectory` on a missing path no longer crashes natively; paths
  like `/root` work; and failures are `IOError`s that say what failed.
- `File.createTempFile` and `createTempDirectory` use unguessable names and
  create exclusively, so another user cannot steer them.
- `Resources` reads only inside `resourcesDir`. (Upgrading)
- `Resources.tree` has a field for every resource: a character a name
  cannot hold becomes `_` (`level-1.json` is `level_1_json`), and a leading
  digit or a keyword gets a `_`, where a resource named `level-1.json`,
  `1.png` or `class` failed the program's build.
- On Windows, `Resources` refuses a name Windows opens as a device (`con`,
  `nul`, `COM1`, `con.txt`, `CONIN$`) in any directory, where reading
  `maps/con.txt` waited on the console for good on the jvm and the
  interpreter, and `exists` answered true for `nul` natively and on neko.
  (Upgrading)
- `FileStream`: reads and writes keep the `IDataInput` contract in both
  modes, `endian` and `position` mean the same opened either way,
  `truncate()` truncates in place, `UPDATE` mode reads back on macOS, an
  asynchronous read hands out only what it has read, and `readObject` reads
  one object. A short `readBytes` throws `EOFError`. (Upgrading)
- `FileStream.readBytes` refuses an offset and length that reach past the
  largest `ByteArray` with a `RangeError`, leaving the destination as it
  was, where an offset near 2^32 wrapped the sum: the read went to a
  negative position, which ended the process on the interpreter.
- Platform checks made at run time ask the machine: `System.PLATFORM`,
  `File.separator` and the storage directory were wrong on eval, the jvm
  and Node running on Windows.
- `System.totalCpuUsage()`, `getDeviceId()`, `processorCount` on macOS and
  `memoryUsage()` past 2 GiB answer correctly.
- On eval and neko, counts past 2^31 no longer wrap negative: a client
  socket's `OutputProgressEvent.bytesTotal`, a `Counter` after `reset()`, a
  `Gauge` after `set()`, a total of `MongoConnection.count()` answers, and
  the HTTP/2 server's request-body budget with tens of thousands of
  concurrent streams.
- `SharedObject` opens on macOS, reads a region whole under one lock, and
  no longer replaces `data` with `{}` on a race.
- `LocalConnection`: a peer that stops reading no longer stalls this side,
  large frames move quickly through small buffers, a second `listen()` on
  a name in use throws, reconnecting no longer runs two readers, `onReady`
  comes after `connect()` returns, a listener no longer stops delivering,
  and SIGPIPE no longer ends the process.
- `NativeProcess` no longer crashes its parent when a child ends, keeps
  UTF-8 split across reads whole, reports `EXIT` after `exit()` on the jvm,
  and its `pid` is the child's.
- On Windows a `Date` before 1970 no longer ends the process (hxcpp fork).
- A process whose threads end as it exits no longer hangs on Windows or
  crashes in debug builds (hxcpp fork).
- HashLink and Neko compile and run again, sockets included; hl TLS reads
  no longer stop every other thread; and neko's temporary files work.
- On HashLink a socket read or write, or a datagram's, whose position and
  length add past 2^31 is refused, where the sum wrapped, passed the check
  and reached outside the buffer.
- Native builds on Linux and macOS compile cleanly, and `-D final` builds
  compile.
- No `trace` calls remain in library code.
- Hash and Random gave different numbers on PHP: 64-bit integers did not
  wrap where 32-bit ones do.
- `ByteArray` on PHP reads and writes what every other target does: a big-endian `readInt`, `readUnsignedInt` or
  `readFloat` (and so an object's length) came back with bits past 32 set,
  `readVarUInt` read a value from 2^31 up as the unsigned number it holds
  (-1 as 4294967295), and `writeVarUInt`, and `ByteArrayOutput`'s
  `writeVarUInt` and `writeVarInt`, of an `Int` past 32 bits
  (`0x7FFFFFFF + 1` there) wrote a fifth byte no reader takes. Text read
  from a `ByteArray`
  reads a malformed UTF-8 sequence as U+FFFD, as on JavaScript, where it
  kept the bytes as they were, which Haxe's string operations there then
  misread or threw over. Reading a JSON object no longer takes time that
  grows with the square of its text (15 seconds for 229 KB). `FileStream`
  builds for PHP, which has no threads, so as on
  Node a file opens asynchronously only to read; and its big-endian
  `readInt`, `readUnsignedInt`, `readFloat` and `readDouble` (and so an
  object's length) read what was written.
- RPC on PHP sends and reads what every other target does. `crossbyte.rpc`
  did not compile there; an `Int8` or `Int16` came back unsigned; a
  negative `VarUInt` or `RPCError` id arrived as the unsigned number it
  holds (-1 as 4294967295); request ids did not wrap past 2^31 - 1; a patch
  whose structure's 32nd field changed hung counting its changes; and a map
  patch key past 2^31 - 1 was taken. PHP has no sockets in CrossByte, and
  `DatagramSocket.isSupported` and `ServerSocket.isSupported` now say so;
  `docs/targets.md` says what RPC does there.

### Upgrading from 1.0.0-rc.1

Each of these can need code changed; each says how. Behaviour that only
an API added in this release has is not listed here.

#### Building

- Native builds need the `production` branch of the `dimensionscape/hxcpp`
  fork, which has the socket, TLS and crypto support CrossByte builds on:
  `haxelib git hxcpp https://github.com/dimensionscape/hxcpp.git production`.
- That fork changes what an application can see natively: `Std.string` of
  a `Float` prints the shortest text that reads back as the same number
  (`0.1 + 0.2` is `0.30000000000000004`), spells `NaN`, `Infinity` and
  `-Infinity` so, writes exponents without leading zeros (`1e-7`), and
  neither printing nor `parseFloat` follows the process locale. TLS is 1.2
  at least, and one TLS read or write moves at most 16 KB, so use the count
  it returns. `sys.net.Socket`'s `listen`, `setBlocking` and `setTimeout`
  throw when the system call fails, `setTimeout` refuses a negative or NaN
  value, `shutdown` throws for any failure but "not connected", and
  `select` refuses a closed socket (and, on Linux and macOS, a descriptor
  past `FD_SETSIZE`). `Std.parseInt` saturates a decimal outside the `Int`
  range. An exception escaping a thread ends that thread, printed as
  `Uncaught exception in thread: ...`, rather than the process. Maps
  iterate in a different order. `Math.floor`, `round` and `ceil` of `NaN`
  are 0. A child process killed by a signal exits with 128 plus the
  signal. Strings of eight characters or more are four bytes larger. On
  Windows, `Sys.println` to a redirected stdout no longer flushes each line.
- With the fork on mbedTLS 3.6.7, a MySQL server that offers TLS only at
  1.0 or 1.1 no longer connects, and native code of your own that calls
  mbedTLS through hxcpp's headers meets its 3.x API.
- A static Lime build (iOS and tvOS always, `-static` elsewhere) compiles
  Lime's curl against hxcpp's mbedTLS, so with the fork on 3.6.7 rebuild
  Lime against it (`lime rebuild <target> -static`); a library built
  against 2.28 does not fit. Lime 8.4.0's curl 7.87 then fails every HTTPS
  request with "ssl_init failed" until it sets its RNG before
  `mbedtls_ssl_setup`, which mbedTLS 3 requires: a two-line move in
  `project/lib/curl/lib/vtls/mbedtls.c`. A dynamic build, whose ndll
  carries its own mbedTLS, is unaffected.
- A build with `-D crossbyte_brotli_native` or `-D crossbyte_lz4_native`
  needs the current `crossbyte-brotli` or `crossbyte-lz4`, whose
  `decompress` takes the output limit.
- A jvm build that adds CrossByte with `-cp` rather than `-lib crossbyte`
  adds `--macro crossbyte._internal.macro.StdOverrides.use()` before any
  other macro, as `extraParams.hxml` does for `-lib`.
- CrossByte depends on the `emitter` haxelib, 2.0.0, which haxelib installs
  with it; a build that adds CrossByte with `-cp` adds `-lib emitter`.
- Natively on Linux and macOS a process raises its soft limit on open
  descriptors to its hard limit as it starts, and the children it starts
  inherit that: build with `-D crossbyte_keep_nofile` to keep the limit it
  was started with, for children that `select()` on descriptors under
  1,024.
- A native Windows build runs at the priority it was started with; set
  `CrossByte.windowsHighPriority = true` for the high class it took itself.

#### Durations

Every duration is a `Float` of seconds. Each member that took milliseconds
has a new name, so code written against the old one stops compiling rather
than waiting a thousand times as long: divide the old value by 1,000.

| rc.1, in milliseconds | 1.0, in seconds |
| --- | --- |
| `Socket.timeout` (and so `WebSocket.timeout`), 20000 | `connectTimeout`, 20 |
| `URLRequest.idleTimeout`, 30000 | `readTimeout`, 30 |
| `URLRequestDefaults.idleTimeout`, 0 (unset) | `readTimeout`, 0 (unset) |
| `HTTPRequestContext.timeout`, as the request's | `readTimeout`, as the request's |
| `GlobalTimer.setTimeout(closure, delay)` | `setTimeout(delay, closure)`, the delay first |
| `GlobalTimer.setInterval(closure, delay)` | `setInterval(interval, closure)`, the interval first |
| `SQLiteConnection.busyTimeout`, 5000 as it opens | `lockWaitTimeout`, 5 |
| `RPCSession.heartbeatInterval`, 45000 | `pingInterval`, 45 |
| `RPCSession.heartbeatTimeout`, 90000 | `idleTimeout`, 90 |
| `RPCSession.DEFAULT_HEARTBEAT_INTERVAL`, `DEFAULT_HEARTBEAT_TIMEOUT` | `DEFAULT_PING_INTERVAL`, `DEFAULT_IDLE_TIMEOUT` |
| `RPCSession.DEFAULT_HEARTBEAT_JITTER` | gone: nothing read it |

#### Names

A member's name spells an acronym after its first word as a word, as
`requestId` does: rename each use. Nothing else about them changes.

| rc.1 | 1.0 |
| --- | --- |
| `readUTF`, `readUTFBytes`, `writeUTF`, `writeUTFBytes`, on `ByteArray`, `IDataInput`, `IDataOutput` and every class implementing them | `readUtf`, `readUtfBytes`, `writeUtf`, `writeUtfBytes` |
| `ByteArrayInput.readVarUTF`, `ByteArrayOutput.writeVarUTF` | `readVarUtf`, `writeVarUtf` |
| `Resources.getJSON` | `getJson` |
| `HTTPStatusEvent.responseURL` | `responseUrl` |
| `crossbyte.net.Endpoint.parseURL` | `parseUrl` |
| `HTTPServerConfig.phpCGIPath`, `phpINIPath` | `phpCgiPath`, `phpIniPath` |

#### Runtime

- An event, and a payload handed to a hook called once per arrival, is
  valid only during the call it is handed to. A `DatagramSocket`, a
  `ReliableDatagramSocket`, a `WebSocket` and a `Socket` hand the same
  event and the same `ByteArray` out again for the next arrival, and empty
  the bytes once the call returns. Code that keeps one past its call (that
  queues events, or `event.data`, to handle at the next game tick, say)
  reads empty bytes, or the next arrival's fields, where it read what
  arrived. Keep a copy instead: `event.data.readBytes(mine)`, the fields you
  need, or `event.clone()`, which copies the payload. Build with
  `-D crossbyte_check_events` to find the line that keeps one (it reads
  poison there, or reads nothing and throws), and with
  `-D crossbyte_fresh_events` to have every arrival made afresh, as before,
  until it copies. What is
  handed out other than as an event or to such a hook stays yours to keep:
  an RPC argument, a message a decoder returns, a request body,
  `NetConnection.onData`'s input.
- Sockets, datagram sockets and WebSocket messages read and write in
  `ByteArray.defaultEndian`, little-endian unless changed, as every
  `ByteArray` does; datagram and WebSocket payloads were big-endian. A
  protocol in network byte order sets `endian = Endian.BIG_ENDIAN` on its
  socket, or `ByteArray.defaultEndian` once.
- A listener added for a typed event-type constant must take that event or
  one it extends: `addEventListener(ProgressEvent.SOCKET_DATA, (e:Event) ->
  ...)` compiles, `(e:IOErrorEvent) -> ...` no longer does; the same for a
  `ServerSocket`'s listeners. Read `UncaughtErrorEvent.origin`, now `Any`,
  through a type test and a cast.
- An event's `target` and `currentTarget` are `emitter.EventTarget`s, not
  `Object`s: `var socket:Socket = event.target` compiles as it did, but a
  field read through one untyped (`event.target.localPort`), and an
  assignment to a type that is no dispatcher, no longer do. Assign it to
  its class first.
- A listener added again for a type it already listens for is not added
  again (but on the runtime): code that added one function twice to have it
  called twice adds two functions, or sets `allowDuplicates`.
- `addEventListener`, `removeEventListener`, `hasEventListener`,
  `removeAllListeners` and `dispatchEvent` are inline, so a subclass cannot
  override them: override `listenersChanged`, `listenerAdded` or
  `listenerRemoved` to act on listeners coming and going. A class
  implementing `IEventDispatcher` implements `events`, the verbs of the
  dispatcher it holds, in place of `dispatchEvent`.
- A type parameter that names an event type (`EventType<T>`, as in a method
  of your own that forwards `addEventListener`) needs `T:emitter.Event`.
- `HostApplication.advance` and `CrossByte.pump` no longer rethrow what a
  handler threw during the step: listen for
  `UncaughtErrorEvent.UNCAUGHT_ERROR` where code caught failures around
  them.
- On the jvm, the interpreter, hl and neko, `CrossByte.current()` on a
  thread no runtime belongs to throws `IllegalOperationError`, where it
  returned the primordial runtime. Capture the runtime on its own thread and
  hand work to it with `CrossByte.post`.
- `CrossByte.pump` is two inline overloads, and `GlobalTimer.setTimeout`
  and `setInterval` are overloads too (see Durations for their arguments):
  none of them is a value any more (`var step = runtime.pump`, or a call
  through `Dynamic`, does not compile or find it). Wrap it,
  `(delta) -> runtime.pump(delta)`.
- `readObject` and `writeObject` throw for an `objectEncoding` the build
  cannot do (AMF without the `format` haxelib), on `ByteArray`,
  `FileStream` and every socket, where they read `null` and wrote nothing.
- An object read through a `ByteArray` or a socket, or by `SharedObject` or
  `SharedChannel`, may hold 1,000,000 values (elements, members, names,
  each null of a run) and nest 256 deep (128 in AMF); one past either is
  refused with an `IOError`. A program reading larger objects it trusts
  raises `ByteArray.maxObjectValues`.
- `writeObject` puts a 32-bit length before an HXSF or JSON object, where
  rc.1 put 16 bits: an object written by rc.1 does not read back, so both
  peers, and anything stored, move to 1.0 together.
- `ByteArray.readVarInt` and `writeVarInt` are `readVarUInt` and
  `writeVarUInt`, in the same format. `ByteArrayInput.readVarUInt` reads
  values from 2^31 up, as a negative `Int`, where it threw; check for one
  where the value is a length.
- `ByteArray.uncompress` throws `crossbyte.errors.IOError` for data it
  cannot read and `crossbyte.errors.RangeError` for a result past its
  limit, whatever the algorithm, where it threw strings, `haxe.io.Eof` or a
  plain `haxe.Exception`: catch these instead.
- Code that keeps "no algorithm" in a `CompressionAlgorithm` types it
  `Null<CompressionAlgorithm>`, which `CompressionAlgorithm.fromString`
  answers. A token nobody knows, converted where an algorithm is asked for,
  throws an `ArgumentError`.
- Log timestamps are UTC with milliseconds (`2026-09-25T09:00:00.123Z`),
  where they were local time to the second, and control characters in a
  message or field are written as escapes. Anything parsing the text
  format expects both.
- A `TaskPool.submit` task's result is `Any`: cast it to read from it.
- `Vector.sort` takes a comparator or nothing; `Vector.concat` takes
  vectors: wrap an array or an item in a `Vector` first.
- `Vector.map` is typed by what its callback returns. A result assigned to
  the original element type, where the callback returns another, no longer
  compiles: it held the other type all along. Type the result as the
  callback's return.
- `Vector`'s `every`, `filter`, `forEach`, `map`, `some` and `sort` are
  macros, so they are not values: where `vector.forEach` was passed as a
  function, pass `f -> vector.forEach(f)`.
- `EnumUtil.getValue` is an `Array<Dynamic>`; `getNameValuePair` and the
  `KeyValuePair`s of `ListedMap`, `OrderedMap`, `Object.entries()` and
  `TypedObject.entries()` are
  classes, so code that builds one from another anonymous type, rather than
  a literal, constructs it instead.
- `SlotHandle` no longer becomes an `Int` by itself: use `handle.index()`
  for the slot and `handle.toInt()` for the whole handle. It has 20 index
  bits, so a `SlotMap` or `PackedSlotMap` holds at most 1,048,576 entries
  (it held 16,777,216), and one made with a larger `maxCapacity` throws.
- An `ObjectPool` keeps 10,000 free objects unless told otherwise: set
  `maxFree` to `0x7FFFFFFF` for no bound, as before. A negative `maxFree`
  throws an `ArgumentError`.
- Code that caught a `String` from a `BitSet` given a negative index or
  length catches a `crossbyte.errors.RangeError`.
- `ObjectRecycler.recycle` returns whether it took the object.
- `Random.reseed(seed)` draws a different sequence from before, so a
  replay recorded with a seed draws differently; instances (`new
  Random(seed)`) draw what they did. `choose` and `chooseWeighted` throw
  `ArgumentError` rather than a `String`, and `fillBytes` a `RangeError`
  for a negative length other than -1 (to the end) or a range past the
  bytes.
- `Version.major`, `minor` and `patch` read a part past 999 as written,
  not as 999 (`hash` still holds each to 999, and the comparisons no
  longer use it). `new Version` takes a part past 999 and throws an
  `ArgumentError`, not a `String`, for one below zero, as the setters now
  do.
- `MathUtil.lerp` answers a `Float`: where its result went into an `Int`,
  take `Std.int` of it.
- `SwitchTable` is `DispatchTable`, and `SwitchTable.make([...])` is
  `Dispatch.make([...])`, which comes with `import crossbyte.ds.DispatchTable`.
  For a dispatch in a hot loop, make a class implementing `DispatchTable`
  instead. The keys are constants of one type (an `Int`, a `String`, or an
  enum abstract over either) and the handlers take the same arguments: a
  table mixing them is split into one per kind. A key held in a variable
  is now a compile error. The fallback takes the key and then the
  handlers' arguments, as `(key, name, amount) -> ...`, where it took the
  key and an `Array<Dynamic>`. A dispatch with arguments of the wrong type
  or number no longer compiles, where it threw an `ArgumentError`.
  Handlers return nothing unless they declare a return type, and then the
  table returns it.
- `crossbyte.Timer.setInterval` refuses an interval of zero or less with an
  `ArgumentError`, where it ran the timer once: arm a timer that runs once
  with `setTimeout`.
- Natively, a runtime has SIGPIPE ignored when the process still has it at
  its default, so a write to a pipe with no reader fails rather than ending
  the process: `Sys.stdout().flush()` throws a file error the program can
  catch, and records logged there are lost. A program that should end
  there (a tool whose output is piped into `head`, say) sets SIGPIPE back
  to its default after making its runtime.
- `ThreadEvent.UPDATE` is gone; nothing dispatched it.
- `Random.seed` is no longer public: set the shared seed with
  `Random.reseed(value)`.
- A `Dynamic` value no longer converts to a `URL` on its own: cast it,
  `(value : String)`, or build `new URL(value)`.
- `PrimitiveValue.toFloat` reads a string as a number only if the whole of
  it is one: `"12abc"` and `"1,5"` are `NaN`, where the number they began
  with was read. Strip what follows a number before converting.
- A `TypedObject<T>` is made from a `T`, or from a `Dynamic` such as
  `Json.parse`'s result, and becomes a `T` or a `Dynamic`: code that gave
  one a value of another type, or took one as another type, `cast`s it
  where that is meant (`var t:TypedObject<Point> = cast value`).
- A `PrimitiveValue` made from a null `String` is null rather than `""`,
  and converts back to a null `String`: code that asked `isString()` of
  one, or used the `""` it gave, asks `isNull()`, or makes the value from
  `text != null ? text : ""`.
- Code that caught a `String` from a `PrimitiveValue` conversion or from
  `PrimitiveValue.fromDynamic` catches a `crossbyte.errors.RangeError` (a
  number out of range) or an `ArgumentError` (anything else), or the
  `crossbyte.errors.Error` both extend.
- `PrimitiveValue.toBool` of NaN is `false`: code that took it as `true`
  asks `Math.isNaN` of the number first.
- A `PrimitiveValue` made from a NaN `Float` is NaN rather than `0.0`:
  code that used the `0` it gave makes the value from
  `Math.isNaN(number) ? 0.0 : number`.
- A payload field named `hasOwnProperty`, `propertyIsEnumerable`,
  `isPrototypeOf`, `valueOf`, `toString` or `toLocaleString` is read from
  an `Object` with brackets, `payload["valueOf"]`: with a dot it is the
  method of that name.
- An `Object` holding an `Array` or a `String` lists no fields, where on
  Node it listed the indices or the characters: code that walked one so
  reads it as the `Array` or `String` it is.
- `FieldStruct`'s `exists`, `get`, `delete` and `clear` are called on the
  struct: `fields.exists(name)` where it was `FieldStruct.exists(fields,
  name)`, and `fields.get(name)`, `fields.delete(name)` and
  `fields.clear()` likewise. A key of one of those names is read and
  written with brackets, `fields["get"]`.
- `PriorityQueue.size` and `Deque.size()` are `length`, and
  `IndexedMap.length()` and `OrderedMap.length()` are the property
  `length`, as on every other `crossbyte.ds` type: drop the parentheses.
  `Deque.isEmpty()` is the property `isEmpty`, as on `PriorityQueue` and
  `Stack`.
- Where CrossByte threw a `String`, it throws one of its error classes,
  with the same text: an `ArgumentError` for a bad argument (crypto keys,
  nonces and lengths, JWK and JWKS documents, a JWT signer's keys,
  `RateLimiter`'s limits, a slot map's or `BloomFilter`'s size, a `URL`
  that does not parse, a null listener); a `RangeError` for an index or
  position out of range (`BitmapData` pixels, `IdList`, `ListedMap`,
  `ByteArrayInput`, a varint too long); an `EOFError` for a
  `ByteArrayInput` read past its end; an `IllegalOperationError` for a call
  the state refuses (an empty `Deque`, a full slot map, a disposed
  `BitmapData`, a statement with no connection, an `ObjectPool` object
  given back twice, a socket started on a thread with no runtime, a
  second `Application`); and a `crossbyte.errors.Error` where libsodium,
  BLAKE3 or mbedTLS failed. `catch (e:String)` no longer catches them:
  catch the class, or `crossbyte.errors.Error`, which they all extend.
- `Error.getStackTrace()` is gone: call `getCallStack()`, which every
  target has.
- `Error.errorID` and `ErrorEvent.errorID` are `errorId`, and every
  `lastInsertRowID` is `lastInsertRowId`, spelt as `requestId` and
  `sessionId` are.
- An error's `errorId` is the number its source gives it (a MongoDB or
  MySQL error number), and 0 for CrossByte's own: an `EOFError` carried
  Flash's 2030, and a `File` or `FileStream` `IOError` AIR's 3001 to 3014.
  Tell `File`'s failures apart by their message.
- `SQLError.detailID` and `detailArguments` are gone, and so are the
  constructor's last two arguments: a `MySQLError`'s number is its `code`
  (and `errorId`), and a `MongoError`'s labels are its `errorLabels`.

#### TCP

- Code that caught a `String` from `new NetConnection(uri)`, `new
  NetHost(uri)` or `parseUrl` catches a `crossbyte.errors.ArgumentError`.
- `ServerSocket.listen()`, and `ServerWebSocket.listen()`, throw an
  `IOError` for a server never bound, where Linux and macOS listened on a
  port of the system's choosing: bind first, to port 0 for one the system
  picks.
- `Socket.writeBytes` throws a `RangeError` for an offset or length outside
  the bytes given, and the `Socket` constructor a `SecurityError` for a
  port outside 0 to 65535, where they wrote part or did nothing.
- A `Socket` stops reading once 16 MiB have arrived that its application
  has not read (`maxInputBufferSize`, `PAUSE`), and goes on once it reads:
  an application that waits for a whole message larger than that before
  reading any raises the limit, or sets it to 0 for none.
- A raw `ServerSocket`, and a `NetHost` on one, closes a connection
  arriving while 10,000 are open (`maxConnections`), and a TLS one closes
  a connection from an address with 16 handshakes under way once half of
  `maxPendingHandshakes` are taken (`maxPendingHandshakesPerAddress`):
  raise the first for a server built to hold more, and set the second to 0
  behind a proxy.
- `NetHost.maxConnections` (`INetHost`) is the most connections a host
  serves, 10,000 by default, where it was the listen backlog: code that set
  it as a backlog now caps its connections at that number, so remove the
  line or set the cap it wants. A host asks for the system's largest
  backlog.
- A class implementing `INetHost` declares `maxConnections` as
  `(get, set)` and adds `refusedConnections` (a `Float`), `canDial`,
  `connectTimeout` and `stunTimeout` (`Float`s of seconds, `(get, set)`),
  `dial`, `discoverPublicAddress`, `localAddressFor`, `allocateRelay`,
  `dialRelayed` and `permitRelayedPeer`. A host that cannot dial from its
  listening endpoint answers `canDial` false, throws
  `IllegalOperationError` from `dial`, `dialRelayed` and
  `permitRelayedPeer`, and fails the `Future`s of `discoverPublicAddress`
  and `allocateRelay`. It adds `setCertificate(certificate, key)` too,
  throwing `IllegalOperationError` where it terminates no TLS, and
  `maxConnectionsPerAddress` and `maxPendingHandshakesPerAddress`
  (`Int`s, `(get, set)`).
- A `NetConnection` whose TCP connect fails calls `onClose` after
  `onError`, and `onClose` after an error is given the error's reason; a
  WebSocket connection closed by its peer reports `Reason.Code` with the
  close frame's code and reason, where it reported `Reason.Closed`. Code
  that took `onClose` to mean a connection had been up checks for
  `onReady` instead.
- `Reason` has a fifth case, `Overflow`, for a connection closed because
  what waited for its peer passed its limit. A `switch` on `Reason` that
  lists every case adds it.
- A host name given to `Socket.connect()`, `WebSocket.connect()`,
  `ReliableDatagramSocket.connect()`, `DatagramSocket.connect()` or
  `DatagramSocket.send()` is looked up off the runtime's thread, and one
  that does not resolve is reported as an `ioError` event after the call
  returns. `ReliableDatagramSocket.connect()` and `DatagramSocket.send()`
  threw `ArgumentError` for one, and `DatagramSocket.connect()` threw
  `IOError`: listen for `ioError` instead. A malformed address still throws
  at once.
- `RateLimiter` is in `crossbyte.net`; `crossbyte.http.RateLimiter`
  remains as a deprecated alias. It is a token bucket now, and its
  constructor is `new RateLimiter(maxRequests = 10, perSeconds = 60.0,
  ?clock, maxKeys = 100000)`, where rc.1's one argument was the window in
  seconds with ten requests fixed: `new RateLimiter(30.0)` becomes `new
  RateLimiter(10, 30.0)`.

#### UDP

- `DatagramSocket.timeout` is gone; it did nothing, so delete what sets it.
- `DatagramSocket.send` is `inline`, so a subclass can no longer override
  it: an override does not compile. Every call compiles as it did, and
  `socket.send` taken as a value, or called through `Reflect` or
  `Dynamic`, works as before. Code that overrode `send` (to log, filter,
  delay or drop datagrams) wraps the socket instead: a class of its own
  that holds a `DatagramSocket`, does its work in a `send` of its own and
  then calls the socket's, and hands the socket out (or forwards
  `addEventListener`) for its events.

#### Reliable UDP

- `ReliableDatagramSocket.send` is `inline`, so a subclass can no longer
  override it, as with `DatagramSocket.send`: wrap the socket instead.
  Every call compiles as it did, and `send` taken as a value, or called
  through `Reflect` or `Dynamic`, works as before.
- A `Socket` subclass that overrides `readBytes` or `writeBytes` no longer
  sees CrossByte's own reads and writes through them (an HTTP/1.1
  response, a cluster link, a TURN relay): those go through `__readBytes`
  and `__writeBytes`, which `readBytes` and `writeBytes` forward to.
  Override those instead to see both.
- `ReliableDatagramSocket.close()` is graceful: its `close` event comes
  once the peer has acknowledged everything, not during the call, and
  `abort()` is the old immediate close. Its FIN holds a place in the
  sequence, which a peer from before 1.0 does not know, so both ends need
  1.0 for what was sent before a close to arrive before it.
- A reliable datagram client on 1.0.0-rc.1 cannot return a join cookie:
  while a 1.0 server validates joins (once `joinValidationThreshold`
  sessions are pending, by default) its CONNECTs are dropped, and it joins
  once fewer are pending, or never under `JoinValidation.ALWAYS`. Set
  `joinValidation = NEVER` on a server that must take such clients under
  any load. A 1.0 client joins a server on rc.1 as before.
- A reliable session holds an acknowledgement for up to 25 ms (`ackDelay`)
  for something it sends to carry it. Set `ackDelay` to 0, on the socket or
  on `ReliableDatagramServerSocket`, for one every pass as before; a peer on
  1.0.0-rc.1 is acknowledged every pass either way.
- `ReliableDatagramSocket.maxOutputBufferSize` is 256 KB by default: a
  session that would hold more waiting for its window is ended with an
  `ioError`. One `send` larger than the window waits whole, so an
  application that sends more than that at once (one large reliable
  message, a file) raises it on its sessions, or sets it to 0 for no limit.
- `ReliableDatagramSocket.timeout`, in milliseconds, is `connectTimeout`,
  in seconds as the class's other durations are: `timeout = 5000` is
  `connectTimeout = 5`. `DEFAULT_TIMEOUT` (20000) is
  `DEFAULT_CONNECT_TIMEOUT` (20.0). A session the server dials takes the
  server's `connectTimeout`, in seconds too.

#### WebSocket

- The process-wide WebSocket settings are gone: set `maxMessageSize` or
  `closeTimeout` on the `ServerWebSocket` or `WebSocket` where code set
  `WebSocket.MAX_MESSAGE_SIZE` or `CLOSE_TIMEOUT`, and `pingInterval`
  where it set `PING_INTERVAL`; `MAX_PAYLOAD` has no replacement, since a
  frame may now be as long as a message. `WebSocket.toWebSocket` is gone
  too; it is `ServerWebSocket`'s own.
- A `wss://` client checks the server's certificate: that it chains to an
  authority the client trusts and names the host. A client of a server with
  a self-signed certificate trusts it with
  `certAuthority = Certificate.fromFile("server.pem")`, or sets
  `verifyCert = false`.
- `ServerWebSocket.cert` and `certAuthority` take `crossbyte.net.Certificate`
  and `crossbyte.net.Key`, not `sys.ssl.Certificate` and `sys.ssl.Key`:
  load them with `Certificate.fromFile(path)` and `Key.fromFile(path,
  ?password)`, or `fromPem`.
- `ServerWebSocket.verifyCert` is gone: `certAuthority`, or
  `requireClientCertificate()`, asks clients for a certificate, natively
  now as well as on Node.
- A `ServerWebSocket`'s `cert` and `certAuthority` are set before `bind()`,
  on Node too, and only on a secure server; either throws otherwise.
- A `ServerWebSocket` answers an upgrade 503 while 10,000 sessions are
  open (`maxConnections`), and closes a connection from an address with 16
  still upgrading once half of `maxPendingHandshakes` are taken
  (`maxPendingHandshakesPerAddress`): raise the first for a server built
  to hold more, and set the second to 0 behind a proxy that forwards
  connections before their client speaks.
- A `ServerWebSocket` closes a session with 1011 once 8 MiB wait for
  its peer (`maxOutputBufferSize`), where it held any amount: set a
  larger limit for a server that bursts more than that to one session,
  or 0 for none.
- A `ServerWebSocket` refuses an upgrade request of more than 16 KiB
  with 431, where it read one of any size: raise `maxHeaderSize` for
  clients carrying more cookies than that.
- A session closes with 1006 when it has heard nothing from its peer for
  60 seconds (`idleTimeout`), pinging it after 30 (`pingInterval`); every
  conforming peer answers pings. Set `idleTimeout` to 0 for a peer that
  must stay silent longer.
- `WebSocket.shutdown()` throws an `IllegalOperationError`, where it
  returned having done nothing: close with `closeWith()` or `close()`.

#### HTTP

- An `HTTPServer` without a `rootDirectory` serves no files and listens on
  `127.0.0.1`: set `config.rootDirectory = new File(...)` for a server that
  serves files, and `config.address = "0.0.0.0"` for one other machines
  must reach. `validate()` refuses PHP, `rewrites` and `tryFiles` entries
  past the first two without a root.
- A static file whose path has a segment starting with `.` (`.env`,
  `.git/config`) is answered 404, except under `/.well-known/`: set
  `serveDotFiles` to serve them.
- `HTTPServerConfig.tryFiles` is `["$uri", "$uri/"]` by default, where it
  ended with `"/index.html"`: restore a single-page application's fallback
  with `config.tryFiles = ["$uri", "$uri/", "/index.html"]`. `validate()`
  refuses a `tryFiles` that does not begin with `"$uri", "$uri/"`.
- `HTTPServerConfig.rewrites` is empty by default, where it routed
  `^/api/.*$` to `/index.php`: pass the rule explicitly to keep it.
- `HTTPServerConfig`'s constructor takes `phpTimeout` after `phpMode`, before
  `tryFiles` and `rewrites`, and its `address` defaults to `127.0.0.1`.
  Code that passed `tryFiles` or `rewrites` by position inserts the
  timeout, or sets the fields by name.
- `HTTPServerConfig.validate()`, and so `new HTTPServer`, refuses an
  `errorDocument` that is not there.
- Server defaults that now bound: `maxConnections` is 10,000 (was 256);
  the rate limiter allows 240 requests a minute per client (was 10);
  `maxOutputBufferSize` is 8 MB (was unbounded); a request must arrive in
  full within `requestTimeout`, 60 seconds, or is answered 408 (0
  disables); a PHP response past `phpMaxResponseSize`, 8 MiB, is a 502;
  and a PHP backend that does not answer within `phpTimeout`, 30 seconds,
  is a 504. Set each where a server needs more.
- HTTP/1.1 connections are kept alive by default (`keepAlive`, 5 s idle,
  1,000 requests): set `keepAlive = false` for one request a connection.
- The server compresses a response only when it is 1 KB or more, of a
  text-like type, and not an error, and prefers gzip to Brotli when the
  client takes both equally: set `compression.minimumSize` and
  `compression.types` to compress more, or `compression.enabled = false`
  for nothing.
- With `corsAllowCredentials` on, `validate()` refuses
  `corsAllowedOrigins` holding `"*"`: name the origins. A preflight is
  answered with `corsAllowedMethods` and `corsAllowedHeaders` rather than
  what it asked for, so list every method and header a page sends
  (`Authorization`, custom headers).
- A request's path is normalised before middleware sees it (repeated
  slashes collapsed, dot segments applied, a backslash read as `/`), a path
  climbing above the root, a malformed escape or an encoded NUL is answered
  400, and `+` in a path is a plus, not a space. A guard written against
  the raw path checks the normalised one.
- A custom `HTTPBackend` that reads `context.data` gets an `HTTPRequestBody`,
  not a `String` or `Bytes`: send `context.data.toBytes()`, and read
  `context.data.text` (or `isText`) where it matters which it was. Code that
  builds an `HTTPRequestContext` from an object literal still compiles; code
  that passes some other structure as one does not.
- `RewriteRule` and `RewriteCondition` are classes: object literals still
  build them, but a value of some other structure type no longer passes as
  one, so build it from a literal.
- `Http.MAX_REDIRECTS`, `MAX_BODY_SIZE`, `MAX_CHUNKED_BODY_SIZE`,
  `MAX_DECOMPRESSED_BODY_SIZE` and `MAX_RESPONSE_HEADER_BYTES` are gone: set
  `maxRedirects`, `maxBodySize`, `maxDecompressedSize` and
  `maxResponseHeaderSize` on each `URLRequest` instead. A custom
  `HTTPBackend` reads them, and `responseHeaderTimeout`, from its
  `HTTPRequestContext`.
- `URLRequest.readTimeout = 0` is no idle limit natively too, where it was
  30 seconds.
- A load fails once it has waited its `readTimeout` for one of
  `URLLoader.maxConcurrentLoads` (16) threads, and a response's head must
  arrive within `URLRequest.responseHeaderTimeout`, five minutes, of its
  request. Raise `maxConcurrentLoads` or `readTimeout` for many slow loads
  at once, and `responseHeaderTimeout` with `readTimeout` for a long poll
  held longer than five minutes.
- A redirect to another origin drops `Authorization`,
  `Proxy-Authorization` and a `Cookie` set in `requestHeaders`, and a
  redirect from `https` to `http` is refused unless
  `URLRequest.followInsecureRedirects` is set.
- `OAuth.getAccessToken` and `refreshAccessToken` go through `URLLoader`
  and need a CrossByte runtime on the calling thread; their callbacks run
  on that thread, after the call has returned, natively and on Node.
- The access log's line is
  `[INFO] [http.access] method=GET path=/ status=200 client=127.0.0.1`,
  where it was `[INFO] [http.access] Client 127.0.0.1 GET / - Status: 200`.
  A parser or alert keyed on `Status: <code>` reads the `status` field
  instead, and a path with a space, a quote or an equals sign comes quoted,
  with `"` and `\` escaped. In JSON the four are members of the object
  (`"status":"200"`, a string like every field) and `message` is empty.

#### RPC

- Both ends of a compiled RPC connection are built with 1.0: a compiled
  call's op is the hash of its method's signature, where it was the hash of
  its name, so a peer on 1.0.0-rc.1 finds none of a 1.0 peer's methods, nor
  it the rc.1 peer's. A hand-written `dispatch` compares against
  `Hash.fnv1a32` of each method's signature (the RPC guide's "What names a
  call") where it compared against that of its name.
- `RPCSession.start()` heartbeats on any session, and every 1.0 session
  answers pings. A session on 1.0.0-rc.1 does not, so heartbeat an older
  peer only from a side that also calls it often enough to be answered. A
  heartbeat timeout closes the connection as `Reason.Timeout`, where
  `onClose` heard `Reason.Closed`.
- A null `String` or `Bytes` argument to a compiled RPC call, where the
  argument is neither optional nor `Null<T>`, throws an `ArgumentError`
  natively too, where a null `String` went as an empty one: pass `""`, or
  declare the argument `?name` or `Null<String>` to send null.
- A handler that throws anything but an `RPCError` answers its caller
  `RPCError.INTERNAL_MESSAGE`, where it sent the error's text: throw an
  `RPCError` with the message the caller should see.
- An `INetConnection` of your own copies what its `send` is given before
  keeping any of it (to queue it, say): an `RPCSession` writes its next
  frame over the one it sent as soon as `send` returns. Every transport
  CrossByte ships copies. `-D crossbyte_check_events` poisons each frame
  once it is sent, so a connection that keeps one sends garbage its tests
  will see; `-D crossbyte_fresh_events` frames each in a buffer of its own,
  as before.
- `RPCResponse.respond()` replaces the responder bound before, as it says,
  where it added one: add with `then`.
- An `@:rpc` method that returns a value declares its return type, or the
  build fails; undeclared, it was taken for `Void` and never answered. A
  contract can no longer name a method `beforeCall`, `afterCall`,
  `dispatch` or `session`, which `RPCHandler` declares.
- A handler that calls its clients back names the sessions it serves, and
  its `session` is typed; a cast of `session`, or a call through
  `session.commands` that went through `Dynamic`, is no longer needed.
  `extends RPCHandler` with no parameters still serves any session.

  Before:

  ```haxe
  class RoomServer extends RPCHandler implements ChatContract {
  	public function say(room:String, text:String):Void {
  		final caller:RPCSession<ListenerCommands, String> = cast session;
  		caller.commands.said(room, text);
  	}
  }
  ```

  After:

  ```haxe
  class RoomServer extends RPCHandler<ListenerCommands, String> implements ChatContract {
  	public function say(room:String, text:String):Void {
  		session.commands.said(room, '${session.data}: $text');
  	}
  }
  ```
- A call the other side's session refused fails with a case of `RPCFailure`
  of its own (`UnknownMethod`, `UnreadableArguments`, `Busy`, `NoHandler`,
  `HandlerTimedOut`, `HandlerFailed`), where it was `Refused` with one of
  `RPCError`'s messages; `Refused(message)` is now only a handler's own
  `RPCError`. A `switch` that lists every case needs the new ones, and one
  that compared a message matches the case instead.

  Before:

  ```haxe
  switch (failure) {
  	case Refused(message) if (message == RPCError.BUSY_MESSAGE): retryLater();
  	case Refused(message): trace('refused: $message');
  	case TimedOut | Cancelled | Stopped | Disconnected(_) | Unsent(_) | Unreadable(_): giveUp();
  }
  ```

  After:

  ```haxe
  switch (failure) {
  	case Busy: retryLater();
  	case Refused(message): trace('refused: $message');
  	case UnknownMethod | UnreadableArguments | NoHandler | HandlerTimedOut | HandlerFailed: giveUp();
  	case TimedOut | Cancelled | Stopped | Disconnected(_) | Unsent(_) | Unreadable(_): giveUp();
  }
  ```
- `RPCHandler.MAX_FRAME_LEN` is `RPCSession.DEFAULT_MAX_FRAME_SIZE`, the
  default of `RPCSession.maxFrameSize`: 8 MiB, as it was.
- `RPCResonse`, a misspelling of `RPCResponse` that rc.1 also exported, is
  gone: write `RPCResponse`.

#### Data

- Counts and ids are `Float`s, exact past 2^31: `lastInsertRowId`,
  `totalChanges` and `DBStats`' page counts of `SQLiteConnection`;
  `affectedRows` and `lastInsertRowId` of `MySQLConnection`,
  `PostgresConnection` and `PostgresRawResult`; and
  `MongoConnection.affectedRows`. `FKViolation.rowid` is a `Null<Float>`,
  and `SQLiteConnection.cacheSize` an `Int`, negative for a size in KiB.
  Code that keeps one in an `Int` needs `Std.int()`.
- Natively, MySQL and SQLite column values come back exact: MySQL
  `BIGINT` and `INT UNSIGNED`, and every SQLite `INTEGER`, are an `Int` when
  the value fits in 32 bits and a `haxe.Int64` when it does not; `DECIMAL`
  is a `String`; `DATE`, `DATETIME` and `TIMESTAMP` are read as UTC, and
  the zero date as `null`; a NULL column is in the row holding `null`;
  `TIME` and `YEAR` are `String`s; and `Bytes` is for binary columns only.
  Take a large id as `var id:haxe.Int64 = row.id`, parse a `DECIMAL` with
  `Std.parseFloat` where a `Float` is close enough, read dates with the UTC
  getters (and set `MySQLConfig.timeZone` to `"+00:00"`), and test for NULL
  with `== null` rather than `Reflect.hasField`.
- A statement the server refuses throws an `SQLError` from every driver,
  after dispatching the `SQLErrorEvent` it already did; so do `begin`,
  `commit`, `rollback` and the savepoint methods of Postgres and MySQL, and
  a COMMIT that failed. SQLite throws `SQLError` where it threw a `String`,
  `PostgresConnection.request()` where it threw `IOError` or a `String`,
  and MySQL throws `MySQLError` (an `SQLError`, with `code` and
  `sqlState`), whose message no longer begins with the statement. Code that
  listened for the event and counted on the call returning catches the
  error too.
- `parameters` of `SQLiteStatement`, `MySQLStatement` and
  `PostgresStatement` is a `FieldStruct<SQLValue>`: a `Bool`, `Int`,
  `Float`, `Int64`, `String`, `Bytes`, `Date` or null converts to it as it
  is set. A value read back is a `SQLValue`; cast it to its type
  (`var name:String = statement.parameters.name`). On SQLite, which took
  `String`s only, a number now goes in as a number and `Bytes` as a blob.
  MySQL writes a number unquoted and a `Date` as its UTC fields: set
  numbers as numbers, and dates as `Date`s rather than formatted strings.
- `PostgresConnection.request()` answers a `PostgresResultSet`, a
  `sys.db.ResultSet`, where it answered `Dynamic`; the
  `PostgresStatement.PostgresResultSet` typedef of `Dynamic` is gone.
  `PostgresRawResult` is a class in `crossbyte.db.postgres`, and
  `SQLiteConnection`'s `WalCheckpointResult`, `FKViolation` and `DBStats`
  are classes: object literals with their fields still make them, but a
  value built as another anonymous structure no longer passes for one.
- `PostgresConnection.autocommit = false` takes effect, where it did
  nothing: statements then wait for `commit()`. Remove it from code that
  set it and relied on each statement committing. A negative Postgres
  `connectTimeout` throws an `ArgumentError`.
- `setSavepoint()` on SQLite, MySQL and Postgres returns the savepoint's
  name, and `releaseSavepoint()` and `rollbackToSavepoint()` without a name
  act on the innermost savepoint held. `rollbackToSavepoint()` with no name
  rolled back the whole transaction: call `rollback()` for that.
- `SQLiteConnection.open()` and `openAsync()` throw on a connection that
  is open: `close()` it first, and after an asynchronous close wait for
  `CLOSE`.
- An SQLite connection opened with `SQLiteMode.READ` refuses to write:
  open with `UPDATE` to write.
- `JournalMode.fromString` throws an `ArgumentError` for a name it does
  not know, where it returned `DELETE`. Code that read an unchecked value
  through it catches the error, or checks the value first.
- A `SQLiteConnection` waits up to 5 seconds for another connection's
  write lock, `lockWaitTimeout` as it opens, where it failed at once with
  "database is locked". On a synchronous connection the wait is on the
  calling thread: set `lockWaitTimeout = 0` where failing at once is wanted,
  or less where a runtime's thread calls it.
- On an asynchronous `SQLiteConnection`, `request()` and the properties
  that ask SQLite wait for the work queued before them (`queueTimeout`),
  and the rows `request()` answers are read by name: its `getResult`,
  `getIntResult` and `getFloatResult` throw. `connected` is true from the
  `OPEN` event to `close()`.
- A native MySQL connection uses TLS whenever the server offers it
  (`MySQLConfig.sslMode`, `PREFERRED` by default), without checking the
  certificate: set `VERIFY_IDENTITY` and `sslCa` to know which server you
  reached, or `DISABLED` for the old behaviour.
- `crossbyte.db.mysql.IsolationLevel` and
  `crossbyte.db.postgres.PostgresIsolationLevel` are one
  `crossbyte.db.IsolationLevel`, with the same four values: import that
  instead. It no longer takes a `String`: `isolationLevel =
  "SERIALIZABLE"` is `isolationLevel = IsolationLevel.SERIALIZABLE`, and
  `IsolationLevel.fromString` reads one from text, refusing anything but
  the four.
- `PostgresConfig.sslMode` is a `PostgresSSLMode`, where it was a
  `String`: `sslMode: "require"` is `sslMode: PostgresSSLMode.REQUIRE`,
  and the other modes are libpq's in capitals (`VERIFY_FULL` for
  `"verify-full"`).
- `MongoConnection` speaks MongoDB's wire protocol, and PHP's `mongodb`
  extension is no longer used. `MongoConnection.lastInsertRowID` is gone
  (it read 0 whatever was inserted): read `lastInsertId`, the `_id` of the
  last document inserted. `request()` takes Extended JSON and answers a
  cursor over the result's documents, where it answered the command's reply
  as one row, and `MongoStatement` binds its `:name` parameters as BSON
  values.
- `BCrypt.hash` makes `$2b$` hashes at cost 12 by default, where it made
  `$2y$` hashes at cost 10, and `BCrypt.needsRehash(hash)` reports a hash of
  any other revision or cost. Hashes stored before still verify: rehash on
  a successful sign-in when `needsRehash` says so, and they are replaced as
  users return.
- A `JWT` verifying tokens that carry `aud` needs `expectedAudience` set to
  the audience it is; with none, those tokens are refused.
- `JWTAlgorithm.HS384` and `HS512` are gone; nothing could use them.
- `JWT.safeBase64UrlEncodeString` is renamed `safeBase64UrlDecodeString`.
- `JWT.verify` and `verifyToken` are inlined where they are called, and are
  no longer values: pass `token -> jwt.verify(token)`. Natively, on the jvm
  and on HashLink a time given as `null` no longer compiles: leave it out
  for the wall clock.
- `JWTPayload.issuedAt`, `expiresAt` and `notBeforeTime` are
  `Null<Float>`, where they were `Null<Int>`: convert with `Std.int` where
  code keeps one in an `Int`. A claims literal whose times mix `Int` and
  `Float` converts one of them (`exp: now + 3600.0`), and a time that is not
  a number no longer compiles.
- `JWTPayload.audience` is a `JWTAudience`: ask it with `contains(name)` or
  read `toArray()`. `JWTPayload.seconds` is no longer public.
- `Secret`, `JWTHeaderData` and `SigningKeyPair` are classes: a value typed
  as an anonymous structure no longer passes for one, and `Json.stringify`
  writes a `JWTHeaderData`'s unset members as `null`.
- Off native cpp, `Ed25519.verifyDetached` throws an
  `IllegalOperationError` where it answered `false`, and `keypair` and
  `signDetached` throw one where they threw a String; `Blake3`,
  `LocalConnection`, `SharedChannel` and `SharedObject` throw one where
  they threw a String or an `ArgumentError`. Check `isSupported` first.
- `Blake3.isAvailable()` and `Ed25519.isAvailable()` are
  `Blake3.isSupported` and `Ed25519.isSupported`, a static `Bool` as every
  other class's feature check is: drop the parentheses.
- `Ed25519.availabilityMessage()` is `Ed25519.unsupportedReason`, which
  every crypto class has beside `isSupported`: why it cannot be used here,
  or `null` where it can.
- `SecureRandom.getSecureRandomBytes`, and so everything that needs secure
  random bytes, throws an `IllegalOperationError` on the interpreter, neko
  and HashLink, where it threw a String.

#### Platform

- `File.applicationStorageDirectory` is the application's own directory
  inside the account's application data, so stores moved:
  `%APPDATA%\stores\<name>` is now `%APPDATA%\<id>\stores\<name>`, and
  `$HOME/stores/<name>` is now `~/.local/share/<id>/stores/<name>` on
  Linux (`$XDG_DATA_HOME` where it is set) and `~/Library/Application
  Support/<id>/stores/<name>` on macOS, with `<id>` the main class's full
  name unless `-D crossbyte_app_id` names it. Nothing is moved for you (a
  store in the old place could be any application's), so move an
  application's own across once. Two applications with the same main
  class, such as `Main`, share a directory until one sets the define.
- `File.applicationDirectory` and `Resources` read from the program's own
  directory instead of the working directory. The build copies `resources`
  beside the program; a tool that moves the program afterwards must carry
  `resources` with it.
- `Resources` refuses a path with a `..` segment, a leading `/` or `\`, or
  a `:`: `exists` answers `false`, `resourceSize` -1, and the loaders throw
  `SecurityError`. Name resources relative to `resourcesDir`. On Windows it
  also refuses a segment Windows opens as a device (`CON`, `PRN`, `AUX`,
  `NUL`, `COM0` to `COM9`, `LPT0` to `LPT9`, `CONIN$`, `CONOUT$`, with or
  without an extension), which Windows cannot hold as a file anyway.
- `File` no longer expands `%NAME%` in a path on Windows: build the path
  from `Sys.getEnv("NAME")`, or start from `File.applicationStorageDirectory`
  and the other static directories, which are usually what was meant.
- `File.resolvePath` normalises the path: `..` never climbs past the file
  system's root or the application storage directory, and an absolute path
  is returned as that path, where it was appended. It is not a sandbox;
  `dir.getRelativePath(file) == null` is the check.
- `File.moveTo` with `overwrite` replaces an existing directory instead of
  merging into it, as its documentation says; merge with `copyTo` and then
  delete the source if that is what was meant.
- `File.data` throws an `IllegalOperationError` until a load has
  succeeded, where it answered `null`: check for a load first, or catch
  it. `File.extension` and `type` are `null` for a name with no dot, where
  they were `""`.
- `File.size` throws an `IOError` for a file over 2 GB, where it answered a
  wrong number, and `File`'s failures are `IOError`s with AIR's error
  numbers, where some were the base `Error` or a string: catch `IOError`.
- `FileStream` reads and writes in `ByteArray.defaultEndian`,
  little-endian unless changed. Set `endian = Endian.BIG_ENDIAN` on a
  stream reading numbers that rc.1's synchronous `FileStream` wrote. Its
  `writeObject` frames HXSF and JSON with a 32-bit length, so objects in
  files written by rc.1 do not read back.
- A synchronous `FileStream.readBytes` asking for more than the file holds
  throws `EOFError` and reads nothing, where it padded with zeros: ask
  `bytesAvailable` first to read "up to" a length.
- `System.processAffinity`, `hasProcessAffinity` and `setProcessAffinity`
  throw an `IllegalOperationError` off native and on macOS, where they
  answered `[false]`, `[]` and `false`: check `System.PLATFORM` and the
  target first. `System.getDeviceId()` answers `null`, not `""`, where
  there is no identifier, and `totalSystemMemory()` and
  `freeSystemMemory()` throw where nothing answers, where they answered 0.
  `System.memoryUsage()` is a `Float`.
- `SharedObject`'s constructor, `flush()`, `sync()` and `clear()` throw an
  `IOError` when another participant holds the region's lock past
  `lockWaitTimeout` (five seconds), where they waited without end; set
  `lockWaitTimeout` to 0 to keep waiting. `sync()` throws an `IOError` for a
  payload the build cannot read, where it set `data` to `{}`.
- On Linux and macOS a `SharedObject` region is not shared between users:
  one another user made under the name throws an `IOError`, where it was
  shared when the first user's umask let others write it.
- Two users can no longer meet over a `LocalConnection`, `SharedChannel` or
  `local://` name: each user's names are their own. A name's socket is
  `/tmp/crossbyte-<uid>/<name>` on Linux and macOS, where it was
  `/tmp/crossbyte_local_connection_<name>`, and its pipe
  `\\.\pipe\crossbyte-<SID>-<name>` on Windows, where it was
  `\\.\pipe\<name>`: a program of your own that opened those directly
  must follow.
- `Worker.canceled` is gone. It was true once a run was over however it
  ended, completed and failed too: read `state` (`CANCELLED`,
  `COMPLETED` or `FAILED`), or `cancelRequested` for a run called off.

## 1.0.0-rc.1 - 2026-04-28

This is the first CrossByte 1.0 release candidate.

### Added

- broader test coverage across core runtime, networking, HTTP, RPC, IO, IPC, crypto, math, and data-structure packages
- contract-driven RPC sample, TCP chat sample, IPC samples, UDP/RUDP samples, worker sample, and simple web server sample
- optional native extension integration paths for `crossbyte-libuv`, `crossbyte-brotli`, and `crossbyte-lz4`
- generated API documentation build in CI, published as the `crossbyte-api-docs` artifact

### Changed

- polished `README.md`, sample index, and release metadata for release-candidate consumption
- promoted Brotli support into the core compression/HTTP surface while keeping native acceleration modular
- refined RPC contract generation so shared interfaces describe logical handler signatures cleanly
- improved CI coverage for interpreter tests, native smoke tests, extension jobs, and sample builds

### Fixed

- multiple native/runtime integration issues shaken out by new samples and CI coverage
- HTTP request/response compression handling across `gzip`, `deflate`, `lz4`, and `br`
- sample build path consistency and native sample coverage in CI
- a broad set of public API doc placeholders and presentation rough edges
