package crossbyte.db;

#if cpp
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
 * With a worker per pooled connection, what `AsyncDatabase.of` builds, a
 * job never waits for a connection, so the pool's acquire timeout and wait
 * metrics never fire: the waiting all happens in the worker pool's queue,
 * which had no bound, no deadline and nothing measuring it.
 *
 * Native only: elsewhere the worker pool runs each job as it is submitted,
 * so there is never a queue to bound.
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
		// A caller long gone, a request that timed out, no longer gets its
		// query run anyway, holding a connection that live requests want.
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
