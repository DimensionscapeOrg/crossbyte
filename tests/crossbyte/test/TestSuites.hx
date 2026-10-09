package crossbyte.test;

import utest.Runner;

class TestSuites {
	public static function addAuth(runner:Runner):Void {
		runner.addCase(new crossbyte.auth.AuthSupportTest());
		runner.addCase(new crossbyte.auth.OAuthExchangeTest());
		runner.addCase(new crossbyte.auth.jwt.JWTTest());
		runner.addCase(new crossbyte.auth.jwt.JWTVerifyTest());
		runner.addCase(new crossbyte.auth.jwt.JWTClaimsTest());
		runner.addCase(new crossbyte.auth.jwt.EdDSAJwtTest());
		runner.addCase(new crossbyte.auth.jwt.PkJwtTest());
		runner.addCase(new crossbyte.auth.jwt.JWKSetTest());
		runner.addCase(new crossbyte.auth.jwt.JWTTypesTest());
		runner.addCase(new crossbyte.auth.jwt.Base64UrlTest());
	}

	public static function addCrypto(runner:Runner):Void {
		runner.addCase(new crossbyte.crypto.CryptoTest());
		runner.addCase(new crossbyte.crypto.SodiumExpansionTest());
		runner.addCase(new crossbyte.crypto.SignatureKeyTest());
		runner.addCase(new crossbyte.crypto.password.BCryptHardeningTest());
		runner.addCase(new crossbyte.crypto.password.BCryptVectorsTest());
		runner.addCase(new crossbyte.crypto.password.BCryptByteVectorsTest());
		runner.addCase(new crossbyte.crypto.password.PasswordOffloadTest());
		runner.addCase(new crossbyte.crypto.SecureRandomTest());
		runner.addCase(new crossbyte.crypto.HmacSha256Test());
	}

	public static function addCore(runner:Runner):Void {
		runner.addCase(new crossbyte.FutureTest());
		runner.addCase(new crossbyte.core.CrossByteTest());
		runner.addCase(new crossbyte.core.CrossByteRunningFlagTest());
		runner.addCase(new crossbyte.core.ConfigTest());
		runner.addCase(new crossbyte.core.SocketCapacityTest());
		runner.addCase(new crossbyte.core.FixedStepTest());
		runner.addCase(new crossbyte.core.PassFlushTest());
		runner.addCase(new crossbyte.core.UncaughtErrorTest());
		runner.addCase(new crossbyte.core.RuntimeTimersTest());
		runner.addCase(new crossbyte.core.ApplicationTest());
		runner.addCase(new crossbyte.core.ChildRuntimeTest());
		runner.addCase(new crossbyte.core.PostTest());
		runner.addCase(new crossbyte.core.RuntimeHealthTest());
		runner.addCase(new crossbyte.core.IdleCollectorTest());
	}

	public static function addFoundation(runner:Runner):Void {
		runner.addCase(new crossbyte.foundation.FoundationConstructsTest());
		runner.addCase(new crossbyte.foundation.Seq32Test());
	}

	public static function addErrors(runner:Runner):Void {
		runner.addCase(new crossbyte.errors.ErrorsTest());
	}

	public static function addEvents(runner:Runner):Void {
		runner.addCase(new crossbyte.events.EventDispatcherTest());
		runner.addCase(new crossbyte.events.EventsSupportTest());
		// Also in PortableSuite: typed event-type constants refuse a listener
		// of the wrong event at compile time.
		runner.addCase(new crossbyte.events.EventTypesTest());
		// Also in PortableSuite: "copy it to keep it": clone() copies, and
		// what each define does to an event and its payload.
		runner.addCase(new crossbyte.events.ArrivalsTest());
	}

	public static function addDataStructures(runner:Runner):Void {
		runner.addCase(new crossbyte.ds.Array2DTest());
		runner.addCase(new crossbyte.ds.CollectionsTest());
		runner.addCase(new crossbyte.ds.PriorityQueueTest());
		runner.addCase(new crossbyte.ds.BitSetTest());
		runner.addCase(new crossbyte.ds.SequenceRingTest());
		runner.addCase(new crossbyte.ds.InterestSetTest());
		runner.addCase(new crossbyte.ds.IdListTest());
		runner.addCase(new crossbyte.ds.QuadTreeTest());
		runner.addCase(new crossbyte.ds.SpatialGridTest());
		runner.addCase(new crossbyte.ds.SpatialGrid3DTest());
		runner.addCase(new crossbyte.ds.BloomFilterTest());
		runner.addCase(new crossbyte.ds.OrderedMapTest());
		runner.addCase(new crossbyte.ds.BitmapDataTest());
		runner.addCase(new crossbyte._internal.compression.CompressionRoundTripTest());
		runner.addCase(new crossbyte._internal.compression.BrotliCodecTest());
		runner.addCase(new crossbyte._internal.compression.CodecFormatsTest());
		// Also in PortableSuite: typed pairs, callbacks and SwitchTable lookups.
		runner.addCase(new crossbyte.ds.TypedShapesTest());
	}

	public static function addHttp(runner:Runner):Void {
		// The server half lives in its own class so a JavaScript build can name
		// it without dragging all of TestSuites in behind it.
		ServerSuite.add(runner);

		// HPACK is pure byte manipulation (no socket, no thread), so unlike
		// the client below it means the same thing on every target, browser
		// included. Also in PortableSuite, which is how js reaches it.
		runner.addCase(new crossbyte.fuzz.ParserFuzzTest());
		runner.addCase(new crossbyte._internal.http.CookieJarTest());
		runner.addCase(new crossbyte._internal.http.PublicKeyPinsTest());
		runner.addCase(new crossbyte._internal.http.h2.hpack.HpackTest());
		runner.addCase(new crossbyte._internal.http.h2.H2Test());
		runner.addCase(new crossbyte._internal.http.h2.H2ServerTest());

		#if !js
		// The client, which drives a raw socket with its own TLS and so exists
		// on no JavaScript target. Its test also spawns threads.
		runner.addCase(new crossbyte._internal.http.HttpTest());
		// The threads URLLoader's loads run on.
		runner.addCase(new crossbyte._internal.http.LoadPoolTest());
		// The backend end to end, which needs a listening socket and a thread,
		// so it sits with the client rather than in PortableSuite. On eval
		// too, since a reset there is an error a catch can see.
		runner.addCase(new crossbyte.http.HTTP2BackendTest());
		#end

		#if cpp
		// The URL group, for the native suite, which calls this and not
		// addURL: the one target where the loader's worker is a real thread.
		// addAll, which also calls addURL, never runs on cpp.
		addURL(runner);
		#end
	}

	public static function addIO(runner:Runner):Void {
		runner.addCase(new crossbyte.io.StoreTest());
		runner.addCase(new crossbyte.io.ByteArrayTest());
		runner.addCase(new crossbyte.io.ByteArrayInputTest());
		runner.addCase(new crossbyte.io.ByteArrayIOTest());
		runner.addCase(new crossbyte.io.ByteArrayOutputTest());
		runner.addCase(new crossbyte.io.FileTest());
		// Red team: a datagram saved to a file from its listener.
		runner.addCase(new crossbyte.io.FileArrivalTest());
		runner.addCase(new crossbyte.io.FilePathTest());
		runner.addCase(new crossbyte.io.FileStreamTest());
		runner.addCase(new crossbyte.io.FileStreamContractTest());
		runner.addCase(new crossbyte.io.FileStreamAsyncRefusalTest());
		runner.addCase(new crossbyte.io.ByteArrayCorrectnessTest());
		runner.addCase(new crossbyte.io.ByteDeltaTest());
		runner.addCase(new crossbyte.io.BitPackingTest());
	}

	public static function addURL(runner:Runner):Void {
		runner.addCase(new crossbyte.url.URLTest());
		runner.addCase(new crossbyte.url.URLLoaderHttpTest());
		// Red team: a datagram forwarded as a request body from its listener.
		runner.addCase(new crossbyte.url.URLLoaderArrivalTest());
		runner.addCase(new crossbyte.url.URLLoaderTest());
		runner.addCase(new crossbyte.url.URLVariablesTest());
		// Registered for the browser, which reaches it through PortableSuite;
		// written here too so the one list describes everything that runs.
		#if (js && !nodejs)
		runner.addCase(new crossbyte.url.URLLoaderBrowserTest());
		#end
	}

	public static function addMath(runner:Runner):Void {
		runner.addCase(new crossbyte.math.MathTest());
	}

	public static function addIPC(runner:Runner):Void {
		runner.addCase(new crossbyte.ipc.LocalConnectionTest());
		runner.addCase(new crossbyte.ipc.SharedChannelTest());
		runner.addCase(new crossbyte.ipc.SharedObjectTest());
		runner.addCase(new crossbyte.ipc.LocalConnectionSendGuardTest());
	}

	public static function addDatabase(runner:Runner):Void {
		runner.addCase(new crossbyte.db.DBSupportTest());
		runner.addCase(new crossbyte.db.PostgresConnectionTest());
		runner.addCase(new crossbyte.db.MongoConnectionTest());
		runner.addCase(new crossbyte.db.DBParameterBindingTest());
		runner.addCase(new crossbyte.db.ConnectionPoolTest());
		runner.addCase(new crossbyte.db.ConnectionPoolMetricsTest());
		runner.addCase(new crossbyte.db.SchemaMigratorTest());
		runner.addCase(new crossbyte.db.PostgresWireTest());
		runner.addCase(new crossbyte.db.PostgresConnInfoTest());
		// MongoDB: the codec, Extended JSON, SCRAM and connection strings need
		// nothing but bytes, and are in PortableSuite too; the rest talk to
		// FakeMongoServer, a thread speaking OP_MSG, so no server is needed.
		runner.addCase(new crossbyte.db.mongodb.BsonTest());
		runner.addCase(new crossbyte.db.mongodb.ExtendedJsonTest());
		runner.addCase(new crossbyte.db.mongodb.ScramTest());
		runner.addCase(new crossbyte.db.mongodb.MongoUriTest());
		runner.addCase(new crossbyte.db.mongodb.MongoWireTest());
		runner.addCase(new crossbyte.db.mongodb.MongoCrudTest());
		runner.addCase(new crossbyte.db.mongodb.MongoTransactionTest());
		// TCP keepalive on the clients' sockets, and a server gone silent as a
		// partitioned host does (Linux, through DeadPeerProbe).
		runner.addCase(new crossbyte.db.DatabaseKeepAliveTest());
		runner.addCase(new crossbyte.db.MySQLDriverTest());
		runner.addCase(new crossbyte.db.SQLiteDriverTest());
		runner.addCase(new crossbyte.db.ItemClassTest());
		#if !cpp
		// The same failures on cpp go through libpq, and are covered against
		// its stand-in by NativePostgresBridgeTest below.
		runner.addCase(new crossbyte.db.TransactionFailureTest());
		#end
		#if target.threaded
		// Where the worker pool has threads, and so a queue to bound: every
		// target but JavaScript.
		runner.addCase(new crossbyte.db.AsyncDatabaseTest());
		#end
		#if cpp
		// Against a libpq stand-in built beside the test binary, so the
		// bridge's threading and its GC-free zones are checked without a
		// server.
		runner.addCase(new crossbyte.db.NativePostgresBridgeTest());
		// The native MySQL client against a server that logs every byte it
		// is sent (fakemysql/FakeMySQLServer), so no database is needed.
		runner.addCase(new crossbyte.db.MySQLNativeWireTest());
		runner.addCase(new crossbyte.db.MySQLNativeResultTest());
		runner.addCase(new crossbyte.db.MySQLNativeSessionTest());
		runner.addCase(new crossbyte.db.MySQLNativeAuthTest());
		// Answers no MySQL server sends: counts and lengths a hostile one, or
		// whoever answers in its place, can put in a packet.
		runner.addCase(new crossbyte.db.MySQLNativeHostileTest());
		// SQLite opens only natively.
		runner.addCase(new crossbyte.db.SQLiteNativeTest());
		// Red team: a datagram stored as a blob from its listener.
		runner.addCase(new crossbyte.db.SQLiteArrivalTest());
		#end
		// The fixed-slot objects rows and documents are built as.
		runner.addCase(new crossbyte._internal.AnonBuilderTest());
		// Rows read by column, Postgres's result block, statement templates.
		runner.addCase(new crossbyte.db.SQLRowTest());
		#if cpp
		// SQLite statements prepared once, their values bound, rows read by column.
		runner.addCase(new crossbyte.db.SQLiteBindingTest());
		#end
		// The MongoDB driver's public types, decided at compile time.
		runner.addCase(new crossbyte.db.mongodb.MongoApiTest());
	}

	public static function addSystem(runner:Runner):Void {
		runner.addCase(new crossbyte.sys.NativeProcessTest());
		runner.addCase(new crossbyte.sys.ProcessLifecycleTest());
		runner.addCase(new crossbyte.sys.ChildProcessSocketTest());
		runner.addCase(new crossbyte.sys.SysSupportTest());
		runner.addCase(new crossbyte.sys.SystemTest());
		runner.addCase(new crossbyte.sys.WorkerTest());
		runner.addCase(new crossbyte.sys.TaskPoolTest());
		// JavaScript's, reached there through PortableSuite; empty elsewhere.
		runner.addCase(new crossbyte.sys.BackgroundDeliveryTest());
	}

	public static function addNet(runner:Runner):Void {
		runner.addCase(new crossbyte.net.DatagramSocketTest());
		// What a datagram listener is handed, sends back and keeps, over real
		// sockets; asynchronous, and also in PortableSuite for Node's path.
		runner.addCase(new crossbyte.net.DatagramArrivalTest());
		// Native only, like DatagramSocketTest beside it. These cases pump the
		// runtime to wait for a datagram, and pumping means Sys.sleep, which on
		// node blocks the very loop the socket is delivered on, so the query
		// would never complete and every case would time out.
		runner.addCase(new crossbyte.net.StunClientTest());
		runner.addCase(new crossbyte.net.SysSocketTimeoutTest());
		runner.addCase(new crossbyte.net.SysSocketEofTest());
		// Every sys target: a reset connection must not end the process on eval.
		runner.addCase(new crossbyte.net.SysSocketResetTest());
		runner.addCase(new crossbyte.cluster.SnowflakeIdTest());
		runner.addCase(new crossbyte.cluster.RendezvousTest());
		runner.addCase(new crossbyte.cluster.MembershipTest());
		runner.addCase(new crossbyte.net.FrameCodecTest());
		runner.addCase(new crossbyte.net.PeerClockTest());
		runner.addCase(new crossbyte.net.EndpointTest());
		runner.addCase(new crossbyte.net.NetConnectionTest());
		// Also in PortableSuite: a TCP NetConnection carries its messages on Node too.
		runner.addCase(new crossbyte.net.NetConnectionTcpTest());
		// Also in PortableSuite: one end, told once, over TCP and WebSocket.
		runner.addCase(new crossbyte.net.NetConnectionLifecycleTest());
		runner.addCase(new crossbyte.net.NetConnectionSchemeTest());
		// Also in PortableSuite: on Node a child runtime's clock is not the
		// application's.
		runner.addCase(new crossbyte.net.NetConnectionClockTest());
		// Every threaded target: a close made from a second thread.
		runner.addCase(new crossbyte.net.CrossThreadCloseTest());
		// Reads the networking tests' own source: what they wait by.
		runner.addCase(new crossbyte.net.NetTestClockTest());
		runner.addCase(new crossbyte.net.NetHostTest());
		// Also in PortableSuite: a URI host on port 0, which Node binds later.
		runner.addCase(new crossbyte.net.NetHostUriTest());
		// Also in PortableSuite, for Node's wss server.
		runner.addCase(new crossbyte.net.NetHostTLSTest());
		// Also in PortableSuite: a key's PEM is not printed in plain view on Node.
		runner.addCase(new crossbyte.net.KeyTest());
		runner.addCase(new crossbyte._internal.socket.poll.PollBackendRegistryTest());
		runner.addCase(new crossbyte._internal.socket.poll.PollBackendSeamTest());
		// Every threaded target: a runtime woken while it closes its wake.
		runner.addCase(new crossbyte._internal.socket.poll.WakeSocketTest());
		runner.addCase(new crossbyte._internal.socket.FlexSocketTest());
		runner.addCase(new crossbyte._internal.socket.BlockedErrorTest());
		runner.addCase(new crossbyte._internal.net.IPv6Test());
		// Every threaded target: what lookups cost the process, through a
		// system lookup the case controls.
		runner.addCase(new crossbyte._internal.net.ResolverTest());
		runner.addCase(new crossbyte.net.StunMessageTest());
		runner.addCase(new crossbyte.net.StunQueryTest());
		runner.addCase(new crossbyte.net.TurnClientTest());
		// Real sockets, so not portable: a relay reached over TCP or TLS.
		runner.addCase(new crossbyte.net.TurnStreamTest());
		runner.addCase(new crossbyte.net.rtc.DtlsCertificateTest());
		runner.addCase(new crossbyte.net.rtc.DtlsTransportTest());
		runner.addCase(new crossbyte.net.rtc.ClientHelloAssemblyTest());
		runner.addCase(new crossbyte.net.rtc.SctpPacketTest());
		runner.addCase(new crossbyte.net.rtc.SctpAssociationTest());
		runner.addCase(new crossbyte.net.rtc.SctpDataTransferTest());
		// Beside it for the reason the WebSocket wire fuzzer sits beside the
		// conformance cases: those cover the shapes someone named, this covers
		// what the receiver is still holding once the traffic stops.
		runner.addCase(new crossbyte.fuzz.SctpWireFuzzTest());
		runner.addCase(new crossbyte.net.rtc.DataChannelTest());
		runner.addCase(new crossbyte.net.rtc.SessionDescriptionTest());
		runner.addCase(new crossbyte.net.ice.IceCandidateTest());
		runner.addCase(new crossbyte.net.ice.IceAgentTest());
		// Real sockets, so this one is not portable and is not in the
		// portable list. It is the join between the agent and the socket it
		// has to run on, which no amount of in-memory testing reaches.
		runner.addCase(new crossbyte.net.ice.IceOverDatagramTest());
		// The capstone: the whole stack over real sockets. Real sockets is
		// also why it is here and not in the portable list.
		runner.addCase(new crossbyte.net.rtc.PeerConnectionTest());
		runner.addCase(new crossbyte.net.rtc.PeerConnectionGatheringTest());
		runner.addCase(new crossbyte.net.rtc.PeerConnectionRelayTest());
		runner.addCase(new crossbyte.net.rtc.PeerConnectionHostTest());
		// Needs no guard here: this group never runs on a JavaScript target,
		// and everywhere it does run the class exists. Its first case is the
		// one that matters most: it asserts that the support flag and the
		// behaviour agree, which is how the interpreter and neko earn a real
		// assertion out of having no UDP at all rather than a skip.
		runner.addCase(new crossbyte.net.LocalAddressTest());
		runner.addCase(new crossbyte.net.ReliableDatagramProtocolTest());
		// The cipher an encrypted session seals with, against RFC 8439 and
		// OpenSSL. Also in PortableSuite, for Node's crypto and the browser.
		runner.addCase(new crossbyte.net.ReliableDatagramCipherTest());
		runner.addCase(new crossbyte.net.ReliableDatagramSocketTest());
		runner.addCase(new crossbyte.net.ReliableDatagramLifecycleTest());
		runner.addCase(new crossbyte.net.SocketCloseTest());
		runner.addCase(new crossbyte.net.SocketHalfOpenTest());
		// Also in PortableSuite, for Node's sockets.
		runner.addCase(new crossbyte.net.SocketObjectTest());
		// Also in PortableSuite, for Node's sockets.
		runner.addCase(new crossbyte.net.SocketContractTest());
		// Also in PortableSuite: Node's replaced socket must report nothing more.
		runner.addCase(new crossbyte.net.SocketReconnectTest());
		// What a closed connection leaves in the registry: on the jvm and
		// natively measured by what the collector can take, elsewhere by
		// searching the registry for it.
		runner.addCase(new crossbyte.net.SocketRetentionTest());
		// More sockets than one select can name, on neko too.
		runner.addCase(new crossbyte.net.SocketRegistryScaleTest());
		// Sockets numbered past select's FD_SETSIZE, which natively on Linux
		// and macOS must still be asked about.
		runner.addCase(new crossbyte.net.DescriptorCeilingTest());
		runner.addCase(new crossbyte.net.NameLookupTest());
		runner.addCase(new crossbyte.net.ServerSocketAcceptTest());
		// Also in PortableSuite: most of it is Node's listener.
		runner.addCase(new crossbyte.net.ServerSocketListenTest());
		runner.addCase(new crossbyte.net.ServerSocketBacklogTest());
		// An accept that fails sets the listener aside rather than spinning:
		// every threaded target, and natively on Linux and macOS out of
		// descriptors for real.
		runner.addCase(new crossbyte.net.ServerSocketAcceptBackoffTest());
		// A raw server's connection limit and a TLS server's handshakes per
		// address, and a NetHost's. Also in PortableSuite, for Node.
		runner.addCase(new crossbyte.net.ServerSocketLimitsTest());
		// A child runtime's real POLL loop, so every threaded target.
		runner.addCase(new crossbyte.net.SocketReadinessTest());
		// One listener's connections on several runtimes: every threaded
		// target, its TLS cases natively and on the jvm.
		runner.addCase(new crossbyte.net.ServerSpreadTest());
		runner.addCase(new crossbyte.net.ServerWebSocketSpreadTest());
		// Deliberately unguarded: the exact-buffer read-loop hang it protects
		// against lives on the interpreter, where sockets cannot be made
		// non-blocking. Guarding it to cpp would run it only where the bug
		// cannot happen.
		runner.addCase(new crossbyte.net.SocketExactBufferReadTest());
		// Registered outside the socket gate below. Most of its cases need a
		// listening socket and are guarded inside the class, but its jvm branch
		// only asserts that constructing a secure ServerSocket throws, and
		// registered under `#if cpp` that branch would compile on jvm and run on
		// nothing. A case that executes nowhere reads as protection while
		// providing none.
		runner.addCase(new crossbyte.net.ServerSocketTLSTest());
		// Which TLS version hxcpp's mbedTLS negotiates, against itself and
		// against Node's OpenSSL, and TLS 1.3 resumption. The class is cpp only.
		#if cpp
		runner.addCase(new crossbyte.net.TlsProtocolTest());
		#end
		// The jvm's own TLS backend and socket shim, against the JDK's TLS
		// stack and raw NIO: chains, failures and what connections cost.
		#if (java || jvm)
		runner.addCase(new crossbyte.net.JvmTlsTest());
		runner.addCase(new crossbyte.net.JvmSocketTest());
		#end

		// jvm as well as cpp, which finds faults a cpp-only run cannot: a
		// listener ignoring setBlocking(false) called before bind(), so that the
		// first accept() on an idle port blocks the runtime's own thread; and
		// TCP addresses reported uncompressed, which no UDP case could catch
		// because DatagramSocket canonicalises and the socket beside it might not.
		#if (cpp || java || jvm)
		runner.addCase(new crossbyte.cluster.NodeChannelTest());
		// What a message waits as, queued or held for the pass: a copy.
		runner.addCase(new crossbyte.cluster.NodeChannelKeeperTest());
		runner.addCase(new crossbyte.net.SocketTest());
		runner.addCase(new crossbyte.net.ServerSocketDrainTest());
		runner.addCase(new crossbyte.net.ServerWebSocketDrainTest());
		// Needs real sockets: these drive the server with a hand-written
		// client rather than CrossByte's own, which is the only way a fault
		// specific to a foreign peer shows up.
		runner.addCase(new crossbyte.net.WebSocketConformanceTest());
		// Beside it on purpose: the conformance cases cover the violations
		// someone named, and this covers the ones nobody did. Same hand-written
		// client, same gate: both drive the server through a real socket.
		runner.addCase(new crossbyte.fuzz.WebSocketWireFuzzTest());
		// Not on eval, whose TLS handshake cannot be made non-blocking.
		runner.addCase(new crossbyte.net.WebSocketTLSTest());
		// The server's half: its certificate, SNI, ALPN and client
		// certificates. Also in PortableSuite, for Node.
		runner.addCase(new crossbyte.net.ServerWebSocketTLSTest());
		// A plain Socket over TLS, likewise; also in PortableSuite, for Node.
		runner.addCase(new crossbyte.net.SocketTLSClientTest());
		runner.addCase(new crossbyte.net.WebSocketClientTest());
		runner.addCase(new crossbyte.net.WebSocketSessionTest());
		// A message's call, every way to send it back, and what a listener
		// keeps. Also in PortableSuite, for Node's sessions.
		runner.addCase(new crossbyte.net.WebSocketArrivalTest());
		// Red team: what a session holds once a message's call returned, and
		// what one message leaves behind for the next. Also in PortableSuite.
		runner.addCase(new crossbyte.net.WebSocketReuseTest());
		// RPC arguments and a NetConnection's input kept past their calls,
		// over each transport, and a TCP echo queued behind a peer not
		// reading. Also in PortableSuite, for Node.
		runner.addCase(new crossbyte.net.TransportArrivalTest());
		// Not on eval either: its sockets block, so a write to a peer that has
		// stopped reading waits rather than buffering.
		runner.addCase(new crossbyte.net.SocketOutputTest());
		#end
		// Registered for the browser, which reaches it through PortableSuite;
		// written here too so the one list describes everything that runs.
		#if (js && !nodejs)
		runner.addCase(new crossbyte.net.BrowserSocketTest());
		#end
		// Node's event loop, which only Node has; reached through PortableSuite.
		#if nodejs
		runner.addCase(new crossbyte.net.NodeListenerFailureTest());
		// A child runtime's sessions and the one thread; through PortableSuite.
		runner.addCase(new crossbyte.net.ChildRuntimeSessionTest());
		// Registered above for the native targets; one case is Node's alone.
		runner.addCase(new crossbyte.net.ServerWebSocketTLSTest());
		#end
		runner.addCase(new crossbyte.net.WebSocketTest());
		// Unguarded here for the interpreter above all, where none of the
		// server suite runs, and where every upgrade must succeed too.
		runner.addCase(new crossbyte.net.ServerWebSocketUpgradeTest());
		// Sessions still upgrading when the server stops, drains or closes,
		// and what it counts. Also in PortableSuite, for Node.
		runner.addCase(new crossbyte.net.ServerWebSocketUpgradeLifecycleTest());
		// What one peer can make a server hold or do, at each limit and past
		// it. Also in PortableSuite, for Node.
		runner.addCase(new crossbyte.net.ServerWebSocketLimitsTest());
		// What a session holds while it is open, and once it has gone quiet.
		// Also in PortableSuite, for Node.
		runner.addCase(new crossbyte.net.WebSocketMemoryTest());
		// One message made ready once and sent to many sessions. Also in
		// PortableSuite, for Node.
		runner.addCase(new crossbyte.net.WebSocketBroadcastTest());
		// Also in PortableSuite: the host a page's Socket dials is read the
		// same way.
		runner.addCase(new crossbyte.net.WebSocketIPv6Test());
		// Also in PortableSuite, for Node's sessions.
		runner.addCase(new crossbyte.net.WebSocketDeflateTest());
		runner.addCase(new crossbyte._internal.websocket.WebSocketFrameTest());
		runner.addCase(new crossbyte.net.RUDPHardeningTest());
		// Real sockets whose frames go through memory, so reordering, loss and
		// duplication happen when a case says rather than when a network does.
		runner.addCase(new crossbyte.net.ReliableDatagramDeliveryTest());
		// Every datagram through the transport's own delivery, in one buffer:
		// what a session keeps past a datagram's call is a copy. Also in
		// PortableSuite, for Node's datagrams.
		runner.addCase(new crossbyte.net.ReliableDatagramArrivalTest());
		runner.addCase(new crossbyte.net.ReliableDatagramCoalescingTest());
		runner.addCase(new crossbyte.net.ReliableDatagramLossRecoveryTest());
		runner.addCase(new crossbyte.net.ReliableDatagramCloseTest());
		// Real sockets through a relay written for the tests, so like the rest
		// of the reliable datagram cases it is not portable.
		runner.addCase(new crossbyte.net.ReliableDatagramRelayTest());
		runner.addCase(new crossbyte.net.CongestionControlTest());
		runner.addCase(new crossbyte.net.ReliableDatagramAckDelayTest());
		runner.addCase(new crossbyte.net.ReliableDatagramSendQueueTest());
		// The frames a message is kept in until acknowledged, given back for
		// the next. Also in PortableSuite, for Node.
		runner.addCase(new crossbyte.net.ReliableDatagramFramePoolTest());
		// What an idle session holds, and what it makes only when it needs it.
		// Also in PortableSuite, for Node.
		runner.addCase(new crossbyte.net.ReliableDatagramSessionMemoryTest());
		// One message to many sessions: PreparedDatagram, sendPrepared and a
		// server's broadcast.
		runner.addCase(new crossbyte.net.ReliableDatagramBroadcastTest());
		// Joins under a flood, and the resets strangers are sent.
		runner.addCase(new crossbyte.net.ReliableDatagramJoinTest());
		// A session following its player to a new address, through a NAT
		// written for the tests.
		runner.addCase(new crossbyte.net.ReliableDatagramRebindTest());
		// Encrypted sessions over real sockets, through a path written for the
		// tests that records, loses, reorders and forges what crosses it.
		runner.addCase(new crossbyte.net.ReliableDatagramEncryptionTest());
		// Sealed datagrams changed, repeated and forged, through memory. Also in
		// PortableSuite, for Node's crypto.
		runner.addCase(new crossbyte.net.ReliableDatagramTamperTest());
		// Real sockets: a raw Bytes write, and a burst taken within one pass.
		runner.addCase(new crossbyte.net.SocketPassTest());
		// A socket's kernel buffers, natively and on the jvm; elsewhere, that
		// asking for one says it cannot be done. Also in PortableSuite, for Node.
		runner.addCase(new crossbyte.net.SocketBufferSizeTest());
		// What a peer can make a connection hold that its application has
		// not read. Also in PortableSuite, for Node's pause and resume.
		runner.addCase(new crossbyte.net.SocketInputLimitTest());
		// What a connection holds once its traffic is over.
		runner.addCase(new crossbyte.net.SocketMemoryTest());
	}

	/**
		CrossByte's replacements for `sys.net.Socket` and `sys.net.UdpSocket`,
		which every sys target compiles instead of its own: what each promises
		on every target, hl's and neko's standard implementations included.
	**/
	public static function addSysNet(runner:Runner):Void {
		runner.addCase(new crossbyte.net.SysSocketContractTest());
		runner.addCase(new crossbyte.net.SocketSelectThreadsTest());
		// hl's TLS client, whose waits its collector can see past.
		runner.addCase(new crossbyte._internal.socket.HlTlsSocketTest());
		// The transfers that answer -1 for "would block" instead of throwing.
		runner.addCase(new crossbyte.net.SysSocketTransferTest());
	}

	public static function addRPC(runner:Runner):Void {
		runner.addCase(new crossbyte.rpc.RPCTest());
		runner.addCase(new crossbyte.rpc.RPCRobustnessTest());
		runner.addCase(new crossbyte.rpc.RPCContractTest());
		runner.addCase(new crossbyte.rpc.RPCCallHookTest());
		runner.addCase(new crossbyte.rpc.RPCAsyncTest());
		runner.addCase(new crossbyte.rpc.RPCSharedHandlerTest());
		runner.addCase(new crossbyte.rpc.RPCNullReturnTest());
		runner.addCase(new crossbyte.rpc.RPCHeartbeatTest());
		runner.addCase(new crossbyte.rpc.RPCDeadlineTest());
		runner.addCase(new crossbyte.rpc.RPCUnhandledCallTest());
		runner.addCase(new crossbyte.rpc.RPCUnsendableCallTest());
		runner.addCase(new crossbyte.rpc.RPCReadyAgainTest());
		runner.addCase(new crossbyte.rpc.RPCPeerCloseCodeTest());
		runner.addCase(new crossbyte.rpc.RPCFrameTest());
		runner.addCase(new crossbyte.rpc.RPCSignatureTest());
		runner.addCase(new crossbyte.rpc.RPCMethodNamesTest());
		runner.addCase(new crossbyte.rpc.RPCTypedSessionTest());
		runner.addCase(new crossbyte.rpc.RPCCallControlTest());
		runner.addCase(new crossbyte.rpc.RPCEdgesTest());
		runner.addCase(new crossbyte.rpc.RPCRefusalTest());
		runner.addCase(new crossbyte.rpc.RPCReliableStreamTest());
		runner.addCase(new crossbyte.rpc.RPCChunkTest());
		runner.addCase(new crossbyte.rpc.RPCHelloTest());
		runner.addCase(new crossbyte.rpc.RPCRuntimeCodecTest());
		runner.addCase(new crossbyte.rpc.RPCPendingCallsTest());
		runner.addCase(new crossbyte.rpc.RPCArrayTest());
		runner.addCase(new crossbyte.rpc.RPCCompactTest());
		runner.addCase(new crossbyte.rpc.RPCStructTest());
		runner.addCase(new crossbyte.rpc.RPCEnumTest());
		runner.addCase(new crossbyte.rpc.RPCNullTypesTest());
		runner.addCase(new crossbyte.rpc.RPCCallWriterTest());
		runner.addCase(new crossbyte.rpc.RPCArgsTest());
		runner.addCase(new crossbyte.rpc.RPCReceiverTest());
		runner.addCase(new crossbyte.rpc.RPCLargeSurfaceTest());
		runner.addCase(new crossbyte.rpc.RPCWideSurfaceTest());
		// Real sockets pumped until something happens, which Node cannot do,
		// so not in the portable suite.
		runner.addCase(new crossbyte.rpc.RPCConnectionEndTest());
		runner.addCase(new crossbyte.rpc.RPCDialTest());
		runner.addCase(new crossbyte.rpc.RPCTransportTest());
		runner.addCase(new crossbyte.rpc.RPCSlowPeerTest());
	}

	public static function addResources(runner:Runner):Void {
		runner.addCase(new crossbyte.resources.ResourcesTest());
	}

	public static function addTimers(runner:Runner):Void {
		runner.addCase(new crossbyte.timer.GlobalTimerTest());
		runner.addCase(new crossbyte.timer.HaxeTimerTest());
		runner.addCase(new crossbyte.timer.TimerStampTest());
		runner.addCase(new crossbyte.timer.ClockTest());
		runner.addCase(new crossbyte.timer.TimerHeapTest());
		runner.addCase(new crossbyte.timer.TimerWheelTest());
	}

	public static function addUtils(runner:Runner):Void {
		// The suite's own assertion helper, registered in a group the native
		// smoke build actually runs (`addFoundation` is not one of them), and
		// a test for a mechanism a hundred call sites depend on is worth
		// nothing if it executes nowhere.
		runner.addCase(new crossbyte.test.RequireTest());
		runner.addCase(new crossbyte.utils.UtilsTest());
		runner.addCase(new crossbyte.utils.LoggerTest());
		runner.addCase(new crossbyte.utils.IntParseTest());
	}

	public static function addMetrics(runner:Runner):Void {
		runner.addCase(new crossbyte.metrics.MetricsTest());
		runner.addCase(new crossbyte.metrics.MetricsEndpointTest());
	}

	/**
		What each common operation allocates, held to a budget. Natively and on
		the jvm only, the two targets with an allocation counter to read (see
		AllocationMeter); Node, neko, hl and the interpreter have none, and
		register nothing here.
	**/
	public static function addAllocationBudgets(runner:Runner):Void {
		// And only as released: under -D crossbyte_fresh_events or
		// -D crossbyte_check_events every event and payload is made afresh,
		// which is what those defines are for, and the budgets are for the
		// reuse they turn off.
		#if ((cpp || jvm) && !(crossbyte_fresh_events || crossbyte_check_events))
		runner.addCase(new crossbyte.AllocationBudgetTest());
		#end
	}

	public static function addAll(runner:Runner):Void {
		addAuth(runner);
		addCrypto(runner);
		addCore(runner);
		addFoundation(runner);
		addErrors(runner);
		addEvents(runner);
		addDataStructures(runner);
		addMath(runner);
		addHttp(runner);
		addIO(runner);
		addURL(runner);
		addIPC(runner);
		addDatabase(runner);
		addSystem(runner);
		addNet(runner);
		addSysNet(runner);
		addRPC(runner);
		addResources(runner);
		addTimers(runner);
		addUtils(runner);
		addMetrics(runner);
		addAllocationBudgets(runner);
	}

	public static function addNativeSmoke(runner:Runner):Void {
		addCrypto(runner);
		// The asymmetric JWT and JWKS cases are guarded `#if (cpp &&
		// windows)` because they need the mbedTLS bridge, and this suite is
		// the only place that combination is built, so it has to register
		// them, or they would compile out everywhere they ran and be
		// unregistered everywhere they compiled.
		addAuth(runner);
		addCore(runner);
		addErrors(runner);
		addEvents(runner);
		addHttp(runner);
		addSystem(runner);
		addNet(runner);
		addSysNet(runner);
		addRPC(runner);
		addTimers(runner);
		// These three carry `#if cpp` cases of their own: SQLite in
		// DBSupportTest, the named-pipe and shared-memory transports across
		// the IPC suites, and the native helpers in UtilsTest. Registered
		// only in addAll, which runs on the interpreter, those cases would
		// compile out everywhere they were registered and be unregistered
		// where they compiled. Anything here that needs a native target has to
		// be in this suite or it is not tested at all.
		addDatabase(runner);
		addIPC(runner);
		addUtils(runner);
		// The metrics group, natively too: hxcpp is the one target whose
		// metric updates are lock-free.
		addMetrics(runner);
		// The whole IO group, not a hand-picked subset. Both halves of it
		// need a native target: ByteArray's growth guarantees are guarded away
		// from eval, whose shim cannot grow its storage in place, and
		// FileStreamTest's two async cases skip everywhere except cpp.
		addIO(runner);
		// This group is arithmetic, and arithmetic is where the targets
		// disagree. BloomFilter and the hash helpers must not assume a 32-bit
		// Int, which is a bug that only exists between targets, and the
		// compression codecs it also carries are bit packing and shift-based
		// hashing, the same shape of thing. Their encoders emit a stream a
		// decoder elsewhere has to read, so a target that packs bits
		// differently produces output that is wrong rather than merely slower,
		// and nothing else here would say so.
		addDataStructures(runner);
		addAllocationBudgets(runner);
	}
}
