package stress;

import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * Creates timers concurrently from several threads.
 *
 * Invariant: every timer is armed, once, with a scheduler handle of its own.
 *
 * `haxe.Timer` must not allocate an id from a static counter outside the
 * lock guarding its timer map, or two threads could take the same id and
 * the second registration evict the first, leaving a timer that silently
 * never fired.
 *
 * `haxe.Timer` has no id of its own. A timer made on a thread without a
 * runtime is handed to the primordial one through its post queue and armed
 * there, taking a handle from that runtime's scheduler, so that race has
 * no counter to happen on. What can still go wrong is the same failure by
 * another route (a handoff lost between threads, or two timers given one
 * handle), and either shows here as a timer that never got a handle, or a
 * handle held twice.
 */
@:access(haxe.Timer)
@:access(crossbyte.core.CrossByte)
class TimerIdStress implements StressCase {
	private static inline final THREADS:Int = 32;
	private static inline final PER_THREAD:Int = 400;
	// Long enough that no timer fires during the run.
	private static inline final IDLE_MS:Int = 3600000;

	private var lock:Mutex;
	private var timers:Array<haxe.Timer>;
	private var finished:Int = 0;

	public function new() {
		lock = new Mutex();
		timers = [];
	}

	public function run():StressResult {
		var runtime = crossbyte.core.CrossByte.__primordial;

		for (t in 0...THREADS) {
			Thread.create(function() {
				// Buffered locally and handed over after the creation loop:
				// this harness's lock taken between constructions would
				// serialize the threads and hide the very window under test.
				var created:Array<haxe.Timer> = [];

				for (i in 0...PER_THREAD) {
					created.push(new haxe.Timer(IDLE_MS));
				}

				lock.acquire();
				for (timer in created) {
					timers.push(timer);
				}
				finished++;
				lock.release();
			});
		}

		// The runtime is host-driven here: pumping it is what runs the arms
		// the threads posted to it.
		var expected:Int = THREADS * PER_THREAD;
		var deadline:Float = haxe.Timer.stamp() + 60;
		var armed:Int = 0;
		while (haxe.Timer.stamp() < deadline) {
			runtime.pump(0.0, 0.0);

			lock.acquire();
			var done:Bool = finished == THREADS;
			lock.release();

			if (done) {
				armed = 0;
				for (timer in timers) {
					if (timer.__armed) {
						armed++;
					}
				}
				if (armed == expected) {
					break;
				}
			}
			crossbyte.sys.System.sleep(0.001);
		}

		var seen:Map<Int, Bool> = new Map();
		var duplicates:Int = 0;
		for (timer in timers) {
			if (!timer.__armed) {
				continue;
			}
			if (seen.exists(timer.__handle)) {
				duplicates++;
			}
			seen.set(timer.__handle, true);
		}

		for (timer in timers) {
			timer.stop();
		}
		runtime.pump(0.0, 0.0);

		var passed:Bool = timers.length == expected && armed == expected && duplicates == 0;

		return {
			name: "Timer arming across threads",
			passed: passed,
			details: [
				'threads=$THREADS timers=$expected',
				"created=" + timers.length,
				'armed=$armed',
				'duplicate handles=$duplicates'
			]
		};
	}
}
