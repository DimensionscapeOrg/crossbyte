# Changelog

All notable changes to CrossByte will be documented in this file.

## Unreleased

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
- **Typed RPC.** Compiled contracts carry arrays, structures, enums,
  `Null<T>` and compact numbers, generated with no reflection; the runtime
  lane has typed calls; a request can hand its answer to a receiver and
  allocate nothing; calls get deadlines, handlers can answer later,
  clients redial, and a hello versions the protocol.
- **Databases.** MongoDB over its wire protocol, with BSON; a native MySQL
  client with TLS and MySQL 8 logins; Postgres parameter binding,
  cancellation and timeouts; SQLite with an asynchronous worker, attached
  databases and schemas; `ConnectionPool`, `AsyncDatabase` and
  `SchemaMigrator`.
- **Crypto.** libsodium, vendored (AEAD, X25519, key exchange, BLAKE2b,
  HKDF, Ed25519, Argon2id); RSA and ECDSA signatures; JWT with RS256, ES256
  and EdDSA, JWKS and claims of your own; OAuth PKCE; asynchronous password
  hashing.
- **Every target.** Node runs the networking stack: sockets, TLS,
  WebSocket, UDP and the HTTP server. The jvm runs the whole suite, TLS
  included. HashLink and Neko build and run again. The native suite runs on
  Windows, Linux and macOS.
- **Runtime and operations.** `Future` and `Completer`, work posted between
  threads, timers on a heap or a timing wheel, loop-health measures, a
  structured `Logger`, layered `Config`, durable `Store`, graceful shutdown
  and Windows service control, and `crossbyte.metrics`.
- **Hardened and faster.** Every server bounds what one peer can make it
  hold or spend; the wire parsers are fuzzed; and natively, sending or
  receiving a message over TCP, UDP, reliable UDP or WebSocket allocates
  nothing once a connection is under way, but the text a WebSocket
  listener asks for.

### Added

#### Runtime

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
  `timerOverruns`.
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
- `crossbyte.core.Config`: configuration layered from defaults, `key=value`
  files and environment variables, with typed getters and `require()`.
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
- `crossbyte.cluster`: `SnowflakeId`, `Rendezvous` hashing, `Membership`
  and `NodeChannel`, low-level pieces for running as more than one node.
- Data structures: `BitSet.nextSetBit`, `nextClearBit`, iteration,
  `isEmpty`, `clone` and the set operations; `RadixTree.longestPrefix` and
  `longestPrefixLength`; `QuadTree.queryCircle`; `Deque` with a starting
  capacity, `iterator()` and `clear()`; `BloomFilter.clear`, `addInt`,
  `containsInt`, `addBytes` and `containsBytes`; `Array2D.fill`.
- `SwitchTable.make` takes any expression as a key, and a fallback for a
  key no case matches.
- `crossbyte.utils.Checksum` (CRC-32, Adler-32, MD5, SHA-1 and XOR) and
  `crossbyte.utils.IntParse`, which reads an integer the same way on every
  target.
- `crossbyte.sys.System.sleep(seconds)`, which returns on the interpreter
  on Windows, where `Sys.sleep` can sleep for days.
- `GlobalTimer.setTimeout` and `setInterval` take a `Void->Void` function
  directly.

#### TCP

- TLS on both ends of a `Socket`. A client sets `secure` before
  `connect()`, and checks the server with `verifyCert` and
  `certAuthority`. A server is `new ServerSocket(true)` with
  `setCertificate`, `addSNICertificate` and `requireClientCertificate()`,
  stepped across ticks under `handshakeTimeout`. Natively, on the jvm and
  on Node.
- `crossbyte.net.Certificate` and `crossbyte.net.Key`, loaded with
  `fromFile` or `fromPem`, a key in any form it comes in (PKCS#1, SEC1,
  PKCS#8, encrypted or not). A `Key` prints as `[Key: redacted]`.
- ALPN: `ServerSocket.setALPN()` and `Socket.alpnProtocol`.
- Native TLS servers resume returning clients with session tickets; build
  with `-D HXCPP_SSL_NO_TICKETS` to turn that off. With the hxcpp fork on
  mbedTLS 3.6.7, TLS 1.3 is negotiated with every peer that offers it.
- Limits on a server: `ServerSocket.admit(address, port)`, asked before
  any TLS work; `maxAcceptsPerTick` (64); `maxPendingHandshakes` (256);
  `maxConnections` (10,000); `maxPendingHandshakesPerAddress` (16); and
  the counts `refusedConnections`, `acceptFailures` and
  `handshakeFailures`.
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
- One server on several cores: `ServerSocket.runtimes`, `runtimeCount` and
  `selectRuntime` hand each accepted connection to a runtime, and
  `reusePort` gives each runtime its own listener on Linux. Natively, on
  the jvm, hl, neko and the interpreter. A runtime that exits gives back
  the places its connections held under `maxConnections`, on a
  `ServerSocket`, an `HTTPServer` or a `ServerWebSocket`.
- `IOErrorEvent.TIMEOUT_ERROR_ID` marks a connect that timed out, and a
  `NetConnection` reports it as `Reason.Timeout`.
- `userData` on `Socket`, `ReliableDatagramSocket`, `DataChannel` and
  `NetConnectionBase`, for an application's state that should go when the
  connection goes.
- `crossbyte.net.RateLimiter`, a token bucket with `tryAcquire`,
  `secondsUntil`, `addressKey` and a bound on keys (`maxKeys`), and
  `crossbyte.net.ConcurrencyLimiter` for how many at once.
- `crossbyte.net.FrameCodec`: length-prefixed messages over a stream, with
  `maxFrameSize` checked on the header.
- `crossbyte.net.LocalAddress` and `ReflexiveAddress`, and on `INetHost`
  `localAddressFor`, `discoverPublicAddress`, `dial` and `canDial`.
- `new NetHost("wss://...")` takes the certificate it presents as `cert`,
  and a `NetHost` URI on port 0 listens on a port the system picks.

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
  sessions.
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
  closeCode)`, `clientCount`, `draining` and `WebSocket.closeWith(code,
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
  congestion control and `bufferedAmount`.
- ICE: `IceAgent`, consent freshness (RFC 7675), role conflicts, ICE
  restart (`restartIce()`), trickle (`onLocalCandidate`,
  `addRemoteCandidate`) and `onSelectedPairChanged`.
- `PeerConnectionHost`: many peer connections on one UDP port, driven by
  one tick.
- STUN and TURN: `gatherReflexive`, `gatherRelayed` and
  `gatherRelayedFrom(servers)` with failover; `TurnClient` over UDP, TCP or
  TLS (`TurnTransport`), with RFC 8656 channels (`useChannels`), IPv6
  (`requestIPv6`), RFC 8489's SHA-256 credentials and 300 redirects;
  `setRelayCredentials` for expiring credentials.
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
  program has stopped making requests. `-D crossbyte_no_http2` leaves it
  out of a build.
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
  before closing.
- Metrics: `HTTPServerConfig.metrics` and `metricsPrefix`.
- One server on several cores: `HTTPServerConfig.runtimes`,
  `runtimeCount` and `reusePort`.
- PHP: `phpTimeout` (30 s; a 504), `phpMaxResponseSize` (8 MiB; a 502)
  and `phpMaxExchanges` (64), and PHP served on Node.
- `serveDotFiles`, off by default.
- Client limits and deadlines per request: `URLRequest.headTimeout`
  (5 min), `totalTimeout`, `maxBodySize` (64 MB), `maxDecompressedSize`
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
- Typed runtime calls: `RPCSession.runtimeCall(op)` and
  `runtimeRequest(op)` write values straight into the frame, and
  `registerArgs(op, handler)` reads them through `RPCArgs`.
- Handlers can answer later by returning `Future<T>`;
  `RPCSession.maxCallsWaiting` (256) bounds the calls waiting.
- Deadlines: `RPCResponse.timeout(ms)`, `RPCSession.callTimeout` and
  `handlerTimeout`; a call past its deadline fails with `RPCTimeoutError`.
  `withTimeout(ms)` on a commands class gives the next call a deadline of
  its own, a call made with a receiver included
  (`commands.withTimeout(2000).joinThen(room, receiver)`). Every deadline
  waits in one heap a session, under one timer, so a call's deadline
  allocates nothing, whatever its length.
- Deadlines and cancellation reach the handler, as gRPC's do: a call's
  deadline goes with it, and a call its caller cancels (`cancelCall`) or
  times out is cancelled on the other side. A handler reads its call as
  `RPCHandler.currentCall` (`RPCSession.currentCall` for a runtime
  handler), an `RPCCall` with `deadline`, `timeLeft`, `cancelled`, `reason`
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
  `up`.
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
- Hooks: `RPCHandler.beforeCall` and `afterCall`, and for runtime handlers
  `RPCSession.beforeRuntimeCall` and `afterRuntimeCall`.
- Contracts, handlers and commands classes can extend others of their
  kind.
- A hello as each connection starts: `RPCSession.PROTOCOL_VERSION`,
  `peerVersion`, `peerCapabilities`, `peerCallsFingerprint`,
  `peerAnswersFingerprint` and `onHello`.
- `RPCSession.maxFrameLength` (8 MiB) and `RPCHandler.session`, the
  session whose call is running.
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
  `maxFrameLength`. Negotiated in the hello, so a peer without it gets whole
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
  `tcpUserTimeout`, `connectionParameters` and `libraryPath`; and
  `PostgresConnection.cancel()`.
- SQLite: `attach()`, `detach()`, `loadSchema()` with
  `getSchemaResult()`, and `queueTimeout` (10 s) for an asynchronous
  connection.
- For every driver: `SQLRow` and `executeEach` read a result row by row
  without an object per row; `itemClass` makes each row an instance of a
  class; `crossbyte.db.ITransactionalConnection`.
- `crossbyte.db.ConnectionPool<T>`, which rolls back a transaction left
  open; `crossbyte.db.AsyncDatabase<T>`, which runs work on a worker with a
  bounded queue; and `crossbyte.db.SchemaMigrator` for versioned
  migrations.
- Compression: `CompressionAlgorithm.LZ4_FRAME` and `ZLIB`, and
  `ByteArray.uncompress(algorithm, maxOutputSize)`.
- Crypto from libsodium: `Aead` (XChaCha20-Poly1305), `X25519`,
  `KeyExchange`, `GenericHash` (BLAKE2b), `HKDF`, `Argon2id`,
  `ConstantTime.equals` and `SecureMemory.wipe`.
- `PublicKeySignature` and `SignatureKey`: RSA and ECDSA over SHA-256.
- JWT: `RS256`, `ES256` and `EdDSA` signers; `JWKSet` and `JWK`;
  `JWT.verify`, which says why a token was refused (`JWTRejection`);
  `maxTokenLength`, `acceptedTypes`, `requireType` and `updateKeys`; and
  claims of your own (`claim`, `hasClaim`, `setClaim`).
- `BCrypt.hashAsync` and `verifyAsync`, the same on `Argon2id`, and
  `dummyHash` on both. Argon2id also runs on Node 24.7 and later.
- `SecureRandom.isSupported`, and `SecureRandom` on Node and in a browser.
- `SecureRandom.fill(bytes, offset, length)` fills part of a `ByteArray`
  you keep, allocating nothing natively and on Node; a WebSocket client
  draws its frame masks into a pool it keeps this way.

#### Platform

- Node runs `Socket`, `ServerSocket` (with TLS), `WebSocket`,
  `ServerWebSocket`, `DatagramSocket`, reliable UDP, `HTTPServer`,
  `NetConnection`, `NetHost`, RPC, `NativeProcess`, `FileStream` and
  `URLLoader`; an `Application` drives itself there and in a browser.
- The jvm has TLS (with ALPN, SNI and client certificates) and runs the
  whole suite; HashLink and Neko build and run it too.
- `crossbyte.io.Store`: durable key/value storage on every target,
  IndexedDB in a browser and files elsewhere.
- `crossbyte.sys.ProcessLifecycle`: graceful shutdown on SIGINT, SIGTERM
  and SIGHUP, Windows console events, and the Windows Service Control
  Manager (`installServiceControl(name)`). The `windows-service` sample
  shows a server draining on `sc stop`.
- `System.applicationId`, set with `-D crossbyte_app_id`, names an
  application's storage directory.
- `File.openWithDefaultApplication()`.
- `SharedObject.remove(name)` and `SharedObject.lockTimeout`;
  `LocalConnection.maxQueuedBytes` (16 MB) and `bytesPending`.
- `NativeProcess` on the jvm, hl and neko.
- Test harnesses: a load and churn harness (`ci/load.hxml`), a soak
  (`ci/soak.hxml`), fuzzing of the wire parsers, a performance suite and
  allocation budgets. `docs/testing.md` describes them.

### Changed

Entries marked "(Upgrading)" can need code changed; the Upgrading section
says how.

#### Runtime

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
- Dispatching an event costs about half what it did, and adding or removing
  a listener copies the list only while a dispatch is walking it.
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
  vectors. (Upgrading)
- `SlotHandle` carries 20 index bits and 11 generation bits, and `SlotMap`
  and `PackedSlotMap` reuse the slot freed longest ago, so a stale handle
  no longer comes to name a new entity within seconds. (Upgrading)
- `ObjectPool` keeps at most `maxFree` free objects, 10,000 unless set.
  (Upgrading)
- `TaskPool.submit` returns `Task<Any>`, `UncaughtErrorEvent.origin` is
  `Any`, and `EnumUtil`, `ListedMap.KeyValuePair` and `Object.entries()`
  use classes rather than anonymous structures. (Upgrading)
- On JavaScript, text is encoded and decoded through the platform's
  `TextEncoder` and `TextDecoder`, about ten times faster, and a NUL byte no
  longer ends a string read from bytes (on HashLink too).
- `ByteArray.writeUTFBytes` writes ASCII text without making bytes of it
  first: natively by one copy, and on the jvm a character at a time for
  text of up to 256 characters.

#### TCP

- A URI that `NetConnection`, `NetHost` or `parseURL` cannot use throws an
  `ArgumentError` naming it, with what is wrong or the schemes that would
  work, where it threw a bare string such as "Protocol error" or
  "missing host". (Upgrading)
- On the jvm under Java 8 a select allocates nothing: the selector puts
  the sockets it finds ready in an array CrossByte gives it, as Netty
  does, where it added each to a set. A TCP echo, a datagram and a
  reliable UDP message allocate 0 to 48 B where they took 72 to 160.
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
- `Socket.close()` sends what was written before it, and a `Socket.timeout`
  of 0 is no deadline natively too, as on Node.
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

- A session sends at the rate the path carries: a retransmission timeout
  measured as RFC 6298 has it (200 ms to 10 s), a window that starts at ten
  frames and halves on loss, selective acknowledgements with RACK loss
  detection (RFC 8985) and a tail probe. Frames a pass produces go out
  bundled, and sessions ask for a megabyte of socket buffer each way
  (`WINDOW_BUFFER_SIZE`). Natively over loopback, 1,000-byte messages
  under 1% loss went from 0.35 to 58 MB/s, and 100-byte messages from
  45,000 to 258,000 a second.
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
- A `timeout` of 0 is no deadline, where it failed the attempt at once.

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
- On the jvm, framing and masking a message boxes nothing: a 100-byte
  echo allocates 396 B where it took 428.
- A `wss://` client checks the server's certificate. (Upgrading)
- A client's failed connect ends one way: `ioError`, then `close` with 1006.
  Its `timeout` bounds the whole connect: lookup, TCP, TLS and upgrade.
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
- `URLRequest.idleTimeout = 0` is no idle limit natively too. (Upgrading)
- `OAuth.getAccessToken` and `refreshAccessToken` go through `URLLoader`,
  so they no longer block the runtime. (Upgrading)
- The native client's process-wide limits (`Http.MAX_*`) are per-request
  settings on `URLRequest`. (Upgrading)

#### RPC

- An RPC session over reliable UDP no longer copies each message that
  arrives: the connection hands a reader that keeps nothing (a session
  reading its frames) the message itself. An RPC call there and its answer
  allocate nothing natively or on the JVM, where they allocated 344 and
  168 bytes.
- A frame larger than its reader takes is refused and read past, and the
  connection goes on: a call past the reader's `maxFrameLength` or past what
  its TCP socket holds (`maxInputBufferSize`), which waited for good there,
  fails `RPCFailure.TooLarge` at once, as does an answer past the caller's
  limit, or past what the answering side's local IPC carries. A call over a
  WebSocket larger than 64 KiB goes as several messages, where one past the
  peer's 1 MiB `maxMessageSize` closed the connection; one over reliable UDP
  past its `maxOutputBufferSize`, or over local IPC past its 8 MiB message,
  fails `Unsent` as it is made, where it ended the session or went nowhere.
  A frame past the reader's `maxFrameLength` ended the connection.
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
- `SQLiteConnection.busyTimeout` is 5 seconds as a connection opens.
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
- Off native cpp, crypto and IPC classes throw `IllegalOperationError`.
  (Upgrading)
- libsodium built by gcc and clang uses 64-bit arithmetic and the CPU's SIMD
  code (X25519 41 to 24 µs, Argon2id at its interactive limits 72 to 45 ms),
  BLAKE3 uses SSE2, SSE4.1 and AVX2 (977 to 3,459 MB/s), and natively
  `SecureRandom` draws small amounts from a per-thread pool.

#### Platform

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
- `removeEventListener(type, this.handler)` removes the listener on eval and
  the jvm, where a bound method never compared equal.
- A `Task` made on a thread with no runtime always calls its handlers, a
  `Worker` cancelled after its work completed ends `CANCELLED`, and a
  throwing task listener no longer stops the others.
- `pump()` on a runtime that has exited no longer claims the calling thread.
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
  `position`.
- The varint writers write every 32-bit value (bit 31 set went out as one
  byte), and the readers refuse a value past 32 bits.
- `writeUTF` refuses a string over 65,535 bytes with a `RangeError`, where
  the length wrapped.
- `ByteArrayOutput` grows in every writer, and `reserve` no longer
  reallocates on every call.
- `EOFError` keeps the message it is given, and `Error.getCallStack()`
  returns the error's own stack.
- `ListedMap`, `DenseSet`, `OrderedMap`, `IndexedMap` and `PackedSlotMap`
  can have the entry a loop is on removed.
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
- `PrimitiveValue.toInt`, `Version` and every number a peer sends are read
  the same way on every target, through `IntParse`.
- `GlobalTimer` hands out unique ids on every threaded target.
- On the jvm, `PriorityQueue`, `SwitchTable.make` with mixed keys, and
  `Vector`'s `every`, `some` and `filter` work.
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
  `addSNICertificate`, `setALPN`, `requireClientCertificate`), which
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
- The client honours `idleTimeout` in milliseconds (the default 30 s waited
  over eight hours), holds a response's header section to 64 KB, refuses a
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
- `onHandlerError`'s default report says a handler that ran out of time
  (its `handlerTimeout`, or a call it forwarded) did not answer in time,
  where it said the handler threw.
- A frame that names a count or length larger than itself is refused before
  anything is allocated, and a frame too short for what it carries no longer
  reads into the next frame.
- A call fails when its connection closes or cannot carry it, where it
  waited for good; its `cause` is the connection's `Reason`.
- The heartbeat no longer closes healthy connections: pings were never
  answered.
- A method returning `Null<T>` answers correctly, where the first answer that
  was not null closed the connection.
- A call to a session with no handler is answered rather than left
  waiting, and a frame over `maxFrameLength` is refused before it is sent.
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
- JWT times past 2038 are judged the same on every target; `verifyToken`
  accepts any `typ` in `acceptedTypes` (`JWT` and `at+jwt`) and none;
  `secureCompare` answers `false` for a null; a header with `crit` is
  refused; and a deeply nested token no longer ends the process.
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
  like `/root` work; and failures are `IOError`s with AIR's error numbers.
- `File.createTempFile` and `createTempDirectory` use unguessable names and
  create exclusively, so another user cannot steer them.
- `Resources` reads only inside `resourcesDir`. (Upgrading)
- `FileStream`: reads and writes keep the `IDataInput` contract in both
  modes, `endian` and `position` mean the same opened either way,
  `truncate()` truncates in place, `UPDATE` mode reads back on macOS, an
  asynchronous read hands out only what it has read, and `readObject` reads
  one object. A short `readBytes` throws `EOFError`. (Upgrading)
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
- Native builds on Linux and macOS compile cleanly, and `-D final` builds
  compile.
- No `trace` calls remain in library code.

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
- Natively on Linux and macOS a process raises its soft limit on open
  descriptors to its hard limit as it starts, and the children it starts
  inherit that: build with `-D crossbyte_keep_nofile` to keep the limit it
  was started with, for children that `select()` on descriptors under
  1,024.
- A native Windows build runs at the priority it was started with; set
  `CrossByte.windowsHighPriority = true` for the high class it took itself.

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
- `HostApplication.advance` and `CrossByte.pump` no longer rethrow what a
  handler threw during the step: listen for
  `UncaughtErrorEvent.UNCAUGHT_ERROR` where code caught failures around
  them.
- On the jvm, the interpreter, hl and neko, `CrossByte.current()` on a
  thread no runtime belongs to throws `IllegalOperationError`, where it
  returned the primordial runtime. Capture the runtime on its own thread and
  hand work to it with `CrossByte.post`.
- `CrossByte.pump` is two inline overloads, and `GlobalTimer.setTimeout`
  and `setInterval` are overloads too: every call compiles as it did, but
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
- `EnumUtil.getValue` is an `Array<Dynamic>`; `getNameValuePair` and the
  `KeyValuePair`s of `ListedMap`, `OrderedMap` and `Object.entries()` are
  classes, so code that builds one from another anonymous type, rather than
  a literal, constructs it instead.
- `SlotHandle` no longer becomes an `Int` by itself: use `handle.index()`
  for the slot and `handle.toInt()` for the whole handle. It has 20 index
  bits, so a `SlotMap` or `PackedSlotMap` holds at most 1,048,576 entries
  (it held 16,777,216), and one made with a larger `maxCapacity` throws.
- An `ObjectPool` keeps 10,000 free objects unless told otherwise: set
  `maxFree` to `0x7FFFFFFF` for no bound, as before. A negative `maxFree`
  throws an `ArgumentError`.
- `ThreadEvent.UPDATE` is gone; nothing dispatched it.
- `Random.seed` is no longer public: set the shared seed with
  `Random.reseed(value)`.
- A `Dynamic` value no longer converts to a `URL` on its own: cast it,
  `(value : String)`, or build `new URL(value)`.

#### TCP

- Code that caught a `String` from `new NetConnection(uri)`, `new
  NetHost(uri)` or `parseURL` catches a `crossbyte.errors.ArgumentError`.
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
  `(get, set)` and adds `refusedConnections`, `canDial`, `dial`,
  `discoverPublicAddress`, `localAddressFor`, `allocateRelay`,
  `dialRelayed` and `permitRelayedPeer`. A host that cannot dial from its
  listening endpoint answers `canDial` false, throws
  `IllegalOperationError` from `dial`, `dialRelayed` and
  `permitRelayedPeer`, and fails the `Future`s of `discoverPublicAddress`
  and `allocateRelay`.
- A `NetConnection` whose TCP connect fails calls `onClose` after
  `onError`, and `onClose` after an error is given the error's reason; a
  WebSocket connection closed by its peer reports `Reason.Code` with the
  close frame's code and reason, where it reported `Reason.Closed`. Code
  that took `onClose` to mean a connection had been up checks for
  `onReady` instead.
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
  `HTTPBackend` reads them, and `headTimeout`, from its
  `HTTPRequestContext`.
- `URLRequest.idleTimeout = 0` is no idle limit natively too, where it was
  30 seconds.
- A load fails once it has waited its `idleTimeout` for one of
  `URLLoader.maxConcurrentLoads` (16) threads, and a response's head must
  arrive within `URLRequest.headTimeout`, five minutes, of its request.
  Raise `maxConcurrentLoads` or `idleTimeout` for many slow loads at once,
  and `headTimeout` with `idleTimeout` for a long poll held longer than
  five minutes.
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

#### Data

- Counts and ids are `Float`s, exact past 2^31: `lastInsertRowID`,
  `totalChanges` and `DBStats`' page counts of `SQLiteConnection`;
  `affectedRows` and `lastInsertRowID` of `MySQLConnection`,
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
- A `SQLiteConnection` waits up to 5 seconds for another connection's
  write lock, `busyTimeout` as it opens, where it failed at once with
  "database is locked". On a synchronous connection the wait is on the
  calling thread: set `busyTimeout = 0` where failing at once is wanted,
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
  they threw a String or an `ArgumentError`. Check `isAvailable()` or
  `isSupported` first.
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
  `SecurityError`. Name resources relative to `resourcesDir`.
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
  `lockTimeout` (five seconds), where they waited without end; set
  `lockTimeout` to 0 to keep waiting. `sync()` throws an `IOError` for a
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
