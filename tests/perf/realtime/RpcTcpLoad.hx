import crossbyte.core.HostApplication;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.NetConnection;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCSession;
import haxe.Timer;

/**
	Compiled RPC over a real TCP connection on loopback, in one process: a
	round is `burst` one-way calls `move(id, x, y)` made one after another, as
	a tick's worth of updates, then the runtime pumped until the handler has
	run them all. Process CPU per call, best and median of `samples` samples.

	Arguments: burst (20), rounds (10000), samples (5), label.
	Pinned to CPUs 24-27.
**/
class RpcTcpLoad extends HostApplication {
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
		new RpcTcpLoad().run();
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
		var rounds = optInt("rounds", 10000);
		var samples = optInt("samples", 5);

		var handler = new MoveHandler();
		var server = new ServerSocket();
		var serverSession:RPCSession<Dynamic, Dynamic> = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			serverSession = new RPCSession(NetConnection.fromSocket(e.socket), null, handler);
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var socket = new Socket();
		socket.connect("127.0.0.1", server.localPort);
		var commands = new MoveCommands();
		var client = new RPCSession<MoveCommands>(NetConnection.fromSocket(socket), commands);
		last = Timer.stamp();
		var deadline = Timer.stamp() + 10;
		while ((serverSession == null || !socket.connected) && Timer.stamp() < deadline) {
			pump();
		}
		if (serverSession == null) {
			Sys.println("not connected");
			Sys.exit(1);
		}

		var stalls = 0;
		function round():Void {
			var want = handler.moves + burst;
			for (i in 0...burst) {
				commands.move(i, 1.5, -2.5);
			}
			var spins = 0;
			while (handler.moves < want && spins < 100000) {
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
			var m0 = handler.moves;
			for (_ in 0...rounds) {
				round();
			}
			var calls = handler.moves - m0;
			cpu.push((PerfCpu.user() - u0 + PerfCpu.kernel() - k0) / calls * 1e9);
			kernel.push((PerfCpu.kernel() - k0) / calls * 1e9);
		}
		Sys.println('RPCTCP label=${opts.exists("label") ? opts.get("label") : ""} burst=$burst rounds=$rounds '
			+ 'cpuPerCall best=${Math.round(best(cpu))}ns median=${Math.round(median(cpu))}ns kernelPerCall median=${Math.round(median(kernel))}ns '
			+ 'stalls=$stalls client=${client != null}');
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

class MoveCommands extends RPCCommands {
	public function new() {}

	@:rpc public function move(id:Int, x:Float, y:Float):Void {}
}

class MoveHandler extends RPCHandler {
	public var moves:Int = 0;
	public var x:Float = 0;

	public function new() {}

	@:rpc public function move(id:Int, x:Float, y:Float):Void {
		moves++;
		this.x += x - y;
	}
}
