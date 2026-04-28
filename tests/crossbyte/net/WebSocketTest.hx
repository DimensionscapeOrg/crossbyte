package crossbyte.net;

import crossbyte._internal.websocket.WebSocket as InternalWebSocket;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;
import utest.Assert;

@:access(crossbyte._internal.websocket.WebSocket)
class WebSocketTest extends utest.Test {
	public function testRequestHandshakeValidationIsCaseInsensitive():Void {
		var ws = emptyWebSocket();
		var headers = ws.__parseHeaders([
			"GET /chat HTTP/1.1",
			"Host: example.com",
			"uPgRaDe: WebSocket",
			"Connection: keep-alive, Upgrade",
			"Sec-WebSocket-Key: abc123",
			"Sec-WebSocket-Version: 13",
			""
		]);

		Assert.isTrue(ws.__validateRequestHandshake(headers));

		var response = ws.__generateResponseHandshake(headers).toString();
		Assert.isTrue(response.indexOf("HTTP/1.1 101 Switching Protocols") == 0);
		Assert.isTrue(response.indexOf("HTTPS/1.1") == -1);
	}

	public function testResponseHandshakeValidationIsCaseInsensitive():Void {
		var ws = emptyWebSocket();
		ws.__key = "test-key";
		var accept = ws.__generateWebSocketAccept(ws.__key);
		var headers = ws.__parseHeaders([
			"HTTP/1.1 101 Switching Protocols",
			"Upgrade: WebSocket",
			"Connection: keep-alive, Upgrade",
			"Sec-WebSocket-Accept: " + accept,
			""
		]);
		headers.set("status", "101");

		Assert.isTrue(ws.__validateResponseHandshake(headers));
	}

	public function testRequestHandshakeRejectsMissingOrInvalidRequiredHeaders():Void {
		var ws = emptyWebSocket();
		var missingKey = ws.__parseHeaders([
			"GET /chat HTTP/1.1",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Version: 13",
			""
		]);
		var oldVersion = ws.__parseHeaders([
			"GET /chat HTTP/1.1",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Key: abc123",
			"Sec-WebSocket-Version: 12",
			""
		]);
		var noUpgradeToken = ws.__parseHeaders([
			"GET /chat HTTP/1.1",
			"Upgrade: websocket",
			"Connection: keep-alive",
			"Sec-WebSocket-Key: abc123",
			"Sec-WebSocket-Version: 13",
			""
		]);

		Assert.isFalse(ws.__validateRequestHandshake(missingKey));
		Assert.isFalse(ws.__validateRequestHandshake(oldVersion));
		Assert.isFalse(ws.__validateRequestHandshake(noUpgradeToken));
	}

	public function testResponseHandshakeRejectsBadAccept():Void {
		var ws = emptyWebSocket();
		ws.__key = "test-key";
		var headers = ws.__parseHeaders([
			"HTTP/1.1 101 Switching Protocols",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Accept: definitely-wrong",
			""
		]);
		headers.set("status", "101");

		Assert.isFalse(ws.__validateResponseHandshake(headers));
	}

	public function testMaskedBinaryFrameDispatchesPayload():Void {
		var ws = openParser();
		var received:ByteArray = null;
		ws.onmessage = e -> received = e.data;

		ws.__input = maskedFrame(0x02, Bytes.ofString("hello"));
		ws.__onData();

		Assert.notNull(received);
		Assert.equals("hello", received.readUTFBytes(received.length));
	}

	public function testFragmentedFrameDispatchesOnceOnFinalContinuation():Void {
		var ws = openParser();
		var calls = 0;
		var received:ByteArray = null;
		ws.onmessage = e -> {
			calls++;
			received = e.data;
		};

		var first = maskedFrame(0x01, Bytes.ofString("hel"), false);
		var second = maskedFrame(0x00, Bytes.ofString("lo"), true);
		first.position = first.length;
		first.writeBytes(second);
		first.position = 0;
		ws.__input = first;
		ws.__onData();

		Assert.equals(1, calls);
		Assert.notNull(received);
		Assert.equals("hello", received.readUTFBytes(received.length));
	}

	public function testPartialFrameWaitsForMoreBytes():Void {
		var ws = openParser();
		var calls = 0;
		ws.onmessage = _ -> calls++;

		var frameBytes:Bytes = maskedFrame(0x02, Bytes.ofString("hello"));
		ws.__input = new ByteArray();
		ws.__input.endian = BIG_ENDIAN;
		writeRawBytes(ws.__input, frameBytes.sub(0, 4));
		ws.__input.position = 0;
		ws.__onData();

		Assert.equals(0, calls);
		Assert.equals(0, ws.__inputPosition);
	}

	public function testExtendedPayloadLength126DispatchesPayload():Void {
		var ws = openParser();
		var received:ByteArray = null;
		ws.onmessage = e -> received = e.data;

		var payload = Bytes.alloc(130);
		for (i in 0...payload.length) {
			payload.set(i, i & 0xFF);
		}

		ws.__input = maskedFrame(0x02, payload);
		ws.__onData();

		Assert.notNull(received);
		Assert.equals(payload.length, received.length);
		Assert.equals(0, received[0]);
		Assert.equals(129, received[129]);
	}

	public function testExtendedPayloadLength127DispatchesMaxPayload():Void {
		var ws = openParser();
		var received:ByteArray = null;
		ws.onmessage = e -> received = e.data;

		var payload = Bytes.alloc(InternalWebSocket.MAX_PAYLOAD);
		payload.set(0, 0x41);
		payload.set(payload.length - 1, 0x5A);

		ws.__input = maskedFrame(0x02, payload);
		ws.__onData();

		Assert.notNull(received);
		Assert.equals(payload.length, received.length);
		Assert.equals(0x41, received[0]);
		Assert.equals(0x5A, received[received.length - 1]);
	}

	public function testContinuationWithoutMessageClosesAsProtocolError():Void {
		var ws = openParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		ws.__input = maskedFrame(0x00, Bytes.ofString("orphan"));
		ws.__onData();

		Assert.equals(InternalWebSocket.CLOSED, ws.readyState);
		Assert.equals(1002, closeCode);
	}

	public function testCloseFrameReportsCodeAndReason():Void {
		var ws = openParser();
		var closeCode:Null<Int> = null;
		var closeReason:String = null;
		ws.onclose = e -> {
			closeCode = e.code;
			closeReason = e.reason;
		};

		var payload = Bytes.alloc(8);
		payload.set(0, 0x03);
		payload.set(1, 0xF0);
		payload.blit(2, Bytes.ofString("policy"), 0, 6);

		ws.__input = maskedFrame(0x08, payload);
		ws.__onData();

		Assert.equals(InternalWebSocket.CLOSED, ws.readyState);
		Assert.equals(1008, closeCode);
		Assert.equals("policy", closeReason);
	}

	public function testOversizedPayloadClosesWithMessageTooBig():Void {
		var ws = openParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		var payload = Bytes.alloc(InternalWebSocket.MAX_PAYLOAD + 1);
		ws.__input = maskedFrame(0x02, payload);
		ws.__onData();

		Assert.equals(InternalWebSocket.CLOSED, ws.readyState);
		Assert.equals(1009, closeCode);
	}

	public function testReservedBitsCloseAsProtocolError():Void {
		var ws = openParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		ws.__input = maskedFrame(0x02, Bytes.ofString("bad"), true, 0x40);
		ws.__onData();

		Assert.equals(InternalWebSocket.CLOSED, ws.readyState);
		Assert.equals(1002, closeCode);
	}

	public function testFragmentedControlFrameClosesAsProtocolError():Void {
		var ws = openParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		ws.__input = maskedFrame(0x09, Bytes.ofString("ping"), false);
		ws.__onData();

		Assert.equals(InternalWebSocket.CLOSED, ws.readyState);
		Assert.equals(1002, closeCode);
	}

	public function testNewDataFrameBeforeContinuationClosesAsProtocolError():Void {
		var ws = openParser();
		var closeCode:Null<Int> = null;
		ws.onclose = e -> closeCode = e.code;

		var first = maskedFrame(0x01, Bytes.ofString("hel"), false);
		var second = maskedFrame(0x01, Bytes.ofString("lo"), true);
		first.position = first.length;
		first.writeBytes(second);
		first.position = 0;
		ws.__input = first;
		ws.__onData();

		Assert.equals(InternalWebSocket.CLOSED, ws.readyState);
		Assert.equals(1002, closeCode);
	}

	public function testPongClearsHeartbeatTimeoutPotential():Void {
		var ws = openParser();
		ws.__hasTimeoutPotential = true;

		ws.__input = unmaskedFrame(0x0A, Bytes.alloc(0));
		ws.__onData();

		Assert.isFalse(ws.__hasTimeoutPotential);
		Assert.equals(InternalWebSocket.OPEN, ws.readyState);
	}

	public function testHandshakeCanCarryFirstFrameInSamePacket():Void {
		var ws = emptyWebSocket();
		ws.readyState = InternalWebSocket.CONNECTING;
		ws.__key = "test-key";
		ws.__handshakeBuffer = "";
		ws.__input = new ByteArray();
		ws.__input.endian = BIG_ENDIAN;
		ws.__incomingMessageBuffer = new ByteArray();
		ws.__incomingMessageBuffer.endian = BIG_ENDIAN;
		ws.__inputPosition = 0;
		ws.__incomingOpcode = -1;
		ws.onopen = _ -> {};
		ws.onclose = _ -> {};

		var received:ByteArray = null;
		ws.onmessage = e -> received = e.data;

		var response = [
			"HTTP/1.1 101 Switching Protocols",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Accept: " + ws.__generateWebSocketAccept(ws.__key),
			"",
			""
		].join("\r\n");
		writeRawBytes(ws.__input, Bytes.ofString(response));
		ws.__input.writeBytes(unmaskedFrame(0x02, Bytes.ofString("ready")));
		ws.__input.position = 0;

		ws.__onData();

		Assert.equals(InternalWebSocket.OPEN, ws.readyState);
		Assert.notNull(received);
		Assert.equals("ready", received.readUTFBytes(received.length));
	}

	public function testSplitHandshakeBuffersUntilComplete():Void {
		var ws = connectingParser();
		var opened = 0;
		ws.onopen = _ -> opened++;
		var received:ByteArray = null;
		ws.onmessage = e -> received = e.data;

		var response = [
			"HTTP/1.1 101 Switching Protocols",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Accept: " + ws.__generateWebSocketAccept(ws.__key),
			"",
			""
		].join("\r\n");
		var splitAt = response.indexOf("Connection");

		writeRawBytes(ws.__input, Bytes.ofString(response.substr(0, splitAt)));
		ws.__input.position = 0;
		ws.__onData();

		Assert.equals(0, opened);
		Assert.isTrue(ws.__handshakeBuffer.length > 0);

		writeRawBytes(ws.__input, Bytes.ofString(response.substr(splitAt)));
		ws.__input.writeBytes(unmaskedFrame(0x02, Bytes.ofString("after")));
		ws.__input.position = 0;
		ws.__onData();

		Assert.equals(1, opened);
		Assert.notNull(received);
		Assert.equals("after", received.readUTFBytes(received.length));
	}

	private static function emptyWebSocket():InternalWebSocket {
		return Type.createEmptyInstance(InternalWebSocket);
	}

	private static function openParser():InternalWebSocket {
		var ws = emptyWebSocket();
		ws.readyState = InternalWebSocket.OPEN;
		ws.__input = new ByteArray();
		ws.__input.endian = BIG_ENDIAN;
		ws.__incomingMessageBuffer = new ByteArray();
		ws.__incomingMessageBuffer.endian = BIG_ENDIAN;
		ws.__inputPosition = 0;
		ws.__incomingOpcode = -1;
		ws.onclose = _ -> {};
		ws.onerror = _ -> {};
		ws.onopen = _ -> {};
		return ws;
	}

	private static function connectingParser():InternalWebSocket {
		var ws = emptyWebSocket();
		ws.readyState = InternalWebSocket.CONNECTING;
		ws.__key = "test-key";
		ws.__handshakeBuffer = "";
		ws.__input = new ByteArray();
		ws.__input.endian = BIG_ENDIAN;
		ws.__incomingMessageBuffer = new ByteArray();
		ws.__incomingMessageBuffer.endian = BIG_ENDIAN;
		ws.__inputPosition = 0;
		ws.__incomingOpcode = -1;
		ws.onclose = _ -> {};
		ws.onerror = _ -> {};
		ws.onopen = _ -> {};
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

	private static function writeRawBytes(target:ByteArray, bytes:Bytes):Void {
		for (i in 0...bytes.length) {
			target.writeByte(bytes.get(i));
		}
	}

	private static function unmaskedFrame(opcode:Int, payload:Bytes, finalFrame:Bool = true):ByteArray {
		var frame = new ByteArray();
		frame.endian = BIG_ENDIAN;
		frame.writeByte((finalFrame ? 0x80 : 0x00) | opcode);
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
