import crossbyte.core.HostApplication;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DeliveryMode;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import crossbyte.sys.System;
import haxe.Timer;

/**
	A game server's reliable UDP traffic, measured on the server.

	The server process binds 127.0.0.1:0, starts a client process (this same
	program, `role=client`) with `sessions` reliable sessions, and runs a
	fixed-rate loop: every tick it sends each session one reliable message of
	`rel` bytes and, if `seq` > 0, one sequenced message of `seq` bytes, and
	each client sends the server one reliable input of `input` bytes per tick.
	Once every session is up and a warm-up has passed, it times `seconds` of
	that loop in process CPU (user and kernel), and reports per tick and per
	session-tick. The client process is separate so its work is not counted.

	Arguments, key=value: sessions (100), rate (30 Hz), seconds (10), rel (64),
	seq (128), input (16), addrs (1: clients bound across this many loopback
	addresses, 127.0.0.2 up, so the server sees as many source hosts), idle
	(0: 1 sends nothing at all, to price an idle server), warmup (3 s),
	label (printed).

	Server pinned to CPUs 24-27, client to 28-31.
**/
class RudpLoad extends HostApplication {
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
		var app = new RudpLoad();
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
	var idle:Bool;
	var relPayload:ByteArray;
	var seqPayload:ByteArray;
	var inputPayload:ByteArray;
	var accepted:Array<ReliableDatagramSocket> = [];
	var received:Int = 0;
	var failures:Int = 0;
	var closes:Int = 0;

	function new() {
		super();
		sessions = optInt("sessions", 100);
		rate = optFloat("rate", 30);
		idle = optInt("idle", 0) == 1;
		relPayload = payload(optInt("rel", 64));
		seqPayload = payload(optInt("seq", 128));
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

	// ---- server -------------------------------------------------------

	function server():Void {
		var server = new ReliableDatagramServerSocket();
		server.maxPendingConnections = -1;
		#if !rt_before
		if (opts.exists("ackdelay")) {
			server.ackDelay = Std.parseFloat(opts.get("ackdelay"));
		}
		#end
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
			var s = e.socket;
			accepted.push(s);
			s.addEventListener(DatagramSocketDataEvent.DATA, function(_:DatagramSocketDataEvent):Void {
				received++;
			});
			s.addEventListener(IOErrorEvent.IO_ERROR, function(_:IOErrorEvent):Void {
				failures++;
			});
			s.addEventListener(Event.CLOSE, function(_:Event):Void {
				closes++;
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();
		// count=1: every datagram the server's socket reads, counted by a
		// second listener (a run for counting, not for timing).
		var datagramsIn = 0;
		if (optInt("count", 0) == 1) {
			@:privateAccess server.__socket.addEventListener(DatagramSocketDataEvent.DATA, function(_:DatagramSocketDataEvent):Void {
				datagramsIn++;
			});
		}

		var args = ['role=client', 'port=${server.localPort}'];
		for (key in opts.keys()) {
			if (key != "role" && key != "port") {
				args.push('$key=${opts.get(key)}');
			}
		}
		var child = new sys.io.Process(Sys.programPath(), args);

		var tick:Float = 1 / rate;
		var seconds:Float = optFloat("seconds", 10);
		var warmup:Float = optFloat("warmup", 3);
		var label:String = opt("label", "");

		// Up: every session connected.
		var deadline = Timer.stamp() + 60;
		var last = Timer.stamp();
		while (accepted.length < sessions && Timer.stamp() < deadline) {
			var now = Timer.stamp();
			advance(now - last, 0.005);
			last = now;
		}
		if (accepted.length < sessions) {
			Sys.println('only ${accepted.length} of $sessions sessions connected');
			child.kill();
			Sys.exit(1);
		}

		var sentTicks = 0;
		var next = Timer.stamp();
		var phaseEnd = Timer.stamp() + warmup;
		var measuring = false;
		var u0 = 0.0, k0 = 0.0, w0 = 0.0, r0 = 0, t0 = 0, d0 = 0, c0 = 0;
		var seqMode = DeliveryMode.sequenced(1);
		var seqLen = seqPayload.length;
		var relLen = relPayload.length;
		while (true) {
			var now = Timer.stamp();
			if (now >= next) {
				if (!idle) {
					for (s in accepted) {
						if (s.connected) {
							if (relLen > 0) {
								s.send(relPayload, 0, relLen);
							}
							if (seqLen > 0) {
								s.send(seqPayload, 0, seqLen, seqMode);
							}
						}
					}
				}
				sentTicks++;
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
					t0 = sentTicks;
					d0 = datagramsIn;
					c0 = readCount();
					phaseEnd = now + seconds;
				} else {
					break;
				}
			}
			var wait = next - Timer.stamp();
			advance(now - last, wait > 0 ? wait : 0);
			last = now;
		}
		var user = PerfCpu.user() - u0;
		var kernel = PerfCpu.kernel() - k0;
		var wall = Timer.stamp() - w0;
		var ticks = sentTicks - t0;
		var inputs = received - r0;
		var datagrams = datagramsIn - d0;
		// The client's count, as of its last write: about a second's lag at
		// each end, which cancels over the window.
		var clientDatagrams = readCount() - c0;
		child.kill();
		child.close();

		var cpu = user + kernel;
		var perTickUs = cpu / ticks * 1e6;
		var perSessionTickNs = cpu / ticks / sessions * 1e9;
		Sys.println('RESULT label=$label sessions=$sessions rate=$rate idle=${idle ? 1 : 0} wall=${r(wall)}s ticks=$ticks inputs=$inputs '
			+ 'expectedInputs=${Math.round(ticks * sessions)} user=${r(user)}s kernel=${r(kernel)}s cpu%=${r(cpu / wall * 100)} '
			+ 'perTick=${r(perTickUs)}us perSessionTick=${r(perSessionTickNs)}ns userPerSessionTick=${r(user / ticks / sessions * 1e9)}ns '
			+ 'failures=$failures closes=$closes' + (datagrams > 0 ? ' datagramsIn=$datagrams inPerSessionTick=${r(datagrams / ticks / sessions)}' : ''));
		if (opt("countfile", "") != "") {
			Sys.println('COUNT client datagrams in (sent by the server): $clientDatagrams = ${r(clientDatagrams / ticks / sessions)} per session-tick');
		}
		Sys.exit(0);
	}

	static function readCount():Int {
		var countFile = opt("countfile", "");
		if (countFile == "") {
			return 0;
		}
		try {
			var n = Std.parseInt(StringTools.trim(sys.io.File.getContent(countFile)));
			return n == null ? 0 : n;
		} catch (_:Dynamic) {
			return 0;
		}
	}

	static function r(x:Float):Float {
		return Math.round(x * 100) / 100;
	}

	// ---- client -------------------------------------------------------

	function client():Void {
		var port = optInt("port", 0);
		var addrs = optInt("addrs", 1);
		var clients:Array<ReliableDatagramSocket> = [];
		for (i in 0...sessions) {
			var c = new ReliableDatagramSocket();
			#if !rt_before
			if (opts.exists("ackdelay")) {
				c.ackDelay = Std.parseFloat(opts.get("ackdelay"));
			}
			#end
			c.addEventListener(DatagramSocketDataEvent.DATA, function(_:DatagramSocketDataEvent):Void {});
			c.addEventListener(IOErrorEvent.IO_ERROR, function(_:IOErrorEvent):Void {});
			c.bind(0, addrs > 1 ? '127.0.0.${2 + (i % addrs)}' : "127.0.0.1");
			c.connect("127.0.0.1", port);
			clients.push(c);
		}
		var tick:Float = 1 / rate;
		var next = Timer.stamp();
		var last = Timer.stamp();
		var inputLen = inputPayload.length;
		// countfile=path: datagrams the clients read, written there each second.
		var datagramsIn = 0;
		var countFile = opt("countfile", "");
		if (countFile != "") {
			for (c in clients) {
				@:privateAccess c.__transport.addEventListener(DatagramSocketDataEvent.DATA, function(_:DatagramSocketDataEvent):Void {
					datagramsIn++;
				});
			}
		}
		var nextWrite = Timer.stamp() + 1;
		// The server kills this process when it is done; this is the backstop.
		var stopAt = Timer.stamp() + optFloat("warmup", 3) + optFloat("seconds", 10) + 120;
		while (Timer.stamp() < stopAt) {
			var now = Timer.stamp();
			if (now >= next) {
				if (!idle && inputLen > 0) {
					for (c in clients) {
						if (c.connected) {
							c.send(inputPayload, 0, inputLen);
						}
					}
				}
				next += tick;
				if (next < now) {
					next = now + tick;
				}
			}
			if (countFile != "" && now >= nextWrite) {
				nextWrite = now + 1;
				sys.io.File.saveContent(countFile, '$datagramsIn');
			}
			var wait = next - Timer.stamp();
			advance(now - last, wait > 0 ? wait : 0);
			last = now;
		}
	}
}
