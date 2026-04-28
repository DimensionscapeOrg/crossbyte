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

	public function testIntervalReschedules():Void {
		var heap = new TimerHeap();
		var fired = 0;

		heap.setInterval(1.0, 1.0, _ -> fired++);
		Assert.equals(1, heap.advanceTime(1.0));
		Assert.equals(1, heap.advanceTime(1.0));
		Assert.equals(2, fired);
		Assert.isFalse(heap.isEmpty);
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
