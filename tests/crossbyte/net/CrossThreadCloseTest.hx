package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketCloseEvent;
import utest.Assert;
import utest.Async;
#if target.threaded
import sys.thread.Deque;
import sys.thread.Thread;
#end

/**
	A connection closed from a thread that is not its runtime's is closed on
	its runtime: `close()` hands the close over, as `CrossByte.post` hands any
	work over, and returns.

	What a runtime owns, its socket registry, its timers, its listeners,
	is not thread-safe, and a close touches all three. A WebSocket's session
	took its timers from the calling thread: from any other its `close()`
	threw inside the heartbeat's clear, which was swallowed half way through,
	the close frame sent, the socket left open and registered, the
	heartbeat left running for good, and `close` never dispatched, and
	`closeWith()` threw the same error at its caller. A reliable session's
	`close()` threw at its caller, from its close timer. A plain socket and
	a `NetConnection` closed there, and told their listeners on the wrong
	thread.

	Each case closes from a real second thread, which the test thread waits
	for without pumping, so nothing touches the runtime from two threads at
	once whatever the code under test does.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.net.WebSocket)
@:access(crossbyte._internal.websocket.WebSocket)
class CrossThreadCloseTest extends utest.Test {
	#if target.threaded
	private static inline var DEADLINE:Float = 10.0;

	@:timeout(30000)
	public function testAWebSocketClosedFromAnotherThreadClosesOnItsRuntime(async:Async):Void {
		if (!crossbyte.crypto.SecureRandom.isSupported) {
			Assert.isFalse(crossbyte.crypto.SecureRandom.isSupported);
			async.done();
			return;
		}

		__webSocketPair(function(client:WebSocket, accepted:WebSocket, finish:Void->Void):Void {
			var runtime:CrossByte = CrossByte.current();
			var session = client.__webSocket;
			// The heartbeat a closed session leaves running fires for the
			// life of the process. Its flag said it had stopped either way:
			// the scheduler is what says whether it did.
			var heartbeat:Int = session.__heartbeat;
			Assert.isTrue(runtime.__timer.isActive(heartbeat), "an open session has no heartbeat to watch");
			var clientClose:WebSocketCloseEvent = null;
			var clientCloseOnRuntime:Bool = false;
			var acceptedClose:WebSocketCloseEvent = null;
			client.addEventListener(Event.CLOSE, function(e:Event) {
				clientClose = Std.downcast(e, WebSocketCloseEvent);
				clientCloseOnRuntime = CrossByte.__currentOrNull() == runtime;
			});
			accepted.addEventListener(Event.CLOSE, e -> acceptedClose = Std.downcast(e, WebSocketCloseEvent));

			var thrown:String = __fromAnotherThread(() -> client.close());
			Assert.isNull(thrown, "close() threw on another thread: " + thrown);

			NetPump.until(() -> clientClose != null && acceptedClose != null, DEADLINE, function(_) {
				Assert.notNull(clientClose, "the client never dispatched its close");
				Assert.isTrue(clientCloseOnRuntime, "the client's close was dispatched off its runtime's thread");
				if (clientClose != null) {
					Assert.equals(1000, clientClose.code, "the client closed with " + clientClose.code);
				}
				Assert.notNull(acceptedClose, "the server's session never heard the client close");
				Assert.isFalse(runtime.__timer.isActive(heartbeat), "the closed session's heartbeat is still running");
				finish();
			});
		}, async);
	}

	@:timeout(30000)
	public function testAWebSocketClosedWithACodeFromAnotherThreadSendsIt(async:Async):Void {
		if (!crossbyte.crypto.SecureRandom.isSupported) {
			Assert.isFalse(crossbyte.crypto.SecureRandom.isSupported);
			async.done();
			return;
		}

		__webSocketPair(function(client:WebSocket, accepted:WebSocket, finish:Void->Void):Void {
			var clientClose:WebSocketCloseEvent = null;
			var acceptedClose:WebSocketCloseEvent = null;
			client.addEventListener(Event.CLOSE, e -> clientClose = Std.downcast(e, WebSocketCloseEvent));
			accepted.addEventListener(Event.CLOSE, e -> acceptedClose = Std.downcast(e, WebSocketCloseEvent));

			var thrown:String = __fromAnotherThread(() -> client.closeWith(4001, "from another thread"));
			Assert.isNull(thrown, "closeWith() threw on another thread: " + thrown);

			NetPump.until(() -> clientClose != null && acceptedClose != null, DEADLINE, function(_) {
				Assert.notNull(acceptedClose, "the server's session never heard the close");
				if (acceptedClose != null) {
					Assert.equals(4001, acceptedClose.code, "the server's session heard " + acceptedClose.code);
					Assert.equals("from another thread", acceptedClose.reason);
				}
				Assert.notNull(clientClose, "the client never dispatched its close");
				finish();
			});
		}, async);
	}

	/**
		A session a server accepted, closed from another thread. Its client
		asks for the upgrade by hand, so this runs where no WebSocket client
		can, the interpreter, hl and neko have no secure random source for
		a client's key.
	**/
	@:timeout(30000)
	public function testAnAcceptedWebSocketClosedFromAnotherThreadClosesOnItsRuntime(async:Async):Void {
		var runtime:CrossByte = CrossByte.current();
		var server = new ServerWebSocket();
		var accepted:WebSocket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted = cast e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new Socket();
		var clientEnded:Bool = false;
		var failure:String = null;
		client.addEventListener(Event.CONNECT, function(_) {
			client.writeUTFBytes("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
				+ "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
			client.flush();
		});
		// Read as it comes, so nothing unread makes the client's own close a
		// reset.
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> client.readUTFBytes(client.bytesAvailable));
		client.addEventListener(Event.CLOSE, _ -> clientEnded = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, e -> failure = e.text);
		client.connect("127.0.0.1", server.localPort);

		NetPump.until(() -> accepted != null || failure != null, DEADLINE, function(_) {
			if (accepted == null) {
				Assert.fail("no session was accepted: " + failure);
				__quietly(() -> client.close());
				__quietly(() -> server.close());
				async.done();
				return;
			}

			var acceptedClose:WebSocketCloseEvent = null;
			var acceptedCloseOnRuntime:Bool = false;
			accepted.addEventListener(Event.CLOSE, function(e:Event) {
				acceptedClose = Std.downcast(e, WebSocketCloseEvent);
				acceptedCloseOnRuntime = CrossByte.__currentOrNull() == runtime;
			});

			var session = accepted.__webSocket;
			var heartbeat:Int = session.__heartbeat;
			Assert.isTrue(runtime.__timer.isActive(heartbeat), "an open session has no heartbeat to watch");
			var thrown:String = __fromAnotherThread(() -> accepted.close());
			Assert.isNull(thrown, "close() threw on another thread: " + thrown);

			NetPump.until(() -> acceptedClose != null && clientEnded, DEADLINE, function(_) {
				Assert.notNull(acceptedClose, "the session never dispatched its close");
				Assert.isTrue(acceptedCloseOnRuntime, "the session's close was dispatched off its runtime's thread");
				Assert.isTrue(clientEnded, "the client never saw the connection end");
				Assert.isFalse(runtime.__timer.isActive(heartbeat), "the closed session's heartbeat is still running");
				__quietly(() -> client.close());
				__quietly(() -> server.close());
				async.done();
			});
		});
	}

	@:timeout(30000)
	public function testASocketClosedFromAnotherThreadIsClosedOnItsRuntime(async:Async):Void {
		var runtime:CrossByte = CrossByte.current();
		var server = new ServerSocket();
		var accepted:Socket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted = e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new Socket();
		var connected:Bool = false;
		client.addEventListener(Event.CONNECT, _ -> connected = true);
		client.connect("127.0.0.1", server.localPort);

		NetPump.until(() -> connected && accepted != null, DEADLINE, function(_) {
			if (!connected || accepted == null) {
				Assert.fail("the connection never came up");
				__quietly(() -> client.close());
				__quietly(() -> server.close());
				async.done();
				return;
			}

			var closes:Int = 0;
			var closedOnRuntime:Bool = false;
			var peerEnded:Bool = false;
			client.addEventListener(Event.CLOSE, function(_) {
				closes++;
				closedOnRuntime = CrossByte.__currentOrNull() == runtime;
			});
			accepted.addEventListener(Event.CLOSE, _ -> peerEnded = true);

			var thrown:String = __fromAnotherThread(() -> client.close());
			Assert.isNull(thrown, "close() threw on another thread: " + thrown);

			NetPump.until(() -> closes > 0 && peerEnded, DEADLINE, function(_) {
				Assert.equals(1, closes, "the socket's close was dispatched " + closes + " times");
				Assert.isTrue(closedOnRuntime, "the socket's close was dispatched off its runtime's thread");
				Assert.isTrue(peerEnded, "the peer never saw the connection end");
				__quietly(() -> accepted.close());
				__quietly(() -> server.close());
				async.done();
			});
		});
	}

	@:timeout(30000)
	public function testANetConnectionClosedFromAnotherThreadEndsOnItsRuntime(async:Async):Void {
		var runtime:CrossByte = CrossByte.current();
		var server = new ServerSocket();
		var accepted:Socket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted = e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		var ready:Bool = false;
		var reasons:Array<Reason> = [];
		var endedOnRuntime:Bool = false;
		var connection = new NetConnection("tcp://127.0.0.1:" + server.localPort, null, () -> ready = true, function(reason:Reason) {
			reasons.push(reason);
			endedOnRuntime = CrossByte.__currentOrNull() == runtime;
		});

		NetPump.until(() -> ready && accepted != null, DEADLINE, function(_) {
			if (!ready || accepted == null) {
				Assert.fail("the connection never came up");
				__quietly(() -> connection.close());
				__quietly(() -> server.close());
				async.done();
				return;
			}

			var thrown:String = __fromAnotherThread(() -> connection.close());
			Assert.isNull(thrown, "close() threw on another thread: " + thrown);

			NetPump.until(() -> reasons.length > 0, DEADLINE, function(_) {
				Assert.equals(1, reasons.length, "onClose was called " + reasons.length + " times");
				Assert.isTrue(endedOnRuntime, "onClose was called off the connection's runtime's thread");
				if (reasons.length > 0) {
					Assert.equals(Reason.Closed, reasons[0]);
				}
				__quietly(() -> accepted.close());
				__quietly(() -> server.close());
				async.done();
			});
		});
	}

	@:timeout(30000)
	public function testAReliableSessionClosedFromAnotherThreadClosesOnItsRuntime(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			async.done();
			return;
		}

		var runtime:CrossByte = CrossByte.current();
		var server = new ReliableDatagramServerSocket();
		var accepted:ReliableDatagramSocket = null;
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> accepted = e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new ReliableDatagramSocket();
		var connected:Bool = false;
		client.addEventListener(Event.CONNECT, _ -> connected = true);
		client.connect("127.0.0.1", server.localPort);

		NetPump.until(() -> connected && accepted != null, DEADLINE, function(_) {
			if (!connected || accepted == null) {
				Assert.fail("the session never came up");
				__quietly(() -> client.abort());
				__quietly(() -> server.close());
				async.done();
				return;
			}

			var closedOnRuntime:Null<Bool> = null;
			var peerEnded:Bool = false;
			client.addEventListener(Event.CLOSE, _ -> closedOnRuntime = CrossByte.__currentOrNull() == runtime);
			accepted.addEventListener(Event.CLOSE, _ -> peerEnded = true);

			var thrown:String = __fromAnotherThread(() -> client.close());
			Assert.isNull(thrown, "close() threw on another thread: " + thrown);

			NetPump.until(() -> closedOnRuntime != null && peerEnded, DEADLINE, function(_) {
				Assert.isTrue(closedOnRuntime == true, "the session's close was dispatched off its runtime's thread, or never: " + closedOnRuntime);
				Assert.isTrue(peerEnded, "the peer never saw the session end");
				__quietly(() -> server.close());
				async.done();
			});
		});
	}

	/**
		A reliable datagram server closed from another thread stops what it
		runs on its runtime's tick, there: here a public-address question
		still waiting, which it fails, on the runtime's thread.

		Its close took the runtime from the calling thread to take its tick
		listeners off, which threw there and was swallowed: the question's
		tick stayed on the runtime for good, and the question was failed on
		the closing thread.
	**/
	@:timeout(30000)
	public function testAReliableServerClosedFromAnotherThreadStopsItsTicksOnItsRuntime(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported || !crossbyte.crypto.SecureRandom.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported && crossbyte.crypto.SecureRandom.isSupported);
			async.done();
			return;
		}

		var runtime:CrossByte = CrossByte.current();
		// A STUN server that never answers, so the question waits.
		var silent = new DatagramSocket();
		silent.bind(0, "127.0.0.1");
		silent.receive();

		var server = new ReliableDatagramServerSocket();
		server.bind(0, "127.0.0.1");
		server.listen();

		var failure:String = null;
		var failedOnRuntime:Bool = false;
		server.discoverPublicAddress("127.0.0.1", silent.localPort, 20000).then(_ -> {}, function(error:String) {
			failure = error;
			failedOnRuntime = CrossByte.__currentOrNull() == runtime;
		});

		NetPump.wait(0.2, function() {
			var tick = @:privateAccess server.__stunTick;
			Assert.isTrue(__listening(runtime, tick), "the question is not on the runtime's tick, so its absence says nothing");

			var thrown:String = __fromAnotherThread(() -> server.close());
			Assert.isNull(thrown, "close() threw on another thread: " + thrown);

			NetPump.until(() -> failure != null, DEADLINE, function(_) {
				Assert.notNull(failure, "the waiting question was never failed");
				Assert.isTrue(failedOnRuntime, "the question was failed off the runtime's thread");
				Assert.isFalse(__listening(runtime, tick), "the closed server's question is still on the runtime's tick");
				try silent.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/** Whether `listener` is among `runtime`'s tick listeners. **/
	@:access(crossbyte.events.EventDispatcher)
	private static function __listening(runtime:CrossByte, listener:Dynamic):Bool {
		if (listener == null || runtime.__eventMap == null) {
			return false;
		}
		var listeners:Array<Dynamic> = runtime.__eventMap.get(crossbyte.events.TickEvent.TICK);
		if (listeners == null) {
			return false;
		}
		for (entry in listeners) {
			if (Reflect.compareMethods(entry.listener, listener)) {
				return true;
			}
		}
		return false;
	}

	/**
		A WebSocket client and the session a server accepted for it, both
		open, handed to `then` with a `finish` that closes what is left.
	**/
	private static function __webSocketPair(then:(WebSocket, WebSocket, Void->Void)->Void, async:Async):Void {
		var server = new ServerWebSocket();
		var accepted:WebSocket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted = cast e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();
		var opened:Bool = false;
		var failure:String = null;
		client.addEventListener(Event.CONNECT, _ -> opened = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, e -> failure = e.text);
		client.connect("127.0.0.1", server.localPort);

		function finish():Void {
			__quietly(() -> client.close());
			__quietly(() -> accepted.close());
			__quietly(() -> server.close());
			async.done();
		}

		NetPump.until(() -> (opened && accepted != null) || failure != null, DEADLINE, function(_) {
			if (!opened || accepted == null) {
				Assert.fail("the session never opened: " + failure);
				finish();
				return;
			}
			then(client, accepted, finish);
		});
	}

	/**
		Runs `act` on a thread of its own, and waits for it, without
		pumping, so the runtime is touched by one thread at a time, then
		says what it threw, or null.
	**/
	private static function __fromAnotherThread(act:Void->Void):Null<String> {
		var outcome = new Deque<String>();
		Thread.create(function():Void {
			var thrown:String = "";
			try {
				act();
			} catch (e:Dynamic) {
				thrown = Std.string(e);
				if (thrown == "") {
					thrown = "an empty error";
				}
			}
			outcome.add(thrown);
		});
		var thrown:String = outcome.pop(true);
		return thrown == "" ? null : thrown;
	}

	private static function __quietly(close:Void->Void):Void {
		try {
			close();
		} catch (_:Dynamic) {}
	}
	#end
}
