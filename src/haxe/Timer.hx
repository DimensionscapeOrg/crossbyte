package haxe;

#if lime_cffi
import lime.system.System;
import haxe.Log;
import haxe.PosInfos;

/**
	A Lime-compatible `haxe.Timer` shape for projects where CrossByte shares a
	classpath with Lime's native backend.

	Lime's native application loop reaches into these private fields through
	`@:access(haxe.Timer)`, so CrossByte's global timer shadow needs to expose
	the same storage contract when `lime_cffi` is active.
**/
class Timer {
	private static var sRunningTimers:Array<Timer> = [];

	private var mTime:Float;
	private var mFireAt:Float;
	private var mRunning:Bool;

	public function new(time_ms:Int) {
		mTime = time_ms;
		mFireAt = System.getTimer() + mTime;
		mRunning = true;
		sRunningTimers.push(this);
	}

	public function stop():Void {
		mRunning = false;
	}

	public dynamic function run():Void {}

	public static function delay(f:Void->Void, time_ms:Int):Timer {
		var timer = new Timer(time_ms);
		timer.run = function() {
			timer.stop();
			f();
		};
		return timer;
	}

	public static function measure<T>(f:Void->T, ?pos:PosInfos):T {
		var t0 = stamp();
		var result = f();
		Log.trace((stamp() - t0) + "s", pos);
		return result;
	}

	public static inline function stamp():Float {
		var timer = System.getTimer();
		return timer > 0 ? timer / 1000 : 0;
	}
}
#else
import crossbyte.core.CrossByte;
import crossbyte.utils.ThreadUtil;
import haxe.Log;
import haxe.PosInfos;
#if target.threaded
import sys.thread.Mutex;
#end

/**
	A `haxe.Timer` implementation backed by CrossByte's runtime.

	A timer is a timer on the runtime's own scheduler, the one
	`crossbyte.Timer` uses. Each run is due one interval after the last one
	was due, so the rate is the one asked for, rather than each period
	rounding up to a whole number of ticks (at the default twelve ticks a
	second a 100ms timer would run every 167ms); a timer that has fallen
	behind (a stall, an interval shorter than a frame) runs once a frame
	until it catches up rather than in a burst.

	It runs on the runtime of the thread that made it: the primordial one on
	the primordial thread, a child runtime on that child's thread. A timer
	made on a thread no runtime belongs to runs on the primordial runtime,
	handed over through its post queue, and so does stopping one from a thread
	other than its runtime's.

	A timer made before any runtime exists waits for one: it joins the
	primordial runtime when that is set up, and counts from then. That is the
	standard library's contract (a timer fires once the event loop runs),
	and libraries rely on it from their static initializers, which run before
	`main`. hxcpp's VS Code debugger is one: its server, compiled into every
	debug build that includes `hxcpp-debug-server`, polls for a late attach
	with a timer it makes during static initialization when no debugger is
	listening.
**/
#if cpp
@:cppFileCode("
#ifndef HX_WINDOWS
#include <time.h>
#endif

// Seconds on a monotonic clock. Windows keeps hxcpp's own stamp, which is
// QueryPerformanceCounter and already monotonic; everywhere else hxcpp's is
// gettimeofday less its first reading, which moves whenever the time of day
// is set, so CLOCK_MONOTONIC is asked for directly.
static double crossbyte_monotonic_seconds() {
#ifdef HX_WINDOWS
	return __time_stamp();
#else
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (double)now.tv_sec + (double)now.tv_nsec * 1e-9;
#endif
}
")
#end
@:access(crossbyte.core.CrossByte)
class Timer {
	// Made before any runtime existed, waiting for the primordial one.
	private static var __waiting:Array<Timer> = [];
	#if target.threaded
	// Guards __waiting and each timer's __home, which another thread can
	// read while the primordial runtime is being set up.
	private static final __mutex:Mutex = new Mutex();
	#end

	private var __interval:Float;

	// The runtime this timer runs on, once it has one.
	private var __home:CrossByte = null;

	// Only touched on __home's thread: the scheduler's handle, when the next
	// run is due there, and whether it is armed.
	private var __handle:Int = 0;
	private var __due:Float = 0.0;
	private var __armed:Bool = false;
	private var __stopped:Bool = false;

	public function new(time_ms:Int) {
		__interval = time_ms > 0 ? time_ms / 1000 : 0.0;

		var home:CrossByte = __homeForThisThread();
		if (home == null) {
			// None yet, before any runtime: `__primordialReady` arms it when
			// the first one is set up.
			__withLock(() -> {
				home = CrossByte.__primordial;
				if (home == null) {
					__waiting.push(this);
				} else {
					__home = home;
				}
			});
			if (home == null) {
				return;
			}
		} else {
			__withLock(() -> __home = home);
		}

		if (home.__isOwnThread()) {
			__arm();
		} else {
			home.post(__arm);
		}
	}

	// The primordial runtime on the primordial thread, even while a runtime
	// pumped on that thread is current there; a child runtime on its own
	// loop's thread; the primordial runtime from a thread with none.
	private static function __homeForThisThread():Null<CrossByte> {
		var primordial:CrossByte = @:privateAccess CrossByte.__primordial;
		if (primordial != null && ThreadUtil.isPrimordial) {
			return primordial;
		}
		var own:CrossByte = CrossByte.__currentOrNull();
		return own != null ? own : primordial;
	}

	// On __home's thread.
	private function __arm():Void {
		if (__stopped || __armed) {
			return;
		}
		var scheduler = @:privateAccess __home.__timer;
		__due = scheduler.time + __interval;
		__handle = scheduler.setTimeout(__interval, __fire);
		__armed = true;
	}

	// On __home's thread, as the scheduler runs it.
	private function __fire(handle:Int):Void {
		if (__stopped) {
			return;
		}

		// Re-armed before running, from the time this run was due rather than
		// from now, so no fraction of a tick is lost and the rate is the one
		// asked for; and before running so a run that throws leaves the timer
		// armed, as the runtime keeps any timer armed through a failure. Due
		// by now already, it waits for the next pass rather than firing again
		// in this one.
		__due += __interval;
		@:privateAccess __home.__timer.reschedule(handle, __due);
		run();
	}

	// On __home's thread.
	private function __disarm():Void {
		if (__armed) {
			__armed = false;
			@:privateAccess __home.__timer.clear(__handle);
		}
	}

	/**
		Called as a primordial runtime is set up, on its thread, so the timers
		made before it (while the program's statics were initialized, before
		`main`) start counting on its scheduler.
	**/
	@:noCompletion private static function __primordialReady(runtime:CrossByte):Void {
		var waiting:Array<Timer> = null;
		__withLock(() -> {
			waiting = __waiting;
			__waiting = [];
			for (timer in waiting) {
				timer.__home = runtime;
			}
		});

		for (timer in waiting) {
			timer.__arm();
		}
	}

	public function stop():Void {
		if (__stopped) {
			return;
		}
		__stopped = true;

		var home:CrossByte = null;
		__withLock(() -> {
			home = __home;
			if (home == null) {
				__waiting.remove(this);
			}
		});
		if (home == null) {
			return;
		}

		if (home.__isOwnThread()) {
			__disarm();
		} else {
			// After the arming, if that was posted too: the queue keeps order.
			home.post(__disarm);
		}
	}

	/**
		Does nothing. A timer runs from construction until `stop()`, as the
		standard library's does, and cannot be restarted once stopped; this
		is kept for code that calls it.
	**/
	public function start():Void {}

	public dynamic function run():Void {}

	public static function delay(f:Void->Void, time_ms:Int):Timer {
		var timer = new Timer(time_ms);
		timer.run = function() {
			timer.stop();
			f();
		};
		return timer;
	}

	public static function measure<T>(f:Void->T, ?pos:PosInfos):T {
		var t0 = stamp();
		var result = f();
		Log.trace((stamp() - t0) + "s", pos);
		return result;
	}

	/**
		Seconds on a monotonic clock, from an arbitrary origin: for how long
		something took and for when something is due, never for the time of
		day, which is `Sys.time()` or `Date.now()`.

		Monotonic wherever the platform offers one: QueryPerformanceCounter
		on Windows native, CLOCK_MONOTONIC on Linux, macOS and other native
		POSIX, `System.nanoTime` on the jvm, `performance.now()` on both
		JavaScript targets. A clock that is the time of day moves when the time
		of day is set: stepped backwards, every deadline measured against it
		waits out the step; stepped forwards, they all fall due at once. hl,
		neko and eval have no monotonic source here and use `Sys.time()`.

		Everything in CrossByte that waits or measures reads this and nothing
		else, which is what keeps any two times it compares on one clock. An
		application comparing its own times against CrossByte's should do the
		same.

		Not inline on cpp, where the clock is a function in this class's own
		compiled file rather than code copied into every caller's.
	**/
	public static #if !cpp inline #end function stamp():Float {
		#if js
		return __jsStamp() / 1000;
		#elseif cpp
		return untyped __cpp__("crossbyte_monotonic_seconds()");
		#elseif ((java || jvm) && !macro)
		// nanoTime is a long, and Haxe 4 has no Int64 to Float: the halves
		// are joined as doubles, exact to the nanosecond for about 104 days
		// of uptime and to the microsecond for long after that.
		var nanos = java.lang.System.nanoTime();
		var low:Float = haxe.Int64.getLow(nanos);
		if (low < 0) {
			low += 4294967296.0;
		}
		return (haxe.Int64.getHigh(nanos) * 4294967296.0 + low) / 1000000000.0;
		#elseif python
		return Sys.cpuTime();
		#elseif sys
		return Sys.time();
		#else
		return 0;
		#end
	}

	#if js
	/**
	 * `performance.now()`, which every browser and every Node since 16 has as
	 * a global, on both JavaScript targets rather than `Date.now()`: it is
	 * monotonic, so a clock adjustment cannot make an elapsed interval come
	 * out negative, and it is sub-millisecond, which matters when what is
	 * being measured is the cost of one frame. That also puts the two
	 * JavaScript targets on the same clock.
	 */
	private static inline function __jsStamp():Float {
		return js.Syntax.code("(typeof performance !== 'undefined' ? performance.now() : Date.now())");
	}
	#end

	private static inline function __withLock(fn:Void->Void):Void {
		#if target.threaded
		__mutex.acquire();
		try {
			fn();
		} catch (e:Dynamic) {
			__mutex.release();
			throw e;
		}
		__mutex.release();
		#else
		fn();
		#end
	}
}
#end
