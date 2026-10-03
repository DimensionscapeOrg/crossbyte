package crossbyte.net._internal;

// Not built for the browser or Node: a server is spread over runtimes on
// threads of their own, which neither has.
#if (!js && target.threaded)
import crossbyte.core.CrossByte;
import crossbyte.net.ServerSocket;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Mutex;

/**
	A server spread over several runtimes: what its front -- the server the
	application made, whose listener stays on the runtime that called
	`listen()` -- shares with the replicas it made, one per runtime, that
	serve the connections handed to them.

	A replica is an instance of the server's own class, made without a
	listener of its own (see `ServerSocket.__replicate`), so each runtime's
	connections are kept, timed and swept by the same code that keeps a
	server's connections on one runtime, in state no other thread touches.
	What the runtimes do share is here, behind one lock: the handshakes in
	flight that `maxPendingHandshakes` bounds, wherever they are; the
	connections an `HTTPServer` counts against `maxConnections`; and whether
	the front has stopped, so a connection still on its way to a runtime is
	closed as it arrives rather than served.

	Each figure changes once per connection, never per message, so a lock
	costs nothing worth measuring; a server on one runtime makes none of
	this.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.net.ServerSocket)
@:noCompletion
class ServerSpread {
	/** The server the application made, listening on its own runtime. **/
	public final front:ServerSocket;

	/** The runtimes connections are served on, in the order given. **/
	public final runtimes:Array<CrossByte>;

	/** One replica per runtime, at the same index. **/
	public final replicas:Array<ServerSocket>;

	/** Whether the runtimes were made for the server, which exits them. **/
	public final owned:Bool;

	@:noCompletion private final __lock:Mutex = new Mutex();

	// The next runtime in turn. Read and moved on the front's runtime alone.
	@:noCompletion private var __next:Int = 0;

	// Handshakes under way across every runtime, and those handed off and
	// not yet taken up; see ServerSocket.__publishPending.
	@:noCompletion private var __inFlight:Int = 0;

	// The servers that set their listener aside at maxPendingHandshakes, and
	// so have to be told when there is room again: the front, or with
	// reusePort the replicas, each of which listens for itself.
	@:noCompletion private var __parked:Array<ServerSocket> = [];

	// Connections an HTTPServer is serving, across every runtime.
	@:noCompletion private var __connections:Int = 0;

	// Whether the front has stopped accepting: a connection arriving at a
	// runtime after this is closed there.
	@:noCompletion private var __stopped:Bool = false;

	// Whether a connection has been refused for want of a live runtime, so
	// that is said once rather than for every one.
	@:noCompletion private var __refusalSaid:Bool = false;

	public function new(front:ServerSocket, runtimes:Array<CrossByte>, owned:Bool) {
		this.front = front;
		this.runtimes = runtimes;
		this.owned = owned;
		replicas = [];
	}

	/**
		Whether `runtime` can still be handed a connection: it is running,
		and its post queue is open.
	**/
	public static inline function isLive(runtime:CrossByte):Bool {
		return runtime != null && runtime.__getRunning() && !runtime.__postClosed;
	}

	/**
		Hands `socket`, just accepted on the front's runtime, to the runtime
		`selectRuntime` names or to the next live one in turn. False when no
		runtime would take it, which leaves the socket to the caller to close.
		A `selectRuntime` that throws refuses the connection, as `admit` does.
	**/
	public function handOff(socket:Socket, peer:{host:Host, port:Int}, address:String):Bool {
		var chosen:Int = -1;
		try {
			var asked:Null<CrossByte> = front.selectRuntime(address, peer.port);
			if (asked != null) {
				chosen = runtimes.indexOf(asked);
			}
		} catch (_:Dynamic) {
			return false;
		}

		// The runtime asked for, if it is live; then each in turn, starting
		// from the next. One that has exited, or exits between the check and
		// the post, is passed over.
		if (chosen >= 0 && __handTo(chosen, socket, peer)) {
			return true;
		}

		var count:Int = replicas.length;
		for (_ in 0...count) {
			var index:Int = __next;
			__next = (__next + 1) % count;
			if (index != chosen && __handTo(index, socket, peer)) {
				return true;
			}
		}

		__sayRefused();
		return false;
	}

	@:noCompletion private function __handTo(index:Int, socket:Socket, peer:{host:Host, port:Int}):Bool {
		var runtime:CrossByte = runtimes[index];
		if (!isLive(runtime)) {
			return false;
		}
		var replica:ServerSocket = replicas[index];
		return runtime.post(() -> replica.__adopt(socket, peer));
	}

	@:noCompletion private function __sayRefused():Void {
		if (__refusalSaid) {
			return;
		}
		__refusalSaid = true;
		crossbyte.utils.Logger.warn("Every runtime the server on port " + front.localPort
			+ " spreads its connections over has exited, so each connection it accepts is closed: see ServerSocket.runtimes.");
	}

	/**
		Runs `work` on each replica's runtime, with that replica. A runtime
		that has exited is passed over, and `skipped` called for it instead,
		on this thread.
	**/
	public function each(work:ServerSocket->Void, ?skipped:ServerSocket->Void):Void {
		for (i in 0...replicas.length) {
			var replica:ServerSocket = replicas[i];
			var runtime:CrossByte = runtimes[i];
			if (!runtime.post(() -> work(replica)) && skipped != null) {
				skipped(replica);
			}
		}
	}

	/**
		Marks the front stopped and tells every runtime, which drops what it
		has still handshaking. Whatever is on its way to one is closed as it
		arrives.
	**/
	public function stop():Void {
		__lock.acquire();
		var already:Bool = __stopped;
		__stopped = true;
		__lock.release();
		if (!already) {
			each(replica -> replica.__stopReplica());
		}
	}

	/**
		As `stop`, and then each replica is closed as its front was: the
		servers built on `ServerSocket` let go of what they hold per runtime
		there, an HTTPServer its PHP bridge. Connections already served stay
		open, as on one runtime.
	**/
	public function close():Void {
		stop();
		each(replica -> {
			try {
				replica.close();
			} catch (_:Dynamic) {}
		});
	}

	public var stopped(get, never):Bool;

	@:noCompletion private function get_stopped():Bool {
		__lock.acquire();
		var value:Bool = __stopped;
		__lock.release();
		return value;
	}

	/** Handshakes under way, and handed off and not yet taken up. **/
	public var inFlight(get, never):Int;

	@:noCompletion private function get_inFlight():Int {
		__lock.acquire();
		var value:Int = __inFlight;
		__lock.release();
		return value;
	}

	/**
		Changes the handshakes in flight by `delta`. Once there is room under
		`limit` again, each server that set its listener aside is asked, on
		its own runtime, to put it back.
	**/
	public function addInFlight(delta:Int, limit:Int):Void {
		__lock.acquire();
		__inFlight += delta;
		if (__inFlight < 0) {
			__inFlight = 0;
		}
		var woken:Array<ServerSocket> = null;
		if (__parked.length > 0 && (limit < 0 || __inFlight < limit)) {
			woken = __parked;
			__parked = [];
		}
		__lock.release();

		if (woken != null) {
			for (server in woken) {
				var runtime:Null<CrossByte> = server.__cbInstance;
				if (runtime != null) {
					runtime.post(server.__syncListenerWatch);
				}
			}
		}
	}

	/**
		Whether as many handshakes are in flight as `limit` allows. If so,
		`server` is noted as having set its listener aside in the same step,
		so the change that makes room cannot be missed.
	**/
	public function parkIfFull(limit:Int, server:ServerSocket):Bool {
		if (limit < 0) {
			return false;
		}
		__lock.acquire();
		var full:Bool = __inFlight >= limit;
		if (full && __parked.indexOf(server) < 0) {
			__parked.push(server);
		}
		__lock.release();
		return full;
	}

	/** Connections being served across every runtime: an HTTPServer's count. **/
	public var connections(get, never):Int;

	@:noCompletion private function get_connections():Int {
		__lock.acquire();
		var value:Int = __connections;
		__lock.release();
		return value;
	}

	/**
		Counts one more connection, unless `limit` are already counted:
		whether it was counted. Checked and counted in one step, so two
		runtimes cannot both take the last place.
	**/
	public function claimConnection(limit:Int):Bool {
		__lock.acquire();
		var room:Bool = __connections < limit;
		if (room) {
			__connections++;
		}
		__lock.release();
		return room;
	}

	/** Counts `count` connections fewer. **/
	public function releaseConnections(count:Int):Void {
		if (count <= 0) {
			return;
		}
		__lock.acquire();
		__connections -= count;
		if (__connections < 0) {
			__connections = 0;
		}
		__lock.release();
	}

	/** Exits the runtimes made for the server; given ones are left alone. **/
	public function exitOwned():Void {
		if (!owned) {
			return;
		}
		for (runtime in runtimes) {
			runtime.exit();
		}
	}
}
#end
