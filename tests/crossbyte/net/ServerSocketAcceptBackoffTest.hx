package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
#if target.threaded
import sys.thread.Lock;
#end

/**
	A listener whose accept fails (the process out of descriptors) is
	set aside for a short, growing while rather than polled on every pass.

	It stays readable, since the connection it could not take is still
	queued, and a POLL loop polling it would spin: tens of thousands of
	failed accepts a second at a whole core, and nothing else served. The
	failures are made here two ways: by a server whose accept is made to
	fail, on every threaded target, and natively on Linux and macOS by the
	real thing, the process's descriptor limit lowered until an accept
	cannot have one.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.net.ServerSocket)
class ServerSocketAcceptBackoffTest extends utest.Test {
	#if (target.threaded && (cpp || java || jvm || eval || neko || hl))
	/**
		For a second of accepts that fail, the server asks a handful of times
		(5 ms, then twice as long each time) and the loop sleeps between;
		once the system hands connections over again, the waiting one is
		taken within the longest wait. It is reported once, and counted
		every time.
	**/
	@:timeout(30000)
	public function testAFailingAcceptSetsTheListenerAside():Void {
		__setAside(false);
	}

	/** The same for a `ServerWebSocket`, whose accept loop is its own. **/
	@:timeout(30000)
	public function testAWebSocketServersFailingAcceptSetsItsListenerAside():Void {
		__setAside(true);
	}

	/**
		Closed while its listener is set aside, a server stays closed: the
		timer that would have brought the listener back does nothing.
	**/
	@:timeout(30000)
	public function testAServerClosedWhileSetAsideStaysClosed():Void {
		var started:Lock = new Lock();
		var server:FailingServer = null;
		var port:Int = 0;
		var child:CrossByte = CrossByte.make(POLL, HEAP, configured -> {
			configured.addEventListener(Event.INIT, _ -> {
				server = new FailingServer();
				server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> {});
				server.addEventListener(IOErrorEvent.IO_ERROR, _ -> {});
				server.bind(0, "127.0.0.1");
				server.listen();
				port = server.localPort;
				started.release();
			});
		});
		var client:sys.net.Socket = null;
		if (started.wait(5.0)) {
			client = new sys.net.Socket();
			client.connect(new sys.net.Host("127.0.0.1"), port);
			__waitFor(() -> server.attempts > 0, 3.0);
			// Closed on its own thread while set aside, then given a second
			// and a half, past the longest wait.
			var closed:Lock = new Lock();
			child.post(() -> {
				server.close();
				closed.release();
			});
			closed.wait(5.0);
			crossbyte.sys.System.sleep(1.5);
		}
		var attemptsAfterClose:Int = server == null ? -1 : server.attemptsAfterClose;
		var watched:Bool = server != null && server.__pollRuntime != null;
		var timer:Int = server == null ? -1 : server.__acceptResumeTimer;
		__stop(child, () -> {});
		if (client != null) {
			try client.close() catch (_:Dynamic) {}
		}
		Assert.notNull(server, "the server never started");
		Assert.equals(0, attemptsAfterClose, "a closed server went on accepting");
		Assert.isFalse(watched, "a closed server's listener was polled again");
		Assert.equals(-1, timer, "a closed server kept the timer that brings its listener back");
	}

	private static function __setAside(web:Bool):Void {
		var started:Lock = new Lock();
		var server:Null<FailingAccept> = null;
		var port:Int = 0;
		var accepted:Int = 0;
		var reported:Int = 0;
		var child:CrossByte = CrossByte.make(POLL, HEAP, configured -> {
			configured.addEventListener(Event.INIT, _ -> {
				var made:ServerSocket = web ? new FailingWebServer() : new FailingServer();
				server = cast made;
				made.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> accepted++);
				made.addEventListener(IOErrorEvent.IO_ERROR, _ -> reported++);
				made.bind(0, "127.0.0.1");
				made.listen();
				port = made.localPort;
				started.release();
			});
		});

		var client:sys.net.Socket = null;
		var attempts:Int = -1;
		var failures:Int = -1;
		var cpu:Float = 0;
		var waited:Float = -1;
		var taken:Int = 0;
		if (started.wait(5.0)) {
			client = new sys.net.Socket();
			client.connect(new sys.net.Host("127.0.0.1"), port);
			__waitFor(() -> server.failedAttempts() > 0, 3.0);
			var cpuBefore:Float = Sys.cpuTime();
			var counted:Int = server.failedAttempts();
			crossbyte.sys.System.sleep(1.0);
			attempts = server.failedAttempts() - counted;
			cpu = Sys.cpuTime() - cpuBefore;
			failures = (cast server : ServerSocket).acceptFailures;

			// Descriptors again: the connection waiting is taken.
			child.post(() -> server.stopFailing());
			var from:Float = haxe.Timer.stamp();
			// Taken from the queue: a ServerWebSocket announces one only once
			// it has upgraded, and this client sends nothing.
			__waitFor(() -> server.takenConnections() > 0, 3.0);
			waited = haxe.Timer.stamp() - from;
			taken = server.takenConnections();
		}

		var total:Int = server == null ? 0 : server.failedAttempts();
		__stop(child, () -> {
			if (server != null) {
				try (cast server : ServerSocket).close() catch (_:Dynamic) {}
			}
		});
		if (client != null) {
			try client.close() catch (_:Dynamic) {}
		}

		Assert.notNull(server, "the server never started");
		// 5, 10, 20 ... 640 ms: about eight in the second. Polled on every
		// pass, it would be thousands.
		Assert.isTrue(attempts >= 1 && attempts <= 20, "the server tried " + attempts + " accepts in a second of failing ones");
		Assert.equals(total, failures, "acceptFailures did not count every failed accept");
		Assert.equals(1, reported, "a run of failed accepts was reported " + reported + " times");
		Assert.equals(1, taken, "the waiting connection was not taken once accepts worked again");
		if (!web) {
			Assert.equals(1, accepted, "the connection taken was not announced");
		}
		Assert.isTrue(waited >= 0 && waited < 2.0, "the waiting connection was taken " + waited + " s after accepts worked again");
		#if cpp
		// Sys.cpuTime is the process's processor time natively, and the loop
		// sleeps between tries: a spinning one would spend the whole second.
		Assert.isTrue(cpu < 0.5, "the process spent " + cpu + " s of processor time in a second of failed accepts");
		#end
	}

	#if (cpp && !windows)
	/**
		The real thing, natively on Linux and macOS: the process's descriptor
		limit lowered until an accept cannot have one.

		On Linux the connections wait in the kernel's queue and the listener
		stays readable: the server sets it aside rather than spin, and once
		descriptors are let go of, a waiting connection is taken. macOS
		instead drops each connection whose accept found no descriptor, so
		its listener goes quiet after one failure a connection and nothing
		waits. There the failures are counted, nothing spins, and a client
		connecting once descriptors are free is taken.
	**/
	@:timeout(30000)
	public function testOutOfDescriptorsAServerWaitsThenServes():Void {
		var original:Int = crossbyte._internal.socket.NativeSocketOptions.descriptorLimit();
		var started:Lock = new Lock();
		var server:ServerSocket = null;
		var port:Int = 0;
		var accepted:Int = 0;
		var child:CrossByte = CrossByte.make(POLL, HEAP, configured -> {
			configured.addEventListener(Event.INIT, _ -> {
				server = new ServerSocket();
				server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> {
					accepted++;
				});
				server.addEventListener(IOErrorEvent.IO_ERROR, _ -> {});
				server.bind(0, "127.0.0.1");
				server.listen();
				port = server.localPort;
				started.release();
			});
		});

		var ballast:Array<sys.net.Socket> = [];
		var clients:Array<sys.net.Socket> = [];
		var attempts:Int = -1;
		var failures:Int = 0;
		var cpu:Float = 0;
		var lowered:Bool = false;
		if (started.wait(5.0)) {
			// Two to let go of and four clients made first (each a descriptor),
			// then the limit lowered to what is open, so connecting them takes
			// nothing and the accept of each finds no descriptor. Made before the
			// limit, so other threads opening or closing descriptors meanwhile
			// (late in a full suite there are some) cannot leave the server room
			// it should not have.
			for (_ in 0...2) {
				ballast.push(new sys.net.Socket());
			}
			for (_ in 0...4) {
				clients.push(new sys.net.Socket());
			}
			var open:Int = __openDescriptors();
			// Less the one the directory listing itself held while it counted.
			lowered = open > 1 && crossbyte._internal.socket.NativeSocketOptions.setDescriptorLimit(open - 1);
			if (lowered) {
				// The limit bounds descriptor numbers, not how many are open:
				// one closed earlier in the suite leaves a hole below it, and
				// the accept takes that.
				// Take every number left, so the condition is made, not assumed.
				// Natively a socket made with none left throws: caught, since
				// escaping here would leave the limit lowered for every later
				// test, and could hang one.
				try {
					for (_ in 0...65536) {
						var filler = new sys.net.Socket();
						if (@:privateAccess filler.__s == null) {
							break;
						}
						ballast.push(filler);
					}
				} catch (_:Dynamic) {}
				try {
					for (client in clients) {
						client.connect(new sys.net.Host("127.0.0.1"), port);
					}
				} catch (_:Dynamic) {}
				__waitFor(() -> server.acceptFailures > 0, 3.0);
				var cpuBefore:Float = Sys.cpuTime();
				var before:Int = server.acceptFailures;
				crossbyte.sys.System.sleep(1.0);
				attempts = server.acceptFailures - before;
				cpu = Sys.cpuTime() - cpuBefore;
				failures = server.acceptFailures;
				for (socket in ballast) {
					try socket.close() catch (_:Dynamic) {}
				}
				#if !mac
				__waitFor(() -> accepted >= 1, 3.0);
				#end
			}
		}

		crossbyte._internal.socket.NativeSocketOptions.setDescriptorLimit(original);
		#if mac
		if (lowered) {
			// macOS drops the connections it could not hand over: one made now
			// shows the server serving again.
			var late = new sys.net.Socket();
			try {
				late.connect(new sys.net.Host("127.0.0.1"), port);
				clients.push(late);
			} catch (_:Dynamic) {}
			__waitFor(() -> accepted >= 1, 3.0);
		}
		#end
		__stop(child, () -> {
			if (server != null) {
				try server.close() catch (_:Dynamic) {}
			}
		});
		for (client in clients) {
			try client.close() catch (_:Dynamic) {}
		}

		Assert.isTrue(lowered, "the descriptor limit could not be lowered");
		#if mac
		Assert.isTrue(failures >= 1, "no accept failed out of descriptors");
		Assert.isTrue(attempts <= 20, "the server tried " + attempts + " accepts in a second out of descriptors");
		#else
		Assert.isTrue(attempts >= 1 && attempts <= 20, "the server tried " + attempts + " accepts in a second out of descriptors");
		#end
		Assert.isTrue(cpu < 0.5, "the process spent " + cpu + " s of processor time in a second out of descriptors");
		Assert.isTrue(accepted >= 1, "nothing was taken once descriptors were let go of");
	}

	/**
		As the process starts its soft limit on descriptors is raised to the
		hard one (on macOS no higher than `OPEN_MAX`), as Go and the JVM do: a
		shell's soft limit of 1,024 would stop a server near a thousand
		connections.
	**/
	public function testTheDescriptorLimitIsRaisedAsTheProcessStarts():Void {
		var soft:Int = crossbyte._internal.socket.NativeSocketOptions.descriptorLimit();
		var hard:Int = crossbyte._internal.socket.NativeSocketOptions.descriptorHardLimit();
		#if crossbyte_keep_nofile
		Assert.isTrue(soft > 0);
		#else
		#if mac
		Assert.isTrue(soft == hard || soft >= 10240, "the soft limit is " + soft + " of a hard limit of " + hard);
		#else
		Assert.equals(hard, soft, "the soft limit is " + soft + " of a hard limit of " + hard);
		#end
		#end
	}

	private static function __openDescriptors():Int {
		for (dir in ["/proc/self/fd", "/dev/fd"]) {
			try {
				return sys.FileSystem.readDirectory(dir).length;
			} catch (_:Dynamic) {}
		}
		return -1;
	}
	#end

	private static function __waitFor(done:Void->Bool, timeout:Float):Void {
		var deadline:Float = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.005);
		}
	}

	/** Runs `cleanup` on the child's thread, then stops it. **/
	private static function __stop(child:CrossByte, cleanup:Void->Void):Void {
		var cleaned:Lock = new Lock();
		if (child.post(() -> {
			cleanup();
			cleaned.release();
		})) {
			cleaned.wait(5.0);
		}
		child.exit();
	}
	#end
}

#if (target.threaded && (cpp || java || jvm || eval || neko || hl))
/** A server whose accepts fail the way a process out of descriptors makes them. **/
private interface FailingAccept {
	public function failedAttempts():Int;
	public function takenConnections():Int;
	public function stopFailing():Void;
}

@:access(crossbyte.net.ServerSocket)
private class FailingServer extends ServerSocket implements FailingAccept {
	public var attempts:Int = 0;
	public var attemptsAfterClose:Int = 0;
	public var taken:Int = 0;
	public var failing:Bool = true;

	public function new() {
		super(false);
	}

	public function failedAttempts():Int {
		return attempts;
	}

	public function takenConnections():Int {
		return taken;
	}

	public function stopFailing():Void {
		failing = false;
	}

	override private function __takeConnection():sys.net.Socket {
		if (failing) {
			attempts++;
			if (__closed) {
				attemptsAfterClose++;
			}
			// What hxcpp throws for EMFILE: a failure, not a would-block.
			throw "Socket operation failed";
		}
		var socket = super.__takeConnection();
		taken++;
		return socket;
	}
}

@:access(crossbyte.net.ServerSocket)
private class FailingWebServer extends ServerWebSocket implements FailingAccept {
	public var attempts:Int = 0;
	public var taken:Int = 0;
	public var failing:Bool = true;

	public function new() {
		super(false);
	}

	public function failedAttempts():Int {
		return attempts;
	}

	public function takenConnections():Int {
		return taken;
	}

	public function stopFailing():Void {
		failing = false;
	}

	override private function __takeConnection():sys.net.Socket {
		if (failing) {
			attempts++;
			throw "Socket operation failed";
		}
		var socket = super.__takeConnection();
		taken++;
		return socket;
	}
}
#end
