package stress;

import crossbyte.db.ConnectionPool;
import crossbyte.sys.TaskPool;
import sys.thread.Mutex;

private class FakeConnection {
	public var id(default, null):Int;

	public function new(id:Int) {
		this.id = id;
	}
}

/**
 * Drives many threads through a small pool.
 *
 * Invariants: the pool never opens more connections than its ceiling,
 * never hands the same connection to two callers at once, and never leaks
 * capacity — including across the error path, since a pool that loses one
 * connection per failure deadlocks after `maxSize` failures.
 */
class ConnectionPoolStress implements StressCase {
	private static inline final MAX_SIZE:Int = 4;
	private static inline final WORKERS:Int = 16;
	private static inline final JOBS:Int = 640;

	private var lock:Mutex;
	private var created:Int = 0;
	private var concurrent:Int = 0;
	private var maxConcurrent:Int = 0;
	private var doubleIssued:Bool = false;
	private var inFlight:Map<Int, Bool>;
	private var completed:Int = 0;
	private var failures:Int = 0;
	private var recovered:Int = 0;

	public function new() {
		lock = new Mutex();
		inFlight = new Map();
	}

	public function run():StressResult {
		var pool = new ConnectionPool({
			factory: function() {
				lock.acquire();
				var connection = new FakeConnection(created++);
				lock.release();
				return connection;
			},
			maxSize: MAX_SIZE,
			acquireTimeout: 30.0
		});

		var workers = new TaskPool(WORKERS);

		for (i in 0...JOBS) {
			// Every fifth job throws, so the error path is exercised under
			// contention rather than only on the happy path.
			var shouldFail:Bool = (i % 5 == 0);

			workers.submit(function() {
				try {
					pool.withConnection(function(connection:FakeConnection):Int {
						lock.acquire();
						if (inFlight.exists(connection.id)) {
							doubleIssued = true;
						}
						inFlight.set(connection.id, true);
						concurrent++;
						if (concurrent > maxConcurrent) {
							maxConcurrent = concurrent;
						}
						lock.release();

						Sys.sleep(0.001);

						lock.acquire();
						concurrent--;
						inFlight.remove(connection.id);
						lock.release();

						if (shouldFail) {
							throw "job failed";
						}
						return connection.id;
					});

					lock.acquire();
					completed++;
					lock.release();
				} catch (_:Dynamic) {
					lock.acquire();
					recovered++;
					lock.release();
				}
			});
		}

		workers.shutdown(true);

		var expectedFailures:Int = Math.ceil(JOBS / 5);
		var expectedCompletions:Int = JOBS - expectedFailures;

		var passed:Bool = completed == expectedCompletions
			&& recovered == expectedFailures
			&& failures == 0
			&& created <= MAX_SIZE
			&& maxConcurrent <= MAX_SIZE
			&& !doubleIssued
			&& pool.inUse() == 0
			&& pool.size() <= MAX_SIZE;

		var details:Array<String> = [
			'jobs=$JOBS workers=$WORKERS maxSize=$MAX_SIZE',
			'completed=$completed (expected $expectedCompletions)',
			'threw-and-recovered=$recovered (expected $expectedFailures)',
			'connections created=$created (ceiling $MAX_SIZE)',
			'peak concurrent checkouts=$maxConcurrent',
			'same connection issued twice=$doubleIssued',
			'leaked capacity: inUse=' + pool.inUse() + " size=" + pool.size()
		];

		pool.close();

		return {name: "ConnectionPool contention", passed: passed, details: details};
	}
}
