package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	What a `WebSocket` client does on its own side of a connection, against
	servers that do not behave.
**/
class WebSocketClientTest extends utest.Test {
	#if (cpp || java || jvm || nodejs)
	/**
		A server that accepts the connection and never answers the upgrade.

		Nothing bounded the wait: `timeout` covered the TCP connect and no
		further, and a client that had sent its upgrade sat in CONNECTING for
		as long as the peer kept the connection open. A TLS listener spoken to
		in plain text is one such peer, and so is anything at the wrong port.
	**/
	@:timeout(20000)
	public function testAnUnansweredUpgradeIsGivenUpOnAfterTheTimeout(async:Async):Void {
		var server = new ServerSocket();
		var held:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) held.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();
		client.timeout = 400;

		var connected:Bool = false;
		var closed:Bool = false;
		var failure:String = null;
		var started:Float = 0.0;
		var took:Float = -1.0;

		client.addEventListener(Event.CONNECT, function(_) connected = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
		client.addEventListener(Event.CLOSE, function(_) {
			closed = true;
			took = haxe.Timer.stamp() - started;
		});

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			started = haxe.Timer.stamp();
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> closed || connected, 8.0, function(_) {
				Assert.isFalse(connected, "an upgrade nobody answered was reported as connected");
				Assert.isTrue(closed, "a client whose upgrade went unanswered was never given up on");
				Assert.isTrue(took >= 0.3 && took < 3.0, 'gave up after $took s against a timeout of 0.4 s');
				Assert.isTrue(failure != null && failure.indexOf("upgrade") >= 0, "the failure did not say what went unanswered: " + failure);

				for (socket in held) {
					try socket.close() catch (_:Dynamic) {}
				}
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		A `wss://` server that accepts the connection and never answers the
		TLS handshake is given up on at `timeout`.

		Natively the handshake had a fixed three seconds of its own, whatever
		`timeout` said, and on Node nothing bounded a connect until it had
		opened: a client there waited on a silent server for good.
	**/
	@:timeout(20000)
	public function testATlsHandshakeNobodyAnswersIsGivenUpOnAtTheTimeout(async:Async):Void {
		__againstASilentServer(true, 400, function(outcome) {
			Assert.isFalse(outcome.connected, "a TLS handshake nobody answered was reported as connected");
			Assert.isTrue(outcome.closed, "a client whose TLS handshake went unanswered was never given up on");
			Assert.isTrue(outcome.took >= 0.3 && outcome.took < 2.0, 'gave up after ${outcome.took} s against a timeout of 0.4 s');
			Assert.notNull(outcome.failure, "the client was not told why the connect failed");
		}, async);
	}

	/**
		A `timeout` of 0 waits as long as it takes, as the upgrade did and as
		Node did. Natively a connect still looking its host up failed at
		once, and a TLS handshake still gave up at its own three seconds.
	**/
	@:timeout(20000)
	public function testATimeoutOfZeroWaits(async:Async):Void {
		__againstASilentServer(true, 0, function(outcome) {
			Assert.isFalse(outcome.closed, "a connect with no deadline was given up on: " + outcome.failure);
			Assert.isNull(outcome.failure, "a connect with no deadline failed: " + outcome.failure);
		}, async, 3.6);
	}

	/**
		A server that answers the upgrade with a refusal fails the connect as
		any other failure does, and as a browser's WebSocket does: `ioError`
		saying so, then `close` with 1006. It closed with 1002 and no error,
		as if an open session had broken the protocol.
	**/
	@:timeout(15000)
	public function testARefusedUpgradeIsAFailedConnect(async:Async):Void {
		var server = new ServerWebSocket();
		server.upgrade = function(request:WebSocketRequest):Bool {
			request.status = 403;
			return false;
		};
		server.bind(0, "127.0.0.1");
		server.listen();

		__failedConnect(() -> server.localPort, function(events, failure) {
			Assert.same(["ioError", "close 1006"], events, "a refused upgrade did not end as a failed connect");
			Assert.isTrue(failure != null && failure.indexOf("403") >= 0, "the failure did not carry the server's answer: " + failure);
			try server.close() catch (_:Dynamic) {}
		}, async);
	}

	/**
		A server that hangs up before answering the upgrade is a failed
		connect too. It closed with 1006 and said nothing at all.
	**/
	@:timeout(15000)
	public function testAServerHangingUpBeforeTheUpgradeIsAFailedConnect(async:Async):Void {
		var server = new ServerSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			try e.socket.close() catch (_:Dynamic) {}
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		__failedConnect(() -> server.localPort, function(events, failure) {
			Assert.same(["ioError", "close 1006"], events, "a hang-up before the upgrade did not end as a failed connect");
			Assert.notNull(failure, "the client was not told why the connect failed");
			try server.close() catch (_:Dynamic) {}
		}, async);
	}

	/**
		Connects a `WebSocket` to the port `port` names once it is known, and
		calls `check` with the events it dispatched, `connect`, `ioError`
		and `close` with its code, in order, and the ioError's text.
	**/
	private function __failedConnect(port:Void->Int, check:(Array<String>, String)->Void, async:Async):Void {
		var client = new WebSocket();
		var events:Array<String> = [];
		var failure:String = null;
		client.addEventListener(Event.CONNECT, function(_) events.push("connect"));
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
			events.push("ioError");
			failure = e.text;
		});
		client.addEventListener(Event.CLOSE, function(e:Event) {
			var close = Std.downcast(e, crossbyte.events.WebSocketCloseEvent);
			events.push("close " + (close == null ? "?" : Std.string(close.code)));
		});

		NetPump.until(() -> port() != 0, 5.0, function(_) {
			client.connect("127.0.0.1", port());
			NetPump.until(() -> events.indexOf("connect") >= 0 || events.length >= 2, 8.0, function(_) {
				// A little longer, for anything dispatched after.
				NetPump.wait(0.2, function() {
					check(events, failure);
					try client.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	/**
		Connects a `WebSocket` with `timeout` to a server that accepts and
		then says nothing, and reports what became of it after `wait`
		seconds, or once it has closed.
	**/
	private function __againstASilentServer(secure:Bool, timeout:Int, check:SilentOutcome->Void, async:Async, wait:Float = 8.0):Void {
		var server = new ServerSocket();
		var held:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) held.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();
		client.secure = secure;
		client.verifyCert = false;
		client.timeout = timeout;

		var outcome:SilentOutcome = {connected: false, closed: false, failure: null, took: -1.0};
		var started:Float = 0.0;
		client.addEventListener(Event.CONNECT, function(_) outcome.connected = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) outcome.failure = e.text);
		client.addEventListener(Event.CLOSE, function(_) {
			outcome.closed = true;
			outcome.took = haxe.Timer.stamp() - started;
		});

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			started = haxe.Timer.stamp();
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> outcome.closed || outcome.connected, wait, function(_) {
				check(outcome);
				for (socket in held) {
					try socket.close() catch (_:Dynamic) {}
				}
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		A connection refused is reported as refused: an ioError that says
		so, and no CONNECT. On Linux and macOS a refused connect leaves the
		socket writable, which was taken for a connection, so the client sent
		its upgrade into nothing and ended in a 1006 that did not say why.
	**/
	@:timeout(15000)
	public function testARefusedConnectionSaysItWasRefused(async:Async):Void {
		// A port nothing listens on, obtained rather than assumed.
		var vacant = new ServerSocket();
		vacant.bind(0, "127.0.0.1");
		vacant.listen(1);

		NetPump.until(() -> vacant.localPort != 0, 5.0, function(_) {
			var port:Int = vacant.localPort;
			try vacant.close() catch (_:Dynamic) {}

			var client = new WebSocket();
			var connected:Bool = false;
			var closed:Bool = false;
			var failure:String = null;
			client.addEventListener(Event.CONNECT, function(_) connected = true);
			client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
			client.addEventListener(Event.CLOSE, function(_) closed = true);
			client.connect("127.0.0.1", port);

			NetPump.until(() -> connected || (failure != null && closed), 8.0, function(_) {
				Assert.isFalse(connected, "a refused connection was reported as connected");
				Assert.isTrue(failure != null && failure.toLowerCase().indexOf("refused") >= 0,
					"the failure did not say the connection was refused: " + failure);
				try client.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		A server whose answer to the upgrade never ends is given up on once
		16 KiB of it have arrived (`maxHeaderSize`), not at `timeout`: the
		client held every byte of it, copied whole with each arrival, for as
		long as the connect's deadline allowed.
	**/
	@:timeout(20000)
	public function testAnAnswerWithoutEndIsGivenUpOnAtTheLimit(async:Async):Void {
		var server = new ServerSocket();
		var held:Array<Socket> = [];
		var pad = new StringBuf();
		for (_ in 0...64 * 1024) {
			pad.add("a");
		}
		var endless:String = "HTTP/1.1 101 Switching Protocols\r\nX-Endless: " + pad.toString();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var socket:Socket = e.socket;
			held.push(socket);
			// Once the request has come: a head of 64 KiB with no end.
			socket.addEventListener(crossbyte.events.ProgressEvent.SOCKET_DATA, function(_) {
				if (socket.bytesAvailable > 0) {
					var discard = new crossbyte.io.ByteArray();
					socket.readBytes(discard, 0, socket.bytesAvailable);
					socket.writeUTFBytes(endless);
					socket.flush();
				}
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();
		client.timeout = 15000;
		var connected:Bool = false;
		var closed:Bool = false;
		var failure:String = null;
		var started:Float = 0.0;
		var took:Float = -1.0;
		client.addEventListener(Event.CONNECT, function(_) connected = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
		client.addEventListener(Event.CLOSE, function(_) {
			closed = true;
			took = haxe.Timer.stamp() - started;
		});

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			started = haxe.Timer.stamp();
			client.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> closed || connected, 8.0, function(_) {
				Assert.isFalse(connected, "an answer without end was taken for an upgrade");
				Assert.isTrue(closed, "a client reading an answer without end was never given up on");
				Assert.isTrue(took >= 0 && took < 5.0, 'gave up after $took s, against a timeout of 15 s');
				Assert.isTrue(failure != null && failure.indexOf("maxHeaderSize") >= 0, "the failure did not say the answer was too large: " + failure);
				for (socket in held) {
					try socket.close() catch (_:Dynamic) {}
				}
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		Each frame a client sends has a masking key of its own, drawn from a
		pool of random bytes four at a time: across more frames than one pool
		holds (2,048), no key is the one before it, nearly all are distinct,
		and every frame unmasks to what was sent. A key reused, or a pool
		refilled with what it held, would show here.
	**/
	@:timeout(30000)
	public function testEveryFrameAClientSendsHasAKeyOfItsOwn(async:Async):Void {
		var frames:Int = 3000;
		var server = new ServerSocket();
		var held:Array<Socket> = [];
		var received = new crossbyte.io.ByteArray();
		var answered:Bool = false;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var socket:Socket = e.socket;
			held.push(socket);
			socket.addEventListener(crossbyte.events.ProgressEvent.SOCKET_DATA, function(_) {
				socket.readBytes(received, received.length, socket.bytesAvailable);
				if (!answered) {
					// The request whole: answered as a server answers it.
					var request:String = received.toString();
					var end:Int = request.indexOf("\r\n\r\n");
					if (end < 0) {
						return;
					}
					var keyMatch = ~/Sec-WebSocket-Key: ([^\r]+)/;
					var key:String = keyMatch.match(request) ? keyMatch.matched(1) : "";
					var accept:String = haxe.crypto.Base64.encode(haxe.crypto.Sha1.make(haxe.io.Bytes.ofString(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
					socket.writeUTFBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept
						+ "\r\n\r\n");
					socket.flush();
					answered = true;
					// What follows the request is frames.
					var rest = new crossbyte.io.ByteArray();
					rest.writeBytes(received, end + 4, received.length - end - 4);
					received = rest;
				}
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();
		var connected:Bool = false;
		client.addEventListener(Event.CONNECT, function(_) connected = true);
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			client.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> connected, 5.0, function(_) {
				Assert.isTrue(connected, "the client never opened");
				for (i in 0...frames) {
					client.sendText("frame " + i);
				}
				// Each frame: 2 bytes of header, 4 of key, the text.
				var expected:Int = 0;
				for (i in 0...frames) {
					expected += 6 + ("frame " + i).length;
				}
				NetPump.until(() -> received.length >= expected, 10.0, function(_) {
					var keys = new Map<Int, Bool>();
					var at:Int = 0;
					var previous:Null<Int> = null;
					var repeats:Int = 0;
					var wrong:Int = 0;
					var bytes:haxe.io.Bytes = received;
					for (i in 0...frames) {
						var length:Int = bytes.get(at + 1) & 0x7F;
						var key:Int = bytes.getInt32(at + 2);
						if (previous != null && key == previous) {
							repeats++;
						}
						previous = key;
						keys.set(key, true);
						var text = new StringBuf();
						for (j in 0...length) {
							text.addChar(bytes.get(at + 6 + j) ^ bytes.get(at + 2 + (j & 3)));
						}
						if (text.toString() != "frame " + i) {
							wrong++;
						}
						at += 6 + length;
					}
					var distinct:Int = Lambda.count(keys);
					Assert.equals(0, repeats, "a frame had the key of the one before it");
					Assert.isTrue(distinct >= frames - 3, '$distinct distinct keys across $frames frames');
					Assert.equals(0, wrong, "frames did not unmask to what was sent");
					for (socket in held) {
						try socket.close() catch (_:Dynamic) {}
					}
					try client.close() catch (_:Dynamic) {}
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}
	#end
}

private typedef SilentOutcome = {
	var connected:Bool;
	var closed:Bool;
	var failure:String;
	var took:Float;
}
