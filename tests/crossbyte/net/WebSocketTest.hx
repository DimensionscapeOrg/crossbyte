package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte._internal.websocket.WebSocket as InternalWebSocket;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

@:access(crossbyte.core.CrossByte)
@:access(crossbyte.events.EventDispatcher)
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
		ws.onmessage = e -> received = kept(e.message);

		ws.__input = maskedFrame(0x02, Bytes.ofString("hello"));
		ws.__onData();

		Require.notNull(received);
		Assert.equals("hello", received.readUTFBytes(received.length));
	}

	/**
		A read that drains the socket is the last read of an arrival, as
		Socket's is. The loop read on until the socket said it would block: a
		system call that read nothing on every arrival, and an exception hxcpp
		throws and the loop catches, a third of an echoing server's time,
		where a plain socket spent a twelfth.
	**/
	public function testAReadThatDrainsTheSocketIsTheLastRead():Void {
		#if cpp
		var listener = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(1);
		var client = new CountingSocket();
		client.connect(new sys.net.Host("127.0.0.1"), listener.host().port);
		var peer = listener.accept();
		client.setBlocking(false);
		var counting = client.counting;

		var ws = openParser();
		ws.__socket = client;
		ws.__connected = true;
		ws.__tls = false;
		var received:String = null;
		ws.onmessage = e -> received = e.message.readUTFBytes(e.message.length);

		var frame = maskedFrame(0x01, Bytes.ofString("hello"));
		peer.output.writeBytes(frame, 0, frame.length);
		peer.output.flush();
		sys.net.Socket.select([client], [], [], 5.0);
		ws.__readAvailable();

		Assert.equals("hello", received);
		Assert.equals(1, counting.reads, "a read that drained the socket was followed by another");
		Assert.equals(0, counting.blocked, "a read was made only to be told the socket would block");
		try client.close() catch (_:Dynamic) {}
		try peer.close() catch (_:Dynamic) {}
		try listener.close() catch (_:Dynamic) {}
		#else
		Assert.pass();
		#end
	}

	/**
		A burst of messages is parsed in one sweep, and what is left of it
		after the last whole frame is moved down once, in place.

		Every 64 KB consumed copied the whole unread rest of the input into a
		new buffer, so a burst cost the square of its length: a client
		uploading 64 KB messages was received at 21 MB/s, 48.7 ms of server
		CPU a megabyte, 82% of it in that copy, and the runtime ran nothing
		else, for seconds at a time, while it lasted.
	**/
	public function testABurstIsParsedWithoutCopyingWhatIsLeft():Void {
		var ws = openParser();
		ws.__isClient = true;
		var size:Int = 8 * 1024;
		var count:Int = 64;

		var burst = new ByteArray();
		burst.endian = BIG_ENDIAN;
		for (i in 0...count) {
			burst.writeBytes(patternFrame(i, size));
		}
		// And the first half of one more, whose rest arrives after.
		var last = patternFrame(count, size);
		var half:Int = last.length >> 1;
		burst.writeBytes(last, 0, half);

		var buffer:ByteArray = ws.__input;
		var copies:Int = 0;
		var messages:Int = 0;
		var wrong:Int = 0;
		ws.onmessage = e -> {
			if (ws.__input != buffer) {
				copies++;
				buffer = ws.__input;
			}
			if (!carries(e.message, messages, size)) {
				wrong++;
			}
			messages++;
		};

		arrive(ws, burst, 0, burst.length);
		if (ws.__input != buffer) {
			copies++;
			buffer = ws.__input;
		}
		Assert.equals(count, messages, "not every whole message in the burst was delivered");
		Assert.equals(0, copies, 'what was left of a burst of $count messages was copied into a new buffer $copies times');

		arrive(ws, last, half, last.length - half);
		Assert.equals(count + 1, messages, "the message split across two arrivals was not delivered");
		Assert.equals(0, wrong, '$wrong messages arrived as something other than what was sent');
	}

	/**
		A session whose peer keeps every read full reads a megabyte a pass,
		as a plain socket does, and the rest on the passes after.

		It read for as long as reads came back full, so a client uploading
		faster than the server parsed held the runtime in that one session,
		every timer and every other socket waiting on it.
	**/
	public function testAPeerThatKeepsSendingIsReadAMegabyteAPass():Void {
		#if cpp
		// 4 bytes of header and 4,092 of payload: 4 KB a frame, 16 a read.
		var size:Int = 4092;
		var total:Int = 8 * 1024 * 1024;
		var raw = new sys.net.Socket();
		var original = raw.input;
		var flood = new FloodInput(patternFrame(0, size), total, 64 * 1024);
		@:privateAccess raw.input = flood;

		var ws = openParser();
		ws.__isClient = true;
		ws.__socket = raw;
		ws.__connected = true;
		ws.__tls = false;
		var messages:Int = 0;
		var wrong:Int = 0;
		ws.onmessage = e -> {
			if (!carries(e.message, 0, size)) {
				wrong++;
			}
			messages++;
		};

		var perPass:Array<Int> = [];
		while (flood.available > 0 && perPass.length < 100) {
			var before:Int = messages;
			ws.__readAvailable();
			perPass.push(messages - before);
		}
		ws.__socket = null;
		@:privateAccess raw.input = original;
		try raw.close() catch (_:Dynamic) {}

		var largest:Int = 0;
		for (n in perPass) {
			if (n > largest) {
				largest = n;
			}
		}
		Assert.equals(total >> 12, messages, "not every message sent was delivered");
		Assert.equals(0, wrong, '$wrong messages arrived as something other than what was sent');
		Assert.isTrue(largest <= 256, 'one pass read $largest messages, ${largest * 4} KB, from a peer that kept sending');
		#else
		Assert.pass();
		#end
	}

	/**
		What a pass of the runtime sends a WebSocket goes out in one write,
		when the pass ends. Each message was a write of its own, a system
		call apiece: a server relaying a chat room's messages to everyone in
		it made one for every message to every member.
	**/
	public function testWhatOnePassSendsGoesOutInOneWrite():Void {
		#if cpp
		var listener = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(1);
		var client = new CountingSocket();
		client.connect(new sys.net.Host("127.0.0.1"), listener.host().port);
		var peer = listener.accept();
		client.setBlocking(false);

		var ws = openSender(client);
		for (i in 0...10) {
			ws.sendString("message " + i);
		}
		CrossByte.current().__flushHeld();
		Assert.equals(1, client.written.writes, "ten messages sent in one pass went out in " + client.written.writes + " writes");

		// All ten arrive, whole and in order: a 2-byte header and 9 bytes each.
		var arrived = Bytes.alloc(110);
		peer.setTimeout(5);
		peer.input.readFullBytes(arrived, 0, arrived.length);
		for (i in 0...10) {
			var at:Int = i * 11;
			Assert.equals(0x81, arrived.get(at), "frame " + i + " is not a final text frame");
			Assert.equals(9, arrived.get(at + 1), "frame " + i + " has the wrong length");
			Assert.equals("message " + i, arrived.getString(at + 2, 9));
		}
		try client.close() catch (_:Dynamic) {}
		try peer.close() catch (_:Dynamic) {}
		try listener.close() catch (_:Dynamic) {}
		#else
		Assert.pass();
		#end
	}

	/**
		A session closed at once still sends what the pass was holding for it,
		and its close frame after: an `abort` in the handler that sent a
		last message used to find both already written, and must not lose
		them now that they wait for the pass to end.
	**/
	public function testWhatAPassHeldGoesBeforeAnAbortCloses():Void {
		#if cpp
		var listener = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(1);
		var client = new CountingSocket();
		client.connect(new sys.net.Host("127.0.0.1"), listener.host().port);
		var peer = listener.accept();
		client.setBlocking(false);

		var ws = openSender(client);
		ws.sendString("last words");
		ws.abort(1001);

		// "last words" in a 12-byte text frame, then a close frame carrying 1001.
		var arrived = Bytes.alloc(16);
		peer.setTimeout(5);
		peer.input.readFullBytes(arrived, 0, arrived.length);
		Assert.equals(0x81, arrived.get(0), "the held message did not go first");
		Assert.equals("last words", arrived.getString(2, 10));
		Assert.equals(0x88, arrived.get(12), "no close frame followed it");
		Assert.equals(2, arrived.get(13));
		Assert.equals(1001, (arrived.get(14) << 8) | arrived.get(15));
		try peer.close() catch (_:Dynamic) {}
		try listener.close() catch (_:Dynamic) {}
		#else
		Assert.pass();
		#end
	}

	public function testFragmentedFrameDispatchesOnceOnFinalContinuation():Void {
		var ws = openParser();
		var calls = 0;
		var received:ByteArray = null;
		ws.onmessage = e -> {
			calls++;
			received = kept(e.message);
		};

		var first = maskedFrame(0x01, Bytes.ofString("hel"), false);
		var second = maskedFrame(0x00, Bytes.ofString("lo"), true);
		first.position = first.length;
		first.writeBytes(second);
		first.position = 0;
		ws.__input = first;
		ws.__onData();

		Assert.equals(1, calls);
		Require.notNull(received);
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
		ws.onmessage = e -> received = kept(e.message);

		var payload = Bytes.alloc(130);
		for (i in 0...payload.length) {
			payload.set(i, i & 0xFF);
		}

		ws.__input = maskedFrame(0x02, payload);
		ws.__onData();

		Require.notNull(received);
		Assert.equals(payload.length, received.length);
		Assert.equals(0, received[0]);
		Assert.equals(129, received[129]);
	}

	public function testExtendedPayloadLength127DispatchesMaxPayload():Void {
		var ws = openParser();
		var received:ByteArray = null;
		ws.onmessage = e -> received = kept(e.message);

		var payload = Bytes.alloc(InternalWebSocket.MAX_PAYLOAD);
		payload.set(0, 0x41);
		payload.set(payload.length - 1, 0x5A);

		ws.__input = maskedFrame(0x02, payload);
		ws.__onData();

		Require.notNull(received);
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
		ws.onmessage = e -> received = kept(e.message);

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
		Require.notNull(received);
		Assert.equals("ready", received.readUTFBytes(received.length));
	}

	public function testSplitHandshakeBuffersUntilComplete():Void {
		var ws = connectingParser();
		var opened = 0;
		ws.onopen = _ -> opened++;
		var received:ByteArray = null;
		ws.onmessage = e -> received = kept(e.message);

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
		Require.notNull(received);
		Assert.equals("after", received.readUTFBytes(received.length));
	}

	public function testCloseDetachesFromOwningRuntimeEvenIfCurrentRuntimeChanges():Void {
		var primordial = CrossByte.current();
		var child = new CrossByte(false, DEFAULT, true);
		var ws = emptyWebSocket();
		ws.__runtime = child;
		ws.__tickConnectListener = ws.__onTickConnect;
		ws.__tickSSLHandshakeListener = ws.__onTickSSLHandshake;
		// A real socket, never connected. Closing now closes the transport
		// whether or not the session opened, and a stand-in object with no
		// close() of its own is not something hxcpp can call one on.
		ws.__socket = new crossbyte._internal.websocket.FlexSocket(false);
		ws.__secure = false;
		ws.__connected = false;
		ws.onclose = _ -> {};

		child.addEventListener("tick", ws.__tickConnectListener);
		var listenersBefore:Array<Dynamic> = cast @:privateAccess child.__eventMap.get("tick");
		Require.notNull(listenersBefore);
		Assert.isTrue(listenersBefore.length > 0);

		primordial.pump(0, 0);
		ws.__close(1000);

		var listenersAfter:Array<Dynamic> = cast @:privateAccess child.__eventMap.get("tick");
		Assert.isTrue(listenersAfter == null || listenersAfter.length < listenersBefore.length);
		child.exit();
	}

	/**
		A `WebSocket` has no half-close, a session ends both ways at once,
		with a close frame, and `shutdown()` says so, as a page's `Socket`
		does, where it returned having done nothing.
	**/
	public function testShutdownIsRefused():Void {
		var socket = new crossbyte.net.WebSocket();
		Assert.raises(() -> socket.shutdown(false, true), crossbyte.errors.IllegalOperationError);
		Assert.raises(() -> socket.shutdown(true, false), crossbyte.errors.IllegalOperationError);
	}

	/**
		A URL whose port is too big for an `Int` is refused, on every target.
		`Std.parseInt` made it the largest Int on Windows, its low 32 bits on
		Linux, port 80, for this one, nothing at all on eval, so the
		default port, and an exception of its own on the jvm. Not on eval, hl
		or neko, which have no secure random to key a client's handshake with,
		so no client to build.
	**/
	#if !(eval || hl || neko)
	public function testAUrlPortTooBigForAnIntIsRefused():Void {
		var thrown:Dynamic = null;
		var session:InternalWebSocket = null;
		try {
			session = new InternalWebSocket("ws://127.0.0.1:4294967376/chat");
		} catch (e:Dynamic) {
			thrown = e;
		}
		if (session != null) {
			try session.abort() catch (_:Dynamic) {}
		}

		Assert.notNull(thrown, "a port too big for an Int was taken as some other port");
		Assert.isTrue(thrown != null && Std.string(thrown).indexOf("port") >= 0, "the refusal did not say it was the port: " + thrown);
	}
	#end

	private static function emptyWebSocket():InternalWebSocket {
		return Type.createEmptyInstance(InternalWebSocket);
	}

	/**
		A copy of a message `onmessage` was handed, to read after the call:
		the message itself is valid only during it.
	**/
	private static function kept(message:ByteArray):ByteArray {
		var copy = new ByteArray();
		copy.writeBytes(message, 0, message.length);
		copy.position = 0;
		return copy;
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

	#if cpp
	/** An open server-side session over `socket`, as an accepted one is, ready to send. **/
	private static function openSender(socket:sys.net.Socket):InternalWebSocket {
		var ws = openParser();
		ws.__socket = socket;
		ws.__connected = true;
		ws.__tls = false;
		ws.__isClient = false;
		ws.__output = new ByteArray();
		ws.__output.endian = BIG_ENDIAN;
		ws.__pendingOutput = new ByteArray();
		ws.__pendingOutput.endian = BIG_ENDIAN;
		ws.__outgoingMessageBuffer = new ByteArray();
		ws.__outgoingMessageBuffer.endian = BIG_ENDIAN;
		// Text is framed from here natively, a server's as well as a client's.
		ws.__maskedPayload = new ByteArray();
		ws.__maskedPayload.endian = BIG_ENDIAN;
		ws.__runtime = CrossByte.current();
		return ws;
	}
	#end

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

	/** An unmasked binary frame, as a server sends, whose payload of `size` bytes counts up from `index`. **/
	private static function patternFrame(index:Int, size:Int):ByteArray {
		var payload = Bytes.alloc(size);
		for (j in 0...size) {
			payload.set(j, (index + j) & 0xFF);
		}
		var frame = new ByteArray();
		frame.endian = BIG_ENDIAN;
		frame.writeByte(0x82);
		writePayloadLength(frame, size, false);
		frame.writeBytes(payload, 0, size);
		frame.position = 0;
		return frame;
	}

	/** Whether `data` is the payload `patternFrame(index, size)` carries: looked at every seventh byte, and the last. **/
	private static function carries(data:ByteArray, index:Int, size:Int):Bool {
		if (data.length != size) {
			return false;
		}
		var j:Int = 0;
		while (j < size) {
			if (data[j] != ((index + j) & 0xFF)) {
				return false;
			}
			j += 7;
		}
		return data[size - 1] == ((index + size - 1) & 0xFF);
	}

	/** `length` bytes of `data` arriving: appended to the session's input and parsed, as a read does. **/
	private static function arrive(ws:InternalWebSocket, data:ByteArray, offset:Int, length:Int):Void {
		ws.__input.position = ws.__input.length;
		ws.__input.writeBytes(data, offset, length);
		ws.__input.position = ws.__inputPosition;
		ws.__onData();
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

#if cpp
/** A socket whose input counts its reads, and its output its writes. */
private class CountingSocket extends sys.net.Socket {
	public var counting(default, null):CountingInput;
	public var written(default, null):CountingOutput;

	private var __own:haxe.io.Input;
	private var __ownOutput:haxe.io.Output;

	override private function init():Void {
		super.init();
		__own = input;
		counting = new CountingInput(input);
		input = counting;
		__ownOutput = output;
		written = new CountingOutput(output);
		output = written;
	}

	/** Puts the socket's own input and output back first: close() casts to them unchecked, and a null there crashes a release build. */
	override public function close():Void {
		input = __own;
		output = __ownOutput;
		super.close();
	}
}

/** Writes through `inner`, counting the writes. */
private class CountingOutput extends haxe.io.Output {
	public var writes(default, null):Int = 0;

	private final __inner:haxe.io.Output;

	public function new(inner:haxe.io.Output) {
		__inner = inner;
	}

	override public function writeByte(c:Int):Void {
		writes++;
		__inner.writeByte(c);
	}

	override public function writeBytes(buffer:Bytes, position:Int, length:Int):Int {
		writes++;
		return __inner.writeBytes(buffer, position, length);
	}

	override public function flush():Void {
		__inner.flush();
	}
}

/** Reads through `inner`, counting the reads and the ones that would have blocked. */
private class CountingInput extends haxe.io.Input {
	public var reads(default, null):Int = 0;
	public var blocked(default, null):Int = 0;

	private final __inner:haxe.io.Input;

	public function new(inner:haxe.io.Input) {
		__inner = inner;
	}

	override public function readByte():Int {
		return __inner.readByte();
	}

	override public function readBytes(buffer:Bytes, position:Int, length:Int):Int {
		reads++;
		try {
			return __inner.readBytes(buffer, position, length);
		} catch (e:Dynamic) {
			if (crossbyte._internal.socket.BlockedError.isBlocked(e)) {
				blocked++;
			}
			throw e;
		}
	}
}
#end
