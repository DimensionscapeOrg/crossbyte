package crossbyte._internal.http.h2;

import crossbyte._internal.http.h2.hpack.HpackEncoder;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Eof;
import haxe.io.Input;
import haxe.io.Output;
import utest.Assert;

/**
 * The server half of HTTP/2.
 *
 * Most cases run a loopback: the client connection from `H2Test` drives this
 * server, and the two are stepped against each other. That is worth more than
 * a canned byte script, because the client is the half already pinned to the
 * RFC 7541 vectors -- so a disagreement between them is a real one, not two
 * copies of the same misreading.
 *
 * The protocol-violation cases are hand-built instead. A conforming client
 * cannot produce an even-numbered stream id or an uppercase field name, which
 * is exactly why those paths need testing.
 */
class H2ServerTest extends utest.Test {
	// ---------------------------------------------------------- the preface

	public function testValidPrefaceIsAcceptedAndAnsweredWithSettings():Void {
		var out = new Collector();
		var server = new H2ServerConnection(out.write);

		server.receive(Bytes.ofString(H2Connection.PREFACE));

		// §3.4: SETTINGS must be the first frame the server sends, and it must
		// follow the preface rather than race it.
		var frames = Collector.parse(out.bytes());
		Assert.equals(1, frames.length);
		Assert.equals(H2FrameType.SETTINGS, frames[0].type);
		Assert.isFalse(frames[0].has(H2Flags.ACK));
	}

	public function testPrefaceSplitAcrossReadsIsReassembled():Void {
		var out = new Collector();
		var server = new H2ServerConnection(out.write);

		// A 24-byte preface can easily arrive in pieces, and a server that
		// only matched it in one read would reject a perfectly good client.
		var preface = Bytes.ofString(H2Connection.PREFACE);
		for (i in 0...preface.length) {
			server.receive(preface, i, 1);
		}

		Assert.equals(1, Collector.parse(out.bytes()).length);
	}

	public function testInvalidPrefaceIsAConnectionError():Void {
		var out = new Collector();
		var server = new H2ServerConnection(out.write);
		var failure:H2ConnectionError = null;
		server.onConnectionError = e -> failure = e;

		// What an HTTP/1.1 client reaching an h2c-only port actually sends.
		server.receive(Bytes.ofString("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));

		Assert.notNull(failure);
		Assert.equals(H2ErrorCode.PROTOCOL_ERROR, failure.code);
		Assert.isTrue(server.closed);
	}

	// -------------------------------------------------------- request cycle

	public function testGetRequestRoundTripsAgainstTheClient():Void {
		var link = new Loopback();
		link.serveWith((request, server) -> {
			Assert.equals("GET", request.method);
			Assert.equals("http", request.scheme);
			Assert.equals("/hello", request.path);
			Assert.equals("example.com", request.authority);
			Assert.equals("yes", request.header("x-probe"));

			server.respond(request.streamId, 200, [new HpackHeader("content-type", "text/plain")], Bytes.ofString("pong"));
		});

		var stream = link.request("GET", "/hello", [new HpackHeader("x-probe", "yes")]);

		Assert.equals(200, stream.status);
		Assert.equals("pong", stream.takeBody().toString());
		Assert.equals("content-type", stream.headers[0].name);
	}

	public function testPostBodyReachesTheHandler():Void {
		var link = new Loopback();
		var received:String = null;

		link.serveWith((request, server) -> {
			received = request.body.toString();
			server.respond(request.streamId, 201, [], Bytes.ofString("stored"));
		});

		var stream = link.request("POST", "/submit", [], Bytes.ofString("the payload"));

		Assert.equals("the payload", received);
		Assert.equals(201, stream.status);
		Assert.equals("stored", stream.takeBody().toString());
	}

	public function testResponseWithNoBodyClosesTheStream():Void {
		var link = new Loopback();
		link.serveWith((request, server) -> server.respond(request.streamId, 204, []));

		var stream = link.request("GET", "/nothing", []);

		Assert.equals(204, stream.status);
		Assert.equals(0, stream.bodyLength);
		Assert.isTrue(stream.endOfStream);
	}

	public function testTwoRequestsShareOneConnection():Void {
		var link = new Loopback();
		var paths:Array<String> = [];

		link.serveWith((request, server) -> {
			paths.push(request.path);
			server.respond(request.streamId, 200, [], Bytes.ofString(request.path));
		});

		var first = link.request("GET", "/one", []);
		var second = link.request("GET", "/two", []);

		// Both on the same connection, with the ids the client chose. This is
		// the property HTTP/1.1 keep-alive cannot give: the second request
		// never waited on the first's framing.
		Assert.same(["/one", "/two"], paths);
		Assert.equals(1, first.id);
		Assert.equals(3, second.id);
		Assert.equals("/one", first.takeBody().toString());
		Assert.equals("/two", second.takeBody().toString());
	}

	public function testHeaderBlockSplitAcrossContinuationIsReassembled():Void {
		var link = new Loopback();
		var seen:String = null;

		link.serveWith((request, server) -> {
			seen = request.header("x-big");
			server.respond(request.streamId, 200, []);
		});

		// A tiny max frame size on the client forces the block to span
		// CONTINUATION frames without needing a huge header to do it.
		link.clientFrameLimit(H2Frame.MIN_MAX_FRAME_SIZE);
		var big = StringTools.rpad("", "abcdefgh", 40000);
		var stream = link.request("GET", "/big", [new HpackHeader("x-big", big)]);

		Assert.equals(big, seen);
		Assert.equals(200, stream.status);
	}

	public function testBytesDeliveredOneAtATimeStillDecode():Void {
		var link = new Loopback();
		link.serveWith((request, server) -> server.respond(request.streamId, 200, [], Bytes.ofString("drip")));

		// The push model has to survive any split, because a socket read
		// boundary has nothing to do with a frame boundary.
		link.deliverOneByteAtATime = true;
		var stream = link.request("GET", "/drip", []);

		Assert.equals(200, stream.status);
		Assert.equals("drip", stream.takeBody().toString());
	}

	public function testPingIsEchoed():Void {
		var out = new Collector();
		var server = new H2ServerConnection(out.write);
		server.receive(Bytes.ofString(H2Connection.PREFACE));
		out.bytes();

		server.receive(frame(H2FrameType.PING, 0, 0, Bytes.ofHex("0807060504030201")));

		var frames = Collector.parse(out.bytes());
		Assert.equals(1, frames.length);
		Assert.equals(H2FrameType.PING, frames[0].type);
		Assert.isTrue(frames[0].has(H2Flags.ACK));
		Assert.equals("0807060504030201", frames[0].payload.toHex());
	}

	// ------------------------------------------------- malformed messages

	public function testMalformedRequestResetsOnlyThatStream():Void {
		// Missing :path. §8.1.1 makes a malformed message a *stream* error, so
		// the connection must keep serving -- resetting everything over one
		// bad request would be a denial of service any client could trigger.
		var reset = firstResetFor([new HpackHeader(":method", "GET"), new HpackHeader(":scheme", "http")]);

		Assert.notNull(reset);
		Assert.equals(H2FrameType.RST_STREAM, reset.type);
		Assert.equals(1, reset.streamId);
	}

	public function testUppercaseFieldNameIsRejected():Void {
		// §8.2.1. Normalising instead would let "X-Thing" and "x-thing" reach
		// a router as two different headers.
		Assert.notNull(firstResetFor(requestFields([new HpackHeader("X-Thing", "value")])));
	}

	public function testConnectionSpecificFieldIsRejected():Void {
		// §8.2.2: HTTP/2 does its own framing, so these are malformed.
		Assert.notNull(firstResetFor(requestFields([new HpackHeader("connection", "keep-alive")])));
		Assert.notNull(firstResetFor(requestFields([new HpackHeader("transfer-encoding", "chunked")])));
	}

	public function testTeIsAllowedOnlyAsTrailers():Void {
		Assert.notNull(firstResetFor(requestFields([new HpackHeader("te", "gzip")])));
		// The one permitted value must still get through.
		Assert.isNull(firstResetFor(requestFields([new HpackHeader("te", "trailers")])));
	}

	public function testStatusPseudoHeaderOnARequestIsRejected():Void {
		// :status belongs to a response; §8.3 makes it malformed here.
		Assert.notNull(firstResetFor(requestFields([new HpackHeader(":status", "200")])));
	}

	public function testPseudoHeaderAfterARegularFieldIsRejected():Void {
		Assert.notNull(firstResetFor([
			new HpackHeader(":method", "GET"), new HpackHeader(":scheme", "http"), new HpackHeader("x-first", "1"),
			new HpackHeader(":path", "/late")
		]));
	}

	public function testDuplicatePseudoHeaderIsRejected():Void {
		Assert.notNull(firstResetFor([
			new HpackHeader(":method", "GET"), new HpackHeader(":scheme", "http"), new HpackHeader(":path", "/a"),
			new HpackHeader(":path", "/b")
		]));
	}

	// ----------------------------------------------------- connection rules

	public function testEvenNumberedClientStreamIsAConnectionError():Void {
		// §5.1.1 reserves even ids for the server. Accepting one would make
		// stream identity ambiguous, so this is fatal rather than a reset.
		Assert.notNull(connectionFailureFor(2, 0));
	}

	public function testStreamIdThatDoesNotIncreaseIsAConnectionError():Void {
		Assert.notNull(connectionFailureFor(3, 1));
	}

	public function testPushPromiseFromAClientIsAConnectionError():Void {
		var out = new Collector();
		var server = new H2ServerConnection(out.write);
		var failure:H2ConnectionError = null;
		server.onConnectionError = e -> failure = e;

		server.receive(Bytes.ofString(H2Connection.PREFACE));
		// §8.4: only servers push.
		server.receive(frame(H2FrameType.PUSH_PROMISE, H2Flags.END_HEADERS, 1, Bytes.ofHex("00000002")));

		Assert.notNull(failure);
		Assert.isTrue(server.closed);
	}

	public function testOversizedFrameIsRefusedBeforeBuffering():Void {
		var out = new Collector();
		var server = new H2ServerConnection(out.write);
		var failure:H2ConnectionError = null;
		server.onConnectionError = e -> failure = e;

		server.receive(Bytes.ofString(H2Connection.PREFACE));

		// A header alone, claiming a payload far past our limit. The decoder
		// must refuse on the declared length rather than wait for bytes that
		// would be 16 MB of buffer if they came.
		var header = new BytesBuffer();
		H2Frame.writeHeader(header, 1000000, H2FrameType.DATA, 0, 1);
		server.receive(header.getBytes());

		Assert.notNull(failure);
		Assert.equals(H2ErrorCode.FRAME_SIZE_ERROR, failure.code);
	}

	public function testGoAwayNamesTheHighestStreamItAccepted():Void {
		var out = new Collector();
		var server = new H2ServerConnection(out.write);
		server.receive(Bytes.ofString(H2Connection.PREFACE));

		var encoder = new HpackEncoder(4096);
		server.receive(frame(H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, 5, encoder.encode(requestFields([]))));
		out.bytes();

		server.goAway(H2ErrorCode.NO_ERROR);

		var frames = Collector.parse(out.bytes());
		var goAway = frames[frames.length - 1];
		Assert.equals(H2FrameType.GOAWAY, goAway.type);
		// §6.8: a client uses this to tell which requests were never handled
		// and so are safe to retry elsewhere.
		Assert.equals(5, (goAway.payload.get(0) << 24) | (goAway.payload.get(1) << 16) | (goAway.payload.get(2) << 8) | goAway.payload.get(3));
	}

	// ------------------------------------------------------- flow control

	public function testBodyLargerThanTheWindowStopsAtTheWindow():Void {
		var link = new BlockedServer(100000);

		// The default window is 65535 in each direction (6.5.2), and 6.9.1
		// forbids sending past it. Writing the whole body anyway is not a
		// slow transfer -- it is a FLOW_CONTROL_ERROR, and a conforming peer
		// kills the connection over it.
		Assert.equals(65535, link.dataSent());
		Assert.isFalse(link.sawEndStream());
	}

	public function testStreamWindowAloneDoesNotUnblockAClosedConnectionWindow():Void {
		var link = new BlockedServer(100000);

		// Both windows gate every DATA frame. Topping up only the stream is
		// the classic stall: the transfer looks unblocked and moves nothing.
		link.windowUpdate(1, 50000);
		Assert.equals(65535, link.dataSent());
		Assert.isFalse(link.sawEndStream());
	}

	public function testWindowUpdateResumesAndCompletesTheBody():Void {
		var link = new BlockedServer(100000);

		link.windowUpdate(0, 50000);
		link.windowUpdate(1, 50000);

		// Every byte arrives, and only now does the stream end.
		Assert.equals(100000, link.dataSent());
		Assert.isTrue(link.sawEndStream());
	}

	public function testResumedBodyRespectsTheFrameSizeLimit():Void {
		var link = new BlockedServer(100000);
		link.windowUpdate(0, 50000);
		link.windowUpdate(1, 50000);

		// The window is not the only bound: 4.2 caps a frame at the peer's
		// SETTINGS_MAX_FRAME_SIZE, which defaults to 16384.
		for (frame in link.dataFrames()) {
			if (frame.payload.length > H2Settings.DEFAULT_MAX_FRAME_SIZE) {
				Assert.fail('DATA frame of ${frame.payload.length} bytes exceeds the frame size limit');
				return;
			}
		}
		Assert.pass();
	}

	public function testQueuedBytesAreReportedAsBackpressure():Void {
		var link = new BlockedServer(100000);

		// What the socket has taken is not what the peer has allowed. A writer
		// feeding a large body watermarks against this, and a zero here would
		// tell it to keep feeding a stream that cannot move.
		Assert.equals(100000 - 65535, link.connection.queuedFor(1));

		link.windowUpdate(0, 50000);
		link.windowUpdate(1, 50000);
		Assert.equals(0, link.connection.queuedFor(1));
	}

	public function testRaisedInitialWindowSizeAlsoResumes():Void {
		var link = new BlockedServer(100000);
		link.windowUpdate(0, 50000);

		// 6.9.2: a raised INITIAL_WINDOW_SIZE retunes every open stream, which
		// releases a queue exactly as a WINDOW_UPDATE would. A server that
		// only listened for the latter would sit on the body forever.
		link.settings(H2Settings.DEFAULT_INITIAL_WINDOW_SIZE + 50000);

		Assert.equals(100000, link.dataSent());
		Assert.isTrue(link.sawEndStream());
	}

	// ------------------------------------------- concurrent stream limit

	public function testMaxConcurrentStreamsIsAdvertised():Void {
		var out = new Collector();
		var server = new H2ServerConnection(out.write);
		server.receive(Bytes.ofString(H2Connection.PREFACE));

		var settings = new H2Settings();
		settings.applyPayload(Collector.parse(out.bytes())[0].payload);

		// §6.5.2 sets no default cap, so silence means "unlimited" -- and each
		// stream a peer opens costs a handler and a buffer. Advertising it
		// also lets a client pace itself rather than discover the limit by
		// being refused.
		Assert.equals(H2ServerConnection.DEFAULT_MAX_CONCURRENT_STREAMS, settings.maxConcurrentStreams);
	}

	public function testStreamsPastTheLimitAreRefused():Void {
		var out = new Collector();
		var settings = new H2Settings();
		settings.enablePush = false;
		settings.maxConcurrentStreams = 2;

		var server = new H2ServerConnection(out.write, settings);
		// Held open: nothing responds, so every stream stays counted.
		server.onRequest = _ -> {};
		server.receive(Bytes.ofString(H2Connection.PREFACE));
		out.bytes();

		var encoder = new HpackEncoder(4096);
		for (id in [1, 3, 5]) {
			server.receive(frame(H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, id, encoder.encode(requestFields([]))));
		}

		var refused:Array<Int> = [];
		for (candidate in Collector.parse(out.bytes())) {
			if (candidate.type == H2FrameType.RST_STREAM) {
				refused.push(candidate.streamId);
			}
		}

		// Only the third. §5.1.2 allows PROTOCOL_ERROR or REFUSED_STREAM, and
		// REFUSED_STREAM is the one that tells the client it was never
		// processed and is safe to retry.
		Assert.same([5], refused);
	}

	public function testAFinishedStreamReleasesItsSlot():Void {
		var out = new Collector();
		var settings = new H2Settings();
		settings.enablePush = false;
		settings.maxConcurrentStreams = 1;

		var server = new H2ServerConnection(out.write, settings);
		server.onRequest = request -> server.respond(request.streamId, 200, [], Bytes.ofString("ok"));
		server.receive(Bytes.ofString(H2Connection.PREFACE));
		out.bytes();

		var encoder = new HpackEncoder(4096);
		for (id in [1, 3, 5]) {
			server.receive(frame(H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, id, encoder.encode(requestFields([]))));
		}

		var refused:Int = 0;
		for (candidate in Collector.parse(out.bytes())) {
			if (candidate.type == H2FrameType.RST_STREAM) {
				refused++;
			}
		}

		// Each request finishes before the next arrives, so a limit of one is
		// never actually reached. A count that forgot to decrement would
		// refuse everything after the first and tighten permanently.
		Assert.equals(0, refused);
	}

	// --------------------------------------------------------- rapid reset

	public function testAFloodOfAbandonedStreamsClosesTheConnection():Void {
		var link = new ResetFlood(5);

		// CVE-2023-44487. The concurrency limit cannot see this: a reset
		// stream is a closed stream, so it frees its slot at once and the peer
		// never approaches the cap while still making the server route,
		// allocate and dispatch every request.
		for (id in [1, 3, 5, 7, 9, 11, 13]) {
			link.openThenReset(id);
		}

		Assert.notNull(link.failure);
		Assert.equals(H2ErrorCode.ENHANCE_YOUR_CALM, link.failure.code);
		Assert.isTrue(link.connection.closed);

		// §6.8: said out loud, so the peer learns why rather than seeing a
		// socket vanish.
		var goAway = link.lastGoAway();
		Assert.notNull(goAway);
		Assert.equals(H2ErrorCode.ENHANCE_YOUR_CALM,
			(goAway.payload.get(4) << 24) | (goAway.payload.get(5) << 16) | (goAway.payload.get(6) << 8) | goAway.payload.get(7));
	}

	public function testAFewAbandonedStreamsAreTolerated():Void {
		var link = new ResetFlood(5);

		// Cancelling is legal and ordinary. Under the budget nothing happens.
		for (id in [1, 3, 5]) {
			link.openThenReset(id);
		}

		Assert.isNull(link.failure);
		Assert.isFalse(link.connection.closed);
	}

	public function testResettingAnAnsweredStreamIsNotHeldAgainstThePeer():Void {
		var out = new Collector();
		var settings = new H2Settings();
		settings.enablePush = false;

		var server = new H2ServerConnection(out.write, settings);
		server.maxResetStreams = 1;
		// Answered immediately, so every reset below arrives after the fact.
		server.onRequest = request -> server.respond(request.streamId, 200, [], Bytes.ofString("ok"));

		var failure:H2ConnectionError = null;
		server.onConnectionError = e -> failure = e;
		server.receive(Bytes.ofString(H2Connection.PREFACE));

		var encoder = new HpackEncoder(4096);
		for (id in [1, 3, 5, 7, 9]) {
			server.receive(frame(H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, id, encoder.encode(requestFields([]))));
			server.receive(frame(H2FrameType.RST_STREAM, 0, id, Bytes.ofHex("00000008")));
		}

		// A client cancelling a download it has already read enough of does
		// exactly this. Counting it would close connections over ordinary use.
		Assert.isNull(failure);
		Assert.isFalse(server.closed);
	}

	public function testTheResetBudgetIsPerWindowRatherThanForever():Void {
		var link = new ResetFlood(2, 0);

		// A window of zero elapses between every reset, so the count restarts
		// each time and a steady trickle never accumulates. The budget is what
		// a burst spends, not a lifetime allowance.
		for (id in [1, 3, 5, 7, 9, 11, 13, 15]) {
			link.openThenReset(id);
		}

		Assert.isNull(link.failure);
		Assert.isFalse(link.connection.closed);
	}

	// ---------------------------------------------------------------- utils

	private static function requestFields(extra:Array<HpackHeader>):Array<HpackHeader> {
		var out = [new HpackHeader(":method", "GET"), new HpackHeader(":scheme", "http"), new HpackHeader(":path", "/x")];
		for (field in extra) {
			out.push(field);
		}
		return out;
	}

	private static function frame(type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Bytes {
		var out = new BytesBuffer();
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
		return out.getBytes();
	}

	/** Sends one request block and returns the RST_STREAM it drew, if any. */
	private static function firstResetFor(fields:Array<HpackHeader>):Null<H2Frame> {
		var out = new Collector();
		var server = new H2ServerConnection(out.write);
		server.receive(Bytes.ofString(H2Connection.PREFACE));
		out.bytes();

		var encoder = new HpackEncoder(4096);
		server.receive(frame(H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, 1, encoder.encode(fields)));

		for (candidate in Collector.parse(out.bytes())) {
			if (candidate.type == H2FrameType.RST_STREAM) {
				return candidate;
			}
		}
		return null;
	}

	/** Opens `first` then `second` and returns the connection error, if any. */
	private static function connectionFailureFor(first:Int, second:Int):Null<H2ConnectionError> {
		var out = new Collector();
		var server = new H2ServerConnection(out.write);
		var failure:H2ConnectionError = null;
		server.onConnectionError = e -> failure = e;
		server.receive(Bytes.ofString(H2Connection.PREFACE));

		var encoder = new HpackEncoder(4096);
		server.receive(frame(H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, first, encoder.encode(requestFields([]))));
		if (second > 0) {
			server.receive(frame(H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, second, encoder.encode(requestFields([]))));
		}

		return failure;
	}
}

/** Collects outbound bytes and hands them over as whole frames. */
private class Collector {
	private var __buffer = new BytesBuffer();
	private var __length:Int = 0;

	public function new() {}

	public function write(chunk:Bytes):Void {
		__buffer.addBytes(chunk, 0, chunk.length);
		__length += chunk.length;
	}

	/** Everything written since the last call. */
	public function bytes():Bytes {
		var out = __buffer.getBytes();
		__buffer = new BytesBuffer();
		__length = 0;
		return out;
	}

	public static function parse(bytes:Bytes):Array<H2Frame> {
		var out:Array<H2Frame> = [];
		var position:Int = 0;

		while (position + H2Frame.HEADER_SIZE <= bytes.length) {
			var length:Int = H2Frame.lengthOf(bytes, position);
			if (position + H2Frame.HEADER_SIZE + length > bytes.length) {
				break;
			}
			out.push(H2Frame.read(bytes, position));
			position += H2Frame.HEADER_SIZE + length;
		}

		return out;
	}
}

/**
 * Runs `H2Connection` and `H2ServerConnection` against each other.
 *
 * Both are blocking-shaped in opposite ways -- the client pulls from an
 * `Input`, the server is pushed bytes -- so the client's input is a queue this
 * fills from the server's output between steps.
 */
private class Loopback {
	public var deliverOneByteAtATime:Bool = false;

	private var __client:H2Connection;
	private var __clientIn:QueueInput;
	private var __clientOut:QueueOutput;
	private var __server:H2ServerConnection;
	private var __handler:(H2ServerRequest, H2ServerConnection) -> Void;

	public function new() {
		__clientIn = new QueueInput();
		__clientOut = new QueueOutput();

		var settings = new H2Settings();
		settings.enablePush = false;

		__client = new H2Connection(__clientIn, __clientOut, settings);
		__server = new H2ServerConnection(bytes -> __clientIn.push(bytes));
		__server.onRequest = request -> __handler(request, __server);
	}

	public function serveWith(handler:(H2ServerRequest, H2ServerConnection) -> Void):Void {
		__handler = handler;
	}

	/** Lowers the client's view of the server frame limit, forcing CONTINUATION. */
	public function clientFrameLimit(limit:Int):Void {
		__client.remoteSettings.maxFrameSize = limit;
	}

	public function request(method:String, path:String, headers:Array<HpackHeader>, ?body:Bytes):H2Stream {
		var stream = __client.request(method, "http", "example.com", path, headers, body);

		// Step until the client's stream finishes: hand the client's output to
		// the server, then let the client read whatever the server produced.
		var guard:Int = 0;
		while (!stream.isClosed() && guard++ < 100) {
			__flushToServer();
			if (!__clientIn.hasData()) {
				break;
			}
			while (!stream.isClosed() && __clientIn.hasData()) {
				__client.pump();
			}
		}

		return stream;
	}

	private function __flushToServer():Void {
		var pending:Bytes = __clientOut.take();
		if (pending.length == 0) {
			return;
		}

		if (deliverOneByteAtATime) {
			for (i in 0...pending.length) {
				__server.receive(pending, i, 1);
			}
		} else {
			__server.receive(pending);
		}
	}
}

/** An `Input` backed by a queue the test appends to between steps. */
private class QueueInput extends Input {
	private var __data:Bytes = Bytes.alloc(0);
	private var __position:Int = 0;

	public function new() {}

	public function push(chunk:Bytes):Void {
		var remaining:Int = __data.length - __position;
		var grown = Bytes.alloc(remaining + chunk.length);
		if (remaining > 0) {
			grown.blit(0, __data, __position, remaining);
		}
		grown.blit(remaining, chunk, 0, chunk.length);
		__data = grown;
		__position = 0;
	}

	public function hasData():Bool {
		return __position < __data.length;
	}

	override public function readByte():Int {
		if (!hasData()) {
			throw new Eof();
		}
		return __data.get(__position++);
	}
}

/** An `Output` the test drains between steps. */
private class QueueOutput extends Output {
	private var __buffer = new BytesBuffer();

	public function new() {}

	override public function writeByte(value:Int):Void {
		__buffer.addByte(value);
	}

	public function take():Bytes {
		var out = __buffer.getBytes();
		__buffer = new BytesBuffer();
		return out;
	}
}

/**
 * A server holding a response body too large for the opening window.
 *
 * Drives one request through, answers with `size` bytes, and then lets a test
 * open the windows a step at a time to watch what actually reaches the wire.
 */
private class BlockedServer {
	public final connection:H2ServerConnection;

	private var __collector:Collector;
	private var __frames:Array<H2Frame> = [];

	public function new(size:Int) {
		__collector = new Collector();
		connection = new H2ServerConnection(__collector.write);

		var body = Bytes.alloc(size);
		for (i in 0...size) {
			body.set(i, i & 0xff);
		}

		connection.onRequest = request -> connection.respond(request.streamId, 200, [], body);
		connection.receive(Bytes.ofString(H2Connection.PREFACE));

		var encoder = new HpackEncoder(4096);
		var fields = [new HpackHeader(":method", "GET"), new HpackHeader(":scheme", "http"), new HpackHeader(":path", "/big")];

		var out = new BytesBuffer();
		var block = encoder.encode(fields);
		H2Frame.writeHeader(out, block.length, H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, 1);
		out.addBytes(block, 0, block.length);
		connection.receive(out.getBytes());

		__collect();
	}

	public function windowUpdate(streamId:Int, increment:Int):Void {
		var payload = Bytes.alloc(4);
		payload.set(0, (increment >> 24) & 0xff);
		payload.set(1, (increment >> 16) & 0xff);
		payload.set(2, (increment >> 8) & 0xff);
		payload.set(3, increment & 0xff);

		var out = new BytesBuffer();
		H2Frame.writeHeader(out, 4, H2FrameType.WINDOW_UPDATE, 0, streamId);
		out.addBytes(payload, 0, payload.length);
		connection.receive(out.getBytes());

		__collect();
	}

	/** Sends a SETTINGS frame raising INITIAL_WINDOW_SIZE. */
	public function settings(initialWindowSize:Int):Void {
		var payload = Bytes.alloc(6);
		payload.set(0, 0);
		payload.set(1, 0x4);
		payload.set(2, (initialWindowSize >> 24) & 0xff);
		payload.set(3, (initialWindowSize >> 16) & 0xff);
		payload.set(4, (initialWindowSize >> 8) & 0xff);
		payload.set(5, initialWindowSize & 0xff);

		var out = new BytesBuffer();
		H2Frame.writeHeader(out, 6, H2FrameType.SETTINGS, 0, 0);
		out.addBytes(payload, 0, payload.length);
		connection.receive(out.getBytes());

		__collect();
	}

	public function dataFrames():Array<H2Frame> {
		var out:Array<H2Frame> = [];
		for (frame in __frames) {
			if (frame.type == H2FrameType.DATA) {
				out.push(frame);
			}
		}
		return out;
	}

	public function dataSent():Int {
		var total:Int = 0;
		for (frame in dataFrames()) {
			total += frame.payload.length;
		}
		return total;
	}

	public function sawEndStream():Bool {
		for (frame in dataFrames()) {
			if (frame.has(H2Flags.END_STREAM)) {
				return true;
			}
		}
		return false;
	}

	private function __collect():Void {
		for (frame in Collector.parse(__collector.bytes())) {
			__frames.push(frame);
		}
	}
}

/**
 * A server driven by a peer that opens streams and abandons them.
 *
 * Requests are deliberately never answered, so every reset lands on a stream
 * the server still considered live -- which is the whole shape of the attack.
 */
private class ResetFlood {
	public final connection:H2ServerConnection;
	public var failure:H2ConnectionError = null;

	private var __collector:Collector;
	private var __encoder:HpackEncoder = new HpackEncoder(4096);
	private var __frames:Array<H2Frame> = [];

	public function new(budget:Int, ?window:Float) {
		__collector = new Collector();

		var settings = new H2Settings();
		settings.enablePush = false;

		connection = new H2ServerConnection(__collector.write, settings);
		connection.maxResetStreams = budget;
		if (window != null) {
			connection.resetWindowSeconds = window;
		}

		// Held open on purpose: an answered stream is gone before its reset
		// arrives, and then there is nothing to abandon.
		connection.onRequest = _ -> {};
		connection.onConnectionError = e -> failure = e;
		connection.receive(Bytes.ofString(H2Connection.PREFACE));
		__collect();
	}

	public function openThenReset(streamId:Int):Void {
		var fields = [new HpackHeader(":method", "GET"), new HpackHeader(":scheme", "http"), new HpackHeader(":path", "/flood")];

		var open = new BytesBuffer();
		var block = __encoder.encode(fields);
		H2Frame.writeHeader(open, block.length, H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, streamId);
		open.addBytes(block, 0, block.length);
		connection.receive(open.getBytes());

		var reset = new BytesBuffer();
		var code = Bytes.ofHex("00000008");
		H2Frame.writeHeader(reset, 4, H2FrameType.RST_STREAM, 0, streamId);
		reset.addBytes(code, 0, code.length);
		connection.receive(reset.getBytes());

		__collect();
	}

	public function lastGoAway():Null<H2Frame> {
		var found:H2Frame = null;
		for (frame in __frames) {
			if (frame.type == H2FrameType.GOAWAY) {
				found = frame;
			}
		}
		return found;
	}

	private function __collect():Void {
		for (frame in Collector.parse(__collector.bytes())) {
			__frames.push(frame);
		}
	}
}
