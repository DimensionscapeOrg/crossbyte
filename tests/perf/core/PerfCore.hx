import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.events.TaskEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import crossbyte.sys.TaskPool;
import haxe.Timer;

/**
	The core area's performance-pattern measurements, driven through the real
	paths: a runtime's tick with its listeners, sockets over loopback in one
	host-driven runtime, the timer scheduler, the task pool.

	Run one scenario per process, so a scenario's garbage and warmed caches
	do not leak into the next:

	```
	PerfCore <scenario> <param> [seconds]
	```

	Each prints `RESULT <scenario> <param> <metric>=<value> ...`. CPU time is
	the process's, every thread's: Sys.cpuTime natively, the OS MXBean on the
	jvm, process.cpuUsage() on Node; not the wall, since a blocked poll is
	not work. Windows' process clock ticks every 15.6 ms, so every scenario
	runs for seconds, not milliseconds.

	A/B, a commit before against this tree: export the commit's src with
	`git archive <commit> src | tar -x -C export/baseline`, then
	`build.hxml` builds it as A and `build-b.hxml` builds `src` as B (and
	`build-jvm.hxml`, `build-node.hxml` both). `run.ps1` runs them
	interleaved, each process pinned to CPUs 24-31. B alone is a benchmark
	of the tree as it is.

	Scenarios: tick, scanmap, scanarr, echo, echo3, idle, blocked, udp,
	fdisset, fdwalk, timerfire, timerfireint, timerreset, tasks, post,
	worker, workerbacklog, mutex, mutexnew, locknew, tasknew, switchtable,
	switchtyped, vectorforeach, vectorloop, logtext, logjson, logoff, throw,
	jsonread, jsonshaped (B only), mtime. Each is described where it is
	written below.
**/
@:access(crossbyte.core.CrossByte)
class PerfCore {
	static var sink:Int = 0;

	static function main():Void {
		var args = Sys.args();
		var scenario = args.length > 0 ? args[0] : "tick";
		var param = args.length > 1 ? Std.parseInt(args[1]) : 1000;
		var seconds = args.length > 2 ? Std.parseFloat(args[2]) : 3.0;

		// Host-driven and primordial, as BenchMain's: this thread pumps it.
		var runtime = new CrossByte(true, DEFAULT, true);

		switch (scenario) {
			case "tick":
				tick(runtime, param, seconds);
			case "scanmap":
				scan(runtime, param, seconds, true);
			case "scanarr":
				scan(runtime, param, seconds, false);
			case "echo":
				echo(runtime, param, seconds, 1);
			case "echo3":
				echo(runtime, param, seconds, 3);
			case "idle":
				idle(runtime, param, seconds);
			case "timerfire":
				timerFire(runtime, param, seconds, false);
			case "timerfireint":
				timerFire(runtime, param, seconds, true);
			case "timerreset":
				timerReset(runtime, param, seconds);
			case "tasks":
				tasks(runtime, param, seconds);
			case "post":
				post(runtime, param, seconds);
			case "mutex", "mutexnew", "locknew", "tasknew":
				primitives(scenario, param, seconds);
			case "worker":
				worker(runtime, param);
			case "workerbacklog":
				workerBacklog(runtime, param);
			case "blocked":
				blocked(runtime, param, seconds);
			case "udp":
				udp(runtime, param, seconds);
			case "logtext", "logjson", "logoff":
				log(scenario, param, seconds);
			case "throw":
				throwCost(param, seconds);
			case "jsonread", "jsonshaped":
				jsonRead(scenario == "jsonshaped", param, seconds);
			case "mtime":
				modificationDate(seconds);
			case "switchtable", "switchtyped":
				switchTable(scenario == "switchtable", param, seconds);
			case "vectorforeach", "vectorloop":
				vector(scenario == "vectorforeach", param, seconds);
			case "fdisset", "fdwalk":
				#if (cpp && windows)
				FdIsSet.run(param, seconds, scenario == "fdwalk");
				#end
			default:
				Sys.println("unknown scenario " + scenario);
		}
		Sys.println("sink " + sink);
		Sys.exit(0);
	}

	/**
		The process's CPU time in seconds. Sys.cpuTime is that natively, but
		wall time on the jvm (System.nanoTime) and on Node (process.uptime).
	**/
	static function cpu():Float {
		#if jvm
		var bean:OsBean = cast JmxFactory.getOperatingSystemMXBean();
		return haxe.Int64.toInt(bean.getProcessCpuTime() / haxe.Int64.ofInt(1000)) / 1e6;
		#elseif nodejs
		var usage:Dynamic = js.Syntax.code("process.cpuUsage()");
		return (usage.user + usage.system) / 1e6;
		#else
		return Sys.cpuTime();
		#end
	}

	// ------------------------------------------------------------------
	// A tick reaching N listeners, each a component's bound method doing a
	// field update: what a runtime carrying a component per entity or per
	// session pays per frame. Pumped as fast as it goes, no socket waits.

	static function tick(runtime:CrossByte, n:Int, seconds:Float):Void {
		var components = [for (i in 0...n) new Component(i)];
		for (c in components) {
			runtime.addEventListener(TickEvent.TICK, c.onTick);
		}

		// Warm.
		for (_ in 0...200) {
			runtime.pump(1 / 60, 0);
		}

		var ticks = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (_ in 0...50) {
				runtime.pump(1 / 60, 0);
			}
			ticks += 50;
		}
		var used = cpu() - c0;
		var total:Float = 0;
		for (c in components) {
			total += c.value;
		}
		sink += Std.int(total) & 1;
		Sys.println('RESULT tick $n ticks=$ticks cpu_s=${r(used)} ns_per_tick=${r(used / ticks * 1e9)} ns_per_listener=${r(used / ticks / n * 1e9)}');
	}

	// ------------------------------------------------------------------
	// One tick listener walking N connections for an idle deadline (the
	// per-tick sweep a keep-alive or a session timeout does) through a
	// Map (as HTTPServer's __active is) or an Array. Every entry is checked,
	// none expires: the idle case, which is the common one.

	static function scan(runtime:CrossByte, n:Int, seconds:Float, useMap:Bool):Void {
		var map = new haxe.ds.ObjectMap<Component, Bool>();
		var arr:Array<Component> = [];
		for (i in 0...n) {
			var c = new Component(i);
			map.set(c, true);
			arr.push(c);
		}
		var deadline = 1e12;
		var expired = 0;
		runtime.addEventListener(TickEvent.TICK, function(e:TickEvent):Void {
			if (useMap) {
				for (c in map.keys()) {
					if (c.lastSeen > deadline) {
						expired++;
					}
				}
			} else {
				for (c in arr) {
					if (c.lastSeen > deadline) {
						expired++;
					}
				}
			}
		});

		for (_ in 0...20) {
			runtime.pump(1 / 60, 0);
		}

		var ticks = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (_ in 0...10) {
				runtime.pump(1 / 60, 0);
			}
			ticks += 10;
		}
		var used = cpu() - c0;
		sink += expired;
		Sys.println('RESULT scan${useMap ? "map" : "arr"} $n ticks=$ticks cpu_s=${r(used)} us_per_tick=${r(used / ticks * 1e6)} ns_per_entry=${r(used / ticks / n * 1e9)}');
	}

	// ------------------------------------------------------------------
	// Ping-pong over loopback: K client sockets and the K the server accepted,
	// all in this one runtime. Each client sends 32 bytes; the server echoes
	// them; the client sends again on the echo. A round trip is two
	// SOCKET_DATA dispatches, two reads, two writes and their sends.
	//
	// `listeners` is how many SOCKET_DATA listeners each socket carries: 1
	// as a plain server has, 3 as one with a metrics or logging tap might.

	static function echo(runtime:CrossByte, k:Int, seconds:Float, listeners:Int):Void {
		var server = new ServerSocket();
		var accepted:Array<Socket> = [];
		var payload = new ByteArray();
		for (i in 0...32) {
			payload.writeByte(i);
		}
		var trips = 0;
		var counting = false;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var s = e.socket;
			accepted.push(s);
			var buffer = new ByteArray();
			s.addEventListener(ProgressEvent.SOCKET_DATA, function(_:ProgressEvent):Void {
				buffer.clear();
				s.readBytes(buffer, 0, s.bytesAvailable);
				s.writeBytes(buffer, 0, buffer.length);
			});
			for (_ in 1...listeners) {
				s.addEventListener(ProgressEvent.SOCKET_DATA, function(ev:ProgressEvent):Void {
					sink += ev.bytesLoaded & 1;
				});
			}
		});
		server.bind(0, "127.0.0.1");
		server.listen(k + 16);
		var port = server.localPort;

		var clients:Array<Socket> = [];
		var connected = 0;
		for (i in 0...k) {
			var c = new Socket();
			var into = new ByteArray();
			c.addEventListener(Event.CONNECT, function(_):Void {
				connected++;
			});
			c.addEventListener(ProgressEvent.SOCKET_DATA, function(_:ProgressEvent):Void {
				into.clear();
				c.readBytes(into, 0, c.bytesAvailable);
				// A whole echo back: send the next.
				if (into.length >= 32) {
					if (counting) {
						trips++;
					}
					c.writeBytes(payload, 0, 32);
				}
			});
			for (_ in 1...listeners) {
				c.addEventListener(ProgressEvent.SOCKET_DATA, function(ev:ProgressEvent):Void {
					sink += ev.bytesLoaded & 1;
				});
			}
			c.connect("127.0.0.1", port);
			clients.push(c);
			// A few at a time, so the listen backlog is not overrun.
			if (i % 64 == 63) {
				pumpUntil(runtime, () -> connected >= i + 1 && accepted.length >= i + 1, 10);
			}
		}
		pumpUntil(runtime, () -> connected >= k && accepted.length >= k, 20);
		if (connected < k || accepted.length < k) {
			Sys.println('RESULT echo $k FAILED connected=$connected accepted=${accepted.length}');
			return;
		}

		for (c in clients) {
			c.writeBytes(payload, 0, 32);
		}

		// Warm.
		var w = Timer.stamp();
		while (Timer.stamp() - w < 0.5) {
			runtime.pump(0.0005, 0.001);
		}

		counting = true;
		var passes = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			runtime.pump(0.0005, 0.001);
			passes++;
		}
		var used = cpu() - c0;
		var wall = Timer.stamp() - w0;
		counting = false;

		// The server's side first, so the TIME_WAITs sit on its listening
		// port rather than holding ephemeral ports other processes need.
		for (s in accepted) {
			try s.close() catch (_:Dynamic) {}
		}
		for (_ in 0...20) {
			runtime.pump(0.001, 0.001);
		}
		for (c in clients) {
			try c.close() catch (_:Dynamic) {}
		}
		server.close();

		Sys.println('RESULT echo${listeners == 1 ? "" : "" + listeners} $k trips=$trips passes=$passes cpu_s=${r(used)} wall_s=${r(wall)} us_per_trip=${r(used / trips * 1e6)} trips_per_pass=${r(trips / passes)} us_per_pass=${r(used / passes * 1e6)}');
	}

	// ------------------------------------------------------------------
	// N connected sockets, idle: what one pass of the runtime costs with
	// them all registered and nothing arriving. Both ends are in the runtime,
	// so 2N descriptors are polled.

	static function idle(runtime:CrossByte, n:Int, seconds:Float):Void {
		var server = new ServerSocket();
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			accepted.push(e.socket);
			e.socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {});
		});
		server.bind(0, "127.0.0.1");
		server.listen(256);
		var port = server.localPort;
		var clients:Array<Socket> = [];
		var connected = 0;
		for (i in 0...n) {
			var c = new Socket();
			c.addEventListener(Event.CONNECT, function(_):Void {
				connected++;
			});
			c.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {});
			c.connect("127.0.0.1", port);
			clients.push(c);
			if (i % 64 == 63) {
				pumpUntil(runtime, () -> connected >= i + 1 && accepted.length >= i + 1, 10);
			}
		}
		pumpUntil(runtime, () -> connected >= n && accepted.length >= n, 20);
		if (connected < n || accepted.length < n) {
			Sys.println('RESULT idle $n FAILED connected=$connected accepted=${accepted.length}');
			return;
		}
		for (_ in 0...100) {
			runtime.pump(1 / 60, 0);
		}

		var passes = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (_ in 0...10) {
				runtime.pump(1 / 60, 0);
			}
			passes += 10;
		}
		var used = cpu() - c0;

		for (s in accepted) {
			try s.close() catch (_:Dynamic) {}
		}
		for (_ in 0...20) {
			runtime.pump(0.001, 0.001);
		}
		for (c in clients) {
			try c.close() catch (_:Dynamic) {}
		}
		server.close();

		var sockets = 2 * n + 1;
		Sys.println('RESULT idle $n passes=$passes cpu_s=${r(used)} us_per_pass=${r(used / passes * 1e6)} ns_per_socket_pass=${r(used / passes / sockets * 1e9)} cpu_pct_at_12tps=${r(used / passes * 12 * 100)} cpu_pct_at_60tps=${r(used / passes * 60 * 100)}');
	}

	// ------------------------------------------------------------------
	// N connections whose peer has stopped reading: each server-side socket
	// has written more than the kernel will hold, so every pass retries its
	// flush and is refused. The peers are plain blocking sys.net.Sockets
	// outside the runtime, which never read. Compare with `idle` at the same
	// N for what a refused flush costs a pass.

	static function blocked(runtime:CrossByte, n:Int, seconds:Float):Void {
		#if sys
		var server = new ServerSocket();
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			accepted.push(e.socket);
		});
		server.bind(0, "127.0.0.1");
		server.listen(256);
		var port = server.localPort;
		var peers:Array<sys.net.Socket> = [];
		for (i in 0...n) {
			var p = new sys.net.Socket();
			p.connect(new sys.net.Host("127.0.0.1"), port);
			peers.push(p);
			if (i % 32 == 31) {
				pumpUntil(runtime, () -> accepted.length >= i + 1, 10);
			}
		}
		pumpUntil(runtime, () -> accepted.length >= n, 20);
		if (accepted.length < n) {
			Sys.println('RESULT blocked $n FAILED accepted=${accepted.length}');
			return;
		}

		// Written a megabyte at a time until the kernel refuses some: loopback
		// on Windows takes tens of megabytes into a peer that never reads
		// before it pushes back. What it refuses waits in the socket.
		var chunk = new ByteArray();
		for (i in 0...65536) {
			chunk.writeByte(i & 0xFF);
		}
		for (s in accepted) {
			var written = 0;
			while (s.bytesPending == 0 && written < 1024) {
				for (_ in 0...16) {
					s.writeBytes(chunk, 0, chunk.length);
				}
				written++;
				runtime.pump(1 / 60, 0);
				runtime.pump(1 / 60, 0);
			}
		}
		for (_ in 0...200) {
			runtime.pump(1 / 60, 0);
		}
		var stuck = 0;
		for (s in accepted) {
			if (s.bytesPending > 0) {
				stuck++;
			}
		}

		var passes = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (_ in 0...10) {
				runtime.pump(1 / 60, 0);
			}
			passes += 10;
		}
		var used = cpu() - c0;

		for (s in accepted) {
			try s.close() catch (_:Dynamic) {}
		}
		for (p in peers) {
			try p.close() catch (_:Dynamic) {}
		}
		server.close();
		Sys.println('RESULT blocked $n stuck=$stuck passes=$passes cpu_s=${r(used)} us_per_pass=${r(used / passes * 1e6)} ns_per_stuck_socket_pass=${r(used / passes / (stuck > 0 ? stuck : 1) * 1e9)}');
		#end
	}

	// ------------------------------------------------------------------
	// A DatagramSocket receiving `burst` datagrams a pass from a plain
	// sys.net.UdpSocket in this process: the sender sends them, the runtime
	// pumps once, the socket reads them and then reads once more to find
	// nothing left. Per datagram, sending included.

	static function udp(runtime:CrossByte, burst:Int, seconds:Float):Void {
		#if sys
		var receiver = new crossbyte.net.DatagramSocket();
		var got = 0;
		receiver.addEventListener(crossbyte.events.DatagramSocketDataEvent.DATA, function(e:crossbyte.events.DatagramSocketDataEvent):Void {
			got++;
		});
		receiver.bind(0, "127.0.0.1");
		receiver.receive();
		var port = receiver.localPort;
		var sender = new sys.net.UdpSocket();
		var to = new sys.net.Address();
		to.host = new sys.net.Host("127.0.0.1").ip;
		to.port = port;
		var payload = haxe.io.Bytes.alloc(64);
		for (_ in 0...100) {
			sender.sendTo(payload, 0, 64, to);
			runtime.pump(0.001, 0);
		}
		var sent = 0;
		var passes = 0;
		var start = got;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (_ in 0...burst) {
				sender.sendTo(payload, 0, 64, to);
			}
			sent += burst;
			runtime.pump(0.0001, 0);
			passes++;
		}
		var used = cpu() - c0;
		var received = got - start;
		receiver.close();
		sender.close();
		Sys.println('RESULT udp $burst sent=$sent received=$received passes=$passes cpu_s=${r(used)} ns_per_datagram=${r(used / received * 1e9)} ns_per_pass=${r(used / passes * 1e9)}');
		#end
	}

	// ------------------------------------------------------------------
	// What one would-block costs as the socket layer reports it: natively a
	// C++ throw of the string "Blocking" (hxcpp's and CrossByte's glue both
	// do), caught as Dynamic, and, with `param` 2, rethrown as Blocked and
	// caught again, as SocketInput/SocketOutput/UdpSocket do. A micro-
	// measure, to apportion what `blocked` and `udp` measure in the workload.

	static function throwCost(depth:Int, seconds:Float):Void {
		var caught = 0;
		var count = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (_ in 0...10000) {
				try {
					wouldBlock(depth);
				} catch (e:Dynamic) {
					caught++;
				}
			}
			count += 10000;
		}
		var used = cpu() - c0;
		Sys.println('RESULT throw $depth count=$count caught=$caught cpu_s=${r(used)} ns_per_would_block=${r(used / count * 1e9)}');
	}

	static function wouldBlock(depth:Int):Void {
		if (depth >= 2) {
			try {
				nativeBlocking();
			} catch (e:Dynamic) {
				if (e == "Blocking") {
					throw haxe.io.Error.Blocked;
				}
				throw e;
			}
		} else {
			nativeBlocking();
		}
	}

	static function nativeBlocking():Void {
		#if cpp
		untyped __cpp__("::hx::Throw(HX_CSTRING(\"Blocking\"))");
		#else
		throw "Blocking";
		#end
	}

	// ------------------------------------------------------------------
	// File.modificationDate on one file, as an HTTP server reads it for each
	// static file it serves.

	static function modificationDate(seconds:Float):Void {
		#if sys
		var path:String = haxe.io.Path.join([Sys.getCwd(), "perfcore-mtime.txt"]);
		sys.io.File.saveContent(path, "x");
		var file = new crossbyte.io.File(path);
		var reads = 0;
		var total:Float = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (_ in 0...100) {
				total += file.modificationDate.getTime();
			}
			reads += 100;
		}
		var used = cpu() - c0;
		sys.FileSystem.deleteFile(path);
		sink += Std.int(total) & 1;
		Sys.println('RESULT mtime 1 reads=$reads cpu_s=${r(used)} us_per_read=${r(used / reads * 1e6)}');
		#end
	}

	// ------------------------------------------------------------------
	// A game message read as ByteArray.readObject reads JSON (parsed, then
	// its fields read `reads` times each) through haxe.Json.parse, or
	// through ShapedJson, which builds each object with fixed slots.

	static function jsonRead(shaped:Bool, reads:Int, seconds:Float):Void {
		var text:String = '{"type":"move","id":42,"x":1.5,"y":2.5,"name":"bob","alive":true}';
		var total:Float = 0;
		var messages = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (_ in 0...10000) {
				var o:Dynamic = shaped ? #if perf_new ShapedJson.read(text) #else haxe.Json.parse(text) #end : haxe.Json.parse(text);
				for (_ in 0...reads) {
					var x:Float = o.x;
					var y:Float = o.y;
					var id:Int = o.id;
					var type:String = o.type;
					total += x + y + id + type.length;
				}
			}
			messages += 10000;
		}
		var used = cpu() - c0;
		sink += Std.int(total) & 1;
		Sys.println('RESULT ${shaped ? "jsonshaped" : "jsonread"} $reads messages=$messages cpu_s=${r(used)} ns_per_message=${r(used / messages * 1e9)}');
	}

	// ------------------------------------------------------------------
	// An access-log line per request, as a server writes one: a message and
	// `fields` structured fields, into a sink that keeps only the length.
	// logtext and logjson format it; logoff is the same call below the
	// level, which still pays for the map its caller built.

	static function log(which:String, fields:Int, seconds:Float):Void {
		var total = 0;
		crossbyte.utils.Logger.sink = function(line:String):Void {
			total += line.length;
		};
		crossbyte.utils.Logger.json = which == "logjson";
		crossbyte.utils.Logger.level = which == "logoff" ? crossbyte.utils.LogLevel.WARN : crossbyte.utils.LogLevel.INFO;
		var names = [for (i in 0...fields) "field" + i];
		var records = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (i in 0...10000) {
				var map = new Map<String, String>();
				for (name in names) {
					map.set(name, "value");
				}
				crossbyte.utils.Logger.info("GET /index.html 200", map);
			}
			records += 10000;
		}
		var used = cpu() - c0;
		sink += total & 1;
		Sys.println('RESULT $which $fields records=$records cpu_s=${r(used)} ns_per_record=${r(used / records * 1e9)}');
	}

	// ------------------------------------------------------------------
	// An opcode dispatcher as SwitchTable's doc shows it (sixteen Int keys,
	// one argument), called once per message with the opcodes spread
	// evenly, against the typed `switch` it stands for. `param` is unused.

	static function switchTable(useTable:Bool, param:Int, seconds:Float):Void {
		var hits:Array<Int> = [for (_ in 0...16) 0];
		var table = crossbyte.ds.SwitchTable.make([
			{key: 0, handler: (v:Int) -> hits[0] += v},
			{key: 1, handler: (v:Int) -> hits[1] += v},
			{key: 2, handler: (v:Int) -> hits[2] += v},
			{key: 3, handler: (v:Int) -> hits[3] += v},
			{key: 4, handler: (v:Int) -> hits[4] += v},
			{key: 5, handler: (v:Int) -> hits[5] += v},
			{key: 6, handler: (v:Int) -> hits[6] += v},
			{key: 7, handler: (v:Int) -> hits[7] += v},
			{key: 8, handler: (v:Int) -> hits[8] += v},
			{key: 9, handler: (v:Int) -> hits[9] += v},
			{key: 10, handler: (v:Int) -> hits[10] += v},
			{key: 11, handler: (v:Int) -> hits[11] += v},
			{key: 12, handler: (v:Int) -> hits[12] += v},
			{key: 13, handler: (v:Int) -> hits[13] += v},
			{key: 14, handler: (v:Int) -> hits[14] += v},
			{key: 15, handler: (v:Int) -> hits[15] += v}
		]);
		var typed = function(key:Int, v:Int):Void {
			switch (key) {
				case 0: hits[0] += v;
				case 1: hits[1] += v;
				case 2: hits[2] += v;
				case 3: hits[3] += v;
				case 4: hits[4] += v;
				case 5: hits[5] += v;
				case 6: hits[6] += v;
				case 7: hits[7] += v;
				case 8: hits[8] += v;
				case 9: hits[9] += v;
				case 10: hits[10] += v;
				case 11: hits[11] += v;
				case 12: hits[12] += v;
				case 13: hits[13] += v;
				case 14: hits[14] += v;
				case 15: hits[15] += v;
				default:
			}
		};
		var calls = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (i in 0...100000) {
				if (useTable) {
					table(i & 15, 1);
				} else {
					typed(i & 15, 1);
				}
			}
			calls += 100000;
		}
		var used = cpu() - c0;
		sink += hits[3] & 1;
		Sys.println('RESULT ${useTable ? "switchtable" : "switchtyped"} 16 calls=$calls cpu_s=${r(used)} ns_per_dispatch=${r(used / calls * 1e9)}');
	}

	// ------------------------------------------------------------------
	// Vector.forEach over N Ints with a (value, index) callback, against an
	// index loop over the same Vector. Per element.

	static function vector(useForEach:Bool, n:Int, seconds:Float):Void {
		var v = new crossbyte.ds.Vector<Int>(n);
		for (i in 0...n) {
			v[i] = i;
		}
		var sum = 0;
		var visit = function(value:Int, index:Int):Void {
			sum += value;
		};
		var elements = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			if (useForEach) {
				v.forEach(visit);
			} else {
				for (i in 0...v.length) {
					visit(v[i], i);
				}
			}
			elements += n;
		}
		var used = cpu() - c0;
		sink += sum & 1;
		Sys.println('RESULT ${useForEach ? "vectorforeach" : "vectorloop"} $n elements=$elements cpu_s=${r(used)} ns_per_element=${r(used / elements * 1e9)}');
	}

	// ------------------------------------------------------------------
	// N one-shot timers, each re-arming itself from its callback for the
	// next frame: N fires a pump. The Void form goes through the scheduler's
	// wrapper closure; the Int form receives its handle, as haxe.Timer's
	// does. A re-armed one-shot reuses its freed slot under a new
	// generation, so its handle is past hxcpp's small-int cache.

	static function timerFire(runtime:CrossByte, n:Int, seconds:Float, withHandle:Bool):Void {
		var fired = 0;
		var sched = runtime.__timer;
		var rearmVoid:Void->Void = null;
		var rearmInt:Int->Void = null;
		rearmVoid = function():Void {
			fired++;
			sched.setTimeout(0.001, rearmVoid);
		};
		rearmInt = function(h:Int):Void {
			fired++;
			sink += h & 1;
			sched.setTimeout(0.001, rearmInt);
		};
		for (i in 0...n) {
			if (withHandle) {
				sched.setTimeout(0.001, rearmInt);
			} else {
				sched.setTimeout(0.001, rearmVoid);
			}
		}
		for (_ in 0...50) {
			runtime.pump(0.002, 0);
		}

		var start = fired;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (_ in 0...10) {
				runtime.pump(0.002, 0);
			}
		}
		var used = cpu() - c0;
		var count = fired - start;
		Sys.println('RESULT timerfire${withHandle ? "int" : ""} $n fires=$count cpu_s=${r(used)} ns_per_fire=${r(used / count * 1e9)}');
	}

	// ------------------------------------------------------------------
	// An idle deadline kept per connection the way a keep-alive does it:
	// every message clears the connection's timer and arms a new one. N
	// connections hold a timer each; one message a step goes to the next
	// connection round the ring. Measures the reset, at N timers live.

	static function timerReset(runtime:CrossByte, n:Int, seconds:Float):Void {
		var handles = new Array<Int>();
		var onIdle = function():Void {
			sink++;
		};
		for (i in 0...n) {
			handles.push(crossbyte.Timer.setTimeout(30.0, onIdle));
		}
		var at = 0;
		var resets = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			for (_ in 0...10000) {
				crossbyte.Timer.clear(handles[at]);
				handles[at] = crossbyte.Timer.setTimeout(30.0, onIdle);
				at++;
				if (at == n) {
					at = 0;
				}
			}
			resets += 10000;
			runtime.pump(0.0001, 0);
		}
		var used = cpu() - c0;
		Sys.println('RESULT timerreset $n resets=$resets cpu_s=${r(used)} ns_per_reset=${r(used / resets * 1e9)}');
	}

	// ------------------------------------------------------------------
	// A burst of N trivial tasks submitted to a four-thread pool from the
	// runtime's thread, then the runtime pumped until every COMPLETE has been
	// delivered. Per task: what the pool, the task and the delivery cost.

	static function tasks(runtime:CrossByte, n:Int, seconds:Float):Void {
		var pool = new TaskPool(4);
		var done = 0;
		var onDone = function(_:TaskEvent<Dynamic>):Void {
			done++;
		};

		// Warm with a small burst.
		for (_ in 0...200) {
			pool.submit(() -> {}).addEventListener(TaskEvent.COMPLETE, onDone);
		}
		pumpUntil(runtime, () -> done >= 200, 30);
		done = 0;

		// Bursts of n, one after another, for at least `seconds`: the
		// process clock ticks every 15.6 ms, too coarse for one burst.
		var bursts = 0;
		var c0 = cpu();
		var w0 = Timer.stamp();
		do {
			var target = done + n;
			for (_ in 0...n) {
				pool.submit(() -> {}).addEventListener(TaskEvent.COMPLETE, onDone);
			}
			pumpUntil(runtime, () -> done >= target, 600);
			bursts++;
		} while (Timer.stamp() - w0 < seconds);
		var used = cpu() - c0;
		var wall = Timer.stamp() - w0;
		pool.shutdown(true);
		Sys.println('RESULT tasks $n bursts=$bursts done=$done cpu_s=${r(used)} wall_s=${r(wall)} us_cpu_per_task=${r(used / done * 1e6)} us_wall_per_task=${r(wall / done * 1e6)}');
	}

	// ------------------------------------------------------------------
	// Another thread handing the runtime M callbacks through post(), as a
	// pool thread hands back a query's answer; the runtime pumps them.

	static function post(runtime:CrossByte, batch:Int, seconds:Float):Void {
		#if target.threaded
		var ran = 0;
		var cb = function():Void {
			ran++;
		};
		var stop = false;
		var sent = 0;
		var lock = new sys.thread.Lock();
		sys.thread.Thread.create(function():Void {
			while (!stop) {
				for (_ in 0...batch) {
					runtime.post(cb);
				}
				sent += batch;
				// Let the runtime catch up rather than queue without bound.
				while (!stop && sent - ran > batch * 4) {
					crossbyte.sys.System.sleep(0.0001);
				}
			}
			lock.release();
		});
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			runtime.pump(0.001, 0.0005);
		}
		stop = true;
		var used = cpu() - c0;
		lock.wait(5);
		Sys.println('RESULT post $batch ran=$ran cpu_s=${r(used)} ns_per_post=${r(used / ran * 1e9)}');
		#end
	}

	// ------------------------------------------------------------------
	// Micro-measures of the threading primitives a Task is made of, to
	// apportion what `tasks` measures whole. Not workloads: read them only
	// as parts of that one. An uncontended acquire/release; a Mutex made;
	// a Lock made; a Task made (with its Mutex and its Lock). What is made
	// is dropped at once, so the collector and the finalizers are counted.

	static function primitives(which:String, batch:Int, seconds:Float):Void {
		#if target.threaded
		var count = 0;
		var mutex = new sys.thread.Mutex();
		var c0 = cpu();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			switch (which) {
				case "mutex":
					for (_ in 0...batch) {
						mutex.acquire();
						mutex.release();
					}
				case "mutexnew":
					for (_ in 0...batch) {
						var m = new sys.thread.Mutex();
						if (m == null) sink++;
					}
				case "locknew":
					for (_ in 0...batch) {
						var l = new sys.thread.Lock();
						if (l == null) sink++;
					}
				default:
					for (_ in 0...batch) {
						var t = new crossbyte.sys.Task<Int>();
						if (t == null) sink++;
					}
			}
			count += batch;
		}
		var used = cpu() - c0;
		Sys.println('RESULT $which $batch count=$count cpu_s=${r(used)} ns_per_op=${r(used / count * 1e9)}');
		#end
	}

	// ------------------------------------------------------------------
	// A Worker reporting N progress messages as fast as it can, then
	// completing, while the runtime pumps and delivers them: what a
	// FileStream or a process reader does per chunk. Delivery is 256 a turn,
	// so a fast producer builds a backlog the runtime drains from the front.

	static function worker(runtime:CrossByte, n:Int):Void {
		#if target.threaded
		var received = 0;
		var finished = false;
		var w = new crossbyte.sys.Worker();
		w.addEventListener(crossbyte.events.ThreadEvent.PROGRESS, function(_):Void {
			received++;
		});
		w.addEventListener(crossbyte.events.ThreadEvent.COMPLETE, function(_):Void {
			finished = true;
		});
		w.doWork = function(_:Dynamic):Void {
			for (i in 0...n) {
				w.sendProgress(i);
			}
			w.sendComplete(n);
		};
		var c0 = cpu();
		var w0 = Timer.stamp();
		w.run();
		pumpUntil(runtime, () -> finished, 600);
		var used = cpu() - c0;
		var wall = Timer.stamp() - w0;
		Sys.println('RESULT worker $n received=$received cpu_s=${r(used)} wall_s=${r(wall)} ns_cpu_per_msg=${r(used / n * 1e9)} ns_wall_per_msg=${r(wall / n * 1e9)}');
		#end
	}

	// ------------------------------------------------------------------
	// The same, with the runtime busy while the worker sends: all N are
	// queued before the runtime pumps once, as when a frame runs long or the
	// runtime is blocked. Then it drains 256 a turn. Times the drain only.

	static function workerBacklog(runtime:CrossByte, n:Int):Void {
		#if target.threaded
		var received = 0;
		var sent = false;
		var w = new crossbyte.sys.Worker();
		w.addEventListener(crossbyte.events.ThreadEvent.PROGRESS, function(_):Void {
			received++;
		});
		w.doWork = function(_:Dynamic):Void {
			for (i in 0...n) {
				w.sendProgress(i);
			}
			sent = true;
		};
		w.run();
		var w0 = Timer.stamp();
		while (!sent && Timer.stamp() - w0 < 600) {
			crossbyte.sys.System.sleep(0.001);
		}
		var c0 = cpu();
		w0 = Timer.stamp();
		pumpUntil(runtime, () -> received >= n, 600);
		var used = cpu() - c0;
		var wall = Timer.stamp() - w0;
		w.cancel();
		Sys.println('RESULT workerbacklog $n received=$received cpu_s=${r(used)} wall_s=${r(wall)} ns_cpu_per_msg=${r(used / n * 1e9)}');
		#end
	}

	// ------------------------------------------------------------------

	static function pumpUntil(runtime:CrossByte, done:Void->Bool, limit:Float):Void {
		var w0 = Timer.stamp();
		while (!done() && Timer.stamp() - w0 < limit) {
			runtime.pump(0.001, 0.001);
		}
	}

	static function r(v:Float):Float {
		return Math.round(v * 1000) / 1000;
	}
}

class Component {
	public var id:Int;
	public var value:Float = 0;
	public var lastSeen:Float = 0;

	public function new(id:Int) {
		this.id = id;
	}

	public function onTick(e:TickEvent):Void {
		value += e.delta;
	}
}

#if jvm
@:native("java.lang.management.ManagementFactory")
extern class JmxFactory {
	static function getOperatingSystemMXBean():JmxOsBean;
}

@:native("java.lang.management.OperatingSystemMXBean")
extern interface JmxOsBean {}

@:native("com.sun.management.OperatingSystemMXBean")
extern interface OsBean extends JmxOsBean {
	function getProcessCpuTime():haxe.Int64;
}
#end
