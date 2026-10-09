package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.UncaughtErrorEvent;
import utest.Assert;
#if target.threaded
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Thread;
#end

using StringTools;

/**
	One listener's connections served on several runtimes: `runtimes`,
	`runtimeCount` and `selectRuntime` on a `ServerSocket`.

	The listener runs on a runtime of its own and each connection is handed
	to one of the others before anything is done with it. These hold the
	parts of that a connection can tell: which runtime it lands on, that
	every event it has runs on that runtime's thread for its whole life,
	that a TLS handshake runs there too, and that what the server counts and
	limits holds for all of them together.

	Every runtime here is a child with a POLL loop, and the clients are
	plain blocking sockets on the test's own thread, so nothing runs on two
	threads at once that the code under test did not put there.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.net.ServerSocket)
@:access(crossbyte.net.Socket)
class ServerSpreadTest extends utest.Test {
	#if nodejs
	/**
		Node runs every runtime on its one thread, so there is nothing to
		spread a server over: each way of asking is refused, saying so, and
		asking for none is not.
	**/
	public function testNodeRefusesToSpreadAServer():Void {
		var server = new ServerSocket();
		var refused:Int = 0;
		try {
			server.runtimes = [CrossByte.current()];
		} catch (_:crossbyte.errors.IllegalOperationError) {
			refused++;
		}
		try {
			server.runtimeCount = 2;
		} catch (_:crossbyte.errors.IllegalOperationError) {
			refused++;
		}
		try {
			server.reusePort = true;
		} catch (_:crossbyte.errors.IllegalOperationError) {
			refused++;
		}
		server.runtimeCount = 0;
		server.runtimes = null;
		Assert.equals(3, refused, "Node took a server spread over runtimes");
		Assert.isNull(server.runtimes);
		Assert.equals(0, server.runtimeCount);

		// An HTTPServer told to spread refuses as it is made, before it listens.
		var config = new crossbyte.http.HTTPServerConfig("127.0.0.1", 0);
		config.runtimeCount = 2;
		var threw:Bool = false;
		try {
			var made = new crossbyte.http.HTTPServer(config);
			made.close();
		} catch (_:crossbyte.errors.IllegalOperationError) {
			threw = true;
		}
		Assert.isTrue(threw, "Node made an HTTPServer spread over runtimes");
	}
	#end

	#if target.threaded
	private static inline var WAIT:Float = 10.0;

	@:timeout(30000)
	public function testConnectionsGoToTheRuntimesInTurn():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var arrived:Deque<Arrival> = new Deque();

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.runtimes = [first, second];
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> arrived.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var clients:Array<sys.net.Socket> = [];
		var landed:Array<Arrival> = [];
		for (_ in 0...4) {
			// One at a time, so the order they are accepted in is known.
			clients.push(SpreadSupport.connect(server.localPort));
			var arrival:Null<Arrival> = SpreadSupport.pop(arrived, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}

		Assert.equals(4, landed.length, "connections were not announced");
		var expected:Array<CrossByte> = [first, second, first, second];
		for (i in 0...landed.length) {
			Assert.isTrue(landed[i].runtime == expected[i], 'connection $i landed on the wrong runtime');
			Assert.isTrue(landed[i].thread == expected[i].__ownerThread, 'connection $i was announced off its runtime\'s thread');
			Assert.isTrue(landed[i].socket.__cbInstance == expected[i], 'connection $i is polled by a runtime other than the one it was announced on');
		}
		var listed:Array<CrossByte> = server.runtimes;
		Assert.isTrue(listed.length == 2 && listed[0] == first && listed[1] == second, "runtimes does not list the runtimes given");
		Assert.equals(2, server.runtimeCount);

		SpreadSupport.closeAll(clients);
		SpreadSupport.closeArrivals(landed);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/**
		Data, a close from the runtime, a close from another thread: every
		event a connection has is dispatched on the runtime it landed on.
	**/
	@:timeout(30000)
	public function testAConnectionLivesOnItsRuntime():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var worker:CrossByte = SpreadSupport.runtime();
		var arrived:Deque<Arrival> = new Deque();
		var seen:Deque<String> = new Deque();

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.runtimes = [worker];
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
				var socket:Socket = e.socket;
				socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
					var text:String = socket.readUTFBytes(socket.bytesAvailable);
					seen.add("data:" + SpreadSupport.where(worker));
					if (text == "bye") {
						socket.close();
						return;
					}
					socket.writeUTFBytes(text.toUpperCase());
					socket.flush();
				});
				socket.addEventListener(Event.CLOSE, _ -> seen.add("close:" + SpreadSupport.where(worker)));
				arrived.add(Arrival.of(socket));
			});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		// Echoed, then closed by the server from its runtime.
		var talker:sys.net.Socket = SpreadSupport.connect(server.localPort);
		var talking:Null<Arrival> = SpreadSupport.pop(arrived, WAIT);
		talker.output.writeString("ping");
		Assert.equals("PING", SpreadSupport.read(talker, 4));
		Assert.equals("data:own", SpreadSupport.pop(seen, WAIT));
		talker.output.writeString("bye");
		Assert.equals("data:own", SpreadSupport.pop(seen, WAIT));
		Assert.equals("close:own", SpreadSupport.pop(seen, WAIT), "a close made on the runtime was dispatched elsewhere");
		Assert.isTrue(SpreadSupport.ended(talker), "the server's close never reached the client");

		// Closed from this thread, which is not the runtime's: handed over.
		var quiet:sys.net.Socket = SpreadSupport.connect(server.localPort);
		var held:Null<Arrival> = SpreadSupport.pop(arrived, WAIT);
		Assert.notNull(held, "the second connection was not announced");
		if (held != null) {
			held.socket.close();
			Assert.equals("close:own", SpreadSupport.pop(seen, WAIT), "a close from another thread was dispatched off the connection's runtime");
			Assert.isTrue(SpreadSupport.ended(quiet), "a close from another thread never reached the client");
		}

		SpreadSupport.closeAll([talker, quiet]);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, worker]);
	}

	/**
		`selectRuntime` is asked on the listener's runtime, and its answer is
		where the connection goes; an answer that is not one of `runtimes`
		goes to the next in turn, and a hook that throws refuses.
	**/
	@:timeout(30000)
	public function testSelectRuntimeRoutesConnections():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var stranger:CrossByte = SpreadSupport.runtime();
		var arrived:Deque<Arrival> = new Deque();
		var asked:Deque<String> = new Deque();
		var answer:Int = 0;

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.runtimes = [first, second];
			server.selectRuntime = function(address:String, port:Int):CrossByte {
				asked.add(address + ":" + SpreadSupport.where(acceptor));
				return switch (answer) {
					case 0: second;
					case 1: stranger;
					default: throw "no runtime for this one";
				}
			};
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> arrived.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var clients:Array<sys.net.Socket> = [];
		var landed:Array<Arrival> = [];
		for (_ in 0...3) {
			clients.push(SpreadSupport.connect(server.localPort));
			var arrival = SpreadSupport.pop(arrived, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}
		Assert.equals(3, landed.length);
		for (arrival in landed) {
			Assert.isTrue(arrival.runtime == second, "a connection the hook sent to the second runtime landed elsewhere");
		}
		Assert.equals("127.0.0.1:own", SpreadSupport.pop(asked, WAIT), "the hook was not asked on the listener's runtime, with the peer's address");

		// Not one of runtimes: the next in turn, which is the first.
		answer = 1;
		clients.push(SpreadSupport.connect(server.localPort));
		var elsewhere:Null<Arrival> = SpreadSupport.pop(arrived, WAIT);
		Assert.notNull(elsewhere);
		if (elsewhere != null) {
			landed.push(elsewhere);
			Assert.isTrue(elsewhere.runtime == first, "an answer outside runtimes was not replaced by the next in turn");
		}

		// A hook that throws refuses the connection.
		answer = 2;
		var refused:sys.net.Socket = SpreadSupport.connect(server.localPort);
		clients.push(refused);
		Assert.isTrue(SpreadSupport.ended(refused), "a connection the hook threw for was not closed");
		Assert.isNull(SpreadSupport.pop(arrived, 0.3), "a connection the hook threw for was announced");

		SpreadSupport.closeAll(clients);
		SpreadSupport.closeArrivals(landed);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second, stranger]);
	}

	/**
		A runtime that has exited is passed over; with none left, each
		connection is closed as it is accepted.
	**/
	@:timeout(30000)
	public function testAnExitedRuntimeIsPassedOver():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var arrived:Deque<Arrival> = new Deque();

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.runtimes = [first, second];
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> arrived.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		SpreadSupport.stop([first]);

		var clients:Array<sys.net.Socket> = [];
		var landed:Array<Arrival> = [];
		for (_ in 0...3) {
			clients.push(SpreadSupport.connect(server.localPort));
			var arrival = SpreadSupport.pop(arrived, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}
		Assert.equals(3, landed.length, "connections were lost to a runtime that had exited");
		for (arrival in landed) {
			Assert.isTrue(arrival.runtime == second, "a connection went to a runtime that had exited");
		}

		SpreadSupport.closeArrivals(landed);
		SpreadSupport.stop([second]);

		var refused:sys.net.Socket = SpreadSupport.connect(server.localPort);
		clients.push(refused);
		Assert.isTrue(SpreadSupport.ended(refused), "with every runtime gone a connection was left open");

		SpreadSupport.closeAll(clients);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor]);
	}

	/**
		A connection handed to a runtime that exits before taking it up is
		closed, not left open and unread. What was posted to a runtime before
		it exits still runs as it exits, after its poll set is past use.
	**/
	@:timeout(30000)
	public function testAConnectionReachingAnExitingRuntimeIsClosed():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var worker:CrossByte = SpreadSupport.runtime();
		var arrived:Deque<Arrival> = new Deque();

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.runtimes = [worker];
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> arrived.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		// The worker held busy until the hand-off is seen waiting in its
		// queue, however long the connect takes, and told to exit before it
		// is let go.
		var hold:Lock = new Lock();
		worker.post(() -> hold.wait(WAIT));
		var client:sys.net.Socket = SpreadSupport.connect(server.localPort);
		client.setTimeout(3.0);
		Assert.isTrue(SpreadSupport.waitFor(() -> worker.postQueueDepth > 0, WAIT), "the connection was never handed to the runtime");
		worker.exit();
		hold.release();

		Assert.isTrue(SpreadSupport.ended(client), "a connection handed to a runtime as it exited was left open");
		Assert.isNull(SpreadSupport.pop(arrived, 0.2), "a connection was announced on a runtime that had exited");

		SpreadSupport.closeAll([client]);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, worker]);
	}

	/**
		`admit` is asked once, on the listener's runtime, before the hand-off;
		a refusal costs no runtime anything.
	**/
	@:timeout(30000)
	public function testAdmitIsAskedOnTheListenersRuntime():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var worker:CrossByte = SpreadSupport.runtime();
		var arrived:Deque<Arrival> = new Deque();
		var asked:Deque<String> = new Deque();
		var count:Int = 0;

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.runtimes = [worker];
			server.admit = function(address:String, port:Int):Bool {
				asked.add(SpreadSupport.where(acceptor));
				return ++count != 2;
			};
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> arrived.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var clients:Array<sys.net.Socket> = [];
		var landed:Array<Arrival> = [];
		clients.push(SpreadSupport.connect(server.localPort));
		var arrival:Null<Arrival> = SpreadSupport.pop(arrived, WAIT);
		if (arrival != null) {
			landed.push(arrival);
		}
		var refused:sys.net.Socket = SpreadSupport.connect(server.localPort);
		clients.push(refused);
		Assert.isTrue(SpreadSupport.ended(refused), "a connection admit refused was left open");
		clients.push(SpreadSupport.connect(server.localPort));
		arrival = SpreadSupport.pop(arrived, WAIT);
		if (arrival != null) {
			landed.push(arrival);
		}

		Assert.equals(2, landed.length, "the admitted connections were not both announced");
		for (_ in 0...3) {
			Assert.equals("own", SpreadSupport.pop(asked, WAIT), "admit was not asked on the listener's runtime");
		}

		SpreadSupport.closeAll(clients);
		SpreadSupport.closeArrivals(landed);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, worker]);
	}

	/**
		A `connect` listener that throws on a connection's runtime is
		reported there, as a socket handler's failure is, and the connection
		closed.
	**/
	@:timeout(30000)
	public function testAThrowingConnectListenerIsContainedOnItsRuntime():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var worker:CrossByte = SpreadSupport.runtime();
		var reported:Deque<String> = new Deque();
		SpreadSupport.on(worker, () -> {
			worker.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, e -> reported.add(e.source + ":" + SpreadSupport.where(worker)));
			return null;
		});
		crossbyte.utils.Logger.setLevel("runtime", crossbyte.utils.LogLevel.OFF);

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.runtimes = [worker];
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) throw "listener failure");
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var client:sys.net.Socket = SpreadSupport.connect(server.localPort);
		Assert.equals(UncaughtErrorEvent.SOCKET + ":own", SpreadSupport.pop(reported, WAIT), "the failure was not reported on the connection's runtime");
		Assert.isTrue(SpreadSupport.ended(client), "the connection whose listener threw was left open");
		crossbyte.utils.Logger.setLevel("runtime", null);

		SpreadSupport.closeAll([client]);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, worker]);
	}

	/**
		`runtimeCount` makes the runtimes, POLL loops each, and `runtimes`
		then lists them; `stopAccepting()` leaves the connections they hold
		serving.
	**/
	@:timeout(30000)
	public function testRuntimeCountMakesTheRuntimes():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var arrived:Deque<Arrival> = new Deque();

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.runtimeCount = 3;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
				var socket = e.socket;
				socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
					socket.writeUTFBytes(socket.readUTFBytes(socket.bytesAvailable));
					socket.flush();
				});
				arrived.add(Arrival.of(socket));
			});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var made:Array<CrossByte> = server.runtimes;
		Assert.equals(3, made.length, "runtimeCount made the wrong number of runtimes");
		Assert.equals(3, server.runtimeCount);
		for (runtime in made) {
			Assert.isTrue(runtime.__loopType.match(POLL), "a runtime made for the server does not poll");
			Assert.isFalse(runtime == acceptor);
		}

		var clients:Array<sys.net.Socket> = [];
		var landed:Array<Arrival> = [];
		for (_ in 0...3) {
			clients.push(SpreadSupport.connect(server.localPort));
			var arrival = SpreadSupport.pop(arrived, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}
		Assert.equals(3, landed.length);
		for (i in 0...landed.length) {
			Assert.isTrue(landed[i].runtime == made[i], 'connection $i did not land on the runtime made for it');
			Assert.isTrue(landed[i].thread == made[i].__ownerThread, 'connection $i was announced off its runtime\'s thread');
		}

		// The listener goes; what was accepted keeps serving.
		SpreadSupport.on(acceptor, () -> server.stopAccepting());
		Assert.isFalse(server.listening);
		for (client in clients) {
			client.output.writeString("still");
			Assert.equals("still", SpreadSupport.read(client, 5), "a connection stopped serving when its server stopped accepting");
		}

		SpreadSupport.closeAll(clients);
		SpreadSupport.closeArrivals(landed);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop(made.concat([acceptor]));
	}

	/** Spreading is settled before listening, and refuses what it cannot spread over. **/
	public function testRuntimesAreCheckedWhenSet():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var worker:CrossByte = SpreadSupport.runtime();
		var failures:Array<String> = SpreadSupport.on(acceptor, () -> {
			var failures:Array<String> = [];
			var server = new ServerSocket();
			try {
				server.runtimes = [worker, null];
				failures.push("a null runtime was taken");
			} catch (_:crossbyte.errors.ArgumentError) {}
			try {
				server.runtimes = [worker, worker];
				failures.push("a runtime listed twice was taken");
			} catch (_:crossbyte.errors.ArgumentError) {}
			try {
				server.runtimeCount = -1;
				failures.push("a negative count was taken");
			} catch (_:crossbyte.errors.ArgumentError) {}

			server.runtimes = [worker];
			server.runtimeCount = 2;
			if (server.runtimes != null) {
				failures.push("runtimeCount did not clear runtimes");
			}
			server.runtimes = [worker];
			if (server.runtimeCount != 1) {
				failures.push("runtimes did not replace runtimeCount");
			}

			server.bind(0, "127.0.0.1");
			server.listen();
			try {
				server.runtimes = null;
				failures.push("runtimes changed after listen()");
			} catch (_:crossbyte.errors.IllegalOperationError) {}
			server.close();
			return failures;
		});
		Assert.same([], failures);
		SpreadSupport.stop([acceptor, worker]);
	}

	/**
		`reusePort` is `SO_REUSEPORT` on Linux, natively and on the jvm from
		Java 9: everywhere else setting it throws, saying so, and a server
		without runtimes refuses to listen with it.
	**/
	public function testReusePortIsRefusedWhereItCannotSpread():Void {
		var server = new ServerSocket();
		var refused:Bool = false;
		try {
			server.reusePort = true;
		} catch (_:crossbyte.errors.IllegalOperationError) {
			refused = true;
		}
		Assert.equals(!SpreadSupport.reusePortExpected(), refused, "reusePort was " + (refused ? "refused" : "taken") + " on " + Sys.systemName());

		if (!refused) {
			var acceptor:CrossByte = SpreadSupport.runtime();
			var failure:String = SpreadSupport.on(acceptor, () -> {
				var lonely = new ServerSocket();
				lonely.reusePort = true;
				lonely.bind(0, "127.0.0.1");
				var failure:String = null;
				try {
					lonely.listen();
					failure = "a server with no runtimes listened with reusePort";
				} catch (_:crossbyte.errors.IOError) {}
				lonely.close();
				return failure;
			});
			Assert.isNull(failure);
			SpreadSupport.stop([acceptor]);
		}
	}

	/**
		On Linux: a listener per runtime on one port, and the kernel sharing
		connections out over them. Each runtime accepts for itself (`admit`
		is asked on each, on its own thread), and the runtime that called
		`listen()` accepts none.
	**/
	@:timeout(60000)
	public function testReusePortSpreadsConnectionsOverListeners():Void {
		if (!SpreadSupport.reusePortExpected()) {
			Assert.pass();
			return;
		}

		var acceptor:CrossByte = SpreadSupport.runtime();
		var runtimes:Array<CrossByte> = [for (_ in 0...4) SpreadSupport.runtime()];
		var arrived:Deque<Arrival> = new Deque();
		var admitted:Deque<Arrival> = new Deque();

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.reusePort = true;
			server.runtimes = runtimes;
			server.admit = function(address:String, port:Int):Bool {
				admitted.add(new Arrival(CrossByte.__currentOrNull(), Thread.current(), null));
				return true;
			};
			server.selectRuntime = (_, _) -> throw "not asked with reusePort";
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> arrived.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var listeners:Int = 0;
		for (replica in server.__spread.replicas) {
			if (replica.__serverSocket != null) {
				listeners++;
			}
		}
		Assert.equals(4, listeners, "not every runtime was given a listener of its own");

		var clients:Array<sys.net.Socket> = [];
		var landed:Array<Arrival> = [];
		for (_ in 0...40) {
			clients.push(SpreadSupport.connect(server.localPort));
		}
		for (_ in 0...40) {
			var arrival = SpreadSupport.pop(arrived, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}

		Assert.equals(40, landed.length, "connections were lost between the listeners");
		var counts:Array<Int> = [for (_ in runtimes) 0];
		for (arrival in landed) {
			var index:Int = runtimes.indexOf(arrival.runtime);
			Assert.isTrue(index >= 0, "a connection landed on a runtime that is not one of runtimes");
			if (index >= 0) {
				counts[index]++;
				Assert.isTrue(arrival.thread == runtimes[index].__ownerThread, "a connection was announced off its runtime's thread");
			}
		}
		for (i in 0...counts.length) {
			Assert.isTrue(counts[i] > 0, 'the kernel sent runtime $i none of 40 connections: $counts');
		}
		for (_ in 0...40) {
			var asked:Null<Arrival> = SpreadSupport.pop(admitted, WAIT);
			Assert.isTrue(asked != null && runtimes.indexOf(asked.runtime) >= 0 && asked.thread == asked.runtime.__ownerThread,
				"admit was not asked on the runtime that accepted");
		}

		SpreadSupport.closeAll(clients);
		SpreadSupport.closeArrivals(landed);
		SpreadSupport.on(acceptor, () -> server.close());
		// Each runtime's listener is closed with the server.
		Assert.isTrue(SpreadSupport.waitFor(() -> {
			var open:Int = 0;
			for (replica in server.__spread.replicas) {
				if (replica.__serverSocket != null) {
					open++;
				}
			}
			return open == 0;
		}, WAIT), "a runtime's listener outlived the server's close()");
		SpreadSupport.stop(runtimes.concat([acceptor]));
	}

	/**
		A runtime that has stalled (a handler blocking it) is handed at most
		`ServerSpread.MAX_WAITING` connections it has not taken up; the next go
		to the runtime after it, and once every runtime is that far behind a
		connection is closed as it is accepted, and counted. Once the runtimes
		catch up, what they were handed is taken up. Without the bound a
		stalled runtime would be handed every connection that came its way in
		turn, each a socket held in its post queue, for as long as the stall
		lasted.
	**/
	@:timeout(30000)
	public function testAStalledRuntimeIsHandedABoundedNumberOfConnections():Void {
		var limit:Int = crossbyte.net._internal.ServerSpread.MAX_WAITING;
		crossbyte.net._internal.ServerSpread.MAX_WAITING = 2;
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var arrived:Deque<Arrival> = new Deque();

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.runtimes = [first, second];
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> arrived.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		// Only the first stalls: what it cannot take goes to the second.
		var firstStall:Lock = new Lock();
		first.post(() -> firstStall.wait(10.0));
		var clients:Array<sys.net.Socket> = [];
		var landed:Array<Arrival> = [];
		for (_ in 0...4) {
			clients.push(SpreadSupport.connect(server.localPort));
		}
		// Two wait on the first; two, and the one passed over, are served.
		for (_ in 0...2) {
			var arrival:Null<Arrival> = SpreadSupport.pop(arrived, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}
		Assert.equals(2, landed.length, "the runtime that was not stalled was not handed what the stalled one could not take");
		for (arrival in landed) {
			Assert.isTrue(arrival.runtime == second, "a connection was announced on the stalled runtime");
		}
		Assert.isTrue(SpreadSupport.waitFor(() -> server.__spread.waitingAt(0) == 2, WAIT), "the stalled runtime was not handed its share");
		Assert.equals(0, server.refusedConnections, "a connection was refused with a runtime free");

		// Now both stall: two more wait on the second, and the next two are
		// refused.
		var secondStall:Lock = new Lock();
		second.post(() -> secondStall.wait(10.0));
		Assert.isTrue(SpreadSupport.waitFor(() -> second.postQueueDepth == 0, WAIT));
		crossbyte.sys.System.sleep(0.05);
		var refused:Array<sys.net.Socket> = [];
		for (i in 0...4) {
			var client = SpreadSupport.connect(server.localPort);
			if (i < 2) {
				clients.push(client);
			} else {
				refused.push(client);
			}
			SpreadSupport.waitFor(() -> server.__spread.waitingAt(1) + server.refusedConnections > i, WAIT);
		}
		Assert.equals(2, server.__spread.waitingAt(0), "the first stalled runtime was handed past its bound");
		Assert.equals(2, server.__spread.waitingAt(1), "the second stalled runtime was handed past its bound");
		Assert.isTrue(SpreadSupport.waitFor(() -> server.refusedConnections == 2, WAIT), 'with every runtime behind, ${server.refusedConnections} were refused, not 2');
		for (client in refused) {
			Assert.isTrue(SpreadSupport.ended(client), "a connection refused with every runtime behind was left open");
		}

		// Caught up: everything handed over is taken up.
		firstStall.release();
		secondStall.release();
		for (_ in 0...4) {
			var arrival:Null<Arrival> = SpreadSupport.pop(arrived, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}
		Assert.equals(6, landed.length, "what the stalled runtimes were handed was not taken up once they caught up");
		Assert.isTrue(SpreadSupport.waitFor(() -> server.__spread.waitingAt(0) == 0 && server.__spread.waitingAt(1) == 0, WAIT));

		crossbyte.net._internal.ServerSpread.MAX_WAITING = limit;
		SpreadSupport.closeAll(clients.concat(refused));
		SpreadSupport.closeArrivals(landed);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/**
		`maxConnections` holds across the runtimes, and a runtime that exits
		gives back the places its connections held: they will never be
		served again.
	**/
	@:timeout(30000)
	public function testTheConnectionLimitHoldsAcrossRuntimesAndAnExitGivesPlacesBack():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var arrived:Deque<Arrival> = new Deque();

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket();
			server.runtimes = [first, second];
			server.maxConnections = 3;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> arrived.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var clients:Array<sys.net.Socket> = [];
		var landed:Array<Arrival> = [];
		for (_ in 0...3) {
			clients.push(SpreadSupport.connect(server.localPort));
			var arrival:Null<Arrival> = SpreadSupport.pop(arrived, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}
		Assert.equals(3, landed.length);
		var past:sys.net.Socket = SpreadSupport.connect(server.localPort);
		Assert.isTrue(SpreadSupport.ended(past), "a connection past the limit across the runtimes was left open");
		Assert.isTrue(SpreadSupport.waitFor(() -> server.refusedConnections == 1, WAIT), "the refusal was not counted");

		// The first runtime held two of them; it exits.
		var onFirst:Int = 0;
		for (arrival in landed) {
			if (arrival.runtime == first) {
				onFirst++;
			}
		}
		SpreadSupport.stop([first]);
		Assert.isTrue(SpreadSupport.waitFor(() -> server.__spread.connections == 3 - onFirst, WAIT),
			'a runtime that exited kept its places: ${server.__spread.connections} counted');
		clients.push(SpreadSupport.connect(server.localPort));
		Assert.notNull(SpreadSupport.pop(arrived, WAIT), "a place given back by a runtime that exited was not taken");

		SpreadSupport.closeAll(clients.concat([past]));
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, second]);
	}

	/**
		A runtime that exits with sessions still upgrading there drops them:
		their connections are closed, and the server's count of upgrades under
		way lets go of them, rather than keeping them counted for as long as
		the server ran, holding places `maxPendingHandshakes` gave out.
	**/
	@:timeout(30000)
	public function testARuntimeThatExitsGivesUpWhatIsStillUpgrading():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();

		var server:ServerWebSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerWebSocket();
			server.runtimes = [first, second];
			server.handshakeTimeout = 30;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) {});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		// Four that never send their upgrade: two on each runtime.
		var silent:Array<sys.net.Socket> = [];
		for (_ in 0...4) {
			silent.push(SpreadSupport.connect(server.localPort));
			var expected:Int = silent.length;
			SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == expected, WAIT);
		}
		Assert.equals(4, server.pendingHandshakeCount(), "the upgrades were not under way");

		SpreadSupport.stop([first]);
		Assert.isTrue(SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == 2, WAIT),
			'upgrades on a runtime that exited stayed counted: ${server.pendingHandshakeCount()}');
		// In turn: the first and third went to the runtime that exited.
		Assert.isTrue(SpreadSupport.ended(silent[0]), "an upgrade on a runtime that exited was left open");
		Assert.isTrue(SpreadSupport.ended(silent[2]), "an upgrade on a runtime that exited was left open");

		SpreadSupport.closeAll(silent);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, second]);
	}

	#if (cpp || java || jvm)
	/**
		A TLS connection is handed over before its handshake, which runs on
		the runtime it lands on; what it sends afterwards is read there too.
	**/
	@:timeout(30000)
	public function testTlsHandshakesRunOnTheRuntimes():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var arrived:Deque<Arrival> = new Deque();

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket(true);
			server.setCertificate(fixture.certificate, fixture.key);
			server.runtimes = [first, second];
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
				var socket = e.socket;
				socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
					socket.writeUTFBytes(socket.readUTFBytes(socket.bytesAvailable).toUpperCase());
					socket.flush();
				});
				arrived.add(Arrival.of(socket));
			});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var replies:Array<Null<String>> = [];
		for (i in 0...4) {
			replies.push(SpreadSupport.tlsExchange(server.localPort, fixture.certificate, "hello" + i));
		}
		var landed:Array<Arrival> = [];
		for (_ in 0...4) {
			var arrival = SpreadSupport.pop(arrived, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}

		Assert.same(["HELLO0", "HELLO1", "HELLO2", "HELLO3"], replies, "a TLS connection did not carry its data");
		Assert.equals(4, landed.length);
		var expected:Array<CrossByte> = [first, second, first, second];
		for (i in 0...landed.length) {
			Assert.isTrue(landed[i].runtime == expected[i], 'TLS connection $i landed on the wrong runtime');
			Assert.isTrue(landed[i].thread == expected[i].__ownerThread, 'TLS connection $i was announced off its runtime\'s thread');
			Assert.isTrue(landed[i].socket.secure, 'TLS connection $i says it is not secure');
		}
		Assert.equals(0, server.pendingHandshakeCount());
		Assert.equals(0, server.handshakeFailures);

		SpreadSupport.closeArrivals(landed);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/**
		`maxPendingHandshakes` counts the handshakes under way on every
		runtime together: past it the listener waits, and as handshakes fail
		at `handshakeTimeout` (counted in `handshakeFailures`, summed over the
		runtimes) the rest are taken. `stopAccepting()` drops what is still
		handshaking wherever it is.
	**/
	@:timeout(30000)
	public function testHandshakeLimitHoldsAcrossRuntimes():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();

		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket(true);
			server.setCertificate(fixture.certificate, fixture.key);
			server.runtimes = [first, second];
			server.maxPendingHandshakes = 2;
			server.handshakeTimeout = 1.0;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) {});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		// Four that never say a word: two are taken, two wait in the queue.
		var silent:Array<sys.net.Socket> = [for (_ in 0...4) SpreadSupport.connect(server.localPort)];
		Assert.isTrue(SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == 2, WAIT), "the handshakes in flight did not reach the limit");
		crossbyte.sys.System.sleep(0.3);
		Assert.equals(2, server.pendingHandshakeCount(), "more handshakes were taken than the limit allows across the runtimes");
		var onRuntimes:Int = 0;
		for (replica in server.__spread.replicas) {
			onRuntimes += replica.__localPendingCount();
		}
		Assert.equals(2, onRuntimes, "the handshakes counted were not under way on the runtimes");

		// The first two time out; the other two are then taken, and time out.
		Assert.isTrue(SpreadSupport.waitFor(() -> server.handshakeFailures == 4, WAIT), 'handshakes that ran out of time were counted ${server.handshakeFailures} times, not 4');
		Assert.isTrue(SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == 0, WAIT));

		// Two more, then a stop: dropped where they are, not counted as failures.
		var dropped:Array<sys.net.Socket> = [for (_ in 0...2) SpreadSupport.connect(server.localPort)];
		Assert.isTrue(SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == 2, WAIT));
		SpreadSupport.on(acceptor, () -> server.stopAccepting());
		for (client in dropped) {
			Assert.isTrue(SpreadSupport.ended(client), "stopAccepting() left a handshake on a runtime running");
		}
		Assert.isTrue(SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == 0, WAIT));
		Assert.equals(4, server.handshakeFailures, "handshakes dropped by stopAccepting() were counted as failures");

		SpreadSupport.closeAll(silent.concat(dropped));
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}
	/**
		A runtime that exits with TLS handshakes under way there drops them,
		closing their connections, and the count of handshakes in flight
		lets go of them, and of their addresses.
	**/
	@:timeout(30000)
	public function testARuntimeThatExitsGivesUpItsHandshakes():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass();
			return;
		}
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerSocket(true);
			server.setCertificate(fixture.certificate, fixture.key);
			server.runtimes = [first, second];
			server.handshakeTimeout = 30;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) {});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});
		var silent:Array<sys.net.Socket> = [];
		for (_ in 0...4) {
			silent.push(SpreadSupport.connect(server.localPort));
			var expected:Int = silent.length;
			SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == expected, WAIT);
		}
		Assert.equals(4, server.pendingHandshakeCount());
		SpreadSupport.stop([first]);
		Assert.isTrue(SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == 2, WAIT),
			'handshakes on a runtime that exited stayed counted: ${server.pendingHandshakeCount()}');
		Assert.isTrue(SpreadSupport.ended(silent[0]), "a handshake on a runtime that exited was left open");
		Assert.isTrue(SpreadSupport.ended(silent[2]), "a handshake on a runtime that exited was left open");
		Assert.equals(2, server.__addressCounts.count("127.0.0.1"), "the address kept the handshakes of a runtime that exited");
		SpreadSupport.closeAll(silent);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, second]);
	}

	#end
	#end
}
