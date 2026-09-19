package crossbyte.fuzz;

import crossbyte.core.CrossByte;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.RawWebSocketClient;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import utest.Assert;

/**
 * Completes a real handshake and then sends the server frames nobody meant it
 * to see.
 *
 * `WebSocketConformanceTest` already covers the violations someone thought of
 * and named: an unmasked client frame, a reserved bit, a fragmented control
 * frame, an oversized control payload. Those are the valuable cases and they
 * are not what this is for. This is for the ones nobody named -- a length
 * field mutated deep in a header, a continuation with nothing to continue, a
 * frame that promises two gigabytes and sends none of it.
 *
 * The last of those is the one worth writing a fuzzer to reach. A frame header
 * is a promise about bytes that have not arrived, and a decoder that believes
 * it before they do is a decoder a four-byte message can ask for a very large
 * allocation.
 *
 * As with `HTTPWireFuzzTest`, **the assertion is the session after them, not
 * the malformed ones.** Every round may be answered with a close, a protocol
 * error, or nothing at all; each is a legitimate answer to nonsense. What is
 * not allowed is for a fresh client to be unable to connect, handshake and be
 * heard once the noise stops.
 */
class WebSocketWireFuzzTest extends utest.Test {
	/** Malformed sessions before the server is asked to prove it is well. **/
	private static inline var ROUNDS:Int = 60;

	private var __runtime:CrossByte;
	private var __server:ServerWebSocket;
	private var __received:Array<ByteArray>;
	private var __state:Int;

	public function setup():Void {
		// Seeded, so a red run reproduces.
		__state = 0x7EA51234;
		__received = [];
		__runtime = CrossByte.current();

		__server = new ServerWebSocket();
		__server.addEventListener(ServerSocketConnectEvent.CONNECT, __onConnect);
		__server.bind(0, "127.0.0.1");
		__server.listen(8);
	}

	public function teardown():Void {
		try {
			__server.close();
		} catch (_:Dynamic) {}

		// Closes are dispatched from the runtime loop rather than from close(),
		// so a session torn down here surfaces during the next case and is read
		// as that case's outcome unless it is drained now.
		var until:Float = Sys.time() + 0.2;
		while (Sys.time() < until) {
			@:privateAccess __runtime.pump(1 / 240, 0);
		}
	}

	public function testTheServerStillServesAfterMalformedFrames():Void {
		var handshakes:Int = 0;

		for (round in 0...ROUNDS) {
			var client:RawWebSocketClient = null;

			try {
				client = new RawWebSocketClient(__runtime, "127.0.0.1", __server.localPort);
			} catch (_:Dynamic) {
				// The server is entitled to refuse a connection outright.
				continue;
			}

			if (client.handshakeStatus != null && client.handshakeStatus.indexOf("101") >= 0) {
				handshakes++;

				try {
					client.sendRaw(__malformed(round, client));
				} catch (_:Dynamic) {
					// Closed on us mid-write, which is one of the answers.
				}

				try {
					client.pumpFor(0.02);
				} catch (_:Dynamic) {}
			}

			try {
				client.close();
			} catch (_:Dynamic) {}
		}

		// The guard against this quietly testing nothing. If the handshake
		// stopped working, every round above would be a connect and a close
		// and the frame decoder would never be reached -- which is the shape
		// the HTTP wire fuzzer was already caught in once, refused at the rate
		// limiter before the parser saw a byte.
		Assert.isTrue(handshakes > ROUNDS / 2,
			"only " + handshakes + " of " + ROUNDS + " rounds got past the handshake, so the frame decoder was barely reached");

		// The whole point: a new session, after all of that.
		var healthy:RawWebSocketClient = new RawWebSocketClient(__runtime, "127.0.0.1", __server.localPort);
		Assert.stringContains("101", healthy.handshakeStatus);

		healthy.send(0x01, Bytes.ofString("still here"));

		var heard:Bool = __pumpUntil(() -> __receivedText().indexOf("still here") >= 0, 5.0);
		Assert.isTrue(heard, "the server stopped hearing clients after malformed frames; saw: " + __receivedText());

		try healthy.close() catch (_:Dynamic) {}
	}

	// --- the traffic ------------------------------------------------------

	private function __malformed(round:Int, client:RawWebSocketClient):Bytes {
		return switch (round % 6) {
			// Not a frame at all.
			case 0: __randomBytes(__nextInt(1, 256));

			// A valid frame cut somewhere, so the header promises a payload
			// that never finishes arriving.
			case 1:
				var whole:Bytes = client.frame(0x01, Bytes.ofString("a reasonable message"));
				whole.sub(0, __nextInt(1, whole.length));

			// A valid frame with one byte changed. In a header that is a
			// length, an opcode or a mask bit; in the body it is nothing.
			case 2:
				var mutant:Bytes = client.frame(0x01, Bytes.ofString("a reasonable message"));
				mutant.set(__nextInt(0, mutant.length), __nextInt(0, 256));
				mutant;

			// A promise of a payload far larger than anything that follows.
			// The header is complete and well formed; only the promise is a
			// lie, and the bytes it describes never come.
			case 3: __hugeLengthHeader();

			// A continuation frame with nothing to continue.
			case 4: client.frame(0x00, Bytes.ofString("orphan"));

			// A control frame carrying a payload, split across fragments, with
			// a reserved bit set -- three violations at once, which is not a
			// case anybody writes by hand.
			case _: client.frame(0x09, __randomBytes(__nextInt(0, 200)), false, true, 0x40);
		}
	}

	/**
	 * A masked text frame whose 64-bit length says two gigabytes, followed by
	 * the mask and nothing else.
	 *
	 * Hand-built rather than through `frame()`, which computes a truthful
	 * length from the payload it is given and so can never express this.
	 */
	private function __hugeLengthHeader():Bytes {
		var out:BytesBuffer = new BytesBuffer();
		out.addByte(0x81); // FIN + text
		out.addByte(0xFF); // masked + 127, so a 64-bit length follows

		out.addByte(0x00);
		out.addByte(0x00);
		out.addByte(0x00);
		out.addByte(0x00);
		out.addByte(0x7F);
		out.addByte(0xFF);
		out.addByte(0xFF);
		out.addByte(0xFF);

		// The mask, and then nothing. The payload the header describes is
		// never sent.
		for (_ in 0...4) {
			out.addByte(__nextInt(0, 256));
		}

		return out.getBytes();
	}

	// --- the server -------------------------------------------------------

	private function __onConnect(e:ServerSocketConnectEvent):Void {
		var session:WebSocket = cast e.socket;

		session.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			try {
				var data:ByteArray = new ByteArray();
				session.readBytes(data, 0, session.bytesAvailable);
				__received.push(data);
			} catch (_:Dynamic) {}
		});
	}

	private function __receivedText():String {
		var out:StringBuf = new StringBuf();
		for (data in __received) {
			try {
				data.position = 0;
				out.add(data.readUTFBytes(data.length));
			} catch (_:Dynamic) {}
		}

		return out.toString();
	}

	private function __pumpUntil(check:Void->Bool, seconds:Float):Bool {
		var deadline:Float = Sys.time() + seconds;
		while (!check() && Sys.time() < deadline) {
			@:privateAccess __runtime.pump(1 / 240, 0);
		}

		return check();
	}

	// --- deterministic input ---------------------------------------------

	private function __next():Int {
		__state ^= __state << 13;
		__state ^= __state >>> 17;
		__state ^= __state << 5;
		return __state;
	}

	private function __nextInt(low:Int, high:Int):Int {
		if (high <= low) {
			return low;
		}

		var value:Int = __next();
		if (value < 0) {
			value = -(value + 1);
		}

		return low + (value % (high - low));
	}

	private function __randomBytes(length:Int):Bytes {
		var out:Bytes = Bytes.alloc(length);
		for (i in 0...length) {
			out.set(i, __nextInt(0, 256));
		}

		return out;
	}
}
