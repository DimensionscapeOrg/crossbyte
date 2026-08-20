package crossbyte.db;

// Not built for the browser: a database driver needs a socket or a file, and credentials do not belong in a page.
#if !(js && !nodejs)

import crossbyte.errors.ArgumentError;
import crossbyte.sys.Task;
import crossbyte.sys.TaskPool;

/**
 * Runs database work off the runtime loop.
 *
 * Every CrossByte database driver is synchronous, so calling one directly
 * from a tick handler blocks the event loop for the duration of the query
 * — the single most common way to make a CrossByte server stutter under
 * load. `AsyncDatabase` pairs a `ConnectionPool` with a `TaskPool` so that
 * hazard is designed out: work runs on a worker thread holding a pooled
 * connection, and the resulting `Task` delivers its completion back on the
 * runtime thread that submitted it.
 *
 * ```haxe
 * var db = new AsyncDatabase(pool, new TaskPool(4));
 *
 * db.submit(connection -> connection.query("SELECT count(*) FROM users"))
 *     .onComplete(result -> Logger.info("users counted"))
 *     .onError(error -> Logger.error('query failed: $error'));
 * ```
 *
 * The callback runs on the runtime thread, so it may touch runtime state
 * directly. The body passed to `submit` runs on a worker thread and must
 * not.
 */
class AsyncDatabase<T> {
	/**
	 * The pool connections are drawn from.
	 */
	public var pool(default, null):ConnectionPool<T>;

	/**
	 * The worker pool database work executes on.
	 */
	public var workers(default, null):TaskPool;

	/**
	 * Seconds a queued job waits for a free connection before failing.
	 * `null` uses the pool's own default.
	 */
	public var acquireTimeout:Null<Float>;

	/**
	 * Creates a facade over an existing pool and worker pool.
	 *
	 * Sizing note: a worker blocks while waiting for a connection, so a
	 * worker count far above the pool's `maxSize` buys nothing — the extra
	 * workers simply queue. Matching them, or keeping workers at or below
	 * `maxSize`, is usually right.
	 */
	public function new(pool:ConnectionPool<T>, workers:TaskPool) {
		if (pool == null) {
			throw new ArgumentError("AsyncDatabase requires a ConnectionPool.");
		}
		if (workers == null) {
			throw new ArgumentError("AsyncDatabase requires a TaskPool.");
		}

		this.pool = pool;
		this.workers = workers;
	}

	/**
	 * Convenience constructor that builds and owns a matching worker pool.
	 *
	 * @param pool The connection pool to draw from.
	 * @param workerCount Workers to create. Defaults to the pool's
	 *        `maxSize`, which keeps every worker able to hold a connection.
	 */
	public static function of<T>(pool:ConnectionPool<T>, ?workerCount:Int):AsyncDatabase<T> {
		if (pool == null) {
			throw new ArgumentError("AsyncDatabase requires a ConnectionPool.");
		}

		var count:Int = (workerCount == null) ? pool.maxSize : workerCount;
		return new AsyncDatabase(pool, new TaskPool(count));
	}

	/**
	 * Runs `body` on a worker thread with a pooled connection.
	 *
	 * The connection is returned to the pool automatically, including when
	 * `body` throws — in which case the returned task fails with that
	 * error rather than raising on the runtime thread.
	 *
	 * @return A task completing with `body`'s return value.
	 */
	public function submit<R>(body:T->R):Task<R> {
		if (body == null) {
			throw new ArgumentError("AsyncDatabase.submit requires a body.");
		}

		var connectionPool = pool;
		var timeout = acquireTimeout;

		return workers.submitResult(function():R {
			return connectionPool.withConnection(body, timeout);
		});
	}

	/**
	 * Runs `body` inside a transaction-shaped scope: `begin` first, then
	 * `commit` on success or `rollback` if `body` throws.
	 *
	 * Transaction control is expressed as callbacks because the drivers do
	 * not share a common interface. With `PostgresConnection` for example:
	 *
	 * ```haxe
	 * db.transaction(c -> c.begin(), c -> c.commit(), c -> c.rollback(),
	 *     connection -> connection.query("INSERT ..."));
	 * ```
	 *
	 * A failure in `rollback` does not mask the original error, which is
	 * the one describing what actually went wrong.
	 */
	public function transaction<R>(begin:T->Void, commit:T->Void, rollback:T->Void, body:T->R):Task<R> {
		if (begin == null || commit == null || rollback == null || body == null) {
			throw new ArgumentError("AsyncDatabase.transaction requires begin, commit, rollback, and body.");
		}

		return submit(function(connection:T):R {
			begin(connection);

			var result:R;
			try {
				result = body(connection);
			} catch (e:Dynamic) {
				try {
					rollback(connection);
				} catch (_:Dynamic) {}
				#if cpp
				cpp.Lib.rethrow(e);
				#else
				throw e;
				#end
				return null;
			}

			commit(connection);
			return result;
		});
	}

	/**
	 * Stops accepting work and releases resources.
	 *
	 * @param drain When `true` (the default), queued jobs run to completion
	 *        before workers stop. Pass `false` to stop as promptly as the
	 *        worker pool allows.
	 */
	public function shutdown(drain:Bool = true):Void {
		if (drain) {
			workers.shutdown(true);
		} else {
			workers.shutdownNow();
		}

		pool.close();
	}
}
#end
