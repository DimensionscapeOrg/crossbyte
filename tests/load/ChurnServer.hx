import LoadMain.Args;
import LoadMain.Children;
import LoadStats.Histogram;
import LoadStats.ProcessStats;
import LoadStats.Report;
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.http.Router;
import crossbyte.io.ByteArray;
import crossbyte.net.Certificate;
import crossbyte.net.Key;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;
import haxe.Timer;

/**
	Scenario S: a web server under connection churn.

	HTTP/1.1 with keep-alive and HTTP/2 on one listener, WebSocket on
	another, each again over TLS, four ports, configured as a deployment
	would be, defaults kept but for two: the per-address rate limit is off,
	since every client here is one address, and the access log is quiet
	unless `--access-log`. Clients connect, do a few to a few dozen requests
	or messages, leave politely, and are replaced, at the concurrency the
	plan gives for as long as it gives it.

	```
	LoadMain churn [--plan 50:300,200:300,1000:300,0:120] [--client node|native]
	               [--procs 4] [--think 10] [--tls-share 0.5] [--report 10]
	               [--cert file --key file]
	```

	`--plan` is concurrency:seconds, phase after phase; a last phase at 0
	is the server left idle, to see whether what churn took comes back.
	`--client node` runs `tests/load/churn-client.js` (Node 18 or later),
	whose TLS connections resume their sessions as browsers do; `native`
	runs `LoadMain churn-bots`, CrossByte's own clients, which cannot
	resume and do not speak HTTP/2 over TLS. Natively the certificate is
	made at startup; on another target pass `--cert` and `--key`.

	Per window: what the server holds (open connections by listener, heap,
	resident memory, handles or descriptors, timers, registered sockets) and
	what the clients saw (requests and messages a second, latency, handshakes
	and resumptions, and every error, by reason). Per phase, the same
	summed. After the last phase, memory against the baseline taken before
	the first client: churn that leaves something behind for each connection
	leaves a slope here.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte._internal.socket.NativeSocketRegistry)
class ChurnServer {
	var runtime:CrossByte;
	var args:Args;
	var reportEvery:Float;
	var plan:Array<{concurrency:Int, seconds:Float}> = [];

	var http:HTTPServer;
	var https:HTTPServer;
	var ws:ServerWebSocket;
	var wss:ServerWebSocket;
	var children:Children;

	var requests:Int = 0;
	var wsMessages:Int = 0;
	var accepted:Int = 0;
	var wsOpened:Int = 0;
	var wsClosed:Int = 0;

	var baseline:ProcessStats;
	var started:Float;
	var windowFrom:Float;
	var windowSample:ProcessStats;
	var window:ClientWindow = new ClientWindow();
	var phaseIndex:Int = 0;
	var phaseStart:Float;
	var phaseSample:ProcessStats;
	var phaseTotals:ClientWindow = new ClientWindow();
	var phaseServer:{requests:Float, wsMessages:Float, accepted:Float} = {requests: 0, wsMessages: 0, accepted: 0};
	var phases:Array<Dynamic> = [];
	var errorsSeen:Float = 0;

	var page:String;
	// Where a certificate made at startup was written, removed at the end.
	var certDir:Null<String> = null;

	public function new(runtime:CrossByte, args:Args) {
		this.runtime = runtime;
		this.args = args;
		reportEvery = args.float("report", 10);
		for (part in args.string("plan", "50:300,200:300,1000:300,0:120").split(",")) {
			var pair = part.split(":");
			plan.push({concurrency: Std.parseInt(pair[0]), seconds: Std.parseFloat(pair[1])});
		}
	}

	public function start():Void {
		started = Timer.stamp();
		if (!args.flag("access-log")) {
			crossbyte.utils.Logger.setLevel("http.access", crossbyte.utils.LogLevel.WARN);
		}

		var buf = new StringBuf();
		for (i in 0...8192) {
			buf.addChar(97 + i % 26);
		}
		page = buf.toString();

		var tls = __certificate();
		http = __http(null, null);
		https = __http(tls.certPath, tls.keyPath);
		ws = __ws(false, tls);
		wss = __ws(true, tls);

		runtime.tps = args.int("tps", 60);
		__gc();
		baseline = ProcessStats.sample();
		Report.emit({
			kind: "churn-start",
			ports: {http: http.localPort, https: https.localPort, ws: ws.localPort, wss: wss.localPort},
			plan: args.string("plan", "50:300,200:300,1000:300,0:120"),
			heapLiveMB: ProcessStats.mb(baseline.heapLive),
			rssMB: ProcessStats.mb(baseline.rss),
			handles: baseline.handles
		});

		children = new Children(__onRecord);
		var client:String = args.string("client", Sys.systemName() == "Windows" ? "node" : "native");
		var procs:Int = args.int("procs", 4);
		var common:Array<String> = [
			"--http", Std.string(http.localPort),
			"--https", Std.string(https.localPort),
			"--ws", Std.string(ws.localPort),
			"--wss", Std.string(wss.localPort),
			"--plan", args.string("plan", "50:300,200:300,1000:300,0:120"),
			"--procs", Std.string(procs),
			"--think", Std.string(args.float("think", 10)),
			"--tls-share", Std.string(args.float("tls-share", 0.5)),
			// Every second, whatever the server's window: a client's lines
			// arrive a report late, and a second late is close enough.
			"--report", "1",
			"--kinds", args.string("kinds", "h1,h2,ws")
		];
		if (client == "node") {
			children.spawn("node", "node", [args.string("script", __defaultScript())].concat(common));
		} else {
			for (i in 0...procs) {
				children.spawnSelf("bots" + i, "churn-bots", common.concat(["--worker", Std.string(i)]), args.string("bots", null));
			}
		}

		phaseStart = windowFrom = Timer.stamp();
		phaseSample = windowSample = ProcessStats.sample();
		crossbyte.Timer.setInterval(reportEvery, reportEvery, __report);
		crossbyte.Timer.setInterval(0.25, 0.25, __watchPhase);
	}

	/** `tests/load/churn-client.js`, found from `export/load/` where the build puts this. **/
	static function __defaultScript():String {
		var dir:String = haxe.io.Path.directory(Sys.programPath());
		return haxe.io.Path.normalize(dir + "/../../tests/load/churn-client.js");
	}

	function __certificate():{certPath:String, keyPath:String, cert:Certificate, key:Key} {
		var certPath:String = args.string("cert", null);
		var keyPath:String = args.string("key", null);
		if (certPath == null) {
			#if cpp
			// ECDSA P-256, made here, as WebRTC's are: nothing to install.
			var made = crossbyte.net.rtc.DtlsCertificate.generate("localhost", 2);
			var temp:Null<String> = Sys.getEnv("TEMP");
			if (temp == null) {
				temp = Sys.getEnv("TMPDIR");
			}
			certDir = haxe.io.Path.join([temp != null ? temp : "/tmp", "crossbyte-load-" + Std.random(0x7FFFFFFF)]);
			sys.FileSystem.createDirectory(certDir);
			certPath = certDir + "/cert.pem";
			keyPath = certDir + "/key.pem";
			sys.io.File.saveContent(certPath, made.certificatePem);
			sys.io.File.saveContent(keyPath, made.privateKeyPem);
			#else
			throw "pass --cert and --key: only a native build makes its own";
			#end
		}
		return {
			certPath: certPath,
			keyPath: keyPath,
			cert: Certificate.fromFile(certPath),
			key: Key.fromFile(keyPath)
		};
	}

	function __http(certPath:Null<String>, keyPath:Null<String>):HTTPServer {
		var config = new HTTPServerConfig("127.0.0.1", 0);
		config.http2Enabled = true;
		// One address for every client here; behind a real load balancer
		// the key would be the forwarded client address.
		config.rateLimitKey = _ -> null;
		config.tlsCertificatePath = certPath;
		config.tlsKeyPath = keyPath;
		var router = new Router();
		router.get("/item/:id", ctx -> {
			requests++;
			var id:String = ctx.params.get("id");
			ctx.handler.respond(200, "application/json",
				'{"id":"$id","name":"item $id","price":${id.length * 7 + 3},"tags":["load","churn","crossbyte"],"stock":${id.length * 11},"description":"An item served to a client that will leave shortly, as most of them do."}');
		});
		router.post("/echo", ctx -> {
			requests++;
			ctx.handler.respondBytes(200, "application/octet-stream", ctx.handler.requestBody);
		});
		router.get("/page", ctx -> {
			requests++;
			ctx.handler.respond(200, "text/plain", page);
		});
		config.middleware.push(router.middleware());
		var server = new HTTPServer(config);
		server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> accepted++);
		return server;
	}

	function __ws(secure:Bool, tls:{certPath:String, keyPath:String, cert:Certificate, key:Key}):ServerWebSocket {
		var server = new ServerWebSocket(secure);
		if (secure) {
			server.setCertificate(tls.cert, tls.key);
		}
		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			var socket:WebSocket = cast event.socket;
			accepted++;
			wsOpened++;
			socket.addEventListener(WebSocketMessageEvent.MESSAGE, (e:WebSocketMessageEvent) -> {
				wsMessages++;
				socket.sendBinary(e.data, 0, e.data.length);
			});
			socket.addEventListener(Event.CLOSE, _ -> wsClosed++);
		});
		server.bind(0, "127.0.0.1");
		server.listen(1024);
		return server;
	}

	function __onRecord(record:Dynamic):Void {
		if (record.kind == "churn-clients") {
			window.add(record);
		}
	}

	function __watchPhase():Void {
		if (phaseIndex >= plan.length) {
			return;
		}
		var now:Float = Timer.stamp();
		if (now - phaseStart < plan[phaseIndex].seconds) {
			return;
		}
		__report();
		var sample:ProcessStats = ProcessStats.sample();
		var wall:Float = now - phaseStart;
		var cpu:Float = (sample.cpu - phaseSample.cpu);
		var record:Dynamic = {
			kind: "churn-phase",
			phase: phaseIndex,
			concurrency: plan[phaseIndex].concurrency,
			seconds: round(wall),
			cpuCores: round(cpu / wall),
			kernelShare: round((sample.kernel - phaseSample.kernel) / Math.max(1e-9, (sample.user - phaseSample.user) + (sample.kernel - phaseSample.kernel))),
			serverRequestsPerSecond: Math.round(phaseServer.requests / wall),
			serverWsMessagesPerSecond: Math.round(phaseServer.wsMessages / wall),
			acceptedPerSecond: round(phaseServer.accepted / wall),
			cpuUsPerRequest: round(cpu * 1e6 / Math.max(1, phaseServer.requests + phaseServer.wsMessages)),
			clients: phaseTotals.toRecord(wall),
			heapLiveMB: ProcessStats.mb(sample.heapLive),
			rssMB: ProcessStats.mb(sample.rss),
			privateMB: ProcessStats.mb(sample.privateBytes),
			handles: sample.handles
		};
		phases.push(record);
		Report.emit(record);
		phaseIndex++;
		phaseStart = now;
		phaseSample = sample;
		phaseTotals = new ClientWindow();
		phaseServer = {requests: 0, wsMessages: 0, accepted: 0};
		if (phaseIndex >= plan.length) {
			crossbyte.Timer.setTimeout(1.0, __finish);
		}
	}

	function __report():Void {
		var now:Float = Timer.stamp();
		var wall:Float = now - windowFrom;
		if (wall < 0.5) {
			return;
		}
		var sample:ProcessStats = ProcessStats.sample();
		var cpu:Float = (sample.cpu - windowSample.cpu);
		var clients:Dynamic = window.toRecord(wall);
		errorsSeen += window.errorCount();
		Report.emit({
			kind: "churn-window",
			t: round(now - started),
			phase: phaseIndex,
			concurrency: phaseIndex < plan.length ? plan[phaseIndex].concurrency : 0,
			cpuCores: round(cpu / wall),
			kernelShare: round((sample.kernel - windowSample.kernel) / Math.max(1e-9, (sample.user - windowSample.user) + (sample.kernel - windowSample.kernel))),
			serverRequestsPerSecond: Math.round(requests / wall),
			serverWsMessagesPerSecond: Math.round(wsMessages / wall),
			acceptedPerSecond: round(accepted / wall),
			open: {
				http: http.activeConnections,
				https: https.activeConnections,
				ws: ws.clientCount,
				wss: wss.clientCount
			},
			wsOpened: wsOpened,
			wsClosed: wsClosed,
			clients: clients,
			heapLiveMB: ProcessStats.mb(sample.heapLive),
			heapNowMB: ProcessStats.mb(sample.heapNow),
			heapReservedMB: ProcessStats.mb(sample.heapReserved),
			rssMB: ProcessStats.mb(sample.rss),
			privateMB: ProcessStats.mb(sample.privateBytes),
			handles: sample.handles,
			timers: runtime.__timer.size,
			registered: __registered()
		});
		phaseTotals.merge(window);
		phaseServer.requests += requests;
		phaseServer.wsMessages += wsMessages;
		phaseServer.accepted += accepted;
		requests = 0;
		wsMessages = 0;
		accepted = 0;
		window = new ClientWindow();
		windowFrom = now;
		windowSample = sample;
	}

	function __registered():Int {
		#if cpp
		try {
			return runtime.__socketRegistry.__set.length;
		} catch (_:Dynamic) {}
		#end
		return -1;
	}

	function __finish():Void {
		// What the clients sent after their last window, then a full
		// collection, and the server held against where it began.
		var giveUpAt:Float = Timer.stamp() + 30;
		var watch:Int = -1;
		watch = crossbyte.Timer.setInterval(0.5, 0.5, () -> {
			if (children.running > 0 && Timer.stamp() < giveUpAt) {
				return;
			}
			crossbyte.Timer.clear(watch);
			__report();
			__gc();
			var after:ProcessStats = ProcessStats.sample();
			var clean:Bool = children.failed == 0 && errorsSeen == 0;
			Report.emit({
				kind: "churn-summary",
				phases: phases,
				errorsSeen: errorsSeen,
				open: {
					http: http.activeConnections,
					https: https.activeConnections,
					ws: ws.clientCount,
					wss: wss.clientCount
				},
				heapLiveMB: ProcessStats.mb(after.heapLive),
				heapReservedMB: ProcessStats.mb(after.heapReserved),
				baselineHeapLiveMB: ProcessStats.mb(baseline.heapLive),
				rssMB: ProcessStats.mb(after.rss),
				baselineRssMB: ProcessStats.mb(baseline.rss),
				privateMB: ProcessStats.mb(after.privateBytes),
				baselinePrivateMB: ProcessStats.mb(baseline.privateBytes),
				handles: after.handles,
				baselineHandles: baseline.handles,
				timers: runtime.__timer.size,
				registered: __registered(),
				childFailures: children.failed,
				clean: clean
			});
			children.killAll();
			if (certDir != null) {
				for (name in ["cert.pem", "key.pem"]) {
					try sys.FileSystem.deleteFile(certDir + "/" + name) catch (_:Dynamic) {}
				}
				try sys.FileSystem.deleteDirectory(certDir) catch (_:Dynamic) {}
			}
			Sys.exit(clean ? 0 : 1);
		});
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
	What the churn clients reported in one window, summed: counts by name,
	and a latency histogram for each kind of exchange.
**/
class ClientWindow {
	var counts:Map<String, Float> = new Map();
	var errors:Map<String, Float> = new Map();
	var latency:Map<String, Histogram> = new Map();
	var concurrency:Float = 0;
	var cpu:Float = 0;

	public function new() {}

	public function add(record:Dynamic):Void {
		var c:Dynamic = record.counts;
		if (c != null) {
			for (name in Reflect.fields(c)) {
				counts.set(name, (counts.exists(name) ? counts.get(name) : 0) + Reflect.field(c, name));
			}
		}
		var e:Dynamic = record.errors;
		if (e != null) {
			for (name in Reflect.fields(e)) {
				errors.set(name, (errors.exists(name) ? errors.get(name) : 0) + Reflect.field(e, name));
			}
		}
		var l:Dynamic = record.latency;
		if (l != null) {
			for (name in Reflect.fields(l)) {
				var h:Histogram = latency.exists(name) ? latency.get(name) : new Histogram();
				h.merge(Histogram.decode(Reflect.field(l, name)));
				latency.set(name, h);
			}
		}
		if (record.concurrency != null) {
			concurrency += record.concurrency;
		}
		if (record.cpu != null) {
			cpu += record.cpu;
		}
	}

	public function merge(other:ClientWindow):Void {
		for (name => n in other.counts) {
			counts.set(name, (counts.exists(name) ? counts.get(name) : 0) + n);
		}
		for (name => n in other.errors) {
			errors.set(name, (errors.exists(name) ? errors.get(name) : 0) + n);
		}
		for (name => h in other.latency) {
			var mine:Histogram = latency.exists(name) ? latency.get(name) : new Histogram();
			mine.merge(h);
			latency.set(name, mine);
		}
		concurrency = other.concurrency;
		cpu += other.cpu;
	}

	public function errorCount():Float {
		var n:Float = 0;
		for (value in errors) {
			n += value;
		}
		return n;
	}

	public function toRecord(wall:Float):Dynamic {
		var perSecond:Dynamic = {};
		for (name => n in counts) {
			Reflect.setField(perSecond, name, Math.round(n / wall * 10) / 10);
		}
		var totals:Dynamic = {};
		for (name => n in counts) {
			Reflect.setField(totals, name, n);
		}
		var errorRecord:Dynamic = {};
		for (name => n in errors) {
			Reflect.setField(errorRecord, name, n);
		}
		var latencyRecord:Dynamic = {};
		for (name => h in latency) {
			Reflect.setField(latencyRecord, name, h.summary());
		}
		return {
			concurrency: concurrency,
			perSecond: perSecond,
			totals: totals,
			errors: errorRecord,
			latency: latencyRecord,
			cpuCores: Math.round(cpu / wall * 1000) / 1000
		};
	}
}
