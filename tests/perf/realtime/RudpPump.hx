import crossbyte.core.HostApplication;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DeliveryMode;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import haxe.Timer;

/**
	Reliable UDP over real loopback sockets, closed loop, in one process:
	a server with `sessions` accepted sessions and as many clients, all on
	one host-driven runtime. A round is what a game tick is, the server
	sends each session one reliable message (`rel` bytes) and one sequenced
	one (`seq` bytes), each client sends one reliable input (`input` bytes),
	and the runtime is pumped until all of it has arrived.

	Two measurements, both of the whole process (server and clients run the
	same code, so a change shows on both sides):

	- Bytes allocated per round and per datagram, read off the collector
	  with collection switched off for a few rounds: deterministic, so a
	  change in allocation shows exactly, whatever else runs on the machine.
	- User CPU per round, the best of `samples` samples of `rounds` rounds
	  each (noise only ever adds), and the median.

	Pinned to CPUs 24-27. Arguments: sessions (500), rounds (200),
	samples (7), rel (64), seq (128), input (16), label, and encrypt=1 for
	every session encrypted (`ReliableDatagramSocket.encryptionKey`), one
	key for all of them.
**/
class RudpPump extends HostApplication {
	static var opts:Map<String, String> = new Map();

	static function opt(name:String, value:String):String {
		return opts.exists(name) ? opts.get(name) : value;
	}

	static function optInt(name:String, value:Int):Int {
		return Std.parseInt(opt(name, Std.string(value)));
	}

	static function main():Void {
		for (arg in Sys.args()) {
			var at = arg.indexOf("=");
			if (at > 0) {
				opts.set(arg.substr(0, at), arg.substr(at + 1));
			}
		}
		PerfCpu.pin(0x0F000000);
		new RudpPump().run();
	}

	var sessions:Int;
	var accepted:Array<ReliableDatagramSocket> = [];
	var clients:Array<ReliableDatagramSocket> = [];
	var serverGot:Int = 0;
	var clientsGot:Int = 0;
	var datagramsIn:Int = 0;
	var last:Float = 0;

	function new() {
		super();
		sessions = optInt("sessions", 500);
	}

	static function payload(length:Int):ByteArray {
		var bytes = new ByteArray();
		for (i in 0...length) {
			bytes.writeByte(i & 0xFF);
		}
		bytes.position = 0;
		return bytes;
	}

	function pump():Void {
		var now = Timer.stamp();
		advance(now - last, 0);
		last = now;
	}

	function run():Void {
		var rel = payload(optInt("rel", 64));
		var seq = payload(optInt("seq", 128));
		var input = payload(optInt("input", 16));
		var seqMode = DeliveryMode.sequenced(1);

		var server = new ReliableDatagramServerSocket();
		server.maxPendingConnections = -1;
		#if !rt_before
		if (opts.exists("ackdelay")) {
			server.ackDelay = Std.parseFloat(opts.get("ackdelay"));
		}
		var key:haxe.io.Bytes = null;
		if (opt("encrypt", "0") == "1") {
			key = haxe.io.Bytes.alloc(32);
			for (i in 0...32) {
				key.set(i, i * 7);
			}
			server.encryptionKeyFor = (_, _, _) -> key;
		}
		#end
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
			accepted.push(e.socket);
			e.socket.addEventListener(DatagramSocketDataEvent.DATA, function(_:DatagramSocketDataEvent):Void {
				serverGot++;
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();
		// Every datagram the server reads, and every one the clients do.
		@:privateAccess server.__socket.addEventListener(DatagramSocketDataEvent.DATA, function(_:DatagramSocketDataEvent):Void {
			datagramsIn++;
		});

		last = Timer.stamp();
		for (i in 0...sessions) {
			var c = new ReliableDatagramSocket();
			#if !rt_before
			if (opts.exists("ackdelay")) {
				c.ackDelay = Std.parseFloat(opts.get("ackdelay"));
			}
			if (key != null) {
				c.encryptionKey = key;
			}
			#end
			c.addEventListener(DatagramSocketDataEvent.DATA, function(_:DatagramSocketDataEvent):Void {
				clientsGot++;
			});
			@:privateAccess c.__transport.addEventListener(DatagramSocketDataEvent.DATA, function(_:DatagramSocketDataEvent):Void {
				datagramsIn++;
			});
			c.bind(0, "127.0.0.1");
			c.connect("127.0.0.1", server.localPort);
			clients.push(c);
			if (i % 50 == 49) {
				pump();
			}
		}
		var deadline = Timer.stamp() + 60;
		while ((accepted.length < sessions || !allConnected()) && Timer.stamp() < deadline) {
			pump();
			crossbyte.sys.System.sleep(0.001);
		}
		if (accepted.length < sessions) {
			Sys.println('only ${accepted.length} of $sessions connected');
			Sys.exit(1);
		}

		var stalls = 0;
		var pumps = 0;
		var roundsRun = 0;
		function round():Void {
			var wantServer = serverGot + sessions;
			var wantClients = clientsGot + 2 * sessions;
			for (s in accepted) {
				s.send(rel, 0, rel.length);
				s.send(seq, 0, seq.length, seqMode);
			}
			for (c in clients) {
				c.send(input, 0, input.length);
			}
			var spins = 0;
			while ((serverGot < wantServer || clientsGot < wantClients) && spins < 20000) {
				pump();
				spins++;
				pumps++;
			}
			roundsRun++;
			if (spins >= 20000) {
				stalls++;
			}
			// And the acknowledgements those drew.
			pump();
			pump();
		}

		var rounds = optInt("rounds", 200);
		var samples = optInt("samples", 7);
		for (_ in 0...50) {
			round();
		}

		// Allocation: collection off, some rounds, the growth in what the
		// collector has reserved, with nothing collected, every allocation
		// takes new room, and the room is counted in blocks, so enough rounds
		// that a block is small beside the total.
		cpp.vm.Gc.run(true);
		cpp.vm.Gc.enable(false);
		var allocRounds = optInt("allocrounds", 100);
		var d0 = datagramsIn;
		var m0 = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_RESERVED);
		for (_ in 0...allocRounds) {
			round();
		}
		var m1 = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_RESERVED);
		var allocDatagrams = datagramsIn - d0;
		cpp.vm.Gc.enable(true);
		cpp.vm.Gc.run(true);
		var bytesPerRound = (m1 - m0) / allocRounds;
		var bytesPerDatagram = (m1 - m0) / allocDatagrams;

		var users:Array<Float> = [];
		var kernels:Array<Float> = [];
		var perDatagram:Array<Float> = [];
		var datagramsPerRound = 0.0;
		for (_ in 0...samples) {
			var u0 = PerfCpu.user();
			var k0 = PerfCpu.kernel();
			var dd0 = datagramsIn;
			for (_ in 0...rounds) {
				round();
			}
			var u = PerfCpu.user() - u0;
			var k = PerfCpu.kernel() - k0;
			var dd = datagramsIn - dd0;
			users.push(u / rounds * 1e6);
			kernels.push(k / rounds * 1e6);
			perDatagram.push(u / dd * 1e9);
			datagramsPerRound = dd / rounds;
		}
		var label = opt("label", "");
		Sys.println('PUMP label=$label sessions=$sessions rounds=$rounds samples=$samples datagramsPerRound=${r(datagramsPerRound)} '
			+ 'allocPerRound=${Math.round(bytesPerRound)}B allocPerDatagram=${Math.round(bytesPerDatagram)}B '
			+ 'userPerRound best=${r(best(users))}us median=${r(median(users))}us '
			+ 'userPerDatagram best=${r(best(perDatagram))}ns median=${r(median(perDatagram))}ns '
			+ 'kernelPerRound median=${r(median(kernels))}us stalls=$stalls pumpsPerRound=${r(pumps / roundsRun)}');
		Sys.exit(0);
	}

	function allConnected():Bool {
		for (c in clients) {
			if (!c.connected) {
				return false;
			}
		}
		return true;
	}

	static function best(values:Array<Float>):Float {
		var b = Math.POSITIVE_INFINITY;
		for (v in values) {
			if (v < b) {
				b = v;
			}
		}
		return b;
	}

	static function median(values:Array<Float>):Float {
		var sorted = values.copy();
		sorted.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return sorted[sorted.length >> 1];
	}

	static function r(x:Float):Float {
		return Math.round(x * 100) / 100;
	}
}
