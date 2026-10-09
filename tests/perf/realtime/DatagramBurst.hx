import crossbyte.core.HostApplication;
import crossbyte.net.DatagramSocket;
import haxe.Timer;
import haxe.io.Bytes;

/**
	What a datagram socket keeps for a pass's sends, natively: one socket
	sends a `size`-byte datagram to each of `sessions` destinations in one
	pass, as a game server's broadcast does, then the runtime goes quiet,
	then it does it again.

	The destinations are `receivers` sockets bound on loopback (never read;
	what they cannot hold the system drops), taken in turn, so no two
	datagrams in a row go to one peer.

	Reports, per broadcast: `gather`, the sends' wall time; `flush`, the
	pass that sends them; `alloc`, the bytes it allocated (collection off,
	objects of 4,000 bytes or more counted exactly); and `held`, the heap
	after a full collection less the heap before the first, once after the
	broadcast and once after the quiet that follows it. Then `steady`: the
	median of `steady` broadcasts back to back at 30 a second, and what that
	run allocated and kept.

	Arguments: sessions (10000), size (1024), receivers (1000), bursts (3),
	quiet (12, seconds), steady (60), label.
**/
@:access(crossbyte.net.DatagramSocket)
class DatagramBurst extends HostApplication {
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
		new DatagramBurst().run();
	}

	var last:Float = 0;

	function new() {
		super();
	}

	function pump():Void {
		var now = Timer.stamp();
		advance(now - last, 0);
		last = now;
	}

	static function heap():Float {
		#if cpp
		cpp.vm.Gc.run(true);
		cpp.vm.Gc.run(true);
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE);
		#else
		return 0;
		#end
	}

	static function large():Float {
		#if cpp
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_LARGE);
		#else
		return 0;
		#end
	}

	function run():Void {
		var sessions = optInt("sessions", 10000);
		var size = optInt("size", 1024);
		var count = optInt("receivers", 1000);
		var payload = Bytes.alloc(size);
		for (i in 0...size) {
			payload.set(i, i & 0xFF);
		}

		// Plain system sockets, bound and never read: nothing of theirs on
		// the heap to blur what the sender keeps.
		var receivers:Array<sys.net.UdpSocket> = [];
		var targets:Array<sys.net.Address> = [];
		var sender = new DatagramSocket();
		sender.bind(0, "127.0.0.1");
		var loopback = new sys.net.Host("127.0.0.1");
		for (_ in 0...count) {
			var r = new sys.net.UdpSocket();
			r.bind(loopback, 0);
			receivers.push(r);
			targets.push(sender.__resolveTarget("127.0.0.1", r.host().port));
		}
		last = Timer.stamp();
		pump();

		var gathers:Array<Float> = [];
		var flushes:Array<Float> = [];
		var cpus:Array<Float> = [];
		function broadcast():Float {
			#if cpp
			cpp.vm.Gc.enable(false);
			#end
			var a0 = large();
			var c0 = Sys.cpuTime();
			var t0 = Timer.stamp();
			for (i in 0...sessions) {
				sender.__sendInPass(payload, 0, size, targets[i % count], null);
			}
			var t1 = Timer.stamp();
			pump();
			var t2 = Timer.stamp();
			var c1 = Sys.cpuTime();
			var a1 = large();
			#if cpp
			cpp.vm.Gc.enable(true);
			#end
			gathers.push(t1 - t0);
			flushes.push(t2 - t1);
			cpus.push(c1 - c0);
			return a1 - a0;
		}

		// Settled first: what setting up left behind is collected.
		var until = Timer.stamp() + 1;
		while (Timer.stamp() < until) {
			pump();
			crossbyte.sys.System.sleep(1 / 60);
		}
		heap();
		var base = heap();
		var line = 'BURST label=${opt("label", "")} sessions=$sessions size=$size receivers=$count base=${kb(base)}KB';
		var quiet = Std.parseFloat(opt("quiet", "12"));
		for (b in 0...optInt("bursts", 3)) {
			var allocated = broadcast();
			var held = heap() - base;
			var until = Timer.stamp() + quiet;
			while (Timer.stamp() < until) {
				pump();
				crossbyte.sys.System.sleep(1 / 60);
			}
			var heldQuiet = heap() - base;
			line += ' b$b:gather=${ms(gathers[b])}ms,flush=${ms(flushes[b])}ms,cpu=${ms(cpus[b])}ms,alloc=${kb(allocated)}KB,held=${kb(held)}KB,heldQuiet=${kb(heldQuiet)}KB';
		}

		gathers = [];
		flushes = [];
		cpus = [];
		var steady = optInt("steady", 60);
		var allocated = 0.0;
		for (_ in 0...steady) {
			allocated += broadcast();
			var until = Timer.stamp() + 1 / 30;
			while (Timer.stamp() < until) {
				pump();
				crossbyte.sys.System.sleep(0.002);
			}
		}
		var held = heap() - base;
		line += ' steady:gather=${ms(median(gathers))}ms,flush=${ms(median(flushes))}ms,cpu=${ms(median(cpus))}ms,alloc=${kb(allocated / steady)}KB,held=${kb(held)}KB';
		Sys.println(line);
		Sys.exit(0);
	}

	static function median(values:Array<Float>):Float {
		var sorted = values.copy();
		sorted.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return sorted[sorted.length >> 1];
	}

	static function ms(x:Float):Float {
		return Math.round(x * 100000) / 100;
	}

	static function kb(x:Float):Float {
		return Math.round(x / 102.4) / 10;
	}
}
