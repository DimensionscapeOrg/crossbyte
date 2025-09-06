package crossbyte;

import crossbyte.core.CrossByte;
import crossbyte._internal.system.timer.TimerScheduler;
#if sys
import sys.thread.Tls;
#end

/**
 * A static, thread-local utility class for scheduling time-based events.
 *
 * `Timer` provides access to a scheduler bound to the current thread.
 * All timer operations are handled by the scheduler attached to this thread.
 * 
 * This API only works in threads that are managed by a CrossByte runtime instance (such as via `CrossByte.runThread()`).
 * It will throw an error if accessed from a thread that has not been initialized with a `CrossByte` instance.
 * 
 * Threads created manually using `sys.thread.Thread.create()` or other non-CrossByte threading APIs
 * will fail at runtime when calling these timer methods unless a scheduler is explicitly bound.
 *
 * This design allows each CrossByte-managed thread to maintain its own isolated timing system.
 * For unified, thread-safe timer APIs, consider using `crossbyte.utils.GlobalTimer` instead.
 * 
 * @see crossbyte.utils.GlobalTimer
 */
@:allow(crossbyte.core.CrossByte)
class Timer {
	@:noCompletion private static final __tls:Tls<TimerScheduler> = new Tls();

	private static inline function bindCurrentThread(timer:TimerScheduler):Void {
		__tls.value = timer;
	}

	private static inline function current():TimerScheduler {
		final scheduler:TimerScheduler = __tls.value;
		#if debug
		if (scheduler == null) {
			throw "TimerScheduler not attached to this thread";
		}
		#end
		return scheduler;
	}

	/**
	 * Schedules a one-time callback to be invoked after a delay (in seconds).
	 *
	 * This version accepts a `Void->Void` function.
	 * 
	 * @param delay The delay in seconds before the callback is invoked.
	 * @param callback A function to be called when the timer elapses.
	 * @return A numeric handle that can be used to clear or manage the timer.
	 */
	overload extern public static inline function setTimeout(delay:Float, callback:Void->Void):Int {
		return current().setTimeout(delay, callback);
	}

	/**
	 * Schedules a one-time callback with its handle as a parameter, invoked after a delay (in seconds).
	 *
	 * This version passes the timer handle to the callback, allowing introspection or re-use.
	 * 
	 * @param delay The delay in seconds before the callback is invoked.
	 * @param callback A function receiving the timer's handle when invoked.
	 * @return A numeric handle that can be used to clear or manage the timer.
	 */
	overload extern public static inline function setTimeout(delay:Float, callback:Int->Void):Int {
		return current().setTimeout(delay, callback);
	}

	/**
	 * Schedules a repeating callback, first invoked after an initial delay, then repeatedly at a given interval (in seconds).
	 *
	 * This version accepts a `Void->Void` function.
	 * 
	 * @param delay The initial delay before the first invocation (in seconds).
	 * @param interval The repeating interval between successive calls (in seconds).
	 * @param callback A function to be called each time the interval elapses.
	 * @return A numeric handle that can be used to pause, resume, or clear the timer.
	 */
	overload extern public static inline function setInterval(delay:Float, interval:Float, callback:Void->Void):Int {
		return current().setInterval(delay, interval, callback);
	}

	/**
	 * Schedules a repeating callback with its handle as a parameter, invoked after an initial delay and then repeatedly.
	 *
	 * This version passes the timer handle to the callback.
	 *
	 * @param delay The initial delay before the first invocation (in seconds).
	 * @param interval The repeating interval between successive calls (in seconds).
	 * @param callback A function receiving the timer's handle each time it is invoked.
	 * @return A numeric handle that can be used to pause, resume, or clear the timer.
	 */
	overload extern public static inline function setInterval(delay:Float, interval:Float, callback:Int->Void):Int {
		return current().setInterval(delay, interval, callback);
	}

	/**
	 * Cancels a timer using its handle.
	 * 
	 * This stops any future invocations and removes the timer from the scheduler.
	 * 
	 * @param handle The timer handle returned by `setTimeout` or `setInterval`.
	 * @return `true` if the timer was successfully cleared, `false` if the handle was invalid or already cleared.
	 */
	public static inline function clear(handle:Int):Bool {
		return current().clear(handle);
	}

	/**
	 * Returns the current logical time (in seconds) for the timer scheduler on the current thread.
	 * 
	 * This value increments when `advanceTime()` is called by the host loop.
	 *
	 * @return The current scheduler time (not wall-clock time).
	 */
	public static inline function getTime():Float {
		return current().time;
	}

	/**
	 * Pauses a running timer, preventing it from firing.
	 * 
	 * A paused timer can be resumed later using `resume()`.
	 *
	 * @param handle The timer handle to pause.
	 * @return `true` if the timer was paused successfully, `false` otherwise.
	 */
	public static inline function pause(handle:Int):Bool {
		return current().setEnabled(handle, false);
	}

	/**
	 * Resumes a previously paused timer.
	 *
	 * The resume time may optionally be adjusted using the `time` parameter.
	 * A policy value may be provided to control rescheduling behavior (e.g., shift vs. retain offset).
	 * 
	 * @param handle The timer handle to resume.
	 * @param time The current time to resume from (typically from `getTime()`).
	 * @param policy The resume policy (scheduler-defined), default is `0`.
	 * @return `true` if the timer was resumed successfully, `false` otherwise.
	 */
	public static inline function resume(handle:Int, time:Float, policy:Int = 0):Bool {
		return current().setEnabled(handle, true, policy, time);
	}

	/**
	 * Returns the current logical time (in seconds) for application since it started.
	 * 
	 * This value increments when `advanceTime()` is called by the host loop.
	 *
	 * @return The application uptime (not wall-clock time).
	 */
	public static inline function stamp():Float {
		@:privateAccess
		return CrossByte.__primordial.uptime;
	}

	/**
	 * Returns the current wall-clock time in seconds.
	 * 
	 * @return The wall-clock time in seconds.
	 */
	public static inline function now():Float {
		return haxe.Timer.stamp();
	}

	/**
	 * Converts an absolute wall clock time (in milliseconds since epoch)
	 * to the scheduler's virtual time.
	 *
	 * @param wallTime The absolute wall clock time.
	 * @return The corresponding virtual time in the scheduler.
	 */
	public static inline function fromWallClock(wallTime:Float):Float {
		final scheduler:TimerScheduler = current();
		return scheduler.time + (wallTime - scheduler.startTime);
	}

	/**
	 * Converts a scheduler virtual time back into a wall clock timestamp.
	 *
	 * @param virtualTime The virtual time from the scheduler.
	 * @return The corresponding wall clock time in milliseconds since epoch.
	 */
	public static inline function toWallClock(virtualTime:Float):Float {
		final scheduler = current();
		return scheduler.startTime + (virtualTime - scheduler.time);
	}
}
