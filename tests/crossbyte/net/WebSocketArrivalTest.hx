package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
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

	// ------------------------------------------------------------- helpers

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
