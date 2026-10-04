package crossbyte.timer;

import crossbyte._internal.system.timer.ResumePolicy;
import crossbyte._internal.system.timer.TimerHandle;
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

		// The next timer takes what the cleared one left, and gets a handle of
		// its own: the old one must no longer validate (no ABA aliasing).
		var newHandle = heap.setTimeout(1.0, _ -> {});
		Assert.isFalse(heap.isActive(oldHandle));
		Assert.isTrue(heap.isActive(newHandle));

		// Well past where an 8-bit generation once wrapped back to oldHandle.
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

	public function testAHandleIsNeverNegative():Void {
		// A handle once carried a generation whose top bit was the sign bit,
		// so one could equal INVALID. Handles count up to MAX_HANDLE and start
		// again at zero, here from just short of the end.
		var heap = new TimerHeap();
		@:privateAccess heap.__nextHandle = TimerHandle.MAX_HANDLE - 2;
		var seen:Array<Int> = [];
		for (_ in 0...6) {
			var handle = heap.setTimeoutVoid(1.0, () -> {});
			seen.push(handle);
			heap.clear(handle);
		}
		Assert.same([TimerHandle.MAX_HANDLE - 2, TimerHandle.MAX_HANDLE - 1, TimerHandle.MAX_HANDLE, 0, 1, 2], seen);
	}

	// A handle a timer was given is never given again while it could still be
	// held: the count runs to 2^31 before it repeats. It was a slot and a
	// twelve-bit generation, slots reused the most recently freed first, so
	// a handle kept after its timer was cleared named whichever timer had
	// that slot 4,096 reuses later, and clearing it cancelled that timer.

	public function testAHandleKeptAcrossThousandsOfTimersStaysCleared():Void {
		for (reuses in [4095, 2 * 4096 - 1, 5000]) {
			var heap = new TimerHeap();
			var kept = heap.setTimeoutVoid(1.0, () -> Assert.fail("a cleared timer fired"));
			Assert.isTrue(heap.clear(kept));
			for (_ in 0...reuses) {
				heap.clear(heap.setTimeoutVoid(1.0, () -> {}));
			}

			var fired = 0;
			var other = heap.setTimeoutVoid(1.0, () -> fired++);
			Assert.isTrue((other : Int) != (kept : Int), "a handle was given twice, after " + reuses + " timers");
			Assert.isFalse(heap.clear(kept), "a handle cleared " + reuses + " timers ago cleared the timer armed since");
			Assert.isTrue(heap.isActive(other));
			heap.advanceTime(1.0);
			Assert.equals(1, fired, "the timer armed last did not fire after " + reuses + " timers");
		}
	}

	public function testTimersArmedTogetherDoNotCrowdTheTable():Void {
		// Handles are counted, so timers armed together have consecutive
		// handles. Placed by their low bits, 10,000 long-lived ones filled one
		// solid run of the table, and each later handle whose place fell
		// inside it walked the run: arming and clearing a timer went from
		// 0.11 to 2.6 microseconds. The longest run of taken places says it
		// without a clock.
		var heap = new TimerHeap();
		for (i in 0...10000) {
			heap.setTimeoutVoid(1000.0 + i, () -> {});
		}
		var longest = 0;
		for (round in 0...4) {
			for (_ in 0...8192) {
				heap.clear(heap.setTimeoutVoid(10.0, () -> {}));
			}
			for (_ in 0...512) {
				heap.setTimeoutVoid(5.0, () -> {});
			}
			var keys:haxe.ds.Vector<Int> = @:privateAccess heap.__table.__keys;
			var run = 0;
			// Twice round, so a run across the end is counted whole.
			for (i in 0...keys.length * 2) {
				if (keys[i % keys.length] != TimerHandle.INVALID) {
					run++;
					if (run > longest) {
						longest = run;
					}
				} else {
					run = 0;
				}
			}
			heap.advanceTime(5.0);
		}
		Assert.equals(10000, heap.size);
		Assert.isTrue(longest < 100, 'a run of $longest taken places');
	}

	public function testHandlesStartingAgainPassOneStillHeld():Void {
		// Once the count has run out it starts again at zero, and a timer
		// armed back then may still hold a handle it comes to.
		var heap = new TimerHeap();
		var fired = 0;
		var old = heap.setTimeoutVoid(5.0, () -> fired++);
		Assert.equals(0, (old : Int));
		@:privateAccess heap.__nextHandle = TimerHandle.MAX_HANDLE;
		var last = heap.setTimeoutVoid(1.0, () -> {});
		var next = heap.setTimeoutVoid(1.0, () -> {});
		Assert.equals(TimerHandle.MAX_HANDLE, (last : Int));
		Assert.equals(1, (next : Int), "the count started again on a handle still held");
		Assert.isTrue(heap.isActive(old));
		heap.advanceTime(5.0);
		Assert.equals(1, fired);
	}

	public function testANaNDelayIsRefusedAndStopsNothing():Void {
		// One NaN due time stopped every timer on the heap: it compares false
		// with every other, and at the root read as never due.
		var heap = new TimerHeap();
		var fired = 0;
		for (i in 0...20) {
			heap.setTimeoutVoid(0.1 + i * 0.01, () -> fired++);
		}
		var refused = 0;
		for (attempt in [() -> heap.setTimeoutVoid(Math.NaN, () -> {}), () -> heap.setTimeout(Math.NaN, _ -> {}),
			() -> heap.setIntervalVoid(Math.NaN, 1.0, () -> {}), () -> heap.setIntervalVoid(1.0, Math.NaN, () -> {}),
			() -> heap.scheduleVoid(Math.NaN, () -> {})]) {
			try {
				attempt();
			} catch (e:crossbyte.errors.ArgumentError) {
				refused++;
			}
		}
		Assert.equals(5, refused, "a NaN delay, interval or time was taken");

		var live = heap.setTimeoutVoid(0.2, () -> fired++);
		for (move in [() -> heap.reschedule(live, Math.NaN), () -> heap.delay(live, Math.NaN), () -> heap.setEnabled(live, false, KeepPhase, Math.NaN)]) {
			try {
				move();
				Assert.fail("a NaN time was taken");
			} catch (e:crossbyte.errors.ArgumentError) {}
		}

		for (i in 0...20) {
			heap.setTimeoutVoid(0.3 + i * 0.01, () -> fired++);
		}
		heap.advanceTime(1.0);
		Assert.equals(41, fired, "timers armed around a NaN did not all fire");
		Assert.isTrue(heap.isEmpty);
	}

	public function testNegativeAndInfiniteDelays():Void {
		// Negative counts as zero: due at the next pass. Infinite is never
		// due, and its timer is held until cleared.
		var heap = new TimerHeap();
		var soon = 0;
		var never = 0;
		heap.setTimeoutVoid(-5.0, () -> soon++);
		heap.setTimeoutVoid(Math.NEGATIVE_INFINITY, () -> soon++);
		var forever = heap.setTimeoutVoid(Math.POSITIVE_INFINITY, () -> never++);
		heap.advanceTime(0);
		Assert.equals(2, soon);
		for (_ in 0...10) {
			heap.advanceTime(1e9);
		}
		Assert.equals(0, never);
		Assert.isTrue(heap.isActive(forever));
		Assert.isTrue(heap.clear(forever));
		Assert.isTrue(heap.isEmpty);
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

	// A done timer's node carries the next timer armed. A handle is a number
	// given once, never a node, so what a cleared handle can reach does not
	// depend on which node a timer is given: these hold whichever it is.

	public function testClearingAHandleTwiceClearsNothingElse():Void {
		var heap = new TimerHeap();
		var fired = 0;
		var handle = heap.setTimeoutVoid(1.0, () -> Assert.fail("a cleared timer fired"));
		var other = heap.setTimeoutVoid(1.0, () -> fired++);

		Assert.isTrue(heap.clear(handle));
		Assert.isFalse(heap.clear(handle), "a handle cleared twice was cleared twice");
		Assert.isFalse(heap.clear(handle, false));
		Assert.isTrue(heap.isActive(other));
		Assert.equals(1, heap.advanceTime(1.0));
		Assert.equals(1, fired);
	}

	public function testAClearedHandleCannotReachTheTimerItsNodeNowCarries():Void {
		var heap = new TimerHeap();
		var stale = heap.setTimeoutVoid(1.0, () -> Assert.fail("a cleared timer fired"));
		var node = @:privateAccess heap.__table.get(stale);
		Assert.isTrue(heap.clear(stale));

		var fired = 0;
		var next = heap.setTimeoutVoid(1.0, () -> fired++);
		Assert.equals(node, @:privateAccess heap.__table.get(next), "the cleared timer's node was not reused");

		Assert.isFalse(heap.isActive(stale));
		Assert.isFalse(heap.clear(stale), "a stale handle cleared the timer its node now carries");
		Assert.isFalse(heap.reschedule(stale, 50.0));
		Assert.isFalse(heap.delay(stale, 50.0));
		Assert.isFalse(heap.setEnabled(stale, false));
		Assert.isTrue(heap.isActive(next));

		Assert.equals(1, heap.advanceTime(1.0));
		Assert.equals(1, fired, "the timer on the reused node did not fire");
		Assert.isFalse(heap.clear(stale));
	}

	public function testATimerClearingItselfAndArmingAnotherFromItsCallback():Void {
		// The node whose callback is running is not handed to a timer armed
		// in that callback: the pass still has it to settle.
		var heap = new TimerHeap();
		var first = 0;
		var second = 0;
		var firstNode:Dynamic = null;
		var secondHandle:TimerHandle = TimerHandle.INVALID;
		var handle:TimerHandle = TimerHandle.INVALID;
		handle = heap.setInterval(1.0, 1.0, h -> {
			first++;
			firstNode = @:privateAccess heap.__table.get(h);
			heap.clear(h);
			secondHandle = heap.setTimeoutVoid(2.0, () -> second++);
			Assert.isTrue(@:privateAccess heap.__table.get(secondHandle) != firstNode, "a timer armed in a callback was given the node still firing");
		});

		heap.advanceTime(1.0);
		Assert.equals(1, first);
		Assert.isFalse(heap.isActive(handle));
		Assert.isTrue(heap.isActive(secondHandle), "the timer armed in the callback was settled as the one that fired");
		heap.advanceTime(1.0);
		Assert.equals(0, second);
		heap.advanceTime(1.0);
		Assert.equals(1, first, "the cleared interval fired again");
		Assert.equals(1, second);
		Assert.isTrue(heap.isEmpty);
	}

	public function testAnIntervalRearmsOnItsOwnNode():Void {
		var heap = new TimerHeap();
		var fired = 0;
		var handle = heap.setIntervalVoid(1.0, 1.0, () -> fired++);
		var node = @:privateAccess heap.__table.get(handle);

		for (_ in 0...5) {
			heap.advanceTime(1.0);
		}
		Assert.equals(5, fired);
		Assert.isTrue(heap.isActive(handle));
		Assert.equals(node, @:privateAccess heap.__table.get(handle));
		Assert.equals(0, @:privateAccess heap.__spare.length, "an interval re-arming gave up its node");
	}

	public function testATimeoutArmedInsideAnotherTimersCallback():Void {
		var heap = new TimerHeap();
		var order:Array<String> = [];
		var outer = heap.setTimeoutVoid(1.0, () -> {
			order.push("outer");
			heap.setTimeoutVoid(0.5, () -> order.push("inner"));
		});
		var outerNode = @:privateAccess heap.__table.get(outer);

		heap.advanceTime(1.0);
		Assert.same(["outer"], order);
		Assert.equals(1, heap.size);
		// The one-shot that ran is done, and its node is spare for the next.
		Assert.equals(outerNode, @:privateAccess heap.__spare[0]);
		heap.advanceTime(0.5);
		Assert.same(["outer", "inner"], order);
		Assert.isTrue(heap.isEmpty);
	}

	public function testASparesNodeHoldsNoCallback():Void {
		// A cleared timer's closure is not kept alive by its node waiting to
		// be reused.
		var heap = new TimerHeap();
		heap.clear(heap.setTimeoutVoid(1.0, () -> {}));
		heap.clear(heap.setTimeout(1.0, _ -> {}));
		var spares:Array<crossbyte._internal.system.timer.TimerNode> = @:privateAccess heap.__spare;
		Assert.equals(1, spares.length);
		Assert.isNull(spares[0].callback);
		Assert.isNull(spares[0].voidCallback);
	}

	public function testABurstOfTimersLeavesAtMostTheLimitSpare():Void {
		var heap = new TimerHeap();
		var handles:Array<TimerHandle> = [];
		for (_ in 0...10000) {
			handles.push(heap.setTimeoutVoid(1.0, () -> {}));
		}
		for (handle in handles) {
			heap.clear(handle);
		}
		Assert.equals(TimerHeap.SPARE_LIMIT, @:privateAccess heap.__spare.length, "a burst pinned its nodes");
		Assert.isTrue(heap.isEmpty);

		// And the slots and the spares serve the next burst.
		var fired = 0;
		for (_ in 0...1000) {
			heap.setTimeoutVoid(1.0, () -> fired++);
		}
		Assert.equals(TimerHeap.SPARE_LIMIT - 1000, @:privateAccess heap.__spare.length);
		Assert.equals(1000, heap.advanceTime(1.0));
		Assert.equals(1000, fired);
	}

	public function testATimerClearedLazilyWhileHeldBackIsFreed():Void {
		// Armed during a pass and due in it, it is held back for the next
		// pass; cleared lazily meanwhile, nothing dequeued it to free its
		// slot, and its handle read as live for as long as the heap ran.
		var heap = new TimerHeap();
		var held:TimerHandle = TimerHandle.INVALID;
		heap.setTimeoutVoid(1.0, () -> {
			// Due before the timer below fires, so this pass reaches it first.
			held = heap.setTimeoutVoid(0, () -> Assert.fail("a cleared timer fired"));
			heap.reschedule(held, 1.2);
		});
		heap.setTimeoutVoid(1.5, () -> Assert.isTrue(heap.clear(held, false)));

		heap.advanceTime(2.0);
		Assert.isFalse(heap.isActive(held), "a timer cleared while held back stayed alive");
		heap.advanceTime(1.0);
		Assert.isFalse(heap.isActive(held));
		Assert.isTrue(heap.isEmpty);
	}

	public function testATimerRescheduledFromItsCallbackAfterANestedPass():Void {
		// Which timer's callback was running was one field of the heap, and a
		// pass run from inside a callback, a nested pump, cleared it: the
		// callback's own reschedule afterwards was lost, and the timer freed.
		var heap = new TimerHeap();
		var runs:Array<Float> = [];
		var nested = 0;
		var handle = heap.setTimeout(1.0, h -> {
			runs.push(heap.time);
			if (runs.length == 1) {
				heap.setTimeoutVoid(0, () -> nested++);
				heap.advanceTime(0);
				heap.reschedule(h, heap.time + 2.0);
			}
		});

		heap.advanceTime(1.0);
		Assert.equals(1, nested, "the nested pass fired nothing");
		Assert.isTrue(heap.isActive(handle), "the timer rescheduled after a nested pass was freed");
		heap.advanceTime(1.0);
		heap.advanceTime(1.0);
		Assert.same([1.0, 3.0], runs);
		Assert.isFalse(heap.isActive(handle));
	}

	public function testATimerResumedFromItsCallbackAfterANestedPassCanBeCleared():Void {
		// The path `crossbyte.Timer.pause` and `resume` take. Resumed after a
		// nested pass, the one-shot went back in the heap and had its slot
		// freed as if it had run: its handle read as cleared, nothing could
		// clear it, and the resume was lost.
		var heap = new TimerHeap();
		var runs = 0;
		var nested = 0;
		var handle = heap.setTimeout(1.0, h -> {
			runs++;
			if (runs == 1) {
				heap.setTimeoutVoid(0, () -> nested++);
				heap.advanceTime(0);
				heap.setEnabled(h, false);
				heap.setEnabled(h, true, ResumePolicy.FromNow);
			}
		});

		heap.advanceTime(1.0);
		Assert.equals(1, nested, "the nested pass fired nothing");
		Assert.isTrue(heap.isActive(handle), "a timer resumed after a nested pass lost its handle");
		Assert.isTrue(heap.clear(handle), "a timer resumed after a nested pass could not be cleared");
		heap.advanceTime(1.0);
		Assert.equals(1, runs, "a cleared timer fired");
		Assert.isTrue(heap.isEmpty);
	}

	public function testACallbackTakingItsHandleIsGivenItsOwnEachTime():Void {
		// Natively the handle is boxed once per timer; a reused node must not
		// hand the next timer the box of the one before.
		var heap = new TimerHeap();
		for (_ in 0...300) {
			heap.clear(heap.setTimeoutVoid(1.0, () -> {}));
		}
		var seen:Array<Int> = [];
		var handle:TimerHandle = TimerHandle.INVALID;
		handle = heap.setInterval(1.0, 1.0, h -> seen.push(h));
		for (_ in 0...3) {
			heap.advanceTime(1.0);
		}
		Assert.same([(handle : Int), (handle : Int), (handle : Int)], seen);
		heap.clear(handle);

		var next:TimerHandle = heap.setTimeout(1.0, h -> seen.push(h));
		Assert.isTrue((next : Int) != (handle : Int));
		heap.advanceTime(1.0);
		Assert.equals((next : Int), seen[3], "a reused node passed the handle of the timer before");
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
