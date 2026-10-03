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
	A game server's WebSocket traffic, measured on the server, as RudpLoad
	measures reliable UDP: the server process binds 127.0.0.1:0 and starts a
	client process (this program, `role=client`) with `sessions` WebSockets.
	Every tick the server sends each session one binary message of `out`
	bytes and each client sends one of `input` bytes. After a warm-up the
	server times `seconds` of it in process CPU, user and kernel.

	The client also reports its own CPU over the window (through `cpufile`),
	for costs only a client pays, such as masking.

	Arguments: sessions (200), rate (30), seconds (10), out (64), input (16),
	warmup (3), cpufile, label.
	Server pinned to CPUs 24-27, client to 28-31.
**/
class WsLoad extends HostApplication {
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
		var app = new WsLoad();
		if (opt("role", "server") == "client") {
			PerfCpu.pin(0xF0000000);
			app.client();
		} else {
			PerfCpu.pin(0x0F000000);
			app.server();
		}
	}

	var sessions:Int;
	var rate:Float;
	var outPayload:ByteArray;
	var inputPayload:ByteArray;
	var peers:Array<WebSocket> = [];
	var received:Int = 0;
	var last:Float = 0;

	function new() {
		super();
		sessions = optInt("sessions", 200);
		rate = optFloat("rate", 30);
		outPayload = payload(optInt("out", 64));
		inputPayload = payload(optInt("input", 16));
	}

	static function payload(length:Int):ByteArray {
		var bytes = new ByteArray();
		for (i in 0...length) {
			bytes.writeByte(i & 0xFF);
		}
		bytes.position = 0;
		return bytes;
	}

	function pump(wait:Float):Void {
		var now = Timer.stamp();
		advance(now - last, wait);
		last = now;
	}

	function server():Void {
		var server = new ServerWebSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var peer:WebSocket = cast e.socket;
			peers.push(peer);
			peer.addEventListener(WebSocketMessageEvent.MESSAGE, function(_:WebSocketMessageEvent):Void {
				received++;
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
		var deadline = Timer.stamp() + 60;
		while (peers.length < sessions && Timer.stamp() < deadline) {
			pump(0.005);
		}
		if (peers.length < sessions) {
			Sys.println('only ${peers.length} of $sessions sessions connected');
			child.kill();
			Sys.exit(1);
		}

		var tick:Float = 1 / rate;
		var seconds:Float = optFloat("seconds", 10);
		var phaseEnd = Timer.stamp() + optFloat("warmup", 3);
		var measuring = false;
		var u0 = 0.0, k0 = 0.0, w0 = 0.0, r0 = 0, t0 = 0;
		var c0:Array<Float> = null;
		var ticks = 0;
		var next = Timer.stamp();
		var outLen = outPayload.length;
		while (true) {
			var now = Timer.stamp();
			if (now >= next) {
				for (p in peers) {
					if (p.connected) {
						p.writeBytes(outPayload, 0, outLen);
						p.flush();
					}
				}
				ticks++;
				next += tick;
				if (next < now) {
					next = now + tick;
				}
			}
			if (now >= phaseEnd) {
				if (!measuring) {
					measuring = true;
					u0 = PerfCpu.user();
					k0 = PerfCpu.kernel();
					w0 = Timer.stamp();
					r0 = received;
					t0 = ticks;
					c0 = readClientCpu();
					phaseEnd = now + seconds;
				} else {
					break;
				}
			}
			var wait = next - Timer.stamp();
			pump(wait > 0 ? wait : 0);
		}
		var user = PerfCpu.user() - u0;
		var kernel = PerfCpu.kernel() - k0;
		var wall = Timer.stamp() - w0;
		var n = ticks - t0;
		var inputs = received - r0;
		var c1 = readClientCpu();
		child.kill();
		child.close();
		var cpu = user + kernel;
		var clientPart = "";
		if (c0 != null && c1 != null) {
			var cu = c1[0] - c0[0];
			var ck = c1[1] - c0[1];
			var cs = c1[2] - c0[2];
			clientPart = ' clientUser=${r(cu)}s clientKernel=${r(ck)}s clientSent=$cs clientUserPerSend=${r(cu / cs * 1e9)}ns';
		}
		Sys.println('RESULT label=${opt("label", "")} sessions=$sessions rate=$rate wall=${r(wall)}s ticks=$n inputs=$inputs '
			+ 'expectedInputs=${Math.round(n * sessions)} user=${r(user)}s kernel=${r(kernel)}s cpu%=${r(cpu / wall * 100)} '
			+ 'perSessionTick=${r(cpu / n / sessions * 1e9)}ns userPerSessionTick=${r(user / n / sessions * 1e9)}ns' + clientPart);
		Sys.exit(0);
	}

	static function readClientCpu():Null<Array<Float>> {
		var file = opt("cpufile", "");
		if (file == "") {
			return null;
		}
		try {
			var parts = StringTools.trim(sys.io.File.getContent(file)).split(" ");
			return [Std.parseFloat(parts[0]), Std.parseFloat(parts[1]), Std.parseFloat(parts[2])];
		} catch (_:Dynamic) {
			return null;
		}
	}

	static function r(x:Float):Float {
		return Math.round(x * 100) / 100;
	}

	function client():Void {
		var port = optInt("port", 0);
		var clients:Array<WebSocket> = [];
		for (i in 0...sessions) {
			var c = new WebSocket();
			c.addEventListener(WebSocketMessageEvent.MESSAGE, function(_:WebSocketMessageEvent):Void {});
			c.addEventListener(IOErrorEvent.IO_ERROR, function(_:IOErrorEvent):Void {});
			c.connect("127.0.0.1", port);
			clients.push(c);
		}
		var tick:Float = 1 / rate;
		var next = Timer.stamp();
		last = Timer.stamp();
		var inputLen = inputPayload.length;
		var stopAt = Timer.stamp() + optFloat("warmup", 3) + optFloat("seconds", 10) + 120;
		var cpuFile = opt("cpufile", "");
		var nextWrite = Timer.stamp() + 0.5;
		var sent = 0;
		while (Timer.stamp() < stopAt) {
			var now = Timer.stamp();
			if (now >= next) {
				for (c in clients) {
					if (c.connected) {
						c.writeBytes(inputPayload, 0, inputLen);
						c.flush();
						sent++;
					}
				}
				next += tick;
				if (next < now) {
					next = now + tick;
				}
			}
			if (cpuFile != "" && now >= nextWrite) {
				nextWrite = now + 0.5;
				sys.io.File.saveContent(cpuFile, '${PerfCpu.user()} ${PerfCpu.kernel()} $sent');
			}
			var wait = next - Timer.stamp();
			pump(wait > 0 ? wait : 0);
		}
	}
}
