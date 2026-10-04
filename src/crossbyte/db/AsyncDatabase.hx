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
 * // Given pool:ConnectionPool<crossbyte.db.postgres.PostgresConnection>.
 * import crossbyte.sys.TaskPool;
 * import crossbyte.utils.Logger;
 *
 * var db = new AsyncDatabase(pool, new TaskPool(4));
 *
 * db.submit(connection -> connection.request("SELECT count(*) FROM users"))
 *     .onComplete(result -> Logger.info("users counted"))
 *     .onError(error -> Logger.error('query failed: $error'));
 * ```
 *
 * The callback runs on the runtime thread, so it may touch runtime state
 * directly. The body passed to `submit` runs on a worker thread and must
 * not.
 *
 * **The queue is bounded twice by default**: a job waits at most
 * `queueTimeout`, 30 seconds, for a worker, and fails at that deadline
 * whether or not a worker comes free; and `maxQueued`, 100,000, is the most
 * that may wait at once. A database slower than the traffic reaching it,
 * or one a partition has silenced, holding every worker, shows up as
 * failed jobs and refused submissions, rather than as a queue that grows
 * with the traffic in memory and in the latency of every job behind it.
 */
class AsyncDatabase<T> {
	/** `queueTimeout` unless set: 30 seconds. **/
	public static inline var DEFAULT_QUEUE_TIMEOUT:Float = 30.0;

	/** `maxQueued` unless set: 100,000 jobs. **/
	public static inline var DEFAULT_MAX_QUEUED:Int = 100000;

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
	 * before failing: `null`, the default, uses the pool's own
	 * `acquireTimeout`, and 0 is no limit.
	 *
	 * With a worker per pooled connection, what `of` builds, this never
	 * fires: a worker only exists when a connection does, so the waiting all
	 * happens earlier, in the worker pool's queue, where this does not reach.
	 * `queueTimeout` is the deadline for that wait.
	 *
	 * @throws ArgumentError When set to NaN or a negative number.
	 */
	public var acquireTimeout(default, set):Null<Float> = null;

	/**
	 * Most jobs allowed to wait for a worker at once: `DEFAULT_MAX_QUEUED`,
	 * 100,000, unless set, or 0 for no limit. Past it `submit` throws an
	 * `IllegalOperationError` instead of queueing.
	 *
	 * The backlog had no bound unless set. A database slower than the
	 * traffic reaching it then showed up as a queue that grew with the
	 * traffic, in memory, each job holding what its body captured, rather
	 * than as an error anyone saw; `queueTimeout` bounds how long a job
	 * waits, and this how many wait, which the traffic decides. Set to more
	 * for a batch that submits more than 100,000 statements at once, or set
	 * to 0. Checked at submission, against the worker pool's queue, which
	 * counts a job that expired there until a worker discards it.
	 *
	 * @throws ArgumentError When set below 0.
	 */
	public var maxQueued(default, set):Int = DEFAULT_MAX_QUEUED;

	/**
	 * Seconds a job may wait for a worker before it fails without running:
	 * `DEFAULT_QUEUE_TIMEOUT`, 30, unless set, or 0 for no limit. The time is
	 * measured from `submit`. At the deadline the job's task fails with an
	 * `IllegalOperationError` saying so, at once, whether or not a worker
	 * has come free: a thread of this database's own watches the deadlines,
	 * since the workers that would otherwise notice are the ones that are
	 * busy. It takes no connection, and a worker that reaches it later
	 * passes over it.
	 *
	 * A caller long gone, an HTTP request that has timed out, say, no
	 * longer gets its query run anyway, holding a connection that live
	 * requests are waiting for. It was `null` unless set, which waited for
	 * ever, and even when set it failed a job only when a worker reached it:
	 * with every worker held by a database that had stopped answering, never.
	 *
	 * A batch of more jobs than the workers finish in this time loses its
	 * tail: raise it, or set 0, for such a batch. Applies to jobs submitted
	 * after it is set.
	 *
	 * @throws ArgumentError When set to NaN or a negative number.
	 */
	public var queueTimeout(default, set):Float = DEFAULT_QUEUE_TIMEOUT;

	@:noCompletion private var __waitSeconds:crossbyte.metrics.Histogram;
	@:noCompletion private var __rejectedTotal:crossbyte.metrics.Counter;
	@:noCompletion private var __expiredTotal:crossbyte.metrics.Counter;
	#if target.threaded
	// Its thread is started by the first job with a deadline, and stopped by
	// shutdown().
	@:noCompletion private var __deadlines:QueueDeadlines;
	#end

	/**
	 * Creates a facade over an existing pool and worker pool.
	 *
	 * Sizing note: a worker blocks while waiting for a connection, so a
	 * worker count far above the pool's `maxSize` buys nothing, the extra
	 * workers simply queue. Matching them, or keeping workers at or below
	 * `maxSize`, is usually right.
	 *
	 * @param metrics Registry to publish the backlog into, or `null` for
	 *        none: `<prefix>_queued` and `<prefix>_running` jobs, a job
	 *        failed at its `queueTimeout` counts as queued until a worker
	 *        passes over it, `<prefix>_queue_wait_seconds`, observed as a
	 *        job starts or expires, and `<prefix>_rejected_total` and
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
		#if target.threaded
		__deadlines = new QueueDeadlines(__waitSeconds, __expiredTotal);
		#end
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
	 * @return A task completing with `body`'s return value, or failing with
	 *         an `IllegalOperationError` if it is still waiting for a worker
	 *         `queueTimeout` seconds after this call.
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
		var waitLimit:Float = queueTimeout;
		var waitSeconds = __waitSeconds;
		var expiredTotal = __expiredTotal;
		var submitted:Float = haxe.Timer.stamp();
		#if target.threaded
		var deadlines:QueueDeadlines = __deadlines;
		var waiting:Null<QueuedJob> = waitLimit > 0 ? new QueuedJob(submitted, waitLimit) : null;
		#end

		var task:Task<R> = workers.submitResult(function():R {
			#if target.threaded
			if (waiting != null) {
				deadlines.started(waiting);
			}
			#end

			var waited:Float = haxe.Timer.stamp() - submitted;

			if (waitSeconds != null) {
				waitSeconds.observe(waited);
			}

			// The watch fails a job at its deadline; one a worker reaches in
			// the moment before the watch does is failed here instead.
			if (waitLimit > 0 && waited > waitLimit) {
				if (expiredTotal != null) {
					expiredTotal.inc();
				}

				throw new IllegalOperationError(QueuedJob.describe(waited, waitLimit));
			}

			return connectionPool.withConnection(body, timeout);
		});

		#if target.threaded
		if (waiting != null) {
			waiting.task = cast task;
			deadlines.add(waiting);
		}
		#end

		return task;
	}

	@:noCompletion private function set_acquireTimeout(value:Null<Float>):Null<Float> {
		if (value != null && (Math.isNaN(value) || value < 0)) {
			throw new ArgumentError('AsyncDatabase.acquireTimeout is a number of seconds, 0 for none, or null for the pool\'s: $value is not one.');
		}

		return acquireTimeout = value;
	}

	@:noCompletion private function set_queueTimeout(value:Float):Float {
		if (Math.isNaN(value) || value < 0) {
			throw new ArgumentError('AsyncDatabase.queueTimeout is a number of seconds, 0 for none: $value is not one.');
		}

		return queueTimeout = value;
	}

	@:noCompletion private function set_maxQueued(value:Int):Int {
		if (value < 0) {
			throw new ArgumentError('AsyncDatabase.maxQueued must not be negative ($value); 0 is no limit.');
		}

		return maxQueued = value;
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
	 * // Given db:AsyncDatabase<crossbyte.db.postgres.PostgresConnection>.
	 * db.transaction(c -> c.begin(), c -> c.commit(), c -> c.rollback(),
	 *     connection -> connection.request("INSERT ..."));
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
	 *        before workers stop, each still failing at its `queueTimeout`
	 *        if no worker reaches it first, so the call waits for the jobs
	 *        running and those queued: as long as the slowest statement,
	 *        which the driver's own limits bound (a read timeout or a
	 *        statement timeout; keepalive for a server that has gone
	 *        silent). Pass `false` to stop as promptly as the worker pool
	 *        allows.
	 */
	public function shutdown(drain:Bool = true):Void {
		if (drain) {
			workers.shutdown(true);
		} else {
			workers.shutdownNow();
		}

		pool.close();
		#if target.threaded
		__deadlines.stop();
		#end
	}
}

#if target.threaded
/** A job waiting for a worker, and when it stops waiting. **/
private final class QueuedJob {
	/** Set once the job is submitted; null until then. **/
	public var task:Null<Task<Dynamic>> = null;
	public var submitted:Float;
	public var limit:Float;
	public var deadline:Float;
	// Where it is in the watch's heap; -1 outside it.
	public var slot:Int = -1;
	// A worker has taken it: the watch leaves it alone, or never takes it in.
	public var started:Bool = false;

	public function new(submitted:Float, limit:Float) {
		this.submitted = submitted;
		this.limit = limit;
		this.deadline = submitted + limit;
	}

	public static function describe(waited:Float, limit:Float):String {
		return 'AsyncDatabase job waited ${Math.round(waited * 1000) / 1000}s for a worker, past its queueTimeout of ${limit}s, and was not run.';
	}
}

/**
	Fails the jobs that wait past their deadline, at it, on a thread of its
	own: the workers that would otherwise notice are the ones that are busy,
	and a database that has stopped answering holds them all.

	The waiting jobs are kept in a heap by deadline. Submitting one costs a
	push and taking one a removal, each under a lock held for a few
	instructions, beside a job that runs a statement. The thread sleeps until
	the earliest deadline, in whole milliseconds, since hxcpp's timed wait
	spins through a fraction of one on Windows, and ends after a while
	with nothing waiting, to be started again by the next job.
**/
@:access(crossbyte.sys.Task)
private final class QueueDeadlines {
	/** Seconds the thread waits with nothing to watch before it ends. **/
	private static inline var IDLE_SECONDS:Float = 10.0;

	private final __lock:sys.thread.Mutex = new sys.thread.Mutex();
	// Released to wake the thread early: a new earliest deadline, or stop().
	private final __wake:sys.thread.Lock = new sys.thread.Lock();
	private final __heap:Array<QueuedJob> = [];
	private var __running:Bool = false;
	private var __stopped:Bool = false;
	// What the thread is sleeping toward, so a job due before it wakes it.
	private var __sleepingUntil:Float = Math.POSITIVE_INFINITY;
	private final __waitSeconds:Null<crossbyte.metrics.Histogram>;
	private final __expiredTotal:Null<crossbyte.metrics.Counter>;

	public function new(waitSeconds:Null<crossbyte.metrics.Histogram>, expiredTotal:Null<crossbyte.metrics.Counter>) {
		__waitSeconds = waitSeconds;
		__expiredTotal = expiredTotal;
	}

	/** Watches `job`, once it has its task; unless a worker took it first. **/
	public function add(job:QueuedJob):Void {
		__lock.acquire();

		if (job.started || __stopped) {
			__lock.release();
			return;
		}

		job.slot = __heap.length;
		__heap.push(job);
		__up(job.slot);

		var wake:Bool = job.deadline < __sleepingUntil;
		var start:Bool = !__running;

		if (start) {
			__running = true;
			__sleepingUntil = job.deadline;
		}

		__lock.release();

		if (start) {
			sys.thread.Thread.create(__watch);
		} else if (wake) {
			__wake.release();
		}
	}

	/** A worker took `job`: it is no longer the watch's. **/
	public function started(job:QueuedJob):Void {
		__lock.acquire();
		job.started = true;

		if (job.slot >= 0) {
			__removeAt(job.slot);
		}

		__lock.release();
	}

	/** Ends the thread, failing nothing more. **/
	public function stop():Void {
		__lock.acquire();
		__stopped = true;

		for (job in __heap) {
			job.slot = -1;
		}

		__heap.resize(0);
		var running:Bool = __running;
		__lock.release();

		if (running) {
			__wake.release();
		}
	}

	private function __watch():Void {
		while (true) {
			var due:Array<QueuedJob> = null;
			__lock.acquire();

			if (__stopped) {
				__running = false;
				__lock.release();
				return;
			}

			var now:Float = haxe.Timer.stamp();

			while (__heap.length > 0 && __heap[0].deadline <= now) {
				var job:QueuedJob = __heap[0];
				__removeAt(0);

				if (due == null) {
					due = [];
				}

				due.push(job);
			}

			var next:Float = __heap.length > 0 ? __heap[0].deadline : Math.POSITIVE_INFINITY;

			if (due == null && next == Math.POSITIVE_INFINITY && __sleepingUntil == Math.POSITIVE_INFINITY) {
				// Idle a whole period with nothing to watch: the next job
				// starts a thread again.
				__running = false;
				__lock.release();
				return;
			}

			__sleepingUntil = next;
			__lock.release();

			if (due != null) {
				for (job in due) {
					__expire(job, now);
				}
			}

			if (next == Math.POSITIVE_INFINITY) {
				__wake.wait(IDLE_SECONDS);
			} else {
				var left:Float = next - haxe.Timer.stamp();

				if (left > 0) {
					__wake.wait(Math.fceil(left * 1000) / 1000);
				}
			}
		}
	}

	/** Fails `job` unless a worker has started it, or it was cancelled. **/
	private function __expire(job:QueuedJob, now:Float):Void {
		var task:Null<Task<Dynamic>> = job.task;

		if (task == null || !task.__start()) {
			return;
		}

		var waited:Float = now - job.submitted;

		if (__waitSeconds != null) {
			__waitSeconds.observe(waited);
		}

		if (__expiredTotal != null) {
			__expiredTotal.inc();
		}

		task.__fail(new IllegalOperationError(QueuedJob.describe(waited, job.limit)));
	}

	private function __removeAt(index:Int):Void {
		var removed:QueuedJob = __heap[index];
		var last:QueuedJob = __heap.pop();
		removed.slot = -1;

		if (index < __heap.length) {
			__heap[index] = last;
			last.slot = index;
			__down(index);
			__up(last.slot);
		}
	}

	private function __up(index:Int):Void {
		var job:QueuedJob = __heap[index];

		while (index > 0) {
			var parent:Int = (index - 1) >> 1;
			var above:QueuedJob = __heap[parent];

			if (above.deadline <= job.deadline) {
				break;
			}

			__heap[index] = above;
			above.slot = index;
			index = parent;
		}

		__heap[index] = job;
		job.slot = index;
	}

	private function __down(index:Int):Void {
		var job:QueuedJob = __heap[index];
		var count:Int = __heap.length;

		while (true) {
			var child:Int = index * 2 + 1;

			if (child >= count) {
				break;
			}

			if (child + 1 < count && __heap[child + 1].deadline < __heap[child].deadline) {
				child++;
			}

			var below:QueuedJob = __heap[child];

			if (job.deadline <= below.deadline) {
				break;
			}

			__heap[index] = below;
			below.slot = index;
			index = child;
		}

		__heap[index] = job;
		job.slot = index;
	}
}
#end
#end
