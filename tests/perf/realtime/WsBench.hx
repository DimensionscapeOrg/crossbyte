import crossbyte.core.HostApplication;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;
import haxe.Timer;

/**
	One WebSocket between two processes, for an A/B of the framing: the
	server process binds 127.0.0.1:0 and starts a client process (this
	program, `role=client`), and after a warm-up each times `seconds` of it.

	- `mode=echo`: the client sends one message of `size` bytes, the server
	  sends it back, and the client sends the next when it arrives. The
	  client reports round trips a second and their latency (p50, p99,
	  p99.9), the server its CPU a message.
	- `mode=stream`: the client sends messages of `size` bytes as fast as the
	  connection takes them, keeping `window` bytes in flight at most. The
	  server reports messages and megabytes a second, and its CPU a message;
	  the client its CPU a message, which is where masking is paid.

	`text=1` sends text (the echo reads it as a String and sends that back),
	otherwise binary. Both sides report the collections that ran in the
	window and the heap in use at its end. Natively the CPU is the process's,
	user and kernel, and the server is pinned to CPUs 24-27, the client to
	28-31, as `WsLoad`'s.

	Arguments: mode (echo), size (100), text (0), seconds (5), warmup (2),
	window (1048576), label.
**/
class WsBench extends HostApplication {
	static var opts:Map<String, String> = new Map();

	static function opt(name:String, value:String):String {
		return opts.exists(name) ? opts.get(name) : value;
	}

	static function optInt(name:String, value:Int):Int {
		return Std.parseInt(opt(name, Std.string(value)));
	}

	static function optFloat(name:String, value:Float):Float {
		return Std.parseFloat(opt(name, Std.string(value)));
	}

	static function main():Void {
		for (arg in Sys.args()) {
			var at = arg.indexOf("=");
			if (at > 0) {
				opts.set(arg.substr(0, at), arg.substr(at + 1));
			}
		}
		var app = new WsBench();
		if (opt("role", "server") == "client") {
			PerfCpu.pin(0xF0000000);
			app.client();
		} else {
			PerfCpu.pin(0x0F000000);
			app.server();
		}
	}

	var mode:String;
	var size:Int;
	var text:Bool;
	var payload:ByteArray;
	var message:String;
	var last:Float = 0;
	var collections:GcCount = new GcCount();

	function new() {
		super();
		mode = opt("mode", "echo");
		size = optInt("size", 100);
		text = opt("text", "0") == "1";
		payload = new ByteArray();
		var chars = new StringBuf();
		for (i in 0...size) {
			payload.writeByte(i & 0xFF);
			chars.addChar(97 + i % 26);
		}
		payload.position = 0;
		message = chars.toString();
	}

	function pump(wait:Float):Void {
		var now = Timer.stamp();
		advance(now - last, wait);
		last = now;
		collections.poll();
	}

	function send(socket:WebSocket):Void {
		if (text) {
			socket.sendText(message);
		} else {
			socket.sendBinary(payload, 0, size);
		}
	}

	function server():Void {
		var peer:WebSocket = null;
		var received:Int = 0;
		var bytes:Float = 0;
		var server = new ServerWebSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			peer = cast e.socket;
			peer.addEventListener(WebSocketMessageEvent.MESSAGE, function(m:WebSocketMessageEvent):Void {
				received++;
				bytes += m.data.length;
				if (mode == "echo") {
					if (m.isText) {
						peer.sendText(m.text);
					} else {
						peer.sendBinary(m.data, 0, m.data.length);
					}
				}
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var args = ['role=client', 'port=${server.localPort}'];
		for (key in opts.keys()) {
			if (key != "role" && key != "port") {
				args.push('$key=${opts.get(key)}');
			}
		}
		var child = new sys.io.Process(Sys.programPath(), args);

		last = Timer.stamp();
		var deadline = Timer.stamp() + 30;
		while (peer == null && Timer.stamp() < deadline) {
			pump(0.005);
		}
		if (peer == null) {
			Sys.println('the client did not connect');
			child.kill();
			Sys.exit(1);
		}

		var phaseEnd = Timer.stamp() + optFloat("warmup", 2);
		while (Timer.stamp() < phaseEnd) {
			pump(0.001);
		}
		var u0 = PerfCpu.user(), k0 = PerfCpu.kernel(), w0 = Timer.stamp(), r0 = received, b0 = bytes, g0 = collections.count;
		phaseEnd = Timer.stamp() + optFloat("seconds", 5);
		while (Timer.stamp() < phaseEnd) {
			pump(0.001);
		}
		var cpu = PerfCpu.user() - u0 + PerfCpu.kernel() - k0;
		var wall = Timer.stamp() - w0;
		var n = received - r0;
		var heap = GcCount.heapMegabytes();
		Sys.println('RESULT side=server label=${opt("label", "")} mode=$mode size=$size text=${text ? 1 : 0} wall=${r(wall)}s messages=$n '
			+ 'msgPerSec=${Math.round(n / wall)} MBPerSec=${r((bytes - b0) / wall / 1048576)} cpuPerMsg=${r(cpu / n * 1e9)}ns '
			+ 'cpu%=${r(cpu / wall * 100)} gcs=${collections.count - g0} heapMB=${r(heap)}');

		// The client reports once it sees its own window out.
		var output = child.stdout;
		var until = Timer.stamp() + 10;
		try {
			while (Timer.stamp() < until) {
				var line = output.readLine();
				if (StringTools.startsWith(line, "RESULT")) {
					Sys.println(line);
					break;
				}
			}
		} catch (_:Dynamic) {}
		child.kill();
		child.close();
		Sys.exit(0);
	}

	function client():Void {
		var port = optInt("port", 0);
		var socket = new WebSocket();
		var open = false;
		var sentAt:Float = 0;
		var echoed:Int = 0;
		var sent:Int = 0;
		var measuring = false;
		var rtts:Array<Float> = [];
		var window = optInt("window", 1048576);
		socket.addEventListener(Event.CONNECT, function(_):Void {
			open = true;
			if (mode == "echo") {
				sentAt = Timer.stamp();
				send(socket);
			}
		});
		socket.addEventListener(WebSocketMessageEvent.MESSAGE, function(m:WebSocketMessageEvent):Void {
			var now = Timer.stamp();
			if (mode != "echo") {
				return;
			}
			if (m.isText) {
				// Read as an application would read it.
				m.text;
			}
			echoed++;
			if (measuring) {
				rtts.push(now - sentAt);
			}
			sentAt = Timer.stamp();
			send(socket);
		});
		socket.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			Sys.println('client error ${e.text}');
		});
		socket.connect("127.0.0.1", port);

		last = Timer.stamp();
		var deadline = Timer.stamp() + 30;
		while (!open && Timer.stamp() < deadline) {
			pump(0.005);
		}

		var phaseEnd = Timer.stamp() + optFloat("warmup", 2);
		var u0 = 0.0, k0 = 0.0, w0 = 0.0, e0 = 0, s0 = 0, g0 = 0;
		while (true) {
			if (mode == "stream") {
				// As much as the connection will take, no more than `window`
				// of it waiting.
				var budget = 64;
				while (socket.connected && socket.outputBufferLength < window && budget-- > 0) {
					send(socket);
					sent++;
				}
			}
			var now = Timer.stamp();
			if (now >= phaseEnd) {
				if (!measuring) {
					measuring = true;
					u0 = PerfCpu.user();
					k0 = PerfCpu.kernel();
					w0 = now;
					e0 = echoed;
					s0 = sent;
					g0 = collections.count;
					phaseEnd = now + optFloat("seconds", 5);
				} else {
					break;
				}
			}
			pump(mode == "stream" && socket.outputBufferLength < window ? 0 : 0.001);
		}
		var cpu = PerfCpu.user() - u0 + PerfCpu.kernel() - k0;
		var wall = Timer.stamp() - w0;
		var n = mode == "echo" ? echoed - e0 : sent - s0;
		var part = "";
		if (mode == "echo" && rtts.length > 0) {
			rtts.sort(Reflect.compare);
			part = ' roundTripsPerSec=${Math.round(n / wall)} p50=${us(pick(rtts, 0.5))}us p99=${us(pick(rtts, 0.99))}us p999=${us(pick(rtts, 0.999))}us';
		}
		Sys.println('RESULT side=client label=${opt("label", "")} mode=$mode size=$size text=${text ? 1 : 0} wall=${r(wall)}s messages=$n '
			+ 'cpuPerMsg=${r(cpu / n * 1e9)}ns cpu%=${r(cpu / wall * 100)} gcs=${collections.count - g0} heapMB=${r(GcCount.heapMegabytes())}' + part);
		Sys.stdout().flush();
		// The server closes this process once it has the line.
		var until = Timer.stamp() + 20;
		while (Timer.stamp() < until) {
			pump(0.01);
		}
	}

	static function pick(sorted:Array<Float>, at:Float):Float {
		var i = Std.int(sorted.length * at);
		return sorted[i >= sorted.length ? sorted.length - 1 : i];
	}

	static function us(seconds:Float):Float {
		return Math.round(seconds * 1e7) / 10;
	}

	static function r(x:Float):Float {
		return Math.round(x * 100) / 100;
	}
}

/**
	Collections counted as they happen: a weakly held object the collector
	clears is a collection, and another is made to catch the next. Polled
	once a pump, so two collections in one pump count once; at the rates
	here that is never.
**/
private class GcCount {
	public var count:Int = 0;

	#if cpp
	var sentinel:cpp.vm.WeakRef<Array<Int>>;
	#end

	public function new() {
		arm();
	}

	public inline function poll():Void {
		#if cpp
		if (sentinel.get() == null) {
			count++;
			arm();
		}
		#end
	}

	function arm():Void {
		#if cpp
		sentinel = new cpp.vm.WeakRef([0]);
		#end
	}

	public static function heapMegabytes():Float {
		#if cpp
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE) / 1048576;
		#else
		return 0;
		#end
	}
}
