package crossbyte._internal.websocket;

import crossbyte._internal.websocket.WebSocket;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

@:access(crossbyte._internal.websocket.WebSocket)
class WebSocketFrameTest extends utest.Test {
	// --- Finding 1: server rejects unmasked client frames ---

	public function testServerRejectsUnmaskedFrame():Void {
		var ws = serverParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		ws.__input = unmaskedFrame(0x02, Bytes.ofString("hello"));
		ws.__onData();

		Assert.equals(WebSocket.CLOSED, ws.readyState);
		Assert.equals(1002, closeCode);
	}

	public function testServerAcceptsMaskedFrame():Void {
		var ws = serverParser();
		var received:ByteArray = null;
		ws.onmessage = e -> received = e.data;

		ws.__input = maskedFrame(0x02, Bytes.ofString("hello"));
		ws.__onData();

		Assert.equals(WebSocket.OPEN, ws.readyState);
		Require.notNull(received);
		Assert.equals("hello", received.readUTFBytes(received.length));
	}

	// --- Finding 2: cumulative reassembled message size cap ---

	public function testOversizeAccumulatedMessageRejected():Void {
		var ws = clientParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		// Drive MAX_MESSAGE_SIZE worth of full frames as continuation fragments,
		// then one more byte to push the running total over the cap.
		var frameSize:Int = WebSocket.MAX_PAYLOAD;
		var frames:Int = Std.int(WebSocket.MAX_MESSAGE_SIZE / frameSize);

		var buffer = new ByteArray();
		buffer.endian = BIG_ENDIAN;
		for (i in 0...frames) {
			var opcode:Int = i == 0 ? 0x02 : 0x00;
			buffer.writeBytes(unmaskedFrame(opcode, Bytes.alloc(frameSize), false));
		}
		// One trailing fragment of a single byte tips the total over MAX_MESSAGE_SIZE.
		buffer.writeBytes(unmaskedFrame(0x00, Bytes.alloc(1), true));
		buffer.position = 0;

		ws.__input = buffer;
		ws.__onData();

		Assert.equals(WebSocket.CLOSED, ws.readyState);
		Assert.equals(1009, closeCode);
	}

	public function testMessageSizeCounterResetsBetweenMessages():Void {
		var ws = clientParser();
		var calls = 0;
		ws.onmessage = _ -> calls++;
		ws.onclose = _ -> {};

		// Two independent binary messages, each at the per-frame max, should both
		// dispatch because the cumulative counter resets when a message completes.
		var buffer = new ByteArray();
		buffer.endian = BIG_ENDIAN;
		buffer.writeBytes(unmaskedFrame(0x02, Bytes.alloc(WebSocket.MAX_PAYLOAD), true));
		buffer.writeBytes(unmaskedFrame(0x02, Bytes.alloc(WebSocket.MAX_PAYLOAD), true));
		buffer.position = 0;

		ws.__input = buffer;
		ws.__onData();

		Assert.equals(2, calls);
		Assert.equals(WebSocket.OPEN, ws.readyState);
	}

	// --- Finding 3: CLOSE frame validation ---

	public function testCloseFrameWithSingleBytePayloadRejected():Void {
		var ws = clientParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		ws.__input = unmaskedFrame(0x08, Bytes.alloc(1));
		ws.__onData();

		Assert.equals(WebSocket.CLOSED, ws.readyState);
		Assert.equals(1002, closeCode);
	}

	public function testCloseFrameWithReservedCodeRejected():Void {
		var ws = clientParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		// 1005 is reserved and MUST NOT appear on the wire.
		var payload = Bytes.alloc(2);
		payload.set(0, 0x03);
		payload.set(1, 0xED); // 0x03ED = 1005
		ws.__input = unmaskedFrame(0x08, payload);
		ws.__onData();

		Assert.equals(WebSocket.CLOSED, ws.readyState);
		Assert.equals(1002, closeCode);
	}

	public function testCloseFrameWithLowCodeRejected():Void {
		var ws = clientParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		// 999 is below the smallest legal close code (1000).
		var payload = Bytes.alloc(2);
		payload.set(0, 0x03);
		payload.set(1, 0xE7); // 0x03E7 = 999
		ws.__input = unmaskedFrame(0x08, payload);
		ws.__onData();

		Assert.equals(WebSocket.CLOSED, ws.readyState);
		Assert.equals(1002, closeCode);
	}

	public function testCloseFrameWithValidCodeReportsCode():Void {
		var ws = clientParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		var payload = Bytes.alloc(2);
		payload.set(0, 0x03);
		payload.set(1, 0xE8); // 0x03E8 = 1000
		ws.__input = unmaskedFrame(0x08, payload);
		ws.__onData();

		Assert.equals(WebSocket.CLOSED, ws.readyState);
		Assert.equals(1000, closeCode);
	}

	public function testEmptyCloseFrameDefaultsToNormalClosure():Void {
		var ws = clientParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		ws.__input = unmaskedFrame(0x08, Bytes.alloc(0));
		ws.__onData();

		Assert.equals(WebSocket.CLOSED, ws.readyState);
		Assert.equals(1000, closeCode);
	}

	public function testCloseFrameWithInvalidUtf8ReasonRejected():Void {
		var ws = clientParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		// Valid code (1000) followed by a lone continuation byte (invalid UTF-8).
		var payload = Bytes.alloc(3);
		payload.set(0, 0x03);
		payload.set(1, 0xE8);
		payload.set(2, 0x80);
		ws.__input = unmaskedFrame(0x08, payload);
		ws.__onData();

		Assert.equals(WebSocket.CLOSED, ws.readyState);
		Assert.equals(1007, closeCode);
	}

	// --- Finding 4: TEXT payload UTF-8 validation + the validator itself ---

	public function testTextFrameWithInvalidUtf8Rejected():Void {
		var ws = clientParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		var payload = Bytes.alloc(2);
		payload.set(0, 0xC3); // lead byte of a 2-byte sequence
		payload.set(1, 0x28); // not a continuation byte -> invalid
		ws.__input = unmaskedFrame(0x01, payload);
		ws.__onData();

		Assert.equals(WebSocket.CLOSED, ws.readyState);
		Assert.equals(1007, closeCode);
	}

	public function testValidTextFrameDispatches():Void {
		var ws = clientParser();
		var received:ByteArray = null;
		ws.onmessage = e -> received = e.data;

		// "héllo" contains a 2-byte UTF-8 sequence (0xC3 0xA9).
		ws.__input = unmaskedFrame(0x01, Bytes.ofString("héllo"));
		ws.__onData();

		Assert.equals(WebSocket.OPEN, ws.readyState);
		Require.notNull(received);
		Assert.equals("héllo", received.readUTFBytes(received.length));
	}

	public function testUtf8ValidatorAcceptsValidSequences():Void {
		var ws = emptyWebSocket();

		Assert.isTrue(validate(ws, Bytes.ofString("")));
		Assert.isTrue(validate(ws, Bytes.ofString("ascii")));
		Assert.isTrue(validate(ws, Bytes.ofString("héllo"))); // 2-byte
		Assert.isTrue(validate(ws, bytesOf([0xE2, 0x82, 0xAC]))); // euro sign, 3-byte
		Assert.isTrue(validate(ws, bytesOf([0xF0, 0x9F, 0x98, 0x80]))); // emoji U+1F600, 4-byte
	}

	public function testUtf8ValidatorRejectsInvalidSequences():Void {
		var ws = emptyWebSocket();

		Assert.isFalse(validate(ws, bytesOf([0x80]))); // stray continuation
		Assert.isFalse(validate(ws, bytesOf([0xC3, 0x28]))); // bad continuation
		Assert.isFalse(validate(ws, bytesOf([0xC0, 0x80]))); // overlong 2-byte
		Assert.isFalse(validate(ws, bytesOf([0xE0, 0x80, 0x80]))); // overlong 3-byte
		Assert.isFalse(validate(ws, bytesOf([0xED, 0xA0, 0x80]))); // surrogate
		Assert.isFalse(validate(ws, bytesOf([0xF4, 0x90, 0x80, 0x80]))); // > U+10FFFF
		Assert.isFalse(validate(ws, bytesOf([0xE2, 0x82]))); // truncated 3-byte
		Assert.isFalse(validate(ws, bytesOf([0xFF]))); // invalid lead byte
	}

	public function testCloseCodeValidator():Void {
		var ws = emptyWebSocket();

		Assert.isTrue(ws.__isValidCloseCode(1000));
		Assert.isTrue(ws.__isValidCloseCode(1011));
		Assert.isTrue(ws.__isValidCloseCode(3000));
		Assert.isTrue(ws.__isValidCloseCode(4999));

		Assert.isFalse(ws.__isValidCloseCode(0));
		Assert.isFalse(ws.__isValidCloseCode(999));
		Assert.isFalse(ws.__isValidCloseCode(1004));
		Assert.isFalse(ws.__isValidCloseCode(1005));
		Assert.isFalse(ws.__isValidCloseCode(1006));
		Assert.isFalse(ws.__isValidCloseCode(1015));
	}

	// --- helpers ---

	private static function validate(ws:WebSocket, bytes:Bytes):Bool {
		var ba:ByteArray = ByteArray.fromBytes(bytes);
		return ws.__isValidUTF8(ba, 0, ba.length);
	}

	private static function bytesOf(values:Array<Int>):Bytes {
		var b = Bytes.alloc(values.length);
		for (i in 0...values.length) {
			b.set(i, values[i]);
		}
		return b;
	}

	private static function emptyWebSocket():WebSocket {
		return Type.createEmptyInstance(WebSocket);
	}

	private static function baseParser():WebSocket {
		var ws = emptyWebSocket();
		ws.readyState = WebSocket.OPEN;
		ws.__input = new ByteArray();
		ws.__input.endian = BIG_ENDIAN;
		ws.__incomingMessageBuffer = new ByteArray();
		ws.__incomingMessageBuffer.endian = BIG_ENDIAN;
		ws.__inputPosition = 0;
		ws.__incomingOpcode = -1;
		ws.__incomingMessageSize = 0;
		ws.onclose = _ -> {};
		ws.onerror = _ -> {};
		ws.onopen = _ -> {};
		ws.onmessage = _ -> {};
		return ws;
	}

	// A parser that behaves as the client endpoint (accepts unmasked server frames).
	private static function clientParser():WebSocket {
		var ws = baseParser();
		ws.__isClient = true;
		return ws;
	}

	// A parser that behaves as the server endpoint (must reject unmasked client frames).
	private static function serverParser():WebSocket {
		var ws = baseParser();
		ws.__isClient = false;
		return ws;
	}

	private static function maskedFrame(opcode:Int, payload:Bytes, finalFrame:Bool = true, flags:Int = 0):ByteArray {
		var frame = new ByteArray();
		frame.endian = BIG_ENDIAN;
		frame.writeByte((finalFrame ? 0x80 : 0x00) | flags | opcode);
		writePayloadLength(frame, payload.length, true);
		frame.writeByte(0x01);
		frame.writeByte(0x02);
		frame.writeByte(0x03);
		frame.writeByte(0x04);
		for (i in 0...payload.length) {
			frame.writeByte(payload.get(i) ^ ((i & 0x03) + 1));
		}
		frame.position = 0;
		return frame;
	}

	private static function unmaskedFrame(opcode:Int, payload:Bytes, finalFrame:Bool = true, flags:Int = 0):ByteArray {
		var frame = new ByteArray();
		frame.endian = BIG_ENDIAN;
		frame.writeByte((finalFrame ? 0x80 : 0x00) | flags | opcode);
		writePayloadLength(frame, payload.length, false);
		for (i in 0...payload.length) {
			frame.writeByte(payload.get(i));
		}
		frame.position = 0;
		return frame;
	}

	private static function writePayloadLength(frame:ByteArray, length:Int, masked:Bool):Void {
		var flag = masked ? 0x80 : 0;
		if (length > 65535) {
			frame.writeByte(flag | 127);
			frame.writeUnsignedInt(0);
			frame.writeUnsignedInt(length);
		} else if (length > 125) {
			frame.writeByte(flag | 126);
			frame.writeShort(length);
		} else {
			frame.writeByte(flag | length);
		}
	}
}
