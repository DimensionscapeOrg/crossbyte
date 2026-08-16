package stress;

import crossbyte.sys.TaskPool;
import sys.thread.Mutex;

/**
 * Floods a worker pool and then drains it.
 *
 * Invariant: `shutdown(drain = true)` runs every submitted job before
 * returning. Silently dropping queued work would be near-impossible to
 * diagnose in a service, since the loss is invisible at the call site.
 */
class TaskPoolDrainStress implements StressCase {
	private static inline final WORKERS:Int = 16;
	private static inline final JOBS:Int = 2000;

	private var lock:Mutex;
	private var ran:Int = 0;

	public function new() {
		lock = new Mutex();
	}

	public function run():StressResult {
		var workers = new TaskPool(WORKERS);

		for (i in 0...JOBS) {
			workers.submit(function() {
				lock.acquire();
				ran++;
				lock.release();
			});
		}

		workers.shutdown(true);

		lock.acquire();
		var completed:Int = ran;
		lock.release();

		return {
			name: "TaskPool drain completeness",
			passed: completed == JOBS && workers.queuedCount == 0,
			details: [
				'jobs=$JOBS workers=$WORKERS',
				'ran=$completed',
				"missing=" + (JOBS - completed),
				"queued after shutdown=" + workers.queuedCount
			]
		};
	}
}
