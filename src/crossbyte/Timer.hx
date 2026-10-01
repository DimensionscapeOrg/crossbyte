package crossbyte;

import crossbyte.core.CrossByte;
import crossbyte.errors.IllegalOperationError;
import crossbyte._internal.system.timer.TimerScheduler;
#if target.threaded
import sys.thread.Tls;
#end

/**
 * A static, thread-local utility class for scheduling time-based events.
 *
 * `Timer` provides access to a scheduler bound to the current thread.
 * All timer operations are handled by the scheduler attached to this thread.
 *
 * This API only works on a thread a CrossByte runtime runs on: the
 * application's, a child runtime's made with `CrossByte.make()`, or the thread
 * that pumps a host-driven runtime. Anywhere else it throws an
 * `IllegalOperationError`, as `CrossByte.current()` does.
 *
 * Threads created manually using `sys.thread.Thread.create()` or other non-CrossByte threading APIs
 * have no runtime, so these timer methods throw there; hand the work to a runtime with
 * `CrossByte.post()` instead.
 *
 * This design allows each CrossByte-managed thread to maintain its own isolated timing system.
 * For process-wide timeout/interval APIs backed by the primordial runtime,
 * consider using `crossbyte.utils.GlobalTimer` instead.
 * 
 * @see crossbyte.utils.GlobalTimer
 */
@:allow(crossbyte.core.CrossByte)
@:allow(crossbyte.rpc.RPCHandler)
class Timer {
	// Per thread on every threaded target. It was one process-wide field off
	// native, so on the jvm and the interpreter whichever runtime ran last
	// owned every thread's timers: after CrossByte.make(), a timer the main
	// thread armed ran on the child's thread.
	#if target.threaded
	@:noCompletion private static final __tls:Tls<TimerScheduler> = new Tls();
	#else
	@:noCompletion private static var __nonThreadedTimer:TimerScheduler;
	#end

	@:noCompletion private static inline function bindCurrentThread(timer:TimerScheduler):Void {
		#if target.threaded
		__tls.value = timer;
		#else
		__nonThreadedTimer = timer;
		#end
	}

	@:noCompletion private static inline function current():TimerScheduler {
		#if target.threaded
		final scheduler:TimerScheduler = __tls.value;
		#else
		final scheduler:TimerScheduler = __nonThreadedTimer;
		#end
		if (scheduler == null) {
			__noScheduler();
		}
		return scheduler;
	}

	// Out of line, so the inline path above stays a load and a test. An
	// IllegalOperationError, as CrossByte.current() throws on the same
	// thread; this was a bare String.
	@:noCompletion private static function __noScheduler():Void {
		throw new IllegalOperationError("crossbyte.Timer needs a CrossByte runtime on this thread, and this thread has none. Use it from a runtime's thread, or hand the work to one with CrossByte.post().");
	}

	@:noCompletion private static inline function currentOrNull():Null<TimerScheduler> {
		#if target.threaded
		return __tls.value;
		#else
		return __nonThreadedTimer;
		#end
	}

	@:noCompletion private static inline function tryGetTime():Float {
		final scheduler = currentOrNull();
		return scheduler != null ? scheduler.time : -1.0;
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
	 * @throws IllegalOperationError If there is no application: no primordial
	 *         runtime has been made, or it has exited.
	 */
	public static inline function stamp():Float {
		final primordial:CrossByte = @:privateAccess CrossByte.__primordial;
		if (primordial == null) {
			// It read the primordial's uptime without looking, which is a
			// null access, natively, in a release build, a crash.
			__noApplication();
		}
		return primordial.uptime;
	}

	@:noCompletion private static function __noApplication():Void {
		throw new IllegalOperationError("crossbyte.Timer.stamp() is the application's uptime, and there is no application: create an Application, HostApplication or ServerApplication first.");
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
	 * Converts an absolute wall clock time (in seconds), as `now()` reads it,
	 * to the scheduler's virtual time.
	 *
	 * Measured from the present: the scheduler's time now, `getTime()`, plus
	 * however far `wallTime` is from `now()`. So a timer due at the result
	 * fires when the clock reads about `wallTime`, as long as the runtime
	 * keeps pace with the clock, as its own loop does. A host-driven runtime
	 * moves at the pace its host advances it.
	 *
	 * @param wallTime The absolute wall clock time.
	 * @return The corresponding virtual time in the scheduler.
	 */
	public static inline function fromWallClock(wallTime:Float):Float {
		// The scheduler's time was counted on top of its start, so after an
		// hour of running every answer was an hour late.
		return current().time + (wallTime - haxe.Timer.stamp());
	}

	/**
	 * Converts a scheduler virtual time back into a wall clock timestamp, on
	 * `now()`'s clock: when the clock reads, or will read, the moment the
	 * scheduler reaches `virtualTime`.
	 *
	 * Measured from the present, as `fromWallClock` is, and its inverse.
	 *
	 * @param virtualTime The virtual time from the scheduler.
	 * @return The corresponding wall clock time in seconds.
	 */
	public static inline function toWallClock(virtualTime:Float):Float {
		return haxe.Timer.stamp() + (virtualTime - current().time);
	}
}
