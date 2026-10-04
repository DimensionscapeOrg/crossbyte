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
 * the same tick have no defined order in either scheduler, a heap does not
 * order equal keys any more than a bucket does, so comparing sequences would
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

	public function testARecurringTimerThatThrowsStaysArmed():Void {
		var wheel = new TimerWheel();
		var failures:Array<Dynamic> = [];
		wheel.onError = error -> failures.push(error);
		var fired = 0;
		var handle = wheel.setInterval(0.010, 0.010, _ -> {
			fired++;
			throw "timer bug";
		});

		for (_ in 0...5) {
			wheel.advanceTime(0.010, 1 << 28);
		}

		Assert.isTrue(fired >= 3, "the timer that threw was not re-armed: fired " + fired);
		Assert.equals(fired, failures.length);
		Assert.isTrue(wheel.isActive(handle));
	}

	public function testEveryDueTimerFiresInOnePass():Void {
		var wheel = new TimerWheel();
		var fired = 0;
		for (_ in 0...1000) {
			wheel.setTimeoutVoid(0.1, () -> fired++);
		}

		Assert.equals(1000, wheel.advanceTime(0.1));
		Assert.equals(1000, fired);
		Assert.isFalse(wheel.cutShort);
	}

	public function testAPassStoppedPartwayThroughABucketFinishesItNext():Void {
		// A cap that ran out inside a bucket left the rest of it behind the
		// cursor, where they waited a whole revolution: half a second.
		var wheel = new TimerWheel();
		var fired = 0;
		for (_ in 0...100) {
			wheel.setTimeoutVoid(0.05, () -> fired++);
		}

		Assert.equals(10, wheel.advanceTime(0.1, 10));
		Assert.equals(10, wheel.advanceTime(0, 10), "the rest of the bucket was stranded behind the cursor");
		for (_ in 0...10) {
			wheel.advanceTime(0, 10);
		}
		Assert.equals(100, fired);
	}

	public function testABudgetCountsWhatItLeaves():Void {
		var wheel = new TimerWheel();
		var fired = 0;
		for (_ in 0...100) {
			wheel.setTimeoutVoid(0.05, () -> {
				fired++;
				var end = haxe.Timer.stamp() + 0.0005;
				while (haxe.Timer.stamp() < end) {}
			});
		}

		var first = wheel.advanceTime(0.1, 0x7FFFFFFF, 0.002);
		Assert.isTrue(wheel.cutShort);
		Assert.equals(100 - first, wheel.overdue());

		var passes = 0;
		while (fired < 100 && passes++ < 100) {
			wheel.advanceTime(0, 0x7FFFFFFF, 0.002);
		}
		Assert.equals(100, fired);
		Assert.equals(0, wheel.overdue());
	}

	public function testASetTimeoutOfZeroFiresOnTheNextFrame():Void {
		// It was placed in the bucket the cursor had just left and fired a
		// revolution later: 517ms at sixty frames a second.
		var wheel = new TimerWheel();
		var frame = 1 / 60;
		wheel.advanceTime(frame);
		wheel.advanceTime(frame);

		var fired = -1;
		var frames = 0;
		wheel.setTimeoutVoid(0, () -> fired = frames);
		while (fired < 0 && frames < 200) {
			frames++;
			wheel.advanceTime(frame);
		}
		Assert.equals(1, fired);
	}

	public function testATimerArmedInACallbackIsNotEarly():Void {
		// Its bucket was counted from the end of the frame and reached from
		// the start of it: a 5ms timer fired in the same frame it was armed.
		var wheel = new TimerWheel();
		var frame = 1 / 60;
		var armedAt = -1.0;
		var firedAt = -1.0;
		wheel.setTimeoutVoid(0.010, () -> {
			armedAt = wheel.time;
			wheel.setTimeoutVoid(0.005, () -> firedAt = wheel.time);
		});

		for (_ in 0...120) {
			wheel.advanceTime(frame);
		}
		Assert.isTrue(armedAt >= 0 && firedAt >= 0, "never fired");
		Assert.isTrue(firedAt - armedAt >= 0.005 - 1e-9, 'armed at $armedAt, fired at $firedAt');
	}

	public function testAnIntervalShorterThanAFrameKeepsItsRate():Void {
		// Re-armed behind the cursor, a 5ms interval fired twice a second at
		// sixty frames a second rather than 200 times.
		var wheel = new TimerWheel();
		var frame = 1 / 60;
		var fired = 0;
		wheel.setIntervalVoid(0.005, 0.005, () -> fired++);

		for (_ in 0...60) {
			wheel.advanceTime(frame);
		}
		Assert.isTrue(fired >= 199 && fired <= 200, "a 5ms interval over one second fired " + fired + " times");
	}

	public function testATimerDaysAwayDoesNotFireAtOnce():Void {
		// Its distance in ticks overflowed an Int.
		var wheel = new TimerWheel();
		var fired = false;
		wheel.setTimeoutVoid(30 * 24 * 3600, () -> fired = true);

		for (_ in 0...10) {
			wheel.advanceTime(0.1);
		}
		Assert.isFalse(fired);
		Assert.equals(1, wheel.size);
	}

	public function testATimerRescheduledFromItsCallbackAfterANestedPass():Void {
		// A pass run from inside a callback cleared which timer was firing:
		// the callback's reschedule afterwards linked the timer into a bucket
		// and the settle then freed it there, still linked.
		var wheel = new TimerWheel();
		var runs = 0;
		var nested = 0;
		var handle = wheel.setTimeout(0.010, h -> {
			runs++;
			if (runs == 1) {
				wheel.setTimeoutVoid(0.001, () -> nested++);
				wheel.advanceTime(0.002);
				wheel.reschedule(h, wheel.time + 0.020);
			}
		});

		wheel.advanceTime(0.010);
		Assert.equals(1, nested, "the nested pass fired nothing");
		Assert.isTrue(wheel.isActive(handle), "the timer rescheduled after a nested pass was freed");
		for (_ in 0...4) {
			wheel.advanceTime(0.010);
		}
		Assert.equals(2, runs);
		Assert.isFalse(wheel.isActive(handle));
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
