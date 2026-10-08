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
 * the same tick have no defined order in either scheduler (a heap does not
 * order equal keys any more than a bucket does), so comparing sequences
 * would fail on a difference neither one promises.
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
		// A cap that runs out inside a bucket must not leave the rest of it
		// behind the cursor, where they would wait a whole revolution: half a second.
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
		// Not placed in the bucket the cursor has just left, where it would fire
		// a revolution later: 517ms at sixty frames a second.
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
		// Its bucket is counted from where it is reached: counted from the end of
		// the frame and reached from the start, a 5ms timer would fire in the
		// same frame it was armed.
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
		// Re-armed behind the cursor, a 5ms interval would fire twice a second
		// at sixty frames a second rather than 200 times.
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
		// Its distance in ticks overflows an Int.
		var wheel = new TimerWheel();
		var fired = false;
		wheel.setTimeoutVoid(30 * 24 * 3600, () -> fired = true);

		for (_ in 0...10) {
			wheel.advanceTime(0.1);
		}
		Assert.isFalse(fired);
		Assert.equals(1, wheel.size);
	}

	// The wheel reuses a done timer's node as the heap does; these are the
	// heap's cases for it.

	public function testAClearedHandleCannotReachTheTimerItsNodeNowCarries():Void {
		var wheel = new TimerWheel();
		var stale = wheel.setTimeoutVoid(0.010, () -> Assert.fail("a cleared timer fired"));
		var node:Dynamic = @:privateAccess wheel.__table.get(stale);
		Assert.isTrue(wheel.clear(stale));
		Assert.isFalse(wheel.clear(stale), "a handle cleared twice was cleared twice");

		var fired = 0;
		var next = wheel.setTimeoutVoid(0.010, () -> fired++);
		Assert.equals(node, @:privateAccess wheel.__table.get(next), "the cleared timer's node was not reused");
		Assert.isFalse(wheel.isActive(stale));
		Assert.isFalse(wheel.clear(stale), "a stale handle cleared the timer its node now carries");
		Assert.isFalse(wheel.reschedule(stale, 5.0));
		Assert.isFalse(wheel.setEnabled(stale, false));

		for (_ in 0...3) {
			wheel.advanceTime(0.010);
		}
		Assert.equals(1, fired, "the timer on the reused node did not fire");
		Assert.isTrue(wheel.isEmpty);
	}

	public function testATimerClearingItselfAndArmingAnotherFromItsCallback():Void {
		var wheel = new TimerWheel();
		var first = 0;
		var second = 0;
		var secondHandle:TimerHandle = TimerHandle.INVALID;
		var handle:TimerHandle = TimerHandle.INVALID;
		handle = wheel.setInterval(0.010, 0.010, h -> {
			first++;
			var firing:Dynamic = @:privateAccess wheel.__table.get(h);
			wheel.clear(h);
			secondHandle = wheel.setTimeoutVoid(0.020, () -> second++);
			Assert.isTrue(@:privateAccess wheel.__table.get(secondHandle) != firing, "a timer armed in a callback was given the node still firing");
		});

		wheel.advanceTime(0.010);
		Assert.equals(1, first);
		Assert.isFalse(wheel.isActive(handle));
		Assert.isTrue(wheel.isActive(secondHandle), "the timer armed in the callback was settled as the one that fired");
		for (_ in 0...4) {
			wheel.advanceTime(0.010);
		}
		Assert.equals(1, first, "the cleared interval fired again");
		Assert.equals(1, second);
		Assert.isTrue(wheel.isEmpty);
	}

	public function testAnIntervalRearmsOnItsOwnNode():Void {
		var wheel = new TimerWheel();
		var fired = 0;
		var handle = wheel.setIntervalVoid(0.010, 0.010, () -> fired++);
		var node:Dynamic = @:privateAccess wheel.__table.get(handle);
		for (_ in 0...5) {
			wheel.advanceTime(0.010);
		}
		Assert.equals(5, fired);
		Assert.equals(node, @:privateAccess wheel.__table.get(handle));
		Assert.equals(0, @:privateAccess wheel.__spare.length, "an interval re-arming gave up its node");
	}

	public function testATimeoutArmedInsideAnotherTimersCallback():Void {
		var wheel = new TimerWheel();
		var order:Array<String> = [];
		wheel.setTimeoutVoid(0.010, () -> {
			order.push("outer");
			wheel.setTimeoutVoid(0.005, () -> order.push("inner"));
		});
		wheel.advanceTime(0.010);
		Assert.same(["outer"], order);
		Assert.equals(1, @:privateAccess wheel.__spare.length, "the one-shot that ran was not kept for reuse");
		wheel.advanceTime(0.010);
		Assert.same(["outer", "inner"], order);
		Assert.isTrue(wheel.isEmpty);
	}

	public function testABurstOfTimersLeavesAtMostTheLimitSpare():Void {
		var wheel = new TimerWheel();
		var handles:Array<TimerHandle> = [];
		for (_ in 0...10000) {
			handles.push(wheel.setTimeoutVoid(0.050, () -> {}));
		}
		for (handle in handles) {
			wheel.clear(handle);
		}
		Assert.equals(TimerHeap.SPARE_LIMIT, @:privateAccess wheel.__spare.length, "a burst pinned its nodes");
		Assert.isNull(@:privateAccess wheel.__spare[0].voidCallback, "a spare node kept its cleared timer's callback");
		Assert.isTrue(wheel.isEmpty);
	}

	public function testATimerRescheduledFromItsCallbackAfterANestedPass():Void {
		// A pass run from inside a callback must not clear which timer is
		// firing: the callback's reschedule afterwards would link the timer into
		// a bucket, and the settle then free it there, still linked.
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

	public function testACallbackTakingItsHandleIsGivenItsOwnEachTime():Void {
		var wheel = new TimerWheel();
		for (_ in 0...300) {
			wheel.clear(wheel.setTimeoutVoid(0.010, () -> {}));
		}
		var seen:Array<Int> = [];
		var handle:TimerHandle = wheel.setInterval(0.010, 0.010, h -> seen.push(h));
		for (_ in 0...3) {
			wheel.advanceTime(0.010);
		}
		Assert.same([(handle : Int), (handle : Int), (handle : Int)], seen);
		wheel.clear(handle);

		var next:TimerHandle = wheel.setTimeout(0.010, h -> seen.push(h));
		wheel.advanceTime(0.010);
		Assert.equals((next : Int), seen[3], "a reused node passed the handle of the timer before");
	}

	public function testAHandleKeptAcrossThousandsOfTimersStaysCleared():Void {
		// See the heap's: a handle that is a slot and a twelve-bit generation.
		var wheel = new TimerWheel();
		var kept = wheel.setTimeoutVoid(0.010, () -> Assert.fail("a cleared timer fired"));
		Assert.isTrue(wheel.clear(kept));
		for (_ in 0...4095) {
			wheel.clear(wheel.setTimeoutVoid(0.010, () -> {}));
		}
		var fired = 0;
		var other = wheel.setTimeoutVoid(0.010, () -> fired++);
		Assert.isFalse(wheel.clear(kept), "a handle cleared 4,095 timers ago cleared the timer armed since");
		wheel.advanceTime(0.020);
		Assert.equals(1, fired);
		Assert.isFalse(wheel.isActive(other));
	}

	public function testANaNDelayIsRefusedAndAnInfiniteOneNeverFires():Void {
		var wheel = new TimerWheel();
		var fired = 0;
		var refused = 0;
		for (attempt in [() -> wheel.setTimeoutVoid(Math.NaN, () -> {}), () -> wheel.setIntervalVoid(1.0, Math.NaN, () -> {})]) {
			try {
				attempt();
			} catch (e:crossbyte.errors.ArgumentError) {
				refused++;
			}
		}
		Assert.equals(2, refused);
		var live = wheel.setTimeoutVoid(0.010, () -> fired++);
		try {
			wheel.reschedule(live, Math.NaN);
			Assert.fail("a NaN time was taken");
		} catch (e:crossbyte.errors.ArgumentError) {}
		wheel.setTimeoutVoid(-1.0, () -> fired++);
		var forever = wheel.setTimeoutVoid(Math.POSITIVE_INFINITY, () -> Assert.fail("an infinite delay fired"));
		for (_ in 0...300) {
			wheel.advanceTime(0.010);
		}
		Assert.equals(2, fired);
		Assert.isTrue(wheel.isActive(forever));
		Assert.isTrue(wheel.clear(forever));
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
