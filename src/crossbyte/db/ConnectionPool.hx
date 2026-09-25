package crossbyte.db;

// Not built for any JavaScript target (Node included, which has no threads): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
#if (cpp || neko || hl || java || jvm)
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
	@:noCompletion private var __waitSeconds:crossbyte.metrics.Histogram;
	@:noCompletion private var __retiredName:String;

	#if (cpp || neko || hl || java || jvm)
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
		__idle = [];
		__out = [];

		#if (cpp || neko || hl || java || jvm)
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
			Sys.sleep(0.001);
		}
	}

	/**
	 * Returns a connection to the pool for reuse.
	 *
	 * Releasing a connection the pool did not issue, or releasing the same
	 * connection twice, is ignored rather than corrupting the accounting.
	 */
	public function release(connection:T):Void {
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

		__out.splice(index, 1);

		if (closed) {
			__created--;
			__releaseLock();
			__closeConnection(connection, "pool_closed");
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
			// The connection may be mid-transaction or otherwise unusable,
			// but only the caller knows; return it and let validation catch
			// a genuinely broken one on the next acquire.
			release(connection);
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
	 * the set is fixed and small — four values — and the distinction
	 * matters operationally: connections retiring through
	 * `failed_validation` mean the database is dropping them underneath
	 * the pool, which is a different problem from an application calling
	 * `discard()`.
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
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		#end
	}

	@:noCompletion private inline function __releaseLock():Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.release();
		#end
	}
}
#end
