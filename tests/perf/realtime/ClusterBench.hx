import crossbyte.cluster.Membership;
import crossbyte.cluster.Rendezvous;

/**
	The cluster helpers on a game server's tick, in wall time on a pinned
	thread: each is single-threaded and allocates little, and the process CPU
	clock steps by 15.6 ms on Windows, coarser than what the fixed code takes.

	- `Membership`: `nodes` nodes, each heard from every `beat` seconds, spread
	  over the ticks, and `sweep()` every tick at `hz`, for `seconds` of
	  simulated time on a clock of its own. Time per tick.
	- `Rendezvous`: `owner(key)` and `owners(key, 3)` for `keys` keys over
	  `ring` nodes. Time per call.

	Best and median of `samples` samples. Arguments: nodes (1024), beat (1),
	hz (60), seconds (60), ring (16), keys (200000), samples (5), label.
	Pinned to CPUs 24-27.
**/
class ClusterBench {
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

		var nodes = optInt("nodes", 1024);
		var beat = optInt("beat", 1);
		var hz = optInt("hz", 60);
		var seconds = optInt("seconds", 60);
		var ring = optInt("ring", 16);
		var keys = optInt("keys", 200000);
		var samples = optInt("samples", 5);
		var label = opts.exists("label") ? opts.get("label") : "";

		var names = [for (i in 0...nodes) "node-" + i];
		var keyNames = [for (i in 0...keys) "room:" + i];

		var sweepCost:Array<Float> = [];
		var left = 0;
		for (_ in 0...samples) {
			var now:Float = 0;
			var alive = new Membership(5, 0, () -> now);
			for (name in names) {
				alive.heard(name, 0.0);
			}
			var ticks = hz * seconds;
			var perTick = Math.ceil(nodes / (beat * hz));
			var next = 0;
			var t0 = haxe.Timer.stamp();
			for (tick in 0...ticks) {
				now = tick / hz;
				for (_ in 0...perTick) {
					alive.heard(names[next], now);
					next = (next + 1) % nodes;
				}
				left += alive.sweep(now);
			}
			sweepCost.push((haxe.Timer.stamp() - t0) / ticks * 1e9);
		}

		var ownerCost:Array<Float> = [];
		var ownersCost:Array<Float> = [];
		var sink = 0;
		var hash = new Rendezvous();
		for (i in 0...ring) {
			hash.add("node-" + i);
		}
		for (_ in 0...samples) {
			var t0 = haxe.Timer.stamp();
			for (key in keyNames) {
				sink += hash.owner(key).length;
			}
			var t1 = haxe.Timer.stamp();
			for (key in keyNames) {
				sink += hash.owners(key, 3).length;
			}
			var t2 = haxe.Timer.stamp();
			ownerCost.push((t1 - t0) / keys * 1e9);
			ownersCost.push((t2 - t1) / keys * 1e9);
		}

		Sys.println('CLUSTER label=$label nodes=$nodes hz=$hz membershipPerTick best=${Math.round(best(sweepCost))}ns median=${Math.round(median(sweepCost))}ns '
			+ 'ring=$ring owner best=${Math.round(best(ownerCost))}ns median=${Math.round(median(ownerCost))}ns '
			+ 'owners3 best=${Math.round(best(ownersCost))}ns median=${Math.round(median(ownersCost))}ns left=$left sink=$sink');
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
