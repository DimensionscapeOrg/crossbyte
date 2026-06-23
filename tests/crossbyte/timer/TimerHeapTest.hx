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
