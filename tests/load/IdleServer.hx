import LoadMain.Args;
import LoadMain.Children;
import LoadStats.ProcessStats;
import LoadStats.Report;
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;
import haxe.Timer;

/**
	Scenario I: many WebSocket connections, open and quiet -- a chat server
	at three in the morning, or a game lobby between matches -- with the
	default heartbeat, a ping each way after thirty seconds of silence.

	```
	LoadMain idle --clients 10000 --seconds 120 [--procs 4] [--rate 500]
	              [--settle 10] [--report 10] [--libuv]
	```

	The server alone, after a full collection; the clients connected, at
	`--rate` a second per process so the listen backlog is not what is
	measured; `--settle` seconds for the accepting to stop costing anything;
	a full collection, which against the first gives memory per connection;
	then `--seconds` of nothing, in which what the process uses of a core is
	what holding the connections costs. `--libuv` installs the
	crossbyte-libuv backend, in a build made with it (README).
**/
@:access(crossbyte.core.CrossByte)
class IdleServer {
	var runtime:CrossByte;
	var args:Args;
	var clients:Int;
	var seconds:Float;
	var settle:Float;
	var reportEvery:Float;

	var server:ServerWebSocket;
	var children:Children;
	var accepted:Int = 0;
	var closed:Int = 0;
	var clientErrors:Float = 0;
	var clientClosedEarly:Float = 0;
	var baseline:ProcessStats;
	var steady:ProcessStats;
	var started:Float;
	var measuring:Bool = false;
	var windowFrom:Float;
	var windowSample:ProcessStats;
	var runFrom:Float;
	var runSample:ProcessStats;
	var connectedAt:Float = 0;

	public function new(runtime:CrossByte, args:Args) {
		this.runtime = runtime;
		this.args = args;
		clients = args.int("clients", 10000);
		seconds = args.float("seconds", 60);
		settle = args.float("settle", 10);
		reportEvery = args.float("report", 10);
	}

	public function start():Void {
		started = Timer.stamp();
		runtime.tps = args.int("tps", 12);
		server = new ServerWebSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			var socket:WebSocket = cast event.socket;
			accepted++;
			socket.addEventListener(Event.CLOSE, _ -> closed++);
		});
		server.bind(0, "127.0.0.1");
		server.listen(4096);

		__gc();
		baseline = ProcessStats.sample();
		var backend:String = "built-in";
		#if crossbyte_libuv_native
		if (args.flag("libuv")) {
			backend = "libuv";
		}
		#end
		Report.emit({
			kind: "idle-start",
			port: server.localPort,
			clients: clients,
			backend: backend,
			heapLiveMB: ProcessStats.mb(baseline.heapLive),
			rssMB: ProcessStats.mb(baseline.rss),
			handles: baseline.handles
		});

		children = new Children(__onRecord);
		var procs:Int = args.int("procs", Std.int(Math.max(1, Math.ceil(clients / 2500))));
		var rate:Int = args.int("rate", 500);
		var hold:Float = clients / (rate * procs) + 30 + settle + seconds + 10;
		for (i in 0...procs) {
			var share:Int = Std.int(clients / procs) + (i < clients % procs ? 1 : 0);
			children.spawnSelf("idle" + i, "idle-bots", [
				"--port", Std.string(server.localPort),
				"--count", Std.string(share),
				"--rate", Std.string(rate),
				"--seconds", Std.string(hold),
				"--report", Std.string(reportEvery)
			], args.string("bots", null));
		}

		var giveUpAt:Float = Timer.stamp() + 30 + clients / (rate * procs) * 2;
		var waiting:Int = -1;
		waiting = crossbyte.Timer.setInterval(0.25, 0.25, () -> {
			if (server.clientCount < clients && Timer.stamp() < giveUpAt) {
				return;
			}
			crossbyte.Timer.clear(waiting);
			connectedAt = Timer.stamp();
			Report.emit({kind: "idle-connected", open: server.clientCount, of: clients, seconds: round(connectedAt - started)});
			crossbyte.Timer.setTimeout(settle, __beginMeasuring);
		});
	}

	function __beginMeasuring():Void {
		__gc();
		steady = ProcessStats.sample();
		var n:Int = server.clientCount > 0 ? server.clientCount : 1;
		Report.emit({
			kind: "idle-steady",
			open: server.clientCount,
			heapLiveMB: ProcessStats.mb(steady.heapLive),
			rssMB: ProcessStats.mb(steady.rss),
			privateMB: ProcessStats.mb(steady.privateBytes),
			handles: steady.handles,
			heapPerConnectionKB: Math.round((steady.heapLive - baseline.heapLive) / n / 102.4) / 10,
			rssPerConnectionKB: Math.round((steady.rss - baseline.rss) / n / 102.4) / 10,
			privatePerConnectionKB: Math.round((steady.privateBytes - baseline.privateBytes) / n / 102.4) / 10
		});
		measuring = true;
		runFrom = windowFrom = Timer.stamp();
		runSample = windowSample = ProcessStats.sample();
		crossbyte.Timer.setInterval(reportEvery, reportEvery, __report);
		crossbyte.Timer.setTimeout(seconds, __end);
	}

	function __report():Void {
		if (!measuring) {
			return;
		}
		var now:Float = Timer.stamp();
		var sample = ProcessStats.sample();
		var wall:Float = now - windowFrom;
		var cpu:Float = (sample.user - windowSample.user) + (sample.kernel - windowSample.kernel);
		Report.emit({
			kind: "idle-window",
			t: round(now - runFrom),
			open: server.clientCount,
			corePercent: round(cpu / wall * 100),
			kernelShare: round((sample.kernel - windowSample.kernel) / Math.max(1e-9, cpu)),
			heapLiveMB: ProcessStats.mb(sample.heapLive),
			heapNowMB: ProcessStats.mb(sample.heapNow),
			heapReservedMB: ProcessStats.mb(sample.heapReserved),
			rssMB: ProcessStats.mb(sample.rss),
			privateMB: ProcessStats.mb(sample.privateBytes),
			handles: sample.handles,
			timers: runtime.__timer.size
		});
		windowFrom = now;
		windowSample = sample;
	}

	function __end():Void {
		__report();
		measuring = false;
		var end = ProcessStats.sample();
		var wall:Float = Timer.stamp() - runFrom;
		var cpu:Float = (end.user - runSample.user) + (end.kernel - runSample.kernel);
		var n:Int = steady == null ? 1 : Std.int(Math.max(1, server.clientCount));
		Report.emit({
			kind: "idle-summary",
			clients: clients,
			open: server.clientCount,
			seconds: round(wall),
			corePercent: round(cpu / wall * 100),
			userPercent: round((end.user - runSample.user) / wall * 100),
			kernelPercent: round((end.kernel - runSample.kernel) / wall * 100),
			cpuUsPerConnectionSecond: round(cpu * 1e6 / wall / n),
			heapPerConnectionKB: Math.round((steady.heapLive - baseline.heapLive) / n / 102.4) / 10,
			rssPerConnectionKB: Math.round((steady.rss - baseline.rss) / n / 102.4) / 10,
			privatePerConnectionKB: Math.round((steady.privateBytes - baseline.privateBytes) / n / 102.4) / 10,
			handlesPerConnection: round((steady.handles - baseline.handles) / n),
			clientErrors: clientErrors,
			clientClosedEarly: clientClosedEarly,
			serverClosedDuring: closed
		});

		var giveUpAt:Float = Timer.stamp() + 120;
		var watch:Int = -1;
		watch = crossbyte.Timer.setInterval(0.5, 0.5, () -> {
			if ((server.clientCount > 0 || children.running > 0) && Timer.stamp() < giveUpAt) {
				return;
			}
			crossbyte.Timer.clear(watch);
			crossbyte.Timer.setTimeout(2.0, () -> {
				__gc();
				var after = ProcessStats.sample();
				var clean:Bool = children.failed == 0 && clientErrors == 0 && clientClosedEarly == 0;
				Report.emit({
					kind: "idle-after",
					open: server.clientCount,
					heapLiveMB: ProcessStats.mb(after.heapLive),
					baselineHeapLiveMB: ProcessStats.mb(baseline.heapLive),
					rssMB: ProcessStats.mb(after.rss),
					baselineRssMB: ProcessStats.mb(baseline.rss),
					handles: after.handles,
					baselineHandles: baseline.handles,
					timers: runtime.__timer.size,
					clean: clean
				});
				children.killAll();
				Sys.exit(clean ? 0 : 1);
			});
		});
	}

	function __onRecord(record:Dynamic):Void {
		if (record.kind == "idle-bots") {
			clientErrors += record.errors;
			clientClosedEarly += record.closedEarly;
		}
	}

	static inline function round(value:Float):Float {
		return Math.round(value * 1000) / 1000;
	}

	static function __gc():Void {
		#if cpp
		cpp.vm.Gc.run(true);
		#elseif (java || jvm)
		java.lang.System.gc();
		#end
	}
}

/**
	Idle WebSocket clients for scenario I: `--count` connections opened at
	`--rate` a second, held without a word for `--seconds` -- the heartbeat
	aside, which the sessions answer themselves -- then closed.
**/
class IdleBots {
	var runtime:CrossByte;
	var args:Args;
	var sockets:Array<WebSocket> = [];
	var open:Int = 0;
	var errors:Int = 0;
	var closedEarly:Int = 0;
	var closing:Bool = false;

	public function new(runtime:CrossByte, args:Args) {
		this.runtime = runtime;
		this.args = args;
	}

	public function start():Void {
		var host:String = args.string("host", "127.0.0.1");
		var port:Int = args.int("port", 0);
		var count:Int = args.int("count", 1000);
		var rate:Int = args.int("rate", 500);
		var seconds:Float = args.float("seconds", 60);
		var reportEvery:Float = args.float("report", 10);
		runtime.tps = 20;

		var started:Int = 0;
		var perStep:Int = Std.int(Math.max(1, rate / 20));
		var opener:Int = -1;
		opener = crossbyte.Timer.setInterval(0.0, 0.05, () -> {
			for (_ in 0...perStep) {
				if (started >= count) {
					crossbyte.Timer.clear(opener);
					return;
				}
				started++;
				var socket = new WebSocket();
				var wasOpen:Bool = false;
				socket.addEventListener(Event.CONNECT, _ -> {
					wasOpen = true;
					open++;
				});
				socket.addEventListener(crossbyte.events.IOErrorEvent.IO_ERROR, e -> {
					if (!closing) {
						errors++;
						if (errors <= 3) {
							Report.say("idle client: " + e.text);
						}
					}
				});
				socket.addEventListener(Event.CLOSE, _ -> {
					if (wasOpen) {
						open--;
					}
					if (!closing) {
						closedEarly++;
					}
				});
				sockets.push(socket);
				try {
					socket.connect(host, port);
				} catch (error:Dynamic) {
					errors++;
				}
			}
		});

		crossbyte.Timer.setInterval(reportEvery, reportEvery, () -> {
			Report.emit({kind: "idle-bots", open: open, errors: errors, closedEarly: closedEarly});
			errors = 0;
			closedEarly = 0;
		});

		crossbyte.Timer.setTimeout(seconds, () -> {
			Report.emit({kind: "idle-bots", open: open, errors: errors, closedEarly: closedEarly});
			errors = 0;
			closedEarly = 0;
			closing = true;
			for (socket in sockets) {
				try {
					if (socket.connected) {
						socket.closeWith(1000);
					}
				} catch (_:Dynamic) {}
			}
			var giveUpAt:Float = Timer.stamp() + 20;
			var watch:Int = -1;
			watch = crossbyte.Timer.setInterval(0.1, 0.1, () -> {
				if (open > 0 && Timer.stamp() < giveUpAt) {
					return;
				}
				crossbyte.Timer.clear(watch);
				Sys.exit(0);
			});
		});
	}
}
