package crossbyte._internal.system.timer;

import crossbyte._internal.system.timer.heap.TimerHeap;
import crossbyte.core.TimerStrategy;

/**
 * An abstract wrapper around `ITimerScheduler`, providing a unified and extensible
 * timer API backed by a heap-based implementation (`TimerHeap`) by default.
 *
 * `TimerScheduler` allows for setting one-shot and recurring timers, pausing,
 * resuming, and rescheduling them. It can be polled using `tick()` to dispatch
 * due callbacks, making it suitable for both game loops and event-driven systems.
 *
 * The default implementation is based on a min-heap, but future variants like
 * timer wheels can be plugged in by implementing `ITimerScheduler`.
 *
 * Both schedulers number the timers they arm, so a handle is not given again
 * until 2^31 timers have been armed, and a cleared one stays inert (see
 * `TimerHandle`). Both refuse a NaN delay, interval or time with an
 * `ArgumentError`; a negative delay counts as zero, and an infinite one never
 * fires, its timer held until cleared.
 */
@:forward(startTime, onError)
abstract TimerScheduler(ITimerScheduler) from ITimerScheduler to ITimerScheduler {
	/**
	 * The number of active timers currently managed by the scheduler.
	 */
	public var size(get, never):Int;

	/**
	 * Whether the scheduler has no active timers.
	 */
	public var isEmpty(get, never):Bool;

	/**
	 * Monotonic elapsed time maintained by the scheduler.
	 *
	 * - Starts at `0.0` when the scheduler is created.
	 * - Advances only when `advanceTime(dt)` is called, by the amount of `dt`.
	 * - Always increases or stays the same (never decreases).
	 *
	 * Use this for relative timing.
	 * 
	 * For absolute wall-clock time, call `haxe.Timer.stamp()`
	 * directly. 
	 * 
	 * This property is intentionally decoupled from system clock.
	 */
	public var time(get, never):Float;

	private inline function get_size():Int {
		return this.size;
	}

	private inline function get_isEmpty():Bool {
		return this.isEmpty;
	}

	public inline function get_time():Float {
		return this.time;
	}

	/**
	 * Creates a new `TimerScheduler` using the given strategy.
	 *
	 * Resolved per instance rather than per build, because a process can run
	 * several runtimes and they need not agree: a simulation thread holding a
	 * timer per entity and a network thread holding a handful want different
	 * structures, and a compile flag cannot say so. There is no cost to
	 * deciding it here: this abstract calls through `ITimerScheduler`
	 * either way, so nothing would be saved by fixing it at build time.
	 *
	 * See `crossbyte.core.TimerStrategy` for which to pick.
	 */
	public inline function new(strategy:TimerStrategy = HEAP) {
		this = switch (strategy) {
			case WHEEL: new crossbyte._internal.system.timer.wheel.TimerWheel();
			case HEAP: new TimerHeap();
		}
	}

	/**
	 * Schedules a one-shot timer to fire after a delay (in seconds).
	 * The callback receives the actual fire time.
	 *
	 * @param delay Seconds from now to fire the timer.
	 * @param callback A function that receives the current time when the timer fires.
	 * @return A handle used to manage the timer.
	 */
	overload extern public inline function setTimeout(delay:Float, callback:Int->Void):Int {
		return this.setTimeout(delay, callback);
	}

	/**
	 * Schedules a one-shot timer from a specific start time.
	 * The callback does not receive any parameters.
	 *
	 * @param startTime Start time in seconds.
	 * @param delay Seconds after start time to fire.
	 * @param callback A function to invoke when the timer fires.
	 * @return A handle used to manage the timer.
	 */
	overload extern public inline function setTimeout(delay:Float, callback:Void->Void):Int {
		return this.setTimeoutVoid(delay, callback);
	}

	/**
	 * Schedules a repeating timer starting at a given time and repeating
	 * at the specified interval. The callback receives the current time.
	 *
	 * @param startTime When the first fire should occur (in seconds).
	 * @param delay How often to repeat (in seconds).
	 * @param callback A function receiving the current time each fire.
	 * @return A handle used to manage the timer.
	 */
	overload extern public inline function setInterval(delay:Float, interval:Float, callback:Int->Void):Int {
		return this.setInterval(delay, interval, callback);
	}

	/**
	 * Schedules a repeating timer without parameters.
	 *
	 * @param startTime When to start (in seconds).
	 * @param delay Interval duration (in seconds).
	 * @param callback A function to invoke each interval.
	 * @return A handle used to manage the timer.
	 */
	overload extern public inline function setInterval(delay:Float, interval:Float, callback:Void->Void):Int {
		return this.setIntervalVoid(delay, interval, callback);
	}

	/**
	 * Cancels a previously scheduled timer.
	 *
	 * @param handle The timer handle to clear.
	 * @return `true` if the timer was active and cleared, `false` otherwise.
	 */
	public inline function clear(handle:Int):Bool {
		return this.clear(handle);
	}

	/**
	 * Checks if a given timer is currently active.
	 *
	 * @param handle The timer handle to check.
	 * @return `true` if the timer is active.
	 */
	public inline function isActive(handle:Int):Bool {
		return this.isActive(handle);
	}

	/**
	 * Schedules a callback to fire at a specific virtual time.
	 *
	 * This variant passes the timer handle into the callback when it is invoked.
	 *
	 * @param time The absolute virtual time at which the callback should fire.
	 * @param callback A function that receives the `TimerHandle` of the scheduled timer.
	 * @return A handle that can be used to pause, resume, or clear the timer.
	 */
	overload extern public inline function schedule(time:Float, callback:TimerHandle->Void):TimerHandle {
		return this.schedule(time, callback);
	}

	/**
	 * Schedules a callback to fire at a specific virtual time.
	 *
	 * This variant invokes a simple function with no parameters.
	 *
	 * @param time The absolute virtual time at which the callback should fire.
	 * @param callback A function to call when the virtual time is reached.
	 * @return A handle that can be used to pause, resume, or clear the timer.
	 */
	overload extern public inline function schedule(time:Float, callback:Void->Void):TimerHandle {
		return this.scheduleVoid(time, callback);
	}

	/**
	 * Reschedules a timer to fire at a new time.
	 *
	 * @param handle The timer handle to modify.
	 * @param time The new time (in seconds) to fire.
	 * @return `true` if rescheduled successfully.
	 */
	public function reschedule(handle:Int, time:Float):Bool {
		return this.reschedule(handle, time);
	}

	/**
	 * Enables or disables a timer.
	 *
	 * @param handle The timer handle.
	 * @param enabled Whether to enable (`true`) or disable (`false`).
	 * @param policy Optional restart/resume policy.
	 * @param time Optional override time.
	 * @return `true` if updated successfully.
	 */
	public inline function setEnabled(handle:Int, enabled:Bool, policy:Int = 0, time:Float = 0.0):Bool {
		// Inline, and on to the form with every argument given, so the jvm
		// boxes neither default; see ITimerScheduler.setEnabledBy.
		return this.setEnabledBy(handle, enabled, policy, time);
	}

	/**
	 * Pauses an active timer.
	 *
	 * @param handle The timer handle.
	 * @return `true` if paused.
	 */
	public inline function pause(handle:Int):Bool {
		return this.setEnabledBy(handle, false, ResumePolicy.KeepPhase, 0.0);
	}

	/**
	 * Resumes a paused timer.
	 *
	 * @param handle The timer handle.
	 * @param time Optional resume time (in seconds).
	 * @param policy Optional resume behavior policy.
	 * @return `true` if resumed.
	 */
	public inline function resume(handle:Int, time:Float = 0.0, policy:Int = 0):Bool {
		return this.setEnabledBy(handle, true, policy, time);
	}

	/**
	 * Returns the next due time (in seconds) for the earliest scheduled timer,
	 * or `null` if the queue is empty.
	 */
	public inline function nextDue():Null<Float> {
		return this.nextDue();
	}

	/**
	 * Advances the clock by `dt` and fires every timer due by then.
	 *
	 * @param dt Seconds to advance by.
	 * @param maxFires Most timers to fire in this call. Unbounded by default:
	 *        a count cap makes every timer late, without bound, once more
	 *        are due each call than it allows.
	 * @param budget Wall-clock seconds the call may spend firing, or zero or
	 *        less for no limit. What it leaves is fired by the next call, and
	 *        counted by `overdue()` until then.
	 * @return The number of timers fired.
	 */
	public inline function advanceTime(dt:Float, maxFires:Int = 0x7FFFFFFF, budget:Float = 0.0):Int {
		return this.advanceBy(dt, maxFires, budget);
	}

	/** `advanceTime` with every argument given, boxing none on the jvm. **/
	public inline function advanceBy(dt:Float, maxFires:Int, budget:Float):Int {
		return this.advanceBy(dt, maxFires, budget);
	}

	/**
	 * Whether the last `advanceTime` stopped with timers still due.
	 */
	public var cutShort(get, never):Bool;

	private inline function get_cutShort():Bool {
		return this.cutShort;
	}

	/**
	 * How many timers are due and still waiting because the last pass was
	 * cut short by its budget.
	 */
	public inline function overdue():Int {
		return this.overdue();
	}
}
