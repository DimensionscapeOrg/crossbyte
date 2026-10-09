package crossbyte.test;

import utest.Runner;

/**
	The cases that need no thread, no socket, no database and no filesystem,
	and so mean the same thing on every target CrossByte builds for,
	including the browser and Node.

	One list, so the portable set cannot drift: two lists of one thing drift,
	and a case left off one (such as the one whose index arithmetic differs
	between a 32-bit Int and a double) would not run on the target with the
	double.

	It is a class of its own rather than a group in `TestSuites`, and that is
	not organisation for its own sake. Naming `TestSuites` compiles all of
	`TestSuites`, including the groups that reference a listening socket and a
	thread lock, so a JavaScript build that so much as mentioned it would fail
	to compile on types it was never going to run. A file this size pulls in
	only what it lists.

	Every case here is also reached by `TestSuites.addAll`, through its own
	subsystem group; `SuiteCoverage` enforces that, so this cannot become a
	private corner where a case runs on js and nowhere else. It is not called
	from `addAll` in turn, which would run each of them twice there.
**/
class PortableSuite {
	public static function add(runner:Runner):Void {
		runner.addCase(new crossbyte.net.StunMessageTest());
		// Owns no socket (a relay is talked to through one the caller
		// supplies), so the whole exchange runs here, including on the
		// browser, where the relay itself could only ever be reached
		// through RTCPeerConnection.
		runner.addCase(new crossbyte.net.TurnClientTest());
		runner.addCase(new crossbyte.net.StunQueryTest());
		runner.addCase(new crossbyte.net.PeerClockTest());
		// The class exists everywhere and generates only on native, so the
		// cases here assert on both sides of that: a target without mbedTLS
		// has to say so rather than fail somewhere further along.
		runner.addCase(new crossbyte.net.rtc.DtlsCertificateTest());
		runner.addCase(new crossbyte.net.rtc.DtlsTransportTest());
		runner.addCase(new crossbyte.net.rtc.ClientHelloAssemblyTest());
		runner.addCase(new crossbyte.net.rtc.SctpPacketTest());
		runner.addCase(new crossbyte.net.rtc.SctpAssociationTest());
		runner.addCase(new crossbyte.net.rtc.SctpDataTransferTest());
		runner.addCase(new crossbyte.net.rtc.DataChannelTest());
		runner.addCase(new crossbyte.net.rtc.SessionDescriptionTest());
		// Arithmetic and ordering with no socket in it, so it belongs here for
		// the same reason the STUN codec does; and it belongs on the browser
		// especially, which is the one target that will be talking ICE to a
		// stack it did not write.
		runner.addCase(new crossbyte.net.ice.IceCandidateTest());
		runner.addCase(new crossbyte.net.ice.IceAgentTest());
		// No socket in it: the cipher an encrypted reliable UDP session seals
		// with, Node's crypto on Node, and the Haxe one in the browser.
		runner.addCase(new crossbyte.net.ReliableDatagramCipherTest());
		// The one guarded entry here, and not the kind of guard that makes a
		// case run nowhere: it still runs on Node through this list and on cpp,
		// jvm and the interpreter through `addNet`. The browser is excluded
		// because `LocalAddress` does not exist there at all, along with the
		// rest of the UDP family, so there is no branch of it to execute.
		//
		// It is worth having on Node specifically. That is where its least
		// ordinary code lives: `DatagramSocket` emulates connect() rather than
		// calling it, so `LocalAddress` reaches past it to the real one, and
		// calling it, so `LocalAddress` reaches past it to the real one, and
		// nothing else covers that path. It binds an ephemeral socket and
		// closes it: no listener, no peer, and no traffic, because asking the
		// routing table sends none.
		#if !(js && !nodejs)
		runner.addCase(new crossbyte.net.LocalAddressTest());
		#end
		// The host a WebSocket client dials, IPv6 included; on Node a session
		// over the IPv6 loopback too.
		runner.addCase(new crossbyte.net.WebSocketIPv6Test());
		// A TLS WebSocket server and a client that has to decide whether to
		// trust it, over loopback. Node only: a page can neither listen nor
		// choose what its own WebSocket trusts.
		#if nodejs
		runner.addCase(new crossbyte.net.WebSocketTLSTest());
		runner.addCase(new crossbyte.net.ServerWebSocketTLSTest());
		runner.addCase(new crossbyte.net.ServerWebSocketUpgradeLifecycleTest());
		// What one peer can make a server hold or do: Node's sessions too.
		runner.addCase(new crossbyte.net.ServerWebSocketLimitsTest());
		runner.addCase(new crossbyte.net.WebSocketMemoryTest());
		runner.addCase(new crossbyte.net.WebSocketBroadcastTest());
		// And a plain Socket over Node's TLS, checked the same way.
		runner.addCase(new crossbyte.net.SocketTLSClientTest());
		runner.addCase(new crossbyte.net.WebSocketClientTest());
		runner.addCase(new crossbyte.net.WebSocketSessionTest());
		// A message's call, every way to send it back, and what a listener keeps.
		runner.addCase(new crossbyte.net.WebSocketArrivalTest());
		// Red team: what a session holds once a message's call returned.
		runner.addCase(new crossbyte.net.WebSocketReuseTest());
		// RPC arguments and a NetConnection's input kept past their calls.
		runner.addCase(new crossbyte.net.TransportArrivalTest());
		// permessage-deflate on Node's sessions, and zlib (what a browser
		// inflates with) reading what a server compressed.
		runner.addCase(new crossbyte.net.WebSocketDeflateTest());
		runner.addCase(new crossbyte.net.SocketOutputTest());
		runner.addCase(new crossbyte.net.ReliableDatagramLifecycleTest());
		// What a session keeps past a datagram's call is a copy, with
		// Node's datagram socket underneath.
		runner.addCase(new crossbyte.net.ReliableDatagramArrivalTest());
		// Encrypted sessions attacked through memory, Node's crypto opening the
		// large datagrams.
		runner.addCase(new crossbyte.net.ReliableDatagramTamperTest());
		// The frames a reliable message is kept in, given back for the next.
		runner.addCase(new crossbyte.net.ReliableDatagramFramePoolTest());
		// What an idle reliable session holds.
		runner.addCase(new crossbyte.net.ReliableDatagramSessionMemoryTest());
		// And what a datagram listener is handed, sends back and keeps.
		runner.addCase(new crossbyte.net.DatagramArrivalTest());
		// Red team: a datagram forwarded as an HTTP body from its listener.
		runner.addCase(new crossbyte.url.URLLoaderArrivalTest());
		runner.addCase(new crossbyte.net.NodeListenerFailureTest());
		// Empty wherever there are threads; on Node, an async write refused.
		runner.addCase(new crossbyte.io.FileStreamAsyncRefusalTest());
		runner.addCase(new crossbyte.net.SocketCloseTest());
		// An object written and read with the encoding a socket starts in.
		runner.addCase(new crossbyte.net.SocketObjectTest());
		// What Socket's documentation promises: ranges, ports, timeouts, close.
		runner.addCase(new crossbyte.net.SocketContractTest());
		// A buffer size asked of a socket Node gives no way to size: refused.
		runner.addCase(new crossbyte.net.SocketBufferSizeTest());
		// An unread connection held at its limit, by pausing Node's socket.
		runner.addCase(new crossbyte.net.SocketInputLimitTest());
		// A raw server's connection limit, on Node's listener.
		runner.addCase(new crossbyte.net.ServerSocketLimitsTest());
		// A connection replaced, whose socket still reports on Node.
		runner.addCase(new crossbyte.net.SocketReconnectTest());
		runner.addCase(new crossbyte.net.NameLookupTest());
		runner.addCase(new crossbyte.net.ServerSocketAcceptTest());
		// A listen that fails, and a TLS listener's handshakes, on Node.
		runner.addCase(new crossbyte.net.ServerSocketListenTest());
		// On Node, a server spread over runtimes refused.
		runner.addCase(new crossbyte.net.ServerSpreadTest());
		// What printing a key shows, which is not its PEM, on Node too.
		runner.addCase(new crossbyte.net.KeyTest());
		// A NetConnection dialled over TCP, and an RPC call over one.
		runner.addCase(new crossbyte.net.NetConnectionTcpTest());
		// How a NetConnection ends, told once, the same over each transport.
		runner.addCase(new crossbyte.net.NetConnectionLifecycleTest());
		// A URI a connection cannot use, said with what would work; ws:// in a page.
		runner.addCase(new crossbyte.net.NetConnectionSchemeTest());
		// Whose clock a NetConnection's stamps are, in a child runtime.
		runner.addCase(new crossbyte.net.NetConnectionClockTest());
		// Whose timers a child runtime's sessions arm in a socket's callback.
		runner.addCase(new crossbyte.net.ChildRuntimeSessionTest());
		// A wss:// NetHost given its certificate.
		runner.addCase(new crossbyte.net.NetHostTLSTest());
		// A NetHost made from a URI on port 0, which Node binds a turn later.
		runner.addCase(new crossbyte.net.NetHostUriTest());
		#end
		// A page's Socket against the echo endpoint ci/browser/run.js serves.
		// The browser only: it is the one target where a Socket is a WebSocket.
		#if (js && !nodejs)
		runner.addCase(new crossbyte.net.BrowserSocketTest());
		#end
		// Also in `addUtils`, the way HpackTest is in two places: twelve cases
		// registered here call `Require.notNull`, so the mechanism they depend
		// on has to be checked on the targets that reach them. It needs
		// nothing (a null check and a throw), so it runs everywhere,
		// browser included.
		runner.addCase(new crossbyte.test.RequireTest());
		runner.addCase(new crossbyte.FutureTest());
		runner.addCase(new crossbyte.ds.CollectionsTest());
		// Typed pairs, callbacks and a typed SwitchTable, rather than Dynamic.
		runner.addCase(new crossbyte.ds.TypedShapesTest());
		// Event-type constants that refuse a listener of the wrong event.
		runner.addCase(new crossbyte.events.EventTypesTest());
		// "Copy it to keep it": clone() copies, and what each define does.
		runner.addCase(new crossbyte.events.ArrivalsTest());
		// Specialised per element type, and Map keys that differ by target.
		runner.addCase(new crossbyte.ds.PriorityQueueTest());
		runner.addCase(new crossbyte.ds.OrderedMapTest());
		runner.addCase(new crossbyte.ds.Array2DTest());
		// Unsigned pixel comparison through the sign bit, where js differs.
		runner.addCase(new crossbyte.ds.BitmapDataTest());
		// Word arithmetic on the sign bit, which is where js differs.
		runner.addCase(new crossbyte.ds.BitSetTest());
		// Sequence numbers wrapping past 2^31 - 1, likewise.
		runner.addCase(new crossbyte.ds.SequenceRingTest());
		runner.addCase(new crossbyte.ds.InterestSetTest());
		// Vectors with counts, where arrays would box on the jvm and lose their
		// store to V8 each round.
		runner.addCase(new crossbyte.ds.IdListTest());
		runner.addCase(new crossbyte.ds.QuadTreeTest());
		// Float cell arithmetic and Vector storage, which differ by target.
		runner.addCase(new crossbyte.ds.SpatialGridTest());
		runner.addCase(new crossbyte.ds.SpatialGrid3DTest());
		// Not portable in the sense of needing nothing (it needs a backend),
		// but portable in the sense that matters: the same assertions run
		// against IndexedDB here and a directory of files everywhere else, so
		// neither backend grades its own homework.
		runner.addCase(new crossbyte.io.StoreTest());
		// The path arithmetic under File, both platforms' rules on whichever
		// one runs it; strings only, so a browser runs it too.
		runner.addCase(new crossbyte.io.FilePathTest());
		runner.addCase(new crossbyte._internal.compression.CompressionRoundTripTest());
		runner.addCase(new crossbyte._internal.compression.BrotliCodecTest());
		runner.addCase(new crossbyte._internal.compression.CodecFormatsTest());
		// Nothing here owns a socket (every parser is handed bytes), so it
		// runs wherever the code it fuzzes can be compiled, which is everywhere.
		runner.addCase(new crossbyte.fuzz.ParserFuzzTest());
		// The MongoDB driver's bytes: BSON, Extended JSON, SCRAM and connection
		// strings. The driver itself blocks on a socket and is not built for
		// JavaScript, but its codec is, and JavaScript is where an Int is a
		// double and Haxe's own UTF-8 decoding stops at a NUL.
		runner.addCase(new crossbyte.db.mongodb.BsonTest());
		runner.addCase(new crossbyte.db.mongodb.ExtendedJsonTest());
		runner.addCase(new crossbyte.db.mongodb.ScramTest());
		runner.addCase(new crossbyte.db.mongodb.MongoUriTest());
		// The objects BSON documents are decoded into.
		runner.addCase(new crossbyte._internal.AnonBuilderTest());
		// BCrypt is pure Haxe, so the published vectors hold it to the same
		// answers on every target; hashes made on one have to verify on another.
		runner.addCase(new crossbyte.crypto.password.BCryptHardeningTest());
		runner.addCase(new crossbyte.crypto.password.BCryptVectorsTest());
		runner.addCase(new crossbyte.crypto.password.BCryptByteVectorsTest());
		// Argon2id runs on Node through its own crypto.argon2; the browser has
		// none and has to say so.
		runner.addCase(new crossbyte.crypto.password.PasswordOffloadTest());
		// HS256 is pure Haxe, so tokens verify alike on every target.
		runner.addCase(new crossbyte.auth.jwt.JWTTest());
		runner.addCase(new crossbyte.auth.jwt.JWTVerifyTest());
		// Times past 2038 and a 32-bit Int are where the targets would disagree.
		runner.addCase(new crossbyte.auth.jwt.JWTClaimsTest());
		// PKCE everywhere; the token exchange itself against Node's own http
		// server, where a provider that never answers must still end the
		// exchange. The browser has no server to run it against and skips that part.
		runner.addCase(new crossbyte.auth.OAuthExchangeTest());
		// Pure rules, no socket: the host, Secure and deletion checks that
		// decide whether a session cookie reaches someone else's server.
		runner.addCase(new crossbyte._internal.http.CookieJarTest());
		// A certificate's public key read for a pin, the same on every target.
		runner.addCase(new crossbyte._internal.http.PublicKeyPinsTest());
		#if (js && !nodejs)
		// And refused in a page, which cannot see the key to check it.
		runner.addCase(new crossbyte.url.URLLoaderBrowserTest());
		#end
		runner.addCase(new crossbyte._internal.http.h2.hpack.HpackTest());
		runner.addCase(new crossbyte._internal.http.h2.H2Test());
		runner.addCase(new crossbyte._internal.http.h2.H2ServerTest());
		runner.addCase(new crossbyte.ds.BloomFilterTest());
		runner.addCase(new crossbyte.errors.ErrorsTest());
		runner.addCase(new crossbyte.math.MathTest());
		runner.addCase(new crossbyte.timer.TimerStampTest());
		// Its tick number wraps at 32 bits, and js is where an Int would not.
		runner.addCase(new crossbyte.core.FixedStepTest());
		// The runtime's own frame is a chain of platform timeouts here, and a
		// throw out of one must not end the chain (on Node, the process).
		runner.addCase(new crossbyte.core.UncaughtErrorTest());
		// What post promises that needs no second thread: order, and a refusal
		// once the runtime has exited rather than silence.
		runner.addCase(new crossbyte.core.PostTest());
		// A child runtime made once the program runs, which on Node must still
		// start, and must leave the program's timers alone when it does.
		runner.addCase(new crossbyte.core.ChildRuntimeTest());
		// TaskPool and Worker with no threads: the work inline, what it
		// reports in a later turn.
		runner.addCase(new crossbyte.sys.BackgroundDeliveryTest());
		// ServerApplication on Node, whose POLL loop runs the DEFAULT one.
		runner.addCase(new crossbyte.core.ApplicationTest());
		// SIGTERM and SIGINT on Node, which run the drain rather than exiting.
		runner.addCase(new crossbyte.sys.ProcessLifecycleTest());
		// Loop lag and overruns as the JavaScript loop takes its turns, and
		// the post queue's depth.
		runner.addCase(new crossbyte.core.RuntimeHealthTest());
		// Listener lists changed in place outside a dispatch, and left alone
		// while one walks them: every JavaScript component dispatches.
		runner.addCase(new crossbyte.events.EventDispatcherTest());
		// The rest of the ByteArray cases. None of them touches sys, and js
		// is the target where every ByteArray read and write could break under a
		// green build if nothing executed one.
		runner.addCase(new crossbyte.io.ByteArrayCorrectnessTest());
		runner.addCase(new crossbyte.io.ByteArrayTest());
		runner.addCase(new crossbyte.io.ByteArrayInputTest());
		runner.addCase(new crossbyte.io.ByteArrayIOTest());
		runner.addCase(new crossbyte.io.ByteArrayOutputTest());
		// Built on the ByteArray varint and writeBytes, and decodes what a
		// browser client may have to receive.
		runner.addCase(new crossbyte.io.ByteDeltaTest());
		// Shifts and 32-bit words, which is exactly where JavaScript differs.
		runner.addCase(new crossbyte.io.BitPackingTest());
		runner.addCase(new crossbyte.utils.UtilsTest());
		// The clock and the escaping both differ by target: a browser has no
		// Sys.time, and a string is UTF-16 on js and the jvm but not on eval.
		runner.addCase(new crossbyte.utils.LoggerTest());
		// Std.parseInt's four answers past 32 bits include JavaScript's.
		runner.addCase(new crossbyte.utils.IntParseTest());
		runner.addCase(new crossbyte.db.DBParameterBindingTest());
		runner.addCase(new crossbyte.db.PostgresWireTest());
		runner.addCase(new crossbyte.db.SQLRowTest());
		runner.addCase(new crossbyte.db.PostgresConnInfoTest());
		runner.addCase(new crossbyte.db.SchemaMigratorTest());
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
		runner.addCase(new crossbyte.rpc.RPCFrameTest());
		runner.addCase(new crossbyte.rpc.RPCSignatureTest());
		runner.addCase(new crossbyte.rpc.RPCMethodNamesTest());
		runner.addCase(new crossbyte.rpc.RPCTypedSessionTest());
		runner.addCase(new crossbyte.rpc.RPCCallControlTest());
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
		// A WebSocket's close reaching a NetConnection, which a page does not
		// have; on Node it does.
		#if !(js && !nodejs)
		runner.addCase(new crossbyte.rpc.RPCPeerCloseCodeTest());
		#end
		// Int64 arithmetic on an injected clock, which JavaScript does with
		// two Ints of its own.
		runner.addCase(new crossbyte.cluster.SnowflakeIdTest());
		// The exposition's numbers: a whole number past 2^31 must not go through
		// Std.int, which wraps on JavaScript as it does on eval and cpp.
		runner.addCase(new crossbyte.metrics.MetricsTest());
		// Where a Haxe Int does not wrap at 32 bits by itself.
		runner.addCase(new crossbyte.foundation.Seq32Test());
		// PrimitiveValue's numbers, which Std.parseInt and Std.int read
		// differently on each target.
		runner.addCase(new crossbyte.foundation.FoundationConstructsTest());
		// The MongoDB driver's public types, decided at compile time.
		runner.addCase(new crossbyte.db.mongodb.MongoApiTest());
		// The types of JWT claims, audiences and key records, alike everywhere.
		runner.addCase(new crossbyte.auth.jwt.JWTTypesTest());
		// HS256's HMAC keeps its words in an Int32Array on JavaScript, and the
		// codec builds its text through TextDecoder there.
		runner.addCase(new crossbyte.auth.jwt.Base64UrlTest());
		runner.addCase(new crossbyte.crypto.HmacSha256Test());
	}
}
