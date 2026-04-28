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
		ws.__input = frameBytes.sub(0, 4);
		ws.__onData();

		Assert.equals(0, calls);
		Assert.equals(0, ws.__inputPosition);
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

	private static function maskedFrame(opcode:Int, payload:Bytes, finalFrame:Bool = true):ByteArray {
		var frame = new ByteArray();
		frame.endian = BIG_ENDIAN;
		frame.writeByte((finalFrame ? 0x80 : 0x00) | opcode);
		frame.writeByte(0x80 | payload.length);
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
}
