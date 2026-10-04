package crossbyte;

#if (cpp || jvm)
import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import crossbyte.net.ServerSocket;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.Socket;
import crossbyte.net.TLSTestFixture;
import crossbyte.net.WebSocket;
import crossbyte.rpc.LinkedConnection;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCResponse;
import crossbyte.rpc.RPCSession;
import crossbyte.test.AllocationMeter;
import haxe.io.Bytes;
import utest.Assert;
#end

/**
	How many bytes each common operation allocates, held to a budget.

	Each case runs one operation for real, a request to an `HTTPServer` over
	loopback, a message echoed by a `ServerWebSocket`, a call over an RPC
	pair, warms it up, and then measures what it allocates with
	`AllocationMeter`: the median of three runs, in bytes per operation. Both
	ends of a connection run on this thread and both are counted: what a
	client allocates is CrossByte's sockets' doing, the test code around them
	allocating nothing per operation. A case fails when the
	figure passes the operation's budget, which is what was measured when the
	budget was set plus about a quarter: a change adding garbage to a path
	everything takes is seen in the change that adds it, as
	`HTTPServerH2Test` sees one adding a system call.

	Natively and on the jvm only: no other target has a counter to read.

	**A failure** names the operation, what it allocated in each run, its
	budget, and what it measured when the budget was set. Natively the runs
	read the same to the byte, and on the jvm within a few percent, so a
	failure that repeats when the class is run alone (`-D gc_bisect`,
	`CB_ONLY=AllocationBudget`) is a path allocating more.

	**To rebaseline**, after allocating more on purpose or less: run the class
	alone with `CB_ALLOC_REPORT=1`, which prints every figure, natively on
	Windows and Linux and on the jvm; set each `measured` to what it printed
	and each budget to about 1.25 times that, rounded up, and the date.
**/
@:access(crossbyte.core.CrossByte)
class AllocationBudgetTest extends utest.Test {
	#if (cpp || jvm)
	/** The day the figures below were measured. **/
	private static inline var MEASURED_ON:String = "2026-10-03";

	// What each operation allocates, in bytes: as measured on MEASURED_ON
	// natively on Windows, natively on Linux and on the jvm, and then the
	// budget each is held to there, the figure and a quarter, and 64 bytes,
	// rounded up to 8. A figure of 0 is held to 8, which one object an
	// operation would pass. The jvm's figure is the largest of Oracle's JRE 8
	// on Windows, Temurin 8 on Linux and a run of the full suite.
	//
	//                                                                           measured                budget
	private static final EVENT = new Budget("an event dispatched to a listener", "dispatch", [0, 0, 0], [8, 8, 8]);
	private static final TIMER = new Budget("a timeout armed and cleared", "timer", [80, 80, 72], [168, 168, 160]);
	private static final INTERVAL = new Budget("an interval timer firing and re-arming", "firing", [0, 0, 112], [8, 8, 208]);
	private static final POST = new Budget("a callback posted to the runtime and run", "post", [104, 104, 184], [200, 200, 296]);
	private static final IDLE_TICK = new Budget("a runtime frame with nothing to do", "frame", [0, 0, 112], [8, 8, 208]);
	private static final HTTP_GET = new Budget("an HTTP/1.1 GET on a kept-alive connection", "request", [1848, 1848, 5048], [2376, 2376, 6376]);
	private static final HTTP_POST = new Budget("an HTTP/1.1 POST of 4 KB on a kept-alive connection", "request", [8612, 8612, 12212], [10832, 10832, 15336]);
	private static final H2_GET = new Budget("an HTTP/2 GET over cleartext", "request", [3728, 3712, 3312], [4728, 4704, 4208]);
	private static final TLS_GET = new Budget("an HTTP/1.1 GET over TLS on a kept-alive connection", "request", [1848, 1848, 11920], [2376, 2376, 14968]);
	private static final WEBSOCKET = new Budget("a 100-byte WebSocket text message echoed", "message", [1704, 1704, 2960], [2200, 2200, 3768]);
	private static final RELIABLE = new Budget("a 200-byte reliable UDP message delivered and acknowledged", "message", [1216, 1216, 2832], [1584, 1584, 3608]);
	private static final TCP = new Budget("a 100-byte message echoed over TCP", "message", [208, 208, 1216], [328, 328, 1584]);
	private static final DATAGRAM = new Budget("a 100-byte datagram sent and received", "datagram", [344, 344, 1224], [496, 496, 1600]);
	// LinkedConnection, the in-memory pair these run over, copies each
	// message it carries into a ByteArray of its own, where a socket's read
	// would not: about a third of a call's figure natively, and half of a
	// one-way call's.
	private static final RPC_CALL = new Budget("an RPC call and its answer", "call", [920, 920, 592], [1216, 1216, 808]);
	private static final RPC_ONE_WAY = new Budget("a one-way RPC call", "call", [392, 392, 264], [560, 560, 400]);

	/** Operations run before measuring, so what the first ones build is not counted. **/
	private static inline var WARM:Int = #if jvm 6000 #else 300 #end;

	/** Operations run before measuring a path the jvm compiles late. **/
	private static inline var WARM_CHEAP:Int = #if jvm 30000 #else 2000 #end;

	// Kept here, not on the stack, so the jvm cannot prove an allocation
	// unused and leave it out.
	private static var __sink:Dynamic = null;

	private static var __runtime:CrossByte;
	private static var __lastPump:Float = 0.0;
	private static var __deadline:Float = 0.0;

	/**
		The meter itself, read against allocations of known size: a run that
		allocates nothing reads (near) nothing, and `Bytes` of 1,000 and 8,000
		bytes read their size and not much more, a small one shares its
		block, a large one is allocated on its own.
	**/
	public function testTheMeterReadsWhatIsAllocated():Void {
		var nothing = AllocationMeter.measure(() -> {}, 200000);
		Assert.isTrue(nothing.perOperation < 1, "a run allocating nothing read " + nothing);

		var small = AllocationMeter.measure(() -> __sink = Bytes.alloc(1000), 4000);
		__report("Bytes.alloc(1000)", small);
		Assert.isTrue(small.perOperation >= 1000 && small.perOperation < 1000 * 1.05 + 64, "1,000-byte allocations read " + small);

		var large = AllocationMeter.measure(() -> __sink = Bytes.alloc(8000), 1000);
		__report("Bytes.alloc(8000)", large);
		Assert.isTrue(large.perOperation >= 8000 && large.perOperation < 8000 * 1.05 + 64, "8,000-byte allocations read " + large);
		__sink = null;
	}

	public function testAnEventDispatchedToAListener():Void {
		var dispatcher = new EventDispatcher();
		var heard:Int = 0;
		dispatcher.addEventListener(Event.COMPLETE, _ -> heard++);
		// One event, dispatched again and again: what is measured is the
		// dispatch, not the caller's `new Event`.
		var event = new Event(Event.COMPLETE);
		var op = () -> {
			dispatcher.dispatchEvent(event);
		};
		__warm(op, WARM_CHEAP);
		__within(EVENT, AllocationMeter.measure(op, 20000));
		Assert.isTrue(heard > 0);
	}

	public function testATimeoutArmedAndCleared():Void {
		var runtime = __start();
		var fired:Int = 0;
		var callback:Void->Void = () -> fired++;
		var op = () -> {
			var handle:Int = Timer.setTimeout(30.0, callback);
			Timer.clear(handle);
		};
		try {
			__warm(op, WARM_CHEAP);
			__within(TIMER, AllocationMeter.measure(op, 20000));
		} catch (error:Dynamic) {
			__finish();
			throw error;
		}
		__finish();
		Assert.equals(0, fired, "a cleared timeout fired");
	}

	public function testAnIntervalFiringAndRearming():Void {
		var runtime = __start();
		var fired:Int = 0;
		// Due every frame, and so fired once in each: a shorter interval is
		// fired again within the frame until it has caught up.
		Timer.setInterval(1 / 60, 1 / 60, () -> fired++);
		var op = () -> {
			var before:Int = fired;
			runtime.pump(1 / 60, 0);
			if (fired != before + 1) {
				throw "the interval fired " + (fired - before) + " times in a frame";
			}
		};
		try {
			__warm(op, WARM_CHEAP);
			__within(INTERVAL, AllocationMeter.measure(op, 20000));
		} catch (error:Dynamic) {
			__finish();
			throw error;
		}
		__finish();
	}

	public function testACallbackPostedToTheRuntime():Void {
		var runtime = __start();
		var ran:Int = 0;
		var callback:Void->Void = () -> ran++;
		var op = () -> {
			runtime.post(callback);
			runtime.pump(1 / 60, 0);
		};
		try {
			__warm(op, WARM_CHEAP);
			__within(POST, AllocationMeter.measure(op, 20000));
		} catch (error:Dynamic) {
			__finish();
			throw error;
		}
		__finish();
		Assert.isTrue(ran > 0);
	}

	public function testAnIdleFrame():Void {
		var runtime = __start();
		var op = () -> runtime.pump(1 / 60, 0);
		try {
			__warm(op, WARM_CHEAP);
			__within(IDLE_TICK, AllocationMeter.measure(op, 20000));
		} catch (error:Dynamic) {
			__finish();
			throw error;
		}
		__finish();
	}

	public function testAnHttpGetOnAKeptAliveConnection():Void {
		__httpRequest(HTTP_GET, false, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", null);
	}

	public function testAnHttpPostOfFourKilobytes():Void {
		var body = Bytes.alloc(4096);
		for (i in 0...body.length) {
			body.set(i, 97 + i % 26);
		}
		__httpRequest(HTTP_POST, false, "POST /upload HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/octet-stream\r\nContent-Length: 4096\r\n\r\n", body);
	}

	public function testAnHttpGetOverTls():Void {
		if (TLSTestFixture.trusted() == null) {
			// No openssl to make a certificate with.
			Assert.pass();
			return;
		}
		__httpRequest(TLS_GET, true, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", null);
	}

	public function testAnHttp2Get():Void {
		var runtime = __start();
		var config = __serverConfig();
		config.http2Enabled = true;
		__quietAccessLog(true);
		var server = new HTTPServer(config);
		var client = new H2Client();
		try {
			client.connect(server.localPort);
			__pumpUntil(() -> client.ready || client.failure != null);
			Assert.isNull(client.failure, "the HTTP/2 connection failed: " + client.failure);
			var answered:Void->Bool = client.answered;
			var op = () -> {
				client.get();
				__pumpUntil(answered);
			};
			__warm(op, WARM);
			__within(H2_GET, AllocationMeter.measure(op, 2000));
			Assert.isNull(client.failure, "the HTTP/2 connection failed: " + client.failure);
		} catch (error:Dynamic) {
			client.close();
			server.close();
			__quietAccessLog(false);
			__finish();
			throw error;
		}
		client.close();
		server.close();
		__quietAccessLog(false);
		__finish();
	}

	public function testAWebSocketMessageEchoed():Void {
		var runtime = __start();
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var session:WebSocket = cast e.socket;
			sessions.push(session);
			session.addEventListener(WebSocketMessageEvent.MESSAGE, (message:WebSocketMessageEvent) -> session.sendText(message.text));
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();
		var opened:Bool = false;
		var echoed:Int = 0;
		var sent:Int = 0;
		client.addEventListener(Event.CONNECT, _ -> opened = true);
		client.addEventListener(WebSocketMessageEvent.MESSAGE, function(message:WebSocketMessageEvent):Void {
			if (message.data.length == 100) {
				echoed++;
			}
		});
		var text:String = StringTools.lpad("", "x", 100);
		var back:Void->Bool = () -> echoed == sent;
		try {
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> opened);
			var op = () -> {
				sent++;
				client.sendText(text);
				__pumpUntil(back);
			};
			__warm(op, WARM);
			__within(WEBSOCKET, AllocationMeter.measure(op, 2000));
		} catch (error:Dynamic) {
			__closeAll(client, sessions, server);
			throw error;
		}
		__closeAll(client, sessions, server);
	}

	public function testAReliableMessageDeliveredAndAcknowledged():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.pass();
			return;
		}
		var runtime = __start();
		var server = new ReliableDatagramServerSocket();
		var accepted:ReliableDatagramSocket = null;
		var arrived:Int = 0;
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
			accepted = e.socket;
			accepted.addEventListener(DatagramSocketDataEvent.DATA, (_:DatagramSocketDataEvent) -> arrived++);
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new ReliableDatagramSocket();
		var message = new ByteArray();
		for (i in 0...200) {
			message.writeByte(i);
		}
		var sent:Int = 0;
		var delivered:Float = 0;
		var done:Void->Bool = () -> arrived == sent && client.framesDelivered >= delivered;
		try {
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> client.connected && accepted != null, false);
			var op = () -> {
				sent++;
				delivered = client.framesDelivered + 1;
				client.send(message, 0, 200);
				// A frame of 1/60 s each, as a game server's tick: the
				// acknowledgement is held for its 25 ms and goes in the next.
				__pumpUntil(done, false);
			};
			__warm(op, WARM);
			__within(RELIABLE, AllocationMeter.measure(op, 2000));
		} catch (error:Dynamic) {
			try client.close() catch (_:Dynamic) {}
			try server.close() catch (_:Dynamic) {}
			__finish();
			throw error;
		}
		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
		__finish();
	}

	/**
		The floor under every protocol here: bytes written to a `Socket`, read
		by the one it is connected to and written back, each end reading into a
		buffer of its own.
	**/
	public function testATcpMessageEchoed():Void {
		var runtime = __start();
		var server = new ServerSocket();
		var accepted:Socket = null;
		var serverInbox = new ByteArray();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var socket:Socket = e.socket;
			accepted = socket;
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_:ProgressEvent):Void {
				var count:Int = socket.bytesAvailable;
				socket.readBytes(serverInbox, 0, count);
				socket.writeBytes(serverInbox, 0, count);
				socket.flush();
			});
		});
		var client = new Socket();
		var connected:Bool = false;
		var arrived:Int = 0;
		var clientInbox = new ByteArray();
		client.addEventListener(Event.CONNECT, _ -> connected = true);
		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_:ProgressEvent):Void {
			var count:Int = client.bytesAvailable;
			client.readBytes(clientInbox, 0, count);
			arrived += count;
		});
		var message = new ByteArray();
		for (i in 0...100) {
			message.writeByte(i);
		}
		var expected:Int = 0;
		var back:Void->Bool = () -> arrived == expected;
		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> connected && accepted != null);
			var op = () -> {
				expected += 100;
				client.writeBytes(message, 0, 100);
				client.flush();
				__pumpUntil(back);
			};
			__warm(op, WARM);
			__within(TCP, AllocationMeter.measure(op, 2000));
		} catch (error:Dynamic) {
			try client.close() catch (_:Dynamic) {}
			try server.close() catch (_:Dynamic) {}
			__finish();
			throw error;
		}
		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
		__finish();
	}

	public function testADatagramSentAndReceived():Void {
		if (!DatagramSocket.isSupported) {
			Assert.pass();
			return;
		}
		var runtime = __start();
		var receiver = new DatagramSocket();
		var sender = new DatagramSocket();
		var arrived:Int = 0;
		var sent:Int = 0;
		receiver.addEventListener(DatagramSocketDataEvent.DATA, (_:DatagramSocketDataEvent) -> arrived++);
		var message = new ByteArray();
		for (i in 0...100) {
			message.writeByte(i);
		}
		var done:Void->Bool = () -> arrived == sent;
		try {
			receiver.bind(0, "127.0.0.1");
			receiver.receive();
			sender.bind(0, "127.0.0.1");
			var port:Int = receiver.localPort;
			var op = () -> {
				sent++;
				sender.send(message, 0, 100, "127.0.0.1", port);
				__pumpUntil(done);
			};
			__warm(op, WARM);
			__within(DATAGRAM, AllocationMeter.measure(op, 2000));
		} catch (error:Dynamic) {
			try sender.close() catch (_:Dynamic) {}
			try receiver.close() catch (_:Dynamic) {}
			__finish();
			throw error;
		}
		try sender.close() catch (_:Dynamic) {}
		try receiver.close() catch (_:Dynamic) {}
		__finish();
	}

	public function testAnRpcCallAndItsAnswer():Void {
		var link = LinkedConnection.pair();
		var commands = new BudgetCommands();
		var handler = new BudgetHandler();
		var clientSession = new RPCSession<BudgetCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);
		var answered:Int = 0;
		var op = () -> {
			var response = commands.add(answered, 1);
			if (!response.completed) {
				throw "the call was not answered";
			}
			answered = response.result;
		};
		__warm(op, WARM_CHEAP);
		__within(RPC_CALL, AllocationMeter.measure(op, 20000));
		Assert.isTrue(answered > 0);
	}

	public function testAOneWayRpcCall():Void {
		var link = LinkedConnection.pair();
		var commands = new BudgetCommands();
		var handler = new BudgetHandler();
		var clientSession = new RPCSession<BudgetCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);
		var op = () -> commands.move(7, 1.5, -2.25);
		__warm(op, WARM_CHEAP);
		__within(RPC_ONE_WAY, AllocationMeter.measure(op, 20000));
		Assert.isTrue(handler.moves > 0);
	}

	// ---------------------------------------------------------------------

	/** A request on one kept-alive connection to an `HTTPServer`, measured. **/
	private function __httpRequest(budget:Budget, tls:Bool, head:String, body:Null<Bytes>):Void {
		var runtime = __start();
		var config = __serverConfig();
		if (tls) {
			var fixture = TLSTestFixture.trusted();
			config.tlsCertificatePath = fixture.certificatePath;
			config.tlsKeyPath = fixture.keyPath;
		}
		__quietAccessLog(true);
		var server = new HTTPServer(config);
		var client = new Http1Client(tls);
		var request = new ByteArray();
		request.writeUTFBytes(head);
		if (body != null) {
			request.writeBytes(ByteArray.fromBytes(body), 0, body.length);
		}
		try {
			client.connect(server.localPort);
			__pumpUntil(() -> client.connected || client.failure != null);
			Assert.isNull(client.failure, "the client did not connect: " + client.failure);
			var answered:Void->Bool = client.answered;
			var op = () -> {
				client.send(request);
				__pumpUntil(answered);
			};
			op();
			Assert.equals(200, client.lastStatus, "the server answered " + client.lastStatus);
			__warm(op, WARM);
			__within(budget, AllocationMeter.measure(op, 2000));
			Assert.equals(200, client.lastStatus, "the server answered " + client.lastStatus);
			if (tls) {
				// The same request in plain text goes unanswered: what was
				// measured did go through TLS.
				var plain = new Http1Client(false);
				plain.connect(server.localPort);
				__pumpUntil(() -> plain.connected || plain.failure != null);
				if (plain.failure == null) {
					plain.send(request);
					var deadline:Float = haxe.Timer.stamp() + 2.0;
					__pumpUntil(() -> plain.failure != null || plain.responses > 0 || haxe.Timer.stamp() > deadline);
				}
				Assert.equals(0, plain.responses, "a plain-text request to the TLS server was answered");
				plain.close();
			}
		} catch (error:Dynamic) {
			client.close();
			server.close();
			__quietAccessLog(false);
			__finish();
			throw error;
		}
		client.close();
		server.close();
		__quietAccessLog(false);
		__finish();
	}

	/**
		Turns the access log off while a server is measured, and back on. It
		is on by default, and would write a line per request measured into
		the suite's output; what its line costs is not the server's.
	**/
	private static function __quietAccessLog(quiet:Bool):Void {
		crossbyte.utils.Logger.setLevel("http.access", quiet ? crossbyte.utils.LogLevel.WARN : null);
	}

	private static function __serverConfig():HTTPServerConfig {
		var config = new HTTPServerConfig("127.0.0.1", 0);
		// One connection carries every request measured, and the limiter
		// is still consulted for each, as a default server's is.
		config.keepAliveMaxRequests = 0;
		config.rateLimiter = new crossbyte.net.RateLimiter(1000000000, 60.0);
		config.middleware.push(function(handler, next):Void {
			if (handler.method == "POST") {
				handler.respond(200, "text/plain", handler.requestBody.length == 4096 ? "stored" : "short");
				return;
			}
			handler.respond(200, "text/plain", "hello, world");
		});
		return config;
	}

	/**
		A host-driven runtime of the case's own, with nothing on it, made the
		thread's runtime by a first frame: what the case makes, sockets,
		servers, timers, is its, and nothing else is. The suite's runtime is
		not idle by the time a case runs: in the full jvm suite a frame of it
		allocated 597 bytes, where an empty one's allocates 88 to 112, since
		other cases left sockets on it to poll. `__finish` ends it, which hands
		the thread back to the suite's.
	**/
	private static function __start():CrossByte {
		__runtime = new CrossByte(false, DEFAULT, true);
		__runtime.pump(0, 0);
		__lastPump = haxe.Timer.stamp();
		return __runtime;
	}

	private static function __finish():Void {
		if (__runtime != null) {
			__runtime.exit();
			__runtime = null;
		}
	}

	/**
		Pumps the runtime until `done`: each frame advanced by the wall time
		since the last, as a server's own loop is, or with `wall` false by a
		60th of a second. Allocates nothing itself.
	**/
	private static function __pumpUntil(done:Void->Bool, wall:Bool = true):Void {
		var runtime:CrossByte = __runtime;
		__deadline = haxe.Timer.stamp() + 10.0;
		while (!done()) {
			var now:Float = haxe.Timer.stamp();
			if (now > __deadline) {
				throw "an operation did not finish in 10 s";
			}
			runtime.pump(wall ? now - __lastPump : 1 / 60, 0);
			__lastPump = now;
		}
	}

	private static function __warm(op:Void->Void, count:Int):Void {
		for (_ in 0...count) {
			op();
		}
	}

	private static function __closeAll(client:WebSocket, sessions:Array<WebSocket>, server:ServerWebSocket):Void {
		try client.close() catch (_:Dynamic) {}
		for (session in sessions) {
			try session.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
		__finish();
	}

	private static function __report(what:String, reading:AllocationReading):Void {
		if (Sys.getEnv("CB_ALLOC_REPORT") != null) {
			Sys.println("[ALLOC] " + AllocationMeter.platform() + " " + what + ": " + reading);
		}
	}

	private static function __within(budget:Budget, reading:AllocationReading, ?pos:haxe.PosInfos):Void {
		var platform:String = AllocationMeter.platform();
		__report(budget.what, reading);
		var allowed:Int = budget.allowedOn(platform);
		Assert.isTrue(reading.perOperation <= allowed,
			budget.what + " allocated " + reading + " per " + budget.unit + ", past its budget of " + allowed + " B on " + platform + "; "
			+ budget.baselineOn(platform) + ". Rerun it alone, then see AllocationBudgetTest's doc comment.",
			pos);
	}
	#end
}

#if (cpp || jvm)
/**
	What one operation is allowed: bytes per operation as measured on
	`AllocationBudgetTest.MEASURED_ON`, and the budget, each natively on
	Windows and on Linux, and on the jvm (Windows and Linux alike), in that
	order.

	macOS is not measured. It runs Linux's code but for the poll, and is held
	to the larger native budget and a quarter again; a failure there says
	what it read, which is the figure to give it a budget of its own.
**/
@:access(crossbyte.AllocationBudgetTest)
private class Budget {
	public final what:String;
	public final unit:String;

	private final __measured:Array<Int>;
	private final __allowed:Array<Int>;

	public function new(what:String, unit:String, measured:Array<Int>, allowed:Array<Int>) {
		this.what = what;
		this.unit = unit;
		__measured = measured;
		__allowed = allowed;
	}

	public function allowedOn(platform:String):Int {
		return switch (platform) {
			case "windows": __allowed[0];
			case "linux": __allowed[1];
			case "jvm": __allowed[2];
			default: Math.ceil((__allowed[0] > __allowed[1] ? __allowed[0] : __allowed[1]) * 1.25);
		}
	}

	public function baselineOn(platform:String):String {
		var at:Int = switch (platform) {
			case "windows": 0;
			case "linux": 1;
			case "jvm": 2;
			default: -1;
		}
		if (at < 0) {
			return "it was not measured on " + platform + ", and measured " + __measured[0] + " B on Windows and " + __measured[1] + " B on Linux on "
				+ AllocationBudgetTest.MEASURED_ON;
		}
		return "it measured " + __measured[at] + " B there on " + AllocationBudgetTest.MEASURED_ON;
	}
}

/**
	An HTTP/1.1 client on one kept-alive connection that reads its responses
	into one buffer and counts them, parsing just enough, the status and
	`Content-Length`: to know where each ends. Allocates nothing per
	response, so what is measured is the server and the socket under it.
**/
private class Http1Client {
	public var failure:String = null;
	public var connected(get, never):Bool;
	public var lastStatus:Int = 0;
	public var responses:Int = 0;

	private var __socket:Socket;
	private var __inbox:ByteArray = new ByteArray();
	private var __filled:Int = 0;
	private var __sent:Int = 0;
	private var __connected:Bool = false;

	public function new(tls:Bool) {
		__socket = new Socket();
		if (tls) {
			__socket.secure = true;
			__socket.verifyCert = false;
		}
		__inbox.length = 64 * 1024;
		__socket.addEventListener(Event.CONNECT, _ -> __connected = true);
		__socket.addEventListener(crossbyte.events.IOErrorEvent.IO_ERROR, (e:crossbyte.events.IOErrorEvent) -> failure = e.text);
		__socket.addEventListener(Event.CLOSE, _ -> failure = "the server closed the connection");
		__socket.addEventListener(ProgressEvent.SOCKET_DATA, __onData);
	}

	public function connect(port:Int):Void {
		__socket.connect("127.0.0.1", port);
	}

	public function send(request:ByteArray):Void {
		__sent++;
		__socket.writeBytes(request, 0, request.length);
		__socket.flush();
	}

	public function answered():Bool {
		if (failure != null) {
			throw failure;
		}
		return responses == __sent;
	}

	public function close():Void {
		try __socket.close() catch (_:Dynamic) {}
	}

	private function get_connected():Bool {
		return __connected;
	}

	private function __onData(_:ProgressEvent):Void {
		var available:Int = __socket.bytesAvailable;
		if (available <= 0) {
			return;
		}
		if (__filled + available > __inbox.length) {
			__inbox.length = __filled + available;
		}
		__socket.readBytes(__inbox, __filled, available);
		__filled += available;

		while (true) {
			var end:Int = __responseEnd();
			if (end < 0) {
				return;
			}
			responses++;
			// Whatever follows the response moves to the front.
			for (i in end...__filled) {
				__inbox[i - end] = __inbox[i];
			}
			__filled -= end;
		}
	}

	/** One past the end of the response at the front of the inbox, or -1. **/
	private function __responseEnd():Int {
		var headEnd:Int = -1;
		var i:Int = 3;
		while (i < __filled) {
			if (__inbox[i] == 10 && __inbox[i - 1] == 13 && __inbox[i - 2] == 10 && __inbox[i - 3] == 13) {
				headEnd = i + 1;
				break;
			}
			i++;
		}
		if (headEnd < 0) {
			return -1;
		}
		// "HTTP/1.1 200"
		lastStatus = (__inbox[9] - 48) * 100 + (__inbox[10] - 48) * 10 + (__inbox[11] - 48);
		var length:Int = __contentLength(headEnd);
		if (length < 0 || __filled < headEnd + length) {
			return -1;
		}
		return headEnd + length;
	}

	private function __contentLength(headEnd:Int):Int {
		var name:String = "content-length:";
		var at:Int = 0;
		while (at + name.length < headEnd) {
			var matched:Bool = true;
			for (k in 0...name.length) {
				var c:Int = __inbox[at + k];
				if (c >= 65 && c <= 90) {
					c += 32;
				}
				if (c != StringTools.fastCodeAt(name, k)) {
					matched = false;
					break;
				}
			}
			if (matched) {
				var value:Int = 0;
				var p:Int = at + name.length;
				while (__inbox[p] == 32) {
					p++;
				}
				while (__inbox[p] >= 48 && __inbox[p] <= 57) {
					value = value * 10 + (__inbox[p] - 48);
					p++;
				}
				return value;
			}
			at++;
		}
		return -1;
	}
}

/**
	A cleartext HTTP/2 client with prior knowledge, enough for one GET at a
	time: the preface and SETTINGS once, the server's SETTINGS acknowledged,
	and then each request a HEADERS frame, read until its stream ends. Its
	header block names the authority from the HPACK table after the first
	request, as a browser's does. Allocates nothing per request.
**/
private class H2Client {
	public var failure:String = null;
	public var ready:Bool = false;

	private var __socket:Socket;
	private var __inbox:ByteArray = new ByteArray();
	private var __filled:Int = 0;
	private var __stream:Int = -1;
	private var __ended:Bool = true;
	private var __request:ByteArray = new ByteArray();
	private var __firstRequest:ByteArray = new ByteArray();
	private var __settingsAck:ByteArray = new ByteArray();

	public function new() {
		__socket = new Socket();
		__inbox.length = 64 * 1024;
		__socket.addEventListener(crossbyte.events.IOErrorEvent.IO_ERROR, (e:crossbyte.events.IOErrorEvent) -> failure = e.text);
		__socket.addEventListener(Event.CLOSE, _ -> failure = "the server closed the connection");
		__socket.addEventListener(Event.CONNECT, _ -> __greet());
		__socket.addEventListener(ProgressEvent.SOCKET_DATA, __onData);

		// :method GET, :scheme http, :path / from the static table; the
		// authority added to the dynamic table by the first request and
		// named by index 62 from then on.
		__frameHeader(__firstRequest, 14, 0x1, 0x5, 0);
		for (b in [0x82, 0x86, 0x84, 0x41, 0x09]) {
			__firstRequest.writeByte(b);
		}
		__firstRequest.writeUTFBytes("127.0.0.1");
		__frameHeader(__request, 4, 0x1, 0x5, 0);
		for (b in [0x82, 0x86, 0x84, 0xBE]) {
			__request.writeByte(b);
		}
		__frameHeader(__settingsAck, 0, 0x4, 0x1, 0);
	}

	public function connect(port:Int):Void {
		__socket.connect("127.0.0.1", port);
	}

	public function get():Void {
		__stream = __stream < 0 ? 1 : __stream + 2;
		__ended = false;
		var frame:ByteArray = __stream == 1 ? __firstRequest : __request;
		frame[5] = (__stream >> 24) & 0x7f;
		frame[6] = (__stream >> 16) & 0xff;
		frame[7] = (__stream >> 8) & 0xff;
		frame[8] = __stream & 0xff;
		__socket.writeBytes(frame, 0, frame.length);
		__socket.flush();
	}

	public function answered():Bool {
		if (failure != null) {
			throw failure;
		}
		return __ended;
	}

	public function close():Void {
		try __socket.close() catch (_:Dynamic) {}
	}

	private function __greet():Void {
		var hello = new ByteArray();
		hello.writeUTFBytes(crossbyte._internal.http.h2.H2Connection.PREFACE);
		// SETTINGS: INITIAL_WINDOW_SIZE as large as it goes, so no stream
		// waits for credit.
		__frameHeader(hello, 6, 0x4, 0, 0);
		hello.writeByte(0);
		hello.writeByte(4);
		hello.writeByte(0x7f);
		hello.writeByte(0xff);
		hello.writeByte(0xff);
		hello.writeByte(0xff);
		// And the connection's window opened to match.
		__frameHeader(hello, 4, 0x8, 0, 0);
		var increment:Int = 0x7fffffff - 65535;
		hello.writeByte((increment >> 24) & 0x7f);
		hello.writeByte((increment >> 16) & 0xff);
		hello.writeByte((increment >> 8) & 0xff);
		hello.writeByte(increment & 0xff);
		__socket.writeBytes(hello, 0, hello.length);
		__socket.flush();
	}

	private static function __frameHeader(out:ByteArray, length:Int, type:Int, flags:Int, stream:Int):Void {
		out.writeByte((length >> 16) & 0xff);
		out.writeByte((length >> 8) & 0xff);
		out.writeByte(length & 0xff);
		out.writeByte(type);
		out.writeByte(flags);
		out.writeByte((stream >> 24) & 0x7f);
		out.writeByte((stream >> 16) & 0xff);
		out.writeByte((stream >> 8) & 0xff);
		out.writeByte(stream & 0xff);
	}

	private function __onData(_:ProgressEvent):Void {
		var available:Int = __socket.bytesAvailable;
		if (available <= 0) {
			return;
		}
		if (__filled + available > __inbox.length) {
			__inbox.length = __filled + available;
		}
		__socket.readBytes(__inbox, __filled, available);
		__filled += available;

		var at:Int = 0;
		while (at + 9 <= __filled) {
			var length:Int = (__inbox[at] << 16) | (__inbox[at + 1] << 8) | __inbox[at + 2];
			if (at + 9 + length > __filled) {
				break;
			}
			var type:Int = __inbox[at + 3];
			var flags:Int = __inbox[at + 4];
			var stream:Int = ((__inbox[at + 5] & 0x7f) << 24) | (__inbox[at + 6] << 16) | (__inbox[at + 7] << 8) | __inbox[at + 8];
			switch (type) {
				case 0x4:
					if (flags & 0x1 == 0) {
						__socket.writeBytes(__settingsAck, 0, __settingsAck.length);
						__socket.flush();
						ready = true;
					}
				case 0x0 | 0x1:
					if (flags & 0x1 != 0 && stream == __stream) {
						__ended = true;
					}
				case 0x3:
					failure = "the server reset stream " + stream;
				case 0x7:
					failure = "the server sent GOAWAY";
				default:
			}
			at += 9 + length;
		}
		for (i in at...__filled) {
			__inbox[i - at] = __inbox[i];
		}
		__filled -= at;
	}
}

private class BudgetCommands extends RPCCommands {
	public function new() {}

	@:rpc public function add(a:Int, b:Int):RPCResponse<Int> {}

	@:rpc public function move(id:Int, x:Float, y:Float):Void {}
}

private class BudgetHandler extends RPCHandler {
	public var moves:Int = 0;

	public function new() {}

	@:rpc public function add(a:Int, b:Int):Int {
		return a + b;
	}

	@:rpc public function move(id:Int, x:Float, y:Float):Void {
		moves++;
	}
}
#end
