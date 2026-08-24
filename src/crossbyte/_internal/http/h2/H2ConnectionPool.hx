package crossbyte._internal.http.h2;

#if !js
import sys.thread.Mutex;

/**
 * Live HTTP/2 sessions, keyed by origin.
 *
 * A connection per request throws away most of what HTTP/2 offers: the TCP and
 * TLS handshakes are paid again every time, the HPACK dynamic table starts
 * empty so every header is sent in full, and the congestion window restarts
 * from cold. Reuse is what makes the second request to a host cheap, and
 * sharing one connection across concurrent requests is what makes them
 * concurrent at all.
 *
 * Sessions are shared, not checked out. That is the difference from
 * `crossbyte.db.ConnectionPool`, and the reason this is its own thing: a
 * database connection carries one statement at a time and must be lent
 * exclusively, while an HTTP/2 connection is designed for many streams at once
 * and lending it exclusively would defeat it.
 */
class H2ConnectionPool {
	/**
	 * Sessions held per origin.
	 *
	 * More than one is worth having even though a single connection can
	 * multiplex: a peer's SETTINGS_MAX_CONCURRENT_STREAMS caps how many
	 * requests one connection will carry, and past that a second connection
	 * is the only way to make progress.
	 */
	public static var maxSessionsPerOrigin:Int = 4;

	private static final __sessions:Map<String, Array<H2ClientSession>> = new Map();
	private static final __gates:Map<String, Mutex> = new Map();
	private static final __lock:Mutex = new Mutex();

	/**
	 * A session for `origin` with room for another stream, opening one through
	 * `connect` if none is available.
	 *
	 * Connecting is serialized per origin. Without that, concurrent first
	 * requests to the same host each find no session, each open their own, and
	 * the multiplexing never happens -- the very case it exists for is the one
	 * that races. The gate is per origin rather than global so a slow host
	 * cannot hold up connections to every other one.
	 *
	 * `connect` still runs outside the global lock: it performs a TCP connect
	 * and possibly a TLS handshake, and holding a shared lock across that
	 * would serialize every origin behind the slowest.
	 */
	public static function acquire(origin:String, connect:Void->H2ClientSession):H2ClientSession {
		var reusable:Null<H2ClientSession> = __findUsable(origin);
		if (reusable != null) {
			return reusable;
		}

		var gate:Mutex = __gateFor(origin);
		gate.acquire();

		// Re-checked behind the gate: whoever held it before us may have
		// opened exactly the session we were about to duplicate.
		var opened:Null<H2ClientSession> = __findUsable(origin);
		if (opened != null) {
			gate.release();
			return opened;
		}

		var session:H2ClientSession;
		try {
			session = connect();
		} catch (e:Dynamic) {
			gate.release();
			throw e;
		}

		__lock.acquire();
		var list:Null<Array<H2ClientSession>> = __sessions.get(origin);
		if (list == null) {
			list = [];
			__sessions.set(origin, list);
		}
		list.push(session);
		__lock.release();

		gate.release();
		return session;
	}

	/**
	 * A live session with stream capacity, reaping dead ones on the way past.
	 *
	 * Returns `null` when a new connection is needed -- except at the ceiling,
	 * where the busiest session comes back instead: the peer refuses a stream
	 * it cannot take, which is a better answer than refusing to try.
	 */
	private static function __findUsable(origin:String):Null<H2ClientSession> {
		__lock.acquire();
		var list:Null<Array<H2ClientSession>> = __sessions.get(origin);

		if (list == null) {
			__lock.release();
			return null;
		}

		var index:Int = list.length - 1;
		while (index >= 0) {
			var candidate:H2ClientSession = list[index];
			if (candidate.dead) {
				// Reaped on the way past rather than by a sweep: a dead
				// session is only interesting to whoever next wants one.
				list.splice(index, 1);
			} else if (candidate.hasCapacity()) {
				__lock.release();
				return candidate;
			}
			index--;
		}

		if (list.length == 0) {
			__sessions.remove(origin);
			__lock.release();
			return null;
		}

		if (list.length >= maxSessionsPerOrigin) {
			var fallback:H2ClientSession = list[list.length - 1];
			__lock.release();
			return fallback;
		}

		__lock.release();
		return null;
	}

	private static function __gateFor(origin:String):Mutex {
		__lock.acquire();
		var gate:Null<Mutex> = __gates.get(origin);
		if (gate == null) {
			gate = new Mutex();
			__gates.set(origin, gate);
		}
		__lock.release();
		return gate;
	}

	/** Drops a session, closing it if it is still alive. */
	public static function discard(session:H2ClientSession):Void {
		__lock.acquire();
		var list:Null<Array<H2ClientSession>> = __sessions.get(session.origin);
		if (list != null) {
			list.remove(session);
			if (list.length == 0) {
				__sessions.remove(session.origin);
			}
		}
		__lock.release();

		try {
			session.close();
		} catch (_:Dynamic) {}
	}

	/** Sessions currently held for an origin. Diagnostics and tests. */
	public static function sessionCount(origin:String):Int {
		__lock.acquire();
		var list:Null<Array<H2ClientSession>> = __sessions.get(origin);
		var count:Int = list == null ? 0 : list.length;
		__lock.release();
		return count;
	}

	/** Closes and forgets everything. */
	public static function closeAll():Void {
		__lock.acquire();
		var all:Array<H2ClientSession> = [];
		for (list in __sessions) {
			for (session in list) {
				all.push(session);
			}
		}
		__sessions.clear();
		__lock.release();

		for (session in all) {
			try {
				session.close();
			} catch (_:Dynamic) {}
		}
	}
}
#end
