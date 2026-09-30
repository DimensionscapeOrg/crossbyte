package crossbyte._internal.http;

#if (sys && !eval)
import crossbyte._internal.socket.FlexSocket;
import sys.thread.Mutex;

/**
 * Idle HTTP/1.1 connections, by origin, kept for the next request to it.
 *
 * `Http` asked for `Connection: close` on every request, so each one paid for
 * a new TCP connection, and over `https` a new TLS handshake: a hundred calls
 * a second to one API were a hundred handshakes. Now a connection whose
 * response was read to its framed end, from a server that did not ask to
 * close, comes back here, and the next request to the same scheme, host and
 * port takes it.
 *
 * Shared by every thread: each `URLLoader` load runs on a worker of its own,
 * so the table is behind a lock, and a connection is only ever in one
 * request's hands or here, never both.
 *
 * A server closes an idle connection when it likes, so what comes back out is
 * checked: one idle past `idleSeconds` is closed rather than trusted, and one
 * with anything waiting on it -- all a server has to say to an idle
 * connection is that it is closing it -- is dropped. What is left can still
 * lose that race, so `Http` takes from here only for a request it may send
 * twice, and sends it again on a new connection if the reused one turns out
 * to be gone before any of the response arrives.
 *
 * Not on eval, where a write or read on a connection the peer has reset
 * raises a native error no Haxe catch can see.
 */
class HttpConnectionPool {
	/** Idle connections kept for one origin. */
	public static var maxIdlePerOrigin:Int = 6;

	/** Idle connections kept in all. */
	public static var maxIdle:Int = 64;

	/**
	 * How long a connection may sit idle and still be reused: under the
	 * five seconds common server defaults allow, so a server closing on its
	 * own timer is not raced for the last moment of it.
	 */
	public static var idleSeconds:Float = 4.0;

	@:noCompletion private static var __lock:Mutex = new Mutex();
	@:noCompletion private static var __idle:Map<String, Array<IdleConnection>> = new Map();
	@:noCompletion private static var __count:Int = 0;

	/**
		A live idle connection to `origin` opened under `tls`, taken out of the
		pool, or null. `tls` is compared with `HTTPTLSOptions.same`, null
		being the defaults: a connection that did not check its server, or that
		presented a client certificate, is never handed to a request that asked
		for something else.
	**/
	public static function take(origin:String, ?tls:crossbyte.http.HTTPTLSOptions):Null<FlexSocket> {
		var now:Float = haxe.Timer.stamp();
		while (true) {
			var candidate:Null<IdleConnection> = null;
			__lock.acquire();
			var list:Null<Array<IdleConnection>> = __idle.get(origin);
			if (list != null) {
				// The newest first, as before.
				var i:Int = list.length;
				while (i-- > 0) {
					if (crossbyte.http.HTTPTLSOptions.same(list[i].tls, tls)) {
						candidate = list[i];
						list.splice(i, 1);
						__count--;
						break;
					}
				}
			}
			__lock.release();

			if (candidate == null) {
				return null;
			}
			if (now - candidate.since < idleSeconds && __quiet(candidate.socket)) {
				return candidate.socket;
			}
			__closeQuietly(candidate.socket);
		}
	}

	/**
		Keeps `socket`, opened under `tls`, for the next request to `origin`
		under the same, or closes it if the pool is full.
	**/
	public static function put(origin:String, socket:FlexSocket, ?tls:crossbyte.http.HTTPTLSOptions):Void {
		var kept:Bool = false;
		var expired:Array<FlexSocket> = [];
		__lock.acquire();
		if (__count >= maxIdle) {
			// Full: first let go of what has sat too long, such as connections
			// to origins nobody has asked for since. At most maxIdle of them.
			__expire(haxe.Timer.stamp(), expired);
		}
		if (__count < maxIdle) {
			var list:Null<Array<IdleConnection>> = __idle.get(origin);
			if (list == null) {
				list = [];
				__idle.set(origin, list);
			}
			if (list.length < maxIdlePerOrigin) {
				list.push(new IdleConnection(socket, haxe.Timer.stamp(), tls));
				__count++;
				kept = true;
			}
		}
		__lock.release();

		for (old in expired) {
			__closeQuietly(old);
		}
		if (!kept) {
			__closeQuietly(socket);
		}
	}

	/** Moves every connection idle past `idleSeconds` into `into`. Under the lock. */
	@:noCompletion private static function __expire(now:Float, into:Array<FlexSocket>):Void {
		var emptied:Array<String> = [];
		for (origin => list in __idle) {
			var i:Int = list.length;
			while (i-- > 0) {
				if (now - list[i].since >= idleSeconds) {
					into.push(list[i].socket);
					list.splice(i, 1);
					__count--;
				}
			}
			if (list.length == 0) {
				emptied.push(origin);
			}
		}
		for (origin in emptied) {
			__idle.remove(origin);
		}
	}

	/** Closes every idle connection. */
	public static function clear():Void {
		__lock.acquire();
		var all:Map<String, Array<IdleConnection>> = __idle;
		__idle = new Map();
		__count = 0;
		__lock.release();

		for (list in all) {
			for (idle in list) {
				__closeQuietly(idle.socket);
			}
		}
	}

	/** Idle connections held right now. */
	public static function idleCount():Int {
		__lock.acquire();
		var count:Int = __count;
		__lock.release();
		return count;
	}

	/**
	 * Whether nothing is waiting to be read: an idle connection with bytes on
	 * it has been closed by its server, or is out of step with it.
	 */
	@:noCompletion private static function __quiet(socket:FlexSocket):Bool {
		try {
			var quiet:Bool = FlexSocket.select([socket], null, null, 0).read.length == 0;
			// The jvm's select leaves a channel non-blocking, and the client
			// reads blocking: a read on it would answer Blocked at once.
			socket.setBlocking(true);
			return quiet;
		} catch (_:Dynamic) {
			return false;
		}
	}

	@:noCompletion private static function __closeQuietly(socket:FlexSocket):Void {
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}
}

@:noCompletion private class IdleConnection {
	public final socket:FlexSocket;
	public final since:Float;

	/** What the connection was opened under, null being the defaults. */
	public final tls:Null<crossbyte.http.HTTPTLSOptions>;

	public function new(socket:FlexSocket, since:Float, tls:Null<crossbyte.http.HTTPTLSOptions>) {
		this.socket = socket;
		this.since = since;
		this.tls = tls;
	}
}
#end
