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

	/**
	 * Seconds a session may sit with nothing in flight before it is closed.
	 * Negative keeps them forever.
	 *
	 * Reuse is the point of the pool, but an unbounded one is a leak: every
	 * origin ever contacted keeps a socket and a parked reader thread, and a
	 * program that talks to many hosts accumulates one of each per host for
	 * as long as it runs.
	 */
	public static var idleTimeoutSeconds:Float = 90;

	private static final __sessions:Map<String, Array<H2ClientSession>> = new Map();
	// Connections being opened, by origin, one for each set of TLS options
	// asked for, and who waits on each.
	private static final __connecting:Map<String, Array<PendingConnect>> = new Map();
	private static final __lock:Mutex = new Mutex();

	/**
	 * A session for `origin` with room for another stream, opening one through
	 * `connect` if none is available.
	 *
	 * Connecting is serialized per origin. Without that, concurrent first
	 * requests to the same host each find no session, each open their own, and
	 * the multiplexing never happens, the very case it exists for is the one
	 * that races. So one request connects and the others wait for it, per
	 * origin, so a slow host cannot hold up connections to every other one.
	 *
	 * The waiting has limits. The others waited on a per-origin mutex, as long
	 * as the connect took and without a deadline or a cancel reaching them, so
	 * a server that accepted TCP and never finished TLS held every request to
	 * its origin for good: three requests, no outcome in 15 seconds, a cancel
	 * doing nothing. A waiter now gives up at `timeoutSeconds`, leaves at once
	 * on its `cancelToken`, and is told the connector's failure rather than
	 * trying the same connect again in turn, unless the connector was only
	 * cancelled, when the next one tries.
	 *
	 * `connect` runs outside the pool's lock: it performs a TCP connect and
	 * possibly a TLS handshake, and holding a shared lock across that would
	 * serialize every origin behind the slowest.
	 *
	 * Only a session opened under the same TLS options is shared, by
	 * `HTTPTLSOptions.same`, null being the defaults: a connection that did not
	 * check its server never carries a request that asked it to.
	 *
	 * @param timeoutSeconds The longest this call waits on another request's
	 *        connect; `<= 0` waits for it however long it takes.
	 */
	public static function acquire(origin:String, connect:Void->H2ClientSession, timeoutSeconds:Float = 0,
			?cancelToken:crossbyte.http.HTTPCancelToken, ?tls:crossbyte.http.HTTPTLSOptions):H2ClientSession {
		var deadline:Float = timeoutSeconds > 0 ? haxe.Timer.stamp() + timeoutSeconds : -1;

		while (true) {
			var expired:Array<H2ClientSession> = [];
			__lock.acquire();
			// Looked for and, failing that, claimed under one hold, so a
			// session opened the moment before is found rather than duplicated.
			var usable:Null<H2ClientSession> = __findUsableLocked(origin, expired, tls);
			var pending:Null<PendingConnect> = usable == null ? __pendingFor(origin, tls) : null;
			var mine:Bool = usable == null && pending == null;
			if (mine) {
				pending = new PendingConnect(tls);
				var list:Null<Array<PendingConnect>> = __connecting.get(origin);
				if (list == null) {
					list = [];
					__connecting.set(origin, list);
				}
				list.push(pending);
			}
			var wake:Null<H2Wake> = null;
			if (usable == null && !mine) {
				wake = new H2Wake();
				pending.waiters.push(wake);
			}
			__lock.release();
			__closeAll(expired);

			if (usable != null) {
				return usable;
			}

			if (mine) {
				return __connectFor(origin, pending, connect, cancelToken);
			}

			__awaitConnect(origin, pending, wake, deadline, cancelToken);
			// Woken by the connect finishing, well or badly: look again.
		}
	}

	/** Opens a connection for `origin` as the one request its waiters wait on. */
	private static function __connectFor(origin:String, pending:PendingConnect, connect:Void->H2ClientSession,
			cancelToken:Null<crossbyte.http.HTTPCancelToken>):H2ClientSession {
		var session:H2ClientSession;
		try {
			session = connect();
		} catch (e:Dynamic) {
			// Passed on to the waiters, who would only meet it again one after
			// another, unless it was this request's own cancel, which says
			// nothing about the server, so the next of them tries.
			__finishConnect(origin, pending, null, (cancelToken != null && cancelToken.cancelled) ? null : e);
			throw e;
		}
		__finishConnect(origin, pending, session, null);
		return session;
	}

	/** Records how `pending` ended, and wakes everyone waiting on it. */
	private static function __finishConnect(origin:String, pending:PendingConnect, session:Null<H2ClientSession>, failure:Dynamic):Void {
		__lock.acquire();
		if (session != null) {
			var list:Null<Array<H2ClientSession>> = __sessions.get(origin);
			if (list == null) {
				list = [];
				__sessions.set(origin, list);
			}
			list.push(session);
		}
		pending.failure = failure;
		pending.finished = true;
		var list:Null<Array<PendingConnect>> = __connecting.get(origin);
		if (list != null) {
			list.remove(pending);
			if (list.length == 0) {
				__connecting.remove(origin);
			}
		}
		var waiters:Array<H2Wake> = pending.waiters;
		pending.waiters = [];
		__lock.release();

		for (waiter in waiters) {
			waiter.release();
		}
	}

	/**
	 * Waits on another request's connect to `origin`, until it finishes, the
	 * deadline passes or the token cancels, and throws for the last two and
	 * for a failure the connect passed on.
	 */
	private static function __awaitConnect(origin:String, pending:PendingConnect, wake:H2Wake, deadline:Float,
			cancelToken:Null<crossbyte.http.HTTPCancelToken>):Void {
		var onCancel:Void->Void = () -> wake.release();
		if (cancelToken != null) {
			cancelToken.onCancel(onCancel);
		}

		var woken:Bool;
		if (deadline < 0) {
			woken = wake.wait();
		} else {
			var remaining:Float = deadline - haxe.Timer.stamp();
			woken = remaining > 0 && wake.wait(remaining);
		}

		if (cancelToken != null) {
			cancelToken.removeHandler(onCancel);
		}

		__lock.acquire();
		pending.waiters.remove(wake);
		var finished:Bool = pending.finished;
		var failure:Dynamic = pending.failure;
		__lock.release();

		if (cancelToken != null && cancelToken.cancelled) {
			throw new H2ConnectionError(H2ErrorCode.CANCEL, "Request was cancelled while waiting for a connection to " + origin);
		}
		if (!finished) {
			throw new H2ConnectionError(H2ErrorCode.CANCEL, "Timed out waiting for a connection to " + origin);
		}
		if (failure != null) {
			throw failure;
		}
	}

	/**
	 * A live session for `origin` with stream capacity, reaping dead and
	 * expired ones on the way past, expired ones into `expired`, for the
	 * caller to close once the lock is let go. Under the lock.
	 *
	 * Returns `null` when a new connection is needed, except at the ceiling,
	 * where the busiest session comes back instead: the peer refuses a stream
	 * it cannot take, which is a better answer than refusing to try.
	 */
	private static function __findUsableLocked(origin:String, expired:Array<H2ClientSession>, ?tls:crossbyte.http.HTTPTLSOptions):Null<H2ClientSession> {
		var list:Null<Array<H2ClientSession>> = __sessions.get(origin);
		if (list == null) {
			return null;
		}

		var matching:Int = 0;
		var busiest:Null<H2ClientSession> = null;
		var index:Int = list.length - 1;
		while (index >= 0) {
			var candidate:H2ClientSession = list[index];
			if (candidate.dead) {
				// Reaped on the way past rather than by a sweep: a dead
				// session is only interesting to whoever next wants one.
				list.splice(index, 1);
			} else if (candidate.goingAway) {
				// Its peer has said GOAWAY, so it takes no new stream: out of
				// the pool, and retired by the caller, which leaves the
				// streams it carries to finish (H2ClientSession.retire).
				list.splice(index, 1);
				expired.push(candidate);
			} else if (__isExpired(candidate)) {
				// Closed by the caller, outside the lock: close() wakes
				// waiters and touches the socket, which is more than should
				// happen with a pool-wide lock held.
				list.splice(index, 1);
				expired.push(candidate);
			} else if (crossbyte.http.HTTPTLSOptions.same(candidate.tls, tls)) {
				if (candidate.hasCapacity()) {
					return candidate;
				}
				matching++;
				if (busiest == null) {
					busiest = candidate;
				}
			}
			index--;
		}

		if (list.length == 0) {
			__sessions.remove(origin);
			return null;
		}

		if (matching >= maxSessionsPerOrigin) {
			return busiest;
		}

		return null;
	}

	/** The connect under way for `origin` under `tls`, if there is one. Under the lock. */
	private static function __pendingFor(origin:String, tls:Null<crossbyte.http.HTTPTLSOptions>):Null<PendingConnect> {
		var list:Null<Array<PendingConnect>> = __connecting.get(origin);
		if (list != null) {
			for (pending in list) {
				if (crossbyte.http.HTTPTLSOptions.same(pending.tls, tls)) {
					return pending;
				}
			}
		}
		return null;
	}

	/**
	 * Whether a session has been idle long enough to close, taking it out of
	 * service if so. See `H2ClientSession.retireIfIdle`, which decides it
	 * under the session's own lock so that a request starting at the same
	 * moment is never closed under.
	 *
	 * "At least" the timeout, so a timeout of N means idle for N or more and
	 * a timeout of zero reaps anything not carrying a request. Strictly more
	 * made that depend on whether the clock ticked between the request
	 * finishing and the sweep, true natively, false on the jvm.
	 */
	private static function __isExpired(session:H2ClientSession):Bool {
		return idleTimeoutSeconds >= 0 && session.retireIfIdle(idleTimeoutSeconds);
	}

	/**
		Retires sessions taken out of the pool: closed at once when they carry
		nothing, dead, or idle, and otherwise once the last stream on them
		ends (`H2ClientSession.retire`).
	**/
	private static function __closeAll(sessions:Array<H2ClientSession>):Void {
		for (session in sessions) {
			try {
				session.retire();
			} catch (_:Dynamic) {}
		}
	}

	/**
	 * Closes every session idle past `idleTimeoutSeconds`, returning how many
	 * went.
	 *
	 * `acquire` already reaps what it walks past, which is enough for a
	 * program that keeps making requests. This is for one that stops: nothing
	 * else would ever look again, and the sockets would outlive the interest
	 * in them.
	 */
	public static function reapIdle():Int {
		if (idleTimeoutSeconds < 0) {
			return 0;
		}

		__lock.acquire();
		var expired:Array<H2ClientSession> = [];

		for (origin in __sessions.keys()) {
			var list:Array<H2ClientSession> = __sessions.get(origin);
			var index:Int = list.length - 1;
			while (index >= 0) {
				var candidate:H2ClientSession = list[index];
				if (candidate.dead || candidate.goingAway || __isExpired(candidate)) {
					list.splice(index, 1);
					expired.push(candidate);
				}
				index--;
			}

			if (list.length == 0) {
				__sessions.remove(origin);
			}
		}
		__lock.release();

		__closeAll(expired);
		return expired.length;
	}

	/**
		Takes a session out of the pool without cutting short the requests it
		carries: it closes once the last of them ends. For one that refused a
		new request, its peer said GOAWAY, or the pool retired it as idle a
		moment after handing it over, where `discard` would fail every other
		request still on it.
	**/
	public static function retire(session:H2ClientSession):Void {
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
			session.retire();
		} catch (_:Dynamic) {}
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

/**
 * A connection one request is opening, and the requests waiting for it.
 * Changed only under the pool's lock.
 */
private class PendingConnect {
	/** One wake-up per waiter, so each can also be woken on its own. */
	public var waiters:Array<H2Wake> = [];

	/** Set once the connect has ended, well or badly. */
	public var finished:Bool = false;

	/** What the connect failed with, for its waiters, or null. */
	public var failure:Dynamic = null;

	/** The TLS options the connection is being opened under. */
	public final tls:Null<crossbyte.http.HTTPTLSOptions>;

	public function new(tls:Null<crossbyte.http.HTTPTLSOptions>) {
		this.tls = tls;
	}
}
#end
