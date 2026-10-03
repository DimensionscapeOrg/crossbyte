import crossbyte.core.HostApplication;
import crossbyte.io.ByteArray;
import crossbyte.net.rtc.DataChannel;
import crossbyte.net.rtc.PeerConnection;
import haxe.Timer;

/**
	WebRTC data channel messages over the whole stack -- ICE, DTLS, SCTP --
	between two PeerConnections in one process over loopback. A round is a
	game tick's worth: `burst` messages of `size` bytes sent one after the
	other on one channel, then the runtime pumped until all have arrived.

	Reports process CPU per message (best and median of `samples` samples of
	`rounds` rounds).

	Arguments: burst (10), size (32), rounds (4000), samples (5), label.
	Pinned to CPUs 24-27.
**/
class RtcLoad extends HostApplication {
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
		new RtcLoad().run();
	}

	var last:Float = 0;
	var received:Int = 0;

	function new() {
		super();
	}

	function pump():Void {
		var now = Timer.stamp();
		advance(now - last, 0);
		last = now;
	}

	function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var deadline = Timer.stamp() + timeout;
		while (!done() && Timer.stamp() < deadline) {
			pump();
			crossbyte.sys.System.sleep(0.001);
		}
	}

	function run():Void {
		var burst = optInt("burst", 10);
		var size = optInt("size", 32);
		var rounds = optInt("rounds", 4000);
		var samples = optInt("samples", 5);

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);
		var accepted:DataChannel = null;
		bob.onChannel = function(channel:DataChannel):Void {
			accepted = channel;
			channel.onBytes = function(_:ByteArray):Void {
				received++;
			};
		};
		alice.bind(0, "127.0.0.1");
		bob.bind(0, "127.0.0.1");
		last = Timer.stamp();
		alice.connect(bob.description());
		bob.connect(alice.description());
		pumpUntil(() -> alice.connected && bob.connected, 15.0);
		if (!alice.connected || !bob.connected) {
			Sys.println("not connected");
			Sys.exit(1);
		}
		var channel = alice.createDataChannel("game");
		pumpUntil(() -> channel.open && accepted != null, 5.0);
		if (!channel.open || accepted == null) {
			Sys.println("no channel");
			Sys.exit(1);
		}

		var message = new ByteArray();
		for (i in 0...size) {
			message.writeByte(i & 0xFF);
		}
		message.position = 0;

		var stalls = 0;
		function round():Void {
			var want = received + burst;
			for (_ in 0...burst) {
				channel.sendBytes(message);
			}
			var spins = 0;
			while (received < want && spins < 100000) {
				pump();
				spins++;
			}
			if (spins >= 100000) {
				stalls++;
			}
			pump();
			pump();
		}

		for (_ in 0...100) {
			round();
		}
		var cpu:Array<Float> = [];
		for (_ in 0...samples) {
			var u0 = PerfCpu.user();
			var k0 = PerfCpu.kernel();
			var r0 = received;
			for (_ in 0...rounds) {
				round();
			}
			var got = received - r0;
			cpu.push((PerfCpu.user() - u0 + PerfCpu.kernel() - k0) / got * 1e9);
		}
		Sys.println('RTC label=${opts.exists("label") ? opts.get("label") : ""} burst=$burst size=$size rounds=$rounds '
			+ 'cpuPerMessage best=${Math.round(best(cpu))}ns median=${Math.round(median(cpu))}ns '
			+ 'stalls=$stalls');
		alice.close();
		bob.close();
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
