package crossbyte._internal.system.timer.wheel;

import haxe.Timer as HxTimer;

/**
 * Timing wheel scheduler: an alternative to `TimerHeap` for runtimes that
 * hold a great many short timers and churn them constantly.
 *
 * The heap is the default and is the right default. It orders timers exactly,
 * treats a one microsecond delay and a six hour delay identically, and after
 * the position map was taken off its sift path it schedules thirty thousand
 * recurring timers in about forty milliseconds of CPU per simulated second.
 * This exists for the shape where the remaining O(log n) still shows: a timer
 * armed per entity or per connection and re-armed on every event, where the
 * work is in the arming rather than in the firing.
 *
 * ## How it trades
 *
 * Time is divided into `RESOLUTION` ticks and `BUCKETS` of them are held in a
 * ring. Arming a timer that falls inside the ring is an index calculation and
 * a list link — no comparisons, no sifting, no growth with the number of
 * timers already held. Firing a tick walks one bucket and nothing else.
 *
 * What it gives up:
 *
 * - **Granularity.** A timer fires when its bucket is reached, so it can be
 *   late by up to one tick. Buckets are chosen with `ceil`, so a timer is
 *   never *early* — a guarantee worth more than the millisecond, since code
 *   that reads a clock in its callback should never see a time before the one
 *   it asked for.
 * - **Range.** Anything beyond the ring waits in an unordered overflow list
 *   and is reconsidered once per revolution. A runtime whose timers are
 *   mostly long is doing a scan the heap would never do, and should use the
 *   heap.
 * - **Exact ordering.** Two timers in the same tick fire in bucket order, not
 *   by their exact times. The heap orders them precisely.
 * - **Catch-up past a revolution.** After a stall longer than the ring, the
 *   whole revolutions beyond the first are skipped rather than walked, so a
 *   recurring timer does not fire once for each tick it missed. The heap
 *   fires every one.
 *
 * So: many short timers, high churn, granularity to spare — the wheel. Few
 * timers, long or arbitrary delays, or exact ordering — the heap.
 *
 * ## Where a timer goes
 *
 * A bucket is chosen from the time of the tick the cursor last reached, not
 * from the scheduler's clock. The two differ during a pass: the clock has
 * already moved to the end of the frame while the cursor walks the frame one
 * tick at a time. Placing by the clock put a timer re-armed from a callback
 * behind the cursor, where it waited a whole revolution -- a `setInterval`
 * of five milliseconds fired twice a second at sixty frames a second -- and
 * put one armed in a callback early, a bucket counted from the end of the
 * frame but reached from its start. A timer due at or before the cursor
 * goes in the next bucket: the cursor's own has been walked already, and
 * `setTimeout(0)` sat there for a revolution, 517 milliseconds.
 */
class TimerWheel implements ITimerScheduler {
	/**
	 * Tick length. One millisecond is finer than any frame this runtime
	 * produces — the loop calls `advanceTime` once per frame, and the fastest
	 * configured rate is several milliseconds — so the wheel's granularity is
	 * never the coarsest thing in the chain.
	 */
	public static inline var RESOLUTION:Float = 0.001;

	/** Ticks held in the ring; the direct range is `BUCKETS * RESOLUTION`. A power of two. */
	public static inline var BUCKETS:Int = 512;

	/** Fires between reads of the clock while a budget is kept; see the heap. */
	private static inline var BUDGET_STRIDE:Int = 32;

	public var size(get, never):Int;
	public var isEmpty(get, never):Bool;
	public var time(get, never):Float;
	public final startTime:Float = HxTimer.stamp();
	public var onError:Dynamic->Void = null;
	public var cutShort(get, never):Bool;

	@:noCompletion private var __buckets:Array<WheelNode>;
	@:noCompletion private var __overflow:WheelNode;

	/**
	 * The bucket the cursor last reached, and how many ticks from the start
	 * that is. The cursor's time is `__tick * RESOLUTION`, kept as a count
	 * rather than a running sum so it never drifts from the clock. A Float,
	 * so it stays exact far past where an Int would wrap.
	 */
	@:noCompletion private var __cursor:Int = 0;
	@:noCompletion private var __tick:Float = 0;
	@:noCompletion private var __now:Float = 0.0;

	/** The tick the last pass meant to reach. */
	@:noCompletion private var __target:Float = 0;

	/** The bucket at the cursor still holds timers a budget stopped short of. */
	@:noCompletion private var __partial:Bool = false;
	@:noCompletion private var __cutShort:Bool = false;
	@:noCompletion private var __size:Int = 0;

	// The current pass's limits, kept here so the bucket walk can check them.
	@:noCompletion private var __fired:Int = 0;
	@:noCompletion private var __checkAt:Int = 0;
	@:noCompletion private var __maxFires:Int = 0;
	@:noCompletion private var __deadline:Float = 0;

	// The node whose callback is running, and whether that callback gave it a
	// new time itself; see the heap.
	@:noCompletion private var __firing:WheelNode = null;
	@:noCompletion private var __rearmed:Bool = false;

	@:noCompletion private var nodes:Array<WheelNode> = [];
	@:noCompletion private var gens:Array<Int> = [];
	@:noCompletion private var free:Array<Int> = [];

	public function new() {
		__buckets = [];
		for (i in 0...BUCKETS) {
			__buckets.push(null);
		}
	}

	private inline function get_size():Int {
		return __size;
	}

	private inline function get_isEmpty():Bool {
		return __size == 0;
	}

	public inline function get_time():Float {
		return __now;
	}

	private inline function get_cutShort():Bool {
		return __cutShort;
	}

	public inline function setTimeout(delay:Float, callback:TimerHandle->Void):TimerHandle {
		return __create(__now + delay, 0, callback, null);
	}

	public inline function setTimeoutVoid(delay:Float, callback:Void->Void):TimerHandle {
		return __create(__now + delay, 0, null, callback);
	}

	public inline function setInterval(delay:Float, interval:Float, callback:TimerHandle->Void):TimerHandle {
		#if debug
		if (interval <= 0) {
			throw "interval must be > 0";
		}
		#end
		return __create(__now + delay, interval, callback, null);
	}

	public inline function setIntervalVoid(delay:Float, interval:Float, callback:Void->Void):TimerHandle {
		#if debug
		if (interval <= 0) {
			throw "interval must be > 0";
		}
		#end
		return __create(__now + delay, interval, null, callback);
	}

	public inline function schedule(time:Float, callback:TimerHandle->Void):TimerHandle {
		return setTimeout(time - __now, callback);
	}

	public inline function scheduleVoid(time:Float, callback:Void->Void):TimerHandle {
		return setTimeoutVoid(time - __now, callback);
	}

	public function clear(handle:TimerHandle, immediate:Bool = true):Bool {
		if (!isActive(handle)) {
			return false;
		}

		var node:WheelNode = nodes[handle.id()];

		if (immediate) {
			__unlink(node);
			__freeSlot(node.id);
		} else if (node.pausedAt != null) {
			// Not linked anywhere, so no tick will ever reach it to free the
			// slot. Free it now or it leaks — the same case the heap calls out.
			__freeSlot(node.id);
		} else {
			node.enabled = false;
		}

		return true;
	}

	public inline function isActive(handle:TimerHandle):Bool {
		var id:Int = handle.id();
		return id >= 0 && id < nodes.length && nodes[id] != null && gens[id] == handle.gen();
	}

	public function reschedule(handle:TimerHandle, time:Float):Bool {
		if (!isActive(handle)) {
			return false;
		}

		var node:WheelNode = nodes[handle.id()];
		node.time = time;

		if (node == __firing) {
			// From its own callback: linked once the callback returns, at the
			// time it asked for, rather than freed or advanced by an interval.
			__rearmed = true;
			return true;
		}

		__unlink(node);
		if (node.enabled && node.pausedAt == null) {
			__link(node);
		}

		return true;
	}

	public function delay(handle:TimerHandle, dt:Float):Bool {
		if (dt < 0 || !isActive(handle)) {
			return false;
		}

		var node:WheelNode = nodes[handle.id()];
		return reschedule(handle, node.time + dt);
	}

	public function setEnabled(handle:TimerHandle, enabled:Bool, policy:ResumePolicy = KeepPhase, time:Float = 0.0):Bool {
		if (!isActive(handle)) {
			return false;
		}

		var node:WheelNode = nodes[handle.id()];

		if (node.enabled == enabled) {
			return true;
		}

		var t:Float = (time != 0.0) ? time : __now;

		if (!enabled) {
			node.enabled = false;
			node.pausedAt = t;
			__unlink(node);
			return true;
		}

		node.enabled = true;

		switch (policy) {
			case KeepPhase:
				if (node.pausedAt != null) {
					var paused:Float = t - node.pausedAt;
					if (paused != 0.0) {
						node.time += paused;
					}
					node.pausedAt = null;
				}
			case FromNow:
				node.time = (node.interval > 0) ? (t + node.interval) : t;
				node.pausedAt = null;
		}

		if (node == __firing) {
			__rearmed = true;
		} else {
			__link(node);
		}
		return true;
	}

	/**
	 * The soonest due time, or null when nothing is scheduled.
	 *
	 * Walks the ring and the overflow list, where the heap answers this from
	 * its root. Nothing in the runtime calls it per frame, so the wheel pays
	 * this cost only where a caller genuinely asks.
	 */
	public function nextDue():Null<Float> {
		var soonest:Null<Float> = null;

		for (offset in 0...BUCKETS) {
			var node:WheelNode = __buckets[(__cursor + offset) & (BUCKETS - 1)];
			while (node != null) {
				if (soonest == null || node.time < soonest) {
					soonest = node.time;
				}
				node = node.next;
			}

			if (soonest != null) {
				// A later bucket cannot hold anything sooner than one already
				// found in this pass, so stop at the first bucket with work.
				break;
			}
		}

		var node:WheelNode = __overflow;
		while (node != null) {
			if (soonest == null || node.time < soonest) {
				soonest = node.time;
			}
			node = node.next;
		}

		return soonest;
	}

	/**
	 * Walks the cursor up to the tick the new time has reached, firing each
	 * bucket on the way. Unbounded by count unless `maxFires` says so; see
	 * the heap for why, and for what `budget` does. A bucket a budget stops
	 * partway through is finished first by the next call.
	 */
	public function advanceTime(dt:Float, maxFires:Int = 0x7FFFFFFF, budget:Float = 0.0):Int {
		__now += dt;
		__cutShort = false;
		__fired = 0;
		__maxFires = maxFires;
		__checkAt = (budget > 0 && BUDGET_STRIDE < maxFires) ? BUDGET_STRIDE : maxFires;
		__deadline = budget > 0 ? HxTimer.stamp() + budget : 0.0;

		// The last tick whose time has been reached. The small allowance keeps
		// a clock summed from frame deltas from falling a whole tick short of
		// a boundary it has reached to within rounding.
		var target:Float = Math.ffloor(__now / RESOLUTION + 1e-7);
		__target = target;

		if (__partial) {
			__fireBucket(__cursor);
			if (__partial) {
				__cutShort = true;
				return __fired;
			}
		}

		var walked:Int = 0;
		while (__tick < target) {
			if (walked >= BUCKETS && target - __tick >= BUCKETS) {
				// A full revolution has been walked in this call and more are
				// still to go. Everything the ring held has been visited, and
				// anything re-armed on the way sits within a revolution of the
				// cursor, so the whole revolutions ahead hold nothing new: they
				// are skipped rather than spun through, for a stall -- a
				// suspend, a breakpoint -- that nobody is waiting on. The
				// same call the frame loop makes when it gives up schedule
				// debt. What they would have caught up on is late, not early.
				__tick += Math.ffloor((target - __tick) / BUCKETS) * BUCKETS;
				__admitOverflow();
				continue;
			}

			__tick += 1;
			__cursor = (__cursor + 1) & (BUCKETS - 1);
			walked++;

			if (__cursor == 0) {
				__admitOverflow();
			}

			__fireBucket(__cursor);
			if (__partial) {
				__cutShort = true;
				break;
			}
		}

		return __fired;
	}

	/**
	 * How many timers are due and still waiting because the last pass was
	 * cut short: those in the bucket it stopped in and in the buckets it
	 * did not reach. Zero after a pass that finished.
	 */
	public function overdue():Int {
		if (!__cutShort) {
			return 0;
		}

		var count:Int = 0;
		var ahead:Float = __target - __tick;
		var buckets:Int = ahead >= BUCKETS ? BUCKETS : Std.int(ahead);

		for (offset in (__partial ? 0 : 1)...(buckets + 1)) {
			var node:WheelNode = __buckets[(__cursor + offset) & (BUCKETS - 1)];
			while (node != null) {
				if (node.enabled) {
					count++;
				}
				node = node.next;
			}
		}

		var node:WheelNode = __overflow;
		while (node != null) {
			if (node.enabled && node.time <= __now) {
				count++;
			}
			node = node.next;
		}

		return count;
	}

	@:noCompletion private function __fireBucket(index:Int):Void {
		var node:WheelNode;

		// Taken from the head until the bucket is empty. Nothing linked while
		// it is walked can land in it: a bucket is chosen at least one tick
		// past the cursor's, and this is the cursor's.
		while ((node = __buckets[index]) != null) {
			if (__fired >= __checkAt) {
				if (__fired >= __maxFires || HxTimer.stamp() >= __deadline) {
					__partial = true;
					return;
				}
				__checkAt = (__fired + BUDGET_STRIDE < __maxFires) ? __fired + BUDGET_STRIDE : __maxFires;
			}

			// Unlinked before the callback runs, so a callback that clears or
			// reschedules this timer operates on a node that is not in any
			// list — the same discipline the heap gets from dequeuing first.
			__unlinkFrom(index, node);

			if (!node.enabled) {
				__freeSlot(node.id);
				continue;
			}

			var id:Int = node.id;
			var gen:Int = gens[id];

			// Contained, and settled as if it had returned before the failure
			// is passed on; see the heap, which does the same.
			var failed:Bool = false;
			var failure:Dynamic = null;
			__firing = node;
			__rearmed = false;
			try {
				// A Void->Void one directly; see TimerNode.voidCallback.
				var direct:Void->Void = node.voidCallback;
				if (direct != null) {
					direct();
				} else {
					node.callback(new TimerHandle(id, gen));
				}
			} catch (error:Dynamic) {
				failed = true;
				failure = error;
			}
			__fired++;
			__firing = null;

			if (gens[id] != gen || nodes[id] != node) {
				// Freed or replaced by its own callback; nothing left to do.
			} else if (__rearmed) {
				__link(node);
			} else if (node.enabled && node.interval > 0) {
				node.time += node.interval;
				__link(node);
			} else if (node.enabled || node.pausedAt == null) {
				// A one-shot that has run, or one cleared lazily from its own
				// callback. One that paused itself stays live, to be resumed.
				__freeSlot(id);
			}

			if (failed) {
				__fail(failure);
			}
		}

		__partial = false;
	}

	// Passes a callback's failure on, once the timer it came from is settled.
	@:noCompletion private function __fail(error:Dynamic):Void {
		if (onError != null) {
			onError(error);
			return;
		}

		#if cpp
		cpp.Lib.rethrow(error);
		#else
		throw error;
		#end
	}

	/**
	 * Moves overflow entries that have come within range into the ring.
	 *
	 * Run once per revolution rather than per tick: an entry cannot become
	 * reachable partway through one, since the ring covers a fixed span ahead
	 * of the cursor.
	 */
	@:noCompletion private function __admitOverflow():Void {
		var node:WheelNode = __overflow;
		__overflow = null;

		while (node != null) {
			var next:WheelNode = node.next;
			node.prev = null;
			node.next = null;
			node.bucket = -1;
			__link(node);
			node = next;
		}
	}

	@:noCompletion private function __create(time:Float, interval:Float, callback:TimerHandle->Void, voidCallback:Void->Void):TimerHandle {
		var id:Int;

		if (free.length > 0) {
			id = free.pop();
		} else {
			id = nodes.length;
			if (id >= TimerHandle.MAX_TIMERS) {
				// Past this the id no longer fits its handle; see the heap.
				throw "TimerWheel full: " + TimerHandle.MAX_TIMERS + " timers are already alive on this runtime";
			}
			nodes.push(null);
			gens.push(0);
		}

		var node:WheelNode = new WheelNode(id, time, interval, callback, voidCallback);
		nodes[id] = node;
		__size++;
		__link(node);

		return new TimerHandle(id, gens[id]);
	}

	@:noCompletion private function __link(node:WheelNode):Void {
		// Counted from the cursor's time, not the clock's; see the class notes.
		// ceil rather than floor, so a timer is never reached before the time
		// it asked for; being late by under a tick is the wheel's trade, being
		// early would be a lie. The allowance only absorbs rounding in the
		// subtraction. Kept a Float until it is known to be small: a timer
		// days out is more ticks than an Int holds, and one that wrapped
		// negative fired at once.
		var ticks:Float = Math.fceil((node.time - __tick * RESOLUTION) / RESOLUTION - 1e-9);

		if (ticks < 1) {
			// Due at or before the cursor, whose bucket has been walked.
			ticks = 1;
		}

		if (ticks >= BUCKETS) {
			node.bucket = -1;
			node.prev = null;
			node.next = __overflow;
			if (__overflow != null) {
				__overflow.prev = node;
			}
			__overflow = node;
			return;
		}

		var index:Int = (__cursor + Std.int(ticks)) & (BUCKETS - 1);
		node.bucket = index;
		node.prev = null;
		node.next = __buckets[index];

		if (node.next != null) {
			node.next.prev = node;
		}

		__buckets[index] = node;
	}

	@:noCompletion private inline function __unlink(node:WheelNode):Void {
		if (node.bucket >= 0) {
			__unlinkFrom(node.bucket, node);
		} else if (node.prev != null || node.next != null || __overflow == node) {
			__unlinkOverflow(node);
		}
	}

	@:noCompletion private function __unlinkFrom(index:Int, node:WheelNode):Void {
		if (node.prev != null) {
			node.prev.next = node.next;
		} else if (__buckets[index] == node) {
			__buckets[index] = node.next;
		}

		if (node.next != null) {
			node.next.prev = node.prev;
		}

		node.prev = null;
		node.next = null;
		node.bucket = -1;
	}

	@:noCompletion private function __unlinkOverflow(node:WheelNode):Void {
		if (node.prev != null) {
			node.prev.next = node.next;
		} else if (__overflow == node) {
			__overflow = node.next;
		}

		if (node.next != null) {
			node.next.prev = node.prev;
		}

		node.prev = null;
		node.next = null;
	}

	@:noCompletion private inline function __freeSlot(id:Int):Void {
		if (nodes[id] != null) {
			__size--;
		}

		nodes[id] = null;
		gens[id] = (gens[id] + 1) & TimerHandle.GEN_MASK;
		free.push(id);
	}
}

private class WheelNode {
	public var id:Int;
	public var time:Float;
	public var interval:Float;
	public var enabled:Bool = true;
	public var pausedAt:Null<Float> = null;
	public var callback:TimerHandle->Void;
	public var voidCallback:Void->Void;

	/** Ring slot holding this node, or -1 when it is in overflow or detached. */
	public var bucket:Int = -1;

	public var prev:WheelNode;
	public var next:WheelNode;

	public inline function new(id:Int, time:Float, interval:Float, callback:TimerHandle->Void, voidCallback:Void->Void) {
		this.id = id;
		this.time = time;
		this.interval = interval;
		this.callback = callback;
		this.voidCallback = voidCallback;
	}
}
