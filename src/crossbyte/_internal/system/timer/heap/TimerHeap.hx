package crossbyte._internal.system.timer.heap;

import haxe.Timer as HxTimer;

class TimerHeap implements ITimerScheduler {
	/**
	 * How near the clock a timer counts as due. The clock is summed from frame
	 * deltas and a due time from the clock plus a delay, and the two round
	 * differently: two 50ms frames fell a rounding error short of the 0.1s a
	 * 100ms timer was due at, and it waited a whole frame more. A nanosecond
	 * is far below anything a timer is asked for.
	 */
	private static inline var DUE_EPSILON:Float = 1e-9;

	public var size(get, never):Int;
	public var isEmpty(get, never):Bool;
	public var time(get, never):Float;
	public final startTime:Float = HxTimer.stamp();
	public var onError:Dynamic->Void = null;

	private final queue:TimerQueue = new TimerQueue();
	private var nodes:Array<TimerNode> = [];
	private var gens:Array<Int> = [];
	private var free:Array<Int> = [];

	private var __now:Float = 0.0;

	// Which pass of advanceTime this is, stamped on a node as it is armed; see
	// TimerNode.armPass. Wraps, and is only ever compared for equality.
	private var __pass:Int = 0;

	// Nodes a pass found due but that were armed during it, held back for the
	// next pass rather than fired by this one.
	private var __deferred:Array<TimerNode> = [];

	// The node whose callback is running, and whether that callback gave it a
	// new time itself -- a reschedule, a delay or a resume through its own
	// handle -- which settling it afterwards has to respect.
	private var __firing:TimerNode = null;
	private var __rearmed:Bool = false;

	private var __cutShort:Bool = false;

	/**
	 * How many fires pass between reads of the clock while a budget is
	 * being kept. A read is tens of nanoseconds, so checking every fire
	 * would cost more than most callbacks; every 32 keeps it under a
	 * nanosecond a fire and overshoots a budget by 31 callbacks at most.
	 */
	private static inline var BUDGET_STRIDE:Int = 32;

	private inline function get_size():Int {
		return queue.size;
	}

	private inline function get_isEmpty():Bool {
		return queue.isEmpty;
	}

	public inline function get_time():Float {
		return __now;
	}

	public function new() {}

	public inline function setTimeout(delay:Float, callback:TimerHandle->Void):TimerHandle {
		return createTimer(__now + delay, 0, callback);
	}

	public inline function setTimeoutVoid(delay:Float, callback:Void->Void):TimerHandle {
		return createTimer(__now + delay, 0, (handle:Int) -> callback());
	}

	public inline function setInterval(delay:Float, interval:Float, callback:TimerHandle->Void):TimerHandle {
		#if debug
		if (interval <= 0) {
			throw "interval must be > 0";
		}
		#end
		return createTimer(__now + delay, interval, callback);
	}

	public inline function setIntervalVoid(delay:Float, interval:Float, callback:Void->Void):TimerHandle {
		#if debug
		if (interval <= 0) {
			throw "interval must be > 0";
		}
		#end
		return createTimer(__now + delay, interval, (handle:TimerHandle) -> callback());
	}

	public function clear(handle:TimerHandle, immediate:Bool = true):Bool {
		if (!isLive(handle)) {
			return false;
		}

		var node:TimerNode = nodes[handle.id()];
		if (immediate) {
			queue.remove(node);
			freeSlot(node.id);
		} else if (node.pausedAt != null) {
			// A paused timer is not in the queue, so advanceTime will never
			// dequeue it to free the slot. Free it now or the slot leaks.
			freeSlot(node.id);
		} else {
			node.enabled = false;
		}
		return true;
	}

	public inline function isActive(handle:TimerHandle):Bool {
		return isLive(handle);
	}

	public inline function schedule(time:Float, callback:TimerHandle->Void):TimerHandle {
		final delay:Float = time - this.time;
		return this.setTimeout(delay, callback);
	}

	public inline function scheduleVoid(time:Float, callback:Void->Void):TimerHandle {
		final delay:Float = time - this.time;
		return this.setTimeoutVoid(delay, callback);
	}

	public function reschedule(handle:TimerHandle, time:Float):Bool {
		if (!isLive(handle)) {
			return false;
		}

		var node:TimerNode = nodes[handle.id()];
		node.time = time;
		node.armPass = __pass;
		if (node == __firing) {
			// From its own callback: the new time is what it runs at next,
			// one-shot or not, instead of being freed or advanced by an
			// interval once the callback returns.
			__rearmed = true;
		} else {
			queue.update(node);
		}
		return true;
	}

	public function delay(handle:TimerHandle, dt:Float):Bool {
		if (!isLive(handle)) {
			return false;
		}

		if (dt < 0) {
			return false;
		}

		var node:TimerNode = nodes[handle.id()];
		node.time += dt;
		if (node == __firing) {
			__rearmed = true;
		} else {
			queue.update(node);
		}
		return true;
	}

	public function setEnabled(handle:TimerHandle, enabled:Bool, policy:ResumePolicy = KeepPhase, time:Float = 0.0):Bool {
		if (!isLive(handle)) {
			return false;
		}

		var node:TimerNode = nodes[handle.id()];
		if (node.enabled == enabled) {
			return true;
		}

		var t:Float = (time != 0.0) ? time : __now;

		if (!enabled) {
			node.enabled = false;
			node.pausedAt = t;
			queue.remove(node);
			return true;
		}

		node.enabled = true;
		switch (policy) {
			case KeepPhase:
				if (node.pausedAt != null) {
					var pausedDur = t - node.pausedAt;
					if (pausedDur != 0.0) {
						node.time += pausedDur;
					}

					node.pausedAt = null;
				}
			case FromNow:
				node.time = (node.interval > 0) ? (t + node.interval) : t;
				node.pausedAt = null;
		}
		node.armPass = __pass;
		if (node == __firing) {
			__rearmed = true;
		} else {
			queue.enqueue(node);
		}
		return true;
	}

	public inline function nextDue():Null<Float> {
		var t:TimerNode = queue.peek();
		return (t != null) ? t.time : null;
	}

	/**
	 * Fires every timer due by the new time, in order.
	 *
	 * There used to be a cap of 256 fires per call, and the runtime never
	 * passed anything else, so a runtime with more than that due each frame
	 * -- a few hundred sessions each keeping a 50ms retransmit clock -- fell
	 * behind a little more every frame, without bound: a 30 second idle
	 * timeout fired at 78. Nothing is capped by count now. A caller that
	 * must bound the pass gives it a `budget` of wall-clock seconds instead,
	 * which is what the runtime does, so a burst of work too big for one
	 * frame is spread over several rather than starving the sockets; what a
	 * budget leaves is reported by `overdue()` and `cutShort`.
	 *
	 * A timer armed during a pass never fires in that pass, however soon it
	 * is due: it waits for the next one. Without that, a callback re-arming
	 * itself for "now" -- a poll-until-ready loop -- would run for the whole
	 * budget every frame, where before the cap stopped it after 256.
	 *
	 * @param maxFires Most timers to fire in this call. Unbounded by default.
	 * @param budget Wall-clock seconds this call may spend firing timers, or
	 *        zero or less for no limit. Checked every few fires.
	 */
	public function advanceTime(dt:Float, maxFires:Int = 0x7FFFFFFF, budget:Float = 0.0):Int {
		__now += dt;
		__pass = (__pass + 1) | 0;
		__cutShort = false;

		if (queue.isEmpty) {
			return 0;
		}

		var fired:Int = 0;
		var checkAt:Int = (budget > 0 && BUDGET_STRIDE < maxFires) ? BUDGET_STRIDE : maxFires;
		var deadline:Float = budget > 0 ? HxTimer.stamp() + budget : 0.0;
		var top:TimerNode = queue.peek();

		while (top != null && top.time <= __now + DUE_EPSILON) {
			if (fired >= checkAt) {
				if (fired >= maxFires || HxTimer.stamp() >= deadline) {
					__cutShort = true;
					break;
				}
				checkAt = (fired + BUDGET_STRIDE < maxFires) ? fired + BUDGET_STRIDE : maxFires;
			}

			queue.dequeue();
			var node:TimerNode = top;

			if (!node.enabled) {
				freeSlot(node.id);
			} else if (node.armPass == __pass) {
				__deferred.push(node);
			} else {
				var gen:Int = gens[node.id];

				// Each callback is contained. A timer that throws is settled
				// exactly as if it had returned -- a recurring one re-armed, a
				// one-shot freed -- and only then is the failure passed on.
				// Letting it propagate from inside the call left a recurring
				// timer dequeued for good, its handle still reading as live,
				// and took whatever was driving the scheduler down with it.
				var failed:Bool = false;
				var failure:Dynamic = null;
				__firing = node;
				__rearmed = false;

				#if timer_burst_catchup
				var fires:Int = 1;
				if (node.interval > 0) {
					var steps:Int = Std.int(Math.floor((__now - node.time) / node.interval)) + 1;
					var room:Int = maxFires - fired;
					fires = (steps < 1) ? 1 : ((steps <= room) ? steps : room);
				}

				var i:Int = 0;
				while (i < fires && node.enabled) {
					try {
						node.callback(new TimerHandle(node.id, gen));
					} catch (error:Dynamic) {
						failed = true;
						failure = error;
					}
					i++;
					fired++;
					// Stop if the callback cleared or re-armed this timer through
					// its handle, or threw: the rest of the burst is not owed to
					// a callback that has just failed.
					if (failed || __rearmed || gens[node.id] != gen || nodes[node.id] != node) {
						break;
					}
				}
				__firing = null;

				if (gens[node.id] != gen || nodes[node.id] != node) {
					// freed by the callback; nothing to do
				} else if (__rearmed) {
					queue.enqueue(node);
				} else if (node.enabled && node.interval > 0) {
					node.time += i * node.interval;
					queue.enqueue(node);
				} else if (node.enabled || node.pausedAt == null) {
					freeSlot(node.id);
				}
				#else
				try {
					node.callback(new TimerHandle(node.id, gen));
				} catch (error:Dynamic) {
					failed = true;
					failure = error;
				}
				fired++;
				__firing = null;
				__settle(node, gen);
				#end

				if (failed) {
					__fail(failure);
				}
			}

			top = queue.peek();
		}

		if (__deferred.length > 0) {
			__readmit();
		}
		return fired;
	}

	/**
	 * Whether the last `advanceTime` stopped with timers still due, because
	 * its budget or its `maxFires` ran out.
	 */
	public var cutShort(get, never):Bool;

	private inline function get_cutShort():Bool {
		return __cutShort;
	}

	/**
	 * How many timers are due by `time` and still waiting, counting only
	 * those armed before the last pass began: what a budget left behind.
	 * One armed since, due at once, is not late yet.
	 *
	 * Walks only the part of the heap that is due, so it costs what it
	 * counts; intended for a metric read now and then, not for every frame.
	 */
	public function overdue():Int {
		return queue.countDue(__now + DUE_EPSILON, __pass);
	}

	// Puts a timer whose callback has just returned where it belongs next.
	// The callback may have cleared, rescheduled or paused it through its own
	// handle: if clear() freed the slot the generation no longer matches (or
	// the slot was reused), so it must not be re-enqueued or freed again.
	private inline function __settle(node:TimerNode, gen:Int):Void {
		if (gens[node.id] != gen || nodes[node.id] != node) {
			// already freed/replaced by the callback; nothing to do
		} else if (__rearmed) {
			// Given a new time by its own callback, which stands as given.
			queue.enqueue(node);
		} else if (node.enabled && node.interval > 0) {
			node.time += node.interval;
			queue.enqueue(node);
		} else if (node.enabled || node.pausedAt == null) {
			// A one-shot that has run, or a timer cleared lazily from its own
			// callback. One that paused itself stays live, to be resumed.
			freeSlot(node.id);
		}
	}

	// Returns what a pass held back to the queue, for the next pass.
	private function __readmit():Void {
		for (node in __deferred) {
			if (nodes[node.id] == node && node.heapIndex < 0 && node.enabled && node.pausedAt == null) {
				queue.enqueue(node);
			}
		}
		__deferred.resize(0);
	}

	// Passes a callback's failure on, once the timer it came from is settled.
	@:noCompletion private function __fail(error:Dynamic):Void {
		if (onError != null) {
			onError(error);
			return;
		}

		// Leaving the pass early: what it held back goes back first.
		__readmit();
		#if cpp
		cpp.Lib.rethrow(error);
		#else
		throw error;
		#end
	}

	private inline function createTimer(absoluteTime:Float, interval:Float, callback:TimerHandle->Void):TimerHandle {
		var id:Int;
		if (free.length > 0) {
			id = free.pop();
		} else {
			id = nodes.length;
			if (id >= TimerHandle.MAX_TIMERS) {
				// Past this the id no longer fits its handle, and a handle
				// would name some other timer.
				throw "TimerHeap full: " + TimerHandle.MAX_TIMERS + " timers are already alive on this runtime";
			}
			nodes.push(null);
			gens.push(0);
		}
		var n:TimerNode = new TimerNode(id, absoluteTime, interval, callback);
		n.armPass = __pass;
		nodes[id] = n;
		queue.enqueue(n);
		return new TimerHandle(id, gens[id]);
	}

	private inline function freeSlot(id:Int):Void {
		nodes[id] = null;
		gens[id] = (gens[id] + 1) & TimerHandle.GEN_MASK;
		free.push(id);
	}

	private inline function isLive(handle:TimerHandle):Bool {
		var id:Int = handle.id();
		return id >= 0 && id < nodes.length && nodes[id] != null && gens[id] == handle.gen();
	}
}
