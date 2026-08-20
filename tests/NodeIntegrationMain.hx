import crossbyte.core.Application;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.NativeProcessEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import crossbyte.sys.NativeProcess;
import crossbyte.sys.NativeProcessStartupInfo;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;

/**
	The parts of CrossByte that only exist on Node, exercised against Node.

	`JsTestMain` deliberately holds nothing needing a socket, a subprocess or a
	runtime driving itself -- it is the portable suite, and it has to mean the
	same thing on the browser build. Everything written for Node specifically
	therefore had no home: the self-driven loop, sockets over `js.node.net`,
	`URLLoader` over Node's HTTP client, `NativeProcess` over `child_process`.

	This is the same work a utest case would do, written as a program instead.
	The things it covers are asynchronous, and one of them owns the process: a
	loop that drives itself cannot be tested from inside a harness that is
	already driving a runtime of its own.

	Exits non-zero if anything fails, so CI notices.
**/
class NodeIntegrationMain extends Application {
	private static inline var HTTP_PORT:Int = 50561;
	private static inline var ECHO_PORT:Int = 50562;
	private static inline var TIMEOUT_MS:Int = 30000;
	private static inline var ROUND_TRIP:String = "round-trip";

	private static var failures:Int = 0;
	private static var checks:Int = 0;

	private var ticks:Int = 0;
	private var tickDeltas:Array<Float> = [];
	private var timerFired:Bool = false;
	private var loopStarted:Float;

	private var httpServer:js.node.http.Server;
	private var echoServer:js.node.net.Server;
	private var listener:ServerSocket;
	private var accepted:Socket;

	public function new() {
		super();
		addEventListener(Event.INIT, onInit);
	}

	private function onInit(event:Event):Void {
		// A ceiling on the whole run. Every stage below waits on something, and
		// one that never completes would otherwise leave CI holding an idle
		// Node process instead of reporting a failure.
		//
		// Unreferenced, because an armed timer is itself a reason for Node to
		// stay alive -- with this one referenced the process sat here for the
		// full thirty seconds after passing, and the guard reported a timeout
		// on a run that had already finished.
		var guard = js.Node.setTimeout(function():Void {
			Sys.println("TIMED OUT after " + TIMEOUT_MS + "ms with " + checks + " checks done");
			Sys.exit(1);
		}, TIMEOUT_MS);
		untyped guard.unref();

		check("Event.INIT reached the application", true, "");

		crossByte.tps = 60;
		loopStarted = haxe.Timer.stamp();
		crossByte.addEventListener(TickEvent.TICK, onTick);
		haxe.Timer.delay(function():Void {
			timerFired = true;
		}, 50);
	}

	// ---- 1. the self-driven loop -----------------------------------------

	private function onTick(event:TickEvent):Void {
		ticks++;
		tickDeltas.push(event.delta);

		if (ticks < 30) {
			return;
		}

		crossByte.removeEventListener(TickEvent.TICK, onTick);

		var elapsed:Float = haxe.Timer.stamp() - loopStarted;
		var mean:Float = 0;
		for (delta in tickDeltas) {
			mean += delta;
		}
		mean /= tickDeltas.length;

		check("the loop ran with nobody pumping it", ticks == 30, "got " + ticks + " ticks");
		check("haxe.Timer fired off those ticks", timerFired, "the timer never ran");
		check("uptime advanced", crossByte.uptime > 0.2, "uptime " + crossByte.uptime);
		// 30 ticks at 60/s is half a second. The bounds are wide because what
		// is under test is that a configured rate was honoured at all, not how
		// tightly Node's timers hold it.
		check("tps was honoured", elapsed > 0.3 && elapsed < 2.0, "30 ticks at tps=60 took " + elapsed + "s");
		check("tick deltas are real", mean > 0.004 && mean < 0.1, "mean delta " + mean);
		check("stamp() is not a constant", haxe.Timer.stamp() > 0, "stamp " + haxe.Timer.stamp());

		startHttpServer();
	}

	// ---- 2. URLLoader over Node's HTTP client ----------------------------

	private function startHttpServer():Void {
		httpServer = js.node.Http.createServer(function(request, response):Void {
			var body:String = "";

			request.on("data", function(chunk):Void {
				body += Std.string(chunk);
			});

			request.on("end", function():Void {
				response.writeHead(200, {"Content-Type": "text/plain"});
				response.end(request.method == "POST" ? "echo:" + body : "crossbyte-over-node");
			});
		});

		httpServer.listen(HTTP_PORT, "127.0.0.1", function():Void {
			getRequest();
		});
	}

	private function getRequest():Void {
		var loader = new URLLoader();
		var sawProgress:Bool = false;
		var status:Int = -1;

		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, function(e:HTTPStatusEvent):Void {
			status = e.status;
		});

		loader.addEventListener(ProgressEvent.PROGRESS, function(_):Void {
			sawProgress = true;
		});

		loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("URLLoader GET succeeded", false, "io error: " + e.text);
			postRequest();
		});

		loader.addEventListener(Event.COMPLETE, function(_):Void {
			check("URLLoader GET returned the body", Std.string(loader.data).indexOf("crossbyte-over-node") >= 0, "got " + loader.data);
			check("URLLoader GET reported 200", status == 200, "status " + status);
			check("URLLoader GET reported progress", sawProgress, "no progress event");
			postRequest();
		});

		loader.load(new URLRequest("http://127.0.0.1:" + HTTP_PORT + "/hello"));
	}

	private function postRequest():Void {
		var loader = new URLLoader();

		loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("URLLoader POST succeeded", false, "io error: " + e.text);
			startEchoServer();
		});

		loader.addEventListener(Event.COMPLETE, function(_):Void {
			check("URLLoader POST sent its body", Std.string(loader.data) == "echo:payload-42", "got " + loader.data);
			httpServer.close();
			startEchoServer();
		});

		var request = new URLRequest("http://127.0.0.1:" + HTTP_PORT + "/echo");
		request.method = "POST";
		request.data = "payload-42";
		loader.load(request);
	}

	// ---- 3. crossbyte.net.Socket over js.node.net ------------------------

	private function startEchoServer():Void {
		echoServer = js.node.Net.createServer(function(connection):Void {
			connection.on("data", function(chunk):Void {
				connection.write(chunk);
			});
		});

		echoServer.listen(ECHO_PORT, "127.0.0.1", function():Void {
			connectSocket();
		});
	}

	private function connectSocket():Void {
		var socket = new Socket();
		var connected:Bool = false;

		socket.addEventListener(Event.CONNECT, function(_):Void {
			connected = true;
			socket.writeUTFBytes(ROUND_TRIP);
			socket.flush();
		});

		socket.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("Socket connected", false, "io error: " + e.text);
			runSubprocess();
		});

		socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			if (socket.bytesAvailable < ROUND_TRIP.length) {
				return;
			}

			var received = socket.readUTFBytes(ROUND_TRIP.length);
			check("Socket connected", connected, "no connect event");
			check("Socket round-tripped its bytes", received == ROUND_TRIP, "got " + received);
			check("Socket knows its remote end", socket.remoteAddress == "127.0.0.1", "got " + socket.remoteAddress);
			check("Socket knows its remote port", socket.remotePort == ECHO_PORT, "got " + socket.remotePort);
			check("Socket knows its local port", socket.localPort > 0, "got " + socket.localPort);
			socket.close();
			echoServer.close();
			startListener();
		});

		socket.connect("127.0.0.1", ECHO_PORT);
	}

	// ---- 4. crossbyte.net.ServerSocket over js.node.net.Server -----------

	private function startListener():Void {
		listener = new ServerSocket();

		check("ServerSocket is supported on Node", ServerSocket.isSupported, "reported unsupported");

		var refusedSecure:String = null;

		try {
			new ServerSocket(true);
		} catch (e:Dynamic) {
			refusedSecure = Std.string(e);
		}

		check("a secure ServerSocket refuses on Node", refusedSecure != null && refusedSecure.indexOf("sys.ssl") >= 0,
			refusedSecure == null ? "it did not refuse" : refusedSecure);

		listener.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			// Held in a field on purpose: the class documents that the
			// application owns the accepted socket, and one only referenced by
			// a local would be collectable the moment this returns.
			accepted = e.socket;

			check("ServerSocket accepted a connection", accepted != null, "no socket on the event");
			check("accepted socket knows its peer", accepted.remoteAddress == "127.0.0.1", "got " + accepted.remoteAddress);

			accepted.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				if (accepted.bytesAvailable < ROUND_TRIP.length) {
					return;
				}

				var request = accepted.readUTFBytes(ROUND_TRIP.length);
				check("ServerSocket read the client bytes", request == ROUND_TRIP, "got " + request);
				accepted.writeUTFBytes(request.toUpperCase());
				accepted.flush();
			});
		});

		// Port 0, so the run cannot collide with whatever else is on the
		// machine -- and so that resolving the assigned port is covered.
		listener.bind(0, "127.0.0.1");
		listener.listen();

		check("bind() marked the server bound", listener.bound, "not bound");
		check("listen() marked the server listening", listener.listening, "not listening");

		// listen() on Node claims the port asynchronously, so the assigned
		// port is not readable until it has. A tick is the runtime's own way
		// of waiting, and the loop is already running.
		waitForPort(0);
	}

	private function waitForPort(attempts:Int):Void {
		if (listener.localPort > 0) {
			check("port 0 resolved to a real port", listener.localPort > 0, "got " + listener.localPort);
			connectToListener();
			return;
		}

		if (attempts > 200) {
			check("port 0 resolved to a real port", false, "still 0 after " + attempts + " ticks");
			finishListener();
			return;
		}

		haxe.Timer.delay(function():Void {
			waitForPort(attempts + 1);
		}, 5);
	}

	private function connectToListener():Void {
		var client = new Socket();

		client.addEventListener(Event.CONNECT, function(_):Void {
			client.writeUTFBytes(ROUND_TRIP);
			client.flush();
		});

		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("client reached the ServerSocket", false, "io error: " + e.text);
			finishListener();
		});

		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			if (client.bytesAvailable < ROUND_TRIP.length) {
				return;
			}

			var reply = client.readUTFBytes(ROUND_TRIP.length);
			check("ServerSocket replied through the accepted socket", reply == ROUND_TRIP.toUpperCase(), "got " + reply);
			client.close();
			finishListener();
		});

		client.connect("127.0.0.1", listener.localPort);
	}

	private function finishListener():Void {
		if (accepted != null) {
			accepted.close();
		}

		listener.close();
		check("close() stopped the server listening", !listener.listening, "still listening");
		runSubprocess();
	}

	// ---- 5. NativeProcess over child_process -----------------------------

	private function runSubprocess():Void {
		var process = new NativeProcess();
		var out:String = "";
		var err:String = "";
		var outClosed:Bool = false;
		var errClosed:Bool = false;

		process.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, function(e:NativeProcessEvent):Void {
			out += e.text;
		});

		process.addEventListener(NativeProcessEvent.STANDARD_ERROR_DATA, function(e:NativeProcessEvent):Void {
			err += e.text;
		});

		process.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_CLOSE, function(_):Void {
			outClosed = true;
		});

		process.addEventListener(NativeProcessEvent.STANDARD_ERROR_CLOSE, function(_):Void {
			errClosed = true;
		});

		process.addEventListener(NativeProcessEvent.EXIT, function(e:NativeProcessEvent):Void {
			check("NativeProcess read stdout", out.indexOf("child-stdout") >= 0, "got " + out);
			check("NativeProcess read stderr", err.indexOf("child-stderr") >= 0, "got " + err);
			check("NativeProcess closed both streams", outClosed && errClosed, "stdout " + outClosed + ", stderr " + errClosed);
			check("NativeProcess reported the exit code", e.exitCode == 7, "got " + e.exitCode);
			check("NativeProcess reported a pid", e.pid > 0, "got " + e.pid);
			feedSubprocess();
		});

		process.start(new NativeProcessStartupInfo("node", ["-e", childScript()]));

		check("NativeProcess is supported on Node", NativeProcess.isSupported, "reported unsupported");
	}

	private function feedSubprocess():Void {
		var process = new NativeProcess();
		var out:String = "";

		process.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, function(e:NativeProcessEvent):Void {
			out += e.text;
		});

		process.addEventListener(NativeProcessEvent.EXIT, function(_):Void {
			check("NativeProcess wrote to stdin", out.indexOf("[through-stdin]") >= 0, "got " + out);
			report();
		});

		process.start(new NativeProcessStartupInfo("node", ["-e", echoStdinScript()]));

		var input = process.standardInput;
		check("NativeProcess handed out an stdin writer", input != null, "standardInput was null");

		if (input != null) {
			input.writeString("through-");
			// Offset and length both non-trivial, so a writeBytes that ignores
			// them would put the wrong text through the pipe rather than none.
			input.writeBytes(haxe.io.Bytes.ofString("xxstdinyy"), 2, 5);
		}

		process.closeInput();
	}

	// Built rather than written out, because a quote inside a -e argument is
	// where a shell, a Haxe string and Node's parser each want a turn.
	private static function childScript():String {
		var q = String.fromCharCode(39);
		return "process.stdout.write(" + q + "child-stdout" + q + ");" + "process.stderr.write(" + q + "child-stderr" + q + ");" + "process.exit(7)";
	}

	private static function echoStdinScript():String {
		var q = String.fromCharCode(39);
		return "let b=" + q + q + ";" + "process.stdin.on(" + q + "data" + q + ",c=>b+=c);" + "process.stdin.on(" + q + "end" + q + ",()=>process.stdout.write("
			+ q + "[" + q + "+b+" + q + "]" + q + "))";
	}

	// ---- reporting --------------------------------------------------------

	private function report():Void {
		Sys.println(failures == 0 ? "ALL PASS (" + checks + " checks)" : failures + " of " + checks + " FAILED");
		js.Node.process.exitCode = failures == 0 ? 0 : 1;
		// Through the runtime rather than Sys.exit, so that stopping a
		// self-driven loop is itself covered: nothing stays scheduled
		// afterwards, and Node returns on its own.
		crossByte.exit();
	}

	private static function check(what:String, ok:Bool, detail:String):Void {
		checks++;
		Sys.println((ok ? "  PASS  " : "  FAIL  ") + what + (ok ? "" : " -- " + detail));

		if (!ok) {
			failures++;
		}
	}

	public static function main():Void {
		new NodeIntegrationMain();
	}
}
