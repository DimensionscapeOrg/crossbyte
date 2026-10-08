package crossbyte._internal.system.timer.heap;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import haxe.Timer as HxTimer;

class TimerHeap implements ITimerScheduler {
	/**
	 * How near the clock a timer counts as due. The clock is summed from frame
	 * deltas and a due time from the clock plus a delay, and the two round
	 * differently: two 50ms frames can fall a rounding error short of the
	 * 0.1s a 100ms timer is due at, which would leave it a whole frame late.
	 * A nanosecond is far below anything a timer is asked for.
	 */
	private static inline var DUE_EPSILON:Float = 1e-9;

	/**
	 * Most nodes kept for reuse once their timers are done.
	 *
	 * Without them a node is made for every timer armed, 80 bytes natively,
	 * and reliable UDP arms one per acknowledgement it holds, so a server
	 * would allocate one per message per session. A done node waits here
	 * for the next timer. The bound is what a burst can pin: a hundred
	 * thousand timers armed and cleared once leave 4,096 nodes behind, under
	 * a third of a megabyte natively. It covers the churn of a few thousand
	 * sessions a frame; a runtime arming more at once than that allocates
	 * for the rest.
	 */
	public static inline var SPARE_LIMIT:Int = 4096;

	public var size(get, never):Int;
	public var isEmpty(get, never):Bool;
	public var time(get, never):Float;
	public final startTime:Float = HxTimer.stamp();
	public var onError:Dynamic->Void = null;

	private final queue:TimerQueue = new TimerQueue();

	// The live timers by handle, and the next handle to give; see TimerHandle.
	private final __table:TimerTable<TimerNode> = new TimerTable<TimerNode>();
	private var __nextHandle:Int = 0;
	private var __handlesWrapped:Bool = false;

	// Nodes whose timers are done, for the next timers armed; see SPARE_LIMIT.
	private var __spare:Array<TimerNode> = [];

	private var __now:Float = 0.0;

	// Which pass of advanceTime this is, stamped on a node as it is armed; see
	// TimerNode.armPass. Wraps, and is only ever compared for equality.
	private var __pass:Int = 0;

	// Nodes a pass found due but that were armed during it, held back for the
	// next pass rather than fired by this one.
	private var __deferred:Array<TimerNode> = [];

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
		return createTimer(__now + checkDelay(delay), 0, callback, null);
	}

	public inline function setTimeoutVoid(delay:Float, callback:Void->Void):TimerHandle {
		return createTimer(__now + checkDelay(delay), 0, null, callback);
	}

	public inline function setInterval(delay:Float, interval:Float, callback:TimerHandle->Void):TimerHandle {
		checkInterval(interval);
		return createTimer(__now + checkDelay(delay), interval, callback, null);
	}

	public inline function setIntervalVoid(delay:Float, interval:Float, callback:Void->Void):TimerHandle {
		checkInterval(interval);
		return createTimer(__now + checkDelay(delay), interval, null, callback);
	}

	/**
		A delay as a timer is armed with it: a negative one is zero, due at
		the next pass, and an infinite one is never due, its timer held until
		cleared. NaN is refused: a NaN due time compares false with every
		other, so the heap could not order it, and at its root it would read
		as never due and stop every timer behind it.
	**/
	public static inline function checkDelay(delay:Float):Float {
		if (delay != delay) {
			throw new ArgumentError("A timer's delay is NaN. Give it a number of seconds: zero or less fires at the next pass, Infinity never.");
		}
		return delay > 0 ? delay : 0.0;
	}

	/** An interval as a timer is armed with it, NaN refused; see checkDelay. **/
	public static inline function checkInterval(interval:Float):Void {
		if (interval != interval) {
			throw new ArgumentError("A timer's interval is NaN. Give it a number of seconds above zero.");
		}
		#if debug
		if (interval <= 0) {
			throw "interval must be > 0";
		}
		#end
	}

	/** A time a timer is moved to, NaN refused; see checkDelay. **/
	public static inline function checkTime(time:Float):Float {
		if (time != time) {
			throw new ArgumentError("A timer's time is NaN. Give it a number of seconds.");
		}
		return time;
	}

	public function clear(handle:TimerHandle, immediate:Bool = true):Bool {
		var node:Null<TimerNode> = __table.get(handle);
		if (node == null) {
			return false;
		}

		if (immediate) {
			queue.remove(node);
			retire(node);
		} else if (node.isPaused()) {
			// A paused timer is not in the queue, so advanceTime will never
			// dequeue it to retire it. Retire it now or it stays live.
			retire(node);
		} else {
			node.enabled = false;
		}
		return true;
	}

	public inline function isActive(handle:TimerHandle):Bool {
		return __table.get(handle) != null;
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
		checkTime(time);
		var node:Null<TimerNode> = __table.get(handle);
		if (node == null) {
			return false;
		}

		node.time = time;
		node.armPass = __pass;
		if (node.firing) {
			// From its own callback: the new time is what it runs at next,
			// one-shot or not, instead of being freed or advanced by an
			// interval once the callback returns.
			node.rearmed = true;
		} else {
			queue.update(node);
		}
		return true;
	}

	public function delay(handle:TimerHandle, dt:Float):Bool {
		checkTime(dt);
		var node:Null<TimerNode> = __table.get(handle);
		if (node == null) {
			return false;
		}

		if (dt < 0) {
			return false;
		}

		node.time += dt;
		if (node.firing) {
			node.rearmed = true;
		} else {
			queue.update(node);
		}
		return true;
	}

	public function setEnabled(handle:TimerHandle, enabled:Bool, policy:ResumePolicy = KeepPhase, time:Float = 0.0):Bool {
		return setEnabledBy(handle, enabled, policy, time);
	}

	public function setEnabledBy(handle:TimerHandle, enabled:Bool, policy:ResumePolicy, time:Float):Bool {
		checkTime(time);
		var node:Null<TimerNode> = __table.get(handle);
		if (node == null) {
			return false;
		}

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
				if (node.isPaused()) {
					var pausedDur = t - node.pausedAt;
					if (pausedDur != 0.0) {
						node.time += pausedDur;
					}

					node.pausedAt = Math.NaN;
				}
			case FromNow:
				node.time = (node.interval > 0) ? (t + node.interval) : t;
				node.pausedAt = Math.NaN;
		}
		node.armPass = __pass;
		if (node.firing) {
			node.rearmed = true;
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
	 * Nothing is capped by count unless `maxFires` says so: with a cap, a
	 * runtime with more than that due each frame (a few hundred sessions
	 * each keeping a 50ms retransmit clock) would fall behind a little more
	 * every frame, without bound. A caller that must bound the pass gives
	 * it a `budget` of wall-clock seconds instead, which is what the runtime
	 * does, so a burst of work too big for one frame is spread over several
	 * rather than starving the sockets; what a budget leaves is reported by
	 * `overdue()` and `cutShort`.
	 *
	 * A timer armed during a pass never fires in that pass, however soon it
	 * is due: it waits for the next one. Without that, a callback re-arming
	 * itself for "now" (a poll-until-ready loop) would run for the whole
	 * budget every frame.
	 *
	 * @param maxFires Most timers to fire in this call. Unbounded by default.
	 * @param budget Wall-clock seconds this call may spend firing timers, or
	 *        zero or less for no limit. Checked every few fires.
	 */
	public function advanceTime(dt:Float, maxFires:Int = 0x7FFFFFFF, budget:Float = 0.0):Int {
		return advanceBy(dt, maxFires, budget);
	}

	/** `advanceTime` with every argument given: see `ITimerScheduler.advanceBy`. **/
	public function advanceBy(dt:Float, maxFires:Int, budget:Float):Int {
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
				retire(node);
			} else if (node.armPass == __pass) {
				// Once: one paused and resumed during the pass can come due
				// again in it, and is already held.
				if (!node.held) {
					node.held = true;
					__deferred.push(node);
				}
			} else {
				// Each callback is contained. A timer that throws is settled
				// exactly as if it had returned (a recurring one re-armed, a
				// one-shot freed), and only then is the failure passed on, so a
				// recurring timer is not left dequeued for good with its handle
				// still reading as live, and whatever is driving the scheduler is
				// not taken down with it.
				var failed:Bool = false;
				var failure:Dynamic = null;
				node.firing = true;
				node.rearmed = false;

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
						__call(node);
					} catch (error:Dynamic) {
						failed = true;
						failure = error;
					}
					i++;
					fired++;
					// Stop if the callback cleared or re-armed this timer through
					// its handle, or threw: the rest of the burst is not owed to
					// a callback that has just failed.
					if (failed || node.rearmed || node.handle == TimerHandle.INVALID) {
						break;
					}
				}
				node.firing = false;

				if (node.handle == TimerHandle.INVALID) {
					// Cleared by the callback, and done with now.
					__recycle(node);
				} else if (node.rearmed) {
					queue.enqueue(node);
				} else if (node.enabled && node.interval > 0) {
					node.time += i * node.interval;
					queue.enqueue(node);
				} else if (node.enabled || !node.isPaused()) {
					retire(node);
				}
				#else
				try {
					__call(node);
				} catch (error:Dynamic) {
					failed = true;
					failure = error;
				}
				fired++;
				node.firing = false;
				__settle(node);
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

	// Runs a timer's callback: a Void->Void one directly, one taking its
	// handle with the handle. Natively the handle goes boxed once per timer;
	// see TimerNode.handleBox.
	private inline function __call(node:TimerNode):Void {
		var direct:Void->Void = node.voidCallback;
		if (direct != null) {
			direct();
		} else {
			#if cpp
			var box:Dynamic = node.handleBox;
			if (box == null) {
				box = node.handleBox = node.handle;
			}
			var withHandle:Dynamic->Void = cast node.callback;
			withHandle(box);
			#else
			node.callback(node.handle);
			#end
		}
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
	// handle. One it cleared is retired already, so it is not re-enqueued or
	// retired again: its node is done. A node is not reused while its
	// callback runs, so it cannot be carrying some other timer by now.
	private inline function __settle(node:TimerNode):Void {
		if (node.handle == TimerHandle.INVALID) {
			// Cleared by its own callback, which has returned: nothing refers
			// to the node now.
			__recycle(node);
		} else if (node.rearmed) {
			// Given a new time by its own callback, which stands as given.
			queue.enqueue(node);
		} else if (node.enabled && node.interval > 0) {
			node.time += node.interval;
			queue.enqueue(node);
		} else if (node.enabled || !node.isPaused()) {
			// A one-shot that has run, or a timer cleared lazily from its own
			// callback. One that paused itself stays live, to be resumed.
			retire(node);
		}
	}

	// Returns what a pass held back to the queue, for the next pass.
	private function __readmit():Void {
		for (node in __deferred) {
			node.held = false;
			if (node.handle == TimerHandle.INVALID) {
				// Cleared while held back: retired then, the node free now.
				__recycle(node);
			} else if (node.heapIndex < 0 && !node.firing && !node.isPaused()) {
				if (node.enabled) {
					queue.enqueue(node);
				} else {
					// Cleared lazily while held back. No pass dequeues it to
					// retire it, so it is retired here, or its handle would stay
					// live for as long as the scheduler ran.
					retire(node);
				}
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

	private inline function createTimer(absoluteTime:Float, interval:Float, callback:TimerHandle->Void, voidCallback:Void->Void):TimerHandle {
		if (__table.size >= TimerHandle.MAX_TIMERS) {
			throw new IllegalOperationError("This runtime's timers are full: " + TimerHandle.MAX_TIMERS + " are already alive on it.");
		}
		var handle:Int = __newHandle();
		var n:TimerNode;
		if (__spare.length > 0) {
			n = __spare.pop();
			n.rearm(handle, absoluteTime, interval, callback, voidCallback);
		} else {
			n = new TimerNode(handle, absoluteTime, interval, callback, voidCallback);
		}
		n.armPass = __pass;
		__table.add(handle, n);
		queue.enqueue(n);
		return handle;
	}

	// The next handle: counted up, and once the count has started again, past
	// any handle a timer armed 2^31 timers ago still holds.
	private inline function __newHandle():Int {
		var handle:Int = __nextHandle;
		if (__handlesWrapped) {
			while (__table.get(handle) != null) {
				handle = (handle + 1) & TimerHandle.MAX_HANDLE;
			}
		}
		__nextHandle = (handle + 1) & TimerHandle.MAX_HANDLE;
		if (__nextHandle == 0) {
			__handlesWrapped = true;
		}
		return handle;
	}

	// Ends a timer, so its handle reads as cleared from now on. Its node goes
	// to the spares at once unless a callback is running for it or a pass
	// holds it back: then once that is over. One already ended is left alone,
	// so a node is never a spare twice.
	private inline function retire(node:TimerNode):Void {
		if (__table.remove(node.handle)) {
			node.handle = TimerHandle.INVALID;
			if (!node.firing && !node.held) {
				__recycle(node);
			}
		}
	}

	// A node no table, heap, pass or callback refers to any more, kept for
	// the next timer while there is room; see SPARE_LIMIT.
	private inline function __recycle(node:TimerNode):Void {
		node.release();
		if (__spare.length < SPARE_LIMIT) {
			__spare.push(node);
		}
	}
}
