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
import crossbyte.net.INetConnection;
import crossbyte.net.NetConnection;
import crossbyte.net.NetHost;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import crossbyte.net.ServerSocket;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.Socket;
import crossbyte.net.TLSTestFixture;
import crossbyte.net.WebSocket;
import crossbyte.rpc.LinkedConnection;
import crossbyte.rpc.RPCBoolReceiver;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCFailure;
import crossbyte.rpc.RPCFloatReceiver;
import crossbyte.rpc.RPCInt64Receiver;
import crossbyte.rpc.RPCIntReceiver;
import crossbyte.rpc.RPCStringReceiver;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCResponse;
import crossbyte.rpc.RPCSession;
import crossbyte.test.AllocationMeter;
import haxe.io.Bytes;
import utest.Assert;
#end

/**
	How many bytes each common operation allocates, held to a budget.

	Each case runs one operation for real (a request to an `HTTPServer` over
	loopback, a message echoed by a `ServerWebSocket`, a call over an RPC
	pair), warms it up, and then measures what it allocates with
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
	private static inline var MEASURED_ON:String = "2026-10-05";

	// What each operation allocates, in bytes: as measured on MEASURED_ON
	// natively on Windows, natively on Linux and on the jvm, and then the
	// budget each is held to there: the figure and a quarter, and 64 bytes,
	// rounded up to 8. A figure of 0 is held to 8, which one object an
	// operation would pass. The jvm's figure is the largest of Oracle's JRE 8
	// on Windows, Temurin 8 on Linux and a run of the full suite.
	//
	//                                                                           measured                budget
	private static final EVENT = new Budget("an event dispatched to a listener", "dispatch", [0, 0, 0], [8, 8, 8]);
	private static final TIMER = new Budget("a timeout armed and cleared", "timer", [0, 0, 0], [8, 8, 8]);
	private static final TIMER_FIRED = new Budget("a timeout armed and fired", "timer", [0, 0, 0], [8, 8, 8]);
	private static final INTERVAL = new Budget("an interval timer firing and re-arming", "firing", [0, 0, 0], [8, 8, 8]);
	private static final HANDLE_INTERVAL = new Budget("an interval timer taking its handle, firing", "firing", [0, 0, 0], [8, 8, 8]);
	private static final PAUSE = new Budget("a timer paused and resumed", "pause", [0, 0, 0], [8, 8, 8]);
	private static final POST = new Budget("a callback posted to the runtime and run", "post", [0, 0, 0], [8, 8, 8]);
	private static final IDLE_TICK = new Budget("a runtime frame with nothing to do", "frame", [0, 0, 0], [8, 8, 8]);
	// The HTTP lines and the streamed line were measured later than
	// MEASURED_ON, on Oracle 8 and Temurin 8 alike for the jvm.
	private static final HTTP_GET = new Budget("an HTTP/1.1 GET on a kept-alive connection", "request", [152, 152, 240], [256, 256, 368]);
	private static final HTTP_POST = new Budget("an HTTP/1.1 POST of 4 KB on a kept-alive connection", "request", [4608, 4608, 4648], [5824, 5824, 5880]);
	private static final STREAM_TEXT = new Budget("a line of text written to a streamed response", "line", [0, 0, 16], [8, 8, 88]);
	private static final H2_GET = new Budget("an HTTP/2 GET over cleartext", "request", [3400, 3384, 2048], [4320, 4296, 2624]);
	private static final TLS_GET = new Budget("an HTTP/1.1 GET over TLS on a kept-alive connection", "request", [152, 152, 6968], [256, 256, 8776]);
	// The jvm's figure measured later than MEASURED_ON: the full suite on
	// Windows (alone 248, Temurin 8 on Linux 253). Nearly all of it is the
	// text the listener asks for.
	private static final WEBSOCKET = new Budget("a 100-byte WebSocket text message echoed", "message", [112, 112, 280], [208, 208, 416]);
	// Nothing natively: the frames each message is kept in until it is
	// acknowledged come from a pool and go back to it (FramePool). The jvm's
	// figures on these four lines, later than MEASURED_ON, are the full suite
	// on Windows: alone they read 0 there and on Temurin 8 on Linux, and in
	// the full suite the JDK's Windows selector boxes the descriptors it finds
	// ready (see sys.net.Socket's ReadyKeys).
	private static final RELIABLE = new Budget("a 200-byte reliable UDP message delivered and acknowledged", "message", [0, 0, 48], [8, 8, 128]);
	// The same, every datagram sealed and opened: what encryption adds is
	// buffers the server's sessions share, made once.
	private static final RELIABLE_ENCRYPTED = new Budget("a 200-byte encrypted reliable UDP message delivered and acknowledged", "message", [0, 0, 48], [8, 8, 128]);
	private static final TCP = new Budget("a 100-byte message echoed over TCP", "message", [0, 0, 32], [8, 8, 104]);
	private static final DATAGRAM = new Budget("a 100-byte datagram sent and received", "datagram", [0, 0, 16], [8, 8, 88]);
	// Over LinkedConnection, the in-memory pair, which copies each message
	// into a buffer it keeps, as a socket's read does. A call's figure is its
	// RPCResponse (128 B natively, 80 on the jvm) and the answer boxed into it
	// (24 B, 16 on the jvm); a frame
	// costs nothing. Measured later than MEASURED_ON; the jvm's on 2026-10-09,
	// once a send through the test double stopped reading its outTimestamp
	// through reflection (24 B a send before).
	private static final RPC_CALL = new Budget("an RPC call and its answer", "call", [152, 152, 96], [256, 256, 184]);
	private static final RPC_ONE_WAY = new Budget("a one-way RPC call", "call", [0, 0, 0], [8, 8, 8]);
	// The array and the string the handler is given are most of it.
	private static final RPC_RUNTIME_ONE_WAY = new Budget("a one-way runtime-lane RPC call of a 12-character string", "call", [152, 144, 128], [256, 248, 224]);
	// Written with runtimeCall and read with registerArgs: no array, nothing
	// boxed. Measured natively on Windows and on the jvm (Oracle 8), later
	// than MEASURED_ON; on Linux (WSL, the hxcpp fork) on 2026-10-09, the same.
	// Made with a receiver (`addThen(a, b, receiver)`): no RPCResponse, and
	// the answer handed over unboxed. Measured later than MEASURED_ON; Linux's
	// (WSL) and the jvm's on 2026-10-09, Linux's the same as Windows'.
	private static final RPC_INT_RECEIVER = new Budget("an RPC call answered through an RPCIntReceiver", "call", [0, 0, 0], [8, 8, 8]);
	private static final RPC_FLOAT_RECEIVER = new Budget("an RPC call answered through an RPCFloatReceiver", "call", [0, 0, 0], [8, 8, 8]);
	private static final RPC_INT64_RECEIVER = new Budget("an RPC call answered through an RPCInt64Receiver", "call", [0, 0, 0], [8, 8, 8]);
	private static final RPC_BOOL_RECEIVER = new Budget("an RPC call answered through an RPCBoolReceiver", "call", [0, 0, 0], [8, 8, 8]);
	// The answer's own string, 12 characters, and nothing else.
	private static final RPC_STRING_RECEIVER = new Budget("an RPC call answered with a 12-character string through an RPCStringReceiver", "call", [24, 24, 64], [96, 96, 144]);
	// The same over a TCP NetConnection to a NetHost, both ends on this
	// thread's runtime: what RPC costs on a real transport. Measured later than
	// MEASURED_ON; Linux's (WSL) on 2026-10-09, the same. Alone the jvm reads 0
	// and 96; its figures allow the 32 B the TCP line reads in the full suite
	// (the JDK's Windows selector boxing what it finds ready).
	private static final RPC_TCP_RECEIVER = new Budget("an RPC call over TCP answered through an RPCIntReceiver", "call", [0, 0, 32], [8, 8, 104]);
	private static final RPC_TCP_CALL = new Budget("an RPC call over TCP and its answer", "call", [152, 152, 128], [256, 256, 224]);
	// The same over reliable UDP. A message arriving was copied for the
	// connection's application, 336 B a call natively, until a session
	// reading its frames borrowed it instead. Measured on 2026-10-09 on
	// Windows, Linux (WSL) and the jvm. Alone the jvm reads 0; its figures
	// allow the 32 B it reads after other reliable UDP and RPC transport
	// cases, as the TCP line's do (the JDK's Windows selector boxing the two
	// sockets it finds ready, which the compiler leaves out only sometimes).
	private static final RPC_RUDP_RECEIVER = new Budget("an RPC call over reliable UDP answered through an RPCIntReceiver", "call", [0, 0, 32], [8, 8, 104]);
	// A call the other side has no method for, told to a receiver as
	// UnknownMethod: nothing, where the reason `onUnreadableFrame` would be
	// told was made for every one (240 B natively, 1,208 on the jvm) though
	// nothing listened. Measured on 2026-10-09 on Windows, Linux (WSL) and
	// the jvm.
	private static final RPC_UNKNOWN_REFUSED = new Budget("an RPC call to a method the other side has not got, refused through a receiver", "call", [0, 0, 0], [8, 8, 8]);
	// An answer of 256 KiB in pieces: the answer itself, and on the jvm 1 KB
	// more (natively only the large objects are read; see measureLarge). The
	// reader put it together in a buffer grown to its size and copied it out,
	// and the writer framed it in a buffer of its own (787 KB natively and on
	// the jvm), and took 2.8 times as long. Measured on 2026-10-09 on
	// Windows, Linux (WSL) and the jvm.
	private static final RPC_LARGE_ANSWER = new Budget("a 256 KiB RPC answer of one Bytes, in pieces", "answer", [262144, 262144, 263590], [264192, 264192, 265216]);
	private static final RPC_TYPED_ONE_WAY = new Budget("a one-way runtime-lane RPC call of three Floats, written and read typed", "call", [0, 0, 0], [8, 8, 8]);

	/**
		Operations run before measuring, so what the first ones build is not
		counted. On the jvm, enough for the compiler to have finished with
		the path: after 6,000, Temurin 8's first run of a GET still reads a
		fifth above the two after it.
	**/
	private static inline var WARM:Int = #if jvm 12000 #else 300 #end;

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
		bytes read their size and not much more (a small one shares its
		block, a large one is allocated on its own).
	**/
	public function testTheMeterReadsWhatIsAllocated():Void {
		var nothing = AllocationMeter.measure(() -> {}, 200000);
		Assert.isTrue(nothing.perOperation < 1, "a run allocating nothing read " + nothing);

		var small = AllocationMeter.measure(() -> __sink = Bytes.alloc(1000), 4000);
		__report("Bytes.alloc(1000)", small);
		Assert.isTrue(small.perOperation >= 1000 && small.perOperation < 1000 * 1.05 + 64, "1,000-byte allocations read " + small);

		// On the jvm an array this size is allocated outside the thread's
		// allocation buffer, and the thread's count also takes in the buffers
		// it refills, a megabyte or so at a time: over 1,000 operations one
		// refill reads as a kilobyte each. Ten times as many spreads it out.
		var large = AllocationMeter.measure(() -> __sink = Bytes.alloc(8000), #if jvm 10000 #else 1000 #end);
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

	public function testATimeoutArmedAndFired():Void {
		// What reliable UDP does with every acknowledgement it holds whose
		// time runs out.
		var runtime = __start();
		var fired:Int = 0;
		var callback:Void->Void = () -> fired++;
		var op = () -> {
			var before:Int = fired;
			Timer.setTimeout(0.0, callback);
			runtime.pump(1 / 60, 0);
			if (fired != before + 1) {
				throw "the timeout fired " + (fired - before) + " times in a frame";
			}
		};
		try {
			__warm(op, WARM_CHEAP);
			__within(TIMER_FIRED, AllocationMeter.measure(op, 20000));
		} catch (error:Dynamic) {
			__finish();
			throw error;
		}
		__finish();
	}

	public function testATimerPausedAndResumed():Void {
		// What a game does with the timers of whatever it pauses. Natively the
		// time a timer was paused at must not be a boxed Float, and on the jvm
		// the time and policy must not be boxed again by each default they pass.
		var runtime = __start();
		// A frame in, so the clock is not at a whole second: natively a boxed
		// whole number of up to 255 is taken from a cache.
		runtime.pump(1 / 60, 0);
		var fired:Int = 0;
		var handle:Int = Timer.setTimeout(30.0, () -> fired++);
		var op = () -> {
			if (!Timer.pause(handle) || !Timer.resume(handle, Timer.getTime())) {
				throw "the timer was not paused and resumed";
			}
		};
		try {
			__warm(op, WARM_CHEAP);
			__within(PAUSE, AllocationMeter.measure(op, 20000));
		} catch (error:Dynamic) {
			__finish();
			throw error;
		}
		Timer.clear(handle);
		__finish();
		Assert.equals(0, fired, "a timer paused and resumed in place fired");
	}

	public function testAnIntervalTakingItsHandleFiring():Void {
		var runtime = __start();
		// Handles past the small-int caches, as a runtime's are once it has
		// armed a few hundred timers.
		for (_ in 0...300) {
			Timer.clear(Timer.setTimeout(30.0, () -> {}));
		}
		var fired:Int = 0;
		var handle:Int = -1;
		handle = Timer.setInterval(1 / 60, 1 / 60, (h:Int) -> {
			if (h == handle) {
				fired++;
			}
		});
		var op = () -> {
			var before:Int = fired;
			runtime.pump(1 / 60, 0);
			if (fired != before + 1) {
				throw "the interval fired " + (fired - before) + " times in a frame with its own handle";
			}
		};
		try {
			__warm(op, WARM_CHEAP);
			__within(HANDLE_INTERVAL, AllocationMeter.measure(op, 20000));
		} catch (error:Dynamic) {
			__finish();
			throw error;
		}
		__finish();
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

	/**
		A line of server-sent events written to a streamed response with
		`writeText` and read by the client: the text is encoded into a
		buffer the thread keeps, and a chunk's size is written as digits.
	**/
	public function testAStreamedResponsesTextWritten():Void {
		var runtime = __start();
		var config = __serverConfig();
		var stream:Null<crossbyte.http.HTTPResponseStream> = null;
		config.middleware.unshift(function(handler, next):Void {
			if (handler.requestPath == "/events") {
				stream = handler.beginResponse(200, "text/event-stream");
				return;
			}
			next();
		});
		__quietAccessLog(true);
		var server = new HTTPServer(config);
		var client = new Socket();
		var inbox = new ByteArray();
		var received:Int = 0;
		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_:ProgressEvent):Void {
			var count:Int = client.bytesAvailable;
			client.readBytes(inbox, 0, count);
			inbox.length = 0;
			received += count;
		});
		var connected:Bool = false;
		client.addEventListener(Event.CONNECT, _ -> connected = true);
		var text:String = "data: tick\n\n";
		var expected:Int = 0;
		var arrived:Void->Bool = () -> received >= expected;
		try {
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> connected);
			client.writeUTFBytes("GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
			client.flush();
			__pumpUntil(() -> stream != null && received > 0);
			// A chunk: its size in hex, CRLF, the text, CRLF.
			var perLine:Int = StringTools.hex(text.length).length + 2 + text.length + 2;
			var op = () -> {
				expected = received + perLine;
				stream.writeText(text);
				__pumpUntil(arrived);
			};
			__warm(op, WARM);
			__within(STREAM_TEXT, AllocationMeter.measure(op, 2000));
		} catch (error:Dynamic) {
			try client.close() catch (_:Dynamic) {}
			server.close();
			__quietAccessLog(false);
			__finish();
			throw error;
		}
		try client.close() catch (_:Dynamic) {}
		server.close();
		__quietAccessLog(false);
		__finish();
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
		`testAReliableMessageDeliveredAndAcknowledged` with the session
		encrypted (`ReliableDatagramSocket.encryptionKey`): every datagram
		sealed by one end and opened by the other. Not on a target that
		cannot encrypt.
	**/
	public function testAnEncryptedReliableMessageDeliveredAndAcknowledged():Void {
		if (!ReliableDatagramSocket.isEncryptionSupported) {
			Assert.pass();
			return;
		}
		var runtime = __start();
		var key = haxe.io.Bytes.alloc(32);
		for (i in 0...32) {
			key.set(i, i * 5);
		}
		var server = new ReliableDatagramServerSocket();
		server.encryptionKeyFor = (_, _, _) -> key;
		var accepted:ReliableDatagramSocket = null;
		var arrived:Int = 0;
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
			accepted = e.socket;
			accepted.addEventListener(DatagramSocketDataEvent.DATA, (_:DatagramSocketDataEvent) -> arrived++);
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new ReliableDatagramSocket();
		client.encryptionKey = key;
		var message = new ByteArray();
		for (i in 0...200) {
			message.writeByte(i);
		}
		var sent:Int = 0;
		var delivered:Float = 0;
		var done:Void->Bool = () -> arrived == sent && client.framesDelivered >= delivered;
		try {
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> client.connected && accepted != null && accepted.connected, false);
			var op = () -> {
				sent++;
				delivered = client.framesDelivered + 1;
				client.send(message, 0, 200);
				__pumpUntil(done, false);
			};
			__warm(op, WARM);
			__within(RELIABLE_ENCRYPTED, AllocationMeter.measure(op, 2000));
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
		// Typed Void: an arrow function ending in an assignment returns its
		// value, which natively is boxed as the function is called.
		var answered:Int = 0;
		var op = function():Void {
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

	/**
		A deadline from the session's `callTimeout` costs a call nothing: the
		calls under it share one queue and one timer. A timer of its own for
		each call (112 bytes natively and 95 on the jvm) is less than a quarter
		of a call's figure, so the call's budget alone would not catch it.
	**/
	public function testAnRpcCallsDeadlineAllocatesNothing():Void {
		var without:AllocationReading = __rpcCallUnder(0);
		var under:AllocationReading = __rpcCallUnder(30000);
		__report("an RPC call and its answer, without a deadline", without);
		__report("an RPC call and its answer, under callTimeout", under);
		Assert.isTrue(under.perOperation - without.perOperation <= 16,
			"a call under callTimeout allocated " + under + ", where one without allocated " + without);
	}

	private static function __rpcCallUnder(callTimeout:Int):AllocationReading {
		var link = LinkedConnection.pair();
		var commands = new BudgetCommands();
		var clientSession = new RPCSession<BudgetCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new BudgetHandler());
		clientSession.callTimeout = callTimeout;
		// Typed Void: an arrow function ending in an assignment returns its
		// value, which natively is boxed as the function is called.
		var answered:Int = 0;
		var op = function():Void {
			var response = commands.add(answered, 1);
			if (!response.completed) {
				throw "the call was not answered";
			}
			answered = response.result;
		};
		__warm(op, WARM_CHEAP);
		return AllocationMeter.measure(op, 20000);
	}

	public function testAnRpcCallAnsweredThroughAnIntReceiver():Void {
		var fixture = new BudgetRpc();
		var receiver = fixture.receiver;
		var op = () -> {
			var told:Int = receiver.told;
			fixture.commands.addThen(receiver.int, 1, receiver);
			if (receiver.told != told + 1) {
				throw "the call was not answered";
			}
		};
		__warm(op, WARM_CHEAP);
		__within(RPC_INT_RECEIVER, AllocationMeter.measure(op, 20000));
		Assert.isTrue(receiver.int > 0);
	}

	/**
		An answer of one `Bytes` that comes in pieces is put together in the
		`Bytes` its call is answered with: what its reader allocates is its
		own size once, not a buffer grown to its size and then copied out.
	**/
	public function testALargeRpcAnswerOfOneBytesIsPutTogetherInPlace():Void {
		// The server first, so the client's hello, saying it reads pieces,
		// reaches it.
		var link = PassingConnection.pair();
		var server = new RPCSession(link.server, null, new BudgetHandler());
		var commands = new BudgetCommands();
		var client = new RPCSession<BudgetCommands>(link.client, commands);
		Assert.isTrue((server.peerCapabilities & crossbyte.rpc._internal.RPCWire.CAPABILITY_CHUNKS) != 0, "the server does not know the client reads pieces");
		var size:Int = 256 * 1024;
		var receiver = new BytesReceiver();
		var op = () -> {
			var before:Float = receiver.got;
			var sends:Int = link.server.sent;
			commands.blobThen(size, receiver);
			if (receiver.got != before + size) {
				throw "the answer did not arrive whole";
			}
			if (link.server.sent - sends < 4) {
				throw "the answer did not go in pieces";
			}
		};
		__warm(op, #if jvm 500 #else 20 #end);
		__within(RPC_LARGE_ANSWER, AllocationMeter.measureLarge(op, 200));
		Assert.isTrue(receiver.got > 0);
	}

	public function testAnRpcCallToAMethodTheOtherSideHasNotGot():Void {
		var fixture = new BudgetRpc();
		var refused = new RefusedReceiver();
		var op = () -> {
			var told:Int = refused.told;
			fixture.commands.absentThen(1, refused);
			if (refused.told != told + 1) {
				throw "the call was not refused";
			}
		};
		__warm(op, WARM_CHEAP);
		__within(RPC_UNKNOWN_REFUSED, AllocationMeter.measure(op, 20000));
		Assert.isTrue(refused.told > 0);
	}

	public function testAnRpcCallAnsweredThroughAFloatReceiver():Void {
		var fixture = new BudgetRpc();
		var receiver = fixture.receiver;
		var op = () -> {
			var told:Int = receiver.told;
			fixture.commands.scaleThen(receiver.float, receiver);
			if (receiver.told != told + 1) {
				throw "the call was not answered";
			}
		};
		__warm(op, WARM_CHEAP);
		__within(RPC_FLOAT_RECEIVER, AllocationMeter.measure(op, 20000));
		Assert.isTrue(receiver.float > 1);
	}

	public function testAnRpcCallAnsweredThroughAnInt64Receiver():Void {
		var fixture = new BudgetRpc();
		var receiver = fixture.receiver;
		var op = () -> {
			var told:Int = receiver.told;
			fixture.commands.countThen(receiver.int64, receiver);
			if (receiver.told != told + 1) {
				throw "the call was not answered";
			}
		};
		__warm(op, WARM_CHEAP);
		__within(RPC_INT64_RECEIVER, AllocationMeter.measure(op, 20000));
		Assert.isTrue(receiver.int64 > haxe.Int64.make(1, 0));
	}

	public function testAnRpcCallAnsweredThroughABoolReceiver():Void {
		var fixture = new BudgetRpc();
		var receiver = fixture.receiver;
		var op = () -> {
			var told:Int = receiver.told;
			fixture.commands.flipThen(receiver.bool, receiver);
			if (receiver.told != told + 1) {
				throw "the call was not answered";
			}
		};
		__warm(op, WARM_CHEAP);
		__within(RPC_BOOL_RECEIVER, AllocationMeter.measure(op, 20000));
		Assert.isTrue(receiver.told > 0);
	}

	public function testAnRpcCallAnsweredThroughAStringReceiver():Void {
		var fixture = new BudgetRpc();
		var receiver = fixture.receiver;
		var op = () -> {
			var told:Int = receiver.told;
			fixture.commands.greetThen(7, receiver);
			if (receiver.told != told + 1) {
				throw "the call was not answered";
			}
		};
		__warm(op, WARM_CHEAP);
		__within(RPC_STRING_RECEIVER, AllocationMeter.measure(op, 20000));
		Assert.equals("hello, world", receiver.string);
	}

	/**
		A call made with a receiver under the session's `callTimeout` costs
		nothing more than one without: its deadline waits in the session's
		queue, as a future's does.
	**/
	public function testAReceiverCallsDeadlineAllocatesNothing():Void {
		var fixture = new BudgetRpc();
		fixture.client.callTimeout = 30000;
		var receiver = fixture.receiver;
		var op = () -> {
			var told:Int = receiver.told;
			fixture.commands.addThen(receiver.int, 1, receiver);
			if (receiver.told != told + 1) {
				throw "the call was not answered";
			}
		};
		__warm(op, WARM_CHEAP);
		var under:AllocationReading = AllocationMeter.measure(op, 20000);
		__report("an RPC call answered through an RPCIntReceiver, under callTimeout", under);
		__within(RPC_INT_RECEIVER, under);
	}

	/**
		A call given a deadline of its own, with `RPCResponse.timeout` after it
		is made or `withTimeout` before, costs nothing more than one without:
		it waits in the session's heap of deadlines, whatever its length. Each
		such call held a timer of its own, a closure and a timer node, before
		that heap took deadlines of any length.
	**/
	public function testACallsOwnDeadlineAllocatesNothing():Void {
		var fixture = new BudgetRpc();
		var receiver = fixture.receiver;
		var commands = fixture.commands;
		var flip:Bool = false;
		var without = () -> {
			var told:Int = receiver.told;
			commands.addThen(receiver.int, 1, receiver);
			if (receiver.told != told + 1) {
				throw "the call was not answered";
			}
		};
		var receiverOwn = () -> {
			var told:Int = receiver.told;
			flip = !flip;
			commands.withTimeout(flip ? 20000 : 30000).addThen(receiver.int, 1, receiver);
			if (receiver.told != told + 1) {
				throw "the call was not answered";
			}
		};
		// A future's answer held back until its deadline has been given, as
		// one from a real peer is: given to a call answered already,
		// `timeout` does nothing. Both are held, so both pay for the holding.
		var answered:Int = 0;
		var link = fixture.link;
		var futureWithout = function():Void {
			link.client.bufferInbound = true;
			var response = commands.add(answered, 1);
			link.client.bufferInbound = false;
			link.client.flushBufferedReads();
			if (!response.completed) {
				throw "the call was not answered";
			}
			answered = response.result;
		};
		var futureOwn = function():Void {
			flip = !flip;
			link.client.bufferInbound = true;
			var response = commands.add(answered, 1).timeout(flip ? 20000 : 30000);
			link.client.bufferInbound = false;
			link.client.flushBufferedReads();
			if (!response.completed) {
				throw "the call was not answered";
			}
			answered = response.result;
		};
		for (op in [without, receiverOwn, futureWithout, futureOwn]) {
			__warm(op, WARM_CHEAP);
		}
		var readings = [for (op in [without, receiverOwn, futureWithout, futureOwn]) AllocationMeter.measure(op, 20000)];
		__report("an RPC call through a receiver, without a deadline", readings[0]);
		__report("an RPC call through a receiver, under withTimeout", readings[1]);
		__report("an RPC call with a future, without a deadline", readings[2]);
		__report("an RPC call with a future, under timeout()", readings[3]);
		Assert.isTrue(readings[1].perOperation - readings[0].perOperation <= 16,
			"a receiver call under withTimeout allocated " + readings[1] + ", where one without allocated " + readings[0]);
		Assert.isTrue(readings[3].perOperation - readings[2].perOperation <= 16,
			"a call given timeout() allocated " + readings[3] + ", where one without allocated " + readings[2]);
	}

	/**
		A send through a connection of the application's own, wrapped as a
		`NetConnection`, allocates nothing for being wrapped. On the jvm the
		wrapper read the connection's `outTimestamp` through the interface,
		which is reflection there, and boxed it: 24 bytes a send, and so a
		call made through `LinkedConnection` cost 24 bytes more there than
		over TCP.
	**/
	public function testASendThroughAnApplicationsConnectionAllocatesNothing():Void {
		var link = LinkedConnection.pair();
		var wrapped:NetConnection = NetConnection.fromINetConnection(link.client);
		var payload = new crossbyte.io.ByteArray();
		payload.writeInt(7);
		var op = () -> wrapped.send(payload);
		__warm(op, WARM_CHEAP);
		var reading:AllocationReading = AllocationMeter.measure(op, 20000);
		__report("a send through an application's INetConnection", reading);
		Assert.isTrue(reading.perOperation <= 8, "a send through a wrapped connection allocated " + reading);
	}

	public function testAnRpcCallOverTcp():Void {
		var runtime = __start();
		var handler = new BudgetHandler();
		var accepted:Array<RPCSession<Dynamic, Dynamic>> = [];
		var host:NetHost = null;
		var session:RPCSession<BudgetCommands> = null;
		try {
			host = new NetHost("tcp://127.0.0.1:0", (connection:INetConnection) -> {
				accepted.push(new RPCSession(connection, null, handler));
			});
			host.listen();
			__pumpUntil(() -> host.localPort != 0);
			var commands = new BudgetCommands();
			var connection = new NetConnection("tcp://127.0.0.1:" + host.localPort);
			session = new RPCSession<BudgetCommands>(connection, commands);
			__pumpUntil(() -> session.up && accepted.length > 0);
			var receiver = new BudgetReceiver();
			var told:Int = 0;
			var answered:Void->Bool = () -> receiver.told == told;
			var byReceiver = function():Void {
				told = receiver.told + 1;
				commands.addThen(receiver.int, 1, receiver);
				__pumpUntil(answered);
			};
			__warm(byReceiver, WARM);
			__within(RPC_TCP_RECEIVER, AllocationMeter.measure(byReceiver, 2000));

			var last:RPCResponse<Int> = null;
			var completed:Void->Bool = () -> last.completed;
			var byFuture = function():Void {
				last = commands.add(receiver.int, 1);
				__pumpUntil(completed);
				receiver.int = last.result;
			};
			__warm(byFuture, WARM);
			__within(RPC_TCP_CALL, AllocationMeter.measure(byFuture, 2000));
			Assert.isTrue(receiver.int > 0);
		} catch (error:Dynamic) {
			try session.close() catch (_:Dynamic) {}
			try host.close() catch (_:Dynamic) {}
			__finish();
			throw error;
		}
		try session.close() catch (_:Dynamic) {}
		try host.close() catch (_:Dynamic) {}
		__finish();
	}

	public function testAnRpcCallOverReliableUdp():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.pass();
			return;
		}
		var runtime = __start();
		var handler = new BudgetHandler();
		var accepted:Array<RPCSession<Dynamic, Dynamic>> = [];
		var host:NetHost = null;
		var session:RPCSession<BudgetCommands> = null;
		try {
			host = new NetHost("rudp://127.0.0.1:0", (connection:INetConnection) -> {
				accepted.push(new RPCSession(connection, null, handler));
			});
			host.listen();
			__pumpUntil(() -> host.localPort != 0);
			var commands = new BudgetCommands();
			var connection = new NetConnection("rudp://127.0.0.1:" + host.localPort);
			session = new RPCSession<BudgetCommands>(connection, commands);
			__pumpUntil(() -> session.up && accepted.length > 0);
			var receiver = new BudgetReceiver();
			var told:Int = 0;
			var answered:Void->Bool = () -> receiver.told == told;
			var byReceiver = function():Void {
				told = receiver.told + 1;
				commands.addThen(receiver.int, 1, receiver);
				__pumpUntil(answered);
			};
			__warm(byReceiver, WARM);
			__within(RPC_RUDP_RECEIVER, AllocationMeter.measure(byReceiver, 2000));
			Assert.isTrue(receiver.int > 0);
		} catch (error:Dynamic) {
			try session.close() catch (_:Dynamic) {}
			try host.close() catch (_:Dynamic) {}
			__finish();
			throw error;
		}
		try session.close() catch (_:Dynamic) {}
		try host.close() catch (_:Dynamic) {}
		__finish();
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

	public function testAOneWayRuntimeRpcCall():Void {
		// The arguments' array is the caller's, made once: what is counted is
		// the lane's, the array and the string the handler is given among it.
		var link = LinkedConnection.pair();
		var serverSession = new RPCSession(link.server);
		var clientSession = new RPCSession(link.client);
		var heard:Array<Int> = [0];
		serverSession.register(7, args -> {
			heard[0]++;
			return null;
		});
		var args:Array<Dynamic> = ["hello, world"];
		var op = () -> clientSession.call(7, args);
		__warm(op, WARM_CHEAP);
		__within(RPC_RUNTIME_ONE_WAY, AllocationMeter.measure(op, 20000));
		Assert.isTrue(heard[0] > 0);
	}

	public function testATypedRuntimeRpcCall():Void {
		// runtimeCall's writer is the session's frame, and registerArgs'
		// reader the session's own: a call of numbers allocates nothing.
		var link = LinkedConnection.pair();
		var serverSession = new RPCSession(link.server);
		var clientSession = new RPCSession(link.client);
		var heard:Array<Float> = [0];
		serverSession.registerArgs(7, args -> {
			heard[0] += args.float(0) + args.float(1) + args.float(2);
			return null;
		});
		var op = () -> clientSession.runtimeCall(7).float(1.5).float(2.5).float(3.5).send();
		__warm(op, WARM_CHEAP);
		__within(RPC_TYPED_ONE_WAY, AllocationMeter.measure(op, 20000));
		Assert.isTrue(heard[0] > 0);
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
		thread's runtime by a first frame: what the case makes (sockets,
		servers, timers) is its, and nothing else is. The suite's runtime is
		not idle by the time a case runs: in the full jvm suite a frame of it
		allocates 597 bytes, where an empty one's allocates a sixth of that,
		since other cases leave sockets on it to poll. `__finish` ends it,
		which hands the thread back to the suite's.
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
	into one buffer and counts them, parsing just enough (the status and
	`Content-Length`) to know where each ends. Allocates nothing per
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

	@:rpc public function scale(x:Float):RPCResponse<Float> {}

	@:rpc public function flip(on:Bool):RPCResponse<Bool> {}

	@:rpc public function greet(id:Int):RPCResponse<String> {}

	@:rpc public function count(n:haxe.Int64):RPCResponse<haxe.Int64> {}

	// Its handler has no such method.
	@:rpc public function absent(a:Int):RPCResponse<Int> {}

	@:rpc public function blob(size:Int):RPCResponse<Bytes> {}
}

/** Counts the bytes of the answers it is told. **/
private class BytesReceiver implements crossbyte.rpc.RPCValueReceiver<Bytes> {
	public var got:Float = 0;

	public function new() {}

	public function onValue(call:Int, value:Bytes):Void {
		got += value.length;
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {}
}

/** Counts the calls refused as UnknownMethod. **/
private class RefusedReceiver implements RPCIntReceiver {
	public var told:Int = 0;

	public function new() {}

	public function onInt(call:Int, value:Int):Void {
		throw "a call to a method nobody has was answered";
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		if (failure != UnknownMethod) {
			throw "the call failed as " + failure;
		}
		told++;
	}
}

/** A pair of sessions over the in-memory pair, and a receiver for their answers. **/
/**
	Two connections joined in memory that pace (an `RPCSession` sends a large
	answer over them in pieces) and pass each send to the peer at once, read
	from one buffer each, so a reading counts what the sessions allocate and
	not the link.
**/
private class PassingConnection extends crossbyte.net.NetConnectionBase implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var onData(get, set):crossbyte.io.ByteArrayInput->Void;
	public var onClose(get, set):crossbyte.net.Reason->Void;
	public var onError(get, set):crossbyte.net.Reason->Void;
	public var onReady(get, set):Void->Void;

	public var peer:PassingConnection;
	/** How many sends this has made. **/
	public var sent:Int = 0;

	final input:ByteArray = new ByteArray();
	// What arrived before anything read it.
	final early:Array<ByteArray> = [];
	var reading:Bool = false;
	var __readEnabled:Bool = false;
	var __onData:crossbyte.io.ByteArrayInput->Void = input -> {};
	var __onClose:crossbyte.net.Reason->Void = reason -> {};
	var __onError:crossbyte.net.Reason->Void = reason -> {};
	var __onReady:Void->Void = () -> {};

	public static function pair():{client:PassingConnection, server:PassingConnection} {
		final client = new PassingConnection();
		final server = new PassingConnection();
		client.peer = server;
		server.peer = client;
		return {client: client, server: server};
	}

	public function new() {
		protocol = TCP;
		__paces = true;
	}

	public function expose():crossbyte.net.Transport {
		return null;
	}

	public function send(data:ByteArray):Void {
		__sendRange(data, 0, data.length);
	}

	override public function __sendRange(data:ByteArray, offset:Int, length:Int):Void {
		sent++;
		peer.receive(data, offset, length);
	}

	function receive(data:ByteArray, offset:Int, length:Int):Void {
		if (!__readEnabled || reading) {
			final copy = new ByteArray();
			copy.writeBytes(data, offset, length);
			early.push(copy);
			return;
		}
		reading = true;
		input.clear();
		input.writeBytes(data, offset, length);
		input.position = 0;
		__onData(input);
		reading = false;
		if (early.length > 0) {
			final next = early.shift();
			receive(next, 0, next.length);
		}
	}

	public function close():Void {}

	inline function get_remoteAddress():String {
		return "127.0.0.1";
	}

	inline function get_remotePort():Int {
		return 1;
	}

	inline function get_localAddress():String {
		return "127.0.0.1";
	}

	inline function get_localPort():Int {
		return 1;
	}

	inline function get_connected():Bool {
		return true;
	}

	inline function get_readEnabled():Bool {
		return __readEnabled;
	}

	function set_readEnabled(value:Bool):Bool {
		__readEnabled = value;
		if (value && early.length > 0) {
			final next = early.shift();
			receive(next, 0, next.length);
		}
		return value;
	}

	inline function get_onData():crossbyte.io.ByteArrayInput->Void {
		return __onData;
	}

	inline function set_onData(value:crossbyte.io.ByteArrayInput->Void):crossbyte.io.ByteArrayInput->Void {
		return __onData = value != null ? value : input -> {};
	}

	inline function get_onClose():crossbyte.net.Reason->Void {
		return __onClose;
	}

	inline function set_onClose(value:crossbyte.net.Reason->Void):crossbyte.net.Reason->Void {
		return __onClose = value != null ? value : reason -> {};
	}

	inline function get_onError():crossbyte.net.Reason->Void {
		return __onError;
	}

	inline function set_onError(value:crossbyte.net.Reason->Void):crossbyte.net.Reason->Void {
		return __onError = value != null ? value : reason -> {};
	}

	inline function get_onReady():Void->Void {
		return __onReady;
	}

	inline function set_onReady(value:Void->Void):Void->Void {
		return __onReady = value != null ? value : () -> {};
	}
}

private class BudgetRpc {
	public final link = LinkedConnection.pair();
	public final commands = new BudgetCommands();
	public final handler = new BudgetHandler();
	public final receiver = new BudgetReceiver();
	public final client:RPCSession<BudgetCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<BudgetCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}

/** Keeps the last answer of each kind, and counts them. **/
private class BudgetReceiver implements RPCIntReceiver implements RPCFloatReceiver implements RPCBoolReceiver implements RPCStringReceiver
		implements RPCInt64Receiver {
	public var told:Int = 0;
	public var int:Int = 0;
	public var float:Float = 1.0;
	public var bool:Bool = false;
	public var string:String = null;
	public var int64:haxe.Int64 = haxe.Int64.make(1, 0);

	public function new() {}

	public function onInt(call:Int, value:Int):Void {
		int = value;
		told++;
	}

	public function onFloat(call:Int, value:Float):Void {
		float = value;
		told++;
	}

	public function onBool(call:Int, value:Bool):Void {
		bool = value;
		told++;
	}

	public function onString(call:Int, value:String):Void {
		string = value;
		told++;
	}

	public function onInt64(call:Int, value:haxe.Int64):Void {
		int64 = value;
		told++;
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		throw "the call failed: " + failure;
	}
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

	@:rpc public function scale(x:Float):Float {
		return x * 1.0001;
	}

	@:rpc public function flip(on:Bool):Bool {
		return !on;
	}

	@:rpc public function greet(id:Int):String {
		return "hello, world";
	}

	var __blob:Null<Bytes> = null;

	@:rpc public function blob(size:Int):Bytes {
		if (__blob == null || __blob.length != size) {
			__blob = Bytes.alloc(size);
		}
		return __blob;
	}

	@:rpc public function count(n:haxe.Int64):haxe.Int64 {
		return n + 1;
	}
}
#end
