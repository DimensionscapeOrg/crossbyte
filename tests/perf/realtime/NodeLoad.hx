import crossbyte.cluster.NodeChannel;
import crossbyte.core.HostApplication;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerSocket;
import haxe.Timer;

/**
	Cluster messages over a real `NodeChannel` on loopback, in one process: a
	round is `burst` messages of `size` bytes sent one after another, as a
	tick's worth of node-to-node traffic, then the runtime pumped until the far
	end has them all. Process CPU per message, best and median of `samples`
	samples.

	Arguments: burst (20), size (64), rounds (10000), samples (5), label.
	Pinned to CPUs 24-27.
**/
class NodeLoad extends HostApplication {
	static var opts:Map<String, String> = new Map();

	static function optInt(name:String, value:Int):Int {
		return opts.exists(name) ? Std.parseInt(opts.get(name)) : value;
	}

	static function main():Void {
		for (arg in Sys.args()) {
			var at = arg.indexOf("=");
			if (at > 0) {
				opts.set(arg.substr(0, at), arg.substr(at + 1));
			}
		}
		PerfCpu.pin(0x0F000000);
		new NodeLoad().run();
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

	function run():Void {
		var burst = optInt("burst", 20);
		var size = optInt("size", 64);
		var rounds = optInt("rounds", 10000);
		var samples = optInt("samples", 5);

		var received = 0;
		var accepted:NodeChannel = null;
		var server = new ServerSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			accepted = NodeChannel.adopt(e.socket);
			accepted.onMessage = _ -> received++;
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var link = NodeChannel.dial("127.0.0.1", server.localPort);
		last = Timer.stamp();
		var deadline = Timer.stamp() + 10;
		while ((accepted == null || !link.up) && Timer.stamp() < deadline) {
			pump();
		}
		if (accepted == null || !link.up) {
			Sys.println("not connected");
			Sys.exit(1);
		}

		var payload = new ByteArray();
		for (i in 0...size) {
			payload.writeByte(i & 0xFF);
		}

		var stalls = 0;
		function round():Void {
			var want = received + burst;
			for (_ in 0...burst) {
				link.send(payload);
			}
			var spins = 0;
			while (received < want && spins < 100000) {
				pump();
				spins++;
			}
			if (spins >= 100000) {
				stalls++;
			}
		}

		for (_ in 0...200) {
			round();
		}
		var cpu:Array<Float> = [];
		var kernel:Array<Float> = [];
		for (_ in 0...samples) {
			var u0 = PerfCpu.user();
			var k0 = PerfCpu.kernel();
			var m0 = received;
			for (_ in 0...rounds) {
				round();
			}
			var messages = received - m0;
			cpu.push((PerfCpu.user() - u0 + PerfCpu.kernel() - k0) / messages * 1e9);
			kernel.push((PerfCpu.kernel() - k0) / messages * 1e9);
		}
		Sys.println('NODE label=${opts.exists("label") ? opts.get("label") : ""} burst=$burst size=$size rounds=$rounds '
			+ 'cpuPerMessage best=${Math.round(best(cpu))}ns median=${Math.round(median(cpu))}ns kernelPerMessage median=${Math.round(median(kernel))}ns '
			+ 'stalls=$stalls');
		Sys.exit(0);
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
}
