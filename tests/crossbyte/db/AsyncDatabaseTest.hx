package crossbyte.db;

#if target.threaded
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.metrics.Metrics;
import sys.thread.Lock;
import utest.Assert;

/** A connection with nothing behind it; what is measured here is the queue. */
private class IdleConnection {
	public function new() {}
}

/**
 * The backlog in front of `AsyncDatabase`'s workers.
 *
 * With a worker per pooled connection (what `AsyncDatabase.of` builds) a
 * job never waits for a connection, so the pool's acquire timeout and wait
 * metrics never fire: the waiting all happens in the worker pool's queue,
 * which therefore needs a bound, a deadline and its own measuring.
 *
 * On every target with threads, which the worker pool has everywhere but
 * JavaScript; there each job runs as it is submitted, and nothing queues.
 */
class AsyncDatabaseTest extends utest.Test {
	public function testABacklogPastMaxQueuedIsRefused():Void {
		var db = AsyncDatabase.of(__pool());
		db.maxQueued = 2;

		var release = __occupyTheWorker(db);
		var first = db.submit(_ -> 1);
		var second = db.submit(_ -> 2);

		Assert.raises(() -> db.submit(_ -> 3), IllegalOperationError);

		release();
		Assert.equals(1, first.await());
		Assert.equals(2, second.await());

		// Room again once the backlog drains.
		Assert.equals(4, db.submit(_ -> 4).await());
		db.shutdown();
	}

	public function testAJobThatWaitedPastQueueTimeoutFailsWithoutRunning():Void {
		// A caller long gone (a request that timed out) does not get its query
		// run anyway, holding a connection that live requests want.
		var db = AsyncDatabase.of(__pool());
		db.queueTimeout = 0.1;

		var release = __occupyTheWorker(db);
		var ran:Bool = false;
		var late = db.submit(function(_):Int {
			ran = true;
			return 1;
		});

		crossbyte.sys.System.sleep(0.3);
		release();

		Assert.raises(() -> late.await(), IllegalOperationError);
		Assert.isFalse(ran, "a job past its deadline was run anyway");

		// One that has not waited long runs as ever.
		Assert.equals(2, db.submit(_ -> 2).await());
		db.shutdown();
	}

	public function testTheBacklogIsMeasured():Void {
		var registry = new Metrics();
		var db = AsyncDatabase.of(__pool(), null, registry, "testdb");
		db.maxQueued = 2;
		db.queueTimeout = 5;

		var release = __occupyTheWorker(db);
		var first = db.submit(_ -> 1);
		var second = db.submit(_ -> 2);

		Assert.equals(2.0, registry.gauge("testdb_queued").value());
		Assert.equals(1.0, registry.gauge("testdb_running").value());

		try {
			db.submit(_ -> 3);
		} catch (_:IllegalOperationError) {}

		Assert.equals(1.0, registry.counter("testdb_rejected_total").value());

		release();
		first.await();
		second.await();
		db.shutdown();

		// The occupying job and the two behind it each waited once.
		Assert.equals(3.0, registry.histogram("testdb_queue_wait_seconds").count());
		Assert.equals(0.0, registry.counter("testdb_expired_total").value());
		Assert.equals(0.0, registry.gauge("testdb_queued").value());
	}

	/**
		The queue is bounded by default, in time and in number, rather than
		waiting for ever and holding as many jobs as were submitted.
	**/
	public function testTheQueueIsBoundedByDefault():Void {
		var db = AsyncDatabase.of(__pool());
		Assert.equals(30.0, db.queueTimeout);
		Assert.equals(100000, db.maxQueued);

		#if (cpp || jvm)
		var release = __occupyTheWorker(db);
		var queued = [for (i in 0...100000) db.submit(_ -> i)];

		Assert.raises(() -> db.submit(_ -> -1), IllegalOperationError);

		release();
		Assert.equals(99999, queued[99999].await());
		#end
		db.shutdown();
	}

	/**
		A job fails at its deadline while every worker is still busy, not only
		when a worker reaches it, which with every worker held by a database
		that has stopped answering would be never.
	**/
	public function testAJobFailsAtItsDeadlineWhileTheWorkersAreBusy():Void {
		var db = AsyncDatabase.of(__pool());
		db.queueTimeout = 0.2;

		var release = __occupyTheWorker(db);
		var ran:Bool = false;
		var started:Float = haxe.Timer.stamp();
		var late = db.submit(function(_):Int {
			ran = true;
			return 1;
		});

		var failure:Dynamic = null;

		try {
			late.await();
		} catch (e:Dynamic) {
			failure = e;
		}

		var waited:Float = haxe.Timer.stamp() - started;
		release();

		Assert.isTrue(Std.isOfType(failure, IllegalOperationError), "the job did not fail: " + Std.string(failure));
		Assert.isTrue(waited < 2.0, 'the job failed after ${waited}s, when its worker came free, not at its 0.2 s deadline');
		Assert.isTrue(waited >= 0.15, 'the job failed after ${waited}s, before its deadline');
		Assert.isFalse(ran, "a job past its deadline was run");

		// The worker passes over it, and takes the next job as ever.
		Assert.equals(2, db.submit(_ -> 2).await());
		db.shutdown();
	}

	/** A queue timeout of 0 is none: a job waits as long as the workers are busy, rather than failing at once. **/
	public function testAQueueTimeoutOfZeroIsNone():Void {
		var db = AsyncDatabase.of(__pool());
		db.queueTimeout = 0;

		var release = __occupyTheWorker(db);
		var job = db.submit(_ -> 7);
		crossbyte.sys.System.sleep(0.3);
		release();

		Assert.equals(7, job.await());

		// And Infinity, as no limit is also written.
		db.queueTimeout = Math.POSITIVE_INFINITY;
		Assert.equals(8, db.submit(_ -> 8).await());
		db.shutdown();
	}

	/** An expired job is counted when it expires, not when a worker finds it. **/
	public function testAJobExpiredAtItsDeadlineIsCounted():Void {
		var registry = new Metrics();
		var db = AsyncDatabase.of(__pool(), null, registry, "deadline");
		db.queueTimeout = 0.1;

		var release = __occupyTheWorker(db);
		var started:Float = haxe.Timer.stamp();
		var late = db.submit(_ -> 1);

		try {
			late.await();
		} catch (_:Dynamic) {}

		var waited:Float = haxe.Timer.stamp() - started;
		Assert.isTrue(waited < 2.0, 'expired after ${waited}s, when its worker came free');
		Assert.equals(1.0, registry.counter("deadline_expired_total").value());
		// The wait of the job holding the worker, and of the one that expired.
		Assert.equals(2, registry.histogram("deadline_queue_wait_seconds").count());
		release();
		db.shutdown();
	}

	/**
		Limits that are not limits are refused: a negative maxQueued, which
		would read as no limit; a NaN queueTimeout, no limit, and a negative
		one, "fail every job"; and an acquireTimeout of either, passed to the
		pool unchecked.
	**/
	public function testNaNAndNegativeLimitsAreRefused():Void {
		var db = AsyncDatabase.of(__pool());

		Assert.raises(() -> db.queueTimeout = Math.NaN, ArgumentError);
		Assert.raises(() -> db.queueTimeout = -1, ArgumentError);
		Assert.raises(() -> db.acquireTimeout = Math.NaN, ArgumentError);
		Assert.raises(() -> db.acquireTimeout = -0.5, ArgumentError);
		Assert.raises(() -> db.maxQueued = -1, ArgumentError);

		// Each refused value leaves the setting as it was.
		Assert.equals(30.0, db.queueTimeout);
		Assert.isNull(db.acquireTimeout);
		Assert.equals(100000, db.maxQueued);

		db.acquireTimeout = 0;
		db.acquireTimeout = null;
		db.maxQueued = 0;
		db.shutdown();
	}

	private static function __pool():ConnectionPool<IdleConnection> {
		return new ConnectionPool<IdleConnection>({factory: () -> new IdleConnection(), maxSize: 1});
	}

	/**
	 * Parks the only worker on a job until the returned function is called,
	 * and returns once it has started.
	 */
	private static function __occupyTheWorker(db:AsyncDatabase<IdleConnection>):Void->Void {
		var started = new Lock();
		var gate = new Lock();

		db.submit(function(_):Int {
			started.release();
			gate.wait(10.0);
			return 0;
		});

		Assert.isTrue(started.wait(5.0), "the worker never took the first job");
		return () -> gate.release();
	}
}
#end
