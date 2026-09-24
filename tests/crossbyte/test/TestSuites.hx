package crossbyte.test;

import utest.Runner;

class TestSuites {
	public static function addAuth(runner:Runner):Void {
		runner.addCase(new crossbyte.auth.AuthSupportTest());
		runner.addCase(new crossbyte.auth.jwt.JWTTest());
		runner.addCase(new crossbyte.auth.jwt.EdDSAJwtTest());
		runner.addCase(new crossbyte.auth.jwt.PkJwtTest());
		runner.addCase(new crossbyte.auth.jwt.JWKSetTest());
	}

	public static function addCrypto(runner:Runner):Void {
		runner.addCase(new crossbyte.crypto.CryptoTest());
		runner.addCase(new crossbyte.crypto.SodiumExpansionTest());
		runner.addCase(new crossbyte.crypto.password.BCryptHardeningTest());
	}

	public static function addCore(runner:Runner):Void {
		runner.addCase(new crossbyte.FutureTest());
		runner.addCase(new crossbyte.core.CrossByteTest());
		runner.addCase(new crossbyte.core.CrossByteRunningFlagTest());
		runner.addCase(new crossbyte.core.ConfigTest());
		runner.addCase(new crossbyte.core.SocketCapacityTest());
		runner.addCase(new crossbyte.core.FixedStepTest());
	}

	public static function addFoundation(runner:Runner):Void {
		runner.addCase(new crossbyte.foundation.FoundationConstructsTest());
	}

	public static function addErrors(runner:Runner):Void {
		runner.addCase(new crossbyte.errors.ErrorsTest());
	}

	public static function addEvents(runner:Runner):Void {
		runner.addCase(new crossbyte.events.EventDispatcherTest());
		runner.addCase(new crossbyte.events.EventsSupportTest());
	}

	public static function addDataStructures(runner:Runner):Void {
		runner.addCase(new crossbyte.ds.Array2DTest());
		runner.addCase(new crossbyte.ds.CollectionsTest());
		runner.addCase(new crossbyte.ds.BitSetTest());
		runner.addCase(new crossbyte.ds.SequenceRingTest());
		runner.addCase(new crossbyte.ds.InterestSetTest());
		runner.addCase(new crossbyte.ds.QuadTreeTest());
		runner.addCase(new crossbyte.ds.SpatialGridTest());
		runner.addCase(new crossbyte.ds.BloomFilterTest());
		runner.addCase(new crossbyte.ds.OrderedMapTest());
		runner.addCase(new crossbyte.ds.BitmapDataTest());
		runner.addCase(new crossbyte._internal.compression.CompressionRoundTripTest());
	}

	public static function addHttp(runner:Runner):Void {
		// The server half lives in its own class so a JavaScript build can name
		// it without dragging all of TestSuites in behind it.
		ServerSuite.add(runner);

		// HPACK is pure byte manipulation -- no socket, no thread -- so unlike
		// the client below it means the same thing on every target, browser
		// included. Also in PortableSuite, which is how js reaches it.
		runner.addCase(new crossbyte.fuzz.ParserFuzzTest());
		runner.addCase(new crossbyte._internal.http.CookieJarTest());
		runner.addCase(new crossbyte._internal.http.h2.hpack.HpackTest());
		runner.addCase(new crossbyte._internal.http.h2.H2Test());
		runner.addCase(new crossbyte._internal.http.h2.H2ServerTest());

		#if !js
		// The client, which drives a raw socket with its own TLS and so exists
		// on no JavaScript target. Its test also spawns threads.
		runner.addCase(new crossbyte._internal.http.HttpTest());
		// The backend end to end, which needs a listening socket and a thread,
		// so it sits with the client rather than in PortableSuite.
		//
		// Not on eval. A pooled HTTP/2 connection keeps a reader thread parked
		// on a socket between requests, and eval raises a peer reset as a
		// native Unix_error that no Haxe catch can see -- it kills the thread,
		// and a send on a reset socket kills the process outright. That is a
		// property of the target's socket layer, not of the pool: the same
		// reset is an ordinary catchable error everywhere else.
		#if (cpp || hl || neko || java || jvm)
		runner.addCase(new crossbyte.http.HTTP2BackendTest());
		#end
		#end
	}

	public static function addIO(runner:Runner):Void {
		runner.addCase(new crossbyte.io.StoreTest());
		runner.addCase(new crossbyte.io.ByteArrayTest());
		runner.addCase(new crossbyte.io.ByteArrayInputTest());
		runner.addCase(new crossbyte.io.ByteArrayIOTest());
		runner.addCase(new crossbyte.io.ByteArrayOutputTest());
		runner.addCase(new crossbyte.io.FileTest());
		runner.addCase(new crossbyte.io.FileStreamTest());
		runner.addCase(new crossbyte.io.ByteArrayCorrectnessTest());
		runner.addCase(new crossbyte.io.ByteDeltaTest());
	}

	public static function addURL(runner:Runner):Void {
		runner.addCase(new crossbyte.url.URLTest());
		runner.addCase(new crossbyte.url.URLLoaderHttpTest());
		runner.addCase(new crossbyte.url.URLLoaderTest());
		runner.addCase(new crossbyte.url.URLVariablesTest());
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
	}

	public static function addSystem(runner:Runner):Void {
		runner.addCase(new crossbyte.sys.NativeProcessTest());
		runner.addCase(new crossbyte.sys.ProcessLifecycleTest());
		runner.addCase(new crossbyte.sys.SysSupportTest());
		runner.addCase(new crossbyte.sys.WorkerTest());
		runner.addCase(new crossbyte.sys.TaskPoolTest());
	}

	public static function addNet(runner:Runner):Void {
		runner.addCase(new crossbyte.net.DatagramSocketTest());
		// Native only, like DatagramSocketTest beside it. These cases pump the
		// runtime to wait for a datagram, and pumping means Sys.sleep, which on
		// node blocks the very loop the socket is delivered on -- so the query
		// never completes and every case times out.
		runner.addCase(new crossbyte.net.StunClientTest());
		runner.addCase(new crossbyte.cluster.SnowflakeIdTest());
		runner.addCase(new crossbyte.cluster.RendezvousTest());
		runner.addCase(new crossbyte.cluster.MembershipTest());
		runner.addCase(new crossbyte.net.FrameCodecTest());
		runner.addCase(new crossbyte.net.EndpointTest());
		runner.addCase(new crossbyte.net.NetConnectionTest());
		runner.addCase(new crossbyte.net.NetHostTest());
		runner.addCase(new crossbyte._internal.socket.poll.PollBackendRegistryTest());
		runner.addCase(new crossbyte._internal.socket.FlexSocketTest());
		runner.addCase(new crossbyte._internal.socket.BlockedErrorTest());
		runner.addCase(new crossbyte._internal.net.IPv6Test());
		runner.addCase(new crossbyte.net.StunMessageTest());
		runner.addCase(new crossbyte.net.StunQueryTest());
		runner.addCase(new crossbyte.net.TurnClientTest());
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
		// Needs no guard here: this group never runs on a JavaScript target,
		// and everywhere it does run the class exists. Its first case is the
		// one that matters most -- it asserts that the support flag and the
		// behaviour agree, which is how the interpreter and neko earn a real
		// assertion out of having no UDP at all rather than a skip.
		runner.addCase(new crossbyte.net.LocalAddressTest());
		runner.addCase(new crossbyte.net.ReliableDatagramProtocolTest());
		runner.addCase(new crossbyte.net.ReliableDatagramSocketTest());
		// Deliberately unguarded: the exact-buffer read-loop hang it protects
		// against lives on the interpreter, where sockets cannot be made
		// non-blocking. Guarding it to cpp would run it only where the bug
		// cannot happen.
		runner.addCase(new crossbyte.net.SocketExactBufferReadTest());
		// Registered outside the socket gate below. Most of its cases need a
		// listening socket and are guarded inside the class, but its jvm branch
		// only asserts that constructing a secure ServerSocket throws -- and
		// registering the class under `#if cpp` meant that branch compiled on
		// jvm and ran on nothing. A case that executes nowhere reads as
		// protection while providing none.
		runner.addCase(new crossbyte.net.ServerSocketTLSTest());

		// jvm as well as cpp. These were cpp-only, and running them on jvm was
		// how two faults there were found: a listener that ignored
		// setBlocking(false) when it was called before bind(), so the first
		// accept() on an idle port blocked the runtime's own thread; and TCP
		// addresses reported uncompressed, which no UDP case could catch
		// because DatagramSocket already canonicalised and the socket beside
		// it did not.
		#if (cpp || java || jvm)
		runner.addCase(new crossbyte.cluster.NodeChannelTest());
		runner.addCase(new crossbyte.net.SocketTest());
		runner.addCase(new crossbyte.net.ServerSocketDrainTest());
		runner.addCase(new crossbyte.net.ServerWebSocketDrainTest());
		// Needs real sockets: these drive the server with a hand-written
		// client rather than CrossByte's own, which is the only way a fault
		// specific to a foreign peer shows up.
		runner.addCase(new crossbyte.net.WebSocketConformanceTest());
		// Beside it on purpose: the conformance cases cover the violations
		// someone named, and this covers the ones nobody did. Same hand-written
		// client, same gate -- both drive the server through a real socket.
		runner.addCase(new crossbyte.fuzz.WebSocketWireFuzzTest());
		#end
		runner.addCase(new crossbyte.net.WebSocketTest());
		runner.addCase(new crossbyte._internal.websocket.WebSocketFrameTest());
		runner.addCase(new crossbyte.net.RUDPHardeningTest());
	}

	public static function addRPC(runner:Runner):Void {
		runner.addCase(new crossbyte.rpc.RPCTest());
		runner.addCase(new crossbyte.rpc.RPCRobustnessTest());
	}

	public static function addResources(runner:Runner):Void {
		runner.addCase(new crossbyte.resources.ResourcesTest());
	}

	public static function addTimers(runner:Runner):Void {
		runner.addCase(new crossbyte.timer.GlobalTimerTest());
		runner.addCase(new crossbyte.timer.HaxeTimerTest());
		runner.addCase(new crossbyte.timer.TimerStampTest());
		runner.addCase(new crossbyte.timer.TimerHeapTest());
		runner.addCase(new crossbyte.timer.TimerWheelTest());
	}

	public static function addUtils(runner:Runner):Void {
		// The suite's own assertion helper, registered in a group the native
		// smoke build actually runs -- `addFoundation` is not one of them, and
		// a test for a mechanism a hundred call sites depend on is worth
		// nothing if it executes nowhere.
		runner.addCase(new crossbyte.test.RequireTest());
		runner.addCase(new crossbyte.utils.UtilsTest());
		runner.addCase(new crossbyte.utils.LoggerTest());
	}

	public static function addMetrics(runner:Runner):Void {
		runner.addCase(new crossbyte.metrics.MetricsTest());
		runner.addCase(new crossbyte.metrics.MetricsEndpointTest());
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
		addRPC(runner);
		addResources(runner);
		addTimers(runner);
		addUtils(runner);
		addMetrics(runner);
	}

	public static function addNativeSmoke(runner:Runner):Void {
		addCrypto(runner);
		// The asymmetric JWT and JWKS cases are guarded `#if (cpp &&
		// windows)` because they need the mbedTLS bridge, but this suite is
		// the only place that combination is built — and it was not
		// registering them, so they compiled out everywhere they ran and
		// were unregistered everywhere they compiled. They had never run.
		addAuth(runner);
		addCore(runner);
		addErrors(runner);
		addEvents(runner);
		addHttp(runner);
		addSystem(runner);
		addNet(runner);
		addRPC(runner);
		addTimers(runner);
		// These three carry `#if cpp` cases of their own — SQLite in
		// DBSupportTest, the named-pipe and shared-memory transports across
		// the IPC suites, and the native helpers in UtilsTest. Registered
		// only in addAll, which runs on the interpreter, those cases
		// compiled out everywhere they were registered and were
		// unregistered where they compiled: the same way the asymmetric JWT
		// suite went unrun. Anything here that needs a native target has to
		// be in this suite or it is not tested at all.
		addDatabase(runner);
		addIPC(runner);
		addUtils(runner);
		// The whole IO group, not a hand-picked subset. Both halves of it
		// need a native target and had been running on nothing:
		// ByteArray's growth guarantees are guarded away from eval, whose
		// shim cannot grow its storage in place, and FileStreamTest's two
		// async cases skip everywhere except cpp. Registering only the two
		// cases named above left the rest of FileTest and the File/socket
		// IO cases native-untested.
		addIO(runner);
		// This group is arithmetic, and arithmetic is where the targets
		// disagree. BloomFilter and the hash helpers were both fixed for
		// assuming a 32-bit Int, which is a bug that only exists between
		// targets -- and the compression codecs it also carries are bit
		// packing and shift-based hashing, the same shape of thing. Their
		// encoders emit a stream a decoder elsewhere has to read, so a
		// target that packs bits differently produces output that is wrong
		// rather than merely slower, and nothing else here would say so.
		addDataStructures(runner);
	}
}
