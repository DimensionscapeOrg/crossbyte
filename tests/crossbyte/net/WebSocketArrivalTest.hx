package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.events._internal.Arrivals;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArray.ByteArrayData;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.Endian;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	"Copy it to keep it" on a WebSocket: a message is right while it is
	handled, every way of sending it back sends what arrived, queued behind
	a peer that is not reading, too, and what a listener keeps is what each
	mode says it is.
**/
@:access(crossbyte.net.WebSocket)
@:access(crossbyte.net.Socket)
@:access(crossbyte._internal.websocket.WebSocket)
class WebSocketArrivalTest extends utest.Test {
	@:timeout(15000)
	public function testAMessageIsItselfInItsCallAndAKeptOneIsWhatTheModeSays(async:Async):Void {
		__serve(async, function(server, sessions, finish) {
			var client = new WebSocket();
			client.connect("127.0.0.1", server.localPort);
			var during:Array<String> = [];
			var clones:Array<WebSocketMessageEvent> = [];
			var kept:Array<WebSocketMessageEvent> = [];
			var keptData:Array<ByteArray> = [];

			NetPump.until(() -> client.connected && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish([client]);
					return;
				}
				sessions[0].addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent):Void {
					during.push((e.isText ? "text:" : "binary:") + e.text + ":" + e.data.position);
					clones.push(cast e.clone());
					kept.push(e);
					keptData.push(e.data);
				});
				client.sendText("first, as text");
				client.sendBinary(bytesOf("second, binary"));
				client.sendText("third");

				NetPump.until(() -> during.length >= 3, 5.0, function(_) {
					Assert.same(["text:first, as text:0", "binary:second, binary:0", "text:third:0"], during);
					if (clones.length == 3) {
						Assert.equals("first, as text", clones[0].text);
						Assert.equals("second, binary", clones[1].data.toString());
						Assert.isFalse(clones[1].isText);
						Assert.equals("third", clones[2].text);
						#if crossbyte_check_events
						for (i in 0...3) {
							Assert.equals(0, keptData[i].length, "a message kept past its call was left alive");
							Assert.isFalse(kept[i].isText, "an event kept past its call still said what it was");
						}
						#elseif crossbyte_fresh_events
						Assert.equals("second, binary", keptData[1].toString());
						Assert.equals("third", kept[2].text);
						#else
						// Released: the session's one event and one message
						// buffer, handed out for each message and emptied once
						// its call returned, its text with it.
						Assert.isTrue(kept[0] == kept[1] && kept[1] == kept[2], "the session's event was not handed out again");
						Assert.isTrue(keptData[0] == keptData[1] && keptData[1] == keptData[2], "the session's message buffer was not read into again");
						Assert.equals(0, keptData[2].length, "a message kept past its call still read whole");
						Assert.equals("", kept[2].text, "an event kept past its call still said what its message was");
						#end
					}
					finish([client]);
				});
			});
		});
	}

	@:timeout(15000)
	public function testEveryWayOfSendingAMessageBackSendsWhatArrived(async:Async):Void {
		__serve(async, function(server, sessions, finish) {
			var client = new WebSocket();
			var back:Array<String> = [];
			client.addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent):Void {
				back.push((e.isText ? "text:" : "binary:") + e.text);
			});
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> client.connected && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish([client]);
					return;
				}
				var session = sessions[0];
				var count:Int = 0;
				session.addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent):Void {
					count++;
					switch (count) {
						case 1:
							session.sendBinary(e.data);
						case 2:
							session.writeBytes(e.data);
							session.flush();
						case 3:
							session.sendText(e.text);
						default:
							// And from the middle of what arrived.
							session.sendBinary(e.data, 2, 3);
					}
				});
				for (message in ["sent back as binary", "written and flushed", "sent back as text", "a part of it"]) {
					client.sendBinary(bytesOf(message));
				}

				NetPump.until(() -> back.length >= 4, 5.0, function(_) {
					Assert.same(["binary:sent back as binary", "binary:written and flushed", "text:sent back as text", "binary:par"], back);
					finish([client]);
				});
			});
		});
	}

	@:timeout(15000)
	public function testTheStreamKeepsWhatArrivedAndItsEventIsWhatTheModeSays(async:Async):Void {
		__serve(async, function(server, sessions, finish) {
			var client = new WebSocket();
			client.connect("127.0.0.1", server.localPort);
			var loaded:Array<Int> = [];
			var kept:Array<ProgressEvent> = [];

			NetPump.until(() -> client.connected && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish([client]);
					return;
				}
				var session = sessions[0];
				// No MESSAGE listener: what arrives goes into the stream.
				session.addEventListener(ProgressEvent.SOCKET_DATA, function(e:ProgressEvent):Void {
					loaded.push(e.bytesLoaded);
					kept.push(e);
				});
				client.sendBinary(bytesOf("one "));
				client.sendBinary(bytesOf("two "));
				client.sendBinary(bytesOf("three"));

				NetPump.until(() -> session.bytesAvailable >= 13, 5.0, function(_) {
					Assert.equals("one two three", session.readUTFBytes(session.bytesAvailable), "the stream lost what arrived");
					var total:Int = 0;
					for (count in loaded) {
						total += count;
					}
					Assert.equals(13, total, "SOCKET_DATA did not say what arrived while it was handled");
					#if crossbyte_check_events
					for (event in kept) {
						Assert.isTrue(event.bytesLoaded == (cast -1 : UInt), "a SOCKET_DATA event kept past its call still said what arrived");
					}
					#elseif crossbyte_fresh_events
					Assert.isTrue(kept[0] != kept[1], "a SOCKET_DATA event was handed out twice");
					#else
					// Released: the socket's one SOCKET_DATA event, as a plain
					// socket hands out.
					for (event in kept) {
						Assert.isTrue(event == kept[0], "the session's SOCKET_DATA event was not handed out again");
					}
					#end
					finish([client]);
				});
			});
		});
	}

	@:timeout(15000)
	public function testANetConnectionsInputIsItsOwnToKeep(async:Async):Void {
		__serve(async, function(server, sessions, finish) {
			var client = new WebSocket();
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> client.connected && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish([client]);
					return;
				}
				// The connection's own input, kept and read a frame later, once
				// more has arrived.
				var connection:NetConnection = NetConnection.fromWebSocket(sessions[0]);
				var kept:ByteArrayInput = null;
				var calls:Int = 0;
				connection.onData = input -> {
					calls++;
					kept = input;
				};
				connection.readEnabled = true;
				client.sendBinary(bytesOf("kept "));
				client.sendBinary(bytesOf("and read later"));

				NetPump.until(() -> calls >= 2 || (kept != null && kept.bytesAvailable >= 19), 5.0, function(_) {
					Require.notNull(kept, "onData was never called");
					Assert.equals("kept and read later", kept.readUTFBytes(19), "the input kept past its call lost what arrived");
					connection.readEnabled = false;
					finish([client]);
				});
			});
		});
	}

	#if (sys && !eval)
	/**
		An echo the peer is not reading: queued, behind the kernel's buffers,
		long after the message it echoes has gone, and still that message.
	**/
	@:timeout(30000)
	public function testAnEchoQueuedBehindAPeerNotReadingIsWhatArrived(async:Async):Void {
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		var queued:Int = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var session:WebSocket = cast e.socket;
			sessions.push(session);
			session.addEventListener(WebSocketMessageEvent.MESSAGE, function(m:WebSocketMessageEvent):Void {
				session.sendBinary(m.data);
				if (session.outputBufferLength > queued) {
					queued = session.outputBufferLength;
				}
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client:RawWebSocketClient = null;
		try {
			client = new RawWebSocketClient(CrossByte.current(), "127.0.0.1", server.localPort);
			var count:Int = 40;
			var size:Int = 60000;
			for (i in 0...count) {
				client.send(0x02, pattern(size, i));
			}
			// The server takes every message and echoes it while the client
			// reads nothing: what the kernel will not hold waits in the session.
			client.pumpFor(0.5);
			Assert.isTrue(queued > 0, "nothing was ever queued, so the echo was not tested behind a peer that is not reading");

			for (i in 0...count) {
				var frame = client.readFrame(10.0);
				if (frame == null) {
					Assert.fail("echo " + i + " never came");
					break;
				}
				Assert.equals(-1, wrongByte(frame.payload, size, i), "echo " + i + " carried another message's bytes");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		if (client != null) {
			client.close();
		}
		for (session in sessions) {
			try session.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
		async.done();
	}
	#end

	#if (sys && !eval)
	/**
		Message after message, whole and in fragments, masked as a client
		sends them: each is right in its call, from position 0 in the
		session's byte order whatever the one before was left as; a clone
		keeps its bytes after later messages; and storage a message grew past
		`Arrivals.KEEP` is let go once its call returns.
	**/
	@:timeout(30000)
	public function testEachMessageIsRightInWhatTheSessionHandsOutAgain(async:Async):Void {
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		var seen:Array<String> = [];
		var clones:Array<WebSocketMessageEvent> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var session:WebSocket = cast e.socket;
			sessions.push(session);
			session.endian = Endian.BIG_ENDIAN;
			session.addEventListener(WebSocketMessageEvent.MESSAGE, function(m:WebSocketMessageEvent):Void {
				var data:ByteArray = m.data;
				var first:Int = data.readUnsignedShort();
				seen.push(data.position + ":" + data.length + ":" + (data.endian == Endian.BIG_ENDIAN ? "big" : "little") + ":" + first);
				clones.push(cast m.clone());
				// Left at its end and in the other order: the next is not to
				// start where this one was left.
				data.position = data.length;
				data.endian = Endian.LITTLE_ENDIAN;
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client:RawWebSocketClient = null;
		var sizes:Array<Int> = [3000, 40, 20000, 2600];
		try {
			client = new RawWebSocketClient(CrossByte.current(), "127.0.0.1", server.localPort);
			for (i in 0...sizes.length) {
				var message:Bytes = pattern(sizes[i], i);
				if (sizes[i] > 1000) {
					// The first frame and two continuations, each unmasked
					// where it lands in the message.
					var third:Int = Std.int(sizes[i] / 3);
					client.send(0x02, message.sub(0, third), false);
					client.send(0x00, message.sub(third, third), false);
					client.send(0x00, message.sub(2 * third, sizes[i] - 2 * third), true);
				} else {
					client.send(0x02, message);
				}
			}
			var deadline:Float = haxe.Timer.stamp() + 10.0;
			while (seen.length < sizes.length && haxe.Timer.stamp() < deadline) {
				client.pumpFor(0.01);
			}

			var expected:Array<String> = [];
			for (i in 0...sizes.length) {
				var lead:Int = (((i * 7) & 0xFF) << 8) | ((31 + i * 7) & 0xFF);
				expected.push('2:${sizes[i]}:big:$lead');
			}
			Assert.same(expected, seen, "a message was not itself in its call");
			for (i in 0...clones.length) {
				var copy:Bytes = clones[i].data;
				Assert.equals(-1, wrongByte(copy.sub(0, clones[i].data.length), sizes[i], i), 'clone $i lost its bytes to a later message');
			}
			if (sessions.length == 1) {
				var parser = sessions[0].__webSocket;
				#if !(crossbyte_fresh_events || crossbyte_check_events)
				Assert.notNull(parser.__messageKept, "no message was read into the session's own buffer");
				var held:Int = capacityOf(parser.__messageKept);
				Assert.isTrue(held <= Arrivals.KEEP, "a 20,000-byte message's storage was held after its call: " + held);
				Assert.isFalse(parser.__messageOut || sessions[0].__messageEventOut, "something was left out after its call");
				#else
				Assert.isNull(parser.__messageKept, "a buffer was kept for reuse with reuse off");
				Assert.isNull(sessions[0].__messageEvent, "an event was kept for reuse with reuse off");
				#end
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		if (client != null) {
			client.close();
		}
		for (session in sessions) {
			try session.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
		async.done();
	}

	/**
		A message arriving inside a listener's call, the listener pumps, and
		the session reads the next, gets an event and a buffer of its own,
		and the message being handled is left as it was.
	**/
	@:timeout(30000)
	public function testAMessageArrivingInsideAListenersCallHasItsOwnEventAndBytes(async:Async):Void {
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		var runtime = CrossByte.current();
		var client:RawWebSocketClient = null;
		var depth:Int = 0;
		var outerEvent:WebSocketMessageEvent = null;
		var outerData:ByteArray = null;
		var nestedEvent:WebSocketMessageEvent = null;
		var nestedData:ByteArray = null;
		var nested:String = null;
		var outerAfter:String = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var session:WebSocket = cast e.socket;
			sessions.push(session);
			session.addEventListener(WebSocketMessageEvent.MESSAGE, function(m:WebSocketMessageEvent):Void {
				depth++;
				if (depth == 1) {
					outerEvent = m;
					outerData = m.data;
					// The next message is sent now, and arrives while this one
					// is being handled.
					client.send(0x02, Bytes.ofString("the nested one, which is longer"));
					var deadline:Float = haxe.Timer.stamp() + 5.0;
					while (nested == null && haxe.Timer.stamp() < deadline) {
						runtime.pump(0, 0);
						crossbyte.sys.System.sleep(0.001);
					}
					m.data.position = 0;
					outerAfter = m.data.readUTFBytes(m.data.length);
				} else {
					nestedEvent = m;
					nestedData = m.data;
					nested = m.data.readUTFBytes(m.data.length);
				}
				depth--;
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		try {
			client = new RawWebSocketClient(runtime, "127.0.0.1", server.localPort);
			client.send(0x02, Bytes.ofString("the outer one"));
			var deadline:Float = haxe.Timer.stamp() + 10.0;
			while (outerAfter == null && haxe.Timer.stamp() < deadline) {
				client.pumpFor(0.01);
			}
			Assert.equals("the nested one, which is longer", nested, "the nested message was not delivered as itself");
			Assert.equals("the outer one", outerAfter, "a message arriving inside a listener changed the one it was handling");
			Assert.isTrue(nestedEvent != null && nestedEvent != outerEvent, "a nested message was handed the event still out");
			Assert.isTrue(nestedData != null && nestedData != outerData, "a nested message was read into the buffer still out");
			#if !(crossbyte_fresh_events || crossbyte_check_events)
			if (sessions.length == 1) {
				Assert.isTrue(outerEvent == sessions[0].__messageEvent, "the outer message was not handed out in the session's own event");
				Assert.isTrue(outerData == sessions[0].__webSocket.__messageKept, "the outer message was not read into the session's own buffer");
			}
			#end
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		if (client != null) {
			client.close();
		}
		for (session in sessions) {
			try session.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
		async.done();
	}
	#end

	/**
		A listener that throws lets go of what it was handed, in both layers:
		the framing layer's message buffer, and the session's event. The next
		message is right, and goes through each again.
	**/
	public function testAListenerThatThrowsLeavesTheNextMessageRight():Void {
		// The framing layer, handed frames as they are read.
		var parser = openParser();
		var calls:Int = 0;
		var handed:Array<ByteArray> = [];
		var after:Array<String> = [];
		parser.__onMessage = function(message:ByteArray, isText:Bool):Void {
			calls++;
			handed.push(message);
			if (calls == 1) {
				message.position = 3;
				throw "a listener's own failure";
			}
			after.push(message.readUTFBytes(message.length));
		};
		append(parser, frame(0x02, "first, which the listener throws on"));
		var thrown:Dynamic = null;
		try {
			parser.__onData();
		} catch (e:Dynamic) {
			thrown = e;
		}
		Assert.equals("a listener's own failure", Std.string(thrown), "the listener's throw did not come back out");
		Assert.isFalse(parser.__messageOut, "a listener's throw left the message buffer out");
		append(parser, frame(0x02, "second"));
		parser.__onData();
		Assert.same(["second"], after, "the message after a listener threw was wrong");
		#if !(crossbyte_fresh_events || crossbyte_check_events)
		Assert.isTrue(handed[0] == handed[1], "the message after a throw was not read into the session's own buffer");
		#end

		// The session, handed whole messages.
		var session = new WebSocket();
		var events:Array<WebSocketMessageEvent> = [];
		var texts:Array<String> = [];
		session.addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent):Void {
			events.push(e);
			if (events.length == 1) {
				throw "a listener's own failure";
			}
			texts.push(e.text);
		});
		thrown = null;
		try {
			session.__messageArrived(bytesOf("thrown on"), true);
		} catch (e:Dynamic) {
			thrown = e;
		}
		Assert.equals("a listener's own failure", Std.string(thrown));
		Assert.isFalse(session.__messageEventOut, "a listener's throw left the session's event out");
		session.__messageArrived(bytesOf("after"), true);
		Assert.same(["after"], texts);
		#if !(crossbyte_fresh_events || crossbyte_check_events)
		Assert.isTrue(events[0] == events[1], "the message after a throw was not handed out in the session's own event");
		#end
	}

	// ------------------------------------------------------------- helpers

	/** A framing layer open as a client's is, reading what `append` gives it. **/
	private static function openParser():crossbyte._internal.websocket.WebSocket {
		var parser:crossbyte._internal.websocket.WebSocket = Type.createEmptyInstance(crossbyte._internal.websocket.WebSocket);
		parser.readyState = crossbyte._internal.websocket.WebSocket.OPEN;
		parser.__isClient = true;
		parser.__input = new ByteArray();
		parser.__input.endian = Endian.BIG_ENDIAN;
		parser.__inputPosition = 0;
		parser.__incomingOpcode = -1;
		parser.__incomingMessageSize = 0;
		parser.__messageOut = false;
		parser.onclose = _ -> {};
		parser.onerror = _ -> {};
		parser.onopen = _ -> {};
		return parser;
	}

	/** `bytes` after whatever `parser` has not read yet. **/
	private static function append(parser:crossbyte._internal.websocket.WebSocket, bytes:ByteArray):Void {
		var input:ByteArray = parser.__input;
		var at:Int = input.position;
		input.position = input.length;
		input.writeBytes(bytes, 0, bytes.length);
		input.position = at;
	}

	/** An unmasked frame, as a server sends one, of `text`. **/
	private static function frame(opcode:Int, text:String):ByteArray {
		var payload = Bytes.ofString(text);
		var frame = new ByteArray();
		frame.endian = Endian.BIG_ENDIAN;
		frame.writeByte(0x80 | opcode);
		frame.writeByte(payload.length);
		frame.writeBytes(payload, 0, payload.length);
		frame.position = 0;
		return frame;
	}

	/** The storage a payload holds, readable or not; 0 for none. **/
	private static function capacityOf(payload:ByteArray):Int {
		if (payload == null) {
			return 0;
		}
		var data:ByteArrayData = payload;
		return @:privateAccess data.__length;
	}

	private function __serve(async:Async, body:(ServerWebSocket, Array<WebSocket>, Array<WebSocket>->Void)->Void):Void {
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) sessions.push(cast e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		function finish(clients:Array<WebSocket>):Void {
			for (client in clients) {
				try client.close() catch (_:Dynamic) {}
			}
			for (session in sessions) {
				try session.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			NetPump.wait(0.1, () -> async.done());
		}

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) body(server, sessions, finish));
	}

	private static function bytesOf(text:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(text);
		bytes.position = 0;
		return bytes;
	}

	private static function pattern(length:Int, seed:Int):Bytes {
		var bytes = Bytes.alloc(length);
		for (i in 0...length) {
			bytes.set(i, (i * 31 + seed * 7) & 0xFF);
		}
		return bytes;
	}

	private static function wrongByte(bytes:Bytes, length:Int, seed:Int):Int {
		if (bytes == null || bytes.length != length) {
			return -2;
		}
		for (i in 0...length) {
			if (bytes.get(i) != ((i * 31 + seed * 7) & 0xFF)) {
				return i;
			}
		}
		return -1;
	}
}
