package stress;

import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * Creates timers concurrently from several threads.
 *
 * Invariant: every timer receives a distinct id.
 *
 * This case caught a real bug: `haxe.Timer` allocated its id from a static
 * counter *outside* the lock guarding the timer map, so two threads could
 * take the same id and the second registration evicted the first — leaving
 * a timer that silently never fired.
 */
@:access(haxe.Timer)
class TimerIdStress implements StressCase {
	private static inline final THREADS:Int = 32;
	private static inline final PER_THREAD:Int = 400;
	// Long enough that no timer fires during the run.
	private static inline final IDLE_MS:Int = 3600000;

	private var lock:Mutex;
	private var ids:Array<Int>;
	private var finished:Int = 0;

	public function new() {
		lock = new Mutex();
		ids = [];
	}

	public function run():StressResult {
		for (t in 0...THREADS) {
			Thread.create(function() {
				// Ids are buffered locally and timers stopped only after the
				// creation loop: both stop() and this harness's own lock take
				// mutexes, and taking one between constructions would
				// serialize the threads and hide the very window under test.
				var local:Array<Int> = [];
				var created:Array<haxe.Timer> = [];

				for (i in 0...PER_THREAD) {
					var timer = new haxe.Timer(IDLE_MS);
					local.push(timer.id);
					created.push(timer);
				}

				for (timer in created) {
					timer.stop();
				}

				lock.acquire();
				for (id in local) {
					ids.push(id);
				}
				finished++;
				lock.release();
			});
		}

		var deadline:Float = Sys.time() + 60;
		while (Sys.time() < deadline) {
			lock.acquire();
			var done:Int = finished;
			lock.release();
			if (done == THREADS) {
				break;
			}
			Sys.sleep(0.01);
		}

		var expected:Int = THREADS * PER_THREAD;
		var seen:Map<Int, Bool> = new Map();
		var duplicates:Int = 0;
		for (id in ids) {
			if (seen.exists(id)) {
				duplicates++;
			}
			seen.set(id, true);
		}

		var passed:Bool = ids.length == expected && duplicates == 0;

		return {
			name: "Timer id allocation",
			passed: passed,
			details: [
				'threads=$THREADS timers=$expected',
				"created=" + ids.length,
				'duplicate ids=$duplicates'
			]
		};
	}
}
