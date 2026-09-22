import crossbyte.core.CrossByte;
import crossbyte.ds.SlotHandle;
import crossbyte.ds.SlotMap;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import haxe.Timer;

/**
	A server-shaped workload, run for as long as you ask, to find out whether
	the native collector's intermittent fault reaches production code.

	## What it is answering

	The cpp suite segfaults inside hxcpp's collector somewhere between one run
	in seven and one in two, and the structure it corrupts is the string hash
	`hx::SourceInfo` keeps for `haxe.PosInfos`. That detail matters, because
	almost nothing outside a test harness makes those: every `utest` assertion
	takes a `?pos:haxe.PosInfos` and there are thousands of them per run,
	while `Logger` captures no position at all and exactly one file under
	`src/` so much as mentions the type.

	So either the fault is test-shaped and of little consequence to a server,
	or it is a collector fault that lands on whichever structure is largest
	and merely meets that one first under utest. Those readings have very
	different consequences for a process meant to stay up for days, and
	nothing measured so far tells them apart.

	This is the experiment that does. It allocates and discards the way a game
	server does -- connections, entities arriving and leaving, messages of
	varied size, string-keyed lookups -- and deliberately generates **no**
	`PosInfos`: nothing here calls `trace`, `Timer.measure`, or an assertion
	library. Run it long. If it stays up, the fault is test-shaped and can be
	prioritised accordingly. If it falls over, the result is better still: a
	controlled reproducer owned by this repository, which is the thing every
	previous attempt on that bug has lacked.

	`SoakMain.exe [seconds] [clients]`, default one minute and sixteen
	clients. The exit status is the answer; the progress lines are so a long
	run can be watched.
**/
@:access(crossbyte.core.CrossByte)
class SoakMain {
	static inline var HOST:String = "127.0.0.1";
	static inline var PORT:Int = 18099;
	static inline var REPORT_EVERY:Float = 5.0;

	/** Roughly how a game's traffic is spread: mostly small, sometimes not. **/
	static var SIZES:Array<Int> = [12, 48, 200, 1400, 8000];

	static var seed:Int = 0x5bd1e995;

	public static function main():Void {
		var seconds:Float = arg(0, 60);
		var clients:Int = Std.int(arg(1, 16));

		Sys.println("soak: " + seconds + "s, " + clients + " clients, no PosInfos generated");

		var runtime = new CrossByte(true, DEFAULT, true);
		var accepted:Array<Socket> = [];
		var echoed:Int = 0;
		var bytesEchoed:Float = 0;

		var server = new ServerSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(event):Void {
			var peer:Socket = cast event.socket;
			accepted.push(peer);
			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				var data = new ByteArray();
				peer.readBytes(data, 0, peer.bytesAvailable);
				bytesEchoed += data.length;
				echoed++;
				peer.writeBytes(data);
				peer.flush();
			});
		});
		server.bind(PORT, HOST);
		server.listen();

		var senders:Array<Socket> = [];

		for (_ in 0...clients) {
			var socket = new Socket();
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				// Drained and dropped, the way a client consumes a reply.
				var sink = new ByteArray();
				socket.readBytes(sink, 0, socket.bytesAvailable);
			});
			socket.connect(HOST, PORT);
			senders.push(socket);
		}

		// The long-lived state a server keeps: entities by handle, sessions
		// by an opaque string. Both churn, and neither is a test double.
		var entities = new SlotMap<EntityState>(1024);
		var handles:Array<SlotHandle> = [];
		var sessions = new Map<String, SessionState>();
		var sessionKeys:Array<String> = [];

		var started:Float = Timer.stamp();
		var deadline:Float = started + seconds;
		var nextReport:Float = started + REPORT_EVERY;
		var ticks:Int = 0;
		var sent:Int = 0;

		while (Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			ticks++;

			for (_ in 0...40) {
				handles.push(entities.insert(new EntityState(next(), next())));
			}

			while (handles.length > 600) {
				entities.remove(handles.shift());
			}

			// String-keyed churn, because the structure the collector damages
			// under test is a string hash. Same shape, no PosInfos.
			for (_ in 0...20) {
				var key:String = "s" + next() + "-" + next();
				sessions.set(key, new SessionState(key, next()));
				sessionKeys.push(key);
			}

			while (sessionKeys.length > 400) {
				sessions.remove(sessionKeys.shift());
			}

			for (socket in senders) {
				if (socket.connected) {
					socket.writeBytes(payload(SIZES[next() % SIZES.length]));
					socket.flush();
					sent++;
				}
			}

			if (Timer.stamp() >= nextReport) {
				nextReport = Timer.stamp() + REPORT_EVERY;
				report(Timer.stamp() - started, ticks, sent, echoed, bytesEchoed, entities.length, sessionKeys.length);
			}

			Sys.sleep(0.001);
		}

		for (socket in senders) {
			closeQuietly(socket);
		}

		for (socket in accepted) {
			closeQuietly(socket);
		}

		try {
			server.close();
		} catch (_:Dynamic) {}

		report(Timer.stamp() - started, ticks, sent, echoed, bytesEchoed, entities.length, sessionKeys.length);
		Sys.println("soak: survived");
	}

	static function report(elapsed:Float, ticks:Int, sent:Int, echoed:Int, bytes:Float, entities:Int, sessions:Int):Void {
		var memory:String = "";

		#if cpp
		memory = " heap=" + Std.int(cpp.vm.Gc.memUsage() / 1024) + "kb";
		#end

		Sys.println("soak: " + Std.int(elapsed) + "s ticks=" + ticks + " sent=" + sent + " echoed=" + echoed + " mb="
			+ Std.int(bytes / 1048576) + " entities=" + entities + " sessions=" + sessions + memory);
	}

	/** A payload of the requested size; a fresh buffer each time, as a message is. **/
	static function payload(size:Int):ByteArray {
		var bytes = new ByteArray();

		for (i in 0...size) {
			bytes.writeByte((i + size) & 0xFF);
		}

		bytes.position = 0;
		return bytes;
	}

	/** Deterministic, so two runs allocate the same way. **/
	static function next():Int {
		seed = (seed * 1103515245 + 12345) & 0x3FFFFFFF;
		return seed;
	}

	static function arg(index:Int, fallback:Float):Float {
		var args = Sys.args();

		if (args.length <= index) {
			return fallback;
		}

		var value:Float = Std.parseFloat(args[index]);
		return Math.isNaN(value) || value <= 0 ? fallback : value;
	}

	static function closeQuietly(socket:Socket):Void {
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}
}

/** What a server keeps per entity: small, numerous, short lived. **/
private class EntityState {
	public var x:Float;
	public var y:Float;
	public var tags:Array<String>;

	public function new(x:Int, y:Int) {
		this.x = x % 4096;
		this.y = y % 4096;
		this.tags = ["live", "e" + (x & 0xFF)];
	}
}

/** And per session: longer lived, string keyed, holding a buffer. **/
private class SessionState {
	public var key:String;
	public var scratch:ByteArray;

	public function new(key:String, size:Int) {
		this.key = key;
		this.scratch = new ByteArray();
		this.scratch.length = 64 + (size % 512);
	}
}
