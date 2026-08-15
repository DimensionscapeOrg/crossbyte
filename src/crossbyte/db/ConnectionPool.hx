package crossbyte.db;

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
	@:noCompletion private var __borrowed:Int = 0;

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

		#if (cpp || neko || hl || java || jvm)
		__lock = new Mutex();
		#end
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
		var value:Int = __borrowed;
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
		var deadline:Float = Sys.time() + timeout;

		while (true) {
			var candidate:Null<T> = __tryTake();
			if (candidate != null) {
				return candidate;
			}

			if (Sys.time() >= deadline) {
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

		if (__borrowed <= 0 || __contains(__idle, connection)) {
			__releaseLock();
			return;
		}

		__borrowed--;

		if (closed) {
			__created--;
			__releaseLock();
			__closeConnection(connection);
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
		if (__borrowed > 0) {
			__borrowed--;
		}
		__created--;
		__releaseLock();

		__closeConnection(connection);
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
			__closeConnection(connection);
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
				__borrowed++;
				__releaseLock();
				return candidate;
			}

			// Validation may talk to the server, so run it unlocked.
			__created--;
			__releaseLock();

			var healthy:Bool = false;
			try {
				healthy = __validate(candidate);
			} catch (_:Dynamic) {
				healthy = false;
			}

			if (healthy) {
				__acquireLock();
				__created++;
				__borrowed++;
				__releaseLock();
				return candidate;
			}

			__closeConnection(candidate);
			__acquireLock();
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
		__borrowed++;
		__releaseLock();

		var connection:T;
		try {
			connection = __factory();
		} catch (e:Dynamic) {
			__acquireLock();
			__created--;
			__borrowed--;
			__releaseLock();
			__rethrow(e);
			return null;
		}

		if (connection == null) {
			__acquireLock();
			__created--;
			__borrowed--;
			__releaseLock();
			throw new IllegalOperationError("ConnectionPool factory returned null.");
		}

		return connection;
	}

	@:noCompletion private function __closeConnection(connection:T):Void {
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

	@:noCompletion private static function __contains<T>(items:Array<T>, value:T):Bool {
		for (item in items) {
			if (item == value) {
				return true;
			}
		}
		return false;
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
