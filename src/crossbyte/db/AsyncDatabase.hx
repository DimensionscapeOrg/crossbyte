package crossbyte.db;

// Not built for the browser: a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.sys.Task;
import crossbyte.sys.TaskPool;

/**
 * Runs database work off the runtime loop.
 *
 * Every CrossByte database driver is synchronous, so calling one directly
 * from a tick handler blocks the event loop for the duration of the query,
 * the single most common way to make a CrossByte server stutter under
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
	 * Seconds a job waits for a free connection, once a worker has taken it,
	 * before failing. `null` uses the pool's own default.
	 *
	 * With a worker per pooled connection, what `of` builds, this never
	 * fires: a worker only exists when a connection does, so the waiting all
	 * happens earlier, in the worker pool's queue, where this does not reach.
	 * `queueTimeout` is the deadline for that wait.
	 */
	public var acquireTimeout:Null<Float>;

	/**
	 * Most jobs allowed to wait for a worker at once, or `0`, the default,
	 * for no limit. Past it `submit` throws instead of queueing.
	 *
	 * The backlog had no bound. A database slower than the traffic reaching
	 * it then shows up as a queue that grows with the traffic, in memory,
	 * and in the latency of every job behind it, rather than as an error
	 * anyone sees. A server should set one. It is not set by default because
	 * a batch that submits ten thousand statements at once is a legitimate
	 * use of the same queue. Checked at submission, against the worker
	 * pool's queue.
	 */
	public var maxQueued:Int = 0;

	/**
	 * Seconds a job may wait for a worker before it fails without running,
	 * or `null`, the default, for no limit. The time is measured from
	 * `submit`, and a job past it fails with an `IllegalOperationError` when
	 * a worker reaches it, without taking a connection.
	 *
	 * A caller long gone, an HTTP request that has timed out, say, no
	 * longer gets its query run anyway, holding a connection that live
	 * requests are waiting for.
	 */
	public var queueTimeout:Null<Float>;

	@:noCompletion private var __waitSeconds:crossbyte.metrics.Histogram;
	@:noCompletion private var __rejectedTotal:crossbyte.metrics.Counter;
	@:noCompletion private var __expiredTotal:crossbyte.metrics.Counter;

	/**
	 * Creates a facade over an existing pool and worker pool.
	 *
	 * Sizing note: a worker blocks while waiting for a connection, so a
	 * worker count far above the pool's `maxSize` buys nothing, the extra
	 * workers simply queue. Matching them, or keeping workers at or below
	 * `maxSize`, is usually right.
	 *
	 * @param metrics Registry to publish the backlog into, or `null` for
	 *        none: `<prefix>_queued` and `<prefix>_running` jobs,
	 *        `<prefix>_queue_wait_seconds`, and `<prefix>_rejected_total` and
	 *        `<prefix>_expired_total` for jobs `maxQueued` and
	 *        `queueTimeout` turned away. The pool publishes its own.
	 * @param metricsPrefix Defaults to `db_async`.
	 */
	public function new(pool:ConnectionPool<T>, workers:TaskPool, ?metrics:crossbyte.metrics.Metrics, ?metricsPrefix:String) {
		if (pool == null) {
			throw new ArgumentError("AsyncDatabase requires a ConnectionPool.");
		}
		if (workers == null) {
			throw new ArgumentError("AsyncDatabase requires a TaskPool.");
		}

		this.pool = pool;
		this.workers = workers;
		__initMetrics(metrics, metricsPrefix);
	}

	/**
	 * Convenience constructor that builds and owns a matching worker pool.
	 *
	 * @param pool The connection pool to draw from.
	 * @param workerCount Workers to create. Defaults to the pool's
	 *        `maxSize`, which keeps every worker able to hold a connection.
	 * @param metrics As for the constructor.
	 * @param metricsPrefix As for the constructor.
	 */
	public static function of<T>(pool:ConnectionPool<T>, ?workerCount:Int, ?metrics:crossbyte.metrics.Metrics, ?metricsPrefix:String):AsyncDatabase<T> {
		if (pool == null) {
			throw new ArgumentError("AsyncDatabase requires a ConnectionPool.");
		}

		var count:Int = (workerCount == null) ? pool.maxSize : workerCount;
		return new AsyncDatabase(pool, new TaskPool(count), metrics, metricsPrefix);
	}

	/**
	 * Runs `body` on a worker thread with a pooled connection.
	 *
	 * The connection is returned to the pool automatically, including when
	 * `body` throws, in which case the returned task fails with that
	 * error rather than raising on the runtime thread.
	 *
	 * @return A task completing with `body`'s return value.
	 * @throws IllegalOperationError When `maxQueued` jobs are already waiting.
	 */
	public function submit<R>(body:T->R):Task<R> {
		if (body == null) {
			throw new ArgumentError("AsyncDatabase.submit requires a body.");
		}

		if (maxQueued > 0 && workers.queuedCount >= maxQueued) {
			if (__rejectedTotal != null) {
				__rejectedTotal.inc();
			}

			throw new IllegalOperationError('AsyncDatabase already has $maxQueued jobs waiting for a worker; refusing another rather than queueing without bound.');
		}

		var connectionPool = pool;
		var timeout = acquireTimeout;
		var waitLimit:Null<Float> = queueTimeout;
		var waitSeconds = __waitSeconds;
		var expiredTotal = __expiredTotal;
		var submitted:Float = haxe.Timer.stamp();

		return workers.submitResult(function():R {
			var waited:Float = haxe.Timer.stamp() - submitted;

			if (waitSeconds != null) {
				waitSeconds.observe(waited);
			}

			if (waitLimit != null && waited > waitLimit) {
				if (expiredTotal != null) {
					expiredTotal.inc();
				}

				throw new IllegalOperationError('AsyncDatabase job waited ${waited}s for a worker, past its queueTimeout of ${waitLimit}s, and was not run.');
			}

			return connectionPool.withConnection(body, timeout);
		});
	}

	@:noCompletion private function __initMetrics(registry:crossbyte.metrics.Metrics, prefix:String):Void {
		if (registry == null) {
			return;
		}

		var name:String = (prefix == null || prefix == "") ? "db_async" : prefix;
		var taskPool:TaskPool = workers;

		// Read from the worker pool rather than counted here, so a job that
		// is cancelled while it waits is not counted as waiting for ever.
		registry.gaugeFn(name + "_queued", () -> taskPool.queuedCount, null, "Jobs waiting for a worker.");
		registry.gaugeFn(name + "_running", () -> taskPool.activeCount, null, "Jobs running on a worker.");

		__waitSeconds = registry.histogram(name + "_queue_wait_seconds", null, null, "Time a job waited for a worker before starting.");
		__rejectedTotal = registry.counter(name + "_rejected_total", null, "Jobs refused because maxQueued were already waiting.");
		__expiredTotal = registry.counter(name + "_expired_total", null, "Jobs that waited past queueTimeout and were not run.");
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
	 *
	 * The task fails when `commit` throws, and `rollback` runs then too:
	 * on an engine that keeps the transaction open after a failed COMMIT,
	 * as SQLite does when the database is busy, that is what closes it
	 * before the connection goes back to the pool. Every driver in this
	 * package throws from a failed commit; a callback that only reports
	 * failure some other way is invisible here.
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
				commit(connection);
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
