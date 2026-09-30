package crossbyte.db;

// Not built for any JavaScript target (Node included, which has no threads): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
#if target.threaded
import sys.thread.Mutex;
#end

/**
 * Configuration for a `ConnectionPool`.
 */
typedef ConnectionPoolOptions<T> = {
	/**
	 * Opens a new connection. Called lazily, never more than `maxSize`
	 * times concurrently.
	 */
	var factory:Void->T;

	/**
	 * Closes a connection being discarded. Optional but strongly advised:
	 * without it, connections retired by `close()`, by failing validation,
	 * or by `discard()` leak their underlying handle.
	 */
	@:optional var close:T->Void;

	/**
	 * Checks a connection before it is handed out. Returning `false`
	 * retires it and supplies a fresh one, which is how a pool survives a
	 * database restart or an idle-timeout disconnect.
	 */
	@:optional var validate:T->Bool;

	/**
	 * Returns a connection to a clean state as it comes back, before any
	 * other caller can take it: on every `release()`, including the one
	 * `withConnection()` makes after its body threw. A reset that throws
	 * retires the connection instead.
	 *
	 * An open transaction needs no reset. A connection that implements
	 * `ITransactionalConnection` -- `PostgresConnection`, `MySQLConnection`
	 * and `SQLiteConnection` do -- has any transaction it comes back with
	 * rolled back by the pool itself, before this runs. A reset is for the
	 * rest of a session's state: settings changed with `SET`, temporary
	 * tables, a role assumed with `SET ROLE`. With `PostgresConnection`:
	 *
	 * ```haxe
	 * reset: c -> c.request("DISCARD ALL;")
	 * ```
	 */
	@:optional var reset:T->Void;

	/**
	 * Maximum connections held at once. Defaults to 8.
	 */
	@:optional var maxSize:Int;

	/**
	 * Default seconds `acquire()` waits for a connection before throwing.
	 * Defaults to 10.
	 */
	@:optional var acquireTimeout:Float;

	/**
	 * Registry this pool publishes its own metrics into.
	 *
	 * Saturation is the failure this makes visible: a pool at its ceiling
	 * looks identical to a slow database from the outside, and the wait
	 * histogram is what separates them. Leave `null` to record nothing.
	 */
	@:optional var metrics:crossbyte.metrics.Metrics;

	/**
	 * Prefix for the metric names this pool publishes, so several pools in
	 * one process can be told apart. Defaults to `db_pool`, yielding
	 * `db_pool_connections_open` and similar.
	 */
	@:optional var metricsPrefix:String;
};

/**
 * A fixed-ceiling pool of reusable database connections.
 *
 * The pool is deliberately driver-agnostic: it is parameterized on the
 * connection type and given a factory, so it works with
 * `SQLiteConnection`, `PostgresConnection`, `MySQLConnection`,
 * `MongoConnection`, or anything else, without those drivers having to
 * share an interface.
 *
 * Connections are created lazily up to `maxSize` and reused thereafter.
 *
 * **Threading.** `acquire()` blocks while the pool is saturated, so call
 * it from a `TaskPool` worker — never from the runtime tick thread, where
 * blocking would stall the event loop. `AsyncDatabase` wires that up
 * correctly and is the recommended entry point.
 *
 * Prefer `withConnection()` over manual acquire/release: it returns the
 * connection even when the body throws, which is what keeps a pool from
 * bleeding capacity on error paths.
 *
 * **Transactions.** A connection that comes back with a transaction still
 * open is rolled back before the next caller can take it, when it
 * implements `ITransactionalConnection`, as every driver here does. The
 * next borrower was otherwise handed that transaction: its writes joined it,
 * and the locks it held stayed held, and `validate` could not tell, since an
 * open transaction answers a ping like any other. A rollback that fails
 * retires the connection, and so does one after which the connection still
 * reports a transaction open: a MySQL session left with autocommit off,
 * which starts the next transaction as the last one ends. A connection
 * released with its transaction open is also logged as a warning under
 * `db.pool`, since that is a bug in the caller; one returned by
 * `withConnection()` after its body threw is not.
 */
class ConnectionPool<T> {
	/**
	 * Maximum number of connections this pool will create.
	 */
	public var maxSize(default, null):Int;

	/**
	 * Seconds `acquire()` waits by default before giving up.
	 */
	public var acquireTimeout(default, null):Float;

	/**
	 * Whether `close()` has been called.
	 */
	public var closed(default, null):Bool = false;

	@:noCompletion private var __factory:Void->T;
	@:noCompletion private var __close:T->Void;
	@:noCompletion private var __validate:T->Bool;
	@:noCompletion private var __reset:T->Void;
	@:noCompletion private var __idle:Array<T>;
	@:noCompletion private var __created:Int = 0;
	// The connections actually checked out, rather than a count of them.
	// release() and discard() have to answer "did this pool issue this?" and a
	// counter cannot: it made a foreign connection, or a second return of one
	// already back, indistinguishable from a real return. Both then adjusted
	// the accounting, and once __created drifts below the number of open
	// connections the ceiling stops holding. maxSize is small, so the linear
	// scan costs nothing beside the query the connection is for.
	@:noCompletion private var __out:Array<T>;

	// Slots reserved by a caller whose factory has not returned yet. Counted
	// as in use because they are: the capacity is spoken for, there is simply
	// no object to hold yet.
	@:noCompletion private var __reserving:Int = 0;

	@:noCompletion private var __metrics:crossbyte.metrics.Metrics;
	@:noCompletion private var __acquiredTotal:crossbyte.metrics.Counter;
	@:noCompletion private var __timeoutsTotal:crossbyte.metrics.Counter;
	@:noCompletion private var __openedTotal:crossbyte.metrics.Counter;
	@:noCompletion private var __retiredTotal:crossbyte.metrics.Counter;
	@:noCompletion private var __rolledBackTotal:crossbyte.metrics.Counter;
	@:noCompletion private var __waitSeconds:crossbyte.metrics.Histogram;
	@:noCompletion private var __retiredName:String;

	@:noCompletion private static final LOG:crossbyte.utils.LogCategory = crossbyte.utils.Logger.category("db.pool");

	#if target.threaded
	@:noCompletion private var __lock:Mutex;
	#end

	public function new(options:ConnectionPoolOptions<T>) {
		if (options == null || options.factory == null) {
			throw new ArgumentError("ConnectionPool requires a factory.");
		}

		maxSize = (options.maxSize == null) ? 8 : options.maxSize;
		if (maxSize < 1) {
			throw new ArgumentError("ConnectionPool maxSize must be at least 1.");
		}

		acquireTimeout = (options.acquireTimeout == null) ? 10.0 : options.acquireTimeout;
		if (acquireTimeout < 0) {
			throw new ArgumentError("ConnectionPool acquireTimeout must not be negative.");
		}

		__factory = options.factory;
		__close = options.close;
		__validate = options.validate;
		__reset = options.reset;
		__idle = [];
		__out = [];

		#if target.threaded
		__lock = new Mutex();
		#end

		__initMetrics(options.metrics, options.metricsPrefix);
	}

	/**
	 * Registers this pool's metrics when a registry is configured.
	 *
	 * The three state gauges are bound to the pool's own accessors rather
	 * than mirrored into separate counters, so they cannot drift from the
	 * accounting they describe. Series are created up front, so a scrape
	 * before the first acquire reports zero instead of omitting the series
	 * — an absent series and an idle pool look identical to a collector
	 * otherwise.
	 */
	@:noCompletion private function __initMetrics(registry:crossbyte.metrics.Metrics, prefix:String):Void {
		if (registry == null) {
			return;
		}

		__metrics = registry;
		var name:String = (prefix == null || prefix == "") ? "db_pool" : prefix;

		registry.gaugeFn(name + "_connections_open", () -> size(), null, "Connections currently open, idle or in use.");
		registry.gaugeFn(name + "_connections_in_use", () -> inUse(), null, "Connections currently checked out.");
		registry.gaugeFn(name + "_connections_idle", () -> available(), null, "Connections sitting idle and immediately available.");
		// A constant, but published so a dashboard can compute saturation
		// without the ceiling being hard-coded into the query.
		registry.gaugeFn(name + "_connections_max", () -> maxSize, null, "Ceiling on connections this pool will create.");

		__acquiredTotal = registry.counter(name + "_acquired_total", null, "Connections handed to a caller.");
		__timeoutsTotal = registry.counter(name + "_acquire_timeouts_total", null, "Acquisitions that gave up before a connection came free.");
		__openedTotal = registry.counter(name + "_opened_total", null, "Connections opened by the factory.");

		__retiredName = name + "_retired_total";
		__retiredTotal = registry.counter(__retiredName, null, "Connections closed and removed from the pool.");
		__rolledBackTotal = registry.counter(name + "_rollbacks_on_release_total", null, "Transactions still open on a released connection, rolled back by the pool.");

		// Wait time is the measurement that distinguishes a saturated pool
		// from a slow database; both show up as slow queries otherwise.
		__waitSeconds = registry.histogram(name + "_acquire_wait_seconds", null, null, "Time spent waiting for a connection to become available.");
	}

	/**
	 * Total connections currently open, whether idle or in use.
	 */
	public function size():Int {
		__acquireLock();
		var value:Int = __created;
		__releaseLock();
		return value;
	}

	/**
	 * Connections sitting idle and immediately available.
	 */
	public function available():Int {
		__acquireLock();
		var value:Int = __idle.length;
		__releaseLock();
		return value;
	}

	/**
	 * Connections currently checked out by callers.
	 */
	public function inUse():Int {
		__acquireLock();
		var value:Int = __out.length + __reserving;
		__releaseLock();
		return value;
	}

	/**
	 * Takes a connection from the pool, creating one if capacity allows,
	 * otherwise waiting for another caller to release one.
	 *
	 * Blocks the calling thread; use from a worker, not the tick loop.
	 *
	 * @param timeoutSeconds Overrides `acquireTimeout` for this call.
	 * @throws IllegalOperationError When the pool is closed, or no
	 *         connection becomes available before the timeout.
	 */
	public function acquire(?timeoutSeconds:Float):T {
		var timeout:Float = (timeoutSeconds == null) ? acquireTimeout : timeoutSeconds;
		var started:Float = haxe.Timer.stamp();
		var deadline:Float = started + timeout;

		while (true) {
			var candidate:Null<T> = __tryTake();
			if (candidate != null) {
				if (__metrics != null) {
					// Observed on every acquire, not just the contended ones:
					// a histogram whose zero bucket stops filling is how a
					// pool that has started queueing announces itself.
					__waitSeconds.observe(haxe.Timer.stamp() - started);
					__acquiredTotal.inc();
				}
				return candidate;
			}

			if (haxe.Timer.stamp() >= deadline) {
				if (__metrics != null) {
					__timeoutsTotal.inc();
					__waitSeconds.observe(haxe.Timer.stamp() - started);
				}
				throw new IllegalOperationError('ConnectionPool.acquire timed out after ${timeout}s with all $maxSize connection(s) in use.');
			}

			// No condition variable is available across every supported
			// target, so wait in small slices. Callers are worker threads,
			// so this costs latency rather than throughput.
			crossbyte._internal.system.Sleep.sleep(0.001);
		}
	}

	/**
	 * Returns a connection to the pool for reuse. A transaction left open on
	 * it is rolled back first, and then the `reset` hook runs, when one is
	 * configured; if either fails the connection is retired instead.
	 *
	 * Releasing a connection the pool did not issue, or releasing the same
	 * connection twice, is ignored rather than corrupting the accounting.
	 */
	public function release(connection:T):Void {
		__release(connection, false);
	}

	@:noCompletion private function __release(connection:T, bodyThrew:Bool):Void {
		if (connection == null) {
			return;
		}

		__acquireLock();

		var index:Int = __indexOf(__out, connection);

		if (index < 0) {
			// Not checked out: either this pool never issued it, or it has
			// already been returned. Adjusting the accounting for either is
			// what lets __created drift away from reality.
			__releaseLock();
			return;
		}

		var reusable:Bool = true;
		// Not into a closed pool: the connection is closed on the way in, and
		// closing it ends the transaction on the server.
		var open:ITransactionalConnection = closed ? null : __openTransaction(connection);

		if ((open != null || __reset != null) && !closed) {
			// Unlocked, since both may talk to the server. The connection
			// stays checked out meanwhile, so nobody can take it half reset.
			__releaseLock();

			try {
				if (open != null) {
					if (__rolledBackTotal != null) {
						__rolledBackTotal.inc();
					}

					// A body that threw has its own error on the way to the
					// caller; one that returned left the transaction open
					// without a word, and this is the only one it gets.
					if (!bodyThrew) {
						LOG.warn("A connection came back to the pool with its transaction still open; it was rolled back. Commit or roll back before releasing it.");
					}

					open.rollback();

					// A rollback that returns with a transaction still open
					// has not reset the session. MySQL with autocommit turned
					// off is the case: it opens the next transaction at once,
					// so the next borrower's "autocommit" writes would sit in
					// it uncommitted, and be rolled back in turn on release.
					// Retired rather than guessed at.
					if (open.inTransaction) {
						reusable = false;
					}
				}

				if (reusable && __reset != null) {
					__reset(connection);
				}
			} catch (_:Dynamic) {
				reusable = false;
			}

			__acquireLock();
			index = __indexOf(__out, connection);

			if (index < 0) {
				__releaseLock();
				return;
			}
		}

		__out.splice(index, 1);

		if (closed || !reusable) {
			__created--;
			__releaseLock();
			__closeConnection(connection, closed ? "pool_closed" : "failed_reset");
			return;
		}

		__idle.push(connection);
		__releaseLock();
	}

	/**
	 * Retires a connection instead of returning it, so a caller that saw a
	 * broken connection does not hand it to the next borrower. The pool
	 * regains capacity to create a replacement.
	 */
	public function discard(connection:T):Void {
		if (connection == null) {
			return;
		}

		__acquireLock();

		var index:Int = __indexOf(__out, connection);

		if (index >= 0) {
			__out.splice(index, 1);
		} else {
			// It may already have been released, in which case it is sitting
			// in the idle list. Closing it without taking it out of that list
			// hands the next caller a dead connection.
			index = __indexOf(__idle, connection);

			if (index < 0) {
				// This pool does not hold it. Retiring it anyway would credit
				// the pool with a slot it never gave up.
				__releaseLock();
				return;
			}

			__idle.splice(index, 1);
		}

		__created--;
		__releaseLock();

		__closeConnection(connection, "discarded");
	}

	/**
	 * Runs `body` with a pooled connection, always returning it afterwards
	 * — including when `body` throws, in which case the exception
	 * propagates unchanged.
	 */
	public function withConnection<R>(body:T->R, ?timeoutSeconds:Float):R {
		var connection:T = acquire(timeoutSeconds);
		var result:R;

		try {
			result = body(connection);
		} catch (e:Dynamic) {
			// The connection may be mid-transaction or otherwise unusable.
			// Releasing it rolls back a transaction it can report and runs the
			// `reset` hook for anything else, and validation catches a
			// genuinely broken one on the next acquire.
			__release(connection, true);
			__rethrow(e);
			return null;
		}

		release(connection);
		return result;
	}

	/**
	 * Closes idle connections and prevents further acquisition.
	 * Connections currently checked out are closed as they are released.
	 * Safe to call more than once.
	 */
	public function close():Void {
		__acquireLock();

		if (closed) {
			__releaseLock();
			return;
		}

		closed = true;
		var toClose:Array<T> = __idle;
		__idle = [];
		__created -= toClose.length;
		__releaseLock();

		for (connection in toClose) {
			__closeConnection(connection, "pool_closed");
		}
	}

	@:noCompletion private function __tryTake():Null<T> {
		__acquireLock();

		if (closed) {
			__releaseLock();
			throw new IllegalOperationError("ConnectionPool is closed.");
		}

		while (__idle.length > 0) {
			var candidate:T = __idle.pop();

			if (__validate == null) {
				__out.push(candidate);
				__releaseLock();
				return candidate;
			}

			// Validation may talk to the server, so run it unlocked. The
			// connection stays counted in __created throughout: it is still
			// open, and discounting it for the duration let another caller see
			// room and open one past the ceiling in that window.
			__releaseLock();

			var healthy:Bool = false;
			try {
				healthy = __validate(candidate);
			} catch (_:Dynamic) {
				healthy = false;
			}

			if (healthy) {
				__acquireLock();
				__out.push(candidate);
				__releaseLock();
				return candidate;
			}

			__closeConnection(candidate, "failed_validation");
			__acquireLock();
			__created--;
			if (closed) {
				__releaseLock();
				throw new IllegalOperationError("ConnectionPool is closed.");
			}
		}

		if (__created >= maxSize) {
			__releaseLock();
			return null;
		}

		// Reserve the slot before unlocking so concurrent callers cannot
		// collectively exceed maxSize while this connection is opening.
		__created++;
		__reserving++;
		__releaseLock();

		var connection:T;
		try {
			connection = __factory();
		} catch (e:Dynamic) {
			__acquireLock();
			__created--;
			__reserving--;
			__releaseLock();
			__rethrow(e);
			return null;
		}

		if (connection == null) {
			__acquireLock();
			__created--;
			__reserving--;
			__releaseLock();
			throw new IllegalOperationError("ConnectionPool factory returned null.");
		}

		__acquireLock();
		__reserving--;
		__out.push(connection);
		__releaseLock();

		if (__metrics != null) {
			// Counted only once the factory has produced a usable
			// connection, so a database refusing connections shows as a flat
			// line here rather than a rising one.
			__openedTotal.inc();
		}

		return connection;
	}

	/**
	 * Every retirement path funnels through here, so counting it here is
	 * what keeps the total honest.
	 *
	 * `reason` is labelled rather than split into separate metrics because
	 * the set is fixed and small — five values — and the distinction
	 * matters operationally: connections retiring through
	 * `failed_validation` mean the database is dropping them underneath
	 * the pool, which is a different problem from an application calling
	 * `discard()`, and `failed_reset` is a connection that could not be
	 * put back in a clean state.
	 */
	@:noCompletion private function __closeConnection(connection:T, reason:String = "released"):Void {
		if (__metrics != null) {
			__metrics.counter(__retiredName, ["reason" => reason]).inc();
		}

		if (__close == null) {
			return;
		}

		try {
			__close(connection);
		} catch (_:Dynamic) {
			// A connection being discarded cannot be salvaged by reporting
			// its close failure.
		}
	}

	/** The connection, when it can report a transaction and has one open. **/
	@:noCompletion private static function __openTransaction<T>(connection:T):ITransactionalConnection {
		if (!Std.isOfType(connection, ITransactionalConnection)) {
			return null;
		}

		var transactional:ITransactionalConnection = cast connection;
		return transactional.inTransaction ? transactional : null;
	}

	@:noCompletion private static function __indexOf<T>(items:Array<T>, value:T):Int {
		for (i in 0...items.length) {
			if (items[i] == value) {
				return i;
			}
		}
		return -1;
	}

	@:noCompletion private static function __rethrow(e:Dynamic):Void {
		#if cpp
		cpp.Lib.rethrow(e);
		#else
		throw e;
		#end
	}

	@:noCompletion private inline function __acquireLock():Void {
		#if target.threaded
		__lock.acquire();
		#end
	}

	@:noCompletion private inline function __releaseLock():Void {
		#if target.threaded
		__lock.release();
		#end
	}
}
#end
