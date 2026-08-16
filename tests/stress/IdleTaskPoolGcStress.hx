package stress;

import crossbyte.sys.TaskPool;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * Leaves worker pools parked and idle, then allocates hard on other
 * threads to force garbage collection.
 *
 * Invariant: allocation keeps making progress while workers are parked.
 *
 * This guards a bug that already shipped once and hung CI. `TaskPool`
 * parked idle workers on `sys.thread.Condition.wait()`, which on hxcpp
 * compiles to `SleepConditionVariableCS(INFINITE)` without an
 * `hx::EnterGCFreeZone()` wrapper — unlike `Deque`'s blocking pop, which
 * wraps correctly. A worker parked there never reaches a GC safepoint, so
 * the next thread to allocate blocks forever inside the collector. Any
 * application holding an idle pool could deadlock, not only the tests.
 *
 * The failure is invisible to unit tests: nothing throws and no assertion
 * fails. The process simply stops at 0% CPU, which is why this belongs in
 * the stress suite. The case reports failure by *timing out* rather than
 * by crashing, so a regression surfaces as a bounded failure instead of a
 * wedged CI job.
 */
class IdleTaskPoolGcStress implements StressCase {
	private static inline final POOLS:Int = 8;
	private static inline final WORKERS_PER_POOL:Int = 4;
	private static inline final ALLOCATOR_THREADS:Int = 4;
	private static inline final ALLOCATIONS_PER_THREAD:Int = 40000;
	private static inline final TIMEOUT_SECONDS:Float = 60;

	private var lock:Mutex;
	private var finished:Int = 0;

	public function new() {
		lock = new Mutex();
	}

	public function run():StressResult {
		var pools:Array<TaskPool> = [];

		// Each pool runs one trivial job so its workers spin up, then goes
		// idle and parks. Parked-but-alive is the state that used to wedge
		// the collector.
		for (i in 0...POOLS) {
			var pool = new TaskPool(WORKERS_PER_POOL);
			pool.submit(function() {});
			pools.push(pool);
		}

		// Give the workers a moment to finish that job and park.
		Sys.sleep(0.25);

		for (t in 0...ALLOCATOR_THREADS) {
			Thread.create(function() {
				// Allocate enough to force several collections. Any GC here
				// must be able to stop the world, which requires every
				// parked worker to be at a safepoint.
				for (n in 0...ALLOCATIONS_PER_THREAD) {
					var churn:Array<String> = [];
					for (k in 0...8) {
						churn.push("allocation " + n + ":" + k);
					}
				}

				lock.acquire();
				finished++;
				lock.release();
			});
		}

		var deadline:Float = Sys.time() + TIMEOUT_SECONDS;
		var completed:Int = 0;

		while (Sys.time() < deadline) {
			lock.acquire();
			completed = finished;
			lock.release();

			if (completed == ALLOCATOR_THREADS) {
				break;
			}
			Sys.sleep(0.02);
		}

		var elapsed:Float = TIMEOUT_SECONDS - (deadline - Sys.time());
		var passed:Bool = completed == ALLOCATOR_THREADS;

		for (pool in pools) {
			try {
				pool.shutdown(true);
			} catch (_:Dynamic) {}
		}

		return {
			name: "Idle TaskPool does not block GC",
			passed: passed,
			details: [
				'idle pools=$POOLS workers=' + (POOLS * WORKERS_PER_POOL),
				'allocator threads=$ALLOCATOR_THREADS x $ALLOCATIONS_PER_THREAD allocations',
				'threads completed=$completed of $ALLOCATOR_THREADS',
				"elapsed=" + Std.int(elapsed * 1000) + "ms (timeout " + Std.int(TIMEOUT_SECONDS) + "s)"
			]
		};
	}
}
