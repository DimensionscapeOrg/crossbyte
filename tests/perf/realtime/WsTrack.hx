import crossbyte.core.HostApplication;
import crossbyte.events.Event;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;

/**
	What a `ServerWebSocket` spends keeping its list of open sessions: `n`
	sessions arrive (the CONNECT a finished upgrade dispatches) and then leave
	(their CLOSE) in a shuffled order, without a network, the list is the
	whole of what is measured. Wall time on a pinned thread per session,
	arrival and departure together (the process CPU clock steps by 15.6 ms on
	Windows), best and median of `samples` samples.

	Arguments: n (10000), samples (5), label. Pinned to CPUs 24-27.
**/
@:access(crossbyte.net.ServerWebSocket)
class WsTrack extends HostApplication {
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
		new WsTrack().run();
	}

	function new() {
		super();
	}

	function run():Void {
		var n = optInt("n", 10000);
		var samples = optInt("samples", 5);
		var order = [for (i in 0...n) i];
		var seed = 12345;
		for (i in 0...n) {
			seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
			var j = seed % n;
			var t = order[i];
			order[i] = order[j];
			order[j] = t;
		}

		var cost:Array<Float> = [];
		var left = 0;
		for (_ in 0...samples) {
			var server = new ServerWebSocket();
			// Fresh each sample, so no session carries a listener from the last.
			var sessions = [for (_ in 0...n) new WebSocket()];
			var t0 = haxe.Timer.stamp();
			for (session in sessions) {
				server.__trackClient(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, session));
			}
			for (i in order) {
				sessions[i].dispatchEvent(new Event(Event.CLOSE));
			}
			cost.push((haxe.Timer.stamp() - t0) / n * 1e9);
			left += server.__clients.length;
		}
		Sys.println('WSTRACK label=${opts.exists("label") ? opts.get("label") : ""} n=$n perSession best=${Math.round(best(cost))}ns median=${Math.round(median(cost))}ns left=$left');
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
