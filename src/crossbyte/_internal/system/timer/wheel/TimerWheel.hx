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
 *
 * So: many short timers, high churn, granularity to spare — the wheel. Few
 * timers, long or arbitrary delays, or exact ordering — the heap.
 */
class TimerWheel implements ITimerScheduler {
	/**
	 * Tick length. One millisecond is finer than any frame this runtime
	 * produces — the loop calls `advanceTime` once per frame, and the fastest
	 * configured rate is several milliseconds — so the wheel's granularity is
	 * never the coarsest thing in the chain.
	 */
	public static inline var RESOLUTION:Float = 0.001;

	/** Ticks held in the ring; the direct range is `BUCKETS * RESOLUTION`. */
	public static inline var BUCKETS:Int = 512;

	public var size(get, never):Int;
	public var isEmpty(get, never):Bool;
	public var time(get, never):Float;
	public final startTime:Float = HxTimer.stamp();

	@:noCompletion private var __buckets:Array<WheelNode>;
	@:noCompletion private var __overflow:WheelNode;
	@:noCompletion private var __cursor:Int = 0;
	@:noCompletion private var __now:Float = 0.0;
	@:noCompletion private var __accum:Float = 0.0;
	@:noCompletion private var __size:Int = 0;

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

	public inline function setTimeout(delay:Float, callback:TimerHandle->Void):TimerHandle {
		return __create(__now + delay, 0, callback);
	}

	public inline function setTimeoutVoid(delay:Float, callback:Void->Void):TimerHandle {
		return __create(__now + delay, 0, (handle:TimerHandle) -> callback());
	}

	public inline function setInterval(delay:Float, interval:Float, callback:TimerHandle->Void):TimerHandle {
		#if debug
		if (interval <= 0) {
			throw "interval must be > 0";
		}
		#end
		return __create(__now + delay, interval, callback);
	}

	public inline function setIntervalVoid(delay:Float, interval:Float, callback:Void->Void):TimerHandle {
		#if debug
		if (interval <= 0) {
			throw "interval must be > 0";
		}
		#end
		return __create(__now + delay, interval, (handle:TimerHandle) -> callback());
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
		__unlink(node);
		node.time = time;

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

		__link(node);
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
			var node:WheelNode = __buckets[(__cursor + offset) % BUCKETS];
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

	public function advanceTime(dt:Float, maxFires:Int = 256):Int {
		__now += dt;
		__accum += dt;

		var fired:Int = 0;
		var ticks:Int = 0;

		while (__accum >= RESOLUTION && fired < maxFires) {
			__accum -= RESOLUTION;
			__cursor = (__cursor + 1) % BUCKETS;
			fired += __fireBucket(__cursor, maxFires - fired);

			if (__cursor == 0) {
				__admitOverflow();
			}

			// One full revolution has visited every bucket, so anything still
			// held is scheduled beyond this pass. Continuing would spin the
			// ring for a stall nobody is waiting on, so the remaining whole
			// revolutions are dropped — the same call the frame loop makes
			// when it declares a stall unrecoverable rather than repaying it.
			if (++ticks >= BUCKETS) {
				var revolution:Float = BUCKETS * RESOLUTION;
				if (__accum >= revolution) {
					__accum = __accum % revolution;
				}
				break;
			}
		}

		return fired;
	}

	@:noCompletion private function __fireBucket(index:Int, budget:Int):Int {
		var node:WheelNode = __buckets[index];
		var fired:Int = 0;

		while (node != null && fired < budget) {
			var next:WheelNode = node.next;

			// Unlinked before the callback runs, so a callback that clears or
			// reschedules this timer operates on a node that is not in any
			// list — the same discipline the heap gets from dequeuing first.
			__unlinkFrom(index, node);

			if (!node.enabled) {
				__freeSlot(node.id);
				node = next;
				continue;
			}

			var id:Int = node.id;
			var gen:Int = gens[id];
			node.callback(new TimerHandle(id, gen));
			fired++;

			if (gens[id] != gen || nodes[id] != node) {
				// Freed or replaced by its own callback; nothing left to do.
			} else if (node.enabled && node.interval > 0) {
				node.time += node.interval;
				__link(node);
			} else {
				__freeSlot(id);
			}

			node = next;
		}

		return fired;
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

	@:noCompletion private function __create(time:Float, interval:Float, callback:TimerHandle->Void):TimerHandle {
		var id:Int;

		if (free.length > 0) {
			id = free.pop();
		} else {
			id = nodes.length;
			nodes.push(null);
			gens.push(0);
		}

		var node:WheelNode = new WheelNode(id, time, interval, callback);
		nodes[id] = node;
		__size++;
		__link(node);

		return new TimerHandle(id, gens[id]);
	}

	@:noCompletion private function __link(node:WheelNode):Void {
		var ticks:Int = Math.ceil((node.time - __now) / RESOLUTION);

		if (ticks < 0) {
			ticks = 0;
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

		// ceil rather than floor, so a timer is never reached before the time
		// it asked for; being late by under a tick is the wheel's trade, being
		// early would be a lie.
		var index:Int = (__cursor + ticks) % BUCKETS;
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

	/** Ring slot holding this node, or -1 when it is in overflow or detached. */
	public var bucket:Int = -1;

	public var prev:WheelNode;
	public var next:WheelNode;

	public inline function new(id:Int, time:Float, interval:Float, callback:TimerHandle->Void) {
		this.id = id;
		this.time = time;
		this.interval = interval;
		this.callback = callback;
	}
}
