import crossbyte.core.HostApplication;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;
import haxe.Timer;

/**
	A `DatagramSocket` woken for a few datagrams at a time, in one process
	over loopback: a round sends `burst` datagrams of `size` bytes from one
	socket to another, then pumps the runtime until the receiver has them.
	Each pass that reads ends with the read that finds the socket empty, so
	this prices what a receive pass costs around its datagrams, the shape
	of a lightly loaded server, woken for each arrival. Process CPU per
	datagram, best and median of `samples` samples.

	Arguments: burst (1), size (64), rounds (20000), samples (5), label.
	Pinned to CPUs 24-27.
**/
class UdpWake extends HostApplication {
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
		new UdpWake().run();
	}

	function new() {
		super();
	}

	function run():Void {
		var burst = optInt("burst", 1);
		var size = optInt("size", 64);
		var rounds = optInt("rounds", 20000);
		var samples = optInt("samples", 5);

		var received = 0;
		var server = new DatagramSocket();
		server.bind(0, "127.0.0.1");
		server.addEventListener(DatagramSocketDataEvent.DATA, _ -> received++);
		server.receive();
		var port = server.localPort;

		var client = new DatagramSocket();
		client.bind(0, "127.0.0.1");

		var payload = new ByteArray();
		for (i in 0...size) {
			payload.writeByte(i & 0xFF);
		}

		var lost = 0;
		function round():Void {
			var want = received + burst;
			for (_ in 0...burst) {
				client.send(payload, 0, size, "127.0.0.1", port);
			}
			var deadline = Timer.stamp() + 1;
			while (received < want) {
				advance(0, 0);
				if (Timer.stamp() > deadline) {
					lost += want - received;
					received = want;
				}
			}
		}

		for (_ in 0...(rounds >> 2)) {
			round();
		}
		var cpu:Array<Float> = [];
		var kernel:Array<Float> = [];
		for (_ in 0...samples) {
			var u0 = PerfCpu.user();
			var k0 = PerfCpu.kernel();
			var r0 = received;
			for (_ in 0...rounds) {
				round();
			}
			var got = received - r0;
			cpu.push((PerfCpu.user() - u0 + PerfCpu.kernel() - k0) / got * 1e9);
			kernel.push((PerfCpu.kernel() - k0) / got * 1e9);
		}
		Sys.println('UDPWAKE label=${opts.exists("label") ? opts.get("label") : ""} burst=$burst size=$size rounds=$rounds '
			+ 'cpuPerDatagram best=${Math.round(best(cpu))}ns median=${Math.round(median(cpu))}ns kernelPerDatagram median=${Math.round(median(kernel))}ns '
			+ 'lost=$lost');
		client.close();
		server.close();
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
