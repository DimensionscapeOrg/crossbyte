package crossbyte.net;

#if (cpp || hxcpp || java || jvm || hl || neko)
import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Deque;
import sys.thread.Thread;
#end
import utest.Assert;

/**
	`select` from two threads at once answers each for its own sockets.

	Every runtime selects on its own thread, once a tick. Descriptor sets
	built for every thread in one static buffer would have two runtimes on
	two threads write their sets over each other's: `select` would fail
	with "Error while waiting on socket", and a set read back from under
	the other thread's write would answer for the wrong sockets.
**/
class SocketSelectThreadsTest extends utest.Test {
	#if (cpp || hxcpp || java || jvm || hl || neko)
	static inline var LOOPBACK:String = "127.0.0.1";

	public function testTwoThreadsSelectingAtOnceEachSeeOnlyTheirOwn():Void {
		var results = new Deque<String>();
		// Different sizes, so the two threads' sets never coincide.
		for (size in [3, 7]) {
			Thread.create(() -> results.add(selectRepeatedly(size, 1.0)));
		}

		// Polled with a deadline rather than a blocking pop, so a thread that
		// never answers fails this case instead of stopping the suite.
		var reports:Array<String> = [];
		var deadline = haxe.Timer.stamp() + 15.0;
		while (reports.length < 2 && haxe.Timer.stamp() < deadline) {
			var report = results.pop(false);
			if (report != null) {
				reports.push(report);
			} else {
				crossbyte.sys.System.sleep(0.01);
			}
		}

		Assert.equals(2, reports.length, "a selecting thread never finished");
		for (report in reports) {
			Assert.equals("ok", report.substr(0, 2), report);
		}
	}

	/**
		Holds `count` connections each with a byte waiting, so every select this
		thread makes should answer exactly them, and selects for `seconds`.
		"ok ..." when every answer was right, what went wrong otherwise.
	**/
	static function selectRepeatedly(count:Int, seconds:Float):String {
		var listener = new Socket();
		var clients:Array<Socket> = [];
		var readers:Array<Socket> = [];

		try {
			listener.bind(new Host(LOOPBACK), 0);
			listener.listen(count);
			for (_ in 0...count) {
				var client = new Socket();
				client.connect(new Host(LOOPBACK), listener.host().port);
				clients.push(client);
				readers.push(listener.accept());
			}
			for (client in clients) {
				client.output.writeByte(1);
				client.output.flush();
			}

			// Until every byte has arrived, so from here each answer is known.
			var deadline = haxe.Timer.stamp() + 5.0;
			while (Socket.select(readers, null, null, 0.05).read.length < count) {
				if (haxe.Timer.stamp() > deadline) {
					return "the bytes never arrived";
				}
			}
		} catch (e:Dynamic) {
			closeAll(readers.concat(clients).concat([listener]));
			return "could not set up: " + Std.string(e);
		}

		var selects:Int = 0;
		var wrong:Int = 0;
		var failed:Int = 0;
		var firstProblem:String = null;
		var end = haxe.Timer.stamp() + seconds;

		while (haxe.Timer.stamp() < end) {
			selects++;
			try {
				var ready = Socket.select(readers, null, null, 0).read;
				var right = ready.length == count;
				for (socket in ready) {
					if (readers.indexOf(socket) < 0) {
						right = false;
					}
				}
				if (!right) {
					wrong++;
					if (firstProblem == null) {
						firstProblem = ready.length + " of " + count + " answered";
					}
				}
			} catch (e:Dynamic) {
				failed++;
				if (firstProblem == null) {
					firstProblem = Std.string(e);
				}
			}
		}

		closeAll(readers.concat(clients).concat([listener]));

		var summary = '$selects selects over $count sockets, $wrong wrong, $failed failed';
		return (wrong == 0 && failed == 0) ? "ok: " + summary : summary + "; first: " + firstProblem;
	}

	static function closeAll(sockets:Array<Socket>):Void {
		for (socket in sockets) {
			try socket.close() catch (_:Dynamic) {}
		}
	}
	#end
}
