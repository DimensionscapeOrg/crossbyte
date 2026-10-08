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

	What a runtime owns (its socket registry, its timers, its listeners)
	is not thread-safe, and a close touches all three. Run from another
	thread, a WebSocket session's `close()` taking its timers from the
	calling thread would throw inside the heartbeat's clear, swallowed half
	way through (the close frame sent, the socket left open and registered,
	the heartbeat left running for good, and `close` never dispatched), and
	`closeWith()` would throw the same error at its caller; a reliable
	session's `close()` would throw at its caller, from its close timer; and
	a plain socket and a `NetConnection` would close there, and tell their
	listeners on the wrong thread.

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
			// The heartbeat a closed session leaves running would fire for the
			// life of the process. Its flag says it has stopped either way: the
			// scheduler is what says whether it did.
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
		can: the interpreter, hl and neko have no secure random source for
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

		Taking the runtime from the calling thread to take its tick listeners
		off would throw there and be swallowed: the question's tick would stay
		on the runtime for good, and the question be failed on the closing
		thread.
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

	/**
		A server closed from another thread lets go of its runtime there: its
		listener leaves the runtime's poll set, and its tick the runtime's
		listeners, on the runtime's thread, plain and WebSocket alike, not from
		the closing thread, while the runtime might be polling the listener or
		dispatching its tick: neither is thread-safe.
	**/
	@:timeout(30000)
	public function testAServerClosedFromAnotherThreadLetsGoOnItsRuntime(async:Async):Void {
		var runtime:CrossByte = CrossByte.current();
		var before:Int = __tickListeners(runtime);
		var plain = new ThreadNotingServerSocket(runtime);
		var web = new ThreadNotingServerWebSocket(runtime);
		var servers:Array<ServerSocket> = [plain, web];
		for (server in servers) {
			server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> {});
			server.bind(0, "127.0.0.1");
			server.listen();
		}
		Assert.isTrue(__tickListeners(runtime) > before, "the WebSocket server put no tick on the runtime, so its absence says nothing");

		for (server in servers) {
			var thrown:String = __fromAnotherThread(() -> server.close());
			Assert.isNull(thrown, "close() threw on another thread: " + thrown);
		}

		NetPump.until(() -> !plain.listening && !web.listening, DEADLINE, function(_) {
			Assert.isTrue(plain.letGo && web.letGo, "a server closed from another thread never let go of its runtime");
			Assert.isFalse(plain.letGoOffRuntime, "the server let go of its runtime's poll set from the closing thread");
			Assert.isFalse(web.letGoOffRuntime, "the WebSocket server let go of its runtime's poll set and tick from the closing thread");
			Assert.isFalse(plain.listening || web.listening, "a server closed from another thread is still listening");
			Assert.equals(before, __tickListeners(runtime), "a server closed from another thread left its tick on the runtime");
			async.done();
		});
	}

	/** `stopAccepting()`, the first half of a graceful shutdown, likewise. **/
	@:timeout(30000)
	public function testAServerStoppedFromAnotherThreadLetsGoOnItsRuntime(async:Async):Void {
		var runtime:CrossByte = CrossByte.current();
		var before:Int = __tickListeners(runtime);
		var plain = new ThreadNotingServerSocket(runtime);
		var web = new ThreadNotingServerWebSocket(runtime);
		var servers:Array<ServerSocket> = [plain, web];
		for (server in servers) {
			server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> {});
			server.bind(0, "127.0.0.1");
			server.listen();
		}

		for (server in servers) {
			var thrown:String = __fromAnotherThread(() -> server.stopAccepting());
			Assert.isNull(thrown, "stopAccepting() threw on another thread: " + thrown);
		}

		NetPump.until(() -> !plain.listening && !web.listening, DEADLINE, function(_) {
			Assert.isTrue(plain.letGo && web.letGo, "a server stopped from another thread never let go of its runtime");
			Assert.isFalse(plain.letGoOffRuntime, "the server let go of its runtime's poll set from the stopping thread");
			Assert.isFalse(web.letGoOffRuntime, "the WebSocket server let go of its runtime's poll set and tick from the stopping thread");
			Assert.equals(before, __tickListeners(runtime), "a server stopped from another thread left its tick on the runtime");
			for (server in servers) {
				try server.close() catch (_:Dynamic) {}
			}
			async.done();
		});
	}

	/**
		A WebSocket server drained from another thread: `onComplete` is
		called on the runtime's thread, as `drain` promises, even with no
		session open, where the drain finishes at once: not on the calling
		thread, with the server closed there.
	**/
	@:timeout(30000)
	public function testAServerDrainedFromAnotherThreadCompletesOnItsRuntime(async:Async):Void {
		var runtime:CrossByte = CrossByte.current();
		var server = new ThreadNotingServerWebSocket(runtime);
		server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> {});
		server.bind(0, "127.0.0.1");
		server.listen();

		var completed:Bool = false;
		var completedOnRuntime:Bool = false;
		var thrown:String = __fromAnotherThread(() -> server.drain(1.0, function() {
			completed = true;
			completedOnRuntime = CrossByte.__currentOrNull() == runtime;
		}));
		Assert.isNull(thrown, "drain() threw on another thread: " + thrown);

		NetPump.until(() -> completed, DEADLINE, function(_) {
			Assert.isTrue(completed, "a drain begun on another thread never completed");
			Assert.isTrue(completedOnRuntime, "onComplete was called off the server's runtime's thread");
			Assert.isFalse(server.letGoOffRuntime, "the drained server let go of its runtime from the draining thread");
			Assert.isFalse(server.listening, "the drained server is still listening");
			async.done();
		});
	}

	/**
		A datagram socket closed from another thread closes on its runtime:
		out of the runtime's poll set there, and `close` dispatched there,
		once, not on the closing thread.
	**/
	@:timeout(30000)
	public function testADatagramSocketClosedFromAnotherThreadClosesOnItsRuntime(async:Async):Void {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			async.done();
			return;
		}

		var runtime:CrossByte = CrossByte.current();
		var socket = new ThreadNotingDatagramSocket(runtime);
		socket.bind(0, "127.0.0.1");
		socket.addEventListener(crossbyte.events.DatagramSocketDataEvent.DATA, _ -> {});
		socket.receive();
		Assert.isTrue(@:privateAccess socket.__registered, "the socket is not in the runtime's poll set, so leaving it says nothing");

		var closes:Int = 0;
		var closedOnRuntime:Bool = false;
		socket.addEventListener(Event.CLOSE, function(_) {
			closes++;
			closedOnRuntime = CrossByte.__currentOrNull() == runtime;
		});

		var thrown:String = __fromAnotherThread(() -> socket.close());
		Assert.isNull(thrown, "close() threw on another thread: " + thrown);

		NetPump.until(() -> closes > 0, DEADLINE, function(_) {
			Assert.equals(1, closes, "the socket's close was dispatched " + closes + " times");
			Assert.isTrue(closedOnRuntime, "the socket's close was dispatched off its runtime's thread");
			Assert.isFalse(socket.pollChangedOffRuntime, "the socket left its runtime's poll set from the closing thread");
			Assert.isFalse(@:privateAccess socket.__registered, "the closed socket is still in its runtime's poll set");
			async.done();
		});
	}

	/** `stopReceiving()` likewise leaves the poll set on the runtime's thread. **/
	@:timeout(30000)
	public function testADatagramSocketStoppedFromAnotherThreadStopsOnItsRuntime(async:Async):Void {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			async.done();
			return;
		}

		var runtime:CrossByte = CrossByte.current();
		var socket = new ThreadNotingDatagramSocket(runtime);
		socket.bind(0, "127.0.0.1");
		socket.addEventListener(crossbyte.events.DatagramSocketDataEvent.DATA, _ -> {});
		socket.receive();

		var thrown:String = __fromAnotherThread(() -> socket.stopReceiving());
		Assert.isNull(thrown, "stopReceiving() threw on another thread: " + thrown);

		NetPump.until(() -> !socket.receiving, DEADLINE, function(_) {
			Assert.isFalse(socket.receiving, "a socket stopped from another thread is still receiving");
			Assert.isFalse(socket.pollChangedOffRuntime, "the socket left its runtime's poll set from the stopping thread");
			Assert.isFalse(@:privateAccess socket.__registered, "the stopped socket is still in its runtime's poll set");
			try socket.close() catch (_:Dynamic) {}
			async.done();
		});
	}

	/**
		An ICE agent detached from another thread stops on its server's
		runtime: its tick comes off the runtime there, not from the detaching
		thread.
	**/
	@:timeout(30000)
	public function testAnAgentDetachedFromAnotherThreadStopsOnItsRuntime(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported || !crossbyte.net.ice.IceAgent.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported && crossbyte.net.ice.IceAgent.isSupported);
			async.done();
			return;
		}

		var runtime:CrossByte = CrossByte.current();
		var server = new ThreadNotingReliableServer(runtime);
		server.bind(0, "127.0.0.1");
		server.listen();
		server.attachIceAgent(new crossbyte.net.ice.IceAgent(true));
		var tick = @:privateAccess server.__iceTick;
		Assert.isTrue(__listening(runtime, tick), "the agent is not on the runtime's tick, so its absence says nothing");

		var thrown:String = __fromAnotherThread(() -> server.detachIceAgent());
		Assert.isNull(thrown, "detachIceAgent() threw on another thread: " + thrown);

		NetPump.until(() -> !__listening(runtime, tick), DEADLINE, function(_) {
			Assert.isFalse(__listening(runtime, tick), "the detached agent is still on the runtime's tick");
			Assert.isFalse(server.untickedOffRuntime, "the agent's tick was taken off the runtime from the detaching thread");
			__quietly(() -> server.close());
			async.done();
		});
	}

	/**
		A relay released from another thread, its allocation still waiting:
		the `allocateRelay` it fails is failed on the server's runtime, and the
		relay's tick comes off there, not on the releasing thread.
	**/
	@:timeout(30000)
	public function testARelayReleasedFromAnotherThreadEndsOnItsRuntime(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported || !TurnClient.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported && TurnClient.isSupported);
			async.done();
			return;
		}

		var runtime:CrossByte = CrossByte.current();
		// A relay that never answers, so the allocation waits.
		var silent = new DatagramSocket();
		silent.bind(0, "127.0.0.1");
		silent.receive();

		var server = new ThreadNotingReliableServer(runtime);
		server.bind(0, "127.0.0.1");
		server.listen();

		var failure:String = null;
		var failedOnRuntime:Bool = false;
		server.allocateRelay("127.0.0.1", silent.localPort, "user", "secret").then(_ -> {}, function(error:String) {
			failure = error;
			failedOnRuntime = CrossByte.__currentOrNull() == runtime;
		});
		var tick = @:privateAccess server.__relayTick;
		Assert.isTrue(__listening(runtime, tick), "the relay is not on the runtime's tick, so its absence says nothing");

		var thrown:String = __fromAnotherThread(() -> server.releaseRelay());
		Assert.isNull(thrown, "releaseRelay() threw on another thread: " + thrown);

		NetPump.until(() -> failure != null, DEADLINE, function(_) {
			Assert.notNull(failure, "the waiting allocation was never failed");
			Assert.isTrue(failedOnRuntime, "the allocation was failed off the runtime's thread");
			Assert.isNull(server.relay, "the released relay is still the server's");
			Assert.isFalse(__listening(runtime, tick), "the released relay is still on the runtime's tick");
			Assert.isFalse(server.untickedOffRuntime, "the relay's tick was taken off the runtime from the releasing thread");
			__quietly(() -> server.close());
			__quietly(() -> silent.close());
			async.done();
		});
	}

	@:access(crossbyte.events.EventDispatcher)
	private static function __tickListeners(runtime:CrossByte):Int {
		var list:Array<Dynamic> = runtime.__eventMap == null ? null : runtime.__eventMap.get(crossbyte.events.TickEvent.TICK);
		return list == null ? 0 : list.length;
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
		Runs `act` on a thread of its own, and waits for it (without
		pumping, so the runtime is touched by one thread at a time), then
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

#if target.threaded
/**
	Notes the thread a server lets go of its runtime on: where its listener
	leaves the runtime's poll set and its tick the runtime's listeners.
	The fields are set in the constructor, before another thread can write
	them: on neko a field first set by another thread can move the object's
	field table under the runtime.
**/
@:access(crossbyte.core.CrossByte)
private class ThreadNotingServerSocket extends ServerSocket {
	public var letGo:Bool;
	public var letGoOffRuntime:Bool;

	private var __owner:CrossByte;

	public function new(owner:CrossByte) {
		letGo = false;
		letGoOffRuntime = false;
		__owner = owner;
		super();
	}

	override private function __detachAcceptTick():Void {
		if (__acceptRuntime != null) {
			letGo = true;
			if (CrossByte.__currentOrNull() != __owner) {
				letGoOffRuntime = true;
			}
		}
		super.__detachAcceptTick();
	}
}

/** The same, for a WebSocket server, which lets go through the same path natively. **/
@:access(crossbyte.core.CrossByte)
private class ThreadNotingServerWebSocket extends ServerWebSocket {
	public var letGo:Bool;
	public var letGoOffRuntime:Bool;

	private var __owner:CrossByte;

	public function new(owner:CrossByte) {
		letGo = false;
		letGoOffRuntime = false;
		__owner = owner;
		super();
	}

	override private function __detachAcceptTick():Void {
		if (__acceptRuntime != null) {
			letGo = true;
			if (CrossByte.__currentOrNull() != __owner) {
				letGoOffRuntime = true;
			}
		}
		super.__detachAcceptTick();
	}
}

/** Notes whether a reliable server took a tick off its runtime from another thread. **/
@:access(crossbyte.core.CrossByte)
private class ThreadNotingReliableServer extends ReliableDatagramServerSocket {
	public var untickedOffRuntime:Bool;

	private var __owner:CrossByte;

	public function new(owner:CrossByte) {
		untickedOffRuntime = false;
		__owner = owner;
		super();
	}

	override private function __untick(listener:crossbyte.events.TickEvent->Void):Void {
		if (CrossByte.__currentOrNull() != __owner) {
			untickedOffRuntime = true;
		}
		super.__untick(listener);
	}
}

/** Notes whether a datagram socket's poll set entry changed off its runtime's thread. **/
@:access(crossbyte.core.CrossByte)
private class ThreadNotingDatagramSocket extends DatagramSocket {
	public var pollChangedOffRuntime:Bool;

	private var __owner:CrossByte;

	public function new(owner:CrossByte) {
		pollChangedOffRuntime = false;
		__owner = owner;
		super();
	}

	override private function __syncPolling():Void {
		var was:Bool = __registered;
		super.__syncPolling();
		if (__registered != was && CrossByte.__currentOrNull() != __owner) {
			pollChangedOffRuntime = true;
		}
	}
}
#end
