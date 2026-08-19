package crossbyte.timer;

import crossbyte._internal.system.timer.ITimerScheduler;
import crossbyte._internal.system.timer.TimerHandle;
import crossbyte._internal.system.timer.heap.TimerHeap;
import crossbyte._internal.system.timer.wheel.TimerWheel;
import utest.Assert;

/**
 * The wheel against the heap, on identical scenarios.
 *
 * Written as a comparison rather than as fixed expectations because the
 * contract being tested is exactly that: an alternative scheduler is only
 * useful if a runtime cannot tell which one it was given. Fixed expectations
 * would pin the wheel to what its author believed the heap does, which is a
 * weaker thing to check than what the heap actually does.
 *
 * Fires are compared as counts per timer, not as a sequence. Timers due in
 * the same tick have no defined order in either scheduler — a heap does not
 * order equal keys any more than a bucket does — so comparing sequences would
 * fail on a difference neither one promises.
 */
class TimerWheelTest extends utest.Test {
	function __runBoth(build:(ITimerScheduler, Array<String>) -> Void, steps:Int, dt:Float):Void {
		var heapLog:Array<String> = [];
		var wheelLog:Array<String> = [];

		var heap:ITimerScheduler = new TimerHeap();
		var wheel:ITimerScheduler = new TimerWheel();

		build(heap, heapLog);
		build(wheel, wheelLog);

		for (i in 0...steps) {
			heap.advanceTime(dt, 1 << 28);
			wheel.advanceTime(dt, 1 << 28);
		}

		Assert.equals(heapLog.length, wheelLog.length);

		var expected:Map<String, Int> = new Map();
		var actual:Map<String, Int> = new Map();
		for (key in heapLog) {
			expected.set(key, (expected.exists(key) ? expected.get(key) : 0) + 1);
		}
		for (key in wheelLog) {
			actual.set(key, (actual.exists(key) ? actual.get(key) : 0) + 1);
		}

		for (key in expected.keys()) {
			Assert.equals(expected.get(key), actual.exists(key) ? actual.get(key) : 0);
		}
		for (key in actual.keys()) {
			Assert.isTrue(expected.exists(key));
		}
	}

	public function testOneShotsMatchTheHeap():Void {
		__runBoth((scheduler, log) -> {
			for (i in 0...20) {
				var n:Int = i;
				scheduler.setTimeoutVoid(0.010 * (i + 1), () -> log.push('t$n'));
			}
		}, 60, 0.010);
	}

	public function testRecurringMatchTheHeap():Void {
		__runBoth((scheduler, log) -> {
			for (i in 0...5) {
				var n:Int = i;
				scheduler.setIntervalVoid(0.020, 0.020 * (n + 1), () -> log.push('r$n'));
			}
		}, 100, 0.010);
	}

	public function testClearedTimerNeverFires():Void {
		__runBoth((scheduler, log) -> {
			scheduler.setTimeoutVoid(0.050, () -> log.push("keep"));
			var dropped = scheduler.setTimeoutVoid(0.030, () -> log.push("drop"));
			scheduler.clear(dropped);
		}, 20, 0.010);
	}

	public function testTimerClearingItselfFromItsCallback():Void {
		// The reentrant case: a node must be out of every list while its own
		// callback runs, or clearing from inside it corrupts the structure
		// holding it.
		__runBoth((scheduler, log) -> {
			scheduler.setInterval(0.010, 0.010, (handle) -> {
				log.push("x");
				if (log.length >= 3) {
					scheduler.clear(handle);
				}
			});
		}, 40, 0.010);
	}

	public function testPauseAndResumeMatchTheHeap():Void {
		__runBoth((scheduler, log) -> {
			var handle = scheduler.setIntervalVoid(0.020, 0.020, () -> log.push("p"));
			scheduler.setTimeoutVoid(0.050, () -> scheduler.setEnabled(handle, false));
			scheduler.setTimeoutVoid(0.150, () -> scheduler.setEnabled(handle, true));
		}, 40, 0.010);
	}

	public function testRescheduleMatchesTheHeap():Void {
		__runBoth((scheduler, log) -> {
			var handle = scheduler.setTimeoutVoid(0.030, () -> log.push("moved"));
			scheduler.reschedule(handle, 0.100);
		}, 30, 0.010);
	}

	public function testDelaysBeyondTheRingStillFire():Void {
		// The ring spans BUCKETS * RESOLUTION; these sit in the overflow list
		// until a revolution brings them into range, which is the part of the
		// wheel with nothing analogous in the heap.
		__runBoth((scheduler, log) -> {
			for (i in 0...5) {
				var n:Int = i;
				scheduler.setTimeoutVoid(0.8 + 0.1 * n, () -> log.push('o$n'));
			}
		}, 200, 0.010);
	}

	public function testWheelNeverFiresEarly():Void {
		// Buckets are chosen with ceil precisely so this holds. Late by under
		// a tick is the wheel's trade; early would mean a callback reading the
		// clock sees a time before the one it asked for.
		var wheel:ITimerScheduler = new TimerWheel();
		var early:Int = 0;

		for (i in 0...200) {
			var due:Float = 0.005 + i * 0.0013;
			wheel.setTimeout(due, (handle) -> {
				if (wheel.time < due - 1e-9) {
					early++;
				}
			});
		}

		for (i in 0...400) {
			wheel.advanceTime(0.005, 1 << 28);
		}

		Assert.equals(0, early);
		Assert.isTrue(wheel.isEmpty);
	}

	public function testSizeTracksLiveTimers():Void {
		var wheel = new TimerWheel();
		Assert.isTrue(wheel.isEmpty);

		var a = wheel.setTimeoutVoid(0.050, () -> {});
		var b = wheel.setTimeoutVoid(2.000, () -> {}); // beyond the ring
		Assert.equals(2, wheel.size);

		wheel.clear(a);
		Assert.equals(1, wheel.size);

		wheel.clear(b);
		Assert.equals(0, wheel.size);
		Assert.isTrue(wheel.isEmpty);
	}
}
