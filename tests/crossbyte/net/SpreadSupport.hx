package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
#if target.threaded
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Thread;
#end

using StringTools;

#if target.threaded
/**
	Runtimes and blocking clients for the spread tests, shared by the
	`ServerSocket`, `ServerWebSocket` and `HTTPServer` cases.
**/
@:access(crossbyte.core.CrossByte)
class SpreadSupport {
	/** A child runtime with a POLL loop, running by the time this returns. **/
	public static function runtime(tps:Int = 60):CrossByte {
		var started:Lock = new Lock();
		var made:CrossByte = CrossByte.make(POLL, HEAP, configured -> {
			configured.tps = tps;
			configured.addEventListener(Event.INIT, _ -> started.release());
		});
		started.wait(WAIT_LONG);
		return made;
	}

	private static inline var WAIT_LONG:Float = 10.0;

	/** Runs `work` on `runtime`'s thread and answers what it returned; rethrows what it threw. **/
	public static function on<T>(runtime:CrossByte, work:Void->T):T {
		var done:Lock = new Lock();
		var result:Null<T> = null;
		var failure:Dynamic = null;
		var failed:Bool = false;
		var posted:Bool = runtime.post(() -> {
			try {
				result = work();
			} catch (error:Dynamic) {
				failure = error;
				failed = true;
			}
			done.release();
		});
		if (!posted || !done.wait(WAIT_LONG)) {
			throw "the runtime did not run what it was handed";
		}
		if (failed) {
			throw failure;
		}
		return result;
	}

	/** Whether `reusePort` should be taken here: Linux, natively or on a Java of 9 or later. **/
	public static function reusePortExpected():Bool {
		#if cpp
		return Sys.systemName() == "Linux";
		#elseif (java || jvm)
		var version:String = java.lang.System.getProperty("java.specification.version");
		var major:Null<Int> = version.indexOf("1.") == 0 ? 8 : Std.parseInt(version);
		return Sys.systemName() == "Linux" && major != null && major >= 9;
		#else
		return false;
		#end
	}

	/** Exits each runtime and waits until it has. **/
	public static function stop(runtimes:Array<CrossByte>):Void {
		for (runtime in runtimes) {
			runtime.exit();
		}
		for (runtime in runtimes) {
			waitFor(() -> runtime.__didExit, WAIT_LONG);
		}
	}

	/** "own" on `runtime`'s own thread with it current, otherwise where it is. **/
	public static function where(runtime:CrossByte):String {
		var current:Null<CrossByte> = CrossByte.__currentOrNull();
		if (current == runtime && Thread.current() == runtime.__ownerThread) {
			return "own";
		}
		return current == null ? "none" : "other";
	}

	public static function pop<T>(queue:Deque<T>, timeout:Float):Null<T> {
		var deadline:Float = haxe.Timer.stamp() + timeout;
		while (true) {
			var item:Null<T> = queue.pop(false);
			if (item != null) {
				return item;
			}
			if (haxe.Timer.stamp() >= deadline) {
				return null;
			}
			crossbyte.sys.System.sleep(0.002);
		}
	}

	public static function waitFor(condition:Void->Bool, timeout:Float):Bool {
		var deadline:Float = haxe.Timer.stamp() + timeout;
		while (!condition()) {
			if (haxe.Timer.stamp() >= deadline) {
				return false;
			}
			crossbyte.sys.System.sleep(0.005);
		}
		return true;
	}

	/** A blocking client, connected, reads bounded by the wait. **/
	public static function connect(port:Int):sys.net.Socket {
		var client:sys.net.Socket = new sys.net.Socket();
		client.connect(new sys.net.Host("127.0.0.1"), port);
		client.setTimeout(WAIT_LONG);
		return client;
	}

	/** Exactly `count` bytes from `client`, as text, or what came before it ended. **/
	public static function read(client:sys.net.Socket, count:Int):String {
		var buffer:haxe.io.Bytes = haxe.io.Bytes.alloc(count);
		var got:Int = 0;
		try {
			while (got < count) {
				var n:Int = client.input.readBytes(buffer, got, count - got);
				if (n <= 0) {
					break;
				}
				got += n;
			}
		} catch (_:Dynamic) {}
		return buffer.sub(0, got).toString();
	}

	/** Whether the server closed `client`'s connection: its read ends. **/
	public static function ended(client:sys.net.Socket):Bool {
		var one:haxe.io.Bytes = haxe.io.Bytes.alloc(1);
		try {
			client.input.readBytes(one, 0, 1);
			return false;
		} catch (_:haxe.io.Eof) {
			return true;
		} catch (error:haxe.io.Error) {
			// A reset is an end too; a timeout is not.
			return !Std.string(error).toLowerCase().contains("timeout") && !Std.string(error).toLowerCase().contains("blocked");
		} catch (error:Dynamic) {
			var text:String = Std.string(error).toLowerCase();
			return !text.contains("timeout") && !text.contains("blocked") && !text.contains("timed out");
		}
	}

	public static function closeAll(clients:Array<sys.net.Socket>):Void {
		for (client in clients) {
			try {
				client.close();
			} catch (_:Dynamic) {}
		}
	}

	/** Closes each announced connection, from here: handed to its runtime. **/
	public static function closeArrivals(arrivals:Array<Arrival>):Void {
		for (arrival in arrivals) {
			try {
				if (arrival.socket.connected) {
					arrival.socket.close();
				}
			} catch (_:Dynamic) {}
		}
	}

	#if (cpp || java || jvm)
	/** A TLS client from this thread: connects, sends `send`, answers what came back. **/
	public static function tlsExchange(port:Int, trusted:Certificate, send:String):Null<String> {
		#if cpp
		var client:sys.ssl.Socket = new sys.ssl.Socket();
		client.verifyCert = false;
		client.setTimeout(WAIT_LONG);
		try {
			client.connect(new sys.net.Host("127.0.0.1"), port);
			client.output.writeString(send);
			client.output.flush();
			var reply:String = read(client, send.length);
			client.close();
			return reply;
		} catch (error:Dynamic) {
			try {
				client.close();
			} catch (_:Dynamic) {}
			return "failed: " + Std.string(error);
		}
		#else
		return JvmTlsPeer.exchange("127.0.0.1", port, trusted, send);
		#end
	}
	#end
}
#end
