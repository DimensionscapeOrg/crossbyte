package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;
import utest.Assert;

/**
 * `ServerWebSocket` driven by a hand-written client through a real
 * handshake.
 *
 * `WebSocketFrameTest` already covers the frame parser, but it assigns
 * `__input` directly and calls `__onData()`, so it never sees the buffer
 * state a handshake leaves behind. Every other end-to-end exercise uses
 * CrossByte's own client on both ends, so the two sides agree by
 * construction.
 *
 * Between those two gaps sat a server that could not receive a single
 * message from a foreign client: the handshake request stayed in the
 * parse buffer, so the first real frame was read starting at the `G` of
 * `GET`, whose `0x47` has RSV1 set, and every session died with 1002.
 * The parser was correct; the state it inherited was not.
 *
 * These cases close that gap. They speak the protocol the way a browser
 * does, and — more usefully — the ways a browser must not.
 */
@:access(crossbyte.net.WebSocket)
class WebSocketConformanceTest extends utest.Test {
	private static inline var TEXT:Int = 0x01;
	private static inline var BINARY:Int = 0x02;
	private static inline var CONTINUATION:Int = 0x00;
	private static inline var CLOSE:Int = 0x08;
	private static inline var PING:Int = 0x09;
	private static inline var PONG:Int = 0x0A;

	private static inline var RSV1:Int = 0x40;

	private var runtime:CrossByte;
	private var server:ServerWebSocket;
	private var client:RawWebSocketClient;
	private var received:Array<Bytes>;
	private var closeCodes:Array<Int>;
	private var metrics:crossbyte.metrics.Metrics;

	public function setup():Void {
		runtime = CrossByte.current();
		received = [];
		closeCodes = [];
		metrics = new crossbyte.metrics.Metrics();

		server = new ServerWebSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, __onConnect);
		// Published before listen(), so the first accepted session counts.
		server.publishMetrics(metrics);
		server.bind(0, "127.0.0.1");
		server.listen(4);
	}

	public function teardown():Void {
		if (client != null) {
			client.close();
			client = null;
		}
		try {
			server.close();
		} catch (_:Dynamic) {}

		// Closes are dispatched from the runtime loop, not from close()
		// itself, so they have to be drained here. Left pending, this
		// test's disconnect surfaces during the next one and is read as
		// that test's outcome — which is exactly how every case in this
		// class failed on its first run, one reporting the close code the
		// case before it had produced.
		var until:Float = Sys.time() + 0.2;
		while (Sys.time() < until) {
			@:privateAccess runtime.pump(1 / 240, 0);
		}
	}

	private function __onConnect(e:ServerSocketConnectEvent):Void {
		var session:WebSocket = cast e.socket;

		session.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			var data:ByteArray = new ByteArray();
			session.readBytes(data, 0, session.bytesAvailable);
			received.push(data);
		});

		// The public socket reports a close without the code, so the close
		// reason is taken from the session underneath it. Protocol errors
		// sever the connection without sending a close frame, so this is
		// the only place the code is observable.
		var inner = session.__webSocket;
		if (inner != null) {
			var previous = inner.onclose;
			inner.onclose = function(event):Void {
				closeCodes.push(event.code);
				previous(event);
			};
		}
	}

	private function connect():RawWebSocketClient {
		client = new RawWebSocketClient(runtime, "127.0.0.1", server.localPort);
		Assert.stringContains("101", client.handshakeStatus);
		return client;
	}

	/** Runs the server until `check` holds or the deadline passes. */
	private function pumpUntil(check:Void->Bool, seconds:Float = 5.0):Bool {
		var deadline:Float = Sys.time() + seconds;
		while (!check() && Sys.time() < deadline) {
			@:privateAccess runtime.pump(1 / 240, 0);
		}
		return check();
	}

	private function receivedText():String {
		var out:StringBuf = new StringBuf();
		for (chunk in received) {
			out.add(chunk.toString());
		}
		return out.toString();
	}

	// --- delivery ---

	/**
	 * The regression for the handshake-buffer bug: one ordinary frame,
	 * sent the way any client sends its first message.
	 */
	public function testFirstFrameAfterHandshakeIsDelivered():Void {
		var peer = connect();
		peer.send(TEXT, Bytes.ofString("hello"));

		Assert.isTrue(pumpUntil(() -> received.length > 0), "first frame was never delivered");
		Assert.equals("hello", receivedText());
		Assert.equals(0, closeCodes.length);
	}

	/**
	 * A message split across continuation frames must arrive whole.
	 */
	public function testFragmentedMessageReassembles():Void {
		var peer = connect();
		peer.send(TEXT, Bytes.ofString("frag"), false);
		peer.send(CONTINUATION, Bytes.ofString("ment"), false);
		peer.send(CONTINUATION, Bytes.ofString("ed!"), true);

		Assert.isTrue(pumpUntil(() -> receivedText() == "fragmented!"), 'reassembled "${receivedText()}"');
		Assert.equals(0, closeCodes.length);
	}

	/**
	 * A ping between two fragments must be answered without disturbing the
	 * message being reassembled around it.
	 */
	public function testControlFrameBetweenFragmentsIsAnsweredAndDoesNotCorruptTheMessage():Void {
		var peer = connect();
		peer.send(TEXT, Bytes.ofString("before"), false);
		peer.send(PING, Bytes.ofString("ping-payload"));
		peer.send(CONTINUATION, Bytes.ofString("-after"), true);

		var pong = peer.readFrame();
		Assert.notNull(pong, "no pong came back");
		if (pong != null) {
			Assert.equals(PONG, pong.opcode);
			Assert.equals("ping-payload", pong.payload.toString());
		}

		Assert.isTrue(pumpUntil(() -> receivedText() == "before-after"), 'reassembled "${receivedText()}"');
		Assert.equals(0, closeCodes.length);
	}

	/**
	 * Several frames arriving in one read must all be parsed, not just the
	 * first.
	 */
	public function testPipelinedFramesInASingleWriteAreAllDelivered():Void {
		var peer = connect();

		// Three separately masked frames concatenated into one write, so the
		// server has to advance frame by frame through a single read.
		peer.sendRaw(__concat([
			peer.frame(TEXT, Bytes.ofString("one")),
			peer.frame(TEXT, Bytes.ofString("two")),
			peer.frame(TEXT, Bytes.ofString("three"))
		]));

		Assert.isTrue(pumpUntil(() -> receivedText() == "onetwothree"), 'received "${receivedText()}"');
		Assert.equals(0, closeCodes.length);
	}

	/**
	 * A frame arriving in pieces must be buffered until it is complete
	 * rather than parsed from a partial header.
	 */
	public function testFrameSplitAcrossWritesIsBuffered():Void {
		var peer = connect();
		var whole:Bytes = peer.frame(TEXT, Bytes.ofString("split across writes"));

		peer.sendRaw(whole.sub(0, 3));
		peer.pumpFor(0.05);
		Assert.equals(0, received.length, "a partial frame was parsed as if complete");

		peer.sendRaw(whole.sub(3, whole.length - 3));

		Assert.isTrue(pumpUntil(() -> receivedText() == "split across writes"), 'received "${receivedText()}"');
		Assert.equals(0, closeCodes.length);
	}

	/**
	 * Payloads of 126 bytes and up switch to the extended length encoding.
	 */
	public function testExtendedLengthPayloadIsParsed():Void {
		var peer = connect();
		var payload:Bytes = Bytes.alloc(4096);
		for (i in 0...payload.length) {
			payload.set(i, (i % 251));
		}

		peer.send(BINARY, payload);

		Assert.isTrue(pumpUntil(() -> __receivedLength() >= payload.length), 'got ${__receivedLength()} of ${payload.length}');
		Assert.equals(0, closeCodes.length);
	}

	/**
	 * Unmasking XORs whole 32-bit words and finishes the remainder a byte
	 * at a time, so every payload length mod 4 has to be exercised — a
	 * word loop that runs one iteration too far, or a tail that starts at
	 * the wrong offset, corrupts only some lengths.
	 *
	 * Each frame also carries a different mask, since the client generates
	 * a fresh one per frame, so this covers alignment against key rotation
	 * rather than one lucky key.
	 */
	public function testMaskedPayloadsDecodeAtEveryWordBoundary():Void {
		var peer = connect();
		var expected:StringBuf = new StringBuf();

		for (length in 0...13) {
			var payload:Bytes = Bytes.alloc(length);
			for (i in 0...length) {
				// Distinct per frame and per offset, so a swap or a short
				// read shows up as wrong text rather than a wrong count.
				payload.set(i, "A".code + ((length * 3 + i) % 26));
			}
			peer.send(TEXT, payload);
			expected.add(payload.toString());
		}

		var want:String = expected.toString();
		Assert.isTrue(pumpUntil(() -> receivedText() == want), 'received "${receivedText()}" wanted "$want"');
		Assert.equals(0, closeCodes.length);
	}

	/**
	 * Session metrics track real connections, and — the part that matters
	 * — the series count does not grow with them.
	 *
	 * A gauge labelled per peer would satisfy every other expectation here
	 * and then grow without bound on a server with churn, because a
	 * collector keeps a series long after the connection that named it has
	 * gone.
	 */
	public function testSessionMetricsAreAggregatesNotPerPeerSeries():Void {
		var before:Int = metrics.size();
		Assert.isTrue(before > 0, "metrics must exist before the first connection");
		Assert.equals(0.0, __metric("websocket_sessions"));

		var peer = connect();
		Assert.isTrue(pumpUntil(() -> __metric("websocket_sessions") == 1.0), "session gauge did not see the connection");
		Assert.equals(1.0, __metric("websocket_sessions_accepted_total"));

		peer.send(TEXT, Bytes.ofString("counted"));
		Assert.isTrue(pumpUntil(() -> received.length > 0));

		// A drained session holds nothing, so both buffer aggregates read
		// zero rather than being absent.
		Assert.equals(0.0, __metric("websocket_output_buffer_bytes_max"));
		Assert.equals(0.0, __metric("websocket_output_buffer_bytes_total"));

		peer.close();
		Assert.isTrue(pumpUntil(() -> __metric("websocket_sessions_closed_total") == 1.0), "close was not counted");
		Assert.equals(0.0, __metric("websocket_sessions"));

		Assert.equals(before, metrics.size(), "a connection must not add a time series");
	}

	/** Reads one value out of the exposition text, as a collector would. */
	private function __metric(name:String):Null<Float> {
		for (line in metrics.toPrometheus().split("\n")) {
			var trimmed:String = StringTools.trim(line);
			if (trimmed == "" || trimmed.charAt(0) == "#") {
				continue;
			}
			var space:Int = trimmed.lastIndexOf(" ");
			if (space > 0 && trimmed.substr(0, space) == name) {
				return Std.parseFloat(trimmed.substr(space + 1));
			}
		}
		return null;
	}

	// --- rejection ---

	/**
	 * RFC 6455 5.1: a server must reject an unmasked frame from a client.
	 */
	public function testUnmaskedClientFrameIsRejected():Void {
		var peer = connect();
		peer.send(TEXT, Bytes.ofString("unmasked"), true, false);

		Assert.isTrue(pumpUntil(() -> closeCodes.length > 0), "session stayed open");
		Assert.equals(1002, closeCodes[0]);
		Assert.isTrue(peer.waitForClose(), "socket was not dropped");
	}

	/**
	 * Reserved bits are only meaningful with a negotiated extension, and
	 * none is negotiated here.
	 */
	public function testReservedBitIsRejected():Void {
		var peer = connect();
		peer.send(TEXT, Bytes.ofString("reserved"), true, true, RSV1);

		Assert.isTrue(pumpUntil(() -> closeCodes.length > 0), "session stayed open");
		Assert.equals(1002, closeCodes[0]);
	}

	/**
	 * Control frames must not be fragmented.
	 */
	public function testFragmentedControlFrameIsRejected():Void {
		var peer = connect();
		peer.send(PING, Bytes.ofString("nope"), false);

		Assert.isTrue(pumpUntil(() -> closeCodes.length > 0), "session stayed open");
		Assert.equals(1002, closeCodes[0]);
	}

	/**
	 * Control frame payloads are capped at 125 bytes.
	 */
	public function testOversizedControlPayloadIsRejected():Void {
		var peer = connect();
		peer.send(PING, Bytes.alloc(126));

		Assert.isTrue(pumpUntil(() -> closeCodes.length > 0), "session stayed open");
		Assert.equals(1002, closeCodes[0]);
	}

	/**
	 * A continuation with no message in progress has nothing to continue.
	 */
	public function testContinuationWithoutAStartedMessageIsRejected():Void {
		var peer = connect();
		peer.send(CONTINUATION, Bytes.ofString("orphan"), true);

		Assert.isTrue(pumpUntil(() -> closeCodes.length > 0), "session stayed open");
		Assert.equals(1002, closeCodes[0]);
	}

	/**
	 * A new data frame may not interrupt a message still being assembled.
	 */
	public function testDataFrameDuringFragmentedMessageIsRejected():Void {
		var peer = connect();
		peer.send(TEXT, Bytes.ofString("started"), false);
		peer.send(TEXT, Bytes.ofString("interrupting"), true);

		Assert.isTrue(pumpUntil(() -> closeCodes.length > 0), "session stayed open");
		Assert.equals(1002, closeCodes[0]);
	}

	/**
	 * Text frames carry UTF-8; malformed sequences are a 1007, distinct
	 * from a framing error.
	 */
	public function testInvalidUtf8TextIsRejected():Void {
		var peer = connect();
		var invalid:Bytes = Bytes.alloc(2);
		// 0xC3 starts a two-byte sequence; 0x28 is not a continuation byte.
		invalid.set(0, 0xC3);
		invalid.set(1, 0x28);

		peer.send(TEXT, invalid);

		Assert.isTrue(pumpUntil(() -> closeCodes.length > 0), "session stayed open");
		Assert.equals(1007, closeCodes[0]);
	}

	/**
	 * A payload past `MAX_PAYLOAD` is refused as too big rather than
	 * allocated.
	 */
	public function testOversizedDataPayloadIsRejected():Void {
		var peer = connect();
		peer.send(BINARY, Bytes.alloc(crossbyte._internal.websocket.WebSocket.MAX_PAYLOAD + 1));

		Assert.isTrue(pumpUntil(() -> closeCodes.length > 0), "session stayed open");
		Assert.equals(1009, closeCodes[0]);
	}

	private function __receivedLength():Int {
		var total:Int = 0;
		for (chunk in received) {
			total += chunk.length;
		}
		return total;
	}

	private function __concat(parts:Array<Bytes>):Bytes {
		var out:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
		for (part in parts) {
			out.addBytes(part, 0, part.length);
		}
		return out.getBytes();
	}
}
