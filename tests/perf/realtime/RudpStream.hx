import crossbyte.core.HostApplication;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import haxe.Timer;

/**
	A STREAM-mode reliable UDP session over loopback, in one process: the
	client writes `mb` megabytes and flushes; the server's reader waits for
	all of it before reading (as a reader waiting for a whole message does).
	Process CPU and wall time for the transfer, best of `samples`.

	Arguments: mb (4), samples (3), label. Pinned to CPUs 24-27.
**/
class RudpStream extends HostApplication {
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
		new RudpStream().run();
	}

	var last:Float = 0;

	function new() {
		super();
	}

	function pump():Void {
		var now = Timer.stamp();
		advance(now - last, 0.001);
		last = now;
	}

	function run():Void {
		var bytes = optInt("mb", 4) * 1024 * 1024;
		var samples = optInt("samples", 3);
		var best = Math.POSITIVE_INFINITY;
		var bestWall = 0.0;
		for (_ in 0...samples) {
			var server = new ReliableDatagramServerSocket();
			server.socketMode = STREAM;
			var accepted:ReliableDatagramSocket = null;
			var done = false;
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
				accepted = e.socket;
				accepted.addEventListener(ProgressEvent.SOCKET_DATA, function(_:ProgressEvent):Void {
					if (accepted.bytesAvailable >= bytes) {
						var sink = new ByteArray();
						accepted.readBytes(sink, 0, bytes);
						done = true;
					}
				});
			});
			server.bind(0, "127.0.0.1");
			server.listen();
			var client = new ReliableDatagramSocket();
			client.mode = STREAM;
			// Four megabytes written at once wait for the window: past the
			// default cap on what may wait.
			client.maxOutputBufferSize = 0;
			var connected = false;
			client.addEventListener(Event.CONNECT, _ -> connected = true);
			last = Timer.stamp();
			client.connect("127.0.0.1", server.localPort);
			var deadline = Timer.stamp() + 10;
			while ((!connected || accepted == null) && Timer.stamp() < deadline) {
				pump();
			}
			var chunk = new ByteArray();
			for (i in 0...65536) {
				chunk.writeByte(i & 0xFF);
			}
			var u0 = PerfCpu.user() + PerfCpu.kernel();
			var w0 = Timer.stamp();
			var written = 0;
			while (written < bytes) {
				client.writeBytes(chunk, 0, 65536);
				written += 65536;
			}
			client.flush();
			deadline = Timer.stamp() + 120;
			while (!done && Timer.stamp() < deadline) {
				pump();
			}
			var cpu = PerfCpu.user() + PerfCpu.kernel() - u0;
			var wall = Timer.stamp() - w0;
			if (!done) {
				Sys.println("timed out");
			}
			if (cpu < best) {
				best = cpu;
				bestWall = wall;
			}
			client.abort();
			server.close();
		}
		Sys.println('STREAM label=${opts.exists("label") ? opts.get("label") : ""} bytes=$bytes cpu best=${Math.round(best * 1000)}ms '
			+ 'wall=${Math.round(bestWall * 1000)}ms cpuPerMB=${Math.round(best / (bytes / 1048576) * 1000)}ms');
		Sys.exit(0);
	}
}
