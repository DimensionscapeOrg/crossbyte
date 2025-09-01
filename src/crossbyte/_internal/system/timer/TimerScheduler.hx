package crossbyte._internal.system.timer;

import crossbyte._internal.system.timer.heap.TimerHeap;

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
 */
@:forward(startTime)
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
	 * Creates a new `TimerScheduler` using a heap-based timer strategy.
	 */
	public inline function new() {
		this = new TimerHeap();
	}

	/**
	 * Schedules a one-shot timer to fire after a delay (in milliseconds).
	 * The callback receives the actual fire time.
	 *
	 * @param delay Milliseconds from now to fire the timer.
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
	 * @param startTime Start time in ms.
	 * @param delay Milliseconds after start time to fire.
	 * @param callback A function to invoke when the timer fires.
	 * @return A handle used to manage the timer.
	 */
	overload extern public inline function setTimeout(delay:Float, callback:Void->Void):Int {
		return this.setTimeout(delay, callback);
	}

	/**
	 * Schedules a repeating timer starting at a given time and repeating
	 * at the specified interval. The callback receives the current time.
	 *
	 * @param startTime When the first fire should occur (in ms).
	 * @param delay How often to repeat (in ms).
	 * @param callback A function receiving the current time each fire.
	 * @return A handle used to manage the timer.
	 */
	overload extern public inline function setInterval(delay:Float, interval:Float, callback:Int->Void):Int {
		return this.setInterval(delay, interval, callback);
	}

	/**
	 * Schedules a repeating timer without parameters.
	 *
	 * @param startTime When to start (in ms).
	 * @param delay Interval duration (in ms).
	 * @param callback A function to invoke each interval.
	 * @return A handle used to manage the timer.
	 */
	overload extern public inline function setInterval(delay:Float, interval:Float, callback:Void->Void):Int {
		return this.setInterval(delay, interval, callback);
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
		return this.schedule(time, callback);
	}

	/**
	 * Reschedules a timer to fire at a new time.
	 *
	 * @param handle The timer handle to modify.
	 * @param time The new time (in ms) to fire.
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
	public function setEnabled(handle:Int, enabled:Bool, policy:Int = 0, time:Float = 0.0):Bool {
		return this.setEnabled(handle, enabled, policy, time);
	}

	/**
	 * Pauses an active timer.
	 *
	 * @param handle The timer handle.
	 * @return `true` if paused.
	 */
	public inline function pause(handle:Int):Bool {
		return this.setEnabled(handle, false);
	}

	/**
	 * Resumes a paused timer.
	 *
	 * @param handle The timer handle.
	 * @param time Optional resume time (in ms).
	 * @param policy Optional resume behavior policy.
	 * @return `true` if resumed.
	 */
	public inline function resume(handle:Int, time:Int = 0, policy:Int = 0):Bool {
		return this.setEnabled(handle, true, policy, time);
	}

	/**
	 * Returns the next due time (in ms) for the earliest scheduled timer,
	 * or `null` if the queue is empty.
	 */
	public inline function nextDue():Null<Float> {
		return this.nextDue();
	}

	/**
	 * Processes and fires any timers due at or before the given time.
	 *
	 * @param time The current time in ms.
	 * @param maxFires Optional limit on how many timers to fire (default 256).
	 * @return The number of timers fired.
	 */
	public inline function advanceTime(dt:Float, maxFires:Int = 256):Int {
		return this.advanceTime(dt, maxFires);
	}
}
