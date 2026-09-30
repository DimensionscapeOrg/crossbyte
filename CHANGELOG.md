# Changelog

All notable changes to CrossByte will be documented in this file.

## Unreleased

### Added
- A TURN relay reached over TLS (`TurnTransport.TLS`), natively, on the jvm
  and on Node, for `ReliableDatagramServerSocket.allocateRelay` and
  `PeerConnection.gatherRelayedFrom` alike. It was refused, saying a plain
  `Socket` could not start TLS; a client `Socket` can now. The relay's
  certificate is checked against the name it was given, trusting the
  system's authorities or one named in `TurnClient.certAuthority`,
  `TurnServer.certAuthority` or `ReliableDatagramServerSocket.
  relayCertAuthority`; `TurnClient.verifyCert` turns the check off.
- TLS settings per request: `URLRequest.verifyCert`, `certAuthority`,
  `clientCertificate` with `clientKey`, and `pinnedPublicKeys` (RFC 7469
  `pin-sha256` digests, with or without `sha256/`). Trusting a private
  authority meant setting a process-wide static through `@:privateAccess`,
  and there was no way to present a client certificate or to pin a key.
  A kept connection, HTTP/1.1 or HTTP/2, is reused only by a request with
  the same settings, so one opened without checking its server never
  carries a request that checks. The client certificate is left behind by
  a redirect to another origin, as `Authorization` is. A pin is checked
  after the handshake and before anything is sent, whether or not the
  chain is, natively, on the jvm and on Node; hl, neko and a browser
  cannot see the server's key, and refuse a pinned request rather than
  send it unchecked. neko's TLS checks the server whatever it is told, so
  `verifyCert = false` changes nothing there. `HTTPTLSOptions` carries the
  settings, and `HTTPRequestContext.tls` hands them to an `HTTPBackend`.
- `URLRequest.maxDecompressedSize`: the most a compressed response may
  decode to before the load fails, 64 MB unless set, per request. The
  ceiling was an internal static of the native client, one number for every
  request, while what a response sends and what it decodes to have no fixed
  ratio. `HTTPRequestContext.maxDecompressedSize` hands it to a backend,
  and the HTTP/2 backend holds to it.
- `HTTPServerConfig.compression`, an `HTTPCompression`: whether the server
  compresses (`enabled`), from what size (`minimumSize`, 1 KB), which
  `Content-Type`s (`types`), and how hard (`level`, Brotli's 0 to 11). A
  static file is compressed once per coding and kept, up to `cacheSize`
  (16 MB), while its size and modification time hold, it was compressed
  again for every request, and a 150 KB script served 64 requests a second
  as Brotli natively against 863 as it was, and a precompressed
  `app.js.br` or `app.js.gz` beside `app.js` is sent in its place when it
  is not older (`precompressed`), which is also how a file large enough to
  stream goes out compressed.
- `crossbyte.sys.System.sleep(seconds)`, a sleep that comes back on the
  interpreter on Windows, where `Sys.sleep` can sleep for 49 days: eval
  times a `Thread.yield()` in the process's CPU time, which Windows counts
  in 15.6ms ticks, and sleeps for what is left, and a tick inside the yield
  leaves a negative remainder that OCaml's `Unix.sleepf` hands to `Sleep()`
  as an unsigned count. With a second thread busy, a loop of
  `Sys.sleep(0.001)` hung in one run of three and `System.sleep` in none.
  Every sleep in the library, the tests and the samples goes through it
  now, the runtime's frame loop, `ConnectionPool`, `FileStream`,
  `FileStore`, `LocalConnection`, `NativeProcess`, `ProcessLifecycle` and
  the tests' pump loops were what hung the interpreter suite, in a
  different test each run, and a suite build fails on any other call to
  `Sys.sleep`.
- `SwitchTable.make` takes any expression as a key, `Opcode.PING`, a
  variable, where it took only literals, refuses two literal keys that are
  the same, and takes a fallback, `(key, args) -> ...`, for a key no case
  matches. Without one it still throws, now naming the key.
- `RadixTree.longestPrefix` and `longestPrefixLength`: the longest key held
  that a string starts with, and its length, the route that serves
  "/api/v1/users/123" when "/api/v1/users" is held. The tree could only
  answer exact keys.
- `crossbyte.ds.IdList`, a list of `Int` ids that holds them unboxed and
  keeps its storage when emptied, and the queries that fill one:
  `SpatialGrid.queryCircleIds` and `queryRectIds`, `SpatialGrid3D.
  querySphereIds` and `queryBoxIds`. `InterestSet.addAll` takes one. A query
  into an `Array<Int>` boxes every id above 127 on the jvm, and an array
  emptied with `resize(0)` hands V8 its storage back, so the interest loop
  the documentation showed allocated 2.2 MB a tick for 1,000 views of 50 on
  either; through an `IdList` it allocates nothing on the jvm and Node, and
  natively it went from 1.28 to about 1.0 ms a tick.
- `crossbyte.ds.IntPriorityQueue`: a priority queue of `Int` ids, each held
  with a priority given when it is enqueued, lowest first, equals in the
  order they came. `PriorityQueue<Int>` does not compile, its elements being
  objects, so a matchmaker keyed on player ids had no queue to use. It calls
  no comparator and looks nothing up while sifting, so it allocates nothing
  per operation on any target, and it keeps its own id table: the jvm's
  `IntMap` visits every bucket to find a missing key, which made 50,000 ids
  take a second there rather than 10 ms.
- A MongoDB client that speaks the server's wire protocol over CrossByte's
  own sockets, on hxcpp, the jvm, the interpreter, hl and neko. MongoDB was
  listed among CrossByte's databases and could be reached from none of
  them: `MongoConnection` went through PHP's extension, embedded in a Haxe
  string that had not compiled since a3239a7. It now opens a `mongodb://`
  string or a config, several hosts, a secondary followed to its primary,
  TLS with a CA file or a client certificate, says hello over OP_MSG, and
  signs in with SCRAM-SHA-256 or SCRAM-SHA-1, their first step riding on
  the hello, or with X.509 or PLAIN. It has `insert` (batched to the
  server's limits, an `ObjectId` made for a document without an `_id`),
  `find`, `findOne`, `update`, `delete`, `aggregate`, `count`,
  `createIndexes`, `drop` and `runCommand`; `MongoCursor` fetches with
  `getMore` as it is read, and `close` sends `killCursors`; write concern
  is per connection or per write. `begin`, `commit` and `rollback` run a
  transaction on the connection's session, and `MongoConnection` is an
  `ITransactionalConnection`, so a pool rolls back one a borrower leaves
  open. A refusal is a `MongoError`, an `SQLError` with the server's code
  in `errorID`, its `codeName`, labels and write errors; a lost connection
  is an `IOError`. Like the other drivers it blocks, for a worker, and it
  is not built for JavaScript. Not done: `mongodb+srv://`, compression,
  retryable writes, and reads from secondaries.
- `crossbyte.db.mongodb.bson`: BSON, encoded and decoded on every target,
  the browser included, double, string, document, array, binary with its
  subtype, ObjectId, bool, UTC datetime, null, regex, JavaScript, int32,
  timestamp, int64 and Decimal128, the last two exactly, and MinKey and
  MaxKey. A `Date` goes out as a BSON date, which is what a TTL index acts
  on; `BsonDateTime` holds one exactly on hl and neko too, where `Date`
  keeps whole seconds between 1901 and 2038. `BsonDocument` keeps its
  field order, which a command, a sort and an index key depend on and an
  anonymous object does not keep on most targets. `ExtendedJson` reads and
  writes MongoDB Extended JSON v2, binding `:name` placeholders as values.
- `StunClient` asks through a socket it is given, and classifies the NAT in
  front of it. `discover` takes the `DatagramSocket` to ask through,
  bound, and left open and as it was found, so the answer describes the
  mapping of the socket an application actually uses. Each question used
  to bind a socket of its own, so it answered for a port nothing used, and
  comparing what two servers saw compared two mappings: every NAT, and
  loopback too, read as symmetric. `classifyMapping` and
  `classifyFiltering` run RFC 5780's tests through one socket against a
  server with a second address, answering with a `NatBehavior`, and
  `probe` asks one RFC 5780 question, a CHANGE-REQUEST in, OTHER-ADDRESS,
  RESPONSE-ORIGIN and where the answer came from out, as a `StunProbe`,
  for the tests those two do not run. A server that gives no OTHER-ADDRESS,
  or ignores CHANGE-REQUEST, is reported as unable to classify rather than
  read as a NAT that lets everything in.
- TURN over TCP, IPv6 relays, and RFC 8489's credentials. `TurnClient`
  takes a `TurnTransport`: over TCP or TLS it frames every message for a
  stream (RFC 8656 section 3.1), `receiveStream` takes what arrives,
  split anywhere, and `streamClosed` ends the allocation with the
  connection, and sends each request once, waiting RFC 8489's 39.5
  seconds, since a stream does not lose it. `PeerConnection.gatherRelayed`,
  a `TurnServer`'s `transport` and `ReliableDatagramServerSocket.allocateRelay`
  reach a relay over TCP for a network that lets nothing else out; what
  the relay relays is UDP either way. TLS is framed the same, and needs a
  TLS stream the caller holds, since a plain `Socket` does not start TLS on
  every target. `requestIPv6` asks for an IPv6 relayed address
  (REQUESTED-ADDRESS-FAMILY), whose peers are IPv6 and are written with the
  transaction as RFC 8489 has it. A relay offering password algorithms is
  answered with SHA-256 keys and MESSAGE-INTEGRITY-SHA256 alone, one
  offering username anonymity with USERHASH in place of USERNAME, and one
  whose nonce offers algorithms on an answer that lists none, the list
  stripped on the way, a downgrade, is not answered at all. The SHA-256
  arithmetic is pinned to values computed with Node's crypto.
  `StunMessage` gains the attributes, `ipv6Bytes` and `canonicalIPv6`,
  and IPv6 in `xorMappedAddress`, `xorPeerAddress` and `xorRelayed` given
  the transaction id.
- Reliable datagram sessions can fall back to a TURN relay, for the peers
  hole punching cannot reach, a symmetric NAT or a carrier's CGNAT at
  either end. `ReliableDatagramServerSocket.allocateRelay` asks a relay for
  an address through the port the server listens on; `relayedCandidate` is
  that address for the peer to be told of, `connectRelayed` opens a session
  that reaches its peer through the relay, a CONNECT arriving through it
  opens one that answers the same way, and `permitRelayedPeer` lets a peer
  that dials first through. An attached `IceAgent` checks from the relayed
  candidate too, and no longer takes STUN that is not a connectivity check,
  it took every STUN message on the socket, a relay's answers included.
  A relay that goes away closes the sessions through it, each with an
  `ioError` saying so; `releaseRelay` frees it. `NetHost` reaches all of
  this through `allocateRelay`, `dialRelayed` and `permitRelayedPeer` on a
  reliable datagram host. And for a protocol of the application's own on
  the same port, `onDatagram` sees every datagram before anything else
  does, and `sendDatagram` answers from the port: there was no way in,
  since everything that was not a reliable frame was dropped as noise.
  `TurnClient.sendTo` takes an offset and a length.
- `PeerConnection.gatherRelayedFrom(servers)`, which asks each TURN relay in
  a list in turn until one lends an address, and keeps one for as long as
  the connection lasts: a relay that loses the allocation is replaced from
  the list and the new relayed candidate announced through
  `onLocalCandidate`, and `restartIce` asks the relay whether it is still
  there, a network change costs the allocation, and replaces one that is
  not. `setRelayCredentials` renews the credentials relays are asked with,
  for the TURN REST convention's expiring ones. A failed gather's `cause` is
  a `TurnError`, the relay's code, its reason, and where a 300 pointed,
  where it was a sentence with no code in it. Underneath: `TurnClient`
  follows 300 Try Alternate to the server it names (once per server, so two
  relays redirecting to each other cannot hold it), and gains
  `setCredentials`, `refresh` and `failure`.
- TLS for a client `Socket`: set `secure` before `connect()` and the socket
  handshakes once TCP is up, stepped as the server's flights arrive, and
  dispatches `connect` when the handshake is done, within `timeout`,
  which counts it, on native, jvm and Node; on eval the handshake blocks,
  as eval's connect does. `secure` was read only to report it, so a client
  asking for TLS spoke plain TCP. `verifyCert` and `certAuthority`, which
  were `WebSocket`'s, are `Socket`'s now and check a secure socket's server
  the way they check a `wss://` one: a certificate from an authority the
  client does not trust, or naming another host, is refused with an
  `ioError` that says so. On Node, a socket a TLS `ServerSocket` accepted
  says it is `secure`, and a socket's `ioError` carries Node's reason.
- permessage-deflate (RFC 7692) for WebSocket, opt in with
  `ServerWebSocket.perMessageDeflate` or, on a client, with
  `WebSocket.perMessageDeflate` before `connect()`. A server declined every
  browser's offer, so an 18 KB JSON snapshot went out at 5.7 times its
  deflated size, and a compressed frame closed the connection with 1002.
  Each message is compressed on its own, both ways: a server answers an
  offer with `server_no_context_takeover; client_no_context_takeover`, and
  a client asks for the same, refuses an answer that keeps a context it
  cannot inflate, and sends uncompressed to a server that did not agree to
  inflate each of its messages alone. Messages shorter than
  `compressionThreshold` (1024 bytes by default) go as they are, and so
  does one that compressing did not shrink; `WebSocket.compressed` says
  whether a session agreed. What arrives compressed is inflated under
  `MAX_MESSAGE_SIZE`, and a message inflating past it is refused with 1009.
- `HTTPRequestContext.followInsecureRedirects`, `manageCookies` and
  `onRedirect`, all optional, so an `HTTPBackend` can follow redirects by the
  built-in client's rules and say where its response came from. The bundled
  HTTP/2 backend uses them.
- PKCE for OAuth (RFC 7636): `OAuth.createCodeVerifier()`,
  `OAuth.codeChallenge(verifier)`, a `codeChallenge` argument to
  `getAuthorizationUrl`, sent with `code_challenge_method=S256`, and a
  `codeVerifier` argument to `getAccessToken`. There was nowhere to put
  either, and PKCE is what keeps an intercepted authorization code from
  being exchanged by someone else. A client with no secret no longer sends
  an empty `client_secret`, which some providers refuse. `OAuth.timeout`
  (30 seconds) bounds each exchange and refresh.
- JWT payloads carry claims of an application's own. A literal can hold
  them beside the registered claims, `{sub: id, exp: now + 3600, role:
  "admin"}`, and `JWTPayload.claim(name)`, `hasClaim` and `setClaim`
  read and set them. That literal failed to compile with "has extra field
  role", so a role or a tenant went in through `Dynamic`. `sub` and `iat`
  are optional, so a refresh token without a subject can be made too.
- `JWT.verify`, which answers with a `JWTVerification`: the claims, or a
  `JWTRejection` naming the first check the token failed,
  `malformed`, `too-large`, `unsupported-algorithm`,
  `algorithm-mismatch`, `type-not-accepted`, `unknown-key`,
  `bad-signature`, `missing-expiry`, `expired`, `not-yet-valid`,
  `issued-in-future`, `wrong-issuer` or `wrong-audience`. `verifyToken`
  answered all of them with the same `null`, so an expired session and a
  forged token looked alike in a log. With it: `JWT.maxTokenLength`, the
  cap on what is parsed, which was a fixed 4096 characters and still
  defaults to that; `JWT.acceptedTypes` and `JWT.requireType`, for which
  `typ` headers pass; and `JWT.updateKeys`, which swaps a verifier's keys
  and keeps its other settings, where rotating keys meant building a new
  `JWT`. `JWKSet.signer(RS256)` turns a fetched key set into what
  `updateKeys` takes, and `unknown-key` is the cue to fetch it again.
- `crossbyte.crypto.SignatureKey`: an RSA or EC key parsed once into
  mbedTLS and held natively, with `sign`, `verify`,
  `joseSignatureLength` and `dispose`. For a key used more than once,
  which `PublicKeySignature`'s PEM-taking functions parse every call. The
  parsed key is wiped and freed when the object is collected, or at once by
  `dispose`.
- `BCrypt.hashAsync` and `verifyAsync`, and `Argon2id.hashAsync` and
  `verifyAsync`, which hash on a `TaskPool` worker and answer with a
  `Future`, completed on the calling runtime's thread at its next tick. A
  hash at the recommended cost holds its thread for 50 to 300 ms, so a
  runtime verifying sign-ins itself served nobody else meanwhile, and about
  eight a second filled it. They use a pool of two workers the hashers
  share, started on first use, or the pool passed in. `BCrypt.dummyHash`
  and `Argon2id.dummyHash` give a hash to verify against when a sign-in
  names a user that does not exist, so it takes as long to refuse as a
  real user's wrong password and the timing does not say which names are
  registered.
- Argon2id on Node 24.7 and later, through Node's own `crypto.argon2`,
  checked for rather than assumed. Its hashes and libsodium's verify in
  each other, and on Node `hashAsync` runs on libuv's thread pool.
- `AsyncDatabase.maxQueued` and `queueTimeout`, and backlog metrics. With a
  worker per pooled connection, what `AsyncDatabase.of` builds, a job
  never waits for a connection, so the pool's acquire timeout and wait
  metrics never fire: all the waiting happens in the worker pool's queue,
  which had no bound, no deadline and nothing measuring it, so a database
  slower than the traffic showed up only as memory and latency growing
  together. `maxQueued` makes `submit` throw once that many jobs are
  waiting; `queueTimeout` fails a job that waited longer than that for a
  worker, without running it or taking a connection. Both are off by
  default, since a batch submitting thousands of statements at once is a
  legitimate use of the queue; a server should set them. Given a
  `Metrics` registry, `AsyncDatabase` publishes `db_async_queued`,
  `db_async_running`, `db_async_queue_wait_seconds`, and the
  `db_async_rejected_total` and `db_async_expired_total` it turned away.
- `ConnectionPool` rolls back a transaction left open on a connection as it
  is released, including by `withConnection` after its body threw,
  before anyone else can take it. A body that began a transaction and then
  failed returned its connection still inside it, so the next borrower's
  writes joined that transaction and its locks stayed held, and `validate`
  could not tell, since an open transaction answers a ping. It applies to a
  connection implementing the new `crossbyte.db.ITransactionalConnection`,
  as `PostgresConnection`, `MySQLConnection` and `SQLiteConnection` now do,
  and needs no configuration; a rollback that fails retires the connection.
  A connection released with its transaction open is also logged as a
  warning under `db.pool`, since that is a bug in the caller, unless
  `withConnection` is returning it after its body threw, which has its own
  error, and each such rollback is counted in
  `db_pool_rollbacks_on_release_total`. `ConnectionPoolOptions.reset` runs
  after it on every release, for the rest of a session's state (`DISCARD
  ALL`, say); a reset that throws retires the connection too, counted with
  the reason `failed_reset`.
- `PostgresConfig.statementTimeout`, `keepAliveIdle`, `keepAliveInterval`,
  `keepAliveCount`, `tcpUserTimeout` and `connectionParameters`, and
  `PostgresConnection.cancel()`. Nothing could bound a PostgreSQL statement:
  no timeout, no way to cancel one, and no way to hand libpq a setting the
  config did not name, so a database host that vanished mid-query was
  noticed only when TCP gave up, about two hours later. `statementTimeout` is
  sent as `statement_timeout` when the session starts, so it costs no round
  trip; the keepalive settings and `tcpUserTimeout` let a dead peer be
  noticed in seconds; `connectionParameters` passes any other libpq keyword
  through, quoted. `cancel()` asks the server to stop the statement a
  connection is running, and is safe from any thread, which is where it is
  needed, since the thread that sent the statement is waiting for its
  answer. Defaults are unchanged. Native driver only.
- `CrossByte.loopLag`, `frameOverruns`, `droppedScheduleDebt` and
  `postQueueDepth`: how far past its deadline the last frame ended, how many
  frames have outrun their tick, how many seconds of schedule the loop has
  given up after stalls too long to repay, and how many posted callbacks
  are waiting to run. With `timerBacklog`, `timerLag` and `timerOverruns`
  they say whether a runtime is keeping up; nothing did before. Each costs
  the loop a clock read a frame at most.
- `Logger` categories and a record sink. `Logger.category("http.access")`
  returns a logger whose level `Logger.setLevel("http.access", level)` sets
  apart from the global one, inherited along the dots (`http` covers
  `http.access`), and `Logger.log` takes a category too. A categorised
  record names it, `[INFO] [http.access] ...`, or `"category"` in JSON.
  `Logger.recordSink` receives each record whole: level, category, message,
  fields, time and the formatted line, where `sink` only ever saw the line
  and could not tell an error from a debug record. A category's level is
  cached, so a record below it costs a comparison. The runtime logs the
  failures it contains under `runtime`.
- `CrossByte.post(callback)`: runs `callback` on the runtime's own thread,
  safe to call from any thread, and wakes the runtime for it. It was
  `__post`, marked internal although it is the one way to hand a runtime
  work from another thread; `__post` still works. Returns `false` once the
  runtime has exited, when the callback would never run.
- `CrossByte.make(loopType, timers, configure)`: a callback run with the new
  child runtime, on the calling thread, before the child's thread starts,
  the place to set `tps` and add `INIT` and `EXIT` listeners. The thread
  used to start inside `make()`, so anything done to the returned runtime
  raced its first frame, and an INIT listener added afterwards could miss
  INIT.
- ICE restart for WebRTC connections. A browser whose network changes
  restarts ICE, new credentials, in a new offer, and they were dropped:
  an agent that had left NEW ignored `start`, so every check afterwards was
  signed with credentials the peer had discarded, and consent ran out half a
  minute later, taking the connection and its channels with it. Now
  `connect` given a description with new credentials restarts this side,
  and `description()` is the answer to send back; a new agent checks with
  the new credentials while the session carries on over the old path, and
  takes it over once it has one of its own. DTLS and SCTP carry on
  untouched. `PeerConnection.restartIce()` starts one from this side, and
  `iceRestarting` says one is under way. The side offering a restart
  controls it, as a browser takes it; an answer to one states this side's
  DTLS role, since a browser refuses `actpass` in an answer; and a
  description with another certificate is refused as a new session.
  Checked against Chrome, started from either side, on a socket of its own
  and on a `PeerConnectionHost`.
- `PeerConnectionHost`: many WebRTC peer connections on one UDP port, driven
  by one tick. A `PeerConnection` binds a socket of its own, and with it a
  port, that socket's buffers and a tick listener, so a server holding ten
  thousand browser peers held ten thousand of each and had to open a port
  range as wide as its peak. `host.createConnection(isOfferer)` makes a
  connection that shares the host's socket instead and is otherwise used
  the same way. The host routes a browser's checks by the ufrag they name,
  the answers to a connection's own checks by their transaction, and DTLS
  by the address that connection proved a path to, never by one it only
  sent to, so a peer listing another's address as its own cannot take that
  peer's traffic. `addLocalCandidate` gives every connection the host's
  public address. A hosted connection gathers no reflexive or relayed
  address of its own, that socket's mapping being every connection's. An
  idle tick measured natively went from about 120 ns a connection to about
  8, with 300 connections. Checked against Chrome in both directions. The
  socket reads at most 64 datagrams each time the runtime services it,
  which the DEFAULT main loop does once a tick, so a busy host wants the
  POLL main loop.
- Partially reliable WebRTC data channels, RFC 3758 with RFC 8832's channel
  types: what a game's state channel is, since a position that arrives late
  is worth less than the next one. `PeerConnection.createDataChannel` takes
  `maxRetransmits` or `maxPacketLifeTime`, as a browser's does, and
  `DataChannel` reports both. A message past its limit is given up on and a
  FORWARD TSN moves the peer past it, rather than everything behind it on
  the stream waiting; one whose time runs out before it is sent is dropped
  unsent. Until now a browser's `{ordered: false, maxRetransmits: 0}`
  channel was quietly made reliable: the association never said it
  understood FORWARD TSN, so the browser could give up on nothing it sent
  here, and DCEP's channel type and reliability parameter were read and
  dropped, so what this end sent back was retransmitted like everything
  else. Both ends now say so in INIT and INIT ACK, the terms are honoured
  in both directions, and a peer's FORWARD TSN is followed: an ordered
  stream skips what was given up on, and part of a message given up on is
  dropped. A peer that does not say it understands FORWARD TSN gets
  reliable channels, as RFC 8831 has it. Checked against Chrome both ways:
  each gives up on a message the other lost, and the other delivers the
  rest in order.
- `LocalConnection.maxQueuedBytes`, the most a connection holds in each
  direction, 16 MB by default, two frames of the largest size, and
  `bytesPending`, what `send` has queued that the peer has not taken yet.
  A sender with more than that to send at once paces itself on
  `bytesPending`; see the entry under Fixed on a peer that stops reading.
- `RPCSession.dial(uri, ?commands, ?handler)`: a client session that dials
  its server, and dials again whenever its connection ends, at once, then
  after a wait doubling from `MIN_REDIAL` (0.25 s) to `MAX_REDIAL` (30 s)
  while the server stays away, until `close()`. While it is down a call
  through it fails as it is made, with the `Reason` the last connection
  ended with, or the last attempt failed with, as its `cause`. Its
  commands, handler, `data` and heartbeat stay with it across connections.
  A gateway surviving a backend restart built this itself, dial, back
  off, rebind, and check the backend was up before each call, since a call
  on a closed TCP connection threw out of its stub. Every session also has
  `onUp` and `onDown`, told as its connection becomes ready and as one that
  was usable ends, `up`, and `close()`. `NetConnection`'s constructor takes
  a `connectTimeout` for `local://`, whose connect waits on the calling
  thread; a dial makes a single try.
- Deadlines for RPC calls. `RPCResponse.timeout(ms)` gives a call until
  then to be answered, and `RPCSession.callTimeout` gives every call a
  session makes, on either lane, a deadline unless it has its own. Past
  it the call fails with a new `RPCTimeoutError`, an `RPCError`, so a
  handler forwarding it tells its own caller the call timed out, the
  connection is left as it was, and an answer arriving later is dropped.
  A call with no deadline waited for as long as its connection lasted,
  however long its peer took. A call without one arms nothing; one with
  one holds a timer until it is answered. `RPCSession.handlerTimeout`
  bounds how long a call the session's handler answers with a `Future`
  may wait: past it the caller is answered `RPCError.TIMEOUT_MESSAGE`,
  `onHandlerError` and `afterCall` are told, and the call gives up its
  place among `maxCallsWaiting`, where a future that never completed held
  one of the 256 for good.
- `ServerSocket.acceptFailures` and `ServerSocket.handshakeFailures` count
  the connections a server could not take from its listen queue and the
  TLS handshakes that failed or timed out, which left no trace before.
- A WebSocket server sees the request a session was opened by, and decides
  on it. `ServerWebSocket.upgrade(request)` is asked before the `101` goes
  out and can refuse the session, answered with `request.status`, 403
  unless changed, or choose its subprotocol; `WebSocketRequest` carries
  the path, query, headers, cookies, `Origin`, the subprotocols offered and
  the peer's address, and the session keeps it as `WebSocket.request`. The
  request was parsed and thrown away, so a session could not be
  authenticated, a page from another site could not be refused, and a
  browser that offered a subprotocol failed to connect at all: none was
  ever echoed. `WebSocket.protocols` asks for subprotocols from a client
  and `protocol` says which was agreed. `sendText` sends a message a
  browser receives as a string, where everything was binary and reached a
  page as a `Blob`; `sendBinary` sends one at once. A session with a
  listener for the new `WebSocketMessageEvent.MESSAGE` receives each
  message whole, with whether it was text, where messages ran together into
  one stream. `ping()`, `pong()`, `pingInterval` and `idleTimeout` are
  public, on the session and, for the sessions it accepts, on the server.
- A response can be written as it is produced:
  `HTTPRequestHandler.beginResponse(status, contentType, headers)` sends the
  head and returns an `HTTPResponseStream` to `write` or `writeText` the body
  into and `end`. Chunked under HTTP/1.1 (ended by closing for an HTTP/1.0
  client), DATA on a stream held open under HTTP/2. `write` answers `false`
  when the client has more waiting than it is reading, and `onDrain` says
  when to go on; a producer that writes regardless is stopped at
  `maxOutputBufferSize` with an error logged rather than held without bound.
  The handler dispatches `Event.CLOSE` when its client goes, the connection
  closed, or an HTTP/2 stream reset, and `connected` says whether it is
  still there. `respondBytes` sends a body of bytes. `respond` took only a
  String and always a `Content-Length`, so server-sent events, downloads
  produced as they went and binary bodies needed `@:privateAccess`.
- A rate-limited request is answered `429` with a `Retry-After` saying how
  many seconds until it may try again, over HTTP/1.1 and HTTP/2, and the
  limiter can be keyed on something other than the client's address:
  `HTTPServerConfig.rateLimitKey(handler)` names the key a request counts
  against, the address a trusted proxy forwards, an account, or null to
  leave it unlimited. `HTTPRequestHandler.remoteAddress` is public, where a
  route limiting logins per client needed `@:privateAccess` to read it.
  `RateLimiter.secondsUntil(key)` says when a key could spend again, and
  `RateLimiter.addressKey(address, prefixBits)` turns an address into the
  key the server uses, an IPv6 one by its prefix.
- `HTTPServerConfig.maxRequestBodySize`, the request body a server accepts,
  on the wire and once decoded, over HTTP/1.1 and HTTP/2; one megabyte by
  default, as before. It was fixed, and it counted the headers too. A body
  past it is now `413`, refused on its `Content-Length` before any of it is
  read and on a chunk's size line for a chunked one; a `Content-Length` past
  the old fixed limit was answered `400`. A header block has its own limit,
  64 KB, answered `431`.
- `HTTPServerConfig.onExpectContinue(handler)`, asked with a request's
  method, path and headers before a client sending `Expect: 100-continue` is
  told to send its body. Returning `false` after answering, a `401`, say,
  keeps the body from being sent at all. The server used to tell every such
  client to go ahead before any middleware had seen the request.
- `HTTPServerConfig.onError(handler, error)`, called when a middleware or
  route throws or passes an error to `next()`. It can answer the request
  itself, a JSON error body, say, and otherwise the server answers `500`,
  or the status an `Int` error names, as before. An error that is not an
  `Int` is now logged at ERROR with the method, the path and, where the
  target keeps one, the stack; it was not logged at all, so a route that
  threw a database error left only an INFO line reading `Status: 500`. The
  client is still told only the status.
- `crossbyte.utils.IntParse.decimal` and `hex`: read an integer from text
  the same way on every target, within a bound, answering `-1` for anything
  that is not a plain non-negative number that fits. `Std.parseInt` has four
  answers past 32 bits, truncated on Linux and macOS native, where
  4294967296 reads as 0, clamped on Windows native, a throw on the jvm and a
  wider-than-Int number on JavaScript, so a check of its result is right on
  no target. These count digits against the bound before converting, never
  throw, and return an unboxed `Int`.
- RPC handlers can answer later. A method declared to return `Future<T>`
  instead of `T`, in a contract too, where its commands stub still
  returns `RPCResponse<T>`, is answered once the future completes, and a
  runtime handler returning a `Future` likewise. A handler whose answer
  depends on something slow, such as a hub asking an instance host for a
  match, had nothing to send by the time it returned. The wire, the caller
  and handlers that answer at once are unchanged; a method answering at once
  generates the same code as before. A future complete already when the
  method returns is answered then with nothing registered; one completed on
  another thread is answered on the session's thread at its runtime's next
  tick, since a connection is not thread-safe. A failure is answered as a
  throw is, an `RPCError`'s message, or `RPCError.INTERNAL_MESSAGE` with
  `onHandlerError` told, and `afterCall` runs when the future completes. A
  response that fails because the other side answered with an error now has
  an `RPCError` as its `cause`, so forwarding one passes the refusal on.
  `RPCSession.maxCallsWaiting` (256) bounds how many calls may wait at once;
  past it a call is refused with `RPCError.BUSY_MESSAGE` before its method
  runs. An answer completing after its connection ended is dropped.
- `crossbyte.Completer<T>`, the side of a `Future` that completes it:
  `complete(value)`, `fail(error)`, and `future` to hand out. A `Future` could
  only be completed by CrossByte itself, so code of an application's own
  could not promise an answer it would have later. `fail` takes what a
  function would throw, keeping it as the future's `cause`. Named after
  Dart's `Completer`, which completes a `Future` the same way.
- An RPC guide, `docs/rpc.md`: contracts, commands and handlers; one-way
  calls and requests; what can be sent; how a failing handler is answered
  and what ends a connection; the call hooks; surfaces built from parts;
  the runtime lane; heartbeats and pending calls. Its examples are
  typechecked in CI, in order, by `ci/doc-examples.js`, which now reads
  markdown guides as well as doc comments, takes declarations as well as
  statements, and lets a statement example name the receiver it assumes
  in a leading `// Given name:Type.` line.
- `RPCSession.beforeRuntimeCall(op, requestId, payloadSize)` and
  `afterRuntimeCall(op, requestId, error)`: what `beforeCall` and
  `afterCall` are to a compiled handler, for handlers added with
  `register`. Those have no class to override hooks in, so the hooks are
  set on the session. Left `null`, as they start, they cost a runtime call
  one check each.
- RPC commands classes can extend other commands classes, as handlers can.
  A subclass sends its parent's methods as well as its own and reads the
  responses to both. A commands class for a contract can extend the one for
  the contract it extends. The macro made `ping` and the response reader
  again in every commands class, which Haxe refused in a subclass.
- RPC contracts can extend other contracts, so a reusable one, presence,
  chat, can be built into an application's. A contract's stubs, and its
  handler's dispatch, now cover every method of every interface it extends,
  however far up. A parent reached twice gives its methods once, and a
  generic parent takes the type its extension passes. A name declared twice
  with different signatures is a compile error, since on the wire the two
  would be one method.
- RPC handler classes can extend other handler classes. A subclass answers
  its parent's methods as well as its own, an override is what answers, and
  a contract method can be implemented by an ancestor, so a reusable
  contract can come with a reusable handler. The macro made `ping` and
  `dispatch` again in every handler class, which Haxe refused in a subclass
  without `override`.
- `RPCHandler.beforeCall(method, requestId, payloadSize)` and
  `afterCall(method, requestId, error)`: one place to authorize, rate limit
  or count every call, and to see how each went, where it had to go in
  every method. `beforeCall` runs before a call's arguments are read, and
  refuses it by returning an `RPCError`: a request is answered with its
  message, and a one-way call is dropped. `afterCall` runs once the answer
  has gone. Hooks in a shared base class apply to every handler built on it.
  The calls are generated only into a handler that overrides them, or whose
  ancestor does. Natively, dispatching a one-way call costs 18 ns in a
  handler without them, as before. With both overridden it costs 22 ns,
  against about 190 ns for the whole call from stub to handler.
- The performance suite measures RPC: dispatching a one-way call, a call
  from stub to handler, and a request answered, over connections joined in
  memory, with and without hooks.
- `crossbyte.rpc.RPCError`, for a failure an RPC handler means its caller to
  see. Thrown from a handler method, its message is the caller's answer:
  the `RPCResponse` fails with it, word for word, and the connection stays
  up. `RPCSession.onHandlerError(op, method, error)` is told of anything a
  handler throws that its caller is not told: anything but an `RPCError`,
  and anything at all from a one-way call. `method` is the compiled
  handler's method name, or `null` for a runtime handler. It logs by
  default, and whatever it throws is ignored.
- Pluggable congestion control for reliable datagram sessions.
  `CongestionControl` decides how many frames a session may have in the
  network at once, and is both the default, Reno, as before, and the
  class to extend: `onAcknowledged`, `onLoss` and `onTimeout` are its events,
  and `window`, read before every frame is sent, is its answer. Setting
  `ReliableDatagramSocket.congestionControl` gives a session its own. A
  server's `congestionControlFor(address, port)` hook gives one to each
  session it accepts or dials, and a hook that throws refuses the CONNECT,
  as `admit` does.
- `LossTolerantCongestionControl`, for paths that lose frames to radio
  rather than to congestion. On a loss it sets the window to what the path
  has been delivering times the fastest round trip: what the path holds
  with nothing queued. A loss with no queue behind it then costs little,
  and a queue is still drained, though never below half the window. At a
  20 ms round trip, 1000-byte messages ran at 7.0 MB/s under 1% loss where
  the default runs at 0.63; at 5% loss, 2.1 against 0.28; at 10%, 1.0
  against 0.19 (medians of six runs). With a small receive buffer
  overflowing, it lost no more frames than the default. It measures by two
  new readings on the socket: `minRoundTripTime`, the fastest round trip,
  and `framesDelivered`, the frames the peer is known to hold, each counted
  once, as soon as it is known.
- `DatagramSocket.receiveBufferSize` and `sendBufferSize`: the operating
  system's buffers for a socket, read and asked for. Past the receive
  buffer, arriving datagrams are dropped, and the systems' defaults are
  small, 64 KB on Windows, so a socket many peers send to, or one
  receiving a window of datagrams at once, wants more. What is granted is
  the system's call (Linux caps it at `net.core.rmem_max`, and reports twice
  what it keeps), so read it back. Natively and on the jvm, and on Node once
  the socket is bound; eval, HashLink and Neko cannot size a socket's
  buffers and read 0.
- `crossbyte.net.PeerClock`: where a peer's clock stands against this one,
  from exchanges the application makes in messages of its own, this side
  notes when it asked, the peer answers with its clock, this side notes when
  the answer came. One exchange puts the peer's reading within the round
  trip, so the offset is taken at the middle and is out by at most half the
  round trip, which `error` reports; of the last `window` exchanges, 16 by
  default, the one with the shortest round trip is used, since queueing is
  what lengthens a round trip and it is rarely even on both legs. `now()`,
  `toPeer` and `toLocal` read times across, `jitter` follows how much one
  round trip differs from the next as RFC 3550 smooths it, and an exchange
  that cannot have happened, an answer before its question, a time that is
  not finite, is refused. It owns no socket and no timer, so it runs on
  every target, the browser included.
- `ReliableDatagramSocket.roundTripTime`, `roundTripVariation` and
  `retransmitTimeout`: what the session measures to time its own
  retransmissions, RFC 6298's smoothed round trip, its variation, and the
  timeout drawn from them, read-only, in seconds. The round trip is -1
  until the first reliable frame sent only once is acknowledged.
- A payload on the CONNECT that opens a reliable datagram session, for the
  server to decide on before it allocates anything. `connect` on
  `ReliableDatagramSocket` and on `ReliableDatagramServerSocket` takes one of
  up to a frame, 1200 bytes, copied when called and carried by every CONNECT
  the handshake repeats; `admit(address, port, payload)` is shown it, empty
  when the peer sent nothing; and the session a server accepts keeps it as
  `connectPayload`, so the handler that takes the session knows who it is by
  the token it was let in on. Admission could weigh only an address, which
  UDP lets a sender write for itself, so a join ticket or a protocol version
  could be checked only once a session and its handshake had been paid for.
  The payload crosses in the clear and anyone who sees it can send it again,
  so what it carries should be something the server can verify and expire,
  not a secret. A CONNECT carrying more than a frame is dropped before
  `admit` is asked, since each pending session holds what its CONNECT
  carried. Peers that both dial, as through NAT, each keep the other's. A
  peer on an older build sends none, and ignores one.
- `crossbyte.io.BitWriter` and `BitReader`: values in as few bits as they
  need. Widths of 1 to 32 bits, signed values, integers in a known range (in
  the bits the range needs, none for a range of one), floats quantized to
  evenly spaced steps over a range (back within half a step, the ends exact),
  and raw 32-bit floats. Bits fill 32-bit words from the lowest up, stored
  little-endian and trimmed to whole bytes, so the bytes are the same on every
  target. The writer gathers a word before storing it and keeps its buffer
  across `reset`, so packing allocates nothing once it has grown; the reader
  treats its input as a peer's, refusing a read past the end with `EOFError`
  and a range value past its maximum with `RangeError`, and reading the last
  partial word a byte at a time rather than past it. A value too wide for its
  field is refused rather than truncated into a different, plausible one. On
  the snapshot the arena sends, 64 records of a 10-bit slot, a 4-bit
  generation, 12-bit x and y and a flag, packing takes 1.05 microseconds
  natively against 1.14 for the same values byte-aligned, and 312 bytes
  against 512.
- `crossbyte.net.DeliveryMode`, and a fourth argument to
  `ReliableDatagramSocket.send` that takes one: `RELIABLE`, the default and
  what `send` always did; `UNRELIABLE`, sent once and never resent; and
  `sequenced(channel)`, unreliable, with anything older than the newest
  message delivered on its channel dropped rather than delivered late. A
  session carried only reliable ordered messages, so state sent over it waited
  behind whichever packet was lost, and the way round that, a raw
  `DatagramSocket`: left the handshake, admission, congestion control and
  keepalive behind. Unreliable and sequenced messages ride the same session,
  must fit one frame (1200 bytes; larger is refused, not split), and are not
  paced by the reliable congestion window, which has no acknowledgements for
  them to open or close it. Channels 0 to 255 are independent, so a newer
  snapshot never makes an older input look stale. The channel and a 24-bit
  wrapping counter travel in the frame's existing sequence field, so nothing
  is added to the frame, and a peer on an older build drops the new frame
  types as unknown rather than misreading them.
- `ReliableDatagramSocket.maxMessageSize`, eight megabytes unless set, zero
  for no limit: the largest reliable message a peer may send. A message
  larger than a frame is held until its last fragment arrives, so what a peer
  can make this side hold is whatever it says a message is; past the limit the
  session closes with an `ioError` saying why.
- `crossbyte.ds.SpatialGrid3D`: `SpatialGrid` with a third axis, for things
  spread as far up and down as across, space, flight, floors a view apart.
  `set(id, x, y, z)` moves an id for a comparison unless it crosses a cell, and
  `querySphere` and `queryBox` visit only the cells they overlap. A world that
  is mostly flat relative to its view radius is still cheaper in
  `SpatialGrid` on the ground plane: a 3D cell costs an array entry whether or
  not anything is in it, and a sphere touches up to 27 cells where a circle
  touches 9. Run through the arena on a flat world it keeps 100,000 entities
  current in 1.07 ms against the 2D grid's 0.91, reporting the same entities
  entering and leaving every view. There is no octree, for the reason there
  is a grid beside `QuadTree`: a tree divides where things are, so moving
  them means building it again.
- `crossbyte.ds.SpatialGrid`: ids at positions, filed into square cells, for
  things that move. Each cell's ids are a list threaded through arrays indexed
  by id, so `set` costs a comparison when an id stays in its cell, at any
  ordinary speed, nearly every step, and a relink when it crosses into
  another, and moving allocates nothing once the arrays have grown. A query
  visits only the cells its circle or rectangle overlaps, and what it finds
  are ids, which go straight into an `InterestSet`. Bounds decide speed, not
  correctness: a position outside them is filed at the edge and still found.
  Measured in the arena sample against rebuilding a `QuadTree` every step, at
  20 Hz with each view holding the same crowd: 0.09 ms against 0.98 to keep
  10,000 moving entities indexed, 0.89 against 14.5 at 100,000, and 2.2
  against 45 at 250,000, where the tree takes most of a 50 ms step. A
  `QuadTree` remains the choice for uneven crowds and things that hold still.
- `samples/arena`: an authoritative game server and sixteen bots in one
  process, built from `FixedStep`, `SpatialGrid`, `InterestSet`, `BitSet`,
  `SequenceRing`, `ByteDelta`, `ConcurrencyLimiter`, `ServerSocket.admit` and
  `FrameCodec`. Every snapshot carries a checksum of what the server built and
  each bot compares what it decoded, so the run exits non-zero when the pieces
  compose badly even if each passes its own tests. CI builds and runs it.
- Admission control on listeners. `ServerSocket.admit(address, port)` is
  asked about each connection as soon as it is accepted, before any TLS
  handshake, before a `Socket` is built, and `false`, or a throw, closes it
  on the spot; a TLS server on Node asks on the raw `connection` event, so a
  refused peer is spared the handshake there too. The accept loop takes up to
  `maxAcceptsPerTick` connections a tick (64) where it took one, which left a
  burst of 190 waiting 3.2 seconds at 60 Hz, and `maxPendingHandshakes` (256)
  bounds handshakes in flight by leaving the rest queued in the kernel.
  `ReliableDatagramServerSocket.admit` is asked before a CONNECT from a new
  address allocates a session, and is shown what the CONNECT carried. `ServerWebSocket` honours all three: it
  accepts through a loop of its own, where they had compiled and done
  nothing.
- `crossbyte.ds.InterestSet`: what came into an observer's view and what left
  it since the last round, the spawn and despawn lists a server sends each
  client. Ids from any visibility test are gathered and committed, and
  `commit` reports departures and then arrivals, at a cost that follows the
  size of the views rather than the largest id. `forget(id)` covers a slot
  reused between rounds, which a set of numbers cannot see. `QuadTree` gains
  `queryCircle`, and stops subdividing 32 levels down: a crowd on one spot
  used to split until the quads were too small for floating point to tell
  apart, and inserts began to fail.
- `crossbyte.ds.SequenceRing` and `crossbyte.io.ByteDelta`, the two halves of
  delta replication. The ring files values by a wrapping sequence number and
  reads anything older than its window as absent. The codec encodes bytes as
  a difference from a baseline, an unchanged 1000-byte snapshot costs five
  bytes, and decodes its input as hostile, refusing a declared length above
  `maxLength` before building anything.
- `BitSet.nextSetBit`, `nextClearBit`, iteration with `for (i in bits)`,
  `isEmpty`, `clone`, and `and`, `or`, `xor` and `andNot` in place. Finding
  the set bits meant calling `get()` on every index; a loop on `nextSetBit`
  finds them a word at a time and allocates nothing.
- `crossbyte.core.FixedStep`: steps of one fixed size however the ticks
  arrive. `advance(delta)` takes each tick's elapsed time and `step()` hands
  back steps of exactly `interval`, each numbered by `tick`. Time beyond
  `maxSteps` is dropped and counted in `dropped` rather than owed, since
  owing it is how a server that falls behind falls further behind, and
  `alpha` is how far into the next step the present is. A quotient a hair
  short of a whole number counts as that number, so a 144 Hz runtime under a
  60 Hz simulation stays on schedule.
- `crossbyte.net.ConcurrencyLimiter`: how many at once, beside
  `RateLimiter`'s how often. Capacity in flight is capped and the rest are
  refused, or held in a bounded first-come queue for a bounded time.
  `tryAcquire` never waits or jumps the queue, `acquire` grants, queues or
  refuses, and `sweep()` from the tick expires waiters, there is no timer
  inside. The `ConcurrencyPermit` it returns releases correctly in every
  state, so a connection can release on close without asking what became of
  its claim, and `limit` may change at any time.
- `crossbyte.cluster`: low-level pieces for running as more than one node,
  none of which refers to another.
  - `SnowflakeId`: 64-bit ids, 41 bits of milliseconds, 10 of node, 12 of
    sequence, unique across nodes without a round trip, ordered by time,
    and never repeated when the clock steps back or a burst exhausts a
    millisecond.
  - `Rendezvous`: highest-random-weight hashing, so every node computes the
    same owner for a key with nobody to ask, and removing a node moves only
    its keys. The owners of fixed keys are pinned in the tests, because two
    targets disagreeing about an owner is the failure this cannot have.
  - `Membership`: who is alive, from heartbeats however they arrive, with
    `onJoin` and `onLeave`, and `maxNodes` bounding the names accepted from
    outside.
  - `NodeChannel`: a framed link to one peer that redials with backoff from
    a quarter second to thirty seconds, bounds what waits for an absent peer
    with `maxQueuedBytes`, and never resends a message behind the caller's
    back.
- `crossbyte.net.FrameCodec`: message boundaries for transports that do not
  keep them, such as TCP and binary WebSocket. A four-byte length prefix, a
  read cursor with amortised compaction, and a declared length checked
  against `maxFrameSize` as soon as the header is readable rather than after
  the bytes arrive.
- `crossbyte.ds.ExpiringMap`: entries that stop being there, bounded twice,
  `ttl` for how long and `maxSize` for how many, since time is no bound when
  whoever fills the map fills it faster than it drains. A sweep costs what
  expired rather than what is held, and an expired entry reads as gone
  however seldom the caller sweeps.
- `userData` on `Socket` (and so `WebSocket`), `ReliableDatagramSocket`,
  `DataChannel` and `NetConnectionBase`: somewhere to keep the application's
  state for a connection that goes when the connection goes, instead of a
  side map whose entries outlive their connections whenever a removal is
  forgotten. Typed `Any`, so reading it back takes an explicit cast.
- ICE consent freshness, RFC 7675. A selected pair used to stay selected
  forever; the agent now re-checks it every four to six seconds, verifies the
  answers against the peer's password, and gives the path up thirty seconds
  after the last valid one. `PeerConnection` closes when that happens.
- Fuzzing, in `tests/crossbyte/fuzz`. Nine parsers that read bytes off a wire
  are fuzzed as pure functions, STUN, SCTP, DCEP, HPACK and its Huffman
  strings, deflate, LZ4, and Postgres results and bytea, and the HTTP
  server, the WebSocket frame decoder and an established SCTP association
  over real connections. Those three assert what is still held once the peers
  have gone as well as that the server survives, because every
  unbounded-growth fault fixed in this release had passed a green suite. The
  generator is seeded, so a red run reproduces.
- A server-shaped soak, `ci/soak.hxml`, to ask whether the native GC fault
  seen in the test suite reaches a process that stays up. Within twenty
  seconds of its first run it found the `SlotMap` leak below; since then it
  has run two hours clean. `TestHarness` gains `-D gc_probe` and
  `-D gc_bisect` for cornering that fault.
- CI runs what it says it runs. Several steps went through a tool release
  that printed its banner and exited 0, so the native samples never built and
  the interpreter suite, the sample type-checks and the three hxcpp audits
  never ran. They do now, with every build's exit code checked, and five of
  the samples are also run. The system and native crypto suites run on Linux
  and macOS, and the examples in `File`'s documentation are type-checked
  before the API docs build.
- The jvm target runs the whole suite. It ran everything except `RPCTest`,
  `CollectionsTest` and `CompressionRoundTripTest`, excluded for a Haxe 4.3.7
  `--jvm` bytecode bug that raises a `VerifyError` at class-load and takes the
  process with it, not a failing case but no result at all. Two of the three
  had stopped tripping it some time ago and nothing re-checked, because nothing
  re-checks an exclusion. The third was real, and belonged to the test rather
  than to `crossbyte.rpc`: constructing an `RPCSession` for its side effects
  and discarding the result leaves an uninitialised reference live across a
  branch. Binding each construction to a local settles it. RPC on jvm needed no
  change and never had coverage saying so; it does now. The entry point also
  calls `addAll` instead of listing groups, which is how `addMetrics` came to
  be missing from it, not a decision, and not visible in either file.
- The core socket suites run on the jvm target: `SocketTest`,
  `ServerSocketDrainTest`, `ServerWebSocketDrainTest` and
  `WebSocketConformanceTest` were registered `#if cpp`, so the socket layer's
  own cases, including the WebSocket conformance run against a hand-written
  client, executed on one target only. Both jvm faults above were found by
  turning them on, and the first of them hung the suite rather than failing it,
  which is what a frozen runtime looks like from outside.
- The HTTP server suite runs on the jvm target. Its cases were gated to
  `cpp || neko || hl || nodejs`, written when the server was native-only and
  never widened, so the whole of `HTTPServer`, routing, streaming, draining,
  metrics, HTTP/2, executed nowhere on jvm. All of it passes there, and does
  now: 458 further assertions on a target that had none of them.
- TLS carries application data, and there is a case that says so. Every jvm TLS
  test stopped at the handshake, which turned out to be the wrong place to
  stop, certificates, ALPN, client certificates and SNI all passed while the
  data path moved nothing. The round trip is against the JDK's own blocking
  `SSLSocket`, so it is a foreign implementation rather than two halves of this
  one agreeing.
- `verifyCert = false` is honoured by the jvm TLS client. It was accepted and
  ignored: the client verified regardless, so a self-signed development server
  was unreachable from jvm no matter what the caller asked for. The JDK
  consults only the three-argument `X509ExtendedTrustManager` overloads on an
  `SSLEngine` handshake, so a trust manager implementing the two-argument forms
  alone is silently never asked. Verification stays on unless it is turned off
  explicitly, and turning it off does not stop the client sending SNI,
  choosing which host to talk to is not the same decision as whether to check
  the answer, and dropping the name would quietly serve it the wrong
  certificate.
- Client-side TLS on the jvm target, and with it OAuth token requests, which
  threw there. `FlexSocket(secure)` handed back a socket that did a plain TCP
  connect and spoke no TLS, so every https request through CrossByte's own HTTP
  client was unencrypted or broken; it now terminates TLS as the client,
  verifying the certificate against the JDK's trust store and checking the
  hostname against it. `OAuth` routes through that client on jvm rather than
  `haxe.Http`, which reaches HTTPS through a `sys.ssl.Socket` that does not
  compile there. Verified against a live HTTPS server: 200 OK from a real host,
  and a token request that reached a real endpoint and parsed its reply.
- Server Name Indication on the jvm target: `addSNICertificate` now presents
  the certificate matching the hostname a client asked for, falling back to the
  one installed with `setCertificate` for a name no entry claims. Selecting per
  name is a key manager's job, `SSLParameters.setSNIMatchers` only decides
  which names a server will accept, not what it answers them with, so the
  backend supplies one. With this, the jvm TLS surface matches what the other
  targets offer: certificates, ALPN, client certificates and SNI.
- Client certificates on the jvm target. `requireClientCertificate` already
  installed a trust store there, but a trust store only says which authorities
  would be acceptable, the handshake was never asking for a certificate, so
  the store was never consulted and an unauthenticated peer was accepted. The
  engine now demands one whenever `verifyCert` is set. A client presenting
  nothing is refused with "Empty client certificate chain"; one presenting a
  trusted certificate completes.
- ALPN on the jvm target, so a TLS listener there can negotiate `h2`. The JDK
  exposes it through `SSLParameters`, where the cpp path needed a native
  extension to reach mbedTLS at all. `ServerSocket.setALPN`, `FlexSocket`'s
  accessors and `Socket.alpnProtocol` all report it. Verified by hand against
  the JDK's own client offering the reverse preference order, so agreement on
  the server's first choice is a negotiation and not an echo; it is not covered
  by CI, for the reason recorded in `ServerSocketTLSTest`.
- TLS on the jvm target. A secure `ServerSocket` refused at construction there
  and `Certificate`/`Key` refused to load anything, so the jvm build had no
  HTTPS server and no WSS. It now terminates TLS through `SSLEngine`, verified
  against `openssl s_client`: TLS 1.3, certificate accepted, handshake
  completed. Java ships two TLS APIs and only `SSLEngine` suits a poll-driven
  runtime, `SSLSocket` is blocking, so the engine is driven over the same
  NIO channel the plain socket uses and reports an unfinished handshake by
  throwing `Blocked`, which is what the existing handshake pump already treats
  as "come back next tick". Nothing above the socket changed. Certificates load
  from PEM; private keys from unencrypted PKCS#8, with PKCS#1 and encrypted
  keys refused by name and told how to convert rather than misparsed. Server
  Name Indication, client certificates and ALPN are not implemented yet and say
  so.
- A performance suite in `tests/bench`, covering the paths that run once per unit of real work, per datagram, per connectivity check, per event, so a regression there is multiplied by traffic. It reports the best of several calibrated samples per case; CI builds and runs it so it cannot rot, and ignores the numbers, because a shared runner's timings gate nothing honestly. Its first run found both of the performance fixes below.
- `StunClient` has tests. It had none, nothing in the repository named it, while `StunMessage` was pinned to RFC 5769's vectors and `TurnClient` had cases of its own, so the class a caller reaches for first was the one thing in that corner nobody checked. Seven cases against a server bound in the test, covering what a real one could not be asked to do: drop a request, refuse one, answer without an address, and answer a question nobody asked.
- `TurnClient.useChannels` and `PeerConnection.gatherRelayed`'s `useChannels` argument: RFC 8656 channels, which replace the thirty-six byte Send indication wrapper on every relayed datagram with four. Off unless asked for, because a relay that binds a channel and then drops what it is sent over it cannot say so, a `ChannelData` message is not STUN, and one implementation tested here answers the bind with success while rejecting every datagram whose top two bits are set. A relay that refuses the bind outright is the safe case and keeps working on indications.
- `crossbyte.net.rtc.PeerConnection.gatherReflexive`: asks a STUN server what address this connection appears from and adds the answer as a candidate, which is what a peer behind NAT has to advertise for anything outside to reach it. It goes out of the connection's own socket, and it has to: a NAT keeps one translation per socket, so an address discovered on a socket of its own, which is what `StunClient` binds, answers truthfully about a mapping this connection does not have and no peer will ever send to. It asks again on RFC 5389's doubling schedule rather than sending once and waiting for a deadline, because the only question a connection asks about its own address is a thing to lose to one dropped datagram, and a deadline alone reports that loss as a server which is not there.
- `crossbyte.net.rtc.PeerConnection.gatherRelayed` and `relayedCandidate`: allocates on a TURN server through that same socket and carries the connection over it when ICE nominates the relayed pair. For the peer no direct path reaches, two symmetric NATs, or one and a firewall that drops anything unsolicited, leave no datagram either end can send that the other receives, and a relay is an address both can. Connectivity checks, the DTLS handshake and every message are wrapped for the server to forward and unwrapped on the way back, so nothing above ICE knows there was a detour. It is preferred last: every byte crosses a third party twice, and a relayed candidate carries the lowest priority there is.
- `IceAgent.addLocalCandidate` takes an optional way of sending from that candidate, and `receive` an optional candidate saying how a datagram arrived. Both additive. The agent used to assume one socket served every local candidate, so which one a pair named moved the priority and nothing else; a relayed candidate's address belongs to a server, and naming it is precisely what decides that a datagram is wrapped for forwarding rather than addressed at the peer. An answer also has to leave the way its request arrived, which is why `receive` needs telling.
- CrossByte interoperates with a real TURN server. Two peers with no path between them but a relay implemented by somebody else, node-turn, RFC 5389 and 5766, open a data channel and exchange messages, including one of 128KB that crosses as 128 chunks with the acknowledgements coming back the same way. Run by `ci/relay/run.js` and part of CI, for the same reason the browser test is: the suite's own relay verifies a request with the very code that produced it, so the two would agree perfectly about anything they are both wrong about.
- RFC 5769 section 2.4, the long-term credential sample, as test vectors. Long-term credentials key the integrity with MD5 of username, realm and password rather than with the password itself, so an implementation can have every byte of the HMAC right and still get every TURN exchange wrong. Three cases hold it: the key derived, the sample verified, and the same request rebuilt from its parts byte for byte. `StunMessage.longTermKey` now also says what it does not do, SASLprep, which matters only for a credential outside printable ASCII and silently derives a different key when it does.
- CrossByte interoperates with a real browser. A headless Chrome `RTCPeerConnection` and `crossbyte.net.rtc` now find a path with ICE, complete a DTLS handshake verified against a signalled fingerprint, open an SCTP association, negotiate a data channel over DCEP and exchange messages, run by `ci/interop/run.js` and part of CI. Every other test in this repository proves this code agrees with itself, which is worth a great deal and is not the same thing: a checksum byte order, a chunk layout or an integrity scheme can be perfectly self-consistent and understood by nothing else alive. Three things were reasoned from RFC text rather than demonstrated until now, the SCTP checksum being written least significant byte first, the DCEP message framing, and SCTP layered inside DTLS records, and this is what turns them from arguments into facts.
- `crossbyte.net.rtc.SessionDescription`: a `PeerDescription` rendered as SDP and read back from it, which is what a browser exchanges. Enough for a data channel and no more, one `m=application` line, no media and no codec negotiation. `a=setup` is the line that matters: `actpass` in an offer means the answer chooses, and choosing the same role the peer took leaves both waiting for a ClientHello neither sends. The parser is pinned to a real Chrome offer rather than to a round trip, because a codec that reads back what it wrote agrees with itself perfectly and may still not understand a word a browser says, it ignores the lines it does not need, skips the TCP candidate Chrome offers and this stack has no transport for, and keeps the peer's own candidate priorities rather than recomputing them, since both peers must sort the same pairs the same way.
- `crossbyte.net.rtc.PeerConnection` and `PeerDescription`: the whole WebRTC stack behind one class. ICE finds a path, DTLS encrypts it, SCTP carries it and DCEP names the channels, all over a single UDP socket, which is why every layer beneath was built owning no socket of its own. Arriving traffic is separated by RFC 7983's rule, a first byte under 4 being STUN and 20 to 63 being DTLS, which is the rule that lets one port carry connectivity checks and an encrypted session at once; SCTP never appears raw, living inside the DTLS records. Every layer is driven from one clock, `haxe.Timer.stamp()` on the runtime tick, and that is load-bearing rather than tidy: each schedules retransmissions against the timestamps it was handed, so two layers fed from clocks with different epochs would disagree about the age of every unacknowledged packet, one retransmitting instantly, the other never, with nothing to name the cause. One `controlling` bit decides everything downstream: who nominates the ICE pair, who is the DTLS client, who opens the association, who takes the even data channel streams. An ICE role conflict therefore propagates upward, because a connection that kept its original answer after the agent changed sides would have both peers claiming the same half of each of those. Signalling is deliberately not carried here, it is the one part of WebRTC that belongs to the application, and every application already has a channel it would rather use, so `description()` hands over the fragment, password, fingerprint and candidates as data. A description arriving without a fingerprint is refused outright, since a connection built on one would be encrypted and unauthenticated, which looks secure in every way that does not matter. Covered by two peers on real sockets completing the entire stack and exchanging a message in each direction, and by a peer presenting a certificate that is not the one it signalled being refused after a handshake that succeeded.
- `crossbyte.net.rtc.DataChannel` and `DataChannelSet`, over a `DcepMessage` codec: the top of the WebRTC stack, and the first thing in it an application would actually hold. SCTP gives an association with streams that are numbered but anonymous; RFC 8832 is what turns a stream number into a channel with a name. The OPEN travels on the very stream it is about, told apart from that channel's own messages by payload protocol identifier 50 alone, which is why a channel needs no second stream to be negotiated on, and why that identifier exists at all. Stream numbers are not negotiated: the peer that was the DTLS client takes the even ones and the other the odd, so two peers opening a channel at the same instant cannot choose the same stream and no round trip is spent discovering a clash. A caller therefore does not pick the number, and an OPEN arriving on a stream this side would have chosen is refused rather than accepted into a collision. A channel carries whole messages, send a megabyte and the far side gets a megabyte in one piece or nothing, never half of one, so an application on top needs no framing of its own. Text and bytes are separated on the wire rather than guessed at from the contents, and an empty message of each kind has an identifier of its own, since a zero-length payload is otherwise indistinguishable from no payload; a channel that swallowed one would be losing messages an application deliberately sent. Sending before the peer has acknowledged throws rather than buffering or dropping, because a caller cannot tell those two apart.
- SCTP data transfer, `SctpDataChunk` and `SctpDataTransfer`, which is messages over an open association: fragmenting them, acknowledging them, retransmitting what went missing, and putting them back in order. Three numbers do three different jobs and conflating any two of them breaks something different: the TSN orders and acknowledges every fragment on the association and is what a SACK talks about; the stream sequence number orders whole messages within one stream and only within it; the payload protocol identifier says what the bytes are, which is why an empty message needs an identifier of its own, a zero-length payload being otherwise indistinguishable from no payload. Reliability costs keeping every unacknowledged fragment until it is acknowledged; ordering costs holding arrivals rather than delivering them, and unordered delivery declines that second cost while keeping the first, a message still arrives, and is still resent, it just does not wait. Both are per stream, which is the entire reason SCTP has streams and the reason a data channel is not simply run over TCP: a message held up on one channel delays nothing on another, and that is asserted directly. A message too large for one packet is cut up with the same stream sequence number on every fragment, the first flagged B and the last E, and held at the receiver until both ends are present with an unbroken run between them. SACKs carry the cumulative acknowledgement and the gap blocks past it, so a sender resends what is missing rather than everything since. The harness drops and reorders packets on demand, because over a wire that never misbehaves an implementation that retransmits and one that does not are indistinguishable.
- The SCTP association handshake, `SctpAssociation`, `SctpParameter` and the states that go with them. Four messages where TCP uses three, and the extra one is the entire point: the peer being asked to open an association commits no memory to it until the requester has proved it can receive at the address it claimed, because the state that would have been held is handed over as a cookie for the requester to carry back. That is the attack SYN cookies were retrofitted onto TCP to survive, designed into SCTP from the start, and it is tested as a property rather than assumed, the answering side is still listening, holding nothing, after it has answered. A cookie it did not issue opens nothing, compared without a short circuit so the timing of a refusal says nothing about how much of a guess was right. Verification tags are the other half: each side invents one, and from then on stamps every packet with the *other* side's, which is what lets an association survive a peer restarting on the same port instead of quietly folding its new traffic into the old session. The INIT is the one packet that carries a zero tag, having none yet to carry, and that is asserted rather than left to convention. Like the agent, the relay and the DTLS transport, it owns no socket, doubly forced here, since an association runs inside a DTLS session which runs over a socket already carrying ICE.
- The SCTP packet layer, `SctpPacket`, `SctpChunk` and `Crc32c`, which is the framing a WebRTC data channel is written in, and the first piece of the last protocol in the chain. Two details here decide whether anything ever interoperates, and both are pinned. The checksum is CRC-32C, Castagnoli's polynomial, not the CRC-32 already in `haxe.crypto`: the two are one letter apart in every document that mentions them and disagree on every input, so the wrong one produces a checksum that is perfectly self-consistent and universally rejected. It is verified against the catalogue's check value and RFC 3720's iSCSI vectors, and asserted to differ from the standard library's. It is then taken over the whole packet *with the checksum field zeroed*, the same shape STUN's integrity has and the same mistake available, and written least significant byte first, alone among the header's fields, because RFC 4960's reference implementation byte-swaps the result before storing it and every implementation follows. Chunk padding follows STUN's rule too: the length counts the header and value and not the padding, while the next chunk still begins on a four byte boundary. An unrecognised chunk carries its own instructions in the top two bits of its type, which is what lets a receiver behave correctly toward a revision it was not written against. All of it is bytes in and bytes out, so it runs on every target including the browser, where SCTP itself lives inside `RTCPeerConnection` and this code never will.
- `crossbyte.net.rtc.DtlsTransport`: the encrypted channel a WebRTC data channel runs inside. ICE finds a path; this is what makes it private, and once SCTP is here every message on every data channel will travel through it. It owns no socket, for the reason everything else in this stack does not: the socket a peer would use is already carrying ICE checks and will later carry SCTP, and mbedTLS would want to own it, so the session is driven through memory callbacks, `onSend` out and `receive` in with `poll` for time. The same shape means two transports can be handed each other's datagrams and complete a real handshake, retransmission timers and all, with no network in between, which is how it is tested. Arriving datagrams are told apart by RFC 7983's rule, below 2 is STUN, 20 to 63 is DTLS, so a transport sharing a socket takes only what is its own and leaves the connectivity checks still keeping the path alive. Verification is by fingerprint and it is not optional: the expected value is a constructor argument, because an implementation that lets it be supplied later has a window in which a session is established and unverified, and something eventually uses it in that window. mbedTLS is configured `MBEDTLS_SSL_VERIFY_OPTIONAL` rather than `VERIFY_NONE`, and that distinction is the whole of mutual authentication here: there is no chain to verify, but `NONE` also means a server never *requests* a client certificate, so the client sends none, so the server has nothing to fingerprint and one end of the session is anonymous. `OPTIONAL` asks for it and declines to fail over a chain that leads nowhere, leaving the fingerprint to decide. The DTLS cookie exchange is disabled on the server side deliberately: it exists to prove a client is reachable at the address it claims, and ICE proved exactly that one round trip earlier by getting an answer to a connectivity check.
- `crossbyte.net.rtc.DtlsCertificate`: the certificate a peer proves itself with, and the fingerprint it publishes instead of a certificate authority. WebRTC has no CA in it, each peer signs its own certificate, sends a hash of it over the signalling channel that already brought the two together, and the handshake checks that what was presented hashes to what was signalled. The trust comes from the signalling channel, and the certificate only has to outlive a session, which is why one per connection is normal here rather than negligent. P-256 rather than RSA, both because it is what every WebRTC implementation defaults to and because it is what makes per-session generation reasonable: measured at one to two milliseconds. The fingerprint is taken over the DER the certificate encodes to and not the PEM text carrying it, since two encodings of one certificate are one certificate and the peer at the other end is hashing bytes off the wire, checked against SHA-256 computed outside Haxe over the same certificate rather than against this implementation's own output. Native only, and `isSupported` says so: mbedTLS is what hxcpp links, Node has no DTLS in core at all, and a browser makes its certificates inside `RTCPeerConnection` where a page deliberately cannot reach the private key. The first half of DTLS; the transport itself follows.
- `NativeDtls`, the mbedTLS bridge under it, and two things learned building it that are now written into the build rather than left to be rediscovered. hxcpp does not compile mbedTLS against its stock configuration: it passes `MBEDTLS_USER_CONFIG_FILE`, and that config turns on `MBEDTLS_THREADING_C`, which adds a mutex member to `mbedtls_ctr_drbg_context`, `mbedtls_entropy_context` and others. A file compiled against the stock config declares the smaller struct and the library then writes the larger one over whatever is next to it, reporting success, and killing the process later somewhere with no visible connection to the cause, which is exactly how this behaved for an afternoon. `NativeDtlsBuild.xml` sets the flags and `NativeDtls.cpp` refuses to compile without them. The second is that `MBEDTLS_THREADING_ALT` leaves the mutex callbacks unset until hxcpp's `_hx_ssl_init()` installs them, and until then `mbedtls_mutex_lock` is a stub that *fails*, so anything touching a mutex-bearing struct returns an error resembling nothing in particular. Whether that had already run depended on static initialiser order across translation units, which made one program work and another built from the same source fail; the bridge now calls it, which is idempotent and free. Failures also report the mbedTLS code rather than an unexplained null, because a failure nobody can reproduce on demand deserves better than "it did not work".
- `crossbyte.net.TurnClient`: a relayed address, for the connections that have nowhere else to go. ICE finds a direct path almost always, and when it does not, symmetric NAT at both ends, a firewall permitting only outbound TCP, a carrier running CGNAT, there is no packet either peer can send that the other will receive, and no amount of hole punching invents one. TURN answers that by having a server both peers can reach forward between them. It is deliberately the last candidate tried: every byte crosses a third party twice and somebody pays for the bandwidth, which is worth it only against the alternative of no connection at all. Allocation, refresh, permissions and Send/Data indications are all here. The handshake begins with a refusal and that is not an error, a relay publishes neither its realm nor the nonce it wants requests signed against, so the first request goes out bare and the 401 that comes back is how the exchange starts; RFC 8656 section 9.2. The credential is not the password either but MD5 of username, realm and password together, so a relay can hold the digest and a credential is bound to the realm it was issued for, and that derivation is pinned to arithmetic done outside Haxe rather than to this implementation's own output. An expired nonce is ordinary operation and is retried against the new one, while a credential the relay actually rejects fails once rather than turning a wrong password into a flood. Requests queue rather than replacing each other: only one is tracked at a time, so starting a second underneath the first would abandon it, and the one abandoned would usually be the refresh, which fails silently, the allocation simply ceasing to be renewed until the connection dies with it. Like `IceAgent` it owns no socket, so the whole exchange is tested against a relay standing in memory, deterministically, on every target including the browser, including the cases a real relay will not produce on demand. Channel binding (section 12) is not implemented and says so: it would trade thirty-six bytes of overhead per packet for four, which is worth having on a busy relay and changes nothing about whether a connection works.
- TURN support in the STUN codec, the allocate, refresh, create-permission and indication methods, `XOR-RELAYED-ADDRESS`, `XOR-PEER-ADDRESS`, `DATA`, `REALM`, `NONCE`, `LIFETIME` and `REQUESTED-TRANSPORT`, and signing keyed with bytes rather than a password, since short-term credentials key with the password directly and long-term ones with a digest. The RFC 5769 vectors still pass through that change, which is what they are there for.
- ICE role conflict resolution, RFC 8445 section 7.3.1.1, which is what lets `IceAgent` talk to a stack CrossByte did not write. Roles are agreed out of band, and any exchange that can be raced, both sides offering at once, a restart, a signalling path that reordered two messages, leaves both peers convinced they hold the same role. Nothing detects it until a check arrives, because until then each side is perfectly consistent with itself, and the two failures look nothing alike: both controlling means two peers nominating possibly different pairs, while both controlled means nobody nominates and the checks run happily forever without ever selecting anything. The larger tiebreaker keeps the role in both cases; what differs is who acts, since an agent that wins refuses the check with a 487 and makes the sender move, while one that loses moves itself. A role change rebuilds every pair, because pair priority is computed from the role and an agent that changed sides without recomputing would be relabelled rather than switched, still ordering its list the old way while the peer orders it the new one. Pairs already proven keep their standing, a path that works being a fact about the network rather than about who nominates. A refusal is acted on only when it answers the role currently held: a check sent while claiming to be controlling can be refused after an inbound check has already made the agent controlled, and acting on that stale answer puts it back into the conflict it just left. Measured without that guard, the peers still converge, so nothing hangs and no other case notices, while the role changes repeatedly and each change discards every pair priority and the nomination in progress, which is the kind of fault that arrives at the right answer and is never found afterwards. `IceAgent.onRoleChanged` reports the switch, since a caller tracking which peer nominates now has it the other way round.
- `StunMessage.errorCode()`, `errorCodeValue()` and `iceRoleClaim()`. The wire format for an error is not the integer, the hundreds digit occupies three bits of one byte and the remainder the next, so 487 travels as a 4 and an 87, and until now this could only render a code and reason together for a human. Anything deciding what to *do* about a refusal needs the number, and parsing it back out of that string would be a way to get it wrong.
- `ReliableDatagramServerSocket.attachIceAgent()`, which runs an `IceAgent` over the socket the server already listens on, and with it, NAT traversal that works end to end rather than in pieces. The agent knows how to find a path and nothing about sockets; the server holds the one socket that can be used to look. Attaching wires the three things the agent needs: checks go out through this socket, STUN arriving here is handed to it, and its clock comes from the runtime tick. It has to be this socket and no other, because a NAT keeps one mapping per socket, a check sent from anywhere else opens a hole for a port the peer was never told about, and the path it proves is not the path the session would then use. Inbound traffic is sorted in three stages: a reply to an outstanding `discoverPublicAddress` query first, then the agent, then the reliable decode. The agent reports whether it took a datagram, so anything it does not recognise falls through to the session rather than being swallowed by a component with no use for it, which matters because a peer keeps checking while its session is already carrying data. One agent per socket, since two would answer each other's checks. Covered by a test that stands two servers up on real sockets, negotiates between them, and then dials a reliable session over the pair ICE chose and carries a message across it; removing the agent from the receive path fails it with the two peers never connecting.
- `crossbyte.net.ice.IceAgent` and `IceCredentials`: the part of ICE that actually connects two peers. Candidates are checked with signed STUN requests, the ones that answer are kept, the controlling peer nominates the best of them, and the peer at the other end, seeing only its own half, arrives at the same pair. A check arriving for a pair not yet tried causes that pair to be tried immediately, which is the piece hole punching depends on: a NAT admits a datagram only after one has gone out to that destination, so the first check in each direction is what opens the mapping for the other and neither side can wait. A response reporting a mapping the sender did not know it had becomes a peer-reflexive candidate, frequently the only kind that works. Unanswered checks retransmit on RFC 5389's schedule, seven attempts, doubling from half a second, and when the last one runs out the failure is reported rather than waited on forever, because a datagram that reached nothing looks exactly like one still in flight. The agent owns no socket: it says what to send through `onSend`, is told what arrived through `receive`, and takes time through `poll`. That is required rather than tidy, since checks have to leave from the very port a peer listens on, and it has the effect that two agents can be pointed at each other and run to completion with no network at all, which is how the whole exchange is tested, deterministically, on every target including the browser. `IceCredentials` carries the fragment and password a check is signed with, refuses lengths below the RFC's minimum entropy, and keeps the password out of `toString`, since a credential that reaches a log has been published. Not done yet, and named rather than hidden: TURN, and the role conflict resolution that settles two peers who both claim to be controlling, the tiebreaker is generated and sent, but a conflict is not yet acted on.
- `SecureRandom.isSupported`. `getSecureRandomBytes` throws on a target with no CSPRNG rather than falling back to something that only looks random, which is right, but a caller that would rather take another path had no way to ask, and everything built on it inherited that. The interpreter and neko report false; the ICE agent aliases this, because transaction ids and tiebreakers that can be guessed are worse than none.
- STUN short-term credentials and the attributes a connectivity check carries: `MESSAGE-INTEGRITY`, `FINGERPRINT`, `USERNAME`, `PRIORITY`, `USE-CANDIDATE`, `ICE-CONTROLLING`/`ICE-CONTROLLED` and `SOFTWARE`. Both digests are computed over a message that does not exist yet, RFC 5389 has the header's length field rewritten to cover the attribute about to be appended, and only then is the hash taken over everything before it. Get that wrong and the result verifies perfectly against your own code and against nobody else's, which is why the tests are pinned to RFC 5769's published vectors rather than to a round trip, in both directions: the sample request and IPv4 response verify as they arrive, and the signing path reproduces their `MESSAGE-INTEGRITY` and `FINGERPRINT` bytes exactly. A decoded message now keeps the bytes it arrived as, because integrity cannot be checked against a re-encoding, attribute padding is unspecified, and RFC 5769 pads a username with spaces where this encoder writes zeros, so a receiver that re-encoded to verify would reject valid traffic from anyone whose padding it did not happen to share. The attribute being hashed is located by walking the list rather than scanning for its tag, since a software name or transaction id can contain those four bytes and hashing the wrong span is how a good message gets rejected or a bad one accepted; that case is tested separately, because the RFC vectors pass either way. Tags are compared without a short circuit, so a forged one cannot be built a byte at a time from how long the rejection took. HMAC-SHA1 comes from `haxe.crypto.Hmac` rather than the bundled libsodium, which offers SHA-256 and SHA-512 and no SHA-1, so this needs no native bridge and works on every target, the browser included.
- `crossbyte.net.ice.IceCandidate`, `IceCandidatePair` and `IceCandidateType`: the addresses a peer can offer, and the order both peers will try them in. ICE does not negotiate an address, it races them, each side pairs everything it gathered against everything the peer sent, sorts, and works down the list until a check answers. The sort is the part that has to be right, because each peer does it alone and RFC 8445 requires the two to agree: peers working one list in different orders spend their checks on different pairs, and the cheapest working path is found late or not at all. The priorities are the RFC's, recommended type preferences included, so a CrossByte peer and a browser order the same pairs identically, 2130706431 for a host candidate and 1694498815 for a server-reflexive one are the numbers that appear verbatim in real SDP, and they are asserted against arithmetic done outside Haxe rather than against this implementation's own output. Pair priority is an `Int64` because the formula needs one: `2^32 * MIN(G, D)` reaches about 9.15e18 against a signed 64-bit ceiling of 9.22e18, so the RFC's exponents fill the type almost exactly, and computing it in an `Int` would wrap on a target with real 32-bit integers while merely losing precision on one whose numbers are doubles, a disagreement between targets rather than a crash. Pairing leaves out what cannot reach rather than failing it a round trip later: different address families, or different components. Candidates naming the same address, port and component count once, because a host and a reflexive candidate are the same place when no NAT sits between them. Pruning by candidate base (section 6.1.2.4) is not done and says so, since pruning by a base that was guessed rather than recorded would drop pairs that were not redundant; the cost is one spare check, not a wrong answer. None of it touches a socket, so it runs on every target including the browser, which is the one most likely to be talking ICE to a stack it did not write.
- HTTP/2 connections are counted, limited and reaped on the server. They were none of those things: `__serveHttp2` constructed a handler and returned, so `maxConnections` was a limit a peer could ignore entirely by speaking HTTP/2, and the sweep that closes idle HTTP/1.1 connections never walked them. An HTTP/2 connection is idle between requests by design, so the deadline depends on what it owes, the keep-alive allowance with no stream open, the request timeout with one open and nothing arriving. Draining closes them through the handler so the peer gets a GOAWAY naming the last stream processed rather than a socket that simply stops.
- Pooled HTTP/2 client connections expire, through `H2ConnectionPool.idleTimeoutSeconds` and `reapIdle()`. Reuse is the point of the pool and an unbounded one is a leak: every origin ever contacted kept a socket and a parked reader thread for the life of the process. `acquire` reaps what it walks past, which covers a program that keeps making requests; `reapIdle()` is for one that stops.
- A cap on the compressed size of a single header block, across all of its CONTINUATION frames (`H2ServerConnection.maxHeaderBlockSize`). SETTINGS_MAX_FRAME_SIZE bounds each frame and nothing bounded the run, so a peer could send HEADERS without END_HEADERS and then CONTINUATION frames forever into a buffer that only grew. SETTINGS_MAX_HEADER_LIST_SIZE is no help either, it limits what the block decodes to, and such a block never reaches the decoder.
- `-D crossbyte_no_http2`, which removes the registry's reference to the bundled backend so dead code elimination can take the framing layer with it. Measured at 171 KB on a 4.1 MB native binary. The existing `autoRegisterBundled` flag stops the registration but not the linkage; only the define removes the reference.
- Rapid Reset defence on the HTTP/2 server (CVE-2023-44487), tunable through `HTTPServerConfig.http2MaxResetStreams` and `http2ResetWindowSeconds`. `SETTINGS_MAX_CONCURRENT_STREAMS` is not a defence against this and cannot be made into one: a reset stream is a closed stream, so it frees its slot the instant it arrives, and a peer that opens a stream and resets it immediately never approaches the limit while still making the server route, allocate and dispatch every request. Streams abandoned before their response are counted per window instead, and a peer past the budget gets GOAWAY with ENHANCE_YOUR_CALM, nothing it sent was malformed, there was simply too much of it. A reset arriving after the response is not counted, because a client cancelling a download it has already read enough of does exactly that.
- `crossbyte.net.LocalAddress`, with `INetHost.localAddressFor` and `ReliableDatagramServerSocket.localAddressFor` beside it: which of this machine's addresses would reach a given peer. This is the candidate ICE calls a host candidate, and it was the one CrossByte could not produce at all, a socket bound to `0.0.0.0` reports `0.0.0.0`, which is every interface and therefore names none. It matters exactly where a reflexive address cannot help: two peers behind the same NAT reaching each other by public address would need that NAT to hairpin a packet back in to the network it came from, which plenty of consumer equipment will not do, while the two sit one hop apart on the same subnet. Both obvious implementations are wrong, and were measured to be before this was designed. Resolving the hostname answered `172.28.192.1`, a WSL adapter nothing on the LAN can reach. Enumerating interfaces answered with nine IPv4 addresses, Tailscale, two VMware adapters, four Hyper-V and WSL adapters, loopback, and one real one, so offering them all spends a peer's connectivity checks on eight that cannot work and hands it a map of every virtual network on the machine, which is the fingerprint browsers went to the trouble of `.local` mDNS names to stop leaking. What this does instead is ask the routing table: connecting a throwaway UDP socket toward the destination is what makes the kernel commit to an interface, and the source address it chose is the answer. Connecting a UDP socket transmits nothing, so the destination need not be reachable or even exist, and the stand-in for "somewhere out on the internet" is from RFC 5737's documentation range rather than a real host, so the lookup implicates nobody. No port comes back and none is needed: a NAT is what makes a reflexive port differ, nothing translates a local address, and so the port to dial is `localPort`. Available where `discoverPublicAddress` is not, it asks the machine rather than the network, so the stream hosts that refuse `dial` for want of a single endpoint still answer this.
- `crossbyte.net.ReflexiveAddress`: the address and port a socket appears as from outside, as a public type. The STUN work returned an anonymous structure declared inside an `_internal` module, so naming the result of a public API meant importing from `_internal`, which nothing else here asks of a caller: `Certificate` and `Key` alias their internal counterparts privately and expose public names.
- `INetHost.discoverPublicAddress`, gated by the same `canDial` that gates dialling. The two are not separate capabilities that happen to coincide: both need one socket to serve accepting and connecting, so a host that cannot dial from its listening endpoint has no single endpoint to ask about either. One flag rather than two that could drift apart.
- `StunClient.isSupported`, in the form the rest of `crossbyte.net` uses, five of its classes already report it, and a caller should be able to branch rather than learn from a failed future.
- `ReliableDatagramServerSocket.discoverPublicAddress()`: where this server is reachable from outside, asked through the socket it already listens on. `StunClient` answers the general question by binding a socket of its own, which cannot be this one, the server holds the port, and a NAT keeps one mapping per socket, so a reflexive address discovered anywhere else describes somewhere no peer can reach this server. The request goes out through the bound socket and the reply is picked out of ordinary inbound traffic by its transaction id, so a query costs no extra socket and disturbs no session. One at a time, since two would race for the same reply. Tested against a STUN server stood up inside the suite rather than a real one, including a reply carrying a mismatched transaction, which is refused, believing one would have a peer publish an address of the sender's choosing to the whole mesh.
- STUN, as `crossbyte.net.StunClient` over an internal `StunMessage` codec: what address the rest of the world sees a socket as. A peer behind NAT cannot answer that locally, `localAddress` is the private side of the mapping, and the address it must publish for others to dial is the public side, so this is the first thing any peer-to-peer transport needs, and the first step of the WebRTC path in general. `discoverFor` asks from a nominated local port rather than an arbitrary one, because a NAT holds one mapping per socket and an answer about the wrong port describes somewhere nobody can reach this peer; that is the same distinction `ReliableDatagramServerSocket.connect` exists for. Replies are matched against the request's transaction id, since a datagram socket accepts from anyone and an unchecked reply is an attacker choosing the address a peer publishes to the whole mesh. `XOR-MAPPED-ADDRESS` is preferred over the older plain attribute for the reason the XOR exists: NATs were built that rewrote anything in a packet resembling an address, so the unobscured form could arrive already "corrected" to the private address it was sent to report on. The codec needs no socket and runs on every target including the browser, where the client itself cannot: a page discovers its reflexive address through `RTCPeerConnection` instead. Verified against a public STUN server as well as by unit test.
- HTTP/2, client and server, in Haxe. HPACK, Huffman, static and dynamic tables, encoder and decoder, is pinned to the worked examples in RFC 7541 Appendix C, which is the part a round-trip test cannot check: an encoder that is merely self-consistent still produces bytes no other implementation can read. Framing, settings, streams and flow control sit on top, and both halves run on every target including the browser, because none of it needs a socket. Server: set `HTTPServerConfig.http2Enabled` and one listener serves both versions, deciding per connection, ALPN over TLS, the connection preface over cleartext, since RFC 9113 retired the `h2c` upgrade and left prior knowledge as the only cleartext mode. Requests reach the same routing, middleware, static-file and CORS pipeline an HTTP/1.1 request does; that took separating "decide a response" from "write HTTP/1.1", which `HTTPRequestHandler` had done in one breath. Client: set `URLRequest.httpVersion`, and nothing else, the bundled backend registers itself on demand. Connections are pooled per origin and shared, so concurrent requests to one host are concurrent streams rather than one connection each, and `URLLoader.close()` resets just that stream instead of dropping everyone else's.
- ALPN on `sys.ssl.Socket`, via `crossbyte.net.ServerSocket.setALPN()` and `Socket.alpnProtocol`. Nothing in the Haxe standard library exposes it, which is what made `h2` over TLS unreachable rather than merely unimplemented; mbedTLS has carried the support all along and hxcpp already links it. Native only, so `FlexSocket.alpnSupported` says whether it will reach the handshake, and `setALPN` is a no-op rather than an error where it will not, a caller can offer `h2` unconditionally and fall back on the `null` it reads back.
- `crossbyte.http.HTTPCancelToken`, and `URLLoader.close()` now uses it to cancel a request already in flight rather than only killing the worker that was waiting on one.
- `HTTPRequestContext.onHeaders`. A backend could previously parse a whole response and hand back nothing but the body, which made every non-core HTTP version strictly less capable than the built-in one. The built-in HTTP/1.1 client reports through it too, so both paths say the same thing.
- `ReliableDatagramServerSocket.connect()`, and `INetHost.dial()` with the `canDial` capability that goes with it: a reliable session opened from the port a server is already bound to. `ReliableDatagramSocket.connect()` makes its own transport and so leaves from an arbitrary port; for a peer-to-peer mesh that is the difference between working and not, because hole punching needs the port a peer dials out from to be the port it is reachable on, and a NAT holds that mapping for one socket. The capability is declared on the interface rather than assumed, because it is what decides whether a transport can carry a mesh at all: a listening TCP or WebSocket host answers `false` and refuses, since accepting and connecting are separate sockets there. A dialled session registers with its server so replies route through the same pump that feeds accepted ones, and it deliberately does not surface through `CONNECT`/`onAccept`, it was initiated, not accepted, and whoever dialled it already holds it. Extracted from RTPMP, which needed exactly this and had been assembling it by writing eleven private fields of `ReliableDatagramSocket` from outside: workable, unnoticeable when an internal is renamed, and wrong in a way that only shows under a second peer, since it left both the server and the session reading one transport.
- `Future.map`, `Future.flatMap`, `Future.all`, `Future.catchError`, `Future.resolved` and `Future.failed`, and a `cause` alongside `error`. `map` and `flatMap` are what every adapter between two asynchronous APIs was writing by hand, `Store.getString` built a future, forwarded one arm through a conversion and the other unchanged, and that unchanged arm is the one an adapter forgets, turning a failure into a result that never arrives. `cause` carries the failure itself rather than prose about it: `HTTPRequestHandler` chose `504` over `502` by searching the message for "did not respond within", so rewording `PHPTimeout` would have silently changed a status code. It now asks what the failure was.
- The HTTP server suite runs on Node: 90 socket round trips that had been gated to cpp, plus the config, rewrite, rate-limiter, hardening and router cases. The gate was `#if cpp`, written when the HTTP server was native-only and left in place through the port, so the target most likely to be deployed as a web server was the one whose web server no test had ever executed. It could not simply be widened, every case drove the runtime with a `while` loop, which delivers socket I/O perfectly well natively and delivers nothing on Node, where I/O arrives by returning to the event loop. Measured before designing anything: a probe pumping that way could not even read the port off a listening server. The cases are utest `Async` now, over a `pumpUntilAsync` that spreads the pumping across event loop turns on Node and delegates to the old synchronous loop everywhere else, so the native run is unchanged in speed, in assertion count, and in unwinding a failure through the test body rather than delivering it on some later turn with no stack.
- PHP is served on Node. It was refused at `validate()` on the grounds that the bridge had to return a response and Node has no synchronous socket read to produce one with, true of the old bridge, and no longer true of anything. The refusal is gone, the FastCGI parsing is shared with the native transport rather than reimplemented, and `Launch` mode uses `crossbyte.sys.NativeProcess` where a native target uses `sys.io.Process`. Covered end to end against a FastCGI backend stood up inside the suite, including a record deliberately torn three bytes in, inside the eight-byte header, which is the split that breaks a parser assuming it can always read a whole one.
- `Store.forEach`, `putString` and `getString`. `forEach` walks entries one at a time, a real IndexedDB cursor in a page, one file at a time elsewhere, and stops when the visitor returns `false`, so a large store is never held in memory the way `keys()` would hold it. `putString`/`getString` are UTF-8 and deliberately the only encoding offered, since anything richer would make the store choose a serialisation format. Absent still reads as `null` rather than `""`.
- `crossbyte.io.Store`: durable key/value storage on every target, string keys and byte values, asynchronous everywhere. IndexedDB in a browser, a directory of atomically-renamed files elsewhere. It is deliberately the shape `localStorage` has, because the shape is right and only the implementation is wrong, synchronous, string-only, five megabytes, blocking the page. Beside `File` rather than in `crossbyte.db`, which is synchronous SQL drivers plus a thread pool and so exists on neither JavaScript target. See proposal 0022.
- `crossbyte.Future<T>`: the eventual result of something unfinished, promoted from `crossbyte.rpc.RPCResponse`, which now extends it and keeps only `requestId` and `op`. Nothing about waiting for a value was ever RPC-specific, and a framework with four ways of saying "later" is three too many.
- CI runs the portable suite in a headless browser (`ci/browser-tests.hxml` and `ci/browser/run.js`). Node is not a browser, no `window`, no `document`, none of a page's restrictions, so the js suite passing there never answered whether the same bundle loads in a page. It did not: the very first browser run threw `SharedArrayBuffer is not defined` while loading, before a test could run. The runner treats any page error as a failure whether or not an assertion noticed, because that one produced no failing assertion; it just meant nothing started.
- `RPCSession`, `RPCHandler`, `RPCCommands` and `NetConnection` build for the browser. `Transport` already had exactly one case there, `TCP`, which is a WebSocket underneath, so what was missing was gating the transports a page has not got out of `NetConnection`, and the RPC layer needed nothing. A browser client can now call a CrossByte server through the same typed surface a desktop one uses.
- `RPCSession`, `RPCHandler`, `RPCCommands`, `NetConnection` and `NetHost` build on Node. The RPC layer needed no port of its own, it is protocol and dispatch over a `NetConnection`, and its session-id counter already had a non-threaded branch. `NetConnection` normalises four transports and Node now has three of them: TCP, WebSocket and reliable datagram. Only `Protocol.LOCAL` is absent, needing an operating-system IPC channel and shared memory, so `Transport.LOCAL` is a case that does not exist there rather than one that fails when used. The RPC suite runs in the portable Node tests.
- TLS servers work on Node. `ServerSocket(true)`, `ServerWebSocket(true)` and `HTTPServerConfig.tlsEnabled` all listen there now, over `js.node.Tls`, and because `tls.Server` extends `net.Server`, listen, close, address and the error event are the same calls either way. Client certificates (`requireClientCertificate`) and SNI (`addSNICertificate`) come with it. The listener is built at `listen()` rather than in the constructor, because Node takes a TLS server's whole configuration when the server is made and every piece of it arrives afterwards, which is the same instant the native path already calls "when TLS configuration is materialized".
- `crossbyte.net.ServerWebSocket` accepts sessions on Node, which was the last piece of the framework still native-only for a reason other than a browser cannot do it. The framing that answers an upgrade and reads a masked client frame is the same code every native target runs; what it sits on is a `js.node.net.Server` and an accepted socket adopted rather than dialled. A secure server refuses there and says why, and the why is worth stating precisely: Node presents certificates perfectly well through `tls.createServer`, but `setCertificate()` takes `sys.ssl` types hxnodejs has not got, so this is a missing abstraction rather than a missing capability. A Node `wss` *client* works today, needing only to verify a certificate rather than name one.
- `crossbyte.net.DatagramSocket` sends and receives on Node, over `dgram`, and `ReliableDatagramSocket` and `ReliableDatagramServerSocket` with it, the reliable layer is protocol code over the datagram socket and needed no port of its own. Nothing polls: a datagram is delivered when Node has one, so there is no descriptor for the socket registry and no read loop. Node fixes a socket's address family when the socket is made where a `sys.net.UdpSocket` takes whatever address it is later handed, so the family is chosen from the first address used and the socket replaced if nothing has bound yet. `connect()` is emulated, the remote is remembered, `send()` names it every time, and anything from another peer is dropped, because the hxnodejs extern predates Node's own. A connected socket needs a numeric address there rather than a name, and says so: a session is matched against the address replies arrive from, and resolving a name on Node needs a callback that `connect()` cannot wait for.
- `crossbyte.net.WebSocket` connects on Node. The framing is the same code every native target runs, masking, fragment reassembly, ping and pong, close codes, with only the transport swapped: `js.node.net` for `ws://`, `js.node.Tls` for `wss://`. Nothing polls there, because Node reports a completed connection, arriving bytes and a closed peer as events, so the tick is left with only the sending half. `wss` works even though a secure `ServerSocket` cannot, a client having only to verify a certificate where a server has to present one. The server half, accepting a connection and upgrading it, is still native-only.
- `crossbyte.crypto.SecureRandom` works on both JavaScript targets: `crypto.randomBytes` on Node, Web Crypto's `getRandomValues` in a browser, both of them real CSPRNGs. It threw on either before, which is why a WebSocket could not even be constructed on Node, a client masks every frame with a fresh key and the key comes from here. The browser path fills a quota at a time, since `getRandomValues` raises on a request over 65536 bytes rather than returning fewer, and refuses outright when a page has no `crypto` object at all, which is what a page served over plain http from anywhere but localhost gets. Still no fallback to `Math.random`: that would hand back something passing every test a caller could write and predictable to anyone who wanted it.
- `crossbyte.http.HTTPServer` serves on Node, along with `HTTPRequestHandler`, `Router`, `HTTPServerConfig` and the rewrite engine. It follows from `ServerSocket`: the server is one, and the request handler wanted a filesystem, which Node has. Two features refused there at first, TLS and PHP, and neither refusal was a limit of Node; both are lifted in this same release, TLS once certificate material could be named without `sys.ssl` and PHP once the bridge stopped needing a synchronous read.
- The rules of HTTP that hold on any target, supported versions, conflicting framing, header name and value sanitising, moved out of `_internal.http.Http` into `_internal.http.HttpSyntax`, which is portable and compiles for the browser too. `Http` is the client, drives a raw socket with its own TLS, and is excluded from both JavaScript targets; leaving the protocol rules inside it would have meant a second copy of a header sanitiser, which is one too many for the thing it prevents. `Http` keeps its four methods as forwards, so its callers and their tests are unchanged.
- `crossbyte.net.ServerSocket` listens on Node, over `js.node.net.Server`. Accepted connections arrive as the same `ServerSocketConnectEvent` carrying the same `crossbyte.net.Socket` as on a native target, and the wiring that makes an accepted socket indistinguishable from a dialled one now lives in `Socket` so the two cannot drift. Two differences are visible and are documented rather than papered over: Node has no bind separate from listen, so a refused address arrives as a `close` event rather than out of `bind()` and a port of `0` reads as `0` until `listen()` has claimed it; and a secure server refuses, because terminating TLS needs `sys.ssl` and hxnodejs has none.
- A `crossbyte.core.Application` drives itself on both JavaScript targets, so the same entry point that runs a desktop build runs a web one. It used to throw and point at `HostApplication`, because CrossByte's loop is a `while` that never returns and a JavaScript runtime that never gets its thread back delivers nothing, no socket, no HTTP response, no repaint. It now takes one turn at a time instead: `requestAnimationFrame` in a browser, a timer on Node, with the configured `tps` honoured as far as each can deliver it. A browser is also given a timer beside the frame request, because a page that is not visible is given no frames at all and the entire runtime would otherwise stop until the tab came back. `POLL` still refuses, neither target has a socket set to poll.
- `crossbyte.sys.NativeProcess` runs on Node, over `child_process`. It was excluded from every JavaScript target on the grounds that the implementation needs threads, but the threads are there to keep a blocking pipe read off the runtime, and Node's streams do not block, so it needs none. Output, stream closes, exit code and pid report through the same events as on the threaded targets. `standardInput` is a real `Output` over the child's stdin; `standardOutput` and `standardError` throw, because Node delivers a child's output through callbacks and there is nothing to read synchronously. A missing executable arrives as an exit with code -1 rather than a throw from `start`, which is when Node reports it.
- `crossbyte.url.URLLoader` works on both JavaScript targets, through the runtime's own HTTP client, `XMLHttpRequest` in a browser, `http`/`https` on Node. It was excluded from both: the native path drives HTTP over a raw socket with its own TLS, which a page is not allowed and which Node has no `sys.ssl` for. Going through the runtime's client also hands it redirects, proxies, certificate verification and connection reuse rather than reimplementing them. The event contract is unchanged, status, progress, complete, error, and there is no worker, because the worker exists on the native targets to keep a blocking request off the loop and no request blocks here. Verified with GET and POST round trips against a Node server.
- `crossbyte.io.FileStream` works on Node. It was excluded from both JavaScript targets for needing `sys.thread.Mutex`, which neither has, but Node has a real filesystem, and one thread means there is nothing for a mutex to exclude, so it takes the no-op shim. Write, read, seek and append all verified against real files. The browser still has no seekable file handle and keeps the refusal.
- The portable suite runs on Node in CI (`ci/js-tests.hxml`), 1013 assertions. Until now the JavaScript targets were only compiled, which is what let a broken `ByteArray` ship green: reintroducing that bug turns this suite from 1013 passing assertions into 37 failures, while every compile-only check stays clean.
- `crossbyte.net.Socket` works on Node, over `js.node.net`. It threw there before: the browser path needs the page's WebSocket and the native path needs `select()`, and Node has neither. Node's socket is asynchronous and event-driven, which is the shape the browser path already had, so the two now mirror each other, events fill the input buffer and the tick only pushes queued writes. Verified with a TCP round trip against a Node echo server rather than by compiling.

- static file responses stream instead of being loaded whole. `__serveFile` called `file.load()` and then copied the entire body into the socket's output buffer, so serving a 2 GB download cost 2 GB of resident memory twice over, and a `maxOutputBufferSize` configured to protect the server would kill the transfer it had just been made to buffer. Identity responses over 256 KB now write their head and pump the body in 64 KB slices under a 256 KB watermark, driven by the socket's own drain rather than a timer: measured on a 2,097,289-byte file, peak buffering was 262,144 bytes, exactly the watermark, an eighth of the file, where the old path's peak was the file itself. A 512 KB burst budget bounds one pump invocation, because a peer that drains as fast as the server writes keeps the buffer under the watermark forever and would otherwise read and write the whole file inside a single tick, starving every other connection on the runtime. The size test now runs ahead of content negotiation, so a large file streams as identity for a client that offered gzip: compressing a multi-gigabyte video wastes memory for nothing, and doing it incrementally needs chunked framing that does not exist yet. A streamed response ends its connection, the body is still arriving when the head has been written, so keeping the connection would let the next request's response interleave into it; combining the two is follow-up work named in proposal 0017
- a peer that stops reading no longer holds a streamed transfer forever. Bounding the pump below `maxOutputBufferSize` is what stops the overflow policy killing a healthy transfer mid-body, but it also meant the one mechanism that reclaimed a stalled connection could never fire, and the receive deadline had already been cleared when the request arrived, so nothing else would either. A transfer that hands no bytes to the kernel for 30 seconds is now closed, without a `408`: the status line for that response left with the head, and a second one would land inside the body as though it were file content
- a file truncated mid-transfer no longer sends fabricated bytes. `FileStream`'s synchronous `readBytes` discards the short-read count and copies the full requested length regardless, so a log rotated or a build artifact replaced under a live download put a slice of zeroes on the wire as though it were content, and a client resuming by `Range` would stitch that hole permanently into its file. Each slice's read is now measured against what it asked for, and a short one ends the connection: a visibly short response is detectable against `Content-Length`, and silently wrong bytes are not. Files of 2 GB and over are refused with a `500` rather than served wrong, because `File.size` is an `Int` and wraps negative there, the positive-truncation case, where a 4 GB file stats as a small one, is undetectable on this standard library and is recorded as such
- HTTP/1.1 keep-alive: a connection now carries more than one request. `Connection: close` was hardcoded into every response path, so every request paid a TCP handshake, and a full TLS handshake where `tlsEnabled` was set, to be answered, and a browser fetching a page with a missing favicon paid two. `HTTPServerConfig` gains `keepAlive` (default `true`, which is what HTTP/1.1 specifies and what every client already expects), `keepAliveTimeout` (5s idle) and `keepAliveMaxRequests` (100). Setting `keepAlive = false` reproduces the old behaviour byte for byte, down to the header's position in the response. The handler became a state machine over the connection rather than a one-shot: one `__decideKeepAlive` is taken when the header is written and acted on by a single response funnel, so the header and what the socket actually does cannot disagree, the twelve scattered `close()` calls that preceded it could each have drifted from the header they followed. A response keeps the connection only when the request was fully consumed, the client's `Connection` tokens allow it, the count is under the limit, and the status is not 400/408/413/5xx; 404, 405 and 304 keep it, which is the point. The consumed-request condition is what makes the rest safe: a `429` is decided before the request line has even been read, so keeping that connection would re-parse the same bytes forever
- pipelined requests are answered in order instead of being destroyed. Both response builders ended with `__incomingBuffer.clear()`, which under close-per-request discarded nothing that mattered; the moment a connection survives its response, that call is deleting a request the client has already sent, and the client then waits for an answer that will never come and blames the wrong end. The unconsumed tail is preserved and re-parsed through a flat driver loop rather than a recursive re-entry, a megabyte of small pipelined requests would otherwise have been tens of thousands of stack frames
- `drain()` no longer waits on connections that are merely idle. It waited on a connection count that, under keep-alive, includes every persistent connection sitting between requests, so a graceful shutdown would have paid its full timeout on a server that was doing nothing. Idle connections are closed as drain begins and the rest are marked to close after the response they are in the middle of
- request duration is measured per request rather than per connection. `http_request_seconds` observed accept-to-close, which under keep-alive would have billed one request for the entire session including idle time; it now runs from a request's first byte to its response being written
- `crossbyte.http.Router`: method and path routing for the HTTP server, supplied as middleware rather than as core surface. The dynamic surface until now was the bare `Middleware` typedef, `GET` served the filesystem, a `POST` to anything that was not PHP got a `405`, and every application that wanted `POST /api/users/42` to reach a function began by hand-writing the same segment split, method switch and id extraction. `get`/`post`/`put`/`delete`/`head`/`options`/`any` register patterns that compile once into segment lists at registration: a literal, a `:param` capturing exactly one segment, or a trailing `*rest` capturing the remainder. No regular expressions, a route table is small, fixed and written by the application author, so a segment walk answers it with nothing to compile per request and no pathological pattern to defend against. Precedence is registration order, first match wins, rather than specificity scoring: ordering rules that need a document to predict are how two routes silently swap priority in a refactor. Methods outside the static dispatch gate work, because bodies are read by framing rather than by method, so a `PUT` route receives its body. The refusals are the valuable part: a pattern with `*rest` anywhere but last, an empty pattern, a capture with no name, and a pattern that names one capture twice are all rejected at registration, the last because a duplicate silently overwrote the earlier value, which is the one failure of the four that produces a wrong answer instead of no answer
- `HTTPServerConfig.requestTimeout`: seconds a request has to arrive in full, request line, headers and body together, answered with `408 Request Timeout` and a closed connection when missed. Defaults to 60; `0` disables. This window was uncovered: the rate limiter runs only once a complete header block exists, so a client trickling one byte at a time, or connecting and sending nothing, was never rate limited and held a connection slot for as long as it cared to, and with `maxConnections` defaulting to 256, tying up every slot cost an attacker almost nothing. Enforced by a sweep on the server rather than by the data path, because the clients this exists for are precisely the ones that stop sending: a check that runs on arrival never fires on a connection that has gone quiet. The sweep arms itself on the first accepted connection, walks active handlers four times a second, and disarms when none remain, so an idle or drained server leaves nothing ticking. Receipt of the full request clears the deadline, response time is the server's own and is not billed to the client
- Postgres parameter binding: `PostgresConnection.requestParams(sql, params)` runs a statement through `PQexecParams` with `$1`-style placeholders, and `PostgresParameter` binds a value as `Text`, `Binary` or `Null`. The driver had no binding at all, statements were assembled as SQL text with values escaped in, and `PQescapeStringConn` works on NUL-terminated C strings, so any value was truncated at its first zero byte, silently and with no error. A ciphertext blob written that way became a fragment of itself, which for an encrypted event log is data loss rather than a performance note. Results no longer go through JSON either, which could not represent a byte sequence that is not valid UTF-8: the bridge returns a length-prefixed block carrying NUL bytes, measured with `PQgetlength` rather than `strlen`, and values arrive as `haxe.io.Bytes`. `NULL` stays distinct from an empty value in both directions, since collapsing them makes a NULL and an empty string the same row and only surfaces later in a `WHERE` clause. Results are requested in text format, so `bytea` arrives as its exact `\x` hex rendering and `PostgresWire.decodeByteaHex` returns it to bytes, binary results would mean decoding every column type from its network representation by OID, for no gain on the case that mattered. Verified in three separable parts, stated rather than blurred: the wire encoding is covered by eleven cases running on every target, the C++ is checked by compiling in the native suite, and the five round-trip cases against a real server run for the first time in CI. `PostgresStatement.executeParams(params)` binds positionally through the same path and reports results through the statement's existing machinery, so the statement API is no longer stuck with substitution; `execute()` and its named `parameters` are unchanged and now documented for what they cannot carry, because mapping named onto positional means scanning statements for placeholders (`docs/proposals/0016-postgres-parameter-binding.md`)
- `Data | Postgres` CI job and `PostgresIntegrationTest`: the first tests in this repository that talk to a real PostgreSQL server. The driver had three tests, all of which checked the support flag or that `open` throws when unsupported, nothing had ever connected, so the entire query path shipped unexercised. A `postgres:16` service container and `libpq5` (the driver dlopens `libpq.so.5` rather than linking it) back a suite covering connect and server version, row round-trips, `affectedRows`, rollback discarding and commit keeping, escaping a value containing quotes and backslashes, and a failing statement raising rather than returning an empty result set, the last mattering because a broken query reading as a query that matched nothing is indistinguishable from success. The suite skips cleanly wherever `CROSSBYTE_PG_HOST` is unset, so a developer without a database still gets a green run; `CROSSBYTE_PG_REQUIRED`, which only CI sets, turns that skip into a failure, because otherwise a broken service container or a missing libpq would skip every case and report success, the shape that let the jvm suite stay red unseen. Marked `@:suiteExempt` since it needs a live server and so cannot be reachable from `addNativeSmoke`. Groundwork for parameter binding: the driver builds SQL by string substitution and returns every value as a JSON string, neither of which can be fixed safely without a server to check the fix against
- `crossbyte.db.SchemaMigrator` and `Migration`: versioned schema migrations applied in order, exactly once each, one transaction apiece. This was the last piece of a service skeleton CrossByte did not supply, `Config`, `Logger`, `Metrics`, `ProcessLifecycle`, `ConnectionPool` and `AsyncDatabase` all existed, so the first thing any service using the database layer had to write was the part that decides whether its tables exist yet. Driver-specific work is three callbacks (`execute`, `readApplied`, `recordApplied`) rather than an interface, the same choice `ConnectionPool` and `AsyncDatabase.transaction` make and for the same reason: these drivers share no base type and demanding one would exclude every driver written outside the package. `recordApplied` is the caller's so the values go through the driver's own parameter binding, generating that INSERT here would put a migration name into SQL text. Statements are supplied individually rather than as one semicolon-separated string, because splitting SQL on `;` breaks on the first string literal or trigger body containing one. The valuable part is what it refuses: an already-applied migration whose content changed (the edit will never re-run, so this database and every other one that ran the original are now different while the file claims otherwise), a pending migration numbered below one already applied (the shape a merge produces, applying it yields a schema no in-order database will ever have), two migrations sharing a version, a half-supplied transaction, and a bookkeeping table name that is not a plain identifier since it reaches the default DDL. A failing migration is rolled back, not recorded, and stops the run rather than letting later migrations run against a schema that does not exist. No `down`: a rollback written before the failure it undoes is understood is guesswork, and one that drops a column destroys the data the incident needed. Optional `lock`/`unlock` callbacks serialise concurrent migrators, held across the whole run so two instances starting within a second of each other during a rolling deploy cannot both read an empty table and both apply migration 1; released on every path out, including a refusal that happens before any migration runs, since a lock left held would stop every other instance from ever migrating. Engine-specific by necessity, `pg_advisory_lock` on PostgreSQL, `GET_LOCK` on MySQL, nothing needed on SQLite. Sixteen cases run on every target against an in-memory connection, and were verified able to fail, disabling the drift check, the ordering check and the rollback produced failures in exactly those three cases and left the other nine green (`docs/proposals/0015-schema-migrations.md`)
- Windows service control: `ProcessLifecycle.installServiceControl(name)` attaches to the Service Control Manager, so `sc stop`, a service restart and system shutdown latch the same request `Ctrl+C` does and run the same callbacks. This is what the graceful-shutdown work in proposals 0001 and 0003 was missing on its deployment target, `installDefaultHandlers()` arms `SetConsoleCtrlHandler`, and a process started by the SCM has no console and receives none of those events, so on a Windows Server host `HTTPServer.drain()` never ran and the SCM killed the process on its timeout with in-flight requests severed. Correct in the configuration that gets tested, inert in the one that ships. The SCM is told `SERVICE_STOP_PENDING` the moment a control arrives (its clock starts when it sends the control, not when the application reacts) and `SERVICE_STOPPED` once `poll()` has run the callbacks and torn the runtime down; `reportServiceStopPending(waitHintMs)` extends the default 30-second hint, and `deferServiceStop` plus `reportServiceStopped()` hand the final report to an asynchronous drain, which `HTTPServer.drain(timeout, onComplete)` needs since it returns before the drain finishes. `isService` reports whether the SCM started this process. The dispatcher and both OS callback threads touch only Win32 and one atomic, never the Haxe runtime, which hxcpp's collector cannot see on a thread Windows created, and the attach handshake is polled from Haxe rather than waited on natively for the same reason. Everything is a no-op off the SCM, so a server written for service deployment runs unmodified from a console, and POSIX targets keep using `SIGINT`/`SIGTERM`, which is what systemd sends. CI covers the wiring and the console path; the SCM transitions themselves need a manual `sc create`/`sc stop` check on a Windows host, which proposal 0014 records rather than assumes (`docs/proposals/0014-windows-service-control.md`)
- `samples/windows-service`: an `HTTPServer` that drains in-flight requests when the Service Control Manager stops it, and behaves identically under `Ctrl+C` from a console. Built in CI with the other samples, and the harness for the manual `sc create`/`sc stop` verification the suite cannot perform. It exists mainly to demonstrate the three settings a real service needs and the specific thing each one prevents: `installServiceControl` rather than `installDefaultHandlers`, or a `sc stop` runs no callback at all; `exitOnShutdown = false`, or the runtime exits the moment the callback returns and the asynchronous drain never gets another tick to finish on; and `deferServiceStop`, or `poll()` reports the service stopped while connections are still being served. It also logs to a file, because a service has no stdout and without one there is no way to see whether the drain ran. Verified end to end by sending a real console control event to the running sample: `stop requested; draining` through `drain complete; reporting service stopped` to a clean exit
- pool and connection metrics, registered automatically wherever a registry is configured. `ConnectionPoolOptions.metrics`/`metricsPrefix` publish open/in-use/idle/max gauges bound to the pool's own accessors, counters for acquisitions, opens, timeouts and retirements, and an `acquire_wait_seconds` histogram, the measurement that separates a saturated pool from a slow database, since both otherwise present as slow queries. `ServerWebSocket.publishMetrics()` adds session counts and accepted/closed totals, and both it and `HTTPServer` gain `output_buffer_bytes_max` and `output_buffer_bytes_total`: `maxOutputBufferSize` bounds one connection, but many peers each sitting just under that bound is invisible from the ceiling alone, and the max separates one stuck client from a server-wide back-up. Everything published is an aggregate across connections, no label carries a peer address or session id, because such a series outlives the connection that named it and grows without bound on a server with churn, which is how a metrics pipeline gets taken down by the thing meant to observe it
- `JWKSet` and `JWK`: JWK Set ingestion (RFC 7517), turning a provider's published keys into the PEM maps `JWTSigner.RS256` and `JWTSigner.ES256` already accept, `JWT.make(RS256(JWKSet.parse(json).pemsFor("RS256")), issuer, audience)`. RSA keys are rebuilt from `n`/`e` and P-256 keys from `x`/`y` into DER `SubjectPublicKeyInfo`, indexed by `kid`. `parse` throws only when the document itself is unusable; a key it cannot verify with goes to `ignored` with a reason instead, because providers stage the next key in a set before signing with it and refusing the whole document over one unrecognised entry would lock a service out of the keys it can still use. A duplicate `kid` keeps the later key and reports the collision, and a key whose `alg` names a different algorithm is refused rather than pressed into service. Verified by rebuilding real OpenSSL-generated keys from their JWK numbers and requiring them to verify genuine RSA and ECDSA signatures, not merely to parse
- `WebSocketConformanceTest`: a server-side protocol suite driven by a hand-written client over a real socket through a real handshake, covering fragmentation, a control frame interleaved between fragments, several frames pipelined into one write, a frame split across writes, extended payload lengths, and the rejections RFC 6455 requires, unmasked client frames, reserved bits, fragmented and oversized control frames, an orphan continuation, a data frame interrupting a fragmented message, invalid UTF-8, and an oversized payload. Eight of the fourteen fail against the source before the read-path fix. `RawWebSocketClient` composes frames by hand so a test can send what a browser sends, and, more usefully, what no cooperating client will ever send, which is coverage no amount of running CrossByte against itself provides

- expanded the libsodium bridge beyond Ed25519 with `Aead` (XChaCha20-Poly1305-IETF), `X25519`, `KeyExchange` (crypto_kx), `GenericHash` (BLAKE2b), `HKDF` (HKDF-SHA-256), `Argon2id` password hashing/derivation, `ConstantTime.equals`, and `SecureMemory.wipe`, all backed by RFC/draft known-answer tests (`docs/proposals/0001-server-hardening.md`)
- `crossbyte.sys.ProcessLifecycle`: cooperative shutdown hooks fed by `SetConsoleCtrlHandler` on Windows and `SIGINT`/`SIGTERM` on POSIX cpp targets, with ordered once-only callback dispatch and optional runtime exit
- EdDSA (Ed25519) JWT signing and verification per RFC 8037 via the native Ed25519 backend, replacing the runtime `"not implemented"` throw; verified against the RFC 8037 appendix A JWS vector
- direct TLS termination in `ServerSocket` (`new ServerSocket(true)` + `setCertificate`/`addSNICertificate`, plus `requireClientCertificate()` for mutual TLS), with handshakes advanced across ticks so a slow or hostile peer never blocks the runtime loop, a `handshakeTimeout` guard against half-open connections, and `pendingHandshakeCount()` for metrics; `HTTPServerConfig.tlsCertificatePath`/`tlsKeyPath` turn `HTTPServer` into an HTTPS server (`docs/proposals/0002-direct-tls.md`)

- graceful shutdown: `ServerSocket.stopAccepting()` releases the listening socket while established connections keep working (freeing the port for a successor process), and `HTTPServer.drain(timeout, ?onComplete)` stops accepting, waits for in-flight requests, then closes, pairs with `ProcessLifecycle` so a service stop finishes live responses instead of severing them (`docs/proposals/0003-graceful-shutdown.md`)
- `crossbyte.core.Config`: layered service configuration from defaults, `key=value` files, and environment variables (with prefix stripping), with case- and separator-insensitive keys, typed accessors (`getInt`/`getFloat`/`getBool`/`getList`), and `require()` for values a service cannot start without; malformed numbers are rejected outright rather than silently truncated
- structured logging: `Logger` gains severity levels (`LogLevel`), `key=value` structured fields, optional JSON output, optional timestamps, and a replaceable `sink`; the existing `info`/`error`/`separator` helpers keep their exact output
- `crossbyte.db.ConnectionPool<T>`: driver-agnostic connection pooling, lazy creation to a fixed ceiling, reuse, acquire timeout, optional health validation, `discard()`, and a `withConnection()` scope that returns the connection even when the body throws; works with every driver without them needing a shared interface
- `crossbyte.db.AsyncDatabase<T>`: runs database work on a `TaskPool` worker holding a pooled connection and delivers the resulting `Task` completion back on the submitting runtime thread, so synchronous drivers no longer block the event loop; includes a `transaction(begin, commit, rollback, body)` scope (`docs/proposals/0004-db-pooling-and-async.md`)
- `crossbyte.metrics`: thread-safe `Counter`, `Gauge` (including gauges bound to a provider function), and `Histogram` (cumulative buckets, plus `time()` which records even when the body throws), a get-or-create `Metrics` registry with Prometheus-grammar validation, and `toPrometheus()` text exposition output (`docs/proposals/0005-metrics.md`)
- socket write backpressure: `Socket.maxOutputBufferSize` bounds how much undrained data may accumulate for a peer that has stopped reading, `outputOverflowPolicy` chooses between closing the connection (default) and throwing, and `outputBufferLength` exposes the current depth; opt-in, so existing behavior is unchanged (`docs/proposals/0006-socket-backpressure.md`)
- `ci/stress-tests.hxml`: a concurrency stress suite covering TaskPool drain completeness, ConnectionPool contention, Metrics registry contention, Timer id allocation, and socket backpressure, races the single-threaded interpreter suites cannot see; wired into the Windows native CI job (`tests/stress/README.md`)
- `HTTPRequestHandler.respond()`: middleware can now answer a request itself (health checks, metrics, auth replies, small API routes) instead of only calling `next()` or failing with a status
- `crossbyte.metrics.MetricsEndpoint`: middleware serving a registry in Prometheus text format, rejecting non-`GET`/`HEAD` with 405 and never letting a failed render break the request path
- opt-in `HTTPServer` instrumentation via `HTTPServerConfig.metrics`/`metricsPrefix`: request counts labelled by status class, a request-duration histogram, and a connection gauge bound to the server's live counter (`docs/proposals/0007-metrics-wiring.md`)
- `crossbyte.crypto.PublicKeySignature`: RSA and ECDSA over SHA-256 via the mbedTLS that already ships with hxcpp, including conversion between ASN.1 DER and the raw `r||s` form JWS carries
- `RS256` and `ES256` JWT signers, replacing the runtime `"not implemented"` throw, this is what lets a service verify OpenID Connect tokens from Google, Microsoft, and other providers; `JWTSigner` gains an `ES256` constructor (`docs/proposals/0008-asymmetric-signatures.md`)
- libsodium 1.0.21 is vendored as source and compiled by hxcpp, the way BLAKE3 already is: the whole `crossbyte.crypto` surface (AEAD, X25519, key exchange, Argon2id, Ed25519, BLAKE2b) now works on every target with no external dependency, no install step, and no build flag. The prebuilt `libsodium.lib` is deleted, a 2.7 MB opaque binary replaced by 2.3 MB of reviewable source, and Windows ARM64 works by construction (`docs/proposals/0009-libsodium-platforms.md`)
- `ServerWebSocket` graceful shutdown: `stopAccepting()` releases the listener while sessions keep working, and `drain(timeout, ?onComplete, closeCode)` sends every session a close frame (1001 "going away") so clients can tell an orderly shutdown from a network failure; adds `clientCount`, `draining`, and `WebSocket.closeWith(code, reason)` (`docs/proposals/0010-websocket-drain.md`)
- stress case guarding the `TaskPool` garbage-collector deadlock fixed in this release: idle pools are held parked while other threads allocate hard, which wedges the process on the pre-fix code and completes in milliseconds on the fixed code
- `CrossByte.defaultSocketCapacity` (1024, was effectively 64): the poll backend's starting allocation is now tunable, sparing a ramping server roughly seven grow-and-rebuild cycles on the way to a thousand connections; it was never a ceiling, since the registry already grew on demand
- `ServerApplication.defaultTicksPerSecond` (default `0`, inherit the runtime's 12): a seam for services whose latency bound is tick cadence, applied before `INIT` so a subclass can still override it. The runtime's 12 ticks per second is a deliberate low-power default and is left alone; under the stock `POLL` loop it bounds how long a ready socket waits, while a loop supplied through `MainLoopType.CUSTOM` can pass a non-zero `pump` socket timeout and be woken by readiness instead (`docs/proposals/0011-poll-capacity-and-tick-rate.md`)
- accepted `wss://` sessions now run the deferred, timeout-guarded TLS handshake the client path already used; previously a server-side handshake happened implicitly on first read with no bound, so a peer that completed TCP then stalled mid-TLS held the socket indefinitely (`docs/proposals/0012-websocket-tls-handshake.md`)

### Removed
- `StunClient.discoverFor`. It bound a fresh socket to the port it was asked about, and the only reason to name a port is that something is already using it, so the bind failed with "Operation attempted on invalid socket" in exactly the case the method existed for, and succeeded only for ports whose mapping tells you nothing. `ReliableDatagramServerSocket.discoverPublicAddress` asks through the socket that already holds the port, which is what that question needs. Removed rather than deprecated: it was a day old and could not do what its signature promised.

### Changed
- `INetHost` declares `allocateRelay`, `dialRelayed` and `permitRelayedPeer`.
  They were on the `NetHost` abstract alone, which found a relay by
  downcasting to the reliable datagram host it makes itself, so a host of an
  application's own was refused whatever it could do, and code holding an
  `INetHost` could not ask. Like `dial`, they are for a host whose one socket
  both listens and dials; a TCP or WebSocket host refuses all three, where it
  refused only `allocateRelay` before. What to change: an `INetHost` of your
  own implements the three, refusing them as it refuses `dial` if it cannot
  dial. The refusals name the protocol through the new `Protocol.toString()`:
  joined to the text, the protocol was its number, and they read "A 0 host
  cannot dial".
- The HTTP server compresses only what is worth it: a body of 1 KB or
  more, of a text-like type, in a response that is not an error. Every
  non-empty body was compressed, a 429 or a 404 cost the setup of a
  Brotli encoder whenever the client listed br, which every browser does,
  so the rate limiter did not bound what a flood of refused requests cost
  (18.8 ms a refusal on Node rather than 0.57); a two-byte answer came
  out as 22 bytes of gzip, and PNGs and archives grew. A response that
  could have been encoded now says `Vary: Accept-Encoding`, which none
  did, so a cache replayed br bodies to clients that had not asked for
  them; an encoded variant's `ETag` is made weak, as nginx does, since one
  strong tag went out on every coding of a body; and a `HEAD` is
  negotiated as its `GET` is, naming the coding and leaving out a length
  it cannot know, where it reported the identity length beside a br
  `GET`: and a route's `HEAD` gives its `GET`'s length rather than 0.
  What to change: to compress smaller bodies or other types, set
  `HTTPServerConfig.compression.minimumSize` and `.types`; to compress
  nothing, `compression.enabled = false`.
- `ci/doc-examples.js` reads doc comments written with a ` * ` down the
  left, which it passed over as holding no examples: 49 of the 96 source
  files with examples are written that way. It checks 73 examples in 23
  files and the RPC guide, where it checked two files: the MongoDB
  client's and BSON's, `Completer`, `Config`, `DtlsCertificate`,
  `HostApplication`, `HTTP2Backend`, `LogCategory`, `Logger`,
  `NetConnection`, `PrimitiveValue`, `Rectangle`, `Store`, `StunClient`
  and `URLVariables` join `File` and `RPCCommands`.
- `SlotHandle` no longer converts to `Int` by itself. A handle passed where
  an id belongs, `grid.set(entity.handle, x, y)` for `entity.slot`,
  compiled, and worked until the slot's first reuse made the handle
  1,048,576 or more, when `SpatialGrid` and `InterestSet` grew their arrays
  to fit it: 117 MB by the third reuse. What to change: use `handle.index()`
  for the slot, and `handle.toInt()` for the whole handle where it is
  written down; an `Int` assigned to a `SlotHandle` still reads one back.
- `MongoConnection.lastInsertRowID` is gone: MongoDB has no row ids, and it
  read 0 whatever was inserted. `lastInsertId` is the `_id` of the last
  document inserted. `request()` takes Extended JSON and answers a cursor
  over the result's documents, where it answered the command's reply as
  one row, and `MongoStatement` binds its `:name` parameters as BSON values,
  `parameters` takes any value, not only a string. The php backend,
  PHP's `mongodb` extension, is removed; the wire client builds for php,
  and has not been run there. What to change: read `lastInsertId`, and
  expect the documents themselves from a `find` through `request()`.
- `ReflexiveAddress.toString()` brackets an IPv6 address,
  `[2001:db8::7]:3478`; unbracketed, the port reads as the address's last
  group. And `preservesPort` no longer claims a kept port shows an
  endpoint-independent mapping: it shows neither that nor the opposite,
  and `StunClient.classifyMapping` finds the mapping itself.
- `ReliableDatagramServerSocket.connect()` to a name, and so
  `NetHost.dial()` on a reliable-UDP host, looks it up off the runtime's
  thread. It was looked up in the call, so every session the server
  carries, and every other socket and timer on the runtime, waited on the
  resolver: two seconds, natively, for a single-label name that does not
  exist. Now the session is returned at once and filed under the address
  the name resolves to, its handshake begun, when the answer comes; its
  timeout counts the lookup, and its `remoteAddress` reads empty until
  then. What to change: what the call threw `ArgumentError` for, given a
  name, it now reports on the session as an `ioError` event followed by
  the session's close, a name that does not resolve, and an endpoint
  this server has a session to already, so listen for `ioError`.
  `congestionControlFor` is asked about a session dialled by name once
  the name is looked up, and one that throws is reported the same way.
  Closing the server closes a session still waiting on its name. An
  address is still resolved, and refused, in the call; on Node a name is
  still refused.
- `DatagramSocket.connect()` to a name looks it up off the runtime's
  thread, as `send()` to one already did. It was looked up in the call,
  so every socket and timer on the runtime waited on the resolver: a
  single-label name that does not exist held it for 2.0 s natively and
  1.1 s on the jvm. Now `connect()` returns at once, and the socket is
  connected to the address the name resolves to when the answer comes;
  until then `connected` reads true, `remoteAddress` reads empty, and
  datagrams sent with no destination wait for the answer, up to 64 of
  them. What to change: a name that does not resolve is reported by an
  `ioError` event after the call returns, the datagrams waiting on it
  are dropped, and the socket is left unconnected, `connect()` used to
  throw `IOError` for one, and no longer does, so listen for `ioError`.
  An address is still connected to in the call, and on Node a name is
  still refused. `connect()` on a closed socket throws `IOError` before
  anything else.
- `URLLoader` runs its loads on a shared pool of threads kept between loads,
  rather than on a thread started and ended for each. At most
  `URLLoader.maxConcurrentLoads`: 16 by default, run at once across the
  process, and more wait their turn in the order they were made; a program
  holding many slow requests open at once, long polls say, should raise it
  to at least that many. A thread with nothing to do ends after 30 seconds.
  Against a local keep-alive server natively, 4,100 sequential loads a
  second became 6,400, and 10,200 with eight in flight became 18,600 to
  22,300. On hxcpp a host that drives the runtime with `pump()` in a loop
  that neither blocks nor allocates must sleep or call
  `cpp.vm.Gc.safePoint()` in it: the load threads allocate, a collection
  one of them starts waits for every thread, and such a loop is never
  stopped for it.
- The HTTP server's access log, one `INFO` line per response, logs under
  the category `http.access`. `Logger.setLevel("http.access", WARN)` quiets
  it and leaves everything else at `INFO`; it used to share the one global
  level, so quieting it quieted everything.
- `OAuth.getAccessToken` and `refreshAccessToken` go through `URLLoader`
  and need a CrossByte runtime on the calling thread; the callbacks run on
  that thread. On native targets and Node they return before the token
  endpoint answers, where native used to run the callbacks before the call
  returned. On the jvm and the interpreter `URLLoader` still runs its
  request inline, so there they return after it, as before.
- `JWTPayload.issuedAt`, `expiresAt` and `notBeforeTime` are
  `Null<Float>`, not `Null<Int>`, and `JWTPayloadData`'s `iat`, `exp` and
  `nbf` take an `Int` or a `Float`. Code that read one into an `Int` has to
  convert it, with `Std.int` where the value is known to fit. `generateToken`
  throws `ArgumentError` for a time that is not a finite number, and writes a
  whole number of seconds that fits an `Int` as an integer on every target.
  `JWTPayload.ofData` is no longer an implicit conversion; object literals
  convert through `JWTPayload.ofClaims`, which lets them carry other claims.
- `Argon2id.verify` throws where no Argon2id backend exists, as `hash`
  does, rather than returning `false`: that refused every password on the
  jvm, the interpreter and the browser while looking like a working check.
  Call `Argon2id.isAvailable()` first where a target may lack one.
- `BCrypt.hash` makes `$2b$` hashes rather than `$2y$`, and
  `BCrypt.needsRehash` reports a hash of any other revision, `$2y$`
  included. That is how the `$2y$` hashes earlier versions stored, which
  lack the key's terminating NUL and verify nowhere else, are found: rehash
  on a successful sign-in when `needsRehash` says so, and they are replaced
  as users return. Until then a wrong password against one costs two hashes
  instead of one. `$2b$` is what OpenBSD, Node, Python and Rust produce, and
  current PHP verifies it; a `$2y$` hash from PHP is replaced the same way,
  harmlessly.
- A synchronous `FileStream.readBytes` asking for more than the file holds
  throws `EOFError`, as its documentation says, and reads nothing; it used
  to pad the rest with zeros and return. Code that read "up to" a length
  should ask `bytesAvailable` first. `File.size` throws an `IOError` for a
  file larger than 2 GB rather than answering with a number that is wrong.
- `PostgresConnection` and `MySQLConnection` `begin`, `commit`, `rollback`
  and the savepoint methods throw an `SQLError` when the server refuses,
  after dispatching the `SQLErrorEvent` as before. They dispatched and
  returned, so a caller that did not listen could not tell a failed COMMIT
  from a committed one; `SQLiteConnection` has always thrown. Code that
  handled the event and called these without a `try` now sees the error
  thrown as well, and should catch it where it handled the event.
- `System.memoryUsage()` returns a `Float` rather than an `Int`, since a
  heap outgrows an `Int`. It is still 0 on the interpreter, hl, neko and in
  a browser, which report no figure.
- On Node and the jvm, `ProcessLifecycle.installDefaultHandlers()` takes
  over SIGINT and SIGTERM, as it already did natively, and returns `true`:
  the process no longer exits on them by itself, and the shutdown callbacks
  and `exitOnShutdown` decide when it ends.
- `SlotHandle` has 20 index bits and 11 generation bits, where it had 24 and
  8, so a `SlotMap` or `PackedSlotMap` holds at most 1,048,576 entries
  rather than 16,777,216. A map created with a larger `maxCapacity` now
  throws, as one past the old limit did.
- Log timestamps are UTC with milliseconds, `2026-09-25T09:00:00.123Z`,
  where they were local time to the second with no zone, and a control
  character in a message or field is written as an escape. Anything parsing
  the text format should expect both.
- On the jvm, the interpreter, hl and neko, `CrossByte.current()` called
  from a thread no runtime belongs to throws `IllegalOperationError` rather
  than returning the primordial runtime, as it already did natively. Code on
  a worker thread that needs a runtime should capture it on the runtime's
  own thread and hand work back through its post queue.
- A timer armed from inside a timer callback for a time already reached,
  `setTimeout(0)`, or a reschedule into the past, fires on the next frame
  rather than in the pass that armed it. Recurring timers still catch up
  within a pass as before.
- `HostApplication.advance` and `CrossByte.pump` no longer rethrow what a
  handler threw during the step, and neither does a `PassFlush` holder's
  failure escape the pass: both are contained and reported through
  `UncaughtErrorEvent.UNCAUGHT_ERROR`, as they are under the runtime's own
  loop. A host that caught failures around `advance` should listen for that
  event instead.
- A `LocalConnection` delivers what arrives for up to 2 ms at a time on
  its runtime's thread. It delivered 32 messages a tick, whatever they
  cost, 384 a second at the default tick rate, and anything faster
  waited in a queue with no bound: 2000 small messages took 63 ticks, and
  now arrive in one. Delivery is posted to the runtime when there is
  something to deliver, where a listener ran on every tick for every
  connection, and a reader with nothing to do looks every 10 ms rather
  than every millisecond, easing off from 1 ms as it stays idle. What
  waits to be delivered is bounded by `maxQueuedBytes`: past it the
  reader stops reading, and what the peer sends waits on its side. A
  `SharedChannel` keeps a connection to each channel it sends to, up to
  16, each closed after 45 s without a send, where it kept one, and
  closed it and dialled again whenever a send went somewhere other than
  the last one had.
- An RPC round trip costs less than half what it did natively: a request
  answered 928 ns to 405 ns, one answered later 1.88 us to 537 ns, and one
  with a `then` callback 2.13 us to 568 ns (BenchRpc, best of 11). Every
  `Future`: so every `RPCResponse`, and every `Completer`, made a
  `sys.thread.Mutex`, an object with a finalizer, and two handler lists,
  and the caller took the lock twice a round trip at about 250 ns each,
  since taking one on hxcpp enters and leaves a GC-free zone. On cpp the
  lock is now a word of the future's own taken with an atomic
  compare-and-swap, and the handler lists are made only for a second
  handler of a kind. A handler's throw is contained without a closure
  made to run it. Other targets keep their `Mutex`.
- `RPCSession.start()` heartbeats whether or not the session has commands,
  so a server that calls it on the sessions it accepts now pings its
  clients and closes one it hears nothing from for `heartbeatTimeout`. Its
  clients answer only if they run this version: a session of an earlier
  one does not answer pings, so heartbeat an older peer only from a side
  that also calls it often enough to be answered. A ping no longer passes
  through `beforeCall` and `afterCall`, which could refuse it or count it
  against a caller's allowance; a handler's own `ping()` is still told of
  each. On a heartbeat timeout `onClose` is told once, with the reason the
  transport gives for a close, `Closed`, rather than `Closed` and then
  `Timeout`; the calls waiting fail with a message saying it timed out.
- A host name is looked up off the runtime's thread. `Socket`, `WebSocket`
  and `ReliableDatagramSocket` looked the name given to `connect()` up in
  the call, and `DatagramSocket` looked one up in every `send()`, so every
  socket and timer on the runtime waited on the resolver: a name that does
  not exist held the loop for a second on the interpreter, two natively,
  and a client reconnecting in a loop did it again exactly while the
  resolver was failing. Now the name is looked up on a thread of its own
  and the connect finished on the runtime's thread when the answer comes;
  the attempt's timeout counts the lookup. A `DatagramSocket` looks a name
  up once and uses the answer for a minute, refreshing it in the
  background, and datagrams sent while the first answer is awaited wait
  for it (up to 64 per name). What to change: a name that does not resolve
  is reported by an `ioError` event after the call returns,
  `ReliableDatagramSocket.connect()` and `DatagramSocket.send()` used to
  throw `ArgumentError` for one, and no longer do, so listen for `ioError`;
  the reliable session then closes, as a timed-out attempt does. A
  malformed address is still thrown at once. On Node, a `DatagramSocket`
  send that fails, a name that does not resolve, a datagram too large,
  is reported as `ioError` and leaves the socket receiving, as natively;
  it stopped the socket receiving.
- A WebSocket session pings a peer it has heard nothing from for 30
  seconds, and closes with 1006 one it has heard nothing from for 60. The
  heartbeat was dead code on both ends and there was no idle timeout, so a
  peer that vanished without closing was held for good with everything sent
  to it piling up. Both are set per session or, for its sessions, on the
  server; zero turns either off. And an accepted subprotocol is now echoed:
  with no `upgrade` hook, the first one a client offers is accepted.
- `WebSocket.closeWith()`: and so `ServerWebSocket.drain()`, carries out
  the closing handshake. The close frame carries its code and reason, where
  it carried nothing and a peer saw 1005 or 1000, so a drain's 1001 never
  arrived; the connection stays up for the peer's answer, with everything
  written before the close still going out first, natively it was closed
  straight after queueing the frame, which dropped both the frame and what
  was queued ahead of it, and closes once the answer comes, or after five
  seconds. The `close` event reports the code and reason the peer answered
  with, or 1006 if it never did. A peer that breaks the protocol is sent a
  close frame saying why before the connection goes. `close()` still closes
  at once.
- A reliable datagram session that has nothing to say stays up, and one
  whose peer has gone is given up after a minute. A session sent no
  keepalive and closed itself when it had heard nothing for 75 seconds, so a
  quiet session died somewhere between 75 and 150 seconds in with both ends
  running, while a dead peer took as long to notice. Now a session that has
  sent nothing for `keepAliveInterval` (15 seconds, which also holds a NAT's
  mapping open) sends a keepalive, and one that has heard nothing for
  `idleTimeout` (60 seconds) dispatches `ioError` and closes. Both are set
  on `ReliableDatagramSocket`, or on `ReliableDatagramServerSocket` for the
  sessions it accepts and dials; zero turns either off. The keepalive is
  the session's HANDSHAKE sent again, which every version answers with an
  acknowledgement, so an older peer keeps the session up as well.
- A `wss://` client checks the server's certificate: that it chains to an
  authority the client trusts, and that it names the host being connected
  to. Every secure `WebSocket`, and so every `NetConnection` to a
  `wss://` address, was built with verification off natively, and
  accepted any certificate for any host, so whoever could sit in the path
  could present one of their own and read the session. There was no way to
  turn it on. `WebSocket.verifyCert` (on by default) and
  `WebSocket.certAuthority` now say what to trust, on every target,
  including Node, which verified already but could be told neither.
  `secure` is a documented public setting. A client of a development server
  with a self-signed certificate must now either trust it,
  `certAuthority = Certificate.fromFile("server.pem")`: or set
  `verifyCert = false`.
- The HTTP/1.1 client keeps connections. It asked for `Connection: close` on
  every request, so each `URLLoader` load paid for a new connection, and over
  `https` a new TLS handshake. Now a response read to its framed end, from a
  server that did not ask to close, leaves its connection for the next
  request to the same scheme, host and port, for up to four seconds, six an
  origin and 64 in all. A kept connection the server has closed is noticed
  before use, or else the request goes again on a new one, which is why
  only `GET`, `HEAD`, `OPTIONS`, `PUT` and `DELETE` are sent on one. Plain
  requests on loopback went from about 375 to 150 microseconds natively.
  Not on eval.
- The server's rate limiter keys an IPv6 client by its /64 rather than its
  whole address, the block one subscriber is given; keyed on the whole
  address, a client stepping through its own /64 had a new budget for every
  request, and a thousand attempts from one against a limit of five were
  refused none of the time. An IPv4-mapped address counts as the IPv4
  address it maps. An HTTP/1.1 request is now counted once its headers are
  read rather than as soon as they have arrived, so a key can come from
  them; one refused before that, as malformed, is not counted.
- An `HTTPServer` with no `rootDirectory` serves no files, and listens on
  `127.0.0.1` unless told otherwise. A missing root used to mean
  `File.applicationStorageDirectory`: the account's home directory on
  Linux and macOS, `%APPDATA%` on Windows, and the address defaulted to
  `0.0.0.0`, so a server with only routes answered every other path from
  there, to anyone who could reach the port: `GET /.ssh/id_rsa` returned the
  key, and a session the application had saved through `Store`, which keeps
  its files in the same directory, was one guessable path away. Now a request
  no middleware answers is `404` without the filesystem being touched, and
  `validate()` refuses PHP, `rewrites` and extra `tryFiles` entries without a
  root, since each names files under it. A server that serves files must set
  `config.rootDirectory = new File(...)` to the directory it means, and one
  that other machines must reach, anything deployed, or in a container,
  must set `config.address = "0.0.0.0"`. The address guards against the
  mistake that does not show: a public server left on loopback fails its
  first request from outside, while a private one left public keeps working.
  Static files whose path has a segment starting with `.`, `.env`,
  `.git/config`, `.htpasswd`, are answered `404` as well, except under
  `/.well-known/`, which RFC 8615 reserves for files meant to be published;
  set `serveDotFiles` to serve them. Middleware and routes still see every
  path.
- A handler's `@:rpc` method is no longer held to eight arguments. Nothing
  else was: a commands stub or a contract with more built, and a handler
  written without a contract could not answer it. Nothing in the encoding
  needs a limit.
- A runtime RPC handler that throws answers its caller with
  `RPCError.INTERNAL_MESSAGE`, "Internal error", unless it threw an
  `RPCError`. It sent `Std.string(error)`, which put whatever the error held,
  a path, a query, a stack, in the hands of whoever made the call. The
  error itself goes to `RPCSession.onHandlerError`.
- Reliable datagram sessions find loss from what arrives rather than
  waiting it out. A receiver holding frames past a gap says which, in a map
  on its acknowledgement, bit `i` for frame `ack + 1 + i`, up to 512
  frames, cut after its last set byte, which older peers ignore. A sender
  takes a frame as lost once one sent after it has arrived and it has had
  that one's round trip to arrive in, as RFC 8985's RACK does, and sends it
  again at once. That counts time rather than frames held past the gap, so
  it works in the small windows a lossy path leaves, and it catches a
  resend that is lost again. One burst of loss halves the window once, and
  frames the peer holds no longer count against it. When nothing comes back
  for two round trips, the last frame goes again as a probe before the
  timeout is waited out. A peer that sends no map is recovered after three
  duplicate acknowledgements. Natively over loopback, 1000-byte messages
  under 1% loss went from 0.35 MB/s to 58, under 5% from 0.01 to 47.7, and
  under 10% from nothing, its handshake's last message was lost, below,
  to 14.3, with 65 MB/s unchanged at no loss. At a 20 ms round trip, 1% loss
  went from 0.25 MB/s to 0.63, 5% from 0.01 to 0.28, and 10% from nothing
  to 0.19. What limits it there is the window, halved for each burst of loss
  as TCP's is, not recovery: none of those losses waited for a timeout.
- Reliable datagram sessions and servers ask for a megabyte of socket
  buffer in each direction, `ReliableDatagramSocket.WINDOW_BUFFER_SIZE`, and
  expose it as `receiveBufferSize` and `sendBufferSize`. A session sends its
  window in one pass, so it lands on the receiving socket at once, and on
  the system default, 64 KB on Windows, most of a large window was
  dropped, each loss then waiting out a retransmission timeout. Natively
  over loopback, 1000-byte messages went from 7,700 a second to 71,000,
  1200-byte ones from 4.2 MB/s to 81, 16 KB messages from 4.6 MB/s to 74,
  and 64 KB messages from 4.3 MB/s to 97. Only ever raised, and only asked
  for: where a system grants less, a session survives the losses it
  causes, only more slowly.
- The `http2` sample ends on its own and says whether it worked: it checks
  both bodies against what it served and exits 1 on anything else, so CI now
  runs it rather than only building it. Its status line never printed, it
  listened for `HTTP_RESPONSE_STATUS`, which is the server's event, where a
  loader reports `HTTP_STATUS`, and it listens on a port the system picks.
  `Http2Sample serve` keeps it serving for a browser, as before.
- The `rpc-greeter` sample's loopback connection stamps its traffic with
  CrossByte uptime, which is what `INetConnection` documents and what
  `RPCSession` measures heartbeats and timeouts against, instead of the time
  of day.
- A reliable datagram session gathers what it sends and sends it when the
  runtime's loop finishes its pass, after the tick's handlers, after each
  round of socket polling, at the end of `HostApplication.advance`, and on
  Node when the platform's turn ends, several frames to a datagram where
  the peer takes them. Every frame was its own datagram and its own system
  call, and every packet that arrived was answered with an ACK of its own.
  Now a pass owes one cumulative ACK at most, and none when a frame going out
  already carries it. A bundle is never larger than the largest single frame,
  so nothing is sent that a path carrying frames cannot carry; one frame
  still goes out as itself, byte for byte; and the capability is a flag on
  CONNECT and HANDSHAKE that an older peer ignores, so it is sent one frame a
  datagram as before. `flush()` sends what is gathered at once, in either
  mode, where before it only turned stream bytes into frames and threw in
  `DATAGRAM` mode, and `close()` sends it before the FIN. Natively over
  loopback, 100-byte reliable messages went from 45,000 to 258,000 a second,
  1000-byte ones from 4,700 to 7,700, and 100-byte unreliable sends from
  85,000 to 283,000.
- The samples drive their runtime through `HostApplication.advance()`. Four
  of them, arena, websocket-echo and both halves of socket-chat, reached
  `CrossByte`'s private constructor and `pump()` through `@:access`, which is
  what anyone copying a sample would have copied.
- `RateLimiter` lives in `crossbyte.net`. Nothing in it was about HTTP, and
  what a game server meters, admissions, a datagram path, an RPC caller,
  is not HTTP either. `crossbyte.http.RateLimiter` remains as a deprecated
  typedef, so existing imports keep compiling.
- `ReliableDatagramSocket` sends at the rate the path carries. It
  retransmitted on a flat three seconds with 500 frames always allowed in
  flight, which on a path already dropping packets makes the drops worse. The
  retransmission timeout is now measured as RFC 6298 describes, smoothed
  round trip plus four times its variation, between 200 ms and 10 s, doubled
  on loss, and the window starts at ten frames, grows by slow start and
  then congestion avoidance, and halves on loss, never below two. The
  repeating timer each frame armed is gone, which with a full window was
  hundreds of live timers per connection, and what waits for the window is
  bounded by the new `maxOutputBufferSize` and `outputOverflowPolicy`, with
  `bufferedAmount` reporting the backlog.
- SCTP flow control, in both directions. A receiver advertised its whole
  window in every SACK however much it held, and nothing capped the total
  across 65536 streams: 16.6 MB across 16384 streams was kept in full. It now
  advertises what is free and holds no more than the 2 MB it offers, giving
  up unfinished messages past that. A sender ignored the window it was told;
  it now queues when there is no room, probes a closed window so it learns
  when it reopens, and reports the backlog as `DataChannel.bufferedAmount`.
  `DataChannel.send` throws once 8 MB is waiting, rather than growing until
  the process dies.
- `HTTPServerConfig` ships defaults a server can run on. The rate limiter
  allowed ten requests a minute per address, fewer than one page with its
  assets, and now allows 240. `maxOutputBufferSize` was unbounded, so a
  client that stopped reading held its whole response in memory; it is now
  8 MB, above anything an ordinary response buffers. Both are named
  constants, `DEFAULT_REQUESTS_PER_MINUTE` and `DEFAULT_MAX_OUTPUT_BUFFER`,
  with the reasoning beside them.
- ICE drops a remote candidate whose address is a name rather than a literal.
  Browsers publish host candidates as random `.local` mDNS names, which
  nothing here resolves, and each send to one blocked the event loop on a
  lookup: 15.8 seconds to connect to a real browser, every other connection
  frozen meanwhile, against 1.3 with the names dropped. Nothing is lost,
  since the browser's own checks arrive and its address is learned from them.
- `ByteArray.readObject`, `writeObject` and their `FileStream` counterparts
  throw for an encoding this build cannot handle, AMF without the optional
  `format` haxelib, instead of reading `null` and writing nothing. The
  message names `-lib format`.
- `ByteArray.endian` and `objectEncoding` are declared as ordinary
  properties. They were forwarded from the underlying type, with documented
  declarations behind a `doc_gen` flag nothing defined, so neither appeared in
  the generated API documentation.
- The documentation describes CrossByte rather than the Flash and AIR runtime
  it was adapted from: security sandboxes, policy files, `Std.is`, types this
  library does not have, and defaults it does not use. Its replacement was
  checked against the code, `readMultiByte` and `writeMultiByte` ignore
  their character set, `URLRequest.method` takes any verb, and the default
  compression is LZ4. Every example in `File` compiles, and CI keeps it that
  way. The README lists the build defines, including the ones that enable the
  native Brotli and LZ4 backends.
- The HTTP request path no longer compiles a regular expression per request,
  and skips building the access-log line when the level would discard it,
  about 1.8% of a request, measured inside the real workload.
- `ByteArray` writes no longer call out to `__resize` when the buffer already has room. Growth, gap zeroing and the length bookkeeping are all unnecessary for a write landing inside existing capacity at or before the current end, which is every append an encoder makes, so that case is now an inline capacity check. `writeByte`, which is inline and where the call was proportionally largest, went from 494 to 766 MB/s on the machine that measured it; `writeInt` gained about a tenth. The gap between reads and writes that prompted this turns out to be mostly inherent: `Bytes.setInt32` costs roughly 1.6 times `Bytes.getInt32` at the platform level, and the constant `ByteArray` overhead above that is an interface method call which cannot be inlined away.
- The three places that ask a STUN server what address it sees, `StunClient`, `ReliableDatagramServerSocket.discoverPublicAddress` and `PeerConnection.gatherReflexive`, now share one implementation of the parts that were never different: the transaction a reply is matched against, the doubling retransmission schedule, the deadline, and the handful of ways a reply can be unhelpful. Their transports genuinely differ and still do. The duplication had already cost something: the retransmission fix earlier in this release had to be applied by hand twice and the second was nearly missed. The extracted logic needs no socket and no clock, so it is now directly tested on every target rather than only through three socket-bound paths.
- `ByteArray`'s integer accessors read and write a word at a time. `readInt`, `readUnsignedInt`, `readShort`, `readUnsignedShort`, `writeInt` and `writeShort` each made one bounds-checked byte access per byte and shifted them together; they now use `getInt32`/`getUInt16` (little-endian by definition on every target) with a swap for big-endian streams, which is most network traffic and all of STUN and SCTP. `readInt` went from 526 to 889 MB/s on the machine that measured it, and little-endian now costs the same as big-endian, the swap was never the expense, the per-byte bounds checks were.
- A multi-byte read that cannot be satisfied now throws without moving the position. Those readers used to lean on `readUnsignedByte` for bounds checking, one byte at a time, so a truncated stream advanced the cursor by however many bytes happened to be present before throwing, leaving a caller that catches `EOFError` to find its position somewhere it never put it.
- CRC-32C is slicing-by-eight with direct word loads instead of a single table fed one byte at a time through the stream API: 638 to about 2700 MB/s on the machine that measured it, and since the checksum was nearly the entire cost of an SCTP packet in either direction, whole-packet encode and decode roughly tripled. Same published vectors before and after, plus a new case comparing every offset and length across the word boundaries against the one-bit-at-a-time definition, the aligned vectors never exercise an odd offset, which is exactly where slicing bugs live.
- The DTLS transport no longer copies. Every record was copied byte-at-a-time up to four times over its life, into a scratch buffer on receive, out of the native session, into the handler's ByteArray, and the mirror of it on send, and a `ByteArray` is a `haxe.io.Bytes` underneath, so the conversion is free. Receive and send now hand the datagram's own storage to the native session, and the record paths write straight into the ByteArray the handler receives. At a typical record size the byte loop cost seven times a blit, and the receive path needed no copy at all.
- Asking a STUN server is repeated on RFC 5389's schedule rather than asked once. `StunClient.discover` and `ReliableDatagramServerSocket.discoverPublicAddress` each sent one datagram and waited out a deadline, so a single dropped packet lost the whole query and was reported as a server that is not there, which sends whoever reads it looking at their configuration for a fault that is not in it. `PeerConnection.gatherReflexive` already did this; now all three agree.
- ICE pairs a reflexive local candidate as its base. RFC 8445 section 6.1.2.2 replaces a reflexive candidate with the address it was discovered through when forming pairs, and 6.1.2.4 drops what that leaves redundant, because nothing sends *from* a reflexive address, the datagram leaves the socket that asked. Without it a peer that gathered a reflexive address sent every connectivity check twice, from one socket, to the same place. A relayed candidate is not collapsed: RFC 8445 section 5.1.1.2 makes it its own base, since a relay lends an address that really does send.
- The browser interoperability test faces the browser people actually run. It used to start Chrome with mDNS candidate obfuscation switched off, which no visitor's browser has: every host candidate a browser publishes is a random `.local` name, meaningless off its own link. Left on, the connection is still made, CrossByte's addresses are real, so the browser's own checks arrive, and the address one arrives from is somewhere the browser demonstrably is, which is what a peer-reflexive candidate is for. The test now asserts that is the mechanism rather than observing a connection and assuming why, and runs both signalling directions against both browsers. So browser interoperability needs no mDNS resolver, and one would not help much: those names resolve only on the link the browser is on, where a peer is already reachable this way.
- BLAKE3 is built with its vectorised backends rather than the portable path alone. SSE2, SSE4.1 and AVX2 were all switched off for build determinism, a real concern, but one about the build and not the output: BLAKE3 is specified so that every implementation emits identical bytes, and `blake3_dispatch.c` chooses between them by CPUID at runtime. What the flags cost was the entire reason to vendor BLAKE3 rather than use the BLAKE2b libsodium already provides. Measured on 128 MB, 977 MB/s becomes 3,459 MB/s and `simdDegree` goes from 1 to 8, with the known-answer vectors unchanged byte for byte. Unlike libsodium's vectorised sources, BLAKE3's do not guard their own bodies, so they are compiled only where the instruction set can exist and each carries the flag its own translation unit needs. AVX-512 stays off: many Intel parts drop their clock while executing it, so a short hash can leave the rest of the process slower than it found it. Changing these flags needs the hxcpp object cache cleared, a stale `blake3_dispatch.obj` goes on referencing SIMD symbols that are no longer compiled, and the link fails on them.
- `PHPBridge.execute()` returns a `Future<PHPResponse>` instead of a `PHPResponse`, and the runtime no longer stops while PHP thinks. A CrossByte runtime serves every connection from one tick and `execute()` was called from inside it, blocking in a read loop until `END_REQUEST`: for as long as one script ran, nothing else on that runtime did, no other request read, no response written, no timer advanced. With `maxConnections` at its default of 256, one slow page held up 255 clients that had nothing to do with it. Native targets now read non-blocking from the tick and Node from its events, both feeding one transport-independent parser (`PHPExchange`), and both sharing the deadline sweep. A `Future` rather than the callback pair proposal 0021 drafted, because `crossbyte.Future<T>` exists now and two ways of saying "later" is one too many. The deadline test gained the two assertions that were impossible before, that `execute()` returns before the deadline elapses, and that the runtime goes on ticking while an exchange is outstanding, and a pipelined request arriving mid-exchange is covered where it was previously only reasoned about: with the handler's request-boundary guard disabled, the static response overtakes the PHP one and the test goes red (`docs/proposals/0021-asynchronous-php-bridge.md`).
- CI builds the hxcpp a developer builds. `HXCPP_REF` pointed at `socket-fixes`, the narrow branch kept clean for the upstream pull request, while local work used `production`, that fix plus the Windows `file_write` correction and a catch-up with upstream. Both currently pass the whole suite, measured rather than assumed, so nothing was broken; but CI and every developer were testing different compiler backends, and the gap widened with each upstream merge one branch took and the other did not.
- `CompressionRoundTripTest` asserts that compressing makes data smaller. It checked only fidelity before, same length back, same bytes back, which a codec storing its input verbatim satisfies perfectly, and three of the four do exactly that: `deflate`, `gzip` and `lz4` emit stored blocks, so 6000 bytes of a repeating phrase come back as 6005, 6028 and 6025. Brotli reaches 23 and is asserted. The other three warn on every run rather than failing, because pinning "does not compress" as expected would make the gap look intended and failing would leave the build red for something needing a real encoder written.
- The test topology is checked rather than remembered. `SuiteCoverage` now reads every `tests/*Main.hx`, not just the two it knew about, so a group an entry point calls is no longer reported as dead and an entry point that hand-lists cases is reported instead, with `@:topologyExempt("reason")` for the three that do so deliberately. The JavaScript suite's list moved into `PortableSuite`, which `SuiteCoverage` requires to be a subset of what `addAll` runs, so a case cannot run on js and nowhere else. The check now runs in the two JavaScript builds as well, which had been the only test builds without it. `-D suite_topology` prints which entry points run each case.
- `BloomFilter` is covered at a size that is not a power of two, and runs in the portable Node suite. Its index derivation relies on `i * h2` wrapping, which happens where an `Int` is 32 bits and not on js, the two differ by exactly 2^32, which a power-of-two size divides away, and both existing tests used one. At `size = 10000` the targets really do set different bits. Not a defect while nothing can read those bits, and the guarantee that is observable, never a false negative, holds on both; the comment on `__indexAt` now says so, and says that adding serialization would make it a defect.
- **Breaking:** the TLS surface takes `crossbyte.net.Certificate` and `crossbyte.net.Key` rather than `sys.ssl.Certificate` and `sys.ssl.Key`. Affects `ServerSocket.setCertificate`, `addSNICertificate` and `requireClientCertificate`, and `ServerWebSocket.cert` and `certAuthority`; `HTTPServerConfig` is unchanged, having always taken paths. Load with `Certificate.fromFile(path)` / `Key.fromFile(path, ?password)` in place of `loadFile`, or `fromPem` for material that never touches disk, which is how a key arrives from a secret manager, and a reason not to make every deployment write one to a file first. Naming a `sys.ssl` type in a signature was a decision about which targets could implement it: Node terminates TLS through `tls.createServer` but has no `sys.ssl`, so the method could not be compiled there at all and the refusal read as "Node cannot serve TLS", which was never true. The jvm target has no TLS backend and both types refuse there, matching the secure `ServerSocket` that already did.
- **Breaking:** `HTTPServerConfig.tryFiles` defaults to `["$uri", "$uri/"]`. It ended with `"/index.html"`, which made a request matching neither of the first two answer 200 with the root index rather than 404, a single-page application fallback, carried by every server whether or not it served an application. It was documented and it was deliberate; what was wrong was which way round the failure fell. An SPA that wants the fallback and does not have it breaks on the first refresh of a deep link: loud, immediate, one entry from fixed. A static site that did not want it and had it answers 200 for every path that does not exist, so a broken link looks alive to a crawler, a monitor sees a healthy page, and a cache stores the wrong body under the missing URL, silent, and indistinguishable from working. Restore it with `config.tryFiles = ["$uri", "$uri/", "/index.html"];`. `"$uri/"` is untouched, so a directory still resolves to its index.
- `Socket` can hold a connection open after the peer half-closes. A read ending in `Eof` was turned straight into a full teardown, so a peer that shut its write side to mark the end of a request, the end-of-request signal for a great many hand-rolled TCP protocols, and the only one available to a protocol that does not length-prefix, was treated as a peer that had gone, and any answer to it went unwritten. `peerShutdownPolicy` decides: `CLOSE` is the default and exactly the previous behaviour, `HALF_OPEN` ends the read direction only and dispatches the new `Event.PEER_CLOSE` while the socket stays writable. `peerShutdown` reports the fact under either policy, and `shutdown(read, write)` surfaces the outbound half, which every target already implemented. Measured on cpp: a half-closed peer does receive a response written after its FIN. `HALF_OPEN` carries a hazard documented on the value, a departed peer is indistinguishable from a half-closed one, and the first write after either succeeds by reaching only the kernel send buffer, so it needs a bound of the consumer's own. The HTTP server stays on `CLOSE`, since HTTP/1.1 frames bodies explicitly and a client FIN tells it nothing new. See `docs/proposals/0019-socket-half-close.md`
- **Breaking.** `HTTPServerConfig.rewrites` now defaults to empty. It shipped carrying one rule, every `^/api/.*$` to `/index.php` with the `PHP` flag, while `phpEnabled` defaults to false, so the out-of-the-box answer for a path a great many services use was an error rather than a 404, and before the guard below it was a segfault. Nothing is routed anywhere now unless it is asked for. Restore the old behaviour by passing the rule explicitly
- **Breaking.** `HTTPServerConfig.validate()` rejects a `tryFiles` list that is not spelled in the order the server follows, and `HTTPServer` calls it on construction. `$uri` and `$uri/` are tested before the list is read and before the rewrite rules, whatever the list says, and even when it omits them, so a literal placed first does not get priority and leaving them out does not switch direct file serving off, which is the reading most likely to be mistaken for a restriction. The list must now begin `["$uri", "$uri/"]`, which is what the default already was. Configs differing only in those decorative entries behaved identically before, so writing them out changes nothing but what the file admits to
- A directory index is chosen from candidates the server can actually serve. `directoryIndex` leads with `index.php`, so with PHP off a directory holding both it and an `index.html` selected the one that cannot be executed, and once serving PHP source was refused, answered 404 with a usable index sitting beside it. Both selectors skip what cannot be delivered, and they share the rule so one directory cannot resolve two ways depending on which reached it first
- `tryFiles` and `rewrites` carry the resolution order in their documentation: `$uri`, then `$uri/`, then every rewrite rule, then the remaining `tryFiles` entries. The consequence worth knowing is that an existing file wins over a rewrite, which is Apache's `RewriteCond !-f` idiom applied for you rather than written out, and not nginx's model where `try_files` runs after the rewrite phase in the order written. Invert it for a given rule with a `FileExists` condition and `negate`

- a timing wheel scheduler, selected per runtime with `TimerStrategy.WHEEL`. The heap remains the default and remains right for almost everything; this is for the shape where its remaining O(log n) still shows, a timer armed per entity or per connection and re-armed on every event, where the work is in the arming rather than the firing. Time is divided into 1ms ticks with 512 of them in a ring, so arming inside that range is an index calculation and a list link, with nothing that grows with how many timers are already held. Against the heap, both freshly optimised, CPU to simulate one second at sixty ticks: 1,000 timers **4.2x**, 10,000 **5.2x**, 30,000 **6.3x**; arm and cancel churn roughly **1.6–2.0x**. What it gives up is measured too, timers past the ring wait in an unordered overflow list reconsidered once per revolution, so ten thousand timers thirty seconds out cost 0.55ms over ten simulated seconds against the heap's nothing, and a runtime whose timers are mostly long should stay on the heap. Ordering within a tick is bucket order rather than exact time, and a timer may be late by up to a tick but never early, since buckets are chosen with `ceil`, a callback that reads the clock should never see a time before the one it asked for. Chosen per runtime rather than per build, `CrossByte.make(loopType, timers)` and the `Application` constructors take a `TimerStrategy`, beside the `MainLoopType` that already works this way, because a process runs a runtime per thread and they need not agree: a simulation thread holding a timer per entity and a network thread holding a handful want different structures. There is no public way to supply an arbitrary scheduler; `ITimerScheduler` remains internal, since publishing an eighteen-member contract with generation-stamped handles and resume policies means committing to it. The full test suite runs green with the wheel driving the runtime, which is the actual contract: no timer-dependent behaviour in the framework can tell the two apart
- the timer scheduler keeps each timer's heap position on the timer rather than in a hash map. `TimerHeap` ordered its nodes through `crossbyte.ds.PriorityQueue`, which is generic and so cannot require its elements to carry anything, it tracks positions in a side `ObjectMap`, making every sift swap two hash writes, around thirty per arm at thirty thousand live timers against fifteen comparisons of actual heap work. A timer node can carry its own index, so `TimerQueue` is the same binary heap with the same ordering and complexity, writing a field where the generic one wrote a hash entry. CPU spent per simulated second, one recurring timer per entity: 1,000 entities **8ms → 1ms**, 10,000 **125ms → 10ms**, 30,000 **499ms → 40ms**. At sixty ticks a second that last figure is the difference between the scheduler taking half the frame budget and taking four percent of a core; arm and cancel churn went from roughly 2.3 million a second to 18 million. `PriorityQueue` is unchanged and still right for callers that cannot make this trade, the map is the price of being generic, and only `TimerHeap` was placed to stop paying it
- a streamed response no longer closes its connection. Proposal 0017's two halves now combine: the head is written when a transfer begins and the body follows over many ticks, so settling the connection at head time would either close it before the first body byte or reset for a next request whose response would interleave into the body still going out. Settling moved to the pump, which runs it once the last byte has left the process; the keep-or-close decision is still made once at header-write time, so what the `Connection` header promised is what happens. The framing never needed to change, a streamed body is delimited by the `Content-Length` that went out with its head, exactly as a buffered one is. Bytes arriving during a transfer are kept rather than dropped and are picked up when it settles, through the same path a pipelined request takes after a buffered response
- `-D precision_tick` is type-checked in CI. It replaces the frame wait with one that spins the tail rather than sleeping it, and no hxml defined it, so the branch compiled nowhere: rewriting the wait to anchor its deadline touched it blind and nothing would have reported it broken. A `Core | hxcpp API Audit` step now builds it, beside the timer burst audit that exists for the same reason
- the HTTP suites share one wire harness instead of five. Each carried its own pump loop, and three their own response parser and completeness predicate, duplication accepted while those suites were built on parallel branches, whose cost had arrived by the time they landed: the predicates disagreed about a response carrying no `Content-Length`, only one knew to skip a `1xx` interim block, and one sliced `Content-Length` from a fixed offset that a single leading space turns into a zero-length body. `HTTPTestSupport` now holds the most capable version of each. What stays local is what genuinely differs, the metrics suite steps the runtime tightly because it reads gauges rather than a socket, and the streaming suite works in `ByteArray` because it asserts byte-exactness on binary payloads
- `tps` now delivers the rate it names. The frame wait was measured from the frame's own start, so an overrun was absorbed permanently rather than compensated, the configured rate acted as a floor on frame time instead of a target for it, and the faster a runtime was asked to tick the worse the shortfall got, with nothing reporting it. Ticks actually delivered in a wall-clock second, measured: 12 tps **11.9 → 12.0**, 60 tps **56.6 → 59.9**, 144 tps **122.3 → 143.9**. The deadline is carried forward by one interval per frame instead of recomputed, so a long frame leaves the next a shorter wait: four frames at 60 tps containing one 30ms overrun take 65ms against an ideal 66.7, where they took 83ms before. Debt is bounded at a quarter second, since repaying minutes of it after a suspend would run a burst of zero-wait frames starving everything else to catch up with a schedule nobody is watching; past that the schedule restarts. Changing `tps` restarts it as well. `pump()` is unaffected, it keeps no schedule and its delta comes from the caller
- the frame wait sleeps once rather than stepping the remainder out a millisecond at a time. At the default tick rate that was over eighty syscalls per frame, roughly a thousand a second, to arrive at the moment a single sleep would have. The bulk now goes in one sleep with a small margin for the operating system to overshoot into, and only that margin is stepped out. Frame accuracy is unchanged where it matters: measured against target across twenty frames, 12 tps gives 84ms against 83, 60 tps 18ms against 17, and 144 tps 8ms against 7. Building with `-D precision_tick` keeps its existing behaviour, including the spin on the tail that buys accuracy with CPU
- event dispatch no longer copies its listener list on every dispatch. The copy existed so that a listener list could not change while it was being walked; the list is now immutable instead, with `addEventListener` and `removeEventListener` building a replacement rather than mutating in place, so a dispatch already in flight keeps the array it started with. The contract is unchanged and was already pinned by tests, a listener added during dispatch is not invoked until the next one, a listener removed during dispatch still runs for the event in flight, and the cost moves from dispatch, which happens forever, to registration, which happens once. Measured over 200,000 dispatches: two listeners **10ms → 6ms**, four **12ms → 8ms**, sixteen 30ms → 27ms, sixty-four 95ms → 87ms. A single listener was already fast-pathed past the copy and is unchanged
- the fallback poll backend stops rescanning to identify ready sockets. It mapped each ready socket back to its position by walking the whole registered set, so a busy pass cost registered × ready comparisons, 65,536 of them for 256 sockets all readable at once, on every pump. Positions cannot change until the registered set does, so they are built once when it changes and looked up thereafter. The non-cpp registry also stops allocating a fresh array to hand `select` each pump, reusing one it keeps; it still cannot pass its own list, since that array is the `DenseSet`'s backing store and `select` may treat what it is given as scratch. Both are on the fallback path, cpp resolves readiness through `cpp.net.Poll`, or through the `crossbyte-libuv` extension where one is built in and installed, which is optional and off by default, so they matter to eval, jvm, neko and hl
- the server loop waits inside poll rather than beside it. `ServerApplication`'s loop polled its sockets with a zero timeout and then slept out the rest of the frame, so sockets were serviced exactly once per tick, measured at the default twelve ticks a second, one poll every 84ms, which every arrival that missed a poll waited for and a request/response pair could pay twice. The frame budget is now poll's timeout, so a ready descriptor wakes the loop and an idle one returns at the deadline: measured A/B with a peer writing 30ms into an 83ms frame, the handler saw it after **54ms before and 1ms after**. Tick cadence is unchanged, an idle frame still measuring the interval. The comment being replaced held that poll must never own the frame wait, because Windows UDP poll could starve timers with an idle socket registered; that was tested rather than assumed away, and with an idle UDP socket bound alongside a 20ms timer the loop fires 50 of an expected 51 per second. The `DEFAULT` loop is deliberately untouched, a fixed timestep is what a general application loop, one that might pump a renderer, is for
- inbound socket data is appended to the input buffer instead of rebuilding it. Every arrival allocated a fresh buffer the size of the unread backlog plus the new bytes, copied the backlog in, copied the new bytes after it, and replaced the buffer, on top of the `BytesBuffer` that had already accumulated the reads. Four copies per arrival, one of them the whole backlog, which made receipt quadratic in the number of arrivals for any consumer reading slower than its peer writes: exactly the shape a WebSocket assembling a large frame or an HTTP body spread across ticks produces. Measured as bytes copied per byte arrived over 200 arrivals, by how much the consumer drains each time: fully **3.0x → 1.0x**, half **52.8x → 2.7x**, an eighth **90.1x → 1.6x**, nothing **102.5x → 1.0x**, and the new figures stay flat as arrivals grow where the old ones did not. `__input` was already a `ByteArray` with geometric growth and retained capacity; the old path allocated raw `Bytes` and threw all of it away
- the socket read buffer holds 64 KB rather than 4 KB, so a megabyte arrives in 16 reads instead of 256, and it is shared per thread rather than held per socket. That sharing is what makes the larger size affordable: 64 KB per socket across the default 256 connections would be 16 MB of idle buffer, where one shared buffer is 64 KB whatever the connection count, less than the 1 MB those sockets held between them before. It is safe to share because the buffer is drained into the socket's own input before anything is dispatched, so no listener can re-enter and find it changed
- the `Date` header is formatted once per second instead of once per response. `__formatHttpDate` was `inline` and rebuilt both month and weekday array literals at every call site on every response; the tables are statics now, shared with `Last-Modified` formatting, and the rendered string is cached on its second, measured at 22x with byte-identical output. The cache is written string-first so a second runtime thread that sees the new stamp finds the matching string in place; the worst a race costs is one redundant format, never a wrong date
- removed three private methods from `HTTPServer`, `sanitizePath`, `pickIndex`, `contentType`, and the `_internal.http.ContentType` enum, none of which had a single caller. They were a parallel implementation of serving decisions that actually live in `HTTPRequestHandler` (`__resolveSafePath`, `__findIndexFile`, `__getMimeType`), which made them worse than dead weight: `sanitizePath` was a fourth copy of path-containment defense, and four copies of a security check is how one of them drifts
- `Worker` delivers every message queued for it on each tick of its owning runtime, bounded by the new `Worker.maxMessagesPerTick` (256 by default; `0` or less drains until the queue is empty), where it used to deliver exactly one. One per tick meant a background job reporting progress drained at the runtime's tick rate, twelve a second under the default `tps`, however often the host pumped, so a `NativeProcess` reading a child's stdout, an async `FileStream` read, a `URLLoader` download and `SQLiteConnection`'s long-lived query worker each fell further behind the more they reported, with the backlog held in the queue rather than lost. Ordering is unchanged: the queue drains in order, and every consumer's handler was already written per-message. The bound is there so one talkative worker cannot hold the tick and starve the socket poll that runs after it, and the drain re-reads the queue on every pass rather than trusting the reference it started with, since a handler is free to `cancel()`, `clean()` or `run()` the worker from inside dispatch. Verified by pinning the bound to 1, which reproduces the old pacing exactly and fails the new test with 1 message delivered where 64 were queued
- WebSocket payload masking and unmasking now XOR 32 bits at a time over `haxe.io.Bytes` instead of a byte at a time through `ByteArray`'s array access, measured at 595 → 1666 MB/s on a 32 MB payload (2.8×). The cost was not the `ByteArray` abstraction, which is `inline` over a `Bytes` subclass and compiles away, bulk `writeBytes` runs at 14 GB/s against a 29 GB/s memcpy floor. It was that `@:arrayAccess set` calls `__resize` on every element to bounds-check an index the loop already knows is in range, because the buffer was allocated at full size immediately before. Unmasking runs once per inbound byte on a server, which is the one place that per-element check was worth removing
- rewrote `crossbyte.http.RateLimiter` as a configurable token bucket (burst capacity, continuous refill, per-key isolation, idle-bucket eviction, injectable clock) replacing the fixed-window placeholder with its hard-coded 10-request limit

### Fixed
- On the jvm, a runtime whose last connections close lets them go.
  `select` keeps what it asks about on its thread between calls, and
  emptied that list only as the next call began; a runtime with nothing
  left to poll made no next call, so the sockets of its last one stayed
  reachable with their buffers and `userData`: 40 closed connections of
  64 KB each survived five collections.
- On the interpreter, a socket's second `close()` does nothing, where it
  threw "not a socket", and `peer()` and `host()` name their `Host` by its
  address as a resolved one is named; `host.host` was null, and
  `ServerWebSocket` names a client by it.
- Natively, a connection reset is a failure when read a byte at a time, not
  the end of the stream. `readByte` took every error but a blocked read for
  the end, so a line reader, or anything reading to the connection's end,
  took what it had as whole when the peer was cut off. It goes through
  `readBytes` now, as it does on hl, neko and eval.
- A miss in a `Map<Int, T>` on the jvm costs what a hit does. Haxe 4.3.7's
  `IntMap` for the java targets never stopped probing at an empty bucket,
  so every miss read the whole table: 110us a miss at 100,000 entries,
  where a hit took nothing measurable. CrossByte puts a fixed copy ahead of
  it there (`std/java`, added to the class path by
  `crossbyte._internal.macro.StdOverrides` from `extraParams.hxml`). A build
  from `-cp` rather than `-lib crossbyte` adds
  `--macro crossbyte._internal.macro.StdOverrides.use()` itself, before any
  other macro, as the suites' build files do.
- `PostgresStatement` hands back a result paged ahead of `getResult()` in
  the order it was read, and calls only its last page complete, the last
  of a result that divides evenly into pages as well. Once the last page
  had been read every page still waiting said it was complete, and off cpp
  the pages came back newest first. Four rows in pages of two read
  "1,2+ 3,4+" and now read "1,2 3,4+"; five read "1,2 3,4 5+".
- `HTTPServerDefaultsTest` no longer leaves its canary store behind: every
  full native run on Windows left an `http-root-canary-*` directory in
  `%APPDATA%\stores`, its value file still there. It cleared the store
  asynchronously and closed it at once, then deleted the directory a
  single time, and a file just written is often held a moment on Windows;
  it now closes the store and removes the directory, trying again for up
  to two seconds.
- On neko the HTTP server answers a conditional request dated past
  January 2038 with a 304, as it does elsewhere. It read `If-Modified-Since`
  through a local `Date`, which neko cannot make past 2038 (`new Date`
  threw `std@date_set_hour`), so such a revalidation was answered with the
  whole file. HTTP dates are read and written in UTC by arithmetic now,
  both ways, the same on every target.
- The HTTP client's request-target case passes on neko. It built its
  non-ASCII path with `String.fromCharCode(0xE9)`, which on neko, whose
  strings are bytes, is one Latin-1 byte rather than the UTF-8 a typed
  URL carries, so the client rightly sent `%E9` where the case expected
  `%C3%A9`.
- A request whose connect times out says so, on every target: `Connection
  Failed: host:port did not answer within 1 s` over HTTP/1.1, and
  `Connecting to ... timed out after 1s` over HTTP/2. Natively the reason
  given was `Blocked`, the read the TLS handshake waited on having timed
  out; on the jvm, whose handshake now holds to the deadline, it came
  wrapped as `Custom(Timeout: ...)`, and an HTTP/2 connect there was not
  taken for a timeout at all.
- On the interpreter, each thread serving HTTP keeps its own compiled
  rewrite patterns and directory listings, as it does on every other
  threaded target. They were held per thread only on cpp, neko, hl and the
  jvm, so runtimes on two eval threads shared one map and one `EReg`,
  which carries its last match: one could read the other's captures.
- Closing an HTTP/2 client connection, the pool's idle sweep,
  `H2ConnectionPool.closeAll`, a request discarding a failed one, no
  longer closes its socket under the thread reading it. For TLS that
  freed the socket's mbedTLS context mid-read, and when the read returned,
  with the server answering the GOAWAY, mbedTLS went on with the freed
  context: a segmentation fault in `mbedtls_ssl_read`, seen natively on
  Linux. The connection is shut down instead, and the reading thread
  closes the socket once its read has ended, as the HTTP/1.1 client
  already did for a cancelled load.
- The HTTP/2 server takes a request sent with trailers. The trailer
  section, a second header block on the stream, replaced the request's
  header section, so the request was read from the trailers, found to
  have no `:method`, and reset: it never reached a handler. Trailers are
  now checked and dropped, as the HTTP/1.1 server drops a chunked body's,
  and a trailer section that does not end the stream, or that carries a
  pseudo-header or a line break, resets the stream as RFC 9113 8.1 says.
- The interpreter suite no longer hangs, now and then, in
  `URLLoaderHttpTest`. The HTTP tests' pump loops slept a millisecond
  between pumps with `Sys.sleep`, which on eval under Windows times a
  yield in 15.6 ms ticks of CPU time and sleeps for what is left of the
  millisecond, a negative remainder, when a tick lands in the yield,
  that OCaml hands to `Sleep()` as about 49 days. One thread doing nothing
  else stalled in five of six minute-long runs, and the case hung in 2 of
  20. The pump loops sleep through `System.sleep` now.
- An HTTP request that cannot connect says why, as in `Connection Failed:
  X509 - Certificate verification failed` natively or the JDK's `PKIX path
  building failed` on the jvm. Every failure, an untrusted or expired
  certificate or a refused port alike, read `Connection Failed` and
  nothing more.
- HTTP/2 on Node and in the browser refuses a NUL in a field, as it does
  on the other targets. The HPACK decoder read each string with
  `Bytes.toString`, which on JavaScript stops at the first NUL, so a field
  holding one arrived as the part before it: the NUL that RFC 9113 makes
  it malformed for never reached the check, and the rest of the value was
  dropped without a word.
- `URLLoader` on Node decodes a compressed response, with Node's zlib and
  within `maxDecompressedSize`, as the other targets' clients do: gzip, br,
  deflate (zlib-wrapped or raw) and lz4, two stacked at most. It handed the
  body on as it came, so a gzip JSON answer arrived as garbage, and it
  sends `Accept-Encoding: identity` unless told otherwise, as the native
  client does. A body that cannot be read as the loader's `dataFormat`,
  text that is not UTF-8, is an `IO_ERROR` on every target, with the bytes
  in `data`: on Node it threw a RangeError out of the completion, which
  ended the process.
- An HTTP/2 request's connect and TLS handshake are held to its timeout,
  and its cancel reaches them. A server that accepted TCP and never
  answered the handshake held the request for good, and every other
  request to its origin, which waited behind the connect on a lock with no
  deadline: three requests had no outcome in 15 seconds, and a cancel did
  nothing. A request waiting on another's connect now leaves at its own
  timeout, or at once when cancelled, and is told how that connect failed
  rather than making it again in turn. A timed-out handshake says so,
  where natively it read as "Blocked".
- The HTTP/1.1 client holds a response's header section to 64 KB,
  `Http.MAX_RESPONSE_HEADER_BYTES`, the limit the server holds a request's
  to. It read header lines for as long as a server sent them, one line for
  as long as it went without ending, and 1xx responses for as long as they
  kept coming, during which the idle timeout never fired, so a server,
  or one a redirect led to, chose how much memory and time the client
  spent. Trailers are held to the same limit, a chunk-size line to 4 KB,
  repeated fields are joined once rather than each onto everything before
  it, and the cookie jar keeps 180 cookies a host and ignores one longer
  than 4,096 characters, where it kept every one and read through all of
  them on each request.
- The cookies `URLRequest.manageCookies` carries across a redirect match
  their host whatever its case, and are kept per host. A cookie set by
  `Example.com` was not sent to `example.com`, so a redirect that changed
  only the host's case kept the caller's credentials and lost the session;
  a second host setting a cookie of the same name replaced the first
  host's; and a host's cookies went back in an order that differed by
  target. They go back in the order they were set.
- HTTP/2 refuses a field holding a CR, LF or NUL in its value, or a name
  that is not visible lowercase ASCII, as RFC 9113 8.2.1 says: on the
  server the request's stream is reset, and in the client the response
  fails, both leaving the connection to its other streams. HPACK carries
  any byte, so a line break reached the request a middleware saw, and a
  response header the caller might pass on over HTTP/1.1.
- The HTTP/2 server sends `Set-Cookie`, `WWW-Authenticate`,
  `Proxy-Authenticate` and any `Authorization` or `Cookie` a response
  carries never-indexed. Every response field went into the HPACK dynamic
  table, session tokens included, where RFC 7541 7.1.3 says an entry's
  presence can be inferred from the compressed size of a later response an
  attacker can influence, and one-off tokens evict the entries worth
  keeping. The client already sent its own credentials this way.
- HTTP/2 on hl sends the headers it was given. HPACK found a static-table
  pair by its name and value joined with a NUL, and a HashLink string ends
  at its first NUL, so every pair of one name looked the same and the last
  one won: `:method GET` went out as POST, `:scheme http` as https and
  `:status 200` as 500, both ways. The table is kept as a map per name now.
- One HTTP/2 request can no longer hold the server for tens of seconds. A
  header section could decode to eight megabytes, a limit never advertised,
  and repeated fields were joined by appending each to everything before
  it: 200,000 one-byte references to one cookie crumb, about 200 KB on the
  wire, held the runtime's thread for 23.5 seconds, and every other client
  with it. The server now advertises `SETTINGS_MAX_HEADER_LIST_SIZE` of 64
  KB, the limit an HTTP/1.1 request's header block already had, and answers
  a section past it `431` on that stream alone: the block is still decoded
  to its end, so the connection and its other requests carry on (the same
  request now takes 54 ms on the jvm, the 431 included). Repeated fields
  are collected and joined once, on both versions. The HTTP/2 client holds
  a response to the same 64 KB, advertised, and refuses one past it without
  losing the connection, joins repeats once, and ends a connection whose
  header block runs on through CONTINUATION frames past 256 KB, as the
  server already did.
- Requests to an IPv6 literal carry its brackets. `URL` takes them off
  `[2001:db8::1]:8080`, and both clients put the host back bare, so `Host`
  and `:authority` read `2001:db8::1:8080`, which no server can split, and
  a relative redirect from such a host named `http://::1:8080/...`, which is
  not a URL. And `Host`, and a relative redirect, dropped the port for 80
  and 443 whatever the scheme: `http://host:443/` was sent as `Host: host`,
  which means port 80.
- A URL can no longer add a header to the request made from it. `URL` kept
  control characters, and the HTTP/1.1 client wrote the path, query and host
  into the request line and `Host` as they were, so
  `http://host/a\r\nX-Injected: evil` put that header on the wire, and a
  longer URL could smuggle a second request. `URL` now refuses a control
  character anywhere, and a space in the host. The request target is
  percent-encoded where it holds a space or anything past ASCII (a space ended
  it early), `User-Agent`, `Host` and `Content-Type` are sanitised as the
  caller's own header lines already were, and a method that is not an HTTP
  token, `URLRequest.method` takes any string, is refused before anything
  is sent. The HTTP/2 client encodes `:path` and sanitises its header values
  the same way, the Node and browser clients report a method or header their
  runtime refuses as an `IO_ERROR` rather than throwing out of `load()`, and
  a `Set-Cookie` holding a control character other than a tab is ignored, as
  RFC 6265bis says, instead of going back out in `Cookie`.
- Concurrent first HTTP/2 requests all find the bundled backend. It marked
  itself registered and was only added once the registry's lock was let go,
  so a request arriving in between found the mark, no backend, and failed
  with "HTTP/2 has no registered HTTPBackend": 5 of 6 concurrent first
  requests on the jvm, and the http2 sample every time.
- Metrics, `Future`, `ConnectionPool` and `ProcessLifecycle` take their locks
  on eval too. Their locks were gated on neko, hl and the jvm by name, which
  left out eval, threaded since workers became real threads there, so a
  counter updated from several threads could lose a whole thread's increments
  (a suite run counted 150,000 of 200,000), and a future completed on a worker
  while the runtime was registering its handler could lose the handler. They
  gate on `target.threaded` now; hxcpp keeps its lock-free paths.
- The whole suite builds and runs on hl and neko, and CI does both
  (`ci/hl-tests.hxml`, `ci/neko-tests.hxml`, `.github/workflows/hl-neko.yml`):
  neither target had been built anywhere, which is how neither compiled for
  five months unnoticed. `RPCSession` also compiles for a HashLink older than
  1.13, which is what Haxe assumes unless told otherwise with `-D hl-ver`: its
  session counter takes a lock there, as on neko, rather than stopping the
  build inside the standard library with "Atomic operations require HL
  1.13+". Cases that cannot run on these targets say why and check what
  happens instead: socket buffer sizes, which hl cannot read, and public
  address discovery and WebSocket clients, which need a secure random source
  neither has.
- On hl, a thread waiting for a slow TLS server no longer stops every other
  thread. HashLink's collector stops every thread and waits for each to
  reach a safe point or say it is blocked; its TLS layer read the network
  without saying so, so an HTTPS response that took six seconds held the
  runtime for six (5,986 ms between two ticks, and 4.5 s of CPU spent
  waiting), and a TLS client whose server ran in the same process waited
  out its whole socket timeout, the server unable to answer until the
  collection finished. `HlTlsSocket`, the TLS client `FlexSocket` makes on
  hl, gives mbedTLS reads and writes through HashLink's plain socket
  natives, which do say so: the same response held the runtime for 91 ms.
- `NativeProcess` runs on hl and neko, and its `pid` is the child's
  everywhere. It asked for an OS define before it would start anything,
  and nothing gives one to hl or neko, their bytecode runs unchanged on
  any OS, so both refused, though their `sys.io.Process` works wherever
  they do. On hl a child's output is read, and its exit waited for, inside
  a blocking section: HashLink's natives for both wait without telling its
  collector, which stops every thread until each reaches a safe point, so a
  child quiet for five seconds held the whole runtime for five. And the id
  was looked up as a `pid` field, by reflection, which no target's
  `sys.io.Process` has, so `pid` and every event's `pid` read -1 natively
  too. It comes from `getPid()`, which they all have.
- On neko, `File.createTempFile` and `createTempDirectory` work, and so
  does every `Store.put`. Where there is no secure random source, both drew
  names from `Std.random(0x7FFFFFFF)`, and neko's Int is 31 bits: that
  bound is not an Int there, and the native under `Std.random` refused it,
  so each threw before touching the disk, a store could be opened and
  read but never written. They draw sixteen bits at a time now.
- hl and neko have sockets again. CrossByte replaces `sys.net.Socket` and
  `sys.net.UdpSocket` on every target, and since 2026-04-28 neither target
  had a branch there, so both got a stand-in that threw, and each
  target's own `sys.ssl.Socket` extends that class and reaches into its
  private surface, so anything touching TLS, which is anything touching the
  network, failed to compile inside Haxe's standard library with errors
  that named nothing in CrossByte. Both now get their standard
  implementations, with the changes callers here were written against: an
  accept with nothing waiting is a would-block rather than null (hl); a
  peer's `host` is its address, where hl left it null and neko named every
  peer `127.0.0.1`; a second `close()` does nothing where neko's threw, and
  so did an unconnected socket's `peer()`; and a connection reset is a
  failure rather than the end of the stream, hl read both as `Eof`, and
  so did neko's `readByte`, so a body delimited by its connection's end was
  reported complete when the connection was cut partway through it. hl's
  `select` builds its descriptor sets per thread: the standard library kept
  one buffer for every thread, and two threads selecting at once got an
  answer for the wrong sockets up to one time in seven, or a failed select.
  And on hl every received datagram threw before it was delivered, because
  `Address.getHost` wrote an `ipv6` field hl's `Host` does not have: UDP,
  RUDP, STUN and ICE received nothing there. Its `host` text is the sender's
  address now wherever it is not converted natively, rather than `0.0.0.0`.
- `IndexedMap` and `PackedSlotMap` can have the entry a loop is on removed,
  as `ListedMap` and `DenseSet` now can. Both move their last entry into a
  removed one's place, and iterated with the value array's own iterator, so
  the entry moved in was skipped; `PackedSlotMap.forEach` counted its
  entries before it began and read past the end after a removal.
- `Array2D.clear()` empties the grid for every reference to it; it replaced
  the rows, so the same grid held elsewhere kept them. `fill(value)` sets
  every cell, the way to give an `Array2D` of `Int`, `Float` or `Bool`
  the same cells everywhere, since made without a value they are 0 on
  static targets and null on eval and JavaScript, which the documentation
  now says.
- A `RadixTree` lookup reads the key in place and allocates nothing. It
  built the common prefix of each label and the key a character at a time,
  and a substring of the key at every level: 2.3 microseconds and 6.4 KB a
  lookup on the jvm, now 0.1 microseconds.
- `WeightedGraph` finds a node by hashing rather than a pass over every
  node, so building a graph of n nodes no longer costs n^2 comparisons:
  20,000 edges in a chain took 15 s on eval and now take tens of
  milliseconds. Strings and integers are found by value and objects by
  identity, as `==` finds them.
- `Deque` keeps its items in a ring rather than a linked list, so adding
  one allocates nothing once the ring has grown: it made a 24-byte node
  for every item added on the jvm. It has `iterator()`, front to back, and
  `clear()`, and takes a starting capacity.
- `ObjectPool` no longer lends one object to two owners after a double
  release in a release build. It kept both releases, so the next two
  `acquire`s returned the same object; it now refuses an object released
  twice in a row, and any release while everything it made is already free,
  and `release` answers whether it took the object back. Debug builds
  still check every release. `maxFree` bounds how many free objects it
  keeps, where a burst of a hundred thousand used to stay for good.
- `MathUtil.nextPow2` answers the same on every target above 2^30: 2^31's
  bit pattern, `1 << 31`. JavaScript's Int does not wrap by itself, so it
  answered 2147483648 there and -2147483648 elsewhere.
- `Seq32` prints and divides as the unsigned number it is on the jvm. It
  printed through a Float, which the jvm writes in scientific notation,
  "4.294967295E9", and in hex saturated to 7FFFFFFF; and `%` passed a
  remainder of 2^31 or more through `Std.int`, which saturated it at
  2147483647. The documentation's example, `0xFFFF_FFFF`, did not compile.
- `PrimitiveValue.toInt` reads a number the same way on every target, or
  throws. It went through `Std.parseInt`, which read "4294967396" as null on
  eval, as that number on Node and as a thrown `NumberFormatException` on
  the jvm, and `Std.int`, which made the Float 3e9 2147483647 on the jvm
  and -1294967296 elsewhere. A string is now spaces, an optional sign and
  decimal or `0x` hex digits, within the range of `Int`, "12abc" throws
  rather than reading 12, and a Float outside that range throws. The
  documentation's example named a type, `Primitive`, that does not exist.
- `BloomFilter` packs its bits 32 to an `Int` and allocates nothing per
  check. It held an array element per bit, a 10-million-bit filter took 40
  MB on the jvm and 76 MB on Node for 1.25 MB of bits, and hashed a UTF-8
  copy of each item and a second, concatenated copy, 336 bytes per check on
  the jvm. It hashes the characters in place, mixes the second hash out of
  the first, and steps through the positions without multiplying, so every
  target sets the same bits. `clear()`, and `addInt`/`containsInt` and
  `addBytes`/`containsBytes` for items that are not strings, are new.
- `crossbyte.ds.Vector` works off hxcpp. `v[i]` threw on eval and the jvm
  and on JavaScript set a property of that name, losing the write: it was a
  class implementing `ArrayAccess`, which only hxcpp honours, and is now an
  abstract with array access over it. As in ActionScript, reading at or past
  the length throws `RangeError` and writing at it appends. Callbacks are
  called once each with as many of `(item, index, vector)` as they take;
  they were tried with two arguments and, on a throw, with one and none, so
  a callback that threw ran again without its index. `fixed` is enforced:
  what would change the length of a fixed Vector throws `RangeError`.
- `BitmapData.threshold` returns the pixels that passed and recolours all of
  them. Each case of the operation ended in `break`, which in Haxe leaves
  the loop the switch is in, so every call returned 0. It compares unsigned,
  as ActionScript's `uint`s do, so an alpha of 0xFF is above 0x7F.
- Removing entries while iterating works in `ListedMap`, `DenseSet` and
  `OrderedMap`. `ListedMap`'s value iterator counted the entries when it was
  made and read past the end after a removal, throwing on every target; its
  pair iterator and `DenseSet`'s skipped the entry swapped into the removed
  one's place (4 of 6 visited); `OrderedMap`'s walked an array of keys that
  a removal shifted under it (3 of 6). Removing the entry a loop is on now
  visits every other entry once in all three, and `OrderedMap` allows any
  removal. `OrderedMap` keeps its entries on a linked list, so `remove` is
  constant time, 20,000 removals took 332 ms on the jvm and 802 ms on
  Node, now 3 ms, and iterating reads no map; `ofIndex` walks to its
  position.
- `ExpiringMap` holds one object per entry, whatever it is touched. Every
  `set` and `touch` left a queue position behind, collected only once
  everything ahead of it had expired, so one idle session in front of 1,000
  busy ones touched 20 times a second held 2.4 million positions, 72 MB
  on the jvm after two minutes, however small `maxSize` was. Entries now
  sit on a list in deadline order and a touch moves one to the end: the
  same run retains 196 KB, and a touch allocates nothing. `length` leaves
  out entries that have expired unswept, as it always said it did, and
  `keys()` lists the one due soonest first.
- `InterestSet` and `BitSet` allocate nothing per round on the jvm and
  Node. Their lists and words were `Array<Int>`s: the jvm boxed every id
  above 127 as it was added and every word as it changed, and emptying a
  list with `resize(0)` gave V8 its store back each round, 2,952 bytes a
  round for a view of 50 on the jvm, and with the query's own array 2.2 MB
  a tick for 1,000 views. They are unboxed vectors with counts now, and
  iterating an `InterestSet` no longer copies its view.
- `SlotMap` and `PackedSlotMap` reuse the slot freed longest ago. They
  handed back the slot freed last, so one entity despawned and another
  spawned each tick reused one slot every time and brought its 11-bit
  generation round in 2048 ticks, 34 seconds at 60 Hz, after which a
  handle kept to the first entity resolved to a newcomer. Now a slot's
  generation comes round only after 2048 times as many inserts as there are
  free slots. `SlotMap` also tracks whether a slot is held apart from its
  value: an entry inserted as `null` was skipped by `forEach` and kept its
  generation through `clear()`, so its old handle could still write, and a
  handle made up for a free slot could `remove` it, `length` went to -1
  and the slot was handed to two inserts. Its generations and free list no
  longer box on the jvm.
- `Random.int` and `inti` draw from all of a range wider than 2^31 values.
  Its size was counted in 32 bits and overflowed, so `Random.int(0,
  0x7FFFFFFF)` was 0 every time on eval and the jvm, half of Node's answers
  fell outside the range, and the full `Int` range gave only negative
  numbers. Narrower ranges draw exactly what they drew before, so seeded
  sequences are unchanged. The shared generator's unseeded start no longer
  repeats between runs on the jvm, hl and neko: `Std.int(stamp * 1e6)`
  saturated there, on the jvm once the machine had been up 36 minutes,
  so every run drew one sequence. And `Random` compiles on hl again, whose
  default version has no atomics; hl before 1.13, neko and eval take a lock.
- `GlobalTimer` locks its ids and its map wherever there are threads. It
  locked them only on hxcpp, so on the jvm four threads setting and
  clearing timers at once were issued 1,051 ids twice in 16,000 and left
  entries behind, and a `clearTimeout` could stop another thread's timer;
  hl, neko and eval were as exposed. An id is now reserved in the same
  lock that picks it. The lock no longer allocates a closure per call, and
  whether an id is in use is asked only once the counter has wrapped,
  the jvm's `IntMap` answers that for a missing id by visiting every
  bucket, so each `setTimeout` cost a pass over every live timer.
- `Resources` reads only inside `resourcesDir`. Paths were joined to the
  directory as given, so a server loading a map by a name a client sent,
  `getText("maps/" + name)`: read whatever `"../../config.json"` named,
  and on Windows `"sample.txt::$DATA"` read through an NTFS stream name. A
  path with a `..` segment, a leading `/` or `\`, or a `:` (a drive letter,
  a stream name) is refused: `exists` answers `false`, `resourceSize` `-1`,
  and the loaders, the listings and `getAbsolutePath` throw
  `SecurityError`. `\` separates on every target, and empty and `.`
  segments are dropped.
- `PriorityQueue` serves equal priorities first come, first served. Each
  dequeue moved the newest element to the root and a strict comparison
  never sank it past an equal, so the newest was served next: a matchmaker
  holding one priority left 29 of its first 30 tickets queued at tick
  20,000, and 5,969 of 5,970 tickets were served out of turn. Ties now go
  by the order elements were enqueued; `update` keeps an element's place.
  The heap also sifts slot numbers rather than rewriting its element map at
  every level an element moves, which makes it about two and a half times
  faster on the jvm and seven on eval.
- A `MongoStatement` that fails reaches its `SQLErrorEvent` listeners on the
  jvm. Its failure paths, and `MongoConnection`'s, passed the caught
  exception where `SQLError` and `IOError` take a `String`, so on the jvm
  each was a ClassCastException that escaped `execute()`, left the
  listeners unrun, and lost what had gone wrong. The cause now travels as
  text, and a server's refusal as the `MongoError` with its code.
- A STUN answer whose FINGERPRINT does not match is dropped, and one
  carrying a comprehension-required attribute this client does not
  understand is not used (RFC 8489 sections 7.3 and 7.3.3). Both were
  believed, a damaged datagram settled the question with whatever
  address it now carried, and an attribute that changed what the answer
  meant was ignored, by `StunClient`,
  `ReliableDatagramServerSocket.discoverPublicAddress` and
  `PeerConnection`'s gathering alike, which share `StunQuery`. A deadline
  that passes after damaged answers says they came damaged, rather than
  that nothing answered.
- An IPv6 address in a STUN or TURN message is read. The family byte for
  IPv6 was taken for no address at all, so a STUN server answering over
  IPv6 reported no mapped address and a relay granting an IPv6 allocation
  had "allocated nothing" while it held one. Pinned to RFC 5769's IPv6
  sample.
- A TURN Send indication costs half what it did: its transaction id comes
  from random bytes drawn sixteen ids at a time, and the peer's
  XOR-PEER-ADDRESS is written once per peer rather than parsed from the
  address for every datagram, 610 to 350 ns for a 64-byte payload and
  1.1 us to 540 ns for 1200 bytes, natively. ChannelData is unchanged.
- A STUN message of more than 32 attributes (`StunMessage.MAX_ATTRIBUTES`)
  is not read. The count was the sender's, and each attribute costs an
  allocation and a copy, so one unauthenticated 64 KB datagram of empty
  attributes cost 527 microseconds to decode on cpp and 4.4 ms on Node,
  and a `PeerConnection` decoded every STUN-range datagram up to four times,
  once each for its reflexive query, its relay, its agent and a restart's
  agent. It decodes once now and shows the message to each, and a
  `PeerConnectionHost` hands on the check it decoded to route.
  `TurnClient.receive`, `IceAgent.receive` and `StunQuery.interpretMessage`
  take a decoded message for that.
- A `PeerConnection` whose relay refused, never answered or went away can
  ask for another. The dead relay stayed attached for the life of the
  connection, so asking again was refused as "already has a relay", and a
  relay lost after a network change was never replaced.
- Closing a `TurnClient`, or the `PeerConnection` holding one, frees the
  allocation on the relay. No Refresh with a lifetime of zero was sent, so
  the relay held the allocation and its port for as long as it had been
  granted, up to an hour on coturn, the next client on the same socket
  was refused with 437, and an application that reconnected ran into the
  relay's quota. The release is sent once, signed, and also when the
  Allocate is still unanswered, since the relay may have granted it.
- `TurnClient` believes only its relay. Relayed data was taken from any
  sender, a Data indication naming a peer, or ChannelData on a bound
  channel's number, from anyone who could reach the socket, was delivered as
  that peer, and a success answering a signed request was accepted without
  its MESSAGE-INTEGRITY being checked, so whoever saw a request go by could
  answer it with a relayed address of their own. Now only datagrams from
  the relay's address and port are TURN traffic, a Data indication is
  delivered only for a peer this client permitted, and an answer to a
  signed request must be signed with the same key (a 401 or 438 excepted),
  or carry a matching FINGERPRINT when it has one, or it is dropped as
  though it never came, as RFC 8489 has it; a request answered only by such
  messages fails saying so. A success carrying a comprehension-required
  attribute the client does not understand fails its request rather than
  being acted on.
- A TURN relay named by hostname is looked up once per allocation. Every
  request went to the name, which natively was looked up again every minute
  and on Node for every datagram; against a round-robin pool the requests
  bounced between relays that refused each other's nonces, and nothing was
  allocated. `TurnClient` now sends to the address the relay first answered
  from, and `serverAddress` says which. A relay that calls every nonce stale
  is given up on after three (`MAX_STALE_NONCES`) rather than asked some
  nine thousand times a second. Requests are transactions of their own, up
  to eight in flight (`MAX_IN_FLIGHT`) and 64 waiting (`MAX_QUEUED`), and a
  refresh never waits behind them: it was sent only when nothing else was
  outstanding, so a caller asking for permissions faster than the relay
  answered let the allocation expire. `permit` sends nothing for a
  permission already in place or already asked for, so calling it before
  every datagram, as `PeerConnection` now does, is cheap.
- A stale nonce on a TURN channel rebind no longer blacks the channel out.
  A 438 on a ChannelBind was neither retried nor used to take the new
  nonce, and the channel stayed marked bound while the relay, whose binding
  lapsed at ten minutes, dropped everything sent on it, for up to six
  minutes, with nothing reported. A ChannelBind is retried like any other
  request, and a rebind the relay refuses, or never answers, sends the
  traffic back to Send indications once the old binding has lapsed.
- A TURN relay refusing one peer refuses that peer, not the whole
  allocation. Any CreatePermission error but 401 and 438 closed the
  `TurnClient`, and ICE pairs a relayed candidate with every one of the
  peer's candidates, private host addresses first, which a hardened relay
  (coturn's `denied-peer-ip`, loopback by default) answers with 403. So the
  relay was gone before the relayed pair that would have worked was tried,
  and neither peer connected. A refused peer is now reported through
  `TurnClient.onPermissionRefused` and not asked about again, the allocation
  carries on, and `PeerConnection` gives up on the pairs the relay refused
  through the new `IceAgent.refusePairs` instead of checking into them for
  half a minute. A 437, the relay saying it holds no such allocation, still
  ends it.
- A TURN allocation survives a relay whose first answer is slow. The signed
  retry after the relay's 401 reused the unsigned request's transaction, so
  once that request had been sent twice, its answer took over half a
  second, or natively the relay's name took that long to resolve and both
  copies left together, the second 401 matched the signed retry and read
  as the credentials being rejected, while the relay granted the signed
  request and held an allocation nobody would use or free. Each
  authenticated retry is a new transaction now, as RFC 8489 has it, and
  answers to superseded ones are ignored. A CreatePermission success or a
  ChannelBind error, from anyone or duplicated, no longer ends whatever
  request is in flight: every answer is matched to its request by
  transaction. And a relay that never answers is given up on after RFC
  8489's 39.5 seconds rather than 63.5.
- On the jvm, TLS sessions are resumed. Every connection built a TLS
  context of its own, key store, key and trust managers, a random source,
  and a context is where sessions are kept, so none was ever resumed and
  each connection paid a full handshake. A listener now builds one for
  everything it accepts, and client connections share one per way of
  verifying, trusting and presenting a certificate, so a session made
  without verification is never resumed by a connection that verifies.
  Node's TLS 1.2 client now resumes 99 of 100 connections to a jvm server
  (0 before), in half the handshake time; a jvm client resumes TLS 1.2
  with a server that caches sessions (239 of 240, at 40% of the CPU) and
  TLS 1.3 with one that issues tickets. The JDK 8 server does not resume
  the TLS 1.3 sessions Node offers back, its own `SSLServerSocket`
  included.
- On the jvm, a TLS read takes every record that has already arrived, as
  far as the caller's buffer goes, where it stopped after one: a large
  upload was read 16 KB a pump, each pump paying a select over every
  connection the runtime held, so 10 MB took 2.4 s beside 2,000 idle
  connections. Records are decrypted straight into the reader's buffer, and
  an idle TLS connection holds none of the engine's buffers: each held
  three for its whole life, 64 KB a connection with its engine (15 KB now),
  over half a gigabyte at 10,000. They come from a small per-thread pool as
  reads and writes need them. And a handshake after the first is carried
  through: a TLS 1.2 renegotiation, which nothing answered once the first
  handshake was done, hung the connection with neither side told. A server
  carries three through for its peer, as Node does, and closes the
  connection at the fourth, each is a private-key operation on a
  connection already admitted. A handshake that fails now sends the peer its
  alert before the close, so the peer reports the reason, a certificate
  refused, or not presented, rather than "Remote host terminated the
  handshake".
- On the jvm, `select` keeps the sockets it is asked about registered from
  one call to the next. It registered every socket it was handed, checked
  every pair of them for duplicates and cancelled every key again, on each
  call, and the runtime makes that call on every pump with every socket it
  holds: 0.61 ms for 1,000 idle sockets, 5.8 ms for 4,000, and on Windows,
  past 1,023, a selector helper thread started and stopped on every call.
  It also leaves a blocking socket blocking, as native `select` does; a
  blocking reader met a read that answered "would block" at once rather
  than waiting for data on its way.
- A jvm connect no longer holds the thread that makes it. A non-blocking
  connect, every `crossbyte.net.Socket` and wss client connect, spun on
  `finishConnect()` until the connection came up, on the runtime's thread:
  two seconds of nothing else running against a listener whose queue was
  full, and the whole SYN-retry time, 21 s on Windows and two minutes on
  Linux, against a host that never answers. It returns at once now, as it
  does natively, and `select` finishes it: writable once it is up, and a
  refusal in the exception set. A blocking connect is bounded by
  `setTimeout`, as reads are, where only the system bounded it.
- A jvm https request whose server stalls or resets the TLS handshake
  fails at its timeout, with the reason. The handshake caught every error,
  a read that timed out, a reset, slept 2 ms and tried again, ten
  thousand times: a server that accepted and said nothing held the request,
  and one of `URLLoader`'s pool threads, for ten thousand times its timeout
  (83 hours at the default 30 seconds), and a reset took 25 seconds to
  report as a handshake that "did not complete". Only a record that has
  arrived in part is waited on now, within what is left of the timeout as
  a whole; anything else is thrown as it came. A record larger than the
  read buffer grows the buffer rather than waiting for ever.
- On the jvm, a certificate file is read whole. Only its first certificate
  was, so a server given the `fullchain.pem` an authority issues presented
  its certificate without the intermediate, and curl, Node, browsers and
  the JDK all refused it; and a CA bundle, `setCA`, `DEFAULT_CA`,
  `requireClientCertificate`, `certAuthority`, trusted its first
  authority alone. Native and Node read every certificate, and now so does
  the jvm, for a server's own chain, an SNI entry's and every trust store.
  A key in the same PEM file as the certificates no longer stops it being
  read either.
- `Socket.timeout` holds on Node: a connect not open by then is ended and
  reported as an `ioError`, a secure one's TLS handshake counted with it,
  as natively. Node gave a connect no deadline of its own, so one to a
  server that took the connection and never answered its TLS hello was
  waited on for good.
- A `Socket` connected again on Node keeps the new connection. The socket
  given up went on reporting, and its reports were taken for the one that
  replaced it: a refused connect's close, which comes a turn after its
  error, released a connect retried from that `ioError`, which then
  connected with nothing to write to; and a connect abandoned for another
  still announced `connect` when it came up, and its end closed the
  connection that replaced it.
- A client `Socket` turns Nagle's algorithm off before it connects rather
  than once the connect is under way. Windows refuses TCP_NODELAY on a
  socket whose connect is in progress and hxcpp does not report it, so
  natively on Windows a client kept Nagle's algorithm on every connect that
  took any time, every one over a network, and a small write waited for
  the acknowledgement of the last.
- A jvm runtime holding many TLS connections pumps faster: the registry asks
  every TLS socket on every pump whether its TLS layer holds decrypted
  bytes, and asked through a dynamic call, 150 to 245 us of each pump at
  2,001 idle connections. It asks through the socket's type now, 16 to 43
  us.
- On neko a runtime services more than 64 sockets. Its registry selected
  every socket it held at once, and neko's `select` takes at most 64 on
  Windows and throws past them, so from the 65th connection no socket was
  serviced at all: 39 of 100 connections timed out. neko now polls through
  its poll natives, which size their sets to what they are given on
  Windows and call `poll()` elsewhere, so a descriptor of 1024 or more,
  which overflowed `select`'s set on Linux, is watched too. hl's `select`
  sizes its sets itself on Windows; on Linux it still cannot watch a
  descriptor of 1024 or more.
- A socket leaves its poll backend before it is closed, and a backend that
  fails no longer leaves a runtime polling nothing. `Socket` closed its
  descriptor and only then queued its deregistration, which a backend that
  registers each descriptor with the system, libuv's, is not allowed:
  libuv forbids closing a descriptor it is polling, and when a child
  process had inherited the file its epoll registration outlived the
  close, so the loop woke for it without sleeping for good. `PollBackend`
  has a `remove(socket)` now, called as a socket is deregistered, while it
  is still open, and every close deregisters first; the built-in backend
  does nothing with it. A backend whose `prepare` or `events` throws is
  replaced by the built-in one, which is prepared at once, where it failed
  the same way every pass; a factory that throws gives the built-in one;
  and a registry grows with the factory it was made with, making the
  larger backend before disposing of the old, so installing a backend
  later never moves a runtime onto it partway through its run. A backend
  implementing `PollBackendGrowable` grows in place.
- A half-open connection held by a server costs nothing while it waits.
  After the peer's FIN a `HALF_OPEN` socket stopped reading but stayed in
  the poll set, where end of stream is readable for good: it was reported
  on every poll, so a POLL loop spun a core per connection held that way
  (3.1 to 3.5 s of CPU per 3 s), and each report flushed again, a write
  that failed was reported every time, 25,566 ioErrors in half a second on
  a TLS 1.2 connection, and the socket was never closed. It leaves the poll
  set's reads once the peer has finished, or `shutdown(true, ...)` has shut
  them, and can still be written to; and a write that fails for a reason
  other than a full buffer closes a socket that reads nothing more, after
  its one `ioError`, since its read side will never reap it.
- Connections are taken, dialled and secured as the system reports them,
  not at the next tick. A POLL loop spends each frame blocked in poll,
  which only a socket in the poll set can end, and listeners were never in
  it: accepts ran from the tick, a connect in flight was watched from the
  tick, and every TLS handshake, a `ServerSocket`'s, and both ends of a
  `wss://` session, was stepped from the tick, a round trip a frame. So
  connect to accept took 41 ms on eval and 52-57 ms on the jvm at the
  default twelve ticks a second, a connect started from a data handler
  waited 80 ms, and a jvm TLS client waited a median 132 ms to
  secureConnect. Listeners are in the poll set now, and read when
  connections are waiting, `maxAcceptsPerTick` at a time; a connect in
  flight is watched for writing; and a handshake is stepped as its socket
  turns readable. Measured at twelve ticks a second, connect to accept is
  0.5 ms on eval and 0.9 ms on the jvm, and a connect from a data handler
  1.2 ms. The tick stays for deadlines: a plain `ServerSocket` has none
  now. A listener at `maxPendingHandshakes` leaves the poll set until one
  finishes, so a full server does not spin.
- A WebSocket client dials an IPv6 literal. The host it was given had to be
  a run of letters, digits, dots and hyphens, so
  `WebSocket.connect("::1", port)` threw "Invalid host" before a socket
  existed, on every target, and a page's `Socket` read the same pattern.
  A literal is taken bracketed, as a URL writes one (`[::1]`,
  `ws://[2001:db8::1]/chat`), or bare, and written bracketed into the URL
  and the `Host` header; names and IPv4 addresses read as before.
- A `ServerSocket`, and so an `HTTPServer`, listens on neko. With no
  backlog given, `listen()` asked for one of `0x7FFFFFFF`, which neko's
  31-bit integers cannot carry, so its natives threw and no server could
  start. The default is `0x7FFFFFF` on every target now, as
  `ServerWebSocket`'s already was, and `FlexSocket.listen()`'s too; any
  backlog past the system's maximum is granted as that maximum, so what a
  server gets is unchanged, 200 connections on a client edition of
  Windows, measured for each value.
- A `ServerWebSocket` accepts sessions on eval, hl and neko. Each session
  it accepted drew a client's handshake key from `SecureRandom` before
  asking whether it was a client, and `SecureRandom` refuses on those
  targets, so every upgrade threw in the accept tick and the peer was
  reset: a server there accepted nothing, whatever this changelog said of
  WebSockets on the interpreter. Only a client draws a key now. A client on
  those targets still needs `SecureRandom`, for its key and its masks, and
  is refused as before.
- A closed connection is let go of. The socket registry's writable queue is
  a `Stack`, whose `clear()` only reset its count, so the backing array held
  every connection that wrote in a busy pass, and through the system
  socket's `custom` the whole `Socket`, its buffers and its `userData`,
  until a later write happened to take its slot; and the select buffer held
  the last connections polled once nothing was left to poll. 150 closed
  connections carrying 64 KB of `userData` each all survived five
  collections on the jvm. `Stack.clear()` empties the slots it counts out,
  and the registry lets go of its select buffer when its set empties.
- A jvm TLS server asks for client certificates only after
  `requireClientCertificate()`, as a native one does. Once the jvm honoured
  `FlexSocket.DEFAULT_VERIFY_CERT`, a listener that set no `verifyCert` of
  its own followed it too, so turning the default on for an application's
  outgoing connections made its servers refuse every client without a
  certificate, every browser.
- A closed `ServerSocket` or `ServerWebSocket` no longer keeps accepting.
  Each path that wanted the accept tick running added it to the runtime
  again, a `connect` listener added after `listen()`, as `NetHost` does,
  and `ServerWebSocket`'s own, and close removed one, so the rest ran on
  for good, a `ServerWebSocket`'s calling `accept()` on its closed listener
  every frame and keeping the server alive. Natively those accepts fail on
  the closed socket; eval keeps the closed socket's descriptor number, so
  once a new listener took it the accept landed there, and since eval
  cannot make a socket non-blocking it waited on it, stopping the runtime
  for good. The interpreter suite hung on Linux that way. The
  tick is now attached once and removed once, a closed server's tick does
  nothing, and on eval a `ServerWebSocket` asks `select` before `accept`.
- A jvm TLS client's engine is told the host and port it dialled. Made
  without them, a certificate check the SNI name could not settle fell back
  to a host of null: on Temurin's Java 8 a certificate for another host was
  refused as "Hostname or IP address is undefined" rather than for its name.
  And a connection to an IPv6 address threw before a byte was sent, since
  the address went out as an SNI name, which the JDK refuses for an IPv6
  literal. An address is no longer sent as SNI at all, which RFC 6066
  forbids; it is checked against the certificate's IP entries.
- `PostgresConnection.inTransaction` on the native driver is the server's
  own account, taken from libpq after every statement. Only `begin()`,
  `commit()` and `rollback()` changed it, so a transaction begun or ended
  as SQL text, `request("BEGIN;")`, read as none, and a pool returning
  the connection saw nothing to roll back.
- Natively, a host loop that only calls `pump()`, no sleep, nothing
  allocated, as a benchmark or an embedder's busy loop does, stalled every
  other thread at its next garbage collection for good: the collector waits
  for each thread to reach a safepoint, and that loop never did. `pump()`
  reaches one now, at no measurable cost (an idle pump is 52-53 ns either
  way).
- On the jvm, a TLS socket's reads ignored `setTimeout`, so an https
  response that stopped arriving was waited for for ever and the HTTP
  client's idle limit never fired over https. The TLS socket now waits for
  ciphertext the way the plain socket does since its own timeout fix.
- On the jvm, `FlexSocket.DEFAULT_VERIFY_CERT` did nothing: a TLS socket
  read only its own `verifyCert`, so turning verification off for every
  socket, as a development setup does, still refused a self-signed server.
  An unset `verifyCert` now falls back to the default, as it does natively.
- On the jvm, a reliable datagram session a server dialled to an IPv6
  address never connected. It was filed under the address as the jvm spells
  it, `0:0:0:0:0:0:0:1`, while datagrams arrive from `::1`, so the peer's
  replies found no session. A dialled address is filed compressed now, as
  arriving ones and dials by name already were.
- `ReliableDatagramServerSocket.discoverPublicAddress`: and so a
  reliable-UDP `NetHost`'s, with a STUN server name that does not
  resolve fails at once instead of at its deadline. The send it asks with
  looks names up off the runtime's thread now, so the failure came after
  the call, as an `ioError` on the socket every session shares, and
  nothing told the question: it waited out its whole deadline. The name
  is now looked up before the question is asked, and one that does not
  resolve fails it with that reason. On Node, which looks the name up
  itself for each request, it still waits for the deadline.
- The PHP bridge looked its backend up and connected to it on the runtime's
  thread, for every request, so each PHP request held every socket and timer
  on the runtime for a name lookup and a connect: 0.29ms for an address and
  0.47ms for `localhost` on loopback, measured, and for a name that does not
  resolve as long as the resolver took, commonly a second. Both happen on a
  thread of the bridge's own now, which hands the connection back through the
  runtime's post queue: a request holds the runtime for 0.02ms, and the round
  trip is no slower. A name is looked up once, and again only after a
  connect to its address fails, so a backend that moves is found at its new
  address. A request that times out while connecting says so.
- A PHP response waited for the runtime's next tick before it was read. The
  bridge read its FastCGI connection from a tick listener, so at the default
  twelve ticks a second a response arrived up to 84ms after PHP sent it,
  however quickly PHP had answered: measured against a backend that answers
  at once, 49-53ms on average in a server's `POLL` loop. The connection is in
  the runtime's poll set now, as `crossbyte.net.Socket`'s are, and the reply
  is read when it arrives: 0.5-0.7ms on average in the same measurement. A
  backend that hangs up mid-response is heard as it hangs up. On eval, where
  a socket cannot be made non-blocking, the bridge no longer blocks the
  runtime reading a reply that has not arrived yet. Node was already told of
  arrivals by an event.
- Recording a metric took a lock on hxcpp, and acquiring an hxcpp `Mutex`
  enters and leaves a GC-free zone: about 230ns for each `Counter.inc`,
  `Gauge` update and `Histogram.observe`, so the two an HTTP server records
  for every response cost it close to half a microsecond. They are atomic
  instructions now, measured at 5ns for an increment and 15ns for both of a
  response's updates. A histogram observation adds to the one bucket it
  falls in rather than to every bucket above it, which is cheaper on the
  other targets too, and a histogram's count is the total of its buckets. A
  scrape reads each histogram once, so its `+Inf` bucket and `_count` agree:
  they were read separately, and an observation between the two reads made
  them differ. On hxcpp a histogram's `_sum` can count an observation its
  buckets do not show yet, or the reverse, while observations arrive.
- A request body over 16 KB reaches the server whole over `https`, natively
  and on the jvm. The client wrote it with `Output.writeBytes`, which writes
  what it can and says how much, and a TLS socket takes one record, 16 KB,
  at a time: the rest was dropped, and the server waited for it until the
  request timed out. HTTP/2 wrote every frame the same way, so a full-sized
  DATA frame lost its last nine bytes and the server closed the connection.
- On the jvm, every `URLLoader` load left two sockets open until the process
  ended: the thread it ran on opened a selector for its reads, and nothing
  closed it when the thread ended. With eight loads in flight at a time,
  9,000 of 15,000 failed with "Address already in use". Loads run on
  long-lived threads now, so there are as many selectors as threads, not as
  loads, and none of them fail.
- A `URLLoader`'s `COMPLETE` or `IO_ERROR` listener can start its next load.
  The loader was still busy while they ran, so the new load was refused with
  "URLLoader is already loading".
- Over HTTP/2 a redirect is followed, as it is over HTTP/1.1, on Node and in
  the browser; a 3xx completed the load with its `Location` unread. The
  HTTP/1.1 client's rules apply, through the same code: at most
  `Http.MAX_REDIRECTS`, a relative `Location` resolved against the request,
  a 301, 302 or 303 made a bodiless GET, `https` to `http` only with
  `followInsecureRedirects`, `Authorization`, `Proxy-Authorization` and a
  hand-set `Cookie` dropped once a hop leaves the origin, and, with
  `manageCookies`, a cookie a hop sets sent back on the next. A hop to an
  origin already connected rides that connection, and `HTTP_RESPONSE_STATUS`
  names the URL the response came from. A HEAD stays a HEAD through a 301,
  302 or 303 on both versions: over HTTP/1.1 it became a GET, and downloaded
  the body it had asked not to be sent.
- `idleTimeout` over HTTP/2 is an idle limit, as it is over HTTP/1.1 and on
  Node: the longest a response may go with nothing arriving for it. It was a
  deadline on the whole response, so a download still arriving steadily was
  cut off when the timeout ran out, where HTTP/1.1 let it finish.
- An HTTP/2 request cancelled before it started no longer closes the
  connection it would have used. The session refused it before sending
  anything, and the backend took that for a failed connection and closed
  it, failing every other request in flight on it. It reports `Request
  cancelled` now, as a cancel at any other point does.
- Cancelling an HTTP/1.1 load, `URLLoader.close()` with a load in flight,
  or its `cancelToken`, ends it on every target, and at once. A cancel that
  landed after the load had looked at its token and before its socket
  existed, while the connection pool was searched, while the socket was
  made, or between two redirects, found nothing to close and was lost: the
  request went out anyway, and its thread waited out the idle timeout for an
  answer nobody wanted. And the cancel closed the socket from the cancelling
  thread. On Linux that does not wake a read already waiting on the socket,
  so the server heard nothing until the read gave up; on eval it killed the
  loading thread with an error no catch sees, and the reset it caused killed
  the server's reader too; and closing a TLS socket frees its mbedTLS
  context under a read that may still be using it. Now the socket is
  published under a lock the cancel also takes, so one always finds the
  other, and it is shut down rather than closed, which ends the read and
  tells the server at once; the loading thread closes it itself. A cancelled
  load reports `Request cancelled` whichever step failed under it, and a
  body that ends with the connection is no longer delivered as complete when
  a cancel is what ended it.
- `File.clone()` gave the clone the original's listeners, where its
  documentation says registrations are not copied. It copied every instance
  field by reflection, `EventDispatcher`'s listener map included, so once the
  original had a listener, one added to either reached both; on the dynamic
  targets it also copied the original's bound methods, so the clone's
  `addEventListener` registered on the original. It copies the file's own
  state now, and the clone starts with no listeners.
- On eval, `sys.net.Socket`'s `input.readByte()` answered 0 at the end of a
  connection instead of throwing `Eof` as every other target does, so a
  reader waiting for a delimiter there, a line reader, read zeros for
  ever. It reads through `readBytes` now, which knows the end when it sees
  it. The HTTP client had worked around this for itself only.
- On the jvm, `sys.net.Socket.setTimeout` did nothing, so a blocking read
  with nothing coming waited for ever. A blocking NIO channel has no read
  timeout of its own, `SO_TIMEOUT` reaches only the stream API, and the
  value was stored and never read. CrossByte's HTTP client reads a response
  that way with its idle limit as the timeout, so on the jvm it could wait for
  ever on a server that stopped sending. A blocking read with a timeout now
  waits for data on the thread's selector first and throws when none comes.
- `FileStream.openAsync` for writing throws `IllegalOperationError` on a
  target without threads, Node, in practice, instead of never returning.
  Its writer is a worker that waits for writes, and with no thread of its own
  it waited inside the call. Where there are threads, async reads now honour
  `readAhead` on the jvm and eval as well, which run workers on threads now.
- `StunClient.discover` with a server name that does not resolve fails at
  once instead of at its deadline. Names are looked up off the runtime's
  thread now, so the failure arrives as the socket's `ioError` after the
  send returns, and the query was not listening for it.
- On Node, a socket, server, WebSocket or datagram listener that throws is
  reported as the runtime's `UncaughtErrorEvent`, with source `SOCKET`, as it
  is natively. The failure was contained there already, but only logged: an
  application watching `UNCAUGHT_ERROR` never heard of a failure Node's own
  loop delivered.
- `removeEventListener(type, this.handler)` removed nothing on eval and the
  jvm. It reads the method again, and there every read of a bound method is
  a new closure that `==` never matches, hxcpp compares two reads equal and
  JavaScript caches the binding, so native and Node were right. The listener
  stayed attached for good: a closed socket or a stopped component went on
  being called, which is how `TCPConnection.close()` came to report its close
  twice on eval. Listeners are now matched with `Reflect.compareMethods`
  where `==` falls short.
- OAuth's token exchange no longer blocks the runtime, and a provider
  that never answers no longer leaves it waiting forever. Native targets
  used the blocking `haxe.Http`, so a token endpoint taking 400 ms held
  every connection the server had for 400 ms per sign-in; on Node a
  stalled endpoint left both callbacks unfired. The exchange and refresh
  now go through `URLLoader`, off the runtime's thread on native and
  asynchronously on Node, answering on the calling runtime's thread, and
  fail after `OAuth.timeout` seconds. A rejected grant reports the
  provider's `error` and `error_description` whatever the status it came
  with, and a failing status is never taken for a token. `expires_in` is
  read with `IntParse`, so one too large for an `Int` is 0 on every target
  rather than whatever `Std.parseInt` made of it on each.
- A JWT expiring after January 2038, or at 2147483647 (a common "never"),
  is judged the same on every target. Times were `Int`: 2147483647 plus the
  leeway wrapped negative on the interpreter and the jvm, so the token was
  expired there and valid on cpp and Node, and the jvm refused every time
  past 2038. Times are now seconds in a `Float`, and may be fractional as
  RFC 7519 allows. A registered claim of the wrong JSON type, a numeric
  `sub`, a string `iat`, is refused as `malformed` rather than handed
  back through a typed property.
- `JWT.verifyToken` accepts tokens from other issuers. It refused any
  whose `typ` was not exactly `JWT`: AWS Cognito's and Sign in with
  Apple's, which carry none, RFC 9068 access tokens (`at+jwt`), and a
  lower-case `jwt`. `typ` is now compared in any case, with an
  `application/` prefix ignored as RFC 7515 allows, against
  `acceptedTypes`: `JWT` and `at+jwt` by default, and a token with no
  `typ` passes unless `requireType` is set.
- RSA and ECDSA signatures no longer leave copies of the private key in
  freed memory, and `JWTSigner.RS256` and `ES256` parse their keys once
  instead of for every token. Each sign and verify parsed the PEM afresh,
  from a copy in the GC heap made per call and a native buffer freed
  without being wiped, and rebuilt an EC key's precomputed tables every
  time. Keys are now parsed once, into native memory that mbedTLS wipes
  when it is freed, and every buffer that held a key is wiped before it
  is released. Signing and verifying also run in a GC-free zone, since a
  4096-bit RSA signature takes about 25 ms: on a worker, it held every
  collection in the process for the rest of the signature it landed in.
- Password hashing on a worker thread no longer stalls every collection
  in a native process. hxcpp collects only once every thread reaches a
  safe point, and neither libsodium's Argon2id nor BCrypt's inner loop
  ever reached one, so moving a hash off the runtime's thread moved the
  stall onto all of them: a collection on the main thread waited 286 ms
  of a 317 ms Argon2id hash on a worker, and 302 ms of a 332 ms BCrypt
  hash. libsodium's password hashes now run in a GC-free zone, with the
  password copied to native memory first and wiped after, and BCrypt
  reaches a safe point every two rounds. The same collections take about
  a millisecond.
- `SecureRandom` on Linux and macOS made its lock on first use, so two
  threads drawing their first bytes at once could each make one and read
  `/dev/urandom` together. It is made up front.
- BCrypt adds the key's terminating NUL for every revision. It was added for
  `$2a$` alone, and `$2y$`, the default, was computed without it, so no hash
  CrossByte made verified anywhere else, no hash migrated from PHP, Laravel,
  Node or Python verified here, PHP's own manual example among them, and
  a password matched its repetitions: without the NUL the key is the
  password cycled to 72 bytes, so `hash("abc")` accepted "abcabc". Hashes
  CrossByte stored before still verify: a `$2y$` hash that fails the
  standard check is tried once more in the old form, and only `$2y$`, the
  one revision it ever produced. `$2x$` hashes are checked with
  crypt_blowfish's sign-extension bug and `$2a$` with its countermeasure, as
  PHP checks them. A cost of 31 ran no rounds at all, since `1 << 31` is
  negative in an `Int`; it runs 2^31.
- `File.createTempFile` and `createTempDirectory` can no longer be steered
  by another user of a shared temporary directory. The name was "ofl" and a
  `Math.random` number below 2^24, and the file was made after checking the
  name was free, by a write that follows symbolic links, so a user who
  planted links at likely names had the next temporary file written
  wherever they pointed. A name now carries 64 bits from the platform's
  secure random source, and the file or directory is created only if
  nothing is at the name, `O_CREAT | O_EXCL | O_NOFOLLOW`, readable by its
  owner only, on POSIX; `CREATE_NEW` on Windows; their equivalents on the jvm
  and Node, with a taken name passed over for another. The interpreter,
  which has neither, still checks first.
- An asynchronous `FileStream` read hands out only bytes it has read. The
  read buffer was allocated at the file's full size before anything was
  loaded, so `bytesAvailable` counted the whole file from the first
  progress event, and reading that much, which the class documentation
  says to do, returned zeros for everything not loaded yet: 6.4 MB of them
  from a 10 MB file on Node. The buffer now grows as data arrives. Where the
  stream's worker has a thread of its own, `readAhead` is honoured as well:
  loading pauses while that much is waiting to be read, and with a finite
  `readAhead` consumed bytes are let go, so a stream holds about that much
  rather than the whole file. Setting `position` outside what is held
  starts loading again from there.
- A chunked `FileStream` copy is exact. A synchronous `readBytes` past the
  end of the file padded the missing bytes with zeros and returned as
  though it had read them, so the usual loop, read a chunk until
  `EOFError`: never saw one, and a 1 MB file copied in 64 KB chunks came
  out 65,436 bytes longer, the tail all zeros. A short read now throws
  `EOFError` and leaves the position where it was, so what is left can
  still be read (see Changed).
- `writeUTF` refuses a string of more than 65,535 bytes with a
  `RangeError`, as documented, in `ByteArray`, and so in the sockets that
  write through it, `ByteArrayOutput` and `FileStream`. The 16-bit length
  in front of the string wrapped, so the reader stopped short and every
  read after it landed inside the string: a `readInt` after a 70,000-byte
  string returned 2021161080 for 42. A synchronous `FileStream.writeUTF`
  also threw `Overflow` from 32,768 bytes, a string `ByteArray` accepted,
  because it wrote the length as a signed short.
- `File.size` no longer reports a file larger than 2 GB as some other size.
  It is an `Int`, and what the standard library's `stat` made of a larger
  file differed by target and was right on none: on Windows native a 3 GB
  file read as 0. It now throws an `IOError`, as the HTTP server already
  refuses such a file, checked against a 64-bit size where the target has
  one and otherwise by asking the file whether it goes on past the
  reported end.
- A `Store` key survives a crash while it is being overwritten. The file
  backend replaced a value by deleting it and then renaming the new one into
  place, because the standard library's rename refuses to replace a file on
  Windows; a process that died between the two left no value, and the next
  open deleted the complete new one as debris. Between the two steps a
  reader saw the key as absent, too: two runtimes on one store, one
  overwriting and one reading, read it as missing in about half of 4,000
  reads, and on Windows a reader holding the file failed the writer's
  delete. The new value is now renamed over the old one in one step
  (`MoveFileExW` on Windows, `Files.move` on the jvm), so the key is never
  absent; each write uses a temporary file of its own rather than one name
  shared by every writer; and the temporary file is flushed to disk before
  the rename, as the store's design promised, with the directory flushed
  after it on POSIX. The interpreter has no fsync to call. A temporary file
  the old writer left as the only copy of a key is promoted on open rather
  than deleted.
- A PHP request body over 65,535 bytes reaches php-fpm intact. The bridge
  put the whole body in one FastCGI STDIN record, whose length field is 16
  bits, so a 100,000-byte POST declared 34,464 bytes and php-fpm read the
  rest of the body as record headers; the parameters went in one record the
  same way. Both are now split across records the way php-fpm reads them,
  parameters only between pairs, since it parses each PARAMS record on its
  own, and a single header too large for any record is refused with an
  error rather than sent broken. On native the request was also written in
  one burst on a non-blocking socket, so on Linux an upload larger than the
  kernel would take at once (about 2.6 MB to a backend not yet reading)
  failed as "Could not reach the PHP backend", a 502. The rest is now
  written on the ticks that follow, as the backend reads it.
- PHP responses reach the client byte for byte. The whole FastCGI output
  was decoded as UTF-8 to find the end of the headers and the body
  re-encoded from that string, which mangled images, PDFs, archives, gzip
  output and Latin-1 pages; Node cut a body off at its first NUL, and eval
  threw from inside the tick. The header block is now found on the bytes
  and only it is decoded, as UTF-8 where it is valid, a byte per character
  where it is not, and the body is passed on untouched. A `Status` header
  that is not a three-digit code is ignored: `99999999999` became status
  2147483647 on Windows and 1215752191 on Linux.
- A failed PostgreSQL or MySQL transaction is no longer reported as
  committed. `commit()` caught the server's refusal and dispatched an event
  instead of throwing, so the documented `AsyncDatabase.transaction(c ->
  c.begin(), c -> c.commit(), ...)` completed as success, `SchemaMigrator`
  recorded a migration that had been rolled back, and the connection went
  back to the pool still marked as inside a transaction. A COMMIT that
  PostgreSQL answers with the tag ROLLBACK, which is what it does after a
  statement in the transaction failed, discarding all of it, also read as
  success, since only the tag says otherwise. Both now throw an `SQLError`
  (see Changed), the tag is read on the native driver, and
  `AsyncDatabase.transaction` rolls back when the commit throws, closing a
  transaction an engine keeps open after a failed COMMIT before the
  connection is pooled again. A savepoint the server refused is no longer
  remembered as the innermost one.
- Native PostgreSQL connections no longer share one result buffer. Every
  connection and thread in the process wrote the bridge's single buffer,
  results, escaped strings, and the reason an open failed, and
  `requestParams` read its result back through a second call, a byte at a
  time. With `AsyncDatabase`'s default of a worker per pooled connection, a
  query could come back with another query's rows, an open could report
  another connection's failure, and a thread could read a buffer another
  had just grown and freed. Against a stand-in libpq, 8 workers running 400
  bound queries each got an answer that belonged to another query and 7 of
  them threw; another run crashed the process. Each connection now keeps
  its own state, and each call returns its own result in one call, copied
  from libpq's memory straight into the block the caller receives. Loading
  libpq is locked. A connection configured with its own `libraryPath` now
  gets that library even after another has been loaded; the first library
  loaded used to serve every connection after it.
- A PostgreSQL query or connect no longer holds up garbage collection on
  every thread. The bridge called libpq with the thread still counted as
  running Haxe code, so the next collection anywhere waited for the query
  to finish: a slow report, a lock wait or an unreachable database host
  stopped the runtime thread and every socket it served. Against a
  stand-in libpq, a collection waited 2.3 seconds for a query and 1.25 for
  a connect. Connecting, executing, cancelling and closing now run in a
  GC-free zone, with the statement and its parameters copied out of the
  Haxe heap first.
- Adding or removing an event listener copies the listener list only while
  a dispatch is walking it. It copied on every call, so n listeners on one
  type, a connection or a task each attaching its own, cost n^2 to
  attach and again to detach: a thousand added and removed took 5.6ms
  natively, and takes 75us now (removed newest first, 20ms and 3ms, where
  finding each one is the cost left). A listener added after the others of
  its priority, the usual case, no longer walks the list to find its place.
  What a dispatch sees is unchanged: a listener added during it does not
  run for that event, and one removed during it still does.
- `CrossByte.cpuLoad` counts a POLL loop's socket handlers, and the posted
  callbacks any loop runs while it waits out a frame. It was measured before
  the poll, so a POLL server busy with its sockets half of every frame
  reported 0%. Time spent blocked in poll, waiting for a socket, still does
  not count as load.
- `System.memoryUsage()` reports the heap in use on the jvm and Node, and
  natively takes the collector's 64-bit figure. It was the 32-bit one, which
  wrapped negative past 2 GiB, and 0 on every other target.
- Timer handles are never negative. The id took 20 bits and the 12-bit
  generation above it reached the sign bit, so from a slot's 2,048th reuse
  every handle for it was negative, against what `TimerHandle` said of
  itself, and a live handle at the top id could equal `TimerHandle.INVALID`.
  The id has 19 bits now: a runtime's scheduler holds up to 524,288 timers at
  once and throws when asked for more, where ids past 1,048,576 used to wrap
  onto other timers without a word.
- A shutdown callback that throws is logged with `Logger.error` (category
  `runtime`). It was swallowed silently; the callbacks after it and the exit
  path still run.
- A `ServerApplication` runs on Node, an `Application` can be made on the
  interpreter, and `docker stop` or Ctrl+C on a jvm or Node service runs the
  shutdown callbacks. `ServerApplication`'s POLL loop threw on JavaScript at
  its first frame, since there is no socket set to poll there, which took
  down the web-server sample; POLL runs the DEFAULT loop on JavaScript now.
  On the interpreter `Thread.current() != mainThread` was true on the main
  thread itself, only `==` compares threads there, so every
  `Application` subclass threw "must only be instantiated in the main
  thread". And `ProcessLifecycle.installDefaultHandlers()` armed nothing off
  native: Node exits on SIGTERM and SIGINT unless something listens, and the
  JVM's default halts after its shutdown hooks, so neither drained. It now
  listens for both on Node and sets the JVM's own signal hook for INT and
  TERM, latching the request as the native handlers do and waking the
  runtime to run the callbacks.
- A `SlotMap` or `PackedSlotMap` handle kept after its entry died no longer
  comes to name whatever takes its slot 256 reuses later. The generation
  was eight bits, and the free list hands the most recently freed slot back
  first, so a missile's target or a last attacker resolved to an unrelated
  entity within seconds of churn. It is eleven bits now, as `TimerHandle`'s
  was widened for the same reason. The sign bit is no longer part of it, so
  a handle is never negative, past 128 reuses every handle was, and a
  live one at the highest index was `SlotHandle.INVALID` itself.
  `SlotMap.clear()` counted the generation without keeping it in range,
  bringing back the leak `remove()` was fixed for: a slot at the top of its
  range held a value no handle could carry, and an entry put there after the
  clear could never be read back.
- `Config.getInt` refuses a value too big for an `Int` on every target, and
  `Version` reads an oversized segment the same everywhere. Both used
  `Std.parseInt`, whose answer past 32 bits depends on the target:
  4294967296 read as 0 on Linux native and 2147483647 on Windows native,
  threw a `NumberFormatException` on the jvm and came back wider than an
  `Int` on JavaScript, so a configured connection limit could quietly become
  0. `getInt` now throws `ArgumentError` for it as for any other malformed
  value, and a version segment past three digits reads as 999, the most
  `hash` has room for. A suffix such as `-beta` still reads as the digits
  before it.
- `haxe.Timer` and `GlobalTimer.setInterval` run at the rate they are asked
  for. CrossByte's `haxe.Timer` counted tick deltas down itself and reset
  to the full interval after each run, dropping whatever the tick had
  overshot by, so every period rounded up to a whole number of ticks: at
  the default twelve ticks a second a 100ms timer ran 12 times in two
  seconds instead of 20. Libraries written against the standard API ran
  slow without knowing it. It also kept every timer in one map under a
  counter that wrapped after 2^32 timers, where a new timer taking a live
  one's id evicted it and it never ran again, and copied every live timer
  into a new array on every tick. A `haxe.Timer` is now a timer on the
  runtime's own scheduler, each run due one interval after the last was
  due; a timer that has fallen behind runs once a frame until it catches
  up rather than in a burst; and it runs on the runtime of the thread that
  made it. `GlobalTimer` skips ids still in use when its own counter wraps.
  The heap scheduler now counts a timer due within a nanosecond of the
  clock as due: two 50ms frames could land a rounding error short of a
  100ms timer, which then waited a frame more.
- A client can no longer forge records in the log. In text mode a message
  or field value was written exactly as given, so a request path carrying
  `%0A`, percent-decoded and logged at INFO, the default level, produced
  a standalone `[ERROR]` line of the client's choosing. Line feeds, carriage
  returns, the Unicode line and paragraph separators and the other control
  characters are now written as escapes, in the message and in field keys
  and values, and a quoted field value escapes its quotes and backslashes
  too. `Logger.timestamps` gave local time to the second with no zone while
  documented as UTC; it is now UTC with milliseconds and a `Z`, worked out
  from the epoch rather than through `Date`.
- A pending `Task` or running `Worker` no longer holds a tick listener of
  its own. Each attached one to its runtime and polled its queue every tick,
  and adding or removing a listener copies the runtime's whole list, so
  submitting a burst of tasks cost time in proportion to the square of its
  size, 8000 pending took 2.3 seconds to submit and 2.2ms of every idle
  tick. Results now reach the runtime through its post queue, one post per
  task and one per batch of a worker's messages, and so arrive without
  waiting for the next tick. `Task.onComplete` and `onError` read a task's
  state and its result together, under the task's lock: read apart, a task
  completing on another thread could be seen as complete with its result
  not yet there, and the handler given null.
- Work handed to a runtime from another thread runs as soon as the runtime
  is free, not at its next tick. A callback posted mid-frame waited out the
  rest of the frame, 38ms on average and up to a whole frame at the
  default twelve ticks a second, and every RPC answer finished on another
  thread, every query result and every task completion paid it, a chain of
  them once per step. A runtime now waits out its frame on a lock that a
  post releases (DEFAULT), or inside a poll that a post ends by writing to a
  loopback wake socket in the poll set (POLL). Measured natively at twelve
  ticks a second, the mean wait fell from 39.7ms to under 0.1ms (DEFAULT)
  and from 37.3ms to 0.1ms (POLL), the worst from 82ms to 0.1ms. It wakes
  once per batch, when the queue goes from empty to not, and an idle
  runtime costs what it did: 0.16% of a core at sixty ticks a second,
  against 0.31% before. `exit()` called from another thread stops the loop
  at once rather than after it has slept out its frame, what was posted
  before a runtime exits still runs, and a post after that is refused
  rather than dropped without a word.
- `CrossByte.make()` no longer takes over the calling thread's timers, and
  a child runtime exits with the runtime that made it. `make()` bound the
  new runtime's timer scheduler to the thread that called it, so once a
  server had started a simulation thread from its INIT handler, a
  `crossbyte.Timer` armed on the main thread, an RPC heartbeat, a
  retransmit clock, ran on the child's thread. Off native the binding was
  one field for the whole process, so whichever runtime ran last owned
  every thread's timers. And once the primordial runtime had exited, the
  process went on waiting for children nothing would ever stop. A child now
  binds its timers on its own thread, the binding is per thread on every
  threaded target, a runtime that exits exits the ones it made, all of
  them, from the primordial one, and a host-driven runtime that exits
  hands its thread's timers back along with the thread.
- `Worker`, `TaskPool` and `Task` run their work on other threads on the
  jvm and the interpreter, as they already did natively. They were written
  for native, hl and neko only, and everywhere else ran the work inline on
  the thread that asked for it: a `TaskPool(4)` given four 200ms jobs held
  its caller for 800ms, `Worker.run()` did the whole job before returning,
  and so `AsyncDatabase`, `URLLoader` and `File`'s async calls stalled the
  loop they exist to keep free. `System.processorCount` also answered 0 off
  native, so `new TaskPool(System.processorCount)` threw. It now asks the
  JVM, Node's list of CPUs or a browser's `hardwareConcurrency`, falls back
  to the environment and `/proc/cpuinfo` on the interpreter, hl and neko,
  and is never below 1.
- `CrossByte.current()` answers the calling thread's own runtime on every
  threaded target, not only natively. On the jvm, the interpreter, hl and
  neko it returned the primordial runtime on every thread, although its
  documentation said it resolved the thread's runtime first: a child
  runtime's thread, or a worker thread, registered its sockets and timers
  with the main runtime and then touched them from the wrong thread, the
  race behind the LocalConnection failures, and `ThreadUtil.isPrimordial`
  was true on every thread. The list of runtimes the process keeps is no
  longer a map keyed by thread, which on the interpreter could never find an
  entry again.
- Every timer due in a frame now fires in that frame. The runtime fired at
  most 256 a frame, about three thousand a second at the default twelve
  ticks, and past that every timer ran late, and later every frame,
  without bound: beside 400 reliable-UDP sessions each keeping a 50ms
  retransmit clock, a 30 second idle timeout fired at 78 seconds. A frame's
  timers are now bounded by time rather than by count. They may use one tick
  interval, so only a burst that would hold the frame past its end, and keep
  the sockets waiting, is spread over the frames after it; the new
  `timerBacklog`, `timerLag` and `timerOverruns` on `CrossByte` say when that
  happens. A timer armed during a pass waits for the next one, so a callback
  that polls by re-arming itself for "now" runs once a frame rather than
  filling the budget. A one-shot timer rescheduled or delayed from its own
  callback now runs at its new time instead of being freed, and a timer that
  pauses itself from its callback can be resumed instead of being destroyed.
- The timing wheel (`TimerStrategy.WHEEL`) fires timers when they are due.
  It placed a timer by the scheduler's clock, which a pass has already moved
  to the end of the frame, instead of by where its cursor was: at sixty
  frames a second `setTimeout(0)` fired after 517ms, a 5ms timer armed from
  a callback fired in the same frame, early, and a 5ms `setInterval` fired
  twice a second instead of 200 times. A timer due at once went into the
  bucket the cursor had just left and waited a whole revolution. Timers are
  now placed from the cursor's own time and never in a bucket already
  walked, a pass stopped partway through a bucket finishes it on the next
  pass instead of leaving the rest a revolution behind, and a timer more
  than 24 days away no longer overflows its tick count and fires at once.
  `new ServerApplication(WHEEL)` ran on the heap, because it built its
  runtime without the strategy it was given; it now uses it.
- An exception from a timer, a tick listener or a socket's handler no
  longer ends the process. The loop had no catch of its own, so one
  handler's bug, a null dereference in one session's idle timeout, one
  malformed message, left it: EXIT was never dispatched, output held for
  the end of the pass was never sent, every other connection went down with
  the one that failed, and a recurring timer that threw was dequeued for
  good while its handle still read as live. On JavaScript the runtime's
  frame chain carried the throw out to the platform, which ended the process
  on Node. Each callback the runtime runs is now contained where it runs. A
  timer is settled as if it had returned, so a recurring one stays armed;
  every tick, INIT and EXIT listener runs whether or not one before it
  threw; a stream socket whose handler threw is closed, dispatching `CLOSE`,
  and the others carry on; held output is flushed past a holder that
  throws; and the loop carries on past anything that fails between
  callbacks, waiting out the frame so a failure that repeats every pass
  cannot spin. A datagram socket is left open, since it is usually the one
  socket a whole UDP service answers on and each datagram arrives whole.
  Every failure is logged with `Logger.error`, with where it was caught and
  its stack where the target keeps one, and dispatched on the runtime as the
  new `UncaughtErrorEvent.UNCAUGHT_ERROR`, to report it elsewhere or to
  decide it is fatal. Callbacks posted to the runtime were already contained
  and are now reported the same way.
- ICE, STUN and TURN read an IPv4 address strictly. Its octets were read
  with `Std.parseInt` and written modulo 256, so a peer's candidate of
  `1.2.3.999` passed as numeric, was dialled through a resolver that took it
  for a name, a blocking lookup on the event loop for every check, and
  had a TURN relay permit 1.2.3.231; `010.1.1.1` was 10.1.1.1 here and
  8.1.1.1 to the socket; and on the jvm an octet past 32 bits threw.
  `IceAgent.addRemoteCandidate` now drops an IPv4 address that is not four
  decimal octets up to 255 without leading zeros; `TurnClient.permit`,
  `bindChannel` and `sendTo` refuse one with `ArgumentError`, keeping
  nothing for `poll` to renew; and an ICE check from an IPv6 address is
  answered without XOR-MAPPED-ADDRESS, which is written for IPv4 alone and
  named 0.0.0.0, teaching the peer a local candidate that does not exist.
- A WebRTC peer that changes network is followed. When the controlling
  peer, a browser whose Wi-Fi went, say, nominated the pair from its new
  address, this end answered and kept the pair it had, sending to an address
  that no longer answered until consent failed 35 seconds later; and a
  candidate trickled after connecting was never paired or checked. Now a
  later nomination switches `IceAgent.selectedPair` (reported by the new
  `onSelectedPairChanged`, with consent restarting on the new pair) and
  `PeerConnection` sends the session there; pairs created or triggered once
  connected are checked at the pacing interval, and not at all when there
  are none; and a peer asking from a pair that failed earlier has that pair
  checked afresh (RFC 8445 section 7.3.1.4).
- An idle WebRTC peer no longer makes native calls every tick. Its DTLS
  session was stepped on every tick, step, pending and available, three
  native calls finding nothing, although nothing in an established session
  runs on a timer: records are read as they arrive and written as they are
  sent. `DtlsTransport.poll` now does nothing once the session is up, and
  `receive` steps it. Measured natively, polling an idle established
  transport went from 47 ns to under 1 ns.
- WebRTC SDP and trickle ICE. An offer listing a second fingerprint under
  another hash was refused, because each `a=fingerprint` line overwrote the
  last and a hash this cannot check wrote nothing; the first sha-256 one is
  now kept. An answer always said `a=mid:0`, which a browser whose offer said
  `a=mid:data` cannot match; `PeerDescription.mid` carries the offer's into
  the answer `PeerConnection.description()` writes. Every document claimed
  `a=end-of-candidates`, telling the peer to stop listening for candidates
  still being gathered; it is now written only when
  `PeerDescription.endOfCandidates` is true, and read back. Trickle ICE was
  the application's to build: `SessionDescription.readCandidate` and
  `writeCandidate` are public (with or without `a=`, `raddr`/`rport`
  included, `0.0.0.0` port 0 for a reflexive one with none given, and a
  second component or an out-of-range priority or port skipped, parsed with
  `IntParse`), `PeerConnection.onLocalCandidate` reports each candidate as it
  is gained, and `PeerConnection.addRemoteCandidate` takes one the peer
  trickled, before or after `connect`, saying whether it was usable.
  `PeerConnection` also has a `userData` slot, as `DataChannel` does.
- A data channel message larger than the peer takes is refused instead of
  vanishing. The SDP promised `a=max-message-size:2097152`, the receive
  window, while the receiver gives up on any message past 1 MB, so a
  message in between had every fragment acknowledged and was then dropped
  whole: the sender saw success and nothing arrived. And the peer's own
  limit was never read, so nothing stopped this end sending past it.
  Descriptions now advertise the 1 MB the receiver takes;
  `SessionDescription.fromSdp` reads the peer's (RFC 8841: 64 KB when the
  attribute is absent, 0 for any size) into the new
  `PeerDescription.maxMessageSize`; `PeerConnection.maxMessageSize` reports
  it; and a channel's `send` or `sendBytes` past it throws `ArgumentError`
  before anything is sent.
- WebRTC peers on different runtimes no longer share an unguarded DTLS
  session table. Every native DTLS session in the process lived in one map,
  named by one counter, and peers on two child runtimes inserted into,
  erased from and searched it at the same time: a lookup landing mid-
  rebalance found a live session gone (a stress test with four threads
  failed three runs in three), and two sessions opened together could be
  given the same handle. The table, the counter and the first seeding of
  the shared RNG are now guarded by a mutex held for the map operation
  alone, which costs about 9 ns per native DTLS call uncontended.
- A WebRTC connection that cannot finish coming up now gives up. Only some
  of its phases had an end: as the DTLS server it waited for a ClientHello
  with no timer running, the SCTP listener waited for an INIT forever, a
  DTLS client took 123 seconds to fail, and consent was checked only once
  everything was up, so a browser tab closed just after ICE left a
  socket, a tick listener and a TLS session held for the life of the
  process, with `ready` pending. `PeerConnection.readyTimeout` (30 seconds
  from `connect`, read at every poll) now fails `ready` with the phase that
  did not finish; consent lost at any point after the path was found ends
  the connection; and a DTLS handshake resends at 1, 2, 4 and 8 seconds and
  fails at 15, with "The DTLS handshake timed out".
- A WebRTC peer can no longer grow the SCTP receiver without bound. Any TSN
  up to 2^31 past the cumulative acknowledgement was taken and remembered,
  so a peer that never sent the next number and kept sending the ones after
  it, as unordered one-byte messages, delivered at once, so the window
  never moved, made the receiver hold 400,000 entries and 24 MB in the
  audit. A TSN more than 16,384 past the cumulative acknowledgement is now
  dropped unread, and with the advertised window shut nothing past the
  highest TSN already received is taken, while one filling a hole below it
  still is (RFC 4960 section 6.2); both are answered with an immediate SACK.
  What has arrived past a hole is kept as runs, which are the SACK's gap
  blocks, so building a SACK no longer probes 511 offsets every time, holes
  or none; a SACK reports at most 128 gap blocks, the lowest first.
- SCTP now answers a peer's HEARTBEAT and completes a peer's SHUTDOWN. Only
  DATA and SACK reached anything: HEARTBEAT ACK was defined and never sent,
  so a peer that probes idle paths, a browser's stack does, counted every
  probe as a failure and could give up on a channel that only received after
  a few minutes, and a graceful SHUTDOWN was ignored until the peer gave up
  and aborted. A HEARTBEAT is now answered at once with its contents copied
  back (RFC 4960 section 8.3). A SHUTDOWN stops new sends, waits for what
  this end still has outstanding to be delivered and acknowledged, is
  answered with SHUTDOWN ACK (resent if lost, given up after eight tries),
  and on SHUTDOWN COMPLETE the association ends and `PeerConnection` closes
  with "The peer shut the association down."
- WebRTC data channels now have congestion control, and no longer flood a
  path. One `send` put everything the peer's window allowed on the wire at
  once, a megabyte was 1,024 packets in one call, and each fragment was
  resent on its own fixed half-second timer, so a slow path got every
  fragment several times before its acknowledgement could arrive, and a
  congested one had most of each burst dropped and resent into the same
  queue: through a bottleneck taking 64 packets at a time a megabyte never
  arrived. SCTP now keeps a congestion window (RFC 4960 section 7): ten
  packets to start, doubling each round trip while everything arrives,
  halved when three SACKs report a fragment missing, which is then sent
  again at once rather than after a timeout, and down to one packet when
  a timeout runs out. The timeout is measured from round trips (RFC 6298),
  between 0.4 and 10 seconds, and doubles on each expiry. No more than four
  packets leave at any one opportunity (Max.Burst), small messages waiting
  together share a packet, and a SACK is sent for every second packet of
  data, or at once on a gap or a duplicate, rather than once a tick. The
  association ends after ten timeouts in a row with nothing acknowledged.
  A SACK is now read in one pass: 4,000 gap blocks over 8,192 outstanding
  fragments cost 60 ms. Measured natively, a 100-byte message round trip
  went from 2.25 to 1.86 us, a 1 KB one from 4.05 to 2.99 us, and an idle
  transfer's poll from 18 to 4 ns.
- A data channel fragment the peer never acknowledges ends the SCTP
  association instead of wedging it. After its tenth attempt the fragment
  was dropped with nothing sent to say so, which left an ordered stream a
  hole no retransmission would fill: everything after it on that stream
  stalled for good, later fragments were resent up to eleven times, and
  the association went on reporting itself open. Past the limit the peer
  is unreachable, as RFC 4960 section 8.1 has it, so the association now
  ends with an ABORT, and `PeerConnection` closes with a reason through
  `onClose` and `closed`.
- A WebRTC peer that goes away is reported, and closing tells the peer.
  `PeerConnection` had no close event: a peer's SCTP ABORT closed the
  association below it without a word, a DTLS close_notify or fatal alert
  was never read, and the one thing that noticed was ICE consent, thirty
  seconds later, without an event either, so channels on a connection
  the peer had closed went on reporting `open`, and the first sign was a
  `send` that threw. `close()` sent nothing, so a browser's channels stayed
  open until its own consent ran out, and it left this end's channels open
  with `onClose` never run. `PeerConnection` now has `onClose(reason)`, a
  `closed` future and `closeReason`, fed by an ABORT, a close_notify or
  fatal alert, lost consent, the loss of the relay a path ran through, and
  `close()` itself. Every channel is closed first and reports `onClose`,
  and one still waiting for its acknowledgement settles `opened`.
  `close()` sends the peer an ABORT and then a close_notify; a path whose
  consent expired, or whose relay went, is closed without them. An ABORT
  is now accepted only with this association's tag, or the peer's with the
  T bit set, and a reason the peer gives is passed on.
  `DtlsTransport.onClose`, `DtlsTransport.close(notifyPeer)` and
  `TurnClient.onLost` are the pieces underneath.
- A `NetConnection` over a WebSocket tells `onClose` how its peer closed:
  `Reason.Code` with the close frame's code and reason. It said
  `Reason.Closed` whatever the peer sent, so a server going away (1001)
  and one refusing a client by policy (1008) were one close to the
  application, and to an RPC call that failed because of it, whose
  `cause` is now that `Reason` too. `Reason.Closed` is what a close with
  no code known reports.
- A `LocalConnection` whose peer stops reading no longer stops its own
  side. `send` wrote on the runtime's thread until everything had gone,
  five seconds a send on Windows, for good on Linux and macOS, holding
  the lock its own reader needed, so two processes filling each other's
  channels each waited on the other; it waited where the collector could
  not reach it, so a frame larger than the channel stalled any thread
  that collected meanwhile, the peer's reader among them, until the write
  gave up; and a write that gave up part way through a frame left the
  peer reading from its middle. `send` now writes what the channel takes
  and queues the rest, which the reader thread writes as the peer reads,
  each frame whole. A peer that leaves more than `maxQueuedBytes` unread
  is taken to be stuck: the connection is closed, with an error saying so
  that is its close reason too. On Linux a send to a peer that had gone
  raised SIGPIPE, which ends the process; it is sent with `MSG_NOSIGNAL`
  (`SO_NOSIGPIPE` on macOS), and the connection closes instead.
- A second `listen()` on a `LocalConnection` name in use throws, on both
  platforms, where Windows made a second instance of the pipe beside the
  first and POSIX removed the first listener's socket file and bound its
  own: either way the first listener's clients went to the second. On
  POSIX a name's socket path turned everything but letters, digits, `-`
  and `_` into `_` and was cut to 48 characters, so `a.b` and `a_b`, or
  two long names alike for their first 48, were one channel; such a name
  is now kept apart by a 64-bit hash of all of it, and a name that needed
  neither keeps its path. A listener lets each client go and takes the
  next with the name held throughout, where it closed and made its
  endpoint again with the name anyone's in between. On Windows a client
  that came and went before the listener next looked, as a
  `SharedChannel` switching destinations did, left the pipe closing,
  which was taken for nobody yet, and the listener took nobody again: it
  is taken like any other, and what it wrote is delivered.
- A `NodeChannel` whose peer drops it comes back whatever clock it is
  polled with. `poll(now)` compared its caller's time with retries
  scheduled on `haxe.Timer.stamp()`; polled with the runtime's uptime, as
  `crossbyte.Timer.stamp()` gives it, it was always early on Linux native,
  jvm and eval, where the two clocks are far apart, and a link that
  dropped once never came back. It worked on Windows and Node only because
  both clocks start near zero there. `poll` now reads the clock itself;
  `now` is optional and not read.
- `SnowflakeId.timestampOf` reads back when any identifier was minted. It
  converted the forty one bits of milliseconds through an `Int`, which
  holds thirty one, and threw `Overflow` for every identifier minted more
  than 24.8 days after the epoch, after 2020-01-25 for the default one.
- An RPC call that fails because its connection ended has the `Reason` it
  ended with as its `cause`, `Timeout` for a heartbeat that gave up, so
  a caller, a gateway above all, can tell a peer gone from a peer refusing,
  whose failure has an `RPCError`. It had a message and nothing else.
- A `LocalConnection` tells `onReady` at the next tick after `connect()`,
  not from inside it. `new NetConnection("local://...")` connects as it is
  made, so an `onReady` set once it had returned, as the RPC guide sets
  one, never ran.
- A `Future`'s `RESULT` or `ERROR` listener that throws is contained, as a
  `then` callback that throws already was: logged, and nothing else
  affected. It escaped into whatever completed the future. For an
  `RPCResponse` that was the session reading its connection, which took
  the throw for a frame it could not read, closed the connection and
  failed every call still waiting, and failing those ran their
  listeners too, so one that threw escaped out of the read altogether.
- An RPC session on a listening `LocalConnection` answers every client it
  takes, not just the first. The listener takes its next client on the
  same object, and the session stayed ended once the first had gone: for
  each client after it, every error answer and every answer given later
  was dropped, a second worker's refused call never heard it was
  refused, and the heartbeat stayed off. A session is now answered on
  again when its connection becomes ready again, and a heartbeat started
  with `start()` resumes. A call from the last client still waiting then
  answers nobody: it is kept to the life of the connection it came in on,
  so the next client, numbering its calls from 1 too, cannot be handed its
  answer.
- An RPC call that cannot go fails as it is made, and nothing is left
  waiting on an answer that cannot come. A request made after its
  connection had ended waited for good over local IPC, whose send reports
  a closed connection to `onError` rather than throwing; over TCP the send
  threw out of the call and left its response waiting. It now fails at
  once, with the `Reason` the connection ended with as its `cause`; a
  request whose send throws fails with what it threw; and a one-way call
  on an ended connection is dropped. Commands with no session
  dereferenced a null connection, a crash on hxcpp in release; a request
  through them now fails with an `IllegalOperationError`, and a one-way
  call throws one. A call whose arguments cannot be framed throws before
  it waits, where it was left waiting under its id. An answer for a
  connection its own handler has closed is dropped rather than reported
  as the handler failing. And an application's own `INetConnection`,
  wrapped as a `NetConnection` again after a session was made on it,
  `(connection : NetConnection).onClose = ...`: set its callback over
  the session's hold on it, so the session never heard it end and its
  calls waited for good; while a session observes such a connection,
  wrapping it again gives the same `NetConnection`.
- An RPC call the other side cannot take no longer ends the connection or
  leaves its caller waiting. A runtime call to a session with no runtime
  handlers ended that session's connection, the reader for a compiled
  handler took the frame for garbage, where the guide promised an error
  answer; it is now answered as the runtime lane answers. A compiled
  request to a session with no handler was dropped, and its caller waited
  on a connection that stayed up; it is now answered
  `RPCError.NO_HANDLER_MESSAGE`. A frame over the 8 MiB limit went out
  without complaint and ended the connection on the other side, failing
  every call waiting on it; a request over it now fails at once with an
  `ArgumentError`, a one-way call throws one, and an answer over it is
  not sent, its caller is answered `RPCError.INTERNAL_MESSAGE` and
  `onHandlerError` is told. The limit is `RPCSession.maxFrameLength`,
  which each session reads and sends by, where it was a constant. A
  session now reads every frame in one place whatever it has bound; a
  frame whose flags are neither a call nor an answer, which was taken for
  a one-way call, now ends the connection as any unreadable frame does.
- The RPC heartbeat keeps healthy connections and drops dead ones. Pings
  were one-way and nobody answered them, so a client heartbeating a server
  that only answers calls heard nothing between calls and closed a healthy
  connection after 90 to 135 seconds. Every session now answers a ping with
  a pong, a response under request id 0, which answers no call, so an
  earlier version passes over it. A peer that never sent a byte was compared
  against a deadline that moved with the clock and was never timed out;
  what the heartbeat has heard is now counted from when it started. It ran
  only on a session with commands, so a server never dropped a client that
  had vanished; it now runs on any session. `start()` before the connection
  was up never started it, and it now starts once the connection is ready.
  `start()` twice ran two heartbeats, one of which outlived `stop()` and,
  once the connection closed, threw out of the tick; it now carries on as
  it was. A timeout reported the close twice, `Closed` and then `Timeout`;
  the calls waiting now fail saying the connection timed out, and
  `close()` alone reports the end. It also logged five lines at INFO for
  every session on every beat, and logs nothing now.
- An RPC method returning `Null<T>`, in a contract, with `@:rpc`, through
  a typedef, or as `Future<Null<T>>`, answers what its caller reads. The
  caller reads a byte saying whether the answer is there before the
  answer, as for an optional argument, and the handler wrote the answer
  bare: its first byte was taken for that flag, the rest misread, and the
  connection closed on the first answer that was not null, failing every
  other call waiting on it. A null `String` could not be written at all on
  eval and JavaScript, and went as "" on cpp. Both sides now decide
  whether a type may be absent from the type itself, not from how it is
  written, so a typedef of `Null<T>` reads and writes the flag too.
- One RPC handler can serve many sessions, and answers each call on the
  connection it came in on. A handler held the session it was given last,
  so a server that gave one handler to every client, as the guide's
  `ChatHandler` and `MatchQueueHandler` invite, sent every answer to its
  newest client. Since each client numbers its calls from 1, that client's
  own call with the same number was completed with it: Bob, asking for a
  `String`, was answered with Alice's `Int`, and Alice waited for good. A
  session now binds its handler while it dispatches to it, a field
  write per delivery, put back after, so a call one session sets off in
  another over an in-memory connection leaves the handler as it found it,
  and a method answering later, with a `Future`, is answered on the
  session it was called from, which the handler keeps from the call. The
  guide's four players queued on one handler were all answered by the
  fourth's connection, three of them never. A response is now checked
  against its call's op as well as its id: one for another op fails the
  call, on both lanes, rather than completing it with a value of another
  type. `RPCHandler.session` is the session whose call is running, `null`
  between calls, so a handler can tell its callers apart, `session.data`,
  `session.commands`. `session` joins `ping` and `dispatch` as a name a
  contract cannot use. The guide now gives one `ChatHandler` to every
  client, and says how one handler serves many.
- A port in a URL that is too big for an `Int` is refused the same way on
  every target, as any port past 65535 is. `parseURL` and a WebSocket URL
  read it with `Std.parseInt`, which answers such a number differently on
  each: on Linux native its low 32 bits, so `tcp://host:4294967296` was port
  0; on Windows the largest `Int`; on eval nothing, so a WebSocket took its
  default port; on the jvm a `NumberFormatException` instead of the parse
  error the caller was told to expect.
- A `ServerSocket` that cannot take a waiting connection, the process
  out of descriptors, says so, once for a run of failures, as an
  `ioError`, and goes on listening. Natively the failure was swallowed,
  so a server out of descriptors looked idle; on the jvm it closed the
  server.
- Removing one `connect` listener from a `ServerSocket` no longer stops it
  accepting while others are still listening.
- A `DatagramSocket` reads everything waiting, up to 1,024 datagrams, each
  time it is found readable. It read 64, and it is asked once a pass, so it
  could take in 3,840 datagrams a second at 60 passes whatever was
  arriving. Each datagram also cost a system call for the socket's own
  address and a formatted copy of the sender's; both are now kept. Reading
  2,000 waiting datagrams over loopback took 2.9 us each and 32 passes; it
  takes 1.7 us and 2. On the jvm every read also allocated, and zeroed, a
  64 KB buffer to receive into and copy out of; it now receives straight
  into the socket's own, and a datagram takes 1.7 us to read there rather
  than 3.7.
- Writing to a `Socket` before its connect has finished is no longer an
  error natively: the bytes wait and go once it has. The flush wrote to the
  socket anyway, which Windows refuses, so it threw, and the tick reported
  the same refusal as an `ioError` on every tick until the connect
  finished.
- A backlog drains in time proportional to its size. Every write the
  socket took only part of copied everything still waiting into a new
  buffer, the output side of the fix the input side already had, so
  draining a backlog cost a copy of it per write, and a TLS socket makes
  one every 16 KB record: through a socket taking 16 KB a write and 64 KB
  a pass, flushing a 16 MB backlog spent 2,395 ms copying, 4 MB 144 ms.
  What has gone is now stepped over, and the buffer compacted only when
  that is at least what remains: 1.5 ms and 0.3 ms. A flush also writes
  until the socket takes no more, where it wrote once, so a TLS socket
  sent one record a pass whatever room the kernel had: the 16 MB went in
  256 passes rather than 1,024. `Socket` and WebSocket sessions both, and
  a WebSocket frame with nothing queued ahead of it goes to the socket
  without first being copied into the queue.
- On Node a WebSocket session counts what Node has queued for it. Its
  `outputBufferLength` read 0 however much was waiting, so
  `ServerWebSocket.drain()` waited on nothing, and `maxOutputBufferSize`
  was checked after a return that path always took: a session to a peer
  that had stopped reading grew without bound. It now closes with 1011 at
  the limit, as it does natively.
- `DatagramSocket.send()` is a fifth quicker natively: 5.3 us a datagram
  where it took 6.9, to one destination over loopback. Every send asked
  the system for the socket's local address, to learn whether it was bound
  yet, and built a `Host` and an `Address` for its destination; it now asks
  until the socket is bound, and keeps the last destination's address.
- On Node an open connection is no longer visited every tick. Each Node
  socket was ticked for as long as it was open, to flush whatever had been
  written: 400 idle sockets cost a pump 3.4 us, and the cost grew with
  every connection held. A write now asks for a flush at the end of the
  pass, sooner than the next tick, and a socket is ticked only while a
  streaming response is feeding it: the same pump costs 0.3 us, with no
  tick listeners.
- A connection's end is announced once, and the same way everywhere.
  Natively a peer that connected and hung up within a tick, a load
  balancer's health check, was announced closed twice, a tick after the
  first time, so an `onDisconnect` ran twice and a live-connection count
  drifted down by one per check. On Node a peer that left left its socket
  connected and flushed from every tick for good: 200 tick listeners after
  200 HTTP clients had come and gone. The socket is now released when Node
  closes it, as a native one is. And Node sockets are half-open, so a
  peer's FIN is decided by `peerShutdownPolicy` as it is natively: under
  `HALF_OPEN` the socket stays writable and dispatches `PEER_CLOSE`, where
  Node ended its own side at once and a peer that half-closed to finish its
  request never got the answer. Under `CLOSE`, as before, it is closed.
- On Node, a socket listener that throws costs its own connection, not the
  process. A socket's events arrive from Node's event loop rather than from
  anything of CrossByte's, so an exception from a listener, a data handler
  meeting a message it could not parse, went to Node, which exited: every
  other client went with the one that sent it. Now it is logged at ERROR
  and that connection closed: a `Socket` closed, a WebSocket session closed
  with 1011, a connection whose `connect` listener threw on a `ServerSocket`
  closed. A `DatagramSocket` is left open, since one socket carries every
  peer, and the next datagram is delivered as usual.
- WebSocket sessions are read when there is something to read, not on every
  tick. Each open session added a tick listener of its own and made a
  receive every tick whether or not anything had arrived, on hxcpp one
  that raised an exception to say nothing had, so ten thousand idle
  sessions cost over a hundred thousand system calls a second. They now sit
  in the runtime's socket registry, read when their socket is readable and
  retried when a write is waiting, and an idle one costs nothing. A session
  a server accepted reports its peer's address and port, and its own, where
  it reported none; an upgrade the server cannot accept is answered with a
  status rather than a dropped connection; and what a session has read past
  is let go once there is enough of it, rather than kept until a read ends
  exactly on a frame.
- A reliable datagram peer that crashes and comes back on the same address
  and port gets back in. Its old session on the server took every CONNECT
  the new one sent, answered none, and was kept alive by them, so the peer
  was locked out for as long as it kept trying: 29 attempts over 173
  seconds, in the case that found it. A CONNECT now carries an id for its
  attempt, in a field older builds never read; one with a new id, from the
  address of a session already held, has the server ask the old peer
  whether it is still there, and the next CONNECT to find no answer replaces
  the session, about three seconds on. A peer still there answers, so a
  CONNECT sent in its name cannot take its session. A HANDSHAKE echoes the
  id it answers, so a new attempt ignores one meant for its predecessor.
  `ReliableDatagramServerSocket.close()` sends each session's peer a FIN,
  where it sent nothing and every client went on sending into a closed port;
  and a server answers a peer that sends as though it had a session and has
  none, the server restarted, or gave it up, with a FIN, ending that
  session at once rather than at the peer's own timeout. On Node, closing a
  `DatagramSocket` waits for its sends to finish, since Node sends a turn
  later and closing cancelled them: the FIN a closing session sends last
  never left.
- In a browser, a `Socket` sends each write once. It sent its buffer and
  never cleared it, and the tick flushes every pass, so one write went out
  again on every tick for as long as the connection lasted: an 11-byte write
  reached the server as 25 messages in two seconds. A write made while the
  page's WebSocket is still connecting waits for it to open, where it threw
  out of the tick. A connection the server closes is cleaned up, it stayed
  connected and flushed from every tick, and announces CLOSE once, or an
  ioError alone if it never opened. `outputBufferLength` counts what the
  page's WebSocket has queued. The browser suite now runs a page's `Socket`
  against an echo endpoint `ci/browser/run.js` serves beside it.
- On Node, a socket written to faster than its peer reads sends what was
  written. A flush handed Node a view over the socket's output buffer and
  then cleared the buffer for reuse, so the next write landed on bytes Node
  still had queued: ten 1 MB messages to a paused client arrived as the
  first five and then 5 MB of the last, and a 12 MB file from `HTTPServer`
  reached a slow download with 786,432 bytes wrong. Each flush now copies.
  `outputBufferLength` and `bytesPending` count what Node has queued, which
  is where the backlog is there, so `maxOutputBufferSize` is reached on Node,
  it never was, and a peer closed for passing it has its queue dropped
  rather than flushed. The HTTP server's streaming watermark, which reads
  the same figure, now holds a download to a slow client on Node too.
- A WebSocket session whose TLS handshake fails, or whose connect times
  out, closes its socket. Only a session that had opened was closed, so a
  server held the descriptor of every connection that failed its handshake,
  and its peer waited on it, for as long as the process ran. A client
  now reports why a connection failed, a refused certificate included, as
  an `IOErrorEvent` with the reason in its text, where it dispatched a bare
  event of that type with none; a connect that fails at once is reported
  rather than waited out; and the answer to its upgrade is waited for no
  longer than `timeout`, where a server that accepted and never answered
  held it in CONNECTING for good. On jvm a WebSocket client could not be
  made at all: it set a byte order on an output the socket does not have
  until it connects. And a jvm TLS client made non-blocking no longer
  completes its handshake inside `connect()`, which held the runtime's
  thread and, against a server on the same runtime, waited twenty seconds
  for an answer its own wait was preventing.
- Counting a response in `HTTPServer`'s metrics no longer looks its status
  class's counter up in the registry each time, a label map built, sorted
  into a key, and the registry's lock taken on top of the counter's own. The
  counter is looked up once and kept: 820 ns a response became 230 ns
  natively, the rest being the counter's own lock, and about 195 ns became
  2 on Node.
- An HTTP/2 request that has fully arrived is no longer held to
  `requestTimeout`. Every open stream counted as a request still arriving,
  so a long poll answered after `requestTimeout` found its connection
  closed with a GOAWAY, and every other stream on it gone too. As over
  HTTP/1.1, the clock stops once the request is in, and a connection's idle
  time counts from the last frame either way.
- A response body too large for the connection's output buffer is sent
  whole. It was written at once: what the peer had not taken by the first
  flush stayed buffered, the socket closed at `maxOutputBufferSize`, and a
  12 MB `respond()` went out as a `200` with its full `Content-Length` and
  part of its body, logged and counted as a success. Such a body now goes
  out as a large file does, in bursts on the socket's drain, and the
  connection is kept alive after it.
- A PHP script is given every request header as `HTTP_*`, and the client
  every response header the script sets. The bridge passed on eight request
  headers and brought back three, `Cache-Control`, `Location` and
  `Set-Cookie`: so behind it a script never saw `Origin`,
  `X-Requested-With`, a CSRF token, a conditional request, `Range` or what a
  proxy forwarded, and a client never got `ETag`, `Content-Disposition`,
  `WWW-Authenticate`, `Vary`, `Access-Control-*` or a script's own fields.
  Left out on the way in: the connection's own fields, `Content-Type` and
  `Content-Length` (CGI has variables for them), `Proxy` (httpoxy), and any
  name with an underscore, which would pass for its hyphenated twin. On the
  way out: the CGI status, the framing, and what the server always writes,
  `access-control-*` too when the server's own CORS is on. A body that
  arrives already encoded, a script's under `zlib.output_compression`, or
  a route's that names its `Content-Encoding`, is no longer encoded again.
- On a cleartext listener with `http2Enabled`, something thrown while
  serving a connection's first HTTP/1.1 request is answered `500`, as on
  any later request. The server reads those first bytes itself to tell the
  versions apart, and the handler it passed them to parsed them outside its
  usual catch, so the throw went up through the socket's dispatch into the
  runtime's pump.
- The server answers `500` for a file past 2 GB over HTTP/2 as well as
  HTTP/1.1. `File.size` throws for such a file, since an Int cannot state
  its length, and the static path did not catch it: HTTP/1.1 answered `500`
  through its catch-all and HTTP/2 reset the stream. The server's own check,
  an open, seek and read of every file it served, is gone with it.
- On eval, the HTTP/1.1 client returns when a server closes without
  answering, or ends a chunked body before its size line: an error, where
  `load()` never returned. A socket's `readByte` answers 0 there at the end
  of the stream instead of throwing, so the client read endless NUL bytes
  into a line that never ended. A connection closing before the headers end
  is now reported as that, rather than as a failure to read.
- The HTTP/1.1 client's idle timeout is in milliseconds, as
  `URLRequest.idleTimeout` says. The socket was handed the milliseconds as
  seconds, so the default 30 second timeout waited 30,000 seconds, and a
  server that never answered held the request for over eight hours. On the
  jvm no socket read times out at all yet; that is `sys.net.Socket`'s.
- `URLLoader.close()` with a request in flight no longer crashes a native
  build with an access violation. The worker thread reported through the
  loader's own worker field, which `close()` clears, so its next report,
  the error from the read `close()` had just ended, was a call on null.
  The URL tests now run in the native suite, where the loader's worker is a
  thread; they had not run natively at all.
- `RateLimiter` holds at most `maxKeys` keys, a new constructor argument,
  100,000 by default, and forgets idle ones without a sweep. Keys are
  whatever a client sends, account names, addresses, and every one was
  kept, with a sweep of the lot run inside whichever `tryAcquire` found it
  due: two million keys held 294 MB on Node, 270 MB on the jvm and 375 MB
  natively, and that one call took 815 ms, 133 ms and 335 ms. Now buckets
  live in two generations and an idle generation is dropped whole, in one
  assignment: that same call takes 0.1 ms on Node, and the flood holds 8 to
  13 MB. Past the cap, new keys share one bucket, so a flood of them is
  limited as one client while the keys already held keep their own. A call
  also costs less natively, 25 ns rather than 45, and `activeKeyCount()` no
  longer walks the table.
- `URLLoader` dispatches `HTTPStatusEvent.HTTP_RESPONSE_STATUS` on every
  target, with the final response's `responseHeaders`, the `responseURL` it
  came from and whether it was `redirected`; it never dispatched it, so
  `Retry-After`, `ETag` and `Location` could not be read. And the transports
  now report one exchange the same way. A 4xx or 5xx is an `IO_ERROR`
  carrying its body over HTTP/2, on Node and in the browser, as it was on
  native HTTP/1.1, where it had completed; Node follows redirects, with the
  native client's rules for credentials and `https` to `http`, where it
  completed with the 3xx; the browser's `idleTimeout` is time without
  progress, as elsewhere, rather than a deadline on the whole exchange; and
  an HTTP/2 response is content-decoded within the client's limits, where a
  gzip body arrived compressed. HTTP/2 still does not follow redirects; the
  3xx completes, and its `Location` is now readable.
- `URLLoader` sends a `URLVariables` as a form on every target: in the query
  of a GET or HEAD, and otherwise as an `application/x-www-form-urlencoded`
  body. At run time one is the map beneath it, so the native client read the
  map's own fields and sent an empty body, and Node and the browser sent a
  debug dump of the map. On Node a body is also sent with its
  `Content-Length` whatever the method: Node frames a body only for methods
  it expects one on, so a body on a DELETE, GET or OPTIONS went out bare, the
  server read it as the next request, and the next call on the pooled socket
  got a `400`.
- With `http2Enabled` on cleartext, a connection that has not yet sent a
  request is counted, timed and drained. While the server waited to see
  which protocol it spoke, it escaped all three: with `maxConnections` at 2
  and `requestTimeout` at half a second, six silent sockets were all taken
  and still open after `drain()`. They now count against the limit, close
  at `requestTimeout`, and close when a drain starts. `drain()` also closes
  at once an HTTP/1.1 connection that has never sent a byte, a browser's
  preconnect held a drain for its whole timeout, and sends HTTP/2 clients a
  GOAWAY when the drain starts rather than at its deadline: streams opened
  after it are refused, those in flight finish, and each connection closes
  with its last stream. An HTTP/2 response with no body, a 204, a 304, any
  HEAD, no longer keeps its stream's concurrency slot, which after 128 of
  them left a connection refusing every stream; and a stream refused for the
  concurrency limit no longer skips its header block, which left the HPACK
  table out of step with the client's for every block after.
- HTTP/2 requests go through what HTTP/1.1 requests go through. Only the
  HTTP/1.1 parser asked the rate limiter, so six requests over HTTP/2 were
  all answered where HTTP/1.1 refused the fourth. DATA was appended with no
  limit while window kept being granted, so one stream could make the server
  hold as much as it sent: a 3 MB upload reached a route HTTP/1.1 refused.
  Now a body past the limit is answered `413` at once, the stream is reset
  without error so the client stops sending, its window is not topped up
  again, and the connection carries on. HTTP/2 responses are counted and
  timed in `metrics`, and HTTP/2 connections in the output-buffer gauges; a
  gzip body is decoded before middleware sees it, as over HTTP/1.1; and
  cookies a browser sends as separate fields are joined with `"; "`, as RFC
  9113 8.2.3 has it, where a comma made `getCookie("sid")` answer
  `abc123, theme=dark`.
- A peer no longer decides how much memory the server or the `URLLoader`
  client spends on a body. The server inflated a request body with no
  ceiling, while its limit counted the compressed bytes on the wire, so a
  32 KB gzip body became 32 MB at the route; it now stops decoding at the
  same limit and answers `413`, and refuses more than two stacked content
  codings with `415`, as the client already did for responses. The client
  allocated a whole body from its `Content-Length` before a byte arrived, so
  one header of 2000000000 cost two gigabytes; a declared length past the
  new `Http.MAX_BODY_SIZE` (64 MB) is now refused before anything is
  allocated, and a body framed by the connection closing is held to the same
  bound. Such a body cut off by a reset was reported complete with part of
  its content; only the connection's clean end completes it now.
- CORS no longer grants every site a signed-in user's data. With
  `corsAllowCredentials` on and `corsAllowedOrigins` left at its default of
  `["*"]`, the server echoed whatever `Origin` arrived with
  `Access-Control-Allow-Credentials: true`, so any page could read `/me` with
  the user's cookies. `validate()` now refuses credentials with `"*"`; name
  the origins instead. `"*"` is always answered as `*`, and
  `Allow-Credentials` goes only beside an origin that was named. A preflight
  is answered with `corsAllowedMethods` and `corsAllowedHeaders` rather than
  by echoing what it asked for, which approved any method and header; a
  page sending `Authorization` or a custom header now needs it listed.
- A conditional request dated after January 2038 is answered `304` on
  native builds. The server compared seconds with `Math.floor`, which
  returns an `Int`, and seconds since 1970 no longer fit one then: on hxcpp
  the cast wrapped, a `If-Modified-Since` in 2100 compared as long ago, and
  the whole file went out again with a `200`.
- `URLLoader` no longer hands a caller's credentials to whatever host a
  redirect names. Every hop was written with every header the caller set,
  so a `302` to another origin received `Authorization: Bearer ...`. Once a
  redirect leaves the origin the request started at, `Authorization`,
  `Proxy-Authorization` and a `Cookie` set in `requestHeaders` are dropped
  for the rest of the exchange, as browsers, curl and Go drop them; cookies
  the client manages already went only to the host that set them. A
  redirect from `https` to `http` is refused unless
  `URLRequest.followInsecureRedirects` is set, and one to any scheme but
  those two is refused, where a malformed `Location` used to throw out of
  the request. Ten redirects ending in a response are no longer reported
  as too many. A caller's header line is written through the same
  sanitiser as the server's, so a CR or LF in a value, one forwarded from
  a client, say, can no longer add a header or a request of its own.
- A middleware guard sees the path the server would serve. The request
  path was only percent-decoded for middleware, while the static resolver
  collapsed slashes and applied `.` and `..` on its own, so a guard refusing
  `/private/` let `//private/report.txt` and `/./private/report.txt` through
  and the file was served for both; on Windows and macOS `/PRIVATE/report.txt`
  went the same way, and on Windows so did a trailing dot and an 8.3 short
  name, `/ENV~1` served `.env`. `requestPath` is now settled once, before
  middleware, over HTTP/1.1 and HTTP/2 alike: repeated slashes collapsed,
  dot steps applied, a backslash read as `/`, and a path climbing above the
  root answered `400`. On Windows and macOS a file is served only under the
  spelling its directory lists, as on Linux. A `..` inside a name is part of
  it: any `..` used to throw before the router ran, so
  `/api/compare/v1.2..v1.3` answered 500. Files and rewrites are resolved only
  once the middleware chain lets a request through, so a request a route
  answers never touches the filesystem, where it paid three lookups and a
  regular expression compile: natively on Windows, a routed request went from
  79 to 31 microseconds end to end, and a static file from 265 to 200.
- The HTTP server and clients read every other number a peer sends the same
  way on every target, through `IntParse`: a byte range, a chunk size, the
  port in a `Host` header or a URL, a cookie's `Max-Age`, a response's status
  and, on Node, its length. `Std.parseInt` answers four ways past an `Int`, so
  on Linux native `Range: bytes=4294967296-` was a range from byte 0, a
  `Max-Age=4294967296` deleted a cookie meant to last a century, and an
  HTTP/2 `:status` of 4294967496 was a 200; on the jvm the last two threw out
  of the whole request. A status is now exactly three digits, a range number
  past an `Int` reaches past any file, and a `Host` of `[::1]:8080` is no
  longer named `[`. Ranges, chunk sizes, status lines, URL ports and
  `If-Modified-Since` dates are read by hand rather than by a regular
  expression compiled on every call.
- A request can no longer be smuggled inside another through a
  `Content-Length` too large for an `Int`. The server checked the field was
  all digits and then trusted `Std.parseInt`, which on Linux and macOS
  native is `strtol` cast to an `int`: 4294967296 read as 0 and 4294967396
  as 100. At 0 the server read no body and parsed the body as the next
  request, so a request carried inside another reached the application
  unseen by a proxy or firewall that inspected the outer one. On the jvm the
  same field threw, answered 500 and logged an ERROR per request. The server
  and the `URLLoader` client now read it through `IntParse`, so a length no
  `Int` holds is refused, `400` on the server, an error on the client,
  which had read it as an empty body, and an HTTP/2 request whose
  `content-length` differs from the DATA it carried is reset as malformed,
  as RFC 9113 8.1.1 requires, rather than handed to the application with a
  length its body does not have.
- An HTTP/2 request cancelled before its response arrived no longer
  completes. `cancel()` reset the stream and woke the request, but the
  stream stayed in the connection's map, so a response arriving after the
  cancel was still written into it, status, headers and body, and a
  request that read its stream after that reported the response through
  `onComplete`, with a full body or an empty one depending on how much had
  landed. The suite saw it once, on jvm. Looped, the case failed about once
  in a thousand runs there under load, and 12 times in 3000 on cpp, where
  the suite had never caught it. Frames for a stream already closed on this
  side are now discarded, as RFC 9113 5.1 requires, with HPACK and
  flow-control state still advanced. The cancel handler is now registered
  before the request lets go of the session's lock. Registered after it, a
  cancel landing just as the request went out had nothing to run, and was
  applied only once the response had completed the stream. A request
  cancelled after its response headers but before the end of its body
  reports "Request cancelled" rather than completing with the part that
  had arrived. Resetting a stream that has already ended no longer sends
  RST_STREAM on a closed stream.
- An HTTP/2 response cut short after its headers is an error, not a
  response. When the server reset the stream, or the connection closed,
  between the headers and the end of the body, the request completed
  through `onComplete` with whatever part of the body had arrived: the
  errors for those cases were given only when the status had not arrived
  either. A stream that never saw END_STREAM now never completes. A reset
  reports "Stream reset by peer: CODE" as before, a connection lost before
  the headers "Connection closed before the response headers arrived" as
  before, and one lost after them "Connection closed before the response
  body completed".
- A pooled HTTP/2 client connection no longer keeps every stream it has
  carried. `H2Connection` never took a stream out of its map, so a
  connection in use grew by one stream and its response headers per
  request for as long as it stayed open, and every SETTINGS from the
  server walked all of them. A stream is now forgotten as it closes. A frame
  arriving for it later is discarded as one for an unknown stream, with
  its header block still decoded and its DATA still counted against the
  connection's window. A GOAWAY that refuses several streams closes them
  after walking the map, not during.
- An HTTP/2 upload the server ends early no longer stalls and takes the
  connection with it. RFC 9113 8.1 lets a server answer, or reset the
  stream, before it has read the whole request body. A body larger than
  the send window was then left waiting for a WINDOW_UPDATE that a closed
  stream never gets. After thirty quiet seconds it failed the connection
  with a FLOW_CONTROL_ERROR, and every other request on it with it, and
  reported that instead of the server's answer. Had it got past that, the
  stream was marked open again, and the caller would have waited out its
  timeout. The upload now stops as soon as the stream ends. The request
  returns the response when the server finished one, sending
  RST_STREAM(CANCEL) so the server's half is released too, and "Stream
  reset by peer: CODE" when it reset instead. The connection stays in the
  pool for other requests.
- An HTTP/2 request can be timed out and cancelled while its body is
  still going out. Its timeout started only once the whole body had been
  sent, and its cancel handler was registered only then. A body waiting on
  a flow-control window counted any frame on the connection as progress.
  So an upload the server had stopped taking waited as long as the
  connection was busy, 36 s for a 1.5 s timeout in the test, and on a
  quiet connection gave up after thirty seconds by failing the connection
  and every request on it. A cancel did nothing until then. The timeout now
  also bounds how long a body's window may stay shut, so an upload that is
  slow but moving is not cut off. The cancel handler is registered before
  the body is sent. Either one resets only that stream, and a cancel wakes
  its body at once. Each body waiting on a window is now woken by every
  frame, where one shared wake-up used to reach only one of them. A
  timeout, during the body or while waiting for the response, is now an
  error in that stream only: it reports "Request to ORIGIN timed out after
  Ns" without the "HTTP/2 connection error: " prefix, and leaves the
  connection pooled. It used to close the connection, failing every other
  request on it; a peer that has gone silent is now found when the
  connection itself fails, not by the first timeout.
- On JavaScript, the runtime lane's RPC request ids overflowed as the
  compiled lane's did before the `RPCCommands.__nextRequestId` fix below:
  an `Int` there is a double, so after 2^31 - 1 runtime calls on one
  session the next id was `2147483648` rather than 1. That is wider than
  the 32 bits a varuint on the wire may hold, and the peer threw "varuint
  overflow" reading the frame instead of answering the call.
- An RPC call waiting on an answer fails when its connection closes, or a
  transport error stops its reads. It waited for good: only `stop()`, a
  heartbeat timeout or an unreadable frame failed it, since the session
  could not use `onClose` to hear of the end, that is the application's
  one callback, and set after the session it would have replaced the
  session's. The transports now tell the session themselves, before the
  application's callbacks and whenever those were set: TCP, WebSocket and
  reliable UDP connections, and `LocalConnection`. A `NetConnection`
  wrapping some other `INetConnection` wraps its `onClose`, keeping the
  application's callback when that is set through the `NetConnection`. A
  close costs one check; nothing on the way data goes changed.
- A `LocalConnection` listened or connected again could run two reader
  threads. `listen()` and `connect()` begin with `close()`, and the reader
  thread of the session that ended sleeps between polls: it woke to find
  the connection running again and carried on beside the new session's
  reader, reading its pipe, splitting its bytes, tearing it down when the
  read that lost found nothing, and closing its pipes on the way out.
  Reusing one server and one client for twenty sessions, a later session
  never connected in 3 runs of 3. A reader thread now acts only for its
  own session: what it does to the connection it does under the handle
  lock having checked the session is still its own, and what it hands on
  is refused once `close()` has ended it. Each reader also frames into its
  own buffer, which `close()` used to clear under a reader writing to it.
- An RPC contract, or a parent handler or commands class, in another
  module than the class that uses it could not name its types through an
  import alias or a private `typedef`. Its types reached the other class by
  name, `toComplexType()` keeps a typedef's, which only their own module
  can resolve, and the build failed with "Type not found" or "Unsupported
  RPC arg type" at the other module's position. They are now written out
  in full, typedefs followed and `Null<T>` kept, so an optional argument
  stays optional on the wire.
- A listening `LocalConnection` could stop delivering for good: no
  `onReady`, and nothing a client sent. Its reader thread attached the tick
  listener that carries dispatches to the runtime's thread, and
  `EventDispatcher` is not thread-safe, adding a listener reads the list,
  copies it and stores the copy, so an attach that met a listener change
  on the runtime's thread (timers and sockets make them all the time) was
  lost while the connection took it as made. Seen as a 2-in-60 flake in the
  native suite; with the runtime's listeners changing as fast as they can,
  38 of 40 connections lost their dispatches. The listener is now attached
  by `listen()` and `connect()` on the runtime's thread, and removed there
  by `close()` or once a connection whose peer went away has delivered its
  last dispatch, so the runtime still never holds a dead one; the reader
  thread only queues. A flush that drained the queue also detached the
  listener, so a dispatch queued in between could wait for the next one;
  that went too. `SharedChannel` had the same arrangement and has the same
  fix.
- `Seq32` arithmetic wraps at 32 bits on JavaScript, as on every other
  target. There `+` and `++` ran on past 2^31 - 1, so a sequence counted up
  past it stopped equalling the same sequence read off the wire, which is
  wrapped. Comparisons still held, which is how it went unseen. A reliable
  datagram session on Node that reached the crossing stopped delivering:
  with its sequence started forty below 2^31, forty messages of a hundred
  arrived. Sessions start at a random point in the 32-bit range, so some
  start close to it. `SnowflakeId` and `SequenceRing` count in `Seq32` too.
  The arithmetic now goes through `haxe.Int32`, which wraps where the
  target does not and costs nothing where it does.
- An RPC handler that extends another no longer fails to build with an
  error about a field that is there. To dispatch what the parent answered,
  the child's build followed the parent's method types, which types a
  method there and then, body and all when it declares no return type,
  before the classes it uses have finished building. A parent method
  `note(value:Int)` whose body read a static of its child failed the
  child with "Class<NotingChildHandler> has no field noted". The parent's
  build now records the signatures it dispatches, types written in full,
  on its `dispatch()`, and the child reads them untyped; a commands class
  reads its parent's response types the same way. A handler `@:rpc`
  method that returns a value without declaring its return type is now an
  error: its answer is encoded as that type, and left undeclared it was
  taken for `Void` and never sent.
- An RPC contract that extends another now carries the parent's methods.
  Only its own were read, so its stubs covered part of it, and its handler,
  which Haxe made implement the rest, dispatched none of the rest. A
  call to one of those arrived as an unknown op and closed the connection.
- Two RPC methods whose names hash to the same op no longer build into one
  surface. An op is the FNV-1a hash of a method's name, `glbvs` and
  `yacxa` share one, and on one connection the two would have been one
  method, with nothing to say so. The build now fails and names both.
- An RPC frame that names a count or a length larger than itself is refused
  before anything is allocated for it. The runtime lane made an array of
  whatever argument count a frame named, and both lanes made a `Bytes` of
  whatever length, before reading a byte of either. So a frame of twenty
  bytes could ask the receiving side for two gigabytes, in any build. Each
  is now checked against what is left of its frame first, and a frame that
  names more than it holds ends the connection.
- An RPC frame too short for what it carries no longer takes the rest from
  the frame after it. Each frame was read and then skipped to its end, but
  nothing stopped its arguments, or a response's value, from running past
  that end into the next frame's bytes. The handler ran on them, or the
  caller was answered with them. Reading is now held to the frame on every
  lane, compiled and runtime, calls and responses. A frame that runs past
  its end ends the connection before anything acts on it.
- An RPC handler method that throws no longer ends the connection. The
  exception reached the session as if the peer had sent an unreadable
  frame, so the connection closed, every call still waiting on it failed
  with it, and the caller was never told what had happened. The frame had
  been read whole, so the session now answers the call with an error and
  goes on to the next frame. A one-way call, compiled or runtime, is
  reported to `RPCSession.onHandlerError` in the same way; a runtime one
  rethrew, and ended the connection too. A frame that cannot be read, too
  long, for no known method, or with arguments that do not decode, still
  ends it.
- Two reliable datagram peers that dialled each other, as a hole-punched
  pair does, answered every HANDSHAKE with one of their own, for as long as
  they stayed connected. Each answer drew the next, so two peers with
  nothing to say passed some forty thousand datagrams a second between them
  over loopback. A HANDSHAKE now carries an acknowledgement once its sender
  has the other side's sequence. One that does is answered with an ACK,
  which draws nothing back.
- A reliable datagram session connects when the last message of its
  handshake is lost. The client's HANDSHAKE, answering the server's, is
  that last message, and a server sends its own again only when asked. So
  one lost datagram left the client connected and sending and the server
  not, dropping everything it was sent until its session timed out: at 10%
  loss, one connection in ten. Now:
  - A session not yet connected answers any frame that only a connected
    peer sends with its HANDSHAKE, once a pass.
  - A client asked again, with nothing yet acknowledged, sends everything
    unacknowledged again at once.
  - A client that has sent nothing repeats its HANDSHAKE on the connection
    attempt interval until the server shows it arrived. A server shows
    that with an ACK.
- A repeated HANDSHAKE no longer moves where a connected reliable datagram
  session expects its next frame. The sequence of every HANDSHAKE was
  taken, and a peer that had sent frames since named where it had got to,
  so frames still on their way were skipped: never delivered, and all
  acknowledged. Every HANDSHAKE now names the sequence its sender's frames
  began at, and only the first is taken.
- A reliable datagram session no longer measures the wait for a gap to
  fill as a round trip. Every frame a cumulative acknowledgement released
  was timed, including those that had arrived long before and sat behind
  the missing one. Under 10% loss on loopback, the smoothed round trip rose
  from 0.1 ms to half a second, and the retransmission timeout with it. A
  frame the peer says it holds is timed when it says so, and each
  acknowledgement gives one measurement, from the last frame sent of those
  it shows delivered.
- `HTTPServer` logs the port it bound when it starts, the one the system
  chose, for a configured 0, where it logged `:0`, and no longer logs every
  HTTP/1.1 response a second time as the raw text of its `HTTPStatusEvent`,
  after the request handler has already logged it readably.
- Native debug builds that include `hxcpp-debug-server`, every cpp debug
  build Aedifex makes while the VS Code hxcpp debugger is installed, no
  longer die before `main` when no debugger is attached. Not finding one,
  the debug server waits for a late attach by polling on a `haxe.Timer`,
  which it makes in a static initializer; CrossByte's `haxe.Timer` threw
  there, "haxe.Timer requires a primordial CrossByte runtime", since no
  runtime exists before `main`. A timer made before any runtime now waits
  for one and starts on the primordial runtime's ticks when that is set up,
  as the standard library's timer fires once its event loop runs, so a
  debugger attaching late is noticed too. Stopping a timer after its
  runtime has exited threw the same error, and no longer does.
- The HTTP/2 client no longer closes a pooled connection under a request
  that has just started on it. The pool judged a session idle from two
  fields it read without the session's lock, streams in flight, and when
  the last one ended, and a request starting on the session writes both,
  bumping the first and zeroing the second. Read between the two, a session
  had nothing in flight and had been idle since the clock began, so it was
  closed as past its allowance. Two concurrent first requests to one origin
  failed about once in two thousand: one with "Connection closed before the
  response headers arrived", the other, finding no connection, dialling a
  server that had stopped listening. The decision is now made by the session
  under its own lock, only tried so the pool never waits behind a request,
  and a session retired that way refuses new streams before anything is
  sent. A request refused like that, or by a connection whose peer has
  said GOAWAY, which the pool had no way to see, goes out once more on
  another connection, which REFUSED_STREAM guarantees is safe; it failed
  before.
- HTTP/2 connections on cpp and Node are no longer closed a quarter second
  after they open. The server's idle sweep measured a connection's silence as
  `Sys.time()` minus a last-activity time from `haxe.Timer.stamp()`, which is
  the same clock on hl, neko and jvm and a counter from an arbitrary start on
  cpp and Node. There every connection read as idle since 1970, the http2
  sample logged `HTTP/2 connection idle for 1790210331s`, and was closed at
  the first sweep: keep-alive between requests lasted a quarter second instead
  of `keepAliveTimeout`, and a connection with a request in flight was cut off
  instead of being given `requestTimeout`. No test noticed, because every
  HTTP/2 exchange in the suite finished before the first sweep ran; four cases
  now outlast it. The sweep and the activity it measures are both on
  `haxe.Timer.stamp()` now, with everything else that waits; see below.
- `haxe.Timer.stamp()` is monotonic on every native target and on the jvm,
  and everything in CrossByte that waits or measures reads it. On Linux and
  macOS natively it was hxcpp's stamp, which is `gettimeofday` less its first
  reading, and on the jvm `Sys.time()`: both move when the time of day is set.
  Stepped back, every deadline measured against them waits out the step;
  stepped forward, they all fall due at once. And some thirty deadlines and durations bypassed it for
  `Sys.time()` on every target, connect and handshake timeouts, the HTTP
  request, keep-alive and stall deadlines, WebSocket pings, drains, pool
  waits, STUN queries, service attach, `Histogram.time`, so where the two
  clocks differ, times from each could meet: `ReliableDatagramServerSocket`
  drove an attached ICE agent from `Sys.time()` while `IceAgent`'s own example
  starts one from `stamp()`, the same mix that closed HTTP/2 connections
  above. `stamp()` is now QueryPerformanceCounter on Windows natively, as it
  was, `CLOCK_MONOTONIC` on other native platforms, `System.nanoTime` on the
  jvm, and `performance.now()` on JavaScript, as it was; hl, neko and eval
  have only the time of day. Tests pin native POSIX to `CLOCK_MONOTONIC`
  and the jvm away from the time of day, and read the framework's source for
  `Sys.time()`, which is left in one place, the `Date` header, marked as the
  time of day on purpose.
- A reliable datagram message larger than one frame arrived as several.
  `DATAGRAM` mode promises the peer one `DATA` event per `send`, and `send`'s
  own documentation said larger payloads were "reassembled on the remote
  side", but nothing marked where a message ended: a 3000-byte send arrived as
  1200, 1200 and 600. Every fragment but the last now carries a flag saying
  more follows, and the receiver joins them once, in order, however they
  arrived. An older peer ignores the flag and delivers fragments as before.
- Closing a reliable datagram session from inside its own `DATA` handler
  reported an `ioError`, "Operation attempted on invalid socket", for the
  close the caller had just made. The acknowledgement for the message being
  handled went out after the handler returned, on the transport the close had
  shut. Nothing is acknowledged once the session is closed.
- `QuadTree.insert` could refuse a point inside its bounds. A child's far edge
  is `(x + w/2) + w/2`, which can round an ulp short of the parent's `x + w`,
  and a point in that sliver was in the parent and in neither child, so the
  children, asked in turn, all refused it, one set of random bounds in
  twenty has such a sliver at its first split alone. The child is now chosen
  by which side of each midline the point falls on, which cannot refuse, and
  which also spares up to four containment tests a level: rebuilding a tree
  of 100,000 points is about a quarter faster.
- `File` refused an absolute path whose only separator is the root,
  `/root`, `/tmp`, `/` itself, on Linux and macOS, and `parent` of a root
  threw. As root in a container `HOME` is `/root`, so the default document
  root, `Store` and `getRootDirectories()` all failed there.
- `PostgresConnection.ping()` reported every native connection dead without
  asking the server, having checked a handle only the php target sets. A pool
  validating with it would have discarded every connection it opened.
- A PHP response lost all but its last cookie: repeated CGI headers
  overwrote one another. They are joined as the rest of the HTTP stack joins
  them, and `Set-Cookie` is split on an escaped newline, where a line break
  typed into the source became `"\r\n"` in a CRLF checkout and glued two
  cookies into one header.
- `File.spaceAvailable` reported every disk full on Linux and macOS. The `df`
  output was split with a pattern missing its global flag, so no row had the
  fields a data row needs.
- Native builds on Linux and macOS, which MSVC had been hiding: a second
  `hxcpp.h` include that GCC resolved into the precompiled-header directory,
  Windows-only calls in `SecureRandom` and `PHPBridge` compiled everywhere,
  `libdl` handed to the linker as a file name, the DTLS bridge linked twice,
  and BLAKE3's SSE4.1 and AVX2 files built without their flags, which hxcpp
  drops from inside a `<file>` element. MSVC now builds the AVX2 backend with
  `/arch:AVX2` too, and BLAKE3 has test vectors long enough to reach both.
- A listening socket on the jvm target had a backlog of 50 whatever it asked
  for, so a burst of 51 connections was refused before the server heard of
  it. It now asks for the system's maximum.
- `SlotMap` and `PackedSlotMap` leaked a slot on its 256th reuse. The
  generation outgrew the eight bits a `SlotHandle` carries, handle and slot
  never compared equal again, and the entry could not be removed.
- SCTP receivers are bounded against a peer that sends and never finishes.
  An association kept every chunk it received for as long as it was open,
  leaking at the rate it was used; the fragments of a message never ended,
  and ordered messages waiting on a sequence that never came, were held
  without limit and are now capped at a megabyte per stream; and reassembly
  re-sorted everything held on every arrival, so 4000 fragments took sixteen
  seconds on eval. Fragments are now inserted in order, and a stream's held
  messages are looked up by sequence rather than searched.
- The DTLS `ClientHello` assembler did work in proportion to every fragment
  so far on each arrival, and a peer chooses the fragments: 4000 pieces of an
  unauthenticated handshake record took seven seconds on eval. It merges in
  order now, with a cap on disjoint runs, and the same 4000 take 15 ms.
- The WebRTC stack settles its futures when their owner closes.
  `PeerConnection.ready`, `IceAgent.connected`, `DtlsTransport.established`,
  `TurnClient.allocated`, the SCTP association's `established` and
  `DataChannel.opened` settled only through the handshake, so closing before
  it finished left a caller waiting forever. A deliberate close does not
  raise the "failed and nothing was listening" warning.
- `PeerConnection` survives the description a peer sends it. One unusable
  candidate threw part-way through `connect` and left the agent unstarted,
  bad credentials threw after the candidates were added, a candidate's
  priority was taken on trust, and pairing cost grew with the cube of the
  peer's candidate count, which is now capped at 64.
- TURN permissions lapsed after five minutes. Refreshing an allocation does
  not renew them and nothing else did, so the relay silently began dropping
  the peer while the connection looked healthy. `TurnClient` renews them on
  its tick.
- A closed `DataChannel` kept its stream number for the life of the
  association, so the peer could not reopen that stream, and after 32768
  channels the number wrapped on the wire into a live one. Closed channels
  are released, and running out of numbers throws.
- A WebSocket frame header claiming a two-gigabyte payload was waited on, and
  everything sent after it retained, though the size limit would refuse the
  frame once it arrived, ten unauthenticated bytes to ask. A frame is now
  refused on its header.
- `ServerWebSocket.handshakeTimeout` closed nothing on any target. The reaper
  took every stalled upgrade for a finished one and stopped tracking it with
  its socket still open, and on Node upgrades were never tracked at all, so a
  peer could connect, send nothing and keep its descriptor.
- WebSocket close codes are validated by RFC 6455's ranges, so a peer closing
  with 1016, 2000 or 5000 gets a protocol error rather than having the code
  reported as its reason.
- HTTP/1.1 header lines that are not headers are refused with 400: an
  obs-fold continuation, whitespace before the colon, a line with no colon.
  Trimming each line first let a folded `Transfer-Encoding` take effect here
  and nowhere upstream, which is request smuggling.
- A chunk size is bounded before it is parsed, on the server and the client.
  `Std.parseInt` answers four different ways for a value past 32 bits, and on
  Node the answer was 4294967295, which the server accepted and then waited
  on forever. The client also requires the size line to be hex, treats a body
  as chunked only when chunked is the final coding, and says why a body
  failed instead of "Download failed".
- Decompression is bounded while it decodes. A server chose how much memory
  the HTTP client spent, a kilobyte of gzip is a megabyte of zeros, and
  stacked codings multiply, which now stops at 64 MB and two codings.
  `ByteArray.uncompress` takes a `maxOutputSize`, honoured inside the
  deflate, gzip, Brotli and LZ4 decoders so the memory is never taken; the
  default, 0, is no limit. The opt-in native Brotli and LZ4 backends are
  still measured after they return.
- The HTTP/2 server bounds the frames it is obliged to answer. SETTINGS and
  PING are acknowledged on arrival and nothing counted them, so a peer
  sending faster than the server drained grew its output without limit
  (CVE-2019-9515, CVE-2019-9512). Past 100 in the Rapid Reset window the
  connection gets GOAWAY with ENHANCE_YOUR_CALM.
- A reliable datagram server believed any CONNECT. One spoofed datagram set a
  handshake retransmitting about seven times at the address it named, and
  half-open sessions were unbounded. Only the dialling side retransmits now,
  and `ReliableDatagramServerSocket.maxPendingConnections` (256) caps
  half-open sessions, dropping the excess rather than answering it.
- Bounds checks that overflowed. `position + length > size` wraps negative
  for a large length and passes; eight checks were written that way, in
  `ByteArray`, `ByteArrayOutput`, `DatagramSocket.send`,
  `ReliableDatagramSocket.send`, the Node process pipe, the native socket
  address code and the Postgres parameter block, and `ByteArrayInput`'s own
  let a varint length of 2^31 - 1 read past the buffer. The varint decoders
  also keep their bounds in `-D final` builds, which had compiled out exactly
  those three guards, and stop at five bytes: a sixth was shifted by 35,
  which most targets mask to 3.
- `ByteArrayOutput.writeIntAt` wrote past the end of a chunk when the integer
  straddled two, an out-of-bounds heap write from a public method.
- `ByteArrayOutput.reserve` reallocated on every call, its early return
  having compared the size against itself doubled, so an RPC message of N
  values allocated about 2N times.
- A `Socket` constructed with port 65535 did nothing, though `connect` to the
  same port worked.
- `Error.getCallStack()` returned the stack of whichever exception was last
  caught anywhere, rather than the error's own.
- A `Future` resolved on one thread while another attached a handler could
  lose the handler, or free the array it was in while the resolution walked
  it. State changes under a lock now, on targets with threads.
- `System.processorCount` returned 0 on macOS. Process affinity is not
  implemented there, macOS having no process-level affinity, and reports an
  empty mask.
- A reliable socket counted its reorder cache by walking it, with an iterator
  allocation, for every datagram that arrived out of order.
- A WebSocket server on the jvm target stopped the runtime. `setBlocking` there
  did nothing when it was called before `bind()`, there is no channel to
  configure until then, and `bind()` opened one hardcoded to blocking, so the
  request was discarded. `ServerWebSocket` calls `accept()` each tick and reads
  "would block" as "nobody is waiting", which on a blocking listener is instead
  a native `accept0()` that parks the caller. That caller is the runtime's own
  thread, so an idle WSS listener froze the whole instance: every timer, every
  other socket. `ServerSocket` escaped it only by chance, because it selects
  before it accepts. The jvm socket now remembers what `setBlocking` asked for
  and opens the listening channel that way.
- TCP addresses on the jvm target were reported uncompressed, `::1` came back
  as `0:0:0:0:0:0:0:1`. `IPv6.compress` exists for exactly this, and its
  documentation names this exact difference, but it was applied in
  `DatagramSocket` and `LocalAddress` and never in the TCP socket beside them:
  the same address read one way over UDP and another over TCP on one target.
  An application comparing what it bound against what it was told back is the
  obvious thing to write and it silently failed, and an address in an HTTP
  whitelist or blacklist written canonically matched nothing.
- TLS on the jvm target stranded incoming data. The handshake completed, the
  connection looked healthy, and a request sent over it was never answered,
  an HTTPS server there accepted connections and replied to none of them. A TLS
  read takes whole records off the channel, so the tail of a handshake
  routinely arrives in the same read as the peer's first application record,
  which is what a client that sends its request the moment it connects
  produces: every HTTPS client. Those bytes then sat in the TLS layer while
  `select` reported an idle socket, and nothing came back for them until the
  peer gave up and closed, the close being the only thing that made the
  channel readable again. `SocketRegistry` now asks each socket whether it is
  holding readable bytes the kernel no longer has, before selecting rather than
  after, since asking afterwards would spend the whole poll timeout waiting for
  data already in hand. Buffered means decrypted and ready, not merely present:
  a partial record answers no, or the registry would hold its select at a zero
  timeout and spin.
- HTTPS did not work on the jvm target at all. `HTTPServer` built a secure
  listener from `tlsCertificatePath` and then skipped installing the
  certificate behind a `#if (!java && !jvm)` gate left from before that target
  had TLS, so the server had nothing to present. Nothing caught it because
  nothing tested HTTPS through `HTTPServer` on any target: the socket layer had
  TLS cases and the HTTP layer had request cases, and the seam between them was
  joined by no test. It has one now, and it runs everywhere the server can
  listen.
- `ServerSocket.alpnSupported` and `FlexSocket.alpnSupported` reported `false`
  on jvm after ALPN started working there. The flags were read, not merely
  advertised: `HTTP2Backend` refuses HTTP/2 over TLS wherever `alpnSupported`
  is false, so the target that could negotiate `h2` was the one being told it
  could not.
- A socket accepted by a TLS listener reported `secure == false`. The field was
  set only by the browser constructor, so every server-side socket denied being
  encrypted regardless of what it was carrying.
- The jvm socket read path allocated and copied on every read. `readBytes`
  allocated a `ByteBuffer` the size of the read and then copied every byte out
  of it into the caller's buffer, sixty-four kilobytes of each per chunk on
  the framework's own read path, while the write beside it had always wrapped
  the caller's array and done neither. It wraps now too. Loopback throughput
  went from about 1200-1500 MB/s to about 3000 MB/s on the machine that
  measured it.
- The jvm socket layer exhausted the machine's ephemeral ports under sustained
  use. `sys.net.Socket.select` opened a fresh `java.nio.channels.Selector` on
  every call, and on Windows a `Selector` builds its wakeup pipe from a loopback
  socket pair, so each call cost two sockets and left them in TIME_WAIT for
  the best part of a minute. The socket registry calls `select` once per tick,
  so a runtime at sixty ticks a second put a hundred and twenty sockets a second
  beyond reach and worked through the whole ephemeral range, about sixteen
  thousand on Windows, in roughly two minutes. Everything socket-shaped then
  failed at once: "Address already in use" out of a connect, and "Unable to
  establish loopback connection" out of the JVM's own pipe setup. The selector
  is now opened once per thread and kept. Measured over two thousand calls:
  1796 sockets stranded before, none after, and the calls themselves 3.6 times
  faster because opening the selector was most of what they did. `waitForRead`
  had the same fault and the same fix.
- A refused connection took the full connect timeout to report, twenty
  seconds by default, measured at 20001ms, for a refusal the operating system
  had reported in two. The tick that completes a connection asked `select` about
  writability alone, and on Windows a failed connect is reported in the
  exception set and never becomes writable, so nothing noticed it until the
  deadline expired. The socket is now asked about on both sets and a refusal is
  reported as soon as it arrives, in 2004ms on the machine that measured it,
  which is the platform's own latency. It arrives as an `ioError`, not a
  `close`: a connection that never came up is a different fact from one that
  hung up, and a caller retries them differently. POSIX reports a failed connect
  as writable rather than exceptional, so it was never affected and is
  unchanged.
- A failed `bind`, `connect`, `send` or listener `close` reported "Operation
  attempted on invalid socket." on `ServerSocket`, `ServerWebSocket` and
  `DatagramSocket`, whatever had actually gone wrong. The socket was usually
  fine, an address that is not an interface on this machine, a port already
  taken, a peer that is gone, and the caught error was discarded rather than
  reported, so the one line of evidence a failure produced named a cause that
  had not happened. Each now says which operation failed, against which address
  and port, and carries the underlying error. `ServerSocket.bind` and
  `ServerWebSocket.bind` additionally matched only two error strings with no
  `default`, so anything else fell through the `switch` and `bind()` returned as
  though it had succeeded, leaving the caller to listen on a socket that was
  never bound; both now report every failure. The same fabrication in
  `Socket.flush` is what made the connect-event race above unreadable for weeks.
- A native client socket could report a healthy connection as failed,
  intermittently and rarely. A non-blocking connect that completed immediately,
  which a loopback connect does now and then on Windows, dispatched the
  connect event synchronously from inside `connect()`, and a listener that wrote
  on it reached a socket the operating system had reported connected but not
  finished establishing; the write failed with an end-of-file the connect had
  raced. Two further faults kept it unreadable. `flush()` reported every
  non-blocking-related write failure as "Operation attempted on invalid socket.",
  a fabricated message naming a cause, a null socket, that had nothing to do
  with what happened, so the real end-of-file never once appeared in a red run.
  And the completion tick dropped the connect event whenever the peer's data and
  FIN landed in the same tick the connect completed, which turned a clean
  one-shot exchange into a reported connection failure. The connect event is now
  dispatched from the writability check the tick already makes rather than
  synchronously, so a listener writes only once the socket is genuinely ready;
  `flush()` surfaces the real error; and the tick announces the connect even when
  the connection closes in the same pass. The eval interpreter, whose sockets are
  blocking and have no writability tick to defer to, keeps its synchronous
  dispatch; the browser and Node paths were asynchronous here already. All three
  were unaffected.
- Writing past the end of a `ByteArray` could expose bytes the caller never wrote. The zeroing of a skipped gap lived inside the reallocation branch and started from the old *capacity*, so a gap opened without a reallocation was never zeroed at all, and one opened with a reallocation was only zeroed above the capacity the old buffer had, while the copy into the new buffer carried every stale byte beneath it across. Shrinking a buffer to reuse it and then writing past the new end handed back the previous contents: ninety-six of ninety-six bytes, measured. The existing case covered only the reallocating path, which is why it had always passed. Zeroing now runs against the old logical length in both paths, and two cases cover the gap that needs no growth.
- An empty data channel message sent to a browser vanished without a word. RFC 8831 gives zero-length messages payload protocol identifiers of their own and has them travel as one byte of zero, because SCTP cannot carry a message of no bytes; the receive side here honoured that convention and the send side never did, shipping an actually-empty chunk that a real browser's SCTP discards silently. Every internal test passed, both ends of a homogeneous pair agreeing on the broken shape, the browser interoperability run now exchanges binary and empty-binary messages with headless Chrome precisely so that class of agreement cannot survive review.
- `StunClient.isSupported` lied on python and lua, and would have on HashLink, which did not compile at the time and does now. It derived from `DatagramSocket.isSupported` alone, and those targets have UDP but no CSPRNG, so the flag said `true` while the first line of `discover()` threw, which is the one thing a support flag exists to prevent and the same bug class the neko UDP flag had. It now also requires `SecureRandom.isSupported`, since the transaction id is what a reply is believed by and one drawn from a weak generator would let an off-path party hand this host an address of its choosing. `discover()` and `ReliableDatagramServerSocket.discoverPublicAddress` fail their future with the reason named rather than throwing, and CI now runs a probe on python, the one CSPRNG-less UDP target it can execute, because every suite runs where a CSPRNG exists and an in-suite assertion of this could never fail.
- A browser offering a data channel to CrossByte could not complete a DTLS handshake. Chrome's ClientHello does not fit in one datagram and is sent in fragments; mbedtls reassembles fragmented handshake messages in general but not this one, because reassembly needs handshake state and the ClientHello is what creates it, its parser says so in as many words. `ClientHelloAssembly` puts the message back together before mbedtls sees it, rebuilt as though it had arrived in one piece, which RFC 6347 requires because the handshake hash is computed over that form. Only a DTLS server ever reads a ClientHello, which is the whole of why a browser answering CrossByte connected and a browser being offered to did not.
- `PeerConnection` drove the ICE role and the DTLS role from one bit, and they are two. The peer that offers is ICE-controlling; which peer sends the DTLS ClientHello is negotiated separately in the description, an offer proposing `actpass` and the answer choosing. Everything above DTLS follows the *DTLS* role rather than the ICE one: RFC 8831 has the DTLS client open the SCTP association and RFC 8832 gives it the even data channel streams. For two CrossByte peers the two roles land on opposite sides and one bit appeared to serve; a browser makes the difference unavoidable, since it offers, taking the ICE role, and offers `actpass`, leaving the peer answering it ICE-controlled and the DTLS client at once. A connection built on one bit has to be wrong about one of them, and wrong quietly, because the ICE half still connects and only the handshake afterwards stalls. `controlling` is now `iceControlling` and `dtlsClient`, the constructor takes `isOfferer`, `description()` states the role this peer has settled on, and `connect()` resolves it from what the peer proposed. A role conflict during checking now changes the ICE role alone, where before it rewrote the DTLS role too, abandoning a handshake already agreed in the description over a detail settled afterwards. The interoperability run passed before this change because the answering peer happened to be both; a CrossByte peer *offering* to a browser could not have connected.
- One failed `DatagramSocket.send()` permanently deafened the socket. The failure was routed into `__dispatchIoError`, which calls `stopReceiving`, so a single unroutable destination stopped every other peer being heard from, silently, and for the life of the socket. That is the same fault the read path was already fixed for, on the other side of the same class, and it is worse here: ICE finds a path by trying every candidate a peer offered and expecting most of them to fail, so an IPv6 candidate arriving at a socket bound to IPv4 was enough to end the connection before it began. It was found by the browser interoperability run and by nothing else, every existing test sent only to somewhere reachable, so the whole suite passed while no CrossByte peer could ever have completed a real WebRTC connection. Sends still throw and still dispatch the error event; what no longer happens is the socket going deaf over one datagram it could not deliver.
- `DatagramSocket.isSupported` answered `true` on neko, where `sys.net.UdpSocket`'s constructor threw "Not available on this platform" (the throw was CrossByte's own replacement for that class, which had no neko branch; neko's standard library has UDP, and the replacement has a neko branch now), so a caller that checked the flag first, which is the entire reason the flag exists, had been told the one lie it is there to prevent and was left with no other path to take. Found while building `LocalAddress` on the same primitive, and neko is in no CI matrix, which is why nothing had caught it. The new `LocalAddressTest` does not assert which answer is right for any target; it asserts that the flag and the behaviour agree, so the next target this happens on fails a test rather than a deployment.
- Two reliable datagram peers dialling each other at the same moment never connected. That is not an exotic case: it is how hole punching works, and the only way two peers behind NAT reach each other, because each side's outbound datagram is what opens its own mapping for the other, so both must dial and neither can wait. `__acceptFrame` answered an incoming `CONNECT` only when `__incoming` was set, which is true of an accepted session and false of a dialled one, so both peers sat retransmitting `CONNECT` at each other until the connection timeout fired. An unconnected session now answers with `HANDSHAKE` whichever side dialled it, the same frame an accepted session already replied with, so the ordinary client-and-server exchange is untouched. This is what joins the STUN work to something usable: each peer discovers where it is reachable, advertises it, the super node hands each the other's address, and the simultaneous dial that follows now completes instead of expiring.

- A `wss://` `ServerWebSocket` held a stalled handshake forever. `ServerSocket` bounds this by deferring TLS and sweeping deadlines from the tick, but `ServerWebSocket` overrides that tick and accepts through its own path, so it inherited `handshakeTimeout` as a setting and never as a sweep, a peer could complete the TCP connection, say nothing, and occupy a socket until the operating system ran out of them. It now tracks accepted sessions whose upgrade has not completed and reaps them, which covers both ways one can stall: a peer silent during TLS, and a peer that completes TLS and never sends the upgrade. Zero still means no deadline. Node keeps the exposure for now, because its server hands connections to a callback rather than accepting in the tick; the reaper is target neutral and needs only that hook.

- One datagram to a departed peer deafened a `DatagramSocket` permanently. A read that failed went to `__dispatchIoError`, which calls `stopReceiving()`, but on a connectionless socket a read error describes one datagram, not the socket. Send to a port nothing listens on and the peer stack answers ICMP port unreachable, which Windows reports back to the sender as an error on a later read; the datagram it complains about is already gone and the socket is fine. Measured before changing anything: a socket that had just completed a STUN exchange stopped receiving entirely after a single knock on a closed local port, reporting `Custom(Socket operation failed)`. For a peer-to-peer mesh that is not an edge case, dialling peers that have since left is ordinary, and one departed peer should not silence every other. A failed read now ends that tick and nothing more, with a run counter so a socket that really has stopped working is still reported rather than swallowed.

- An async `SQLiteConnection` could lose every event it had queued, including the `CLOSE` it was closing for. `close()` sent its `CLOSE` progress message and then called `Worker.cancel()`, which detaches the runtime listener and frees the message queue immediately, on the worker thread, so anything the main thread had not yet drained was destroyed. Whether that happened turned on whether a runtime tick landed while the worker was still running, which is why it surfaced as an intermittent test failure rather than as a broken feature: roughly one run in four in the full suite, one in sixty in isolation. With no tick during the run at all it is not intermittent, all six events of an open-through-close sequence were lost, every time, which is how it was finally pinned down. `close()` now finishes through `sendComplete()`, whose `Complete` message travels the same queue in order: everything sent before it is dispatched first, and the listener is detached when that message is drained on the main thread with nothing outstanding. The work loop leaves on a flag set from inside itself, so the worker thread ends rather than blocking on a queue nothing will add to.
- Every platform decision made while running now asks the machine rather than the compiler. `#if windows` says what a build was told, not where it runs: Haxe sets it on no target by itself, a native build gets it from its hxml, or from `HostPlatform` when CrossByte is a haxelib, and eval, the JVM and Node never have it (nor do hl and neko, which were not compiling at the time), so three targets running on Windows took the branch written for POSIX, and nothing said so. `System.PLATFORM` read `"undefined"` on all three. `System.appStorageDir`, which is where `Store` keeps its files, read `HOME` instead of `APPDATA`: with `HOME` set, as Git Bash sets it, that is the profile root, so a store written by a native build was invisible to a Node one on the same machine; with `HOME` unset, which is the normal state for a Windows service, it became the literal string `"undefined"` relative to the working directory. `File.separator` and `File.lineEnding` answered for the wrong platform, `File` joined every path it built on the wrong character, `getRootDirectories` returned `/`, the temporary directory resolved to `/tmp`, `%VAR%` expansion was compiled out, and `isHidden` applied the dotfile convention on Windows. `HTTPRequestHandler` skipped the case fold in its document-root containment check, which is fail-closed, a legitimate request refused rather than a forbidden one served, and is why it went unnoticed. The affected sites use `System.isWindows`; the conditionals that genuinely select types, native includes and macro-time behaviour are unchanged.
- The test for the storage directory carried the same `#if windows` as the code, so on eval it expected the wrong value and got it. A test that reproduces the bug it checks for cannot see it.
- `File.spaceAvailable` was wrong on every target that could answer it, and wrong by answering rather than failing, the worst shape for a caller asking "have I room to write this". On Windows it matched the `fsutil` line containing "Total bytes", which is the volume's capacity, so a 930 GB disk with 75 GB free reported 930 GB. On POSIX it required `df`'s first column to equal the path, but that column is the device, so the loop fell through and returned zero, indistinguishable from a full disk. On Node it compiled cleanly and threw `ReferenceError: sys is not defined` when called, because `sys.io.Process` type-checks there (hxnodejs allows the `sys` package) and generates nothing. It also asked the process for its exit code after closing it, which raises `process_exit` on eval. Node now reads `fs.statfsSync` directly, no shell, no output parsing, and the shelling targets parse the right line and return bytes on both. Nothing had ever called this method, which is why all of it survived.
- `File` chose its platform behaviour with `#if windows`, which says which target the compiler was aimed at rather than which machine is running. eval does not set it, so on Windows `spaceAvailable` took the `df` branch, found no `df`, and reported a full disk as empty. The disk-space path uses `Sys.systemName()` now. The same conditional still governs `lineEnding`, `isHidden`, `getRootDirectories`, the temporary directory and Windows environment-variable expansion in this class, and is wrong there in the same way on eval, Node and the JVM; those are left for a change of their own rather than swept in behind a bug fix.
- `Future.then` replaced the previous handler instead of adding to it, so a future observed in two places silently lost one of them, and since `then` returns the future, `f.then(a).then(b)` ran only `b`: the shape the API's own fluent return type advertises was the shape it punished. Handlers accumulate and run in registration order.
- A handler that threw took three things down with it, all silently. It escaped into whoever resolved the future, for the PHP bridge that is the runtime tick, where an escape costs every other connection rather than the one, it stopped every handler registered after it, and it skipped the event dispatch, so anyone observing by `RESULT` instead of by callback simply never heard. Handlers are isolated and a throw is reported.
- A `Future` that failed with nothing listening lost the failure completely: no log, no exception, no return value anyone checks, with the symptom being a thing that never happens. It is now reported a tick later, a tick, not immediately, because failing before the caller can attach is legitimate and happens here: `PHPBridge.execute` refuses a path traversal by returning an already-failed future, and the caller attaches on the next line.
- `StoreTest` chains through `flatMap` instead of nesting. It was written before `Future` could compose, so each step sat inside the one before it, ten tabs deep at worst, with a failure handler repeated at every level: 68 copies of `failWith(async)` across the file, now 6. The repetition was the cost rather than the indentation, each copy is a place to forget one, and a forgotten one turns a failing store into a case that hangs until utest times it out and reports something unrelated to what broke. Two cases keep their nesting deliberately, because the failure is what they assert and `flatMap` exists to carry a failure past everything downstream. Identical assertion counts on all six targets before and after.
- `crossbyte.Future` had no tests, which is not incidental to the four defects above; each is a one-line demonstration and none of them had one. It now has 29 assertions, running on every target including the browser.
- A streamed response hung its connection forever on Node. `HTTPRequestHandler` primes its stream pump once and then waits for `Socket.__onWritableDrain` to ask for each next slice; that hook is only ever invoked from `registryOnWritable`, which the native poll registry calls when a descriptor reports writable. Node has no registry and no descriptor, so nothing called it at all, a response wrote its head and its first slice and then stopped, with the client waiting on a body that was never coming. Every identity response over the 256 KB streaming threshold did this. The pump is driven from the tick there instead, which is safe to do every tick because it already bounds itself by the watermark and by a burst budget, so it writes only what the peer has made room for however often it is asked.
- `MetricsEndpoint` refused to build on Node. Its gate was `#if !js` under the comment "not built for the browser: it serves metrics over HTTP, which means listening", and Node listens. The same "JavaScript means browser" reading that kept the HTTP server's own tests off Node long after the server ran there. It is middleware over `HTTPRequestHandler` and now shares that class's gate.
- Any byte above 0x7F in a request line or header threw `RangeError: Invalid code point -23` out of request parsing on Node, a UTF-8 filename in a `Content-Disposition`, an accented `Referer`, a non-ASCII `User-Agent`. `__readLine` built its string with `ByteArray.readByte`, which carries Flash's sign extension, so 0xE9 arrived as -23 and went to `addChar` as a negative code point: harmless where a String is bytes, fatal where it is code points. The comment above the loop claimed these bytes "read back exactly as they arrived", which was the intent and not the behaviour. Found by running the HTTP suite on Node for the first time; it is the one case of 69 that failed there.
- Header injection and request smuggling were unchecked on both JavaScript targets. The rules were extracted out of `_internal.http.Http` into the portable `HttpSyntax` precisely so they could be tested everywhere, but `HTTPHardeningTest` went on calling them through `Http`, which drives a raw socket with its own TLS and exists on no JavaScript target, so the extraction bought no coverage at all. The cases now call `HttpSyntax`, and `exceedsChunkedBodyLimit`, the one decision helper left behind in `Http` when the others moved, went with them.
- a failing PHP backend is named in the error rather than described as nothing. A socket error can arrive with no text at all, and the bridge reported it verbatim, "PHP backend failed: " with an empty reason, which tells an operator running more than one backend neither which one nor why. The address and port are included and an empty reason is replaced with a statement that there was none. Found by a Node test whose backend was closed rather than silent, which is a different failure than the one it was written for.
- A PHP backend that accepted a connection and then never answered held the runtime forever. There was no timeout on the FastCGI socket and no deadline on the exchange, and `requestTimeout` deliberately stops covering that window once a request has been read, so one unresponsive php-fpm stopped the server for every client at once, with no recovery short of killing the process. `HTTPServerConfig.phpTimeout` bounds it, defaulting to 30 seconds, and an exchange that runs past it answers `504 Gateway Timeout` rather than `502` or nothing. `0` restores the old unbounded behaviour for a deployment that wants it.
- deflate, gzip and LZ4 now compress. All three were stores: `Deflater.compress` wrote stored blocks and nothing else, a `0x01` header, the length, its complement, then the raw bytes, no Huffman coding and no LZ77, gzip wrapped the same, and `Lz4.compress` emitted one literal run without ever looking for a match. Every output was a valid stream that any decoder accepted, and every one was larger than what went in: 6000 bytes of a repeated twelve-byte string came back as 6005, 6028 and 6025, measured identically on cpp, Node and in a browser. `HTTPRequestHandler` serves `Content-Encoding: gzip` and `deflate` through these, so a server negotiating either sent more bytes than it would have uncompressed and made the client decompress them for nothing; only clients asking for `br` were getting real compression. Deflate now emits a single fixed-Huffman block (BTYPE=01, the RFC 1951 section 3.2.6 code lengths, so no table has to be described in the stream) over an LZ77 pass with hash chains, lazy matching and a bounded chain walk, and falls back to stored blocks when that would not be smaller, so incompressible data still costs five bytes per 64K rather than growing. LZ4 gained the match search its format was already written for. The same 6000 bytes now come back as 59, 77 and 45 against brotli's 23. The streams were checked against decoders that are not CrossByte's, which is the part a round-trip cannot answer: `zlib.inflateRawSync` and `zlib.gunzipSync` for deflate and gzip, and for LZ4 a decoder written from the block format, asserting the trailing-literals and last-match rules a lenient decoder would overlook. Thirty payloads pass through all of it, every length from 0 to 19, both codecs' match boundaries, all 256 literal values, long overlapping runs, matches at maximum length and at 30000 distance, and incompressible data on both sides of 64K, and cpp, Node and browser produce byte-identical output for all thirty.
- gzip spent five bytes per response on a filename that did not exist. `ByteArray.compress(GZIP)` passed the literal `"data"` and `GZCompressor` set `FNAME` unconditionally, so every gzip HTTP body carried a name for a file there was none of. The member is written unnamed unless a name is actually supplied; the decompressor already handled `FNAME` being absent.
- LZ4 decoding threw in a browser, `TypeError: Cannot read properties of undefined (reading 'hxBytes')`, on every call, since the `js && !nodejs` branch that caused it was written. It returned `Bytes.ofData(untyped oBuf.buffer)`, and `oBuf` is a `ByteArray` with no `buffer`, so `ofData` was handed `undefined`. Given one it would still have been wrong, returning the whole backing store where only the first `oPos` bytes were written. The generic path every other target already used is correct, and the browser now takes it too.
- Including CrossByte in a browser bundle threw `SharedArrayBuffer is not defined` while the bundle loaded, before a line of application code ran. `Random`'s shared seed was a `haxe.atomic.AtomicInt`, which Haxe implements on js with a `SharedArrayBuffer`, available only to a cross-origin-isolated page, and it is a static initialiser. It is an `AtomicInt` only where there are threads to race now, and a plain `Int` elsewhere, for the same reason `NoMutex` exists. `Random.seed` was public and read by nothing outside the class; `reseed()` is the supported way to set it and does not vary by target. The interpreter has no atomics either, so this also un-gates `Random` there, the suite that runs everything could not previously name the class.
- An `RPCHandler` with more than eight methods could not dispatch anything on either JavaScript target. Above that count the macro generates a perfect hash: it builds the tables at compile time on the eval interpreter and emits the same arithmetic to run on the target, so the two must agree about what an opcode hashes to. They multiply by constants chosen to overflow, eval wraps and js does not, and every index differed, so every call hit the `Unknown RPC op` guard. Eight or fewer used a direct switch and worked, which is why nothing noticed.
- `Random` gave a different sequence for the same seed on JavaScript, breaking the one guarantee it documents: reproducible results when seeded. Its mixer multiplies by two constants chosen to overflow. A replay, a procedural world or a shared simulation crossing targets would have diverged in silence.
- `crossbyte.utils.Hash` computed a different function on JavaScript. Every hash in it multiplies by a constant chosen to overflow, the overflow is the mixing step, and where an `Int` is 32 bits that wrap is free, while on js an `Int` is a double and the product simply grows past 2^53 and loses its low bits. `fnv1a32` of "sendData" was `-20905118279726560` there against `622618135` everywhere else, so two CrossByte programs hashing the same bytes disagreed if either was JavaScript. `fmix32` and `combineHash32` were wrong the same way. All three now go through a wrapping 32-bit multiply, and `UtilsTest` pins known answers rather than self-consistency, a test that hashed something and compared it to itself passed throughout.
- `RPCCommands.__nextRequestId` could not detect its own overflow on JavaScript. The guard resets the seed when the increment wraps negative, which needs a 32-bit `Int`; on js `0x7FFFFFFF + 1` is `2147483648`, positive, past the guard, and past the width of the field the id is written to, after which the id and the pending-response key stop agreeing and the call waits for a reply it cannot match.
- `ServerWebSocket.secure` reported `false` on a server that was terminating TLS, on every target. The constructor set a private `__isSecure` and then called `super()` with no argument, so the property it inherits from `ServerSocket` never saw the value, two fields for one fact, and the public one was the wrong one. It now passes the flag up and keeps no copy. One consequence is deliberate: a secure `ServerWebSocket` refuses on the jvm target at construction, where before it was accepted and then had no TLS to give. That refusal was always `ServerSocket`'s, and stepping past it was never intended.
- `crossbyte.net.Socket.close()` did nothing on Node. It called `close()` on the underlying socket, which a `js.node.net.Socket` does not have, and the resulting TypeError was swallowed by the surrounding catch, so no FIN reached the peer, the descriptor stayed open, and the handle kept Node's event loop alive. `localAddress`, `localPort`, `remoteAddress`, `remotePort` and `shutdown()` were wrong on both JavaScript targets for the same reason, reaching for a sys socket's API. Node uses its own equivalents; a browser refuses and says why.
- `haxe.Timer.stamp()` returned a constant `0` on Node, so nothing that measured an interval measured one. The vendored shim branched on `js && !nodejs` for the browser and then on the `sys` define, which hxnodejs does not set, despite providing `Sys`, so Node fell all the way through to the final `return 0`. Frame cost, and so `cpuLoad`, read as zero; both timer schedulers based themselves at zero; and `Random`'s default seed, which is a stamp, was the same number on every run of every program. Both JavaScript targets now read `performance.now()`, which is monotonic and sub-millisecond where `Date.now()` is neither.
- `System.totalSystemMemory` and `freeSystemMemory` work on Node. They shell out through `sys.io.Process`, which hxnodejs has no runtime for, so on Node they compiled and then failed with `ReferenceError: sys is not defined`, worse than refusing, because the failure arrives at the call rather than at the build. Node reports both directly through `os.totalmem` and `os.freemem`, with no shell involved.
- `ByteArray` no longer corrupts its own storage on JavaScript. `__setData` adopted `bytes.getData()`, which on js is the `ArrayBuffer` underneath the storage rather than the `Uint8Array` that *is* the storage, so the result had none of the typed-array methods every read and write goes through and the first `blit` died on `b.set is not a function`. Being inline, the one site produced four. This affects the browser exactly as much as Node; nothing had run `ByteArray` on either until now.
- `PostgresConnection.escape` no longer doubles backslashes. It runs when there is no libpq connection to ask, and it escaped for a server with `standard_conforming_strings` off, a setting PostgreSQL has defaulted away from since 9.1. On any modern server a backslash carries no meaning inside an ordinary string literal, so doubling it stored two where the caller wrote one: `C:\Users` came back out as `C:\\Users`, silently corrupting paths, regular expressions and UNC names. Doubling the quote, which is the half that was always right, is unchanged.
- **Breaking.** `PostgresConnection.setSavepoint()` returns the savepoint's name, and the connection tracks the savepoints it holds. It returned nothing while `releaseSavepoint` and `rollbackToSavepoint` both required a name, so a savepoint created without one could never be reached again by any means, and calling release with no name minted a fresh name and asked the server to release a savepoint that had never existed. Both now act on the innermost savepoint when the name is omitted, releasing discards anything nested inside, rolling back keeps the savepoint as PostgreSQL does, and ending the transaction clears them. `rollbackToSavepoint()` with no name previously rolled back the entire transaction, losing everything before the savepoint the caller meant to return to; it now does that only when no savepoint is open.
- Generated Postgres savepoint names come from a counter rather than a truncated microsecond timestamp, the same defect fixed in `SQLiteConnection`: 2000 names generated back to back produced 47 duplicates, and the value overflows `Int` about 36 minutes into a process.
- A malformed Postgres result block no longer segfaults the process. `PostgresWire`'s cursor bounds-checked every read with `position + count > length`, which overflows `Int` for a large count and wraps negative, and a negative is not greater than the length, so the check passed and the read ran off the end of the buffer. Measured: a 20-byte block claiming a field name of 2147483647 bytes crashed the process, which is precisely the failure that cursor exists to turn into an exception. The check now measures against the bytes remaining, which cannot overflow.
- A Postgres result block can no longer claim more rows than it contains. A row of no columns reads nothing, so with a field count of zero the row loop was bounded by the claimed count alone rather than by the block holding anything: 20 bytes claiming twenty million rows allocated twenty million of them, and the count could have said two billion. Postgres does not return rows for a statement with no columns, so that combination is now refused, as are negative field and row counts, which previously decoded as an empty result rather than as the malformed block they are.
- `SQLiteConnection`'s async job queue is synchronised on every threaded target, not only cpp. The queue is written by whichever thread calls the connection and read by the worker; cpp used a `Deque` behind a `Mutex`, while neko, hl, java and jvm got a plain `Array` pushed and popped with no lock at all, on targets with real threads, and with both of the right types already imported in that same file.
- An idle async SQLite connection no longer spins. The non-cpp queue had no blocking read, so an empty queue fell through to `haxe.Timer.delay(fn, 0)`, which schedules rather than waits: on every target except hl and neko the worker burned a core doing nothing. The blocking `Deque` read removes the wait loop entirely.
- `SQLiteConnection.cancel()` no longer parks its worker thread forever. It replaced the queue object while the worker was blocked reading the old one, so the worker waited on a queue nothing would ever add to again, and every job queued afterwards went somewhere with no consumer and silently never ran. The queue is drained in place now and the worker woken so it can observe the cancellation.
- **Breaking.** `SQLiteConnection.setSavepoint()` returns the savepoint's name. It returned nothing, so a savepoint created without one could never be referred to again, and `releaseSavepoint()` with no name generated a *different* name and asked SQLite to release a savepoint that had never existed, which it refuses: `RELEASE sp_410; (Sqlite error : SQL logic error)`, measured against a real database. The no-argument savepoint API could not work at all.
- `SQLiteConnection` tracks its open savepoints, so `releaseSavepoint()` and `rollbackToSavepoint()` without a name act on the innermost one instead of minting a fresh one. `rollbackToSavepoint()` previously rolled back the entire transaction whenever the name was omitted, losing everything before the savepoint the caller meant to return to; it now does that only when no savepoint is open. Releasing discards the savepoint and anything nested inside it, rolling back keeps it, and committing or rolling back the transaction clears them all, matching what SQLite itself does.
- Generated savepoint names come from a counter rather than a truncated microsecond timestamp. The old scheme collided: 2000 names generated back to back produced 47 duplicates on cpp, and two savepoints sharing a name make `RELEASE` and `ROLLBACK TO` act on the wrong one. It also overflowed `Int` about 36 minutes into a process and wrapped every 72, so a long-lived connection reissued names it had already used.
- `SchemaMigrator` rolls back when the commit is what fails. The commit sat outside the try that guards a migration, so a commit that threw, a filled disk, a serialisation conflict, a connection lost between the last statement and this one, left the transaction neither committed nor undone, and the connection went back to its caller, and through a pool to the next borrower, still inside it. It also escaped as the driver's own error rather than the `SQLError` every other migration failure raises.
- `SchemaMigrator` releases its migration lock exactly once and no longer reports a successful run as a failure. The release sat inside the try, so a failure to release was caught by the handler that exists to release, unlocking a second time, and turning a run that had applied and recorded every migration into a thrown error. On a rolling deploy that is an instance refusing to start after successfully migrating, which is worse than the stuck lock it was reporting. The run's outcome is now reported as it happened and a failed release is logged.
- CORS preflights keep the connection alive and are built by the same path as every other response. `OPTIONS` wrote its response by hand and closed the socket, which was a deliberate deferral while keep-alive landed and left preflights outside every guarantee the builder makes: no one-response-per-request suppression, so a middleware that had already answered could be followed by a second response on the same connection; no check the socket was still connected; no log line, so preflights were invisible to an operator; no configured custom headers; and an unconditional close, costing a fresh connection, and a full TLS handshake where enabled, immediately before the request it was clearing.
- No `Content-Length` on a response that cannot carry a body. RFC 7230 3.3.2 forbids the header on a 1xx or 204 and 3.3.3 has the client end such a response at the blank line whatever the headers say, so it was both disallowed and redundant; 304 is treated the same, since `Content-Length: 0` there asserts a zero-length representation rather than describing the one the client already holds. Affects the preflight and the `If-Modified-Since` 304.
- `ConnectionPool` no longer opens past `maxSize`. Ownership was inferred from a borrowed-count rather than known, so `discard()` could not tell a connection the pool issued from one it never had, nor a second discard of one already retired, and it adjusted the accounting for all of them. Each spurious call credited the pool with a slot it never gave up, and once the open-count drifted below reality the ceiling stopped holding and the pool opened without limit, which is the one thing a pool exists to prevent. `discard()` of an already-released connection also closed it while leaving it in the idle list, so the next caller was handed a dead connection. Separately, a connection being validated was discounted for the whole unlocked validation window, letting a caller arriving mid-check see room that did not exist. The pool now tracks the connections it has issued, so a foreign or repeated return is ignored the way a repeated `release()` already was, and a connection stays counted while it is validated
- Named parameters are no longer substituted inside SQL comments or quoted identifiers. `ParamBinder` modelled single-quoted literals and nothing else, so a `:name` in a `--` line comment, a `/* */` block comment, a `"quoted identifier"` or a MySQL backtick identifier was replaced with an escaped value. The comment case is an injection regardless of how well the value is escaped, because quoting carries no meaning inside a comment: a value containing a newline ends it, and the remainder becomes statement text, `-- audit :note` with `x
OR 1=1 --` produced a query the server ran differently. All four drivers reach this on the `:name` API; Postgres `executeParams` binds natively and was never affected. Block comments nest, as Postgres does. Backslash escapes in literals and Postgres dollar-quoting remain unmodelled and are now documented on the class, since closing them needs a per-dialect scan rather than a shared one
- A file too large for `FileSystem.stat` to describe is refused rather than served wrong. `stat` reports an `Int`, which cannot express a size past 2 GB, and what it reports instead is target-specific: measured on Windows/cpp, files of 3 GB and 5 GB **both report 0**, indistinguishable from an empty file. The previous guard tested for a negative size, a wrap hxcpp does not produce, so on this target it never fired and every oversized file went past it. The reported length is now checked against the file itself, seek to it and read a byte, which a file of that length cannot supply, so it holds however a given target gets the size wrong, whether that is a wrap, a clamp, or a failed stat returning zero. Verified against real 3 GB and 5 GB files, which are now refused with a 500 naming the cause. Serving them properly needs 64-bit lengths Haxe does not have; this makes the limit visible instead of silent
- PHP source is no longer served as a static file when no bridge is configured. `phpEnabled` defaults to false, and the static path tested for the bridge and the extension together, so with PHP off a `.php` file was not executable, fell through, and was sent verbatim: `GET /config.php` answered **200 with the file**, credentials and all. Reachable in two ways on stock settings, directly and through `directoryIndex`, which leads with `index.php` so a directory request resolved to one. Both now answer 404, chosen over 403 so the reply is indistinguishable from one for a path that does not exist; the operator is told through a logged warning instead. The guard reuses `__isPhp` rather than repeating the extension test, so what may be executed and what may be sent as bytes cannot drift apart, and since it lowercases, `GET /config.PHP`, which opens the same file on Windows, does not get a second answer

- **a percent-encoded NUL in a request path could serve a blacklisted file.** Found while replacing the path decoder, and the more serious half of that change. Every filesystem call under `File` reaches a C API through the Haxe string's `char*` and therefore ends at the first NUL, while `blacklist` and `whitelist` compare whole strings, which do not, so `GET /secret.txt%00.html` was checked under the name `secret.txt\0.html`, matched no blacklist entry, and was then truncated by `exists()` and `load()` and served as `secret.txt`. The whitelist failed closed on the same request and the root containment check was never bypassed; it is the blacklist that failed open, which is the direction that matters. On cpp a *malformed* escape reached the same place without any `%00`: `urlDecode("/100%.html")` returned `/100`, a NUL, then `tml`, it consumed `.h` as the escape digits and emitted a zero byte, so a path did not even have to be trying. The decoder now refuses a decoded NUL with `400 Bad Request`, since no legitimate path carries one, rather than leaving every downstream use to defend itself. This is also why the same request now draws a `400` instead of a `404`
- a literal `+` in a request path no longer becomes a space. Paths were decoded with `StringTools.urlDecode`, which is form decoding, under it `+` means space, a rule RFC 3986 confines to query strings; in a path `+` is an ordinary character. So `GET /a+b.html` looked up `a b.html`, a file whose name genuinely contains `+` was unreachable by any spelling, sending `%2B` decoded correctly in the handler and was then corrupted anyway, because the rewrite engine's `normalize()` ran `urlDecode` a second time on the already-decoded path. Both decodes are replaced: the handler now runs a dedicated decoder that handles `%XX` escapes and nothing else, adjacent escapes are decoded as one byte run and read back as UTF-8, so `%C3%A9` still arrives as one character, and `normalize()` stops decoding entirely, since its input is the handler's output and a second decode turns the `+` and `%` a correct single decode legitimately leaves behind into a different name (`/100%.html`, the single decode of `/100%25.html`, re-read as a truncated escape). A malformed escape, truncated, or with a non-hex digit, is now answered `400 Bad Request`, which it never was: the `try`/`catch` around the old decode was dead code, because `urlDecode` does not raise on bad input, it drops the `%` and keeps going. `/oops%zz.html` was served as `oopszz.html` and `/100%.html` as `100.html`, so two spellings of a path silently named one file and a request no standard considers valid was answered as though it were. Double-encoded traversal needs no second decode to stay caught: `%252e%252e` decodes once to the literal text `%2e%2e`, which no filesystem reads as dots, it now draws the 404 of a name that does not exist rather than a manufactured 403. Query strings are untouched and keep form semantics, raw through `queryString` with `URLVariables` still reading `+` as a space there, which is where that rule belongs
- WebSockets could not work on the interpreter at all, and this removed one of the reasons. (Not the last: every session, a server's included, also drew a client key from `SecureRandom`, which the interpreter does not have, so a `ServerWebSocket` there accepted nothing, each upgrade threw in the accept tick and the peer was reset, as a raw handshake against eval, hl and neko showed.) The session drains its socket from a plain tick listener and never registers with the poll registry, so the very first read on an idle connection parked the interpreter, not on some unlucky payload size, but on every connection, immediately. `crossbyte.net.Socket` had the narrower form of the same fault: its read loop continues while a read exactly fills the 4096-byte buffer, so any message whose length was an exact multiple of 4096 blocked the runtime thread waiting for bytes that were not coming. Both loops are now gated on a zero-timeout `select` under `#if eval`. The root cause is that eval's `sys.net.Socket.setBlocking` is a no-op, it is a no-op in the Haxe standard library too, which is where this shim's copy came from, and it cannot be implemented on 4.3.7: eval exposes no per-socket blocking control and no bridge from a `NativeSocket` to the libuv handle that has one. That is now written down where the empty method body used to carry a `// TODO: Don't know how to implement this...`
- data received before a peer's EOF is delivered before the close is announced. When a final burst and the peer's FIN arrived in the same tick, `Socket.this_onTick` cleaned the socket and dispatched `CLOSE` first, then dispatched the pending data, at which point the socket was already null, so any listener that did the obvious thing and called `readBytes` got `"Operation attempted on invalid socket."`, and that `IOError` escaped through the event dispatch into the socket registry and killed the runtime loop. One disconnecting peer could take down every other connection in the process. This is target-independent and predates the interpreter work above; the eval gate merely made it easy to reach, because a gated loop sees the FIN as readable and forces the EOF read inside the same tick
- TLS on the interpreter is documented rather than fixed. The `select` gate is deliberately not applied to SSL-backed sockets: it sees the kernel socket, while mbedtls has already drained the TLS record and holds the decrypted plaintext in a buffer `select` cannot observe, so gating there would strand the tail of any record larger than the read buffer, permanently, since the descriptor never reads ready again. SSL sockets therefore keep read-until-short-read and its exact-multiple caveat. A `wss` handshake on interp can still park the runtime, and the obvious mitigation was measured and rejected: `setTimeout` does propagate and `SO_RCVTIMEO` expires on schedule, but eval raises the expiry as an OCaml `Unix_error` that no Haxe `catch` intercepts, not `haxe.Exception`, not `Dynamic`, so it would trade a stall for an uncatchable process death
- the `sys.net.Socket` shim's fallback branch claimed support for "cpp, hxcpp, and eval" in all sixteen of its throw messages, while a fully implemented java/jvm branch sat directly above it
- `next(405)` from middleware no longer emits `HTTP/1.1 405 OK`. `__statusMessage` had no entry for 405, and its default branch answers `OK`, so the one status a router or a metrics endpoint is most likely to raise by hand rendered a status line contradicting itself. `MetricsEndpoint` has been raising it since it landed. The remaining hole is unchanged and deliberate: any status not in the table still renders `OK`, so a thrown `418` reads as `HTTP/1.1 418 OK`, the table wants filling out, which is a larger change than this one
- receiving HTTP headers is no longer quadratic in how many pieces they arrive in. The completeness scan restarted from byte zero on every data event, so a header block trickling in paid for its own length once per arrival, measured at 7.6x on a 2 KB block arriving in 64-byte chunks, and growing without bound as the chunks shrink, which is the shape both a slow honest link and a deliberate byte-at-a-time client produce. The scan now resumes where it stopped, carrying its last three bytes across events so a `CRLFCRLF` split across arrivals is still seen; finding the block resets the carry, and so does clearing the buffer, since a resume offset into bytes that no longer exist would skip that much of the next request. Header lines were also built one `+=` per byte, a fresh string per character, and now accumulate in a `StringBuf` via `addChar`, which keeps the byte-for-byte semantics: no UTF-8 decoding, each byte one code point, so a header value carrying bytes above 0x7F reads back exactly as it arrived, and a test pins that

- URL rewrite backreference expansion no longer lets the request rewrite itself. `$1` through `$9` were substituted by one `String.replace` pass per group, and each pass reprocessed text the previous ones had already written: a path segment captured into `$1` whose own value contained the characters `$2` had that `$2` replaced by the next iteration, so a rule author writing `/user?name=$1&id=$2` against `/u/a$2b/ZZZ` got `/user?name=aZZZb&id=ZZZ`, part of the target chosen by the request rather than by the rule. Expansion is now a single left-to-right scan, which cannot revisit what it has emitted, and copies the runs between markers whole rather than a character at a time so a target carrying non-ASCII text is never taken apart. Traversal was never reachable this way, since `abs()` still confines every resolved path to the document root; what leaked was control over the rewritten target within it. mod_rewrite's numbering is deliberately kept: `$0` is not a group and `$10` reads as `$1` followed by a literal `0`, as does a group the pattern never captured, which stays as written
- rewrite rules are compiled once instead of once per request. `reMatch` built a fresh `EReg` for every rule on every request, `backrefs` built a second one for the rule that matched, and each `Method` or `Header` condition built another, so a request against a seven-rule config paid at least seven regular-expression compilations before it could be routed. Patterns come from configuration and never change, so they are now held compiled: 20,000 requests through a seven-rule set went from 154ms to 75ms (2.1×), while the match-and-expand path for the one rule that hits improved 1.2×. The cache is per thread rather than shared, because an `EReg` carries the result of its last `match()` and two runtime threads reading captures from one instance would read each other's; it is held in `Tls` on every target with real threads (cpp, neko, hl, java, jvm) and a plain static on the rest, matching the guard `HTTPBackendRegistry` uses for the same reason. Two maps rather than one keyed by pattern-plus-flag, since building a composite key would allocate per rule per request and give back most of what the cache saves. `backrefs` also stops prefixing patterns with an inline `(?i)` and uses the `i` flag `reMatch` already used, so both now agree and share one compiled expression
- `tryFiles` no longer re-runs filesystem probes whose answer is already known. `decide()` opens by testing the request path as a file and as a directory index and returns if either resolves, so by the time the `tryFiles` loop ran, its `$uri` and `$uri/` cases could not be true, they cost two `exists`/`isDirectory` pairs per request on every path that reaches a rewrite or a 404, and could never reach a different answer. They are skipped explicitly now, with literal entries still tried in order. Noted while doing this, not changed: because those two checks happen before the loop rather than within it, an entry's position in `tryFiles` does not affect when `$uri` is tried, so an nginx-style `["/override.html", "$uri"]` still serves `$uri` first. The default `["$uri", "$uri/", "/index.html"]` matches the hardcoded order, which is why this has never shown. Honouring the configured order is a routing-precedence change rather than a fix, and would alter behaviour for anyone whose config depends on the current one
- a failed OAuth token exchange now reaches the caller. `getAccessToken` and `refreshAccessToken` take an optional `onError`, and `callback` fires only on success, previously a rejected grant was logged and nothing else happened, which from the caller's side is indistinguishable from a request still in flight. The optional parameter keeps every existing call site compiling, and without one the failure is still logged exactly as before. Two silent successes are closed with it: a provider answering a rejected grant with an error document and a non-failing status used to be delivered as success carrying a token whose `accessToken` was null, which then failed somewhere later with nothing connecting it to the real cause; and `expires_in` sent as a string, which some providers do, went straight into an `Int` field. The reported message carries the provider's own `error`/`error_description` rather than just naming the operation. Verified the tests can fail by removing the `access_token` guard, which reproduces the original behaviour, including the delayed null dereference that made it hard to place
- `File.copyTo` no longer reports every failure as a missing file. It caught everything and rethrew `"File or directory does not exist."` (3003), so a permission denial, a full disk, or a file held open by another process all sent whoever read the error looking for the wrong thing. The source is now checked up front, so 3003 means what it says, and anything else is reported with the real cause and both paths. A failure inside a recursive call is passed through untouched rather than re-wrapped, since the inner one already names the path it happened on. Same class as the null-listing crash fixed earlier this release, where the reported cause was also not the real one
- a compile-time guard, `SuiteCoverage`, that fails the build when a test exists which nothing will run. Wired into every test hxml via `--macro`, it rejects three things: a `utest.Test` subclass registered in no `TestSuites` group, a group no other group calls, and, the one that kept recurring, a case with cpp-only conditional code that is not reachable from `addNativeSmoke`, whose guarded body therefore compiles nowhere it is registered. A genuinely hand-run harness can opt out with `@:suiteExempt("why")`, which requires stating the reason. Six instances of this shipped before it existed; on its first run it found a seventh, `FileStreamTest`, whose two async cases are guarded to skip on everything but cpp and so had never executed on any target
- **the jvm target had no CI at all.** Both entry points existed and neither was ever built or run: the workflow contained no reference to jvm or java. Three jvm defects were found and fixed by hand this release, a `PriorityQueue` `VerifyError`, a `SwitchTable` `ClassCastException`, and `Vector` `every`/`some`/`filter`, with nothing to stop them returning. A `Core | JVM Tests` job now builds and runs both suites on Java 8, the floor those `VerifyError` fixes were verified against. The full suite was red when the job was added, for the entry below; the smoke subset passing is exactly what let that stay unseen
- IPv6 addresses are reported in RFC 5952 canonical form on every target. `sys.net.Host.toString()` renders the loopback address as `::1` on hxcpp and `0:0:0:0:0:0:0:1` on the jvm, so `DatagramSocket.localAddress`, `remoteAddress` and the source address on a `DATA` event disagreed across targets, an application comparing what it bound against what it was told back worked on one and failed on the other. `IPv6.compress` lowercases, strips leading zeros, and collapses the longest run of zero groups; anything that is not a plain eight-group literal, including hostnames and IPv4 tails, is returned untouched
- `ByteArray.writeBytes` no longer zero-fills the region it is about to overwrite, measured at 14,342 → 19,908 MB/s on a 32 MB append (1.39×, from 48% to 62% of the memcpy floor; both binaries run back to back with their `blit` baselines within 6%). `__resize` takes an optional `overwriteFrom`, so an append, the whole of the bulk write path, skips the fill entirely, while a gap left by seeking past the end is still zeroed. The zeroing is **not** redundant in general, contrary to how this was first described: it is what stops a grown buffer exposing whatever the allocator last left in that memory, and removing it outright would have been a heap-disclosure bug
- `ByteArray` growth no longer exposes uninitialised memory on the eval target. Every other target swaps the underlying buffer and carries the zeroed region across with it; the eval shim copies into a `Bytes` whose storage never grew, so it did not, measured at 65,474 of 65,532 bytes non-zero on eval against 0 on cpp. `__resize` now zeroes the grown span explicitly there, after the logical length is set and starting from the pre-growth length rather than the capacity `__setData` leaves in `__length`; getting either of those wrong is not academic, since the first attempt dropped the write entirely and the second left a stale byte at index 1. The growth tests no longer skip on eval
- `File.deleteDirectory` on a path that no longer exists took the process down on native targets instead of throwing. hxcpp's `sys_read_dir` answers a directory it cannot open with `null` rather than raising, `sys.FileSystem.readDirectory` passes that straight through, and `for (item in ...)` then dereferenced it, a segfault, so past any `catch` the caller wrote. That is what disguised it as a `moveTo` bug: the crash landed on the `try source.deleteDirectory(true) catch (_) {}` teardown line, after `moveTo` had already copied, deleted and returned successfully. Every listing in `File`, `deleteDirectory`, `__deletePath`, `getDirectoryListing` and the async worker, now goes through one helper that turns the null into the same catchable `Error` on every target; `__canonicalize` had guarded for this all along, in exactly one place. This crash is what had kept `FileTest`, and with it the whole of `addIO`, from running on any native target
- `CrossByte.pump()` on a runtime that had already exited claimed the calling thread and never gave it back. It published `this` into the thread-local current-runtime slot and rebound the thread's timer scheduler *before* reading the stop flag, and the hand-back inside `__finalizeExit` is guarded by `__didExit`, which had already been set, so from that call onward `CrossByte.current()` returned a runtime that could never tick again. Anything resolving the current runtime afterwards attached to the dead one: a `Worker`'s completion listener, a timer, a socket registration. None of them ran, and nothing was raised to say so. `pump()` now reads the stop flag before it claims anything, and hands the slot back if it already holds this stopped instance. Found through `NativeProcessTest`, which pumped 17,268 times across 30 seconds without one tick reaching it, and which had only started failing because utest's fixture order, which shifts when cases are added, put the case that deliberately pumps an exited runtime ahead of it. The defect was in the runtime the whole time, not in the test's timing budget. Noted while doing this, not fixed: `Worker` delivers exactly one queued message per tick, so a worker producing a burst of progress events drains at tick rate rather than as fast as the host pumps
- no `trace()` calls remain in library code. `OAuth`'s two token-request failures went to unfilterable stdout and now log at `Logger.error`; the HTTP header dump stays behind `#if http_debug` but routes through `Logger` so that when enabled it honours the configured level and sink. The `trace` calls left in `File` and `URLVariables` are documentation examples inside doc comments and are meant to stay. Noted while doing this, not fixed: `OAuth`'s error handlers log and never invoke the caller's callback, so a failed token exchange is indistinguishable from one still in flight, surfacing it needs an error callback and so a signature change
- "the socket would block" was recognised four different ways, and every call site covered a different subset. The condition arrives as `haxe.io.Error.Blocked`, wrapped in `Error.Custom` by the hxcpp debugger, or as the bare strings `"Blocking"` or `"Blocked"` from the TLS layer, which throws before anything maps it to a type, and the checks were written out by hand in `Socket`, `ServerSocket`, `ServerWebSocket`, `DatagramSocket` and the internal `WebSocket`, two of them verbatim duplicates. Missing a spelling is not cosmetic: a would-block read as fatal closes a healthy connection, and one read as success silently discards what was being written. Both have shipped here. `BlockedError.isBlocked` is now the single predicate, and the jvm-specific branch `ServerWebSocket` carried for it is gone, the enum match that mis-compiled inside a `catch` now lives in a plain static function where that does not apply
- **a socket that blocked twice in a row stranded whatever it still held.** The socket registry drains its writable queue with `forEach` and then clears it, but a socket that is still blocked re-queues itself from inside that dispatch, so the clear discarded the re-queue and the socket was never retried again. Silent: no error, no close, indistinguishable to the peer from data that was never sent. Both registries now swap the queue before draining. A 4 MB write to a slowly-draining peer previously delivered 2.8 MB and timed out; it now completes in 3 ms
- a blocked write retried through the global timer instead of the queue the registry already provides. A partial write called `__queueWrite()`, but a fully blocked one used `Timer.delay(__tryFlush, 0)`, two mechanisms for one job, and the timer was the one whose exception unwound through the tick dispatch and stopped the whole runtime loop rather than failing one connection. Both paths now use the queue. `registryOnWritable` also had to call `__tryFlush` rather than `flush`, since `flush` returns early while a blocked retry is outstanding and so could never have recovered a fully blocked socket
- three more test groups had never run their native cases. `addDatabase`, `addIPC` and `addUtils` were registered only in `addAll`, which runs on the interpreter, so their `#if cpp` bodies compiled out where they were registered and were unregistered where they compiled, the same gap that hid the asymmetric JWT suite. Running them surfaced two stale assertions that had been wrong since the native Postgres bridge landed (`PostgresConnection.isSupported` is `true` on cpp, and both `PostgresConnectionTest` and `DBSupportTest` asserted `false`), and one that could never have held: `pragmaList()` was asserted to contain `page_size`, but `PRAGMA pragma_list` returns nothing on the SQLite hxcpp bundles (3.23.1), so the call yields an empty array on every native build
- the asymmetric JWT tests had never run. `PkJwtTest`'s RS256/ES256 cases are guarded `#if (cpp && windows)` because they need the mbedTLS bridge, but they were registered only through `addAuth`, which the native smoke suite, the one place that combination is built, did not call. So they compiled out everywhere they were registered and were unregistered where they compiled. The native suite now includes `addAuth`; the cases pass, and were correct all along
- **a WebSocket server could not receive messages from a client.** The handshake request was parsed out of the input buffer with `getString`, which does not advance the cursor, and the post-handshake cleanup only reset that cursor when the buffer looked empty, which it never did. The request bytes therefore stayed in the buffer, so the first frame the peer sent was parsed starting at the `G` of `GET`; `0x47` has RSV1 set, so the session was closed with 1002 as a protocol error. Every server-side session dropped the client's first message and the connection with it. The handshake bytes are now discarded once the upgrade completes, with any pipelined data preserved. Nothing caught this because the frame-level tests construct sessions directly and skip the handshake, and the one exercise that did cover the real path, the websocket echo sample, was compiled in CI and never run. Built against the pre-fix source that sample fails outright, so executing it would have caught this on the commit that introduced it; it now runs in CI
- jvm: `PriorityQueue` produced invalid bytecode (`VerifyError` on Java 8), a bound method reference inside the `@:generic` specialization; replaced with a capture-free comparator lambda
- jvm: `SwitchTable.make` dispatchers with mixed String/Int keys crashed with `ClassCastException`, a Dynamic-subject switch containing an Int case coerces the subject with `Jvm.toInt`; the macro now emits an if-chain through Dynamic-typed comparison/dispatch helpers
- jvm: `Vector` `every`/`some`/`filter` always returned false/empty, `Reflect.callMethod` arity-mismatch behavior differs on jvm, breaking the callback-arity fallback; the closure's real arity is now resolved reflectively and called directly
- with these fixes the jvm smoke suite passes fully on Java 8 (previously: 4 `VerifyError`s plus 2 failing tests)
- `haxe.Timer` allocated its id from a static counter outside the lock guarding the timer map, so two threads creating timers concurrently could take the same id and the second registration evicted the first, a timer that silently never fired
- `HTTPBackendRegistry` mutated a shared array without synchronization while `resolve()` read it from request threads; mutation now publishes a new array under a lock and lookups iterate a stable snapshot
- `ProcessLifecycle` guards its callback list, so registering from a worker thread while the runtime thread dispatches can no longer drop or double-run a callback
- a WebSocket TLS handshake that failed with a typed non-`Blocked` error was treated as a *successful* one and promoted to an open session; terminal failures now close immediately instead of idling until the deadline
- `ServerWebSocket.bind()` did not resolve an ephemeral port: binding to 0 left `localPort` at 0, so callers could not discover the assigned port
- the WebSocket read loop discarded the last message before a disconnect. Whether buffered bytes got delivered was decided inside the loop's `catch` branches, so a pass that read a complete frame and then left through `nBytes <= 0`, how a closed peer reads on some targets, dropped that frame entirely. Delivery and closing were also alternatives rather than sequential, so data followed by a disconnect lost the data, and data followed by a genuine error skipped the close and left a failed session open. Delivery is now keyed on how many bytes were actually read, and happens before the close is applied. The final message before a disconnect is the one most worth keeping, a goodbye, a last ack, and losing it is indistinguishable to the application from the peer never having sent it
- a normal WebSocket disconnect no longer prints `Error Reason:,Eof` and `closed from remote host` through `trace`. A clean TCP FIN is ordinary, not a failure, and unfilterable trace output is noise in any real deployment; remote closes and heartbeat timeouts now go to `Logger.debug`, and only genuine read failures log at `warn`
- a socket closed while a write was still blocked took down the whole runtime loop. A blocked write schedules its retry with `Timer.delay`, and if the socket closed before that fired, peer disconnect, application close, or the overflow policy, the retry called `flush()` on a released socket and raised. Because the retry runs inside the runtime's tick dispatch, the exception escaped `pump()` and stopped the loop serving *every other connection* rather than failing the one. The retry now finds nothing to do instead of raising
- the WebSocket write path mishandled a full socket send buffer in both directions: `__writeBytes` caught the blocked write and only traced it, silently discarding the bytes, while `__sendFrame` treated the same transient condition as fatal and closed the session with 1006. A send buffer that is momentarily full is normal on a non-blocking socket and is neither a licence to drop data nor an error; both paths now retain the unwritten remainder, honour partial writes, and retry on the next tick, closing only on a genuine I/O failure

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
