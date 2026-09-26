package crossbyte.timer;

import crossbyte._internal.system.timer.ResumePolicy;
import crossbyte._internal.system.timer.heap.TimerHeap;
import utest.Assert;

class TimerHeapTest extends utest.Test {
	public function testTimeoutFiresAfterDelay():Void {
		var heap = new TimerHeap();
		var fired = 0;

		heap.setTimeout(1.0, _ -> fired++);
		Assert.equals(0, heap.advanceTime(0.5));
		Assert.equals(0, fired);

		Assert.equals(1, heap.advanceTime(0.5));
		Assert.equals(1, fired);
		Assert.isTrue(heap.isEmpty);
	}

	public function testClearPreventsFire():Void {
		var heap = new TimerHeap();
		var fired = false;
		var handle = heap.setTimeout(1.0, _ -> fired = true);

		Assert.isTrue(heap.clear(handle));
		Assert.isTrue(heap.isEmpty);
		Assert.equals(0, heap.size);
		Assert.equals(null, heap.nextDue());
		Assert.equals(0, heap.advanceTime(1.0));
		Assert.isFalse(fired);
	}

	public function testCallbackClearingSelfDoesNotCorruptHeap():Void {
		var heap = new TimerHeap();
		var aFired = 0;

		// An interval timer that cancels itself while firing must not be
		// re-enqueued (or double-freed) after the callback returns.
		heap.setInterval(1.0, 1.0, h -> {
			aFired++;
			heap.clear(h);
		});

		Assert.equals(1, heap.advanceTime(1.0));
		Assert.equals(1, aFired);
		Assert.isTrue(heap.isEmpty);

		// The zombie must not resurface on later ticks.
		Assert.equals(0, heap.advanceTime(5.0));
		Assert.equals(1, aFired);

		// A fresh timer after the self-clear must still work (no slot aliasing).
		var bFired = 0;
		heap.setTimeout(1.0, _ -> bFired++);
		Assert.equals(1, heap.advanceTime(1.0));
		Assert.equals(1, bFired);
		Assert.isTrue(heap.isEmpty);
	}

	public function testIntervalReschedules():Void {
		var heap = new TimerHeap();
		var fired = 0;

		heap.setInterval(1.0, 1.0, _ -> fired++);
		Assert.equals(1, heap.advanceTime(1.0));
		Assert.equals(1, heap.advanceTime(1.0));
		Assert.equals(2, fired);
		Assert.isFalse(heap.isEmpty);
	}

	public function testClearDeferredOnPausedTimerFreesSlot():Void {
		var heap = new TimerHeap();
		var fired = 0;
		var handle = heap.setTimeout(1.0, _ -> fired++);

		// Pause removes the node from the queue and records pausedAt.
		Assert.isTrue(heap.setEnabled(handle, false));
		Assert.isTrue(heap.isEmpty);

		// clear(immediate=false) on a paused timer must free the slot now;
		// otherwise advanceTime never dequeues it and the slot leaks forever.
		Assert.isTrue(heap.clear(handle, false));
		Assert.isFalse(heap.isActive(handle));
		Assert.isTrue(heap.isEmpty);
		Assert.isTrue(heap.size == 0);

		// Advancing must not fire the cleared timer and must not resurface it.
		Assert.equals(0, heap.advanceTime(5.0));
		Assert.equals(0, fired);

		// The freed slot must be cleanly reusable by a fresh timer.
		var bFired = 0;
		var h2 = heap.setTimeout(1.0, _ -> bFired++);
		Assert.isFalse(heap.isActive(handle)); // stale handle still invalid
		Assert.isTrue(heap.isActive(h2));
		Assert.equals(1, heap.advanceTime(1.0));
		Assert.equals(1, bFired);
		Assert.isTrue(heap.isEmpty);
	}

	public function testGenerationWideningInvalidatesReusedSlotHandle():Void {
		var heap = new TimerHeap();

		// Create then clear a timer; capture the original handle.
		var oldHandle = heap.setTimeout(1.0, _ -> {});
		Assert.isTrue(heap.isActive(oldHandle));
		Assert.isTrue(heap.clear(oldHandle));
		Assert.isFalse(heap.isActive(oldHandle));

		// The freed slot is reused (LIFO) by the next create; the new handle
		// occupies the same id but a bumped generation, so the old handle must
		// no longer validate (no ABA aliasing).
		var newHandle = heap.setTimeout(1.0, _ -> {});
		Assert.isFalse(heap.isActive(oldHandle));
		Assert.isTrue(heap.isActive(newHandle));

		// Exercise the slot well past the old 8-bit (256) wrap boundary to
		// confirm the widened generation field never aliases back to oldHandle.
		var last = newHandle;
		for (i in 0...600) {
			Assert.isTrue(heap.clear(last));
			Assert.isFalse(heap.isActive(oldHandle));
			last = heap.setTimeout(1.0, _ -> {});
			Assert.isFalse(heap.isActive(oldHandle));
		}
		Assert.isTrue(heap.isActive(last));
		Assert.isTrue(heap.clear(last));
		Assert.isTrue(heap.isEmpty);
	}

	public function testARecurringTimerThatThrowsStaysArmed():Void {
		// Driven by hand, with nothing set to receive failures, a throw still
		// leaves advanceTime, but only once the timer is settled. It used to
		// leave from inside the call, with the timer already dequeued: its
		// handle went on reading as live and it never fired again.
		var heap = new TimerHeap();
		var fired = 0;
		var handle = heap.setInterval(1.0, 1.0, _ -> {
			fired++;
			throw "timer bug";
		});

		for (_ in 0...3) {
			try {
				heap.advanceTime(1.0);
				Assert.fail("with no onError the failure should propagate");
			} catch (e:Dynamic) {
				Assert.equals("timer bug", e);
			}
		}

		Assert.equals(3, fired);
		Assert.isTrue(heap.isActive(handle));
		Assert.equals(1, heap.size);
	}

	public function testATimerFailureGoesToOnErrorAndThePassCarriesOn():Void {
		var heap = new TimerHeap();
		var failures:Array<Dynamic> = [];
		heap.onError = error -> failures.push(error);
		var after = 0;

		heap.setTimeout(1.0, _ -> throw "one-shot bug");
		heap.setTimeout(1.0, _ -> after++);

		Assert.equals(2, heap.advanceTime(1.0));
		Assert.same(["one-shot bug"], failures);
		Assert.equals(1, after, "the timer after the one that threw waited for another pass");
		Assert.isTrue(heap.isEmpty, "the one-shot that threw was not freed");
	}

	public function testEveryDueTimerFiresInOnePass():Void {
		// There was a cap of 256 fires a pass, and the runtime never passed
		// anything but the default: past 256 due a frame, every timer ran
		// late, and later every frame.
		var heap = new TimerHeap();
		var fired = 0;
		for (_ in 0...1000) {
			heap.setTimeoutVoid(0.1, () -> fired++);
		}

		Assert.equals(1000, heap.advanceTime(0.1));
		Assert.equals(1000, fired);
		Assert.isFalse(heap.cutShort);
		Assert.equals(0, heap.overdue());
	}

	public function testABudgetSpreadsAPassAndCountsWhatItLeaves():Void {
		var heap = new TimerHeap();
		var fired = 0;
		for (_ in 0...100) {
			heap.setTimeoutVoid(0.1, () -> {
				fired++;
				__burn(0.0005);
			});
		}

		var first = heap.advanceTime(0.1, 0x7FFFFFFF, 0.002);
		Assert.isTrue(heap.cutShort, "a pass well over its budget was not cut short");
		Assert.isTrue(first < 100, "the budget did not stop the pass: " + first);
		Assert.equals(100 - first, heap.overdue());

		// What it left goes on the next passes, without the clock moving.
		var passes = 1;
		while (fired < 100 && passes < 100) {
			heap.advanceTime(0, 0x7FFFFFFF, 0.002);
			passes++;
		}
		Assert.equals(100, fired);
		Assert.isFalse(heap.cutShort);
		Assert.equals(0, heap.overdue());
	}

	public function testATimerArmedDuringAPassWaitsForTheNextOne():Void {
		// A callback that re-arms itself for now, polling until something
		// is ready, ran again inside the same pass until a cap stopped it.
		var heap = new TimerHeap();
		var runs = 0;
		function again():Void {
			runs++;
			heap.setTimeoutVoid(0, again);
		}
		heap.setTimeoutVoid(0.1, again);

		heap.advanceTime(0.1);
		Assert.equals(1, runs, "a timer re-armed for now ran again in the pass that armed it");
		Assert.equals(0, heap.overdue(), "one armed during the pass is not late");
		heap.advanceTime(1 / 60);
		Assert.equals(2, runs);
		heap.advanceTime(0);
		Assert.equals(3, runs);
	}

	public function testATimerRescheduledFromItsOwnCallbackRunsAtItsNewTime():Void {
		// It used to be freed once the callback returned, taking the new time
		// with it.
		var heap = new TimerHeap();
		var runs:Array<Float> = [];
		var handle = heap.setTimeout(1.0, h -> {
			runs.push(heap.time);
			if (runs.length == 1) {
				heap.reschedule(h, heap.time + 2.0);
			}
		});

		heap.advanceTime(1.0);
		Assert.isTrue(heap.isActive(handle), "the snoozed timer was freed");
		heap.advanceTime(1.0);
		heap.advanceTime(1.0);
		Assert.same([1.0, 3.0], runs);
		Assert.isFalse(heap.isActive(handle));
	}

	public function testARecurringTimerThatPausesItselfCanBeResumed():Void {
		// Pausing from its own callback used to free it instead.
		var heap = new TimerHeap();
		var runs = 0;
		var handle = heap.setInterval(1.0, 1.0, h -> {
			runs++;
			if (runs == 2) {
				heap.setEnabled(h, false);
			}
		});

		for (_ in 0...4) {
			heap.advanceTime(1.0);
		}
		Assert.equals(2, runs);
		Assert.isTrue(heap.isActive(handle), "pausing itself destroyed the timer");

		Assert.isTrue(heap.setEnabled(handle, true, ResumePolicy.FromNow));
		heap.advanceTime(1.0);
		Assert.equals(3, runs);
	}

	public function testATimerIsDueWhenTheClockReachesItByAnyPath():Void {
		// The clock is summed from frame deltas and a due time from the clock
		// plus a delay, and they round differently. From here, two 50ms steps
		// land a rounding error short of the 0.1s a timer asked for, and it
		// waited a whole frame more.
		var heap = new TimerHeap();
		for (_ in 0...16) {
			heap.advanceTime(1 / 60);
		}
		var fired = 0;
		heap.setTimeoutVoid(0.1, () -> fired++);

		heap.advanceTime(0.05);
		Assert.equals(0, fired);
		heap.advanceTime(0.05);
		Assert.equals(1, fired);
	}

	private static function __burn(seconds:Float):Void {
		var end = haxe.Timer.stamp() + seconds;
		while (haxe.Timer.stamp() < end) {}
	}

	public function testPauseResumeKeepPhaseFromZeroPreservesRemainingDelay():Void {
		var heap = new TimerHeap();
		var fired = 0;
		var handle = heap.setTimeout(1.0, _ -> fired++);

		Assert.isTrue(heap.setEnabled(handle, false));
		Assert.equals(0, heap.advanceTime(0.5));
		Assert.equals(0, fired);

		Assert.isTrue(heap.setEnabled(handle, true, ResumePolicy.KeepPhase, heap.time));
		Assert.equals(0, heap.advanceTime(0.99));
		Assert.equals(0, fired);

		Assert.equals(1, heap.advanceTime(0.01));
		Assert.equals(1, fired);
	}
}
