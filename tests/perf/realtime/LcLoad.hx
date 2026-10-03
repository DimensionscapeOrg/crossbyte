import crossbyte.core.HostApplication;
import crossbyte.io.ByteArray;
import crossbyte.ipc.LocalConnection;
import haxe.Timer;

/**
	LocalConnection messages between two connections in one process, over the
	real local transport (a named pipe on Windows), each with its reader
	thread: `count` messages of `size` bytes, sent `burst` at a time and then
	pumped until received. Process CPU (user and kernel, every thread) per
	message, best and median of `samples` samples.

	Arguments: count (100000), size (64), burst (1000), samples (5), label.
	Pinned to CPUs 24-27.
**/
class LcLoad extends HostApplication {
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
		new LcLoad().run();
	}

	var received:Int = 0;
	var receivedBytes:Float = 0;
	var last:Float = 0;

	function new() {
		super();
	}

	function pump(timeout:Float):Void {
		var now = Timer.stamp();
		advance(now - last, timeout);
		last = now;
	}

	function run():Void {
		var count = optInt("count", 100000);
		var size = optInt("size", 64);
		var burst = optInt("burst", 1000);
		var samples = optInt("samples", 5);
		var name = "cb_perf_lc_" + Std.random(1 << 30);

		var server = new LocalConnection();
		var client = new LocalConnection();
		server.readEnabled = true;
		server.onData = function(input) {
			received++;
			receivedBytes += input.bytesAvailable;
		};
		server.listen(name);
		client.connect(name);
		last = Timer.stamp();
		var deadline = Timer.stamp() + 10;
		while ((!server.connected || !client.connected) && Timer.stamp() < deadline) {
			pump(0.005);
		}
		if (!server.connected || !client.connected) {
			Sys.println("not connected");
			Sys.exit(1);
		}

		var message = new ByteArray();
		for (i in 0...size) {
			message.writeByte(i & 0xFF);
		}
		message.position = 0;

		function sample(n:Int):Void {
			var target = received + n;
			var sent = 0;
			while (sent < n) {
				var upTo = sent + burst > n ? n : sent + burst;
				while (sent < upTo) {
					client.send(message);
					sent++;
				}
				// Waits for the burst, so neither side's queue grows without end;
				// sleeping between pumps, so the wait itself costs no CPU.
				var stopAt = Timer.stamp() + 5;
				while (received < target - n + sent && Timer.stamp() < stopAt) {
					pump(0);
					if (received < target - n + sent) {
						crossbyte.sys.System.sleep(0.0005);
					}
				}
			}
		}

		sample(count >> 2);
		var cpu:Array<Float> = [];
		var users:Array<Float> = [];
		var walls:Array<Float> = [];
		for (_ in 0...samples) {
			var u0 = PerfCpu.user();
			var k0 = PerfCpu.kernel();
			var w0 = Timer.stamp();
			var r0 = received;
			sample(count);
			var u = PerfCpu.user() - u0;
			var k = PerfCpu.kernel() - k0;
			var got = received - r0;
			cpu.push((u + k) / got * 1e9);
			users.push(u / got * 1e9);
			walls.push((Timer.stamp() - w0) / got * 1e9);
		}
		Sys.println('LC label=${opts.exists("label") ? opts.get("label") : ""} size=$size count=$count burst=$burst '
			+ 'cpuPerMessage best=${Math.round(best(cpu))}ns median=${Math.round(median(cpu))}ns '
			+ 'userPerMessage median=${Math.round(median(users))}ns wallPerMessage median=${Math.round(median(walls))}ns');
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
