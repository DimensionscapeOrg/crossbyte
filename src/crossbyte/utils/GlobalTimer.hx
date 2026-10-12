package crossbyte.utils;

import crossbyte.Function;
import haxe.ds.Map;
import haxe.Timer as HxTimer;
#if target.threaded
import sys.thread.Mutex;
#end

/**
	Timers by id, callable from any thread, on `haxe.Timer`.

	`setTimeout(delay, closure)` calls `closure` once, `delay` seconds from
	now, and `setInterval(interval, closure)` every `interval` seconds; each
	returns the id `clearTimeout` or `clearInterval` takes. Given an `args`
	array after the function, either calls a function of any arity with
	those arguments.

	`crossbyte.Timer` is the runtime's own, in seconds too, and handed a
	handle rather than an id; it runs on a runtime's thread only.

	A timer runs where a `haxe.Timer` made on the calling thread would: on
	that thread's runtime (the primordial runtime on the primordial thread, a
	child runtime on its own thread), or on the primordial runtime when the
	thread has none. One whose runtime exits never runs, and its id is let
	go then.

	Safe to call from any thread. The ids and the map behind them are kept
	under a lock wherever there are threads, so threads setting and
	clearing timers at once are never issued one id twice, and a
	`clearTimeout` never stops another thread's timer.

	From ActionScript: there the function comes first and the delay is in
	milliseconds, so `setTimeout(f, 500)` is `setTimeout(0.5, f)` here.
**/
final class GlobalTimer {
	@:noCompletion private static var __lastTimerID:UInt = 0;
	// Whether the id counter has gone round once. Until it has, every id it
	// gives is new, and asking the map whether one is in use is skipped: an
	// IntMap on the jvm answers that question for a missing id by visiting
	// every bucket.
	@:noCompletion private static var __wrapped:Bool = false;
	@:noCompletion private static var __timers:Map<UInt, HxTimer> = new Map();
	#if target.threaded
	@:noCompletion private static final __mutex:Mutex = new Mutex();
	#end

	/**
		Stops the interval `setInterval` returned `id` for. An id already
		cleared, or never given, is ignored.
	**/
	public static function clearInterval(id:UInt):Void {
		var timer = __removeTimer(id);
		if (timer != null) {
			timer.stop();
		}
	}

	/**
		Stops the timeout `setTimeout` returned `id` for, if it has not run.
		An id already cleared, already run, or never given is ignored.
	**/
	public static function clearTimeout(id:UInt):Void {
		var timer = __removeTimer(id);
		if (timer != null) {
			timer.stop();
		}
	}

	/**
		Calls `closure` every `interval` seconds until `clearInterval` is
		called with the id this returns. Until then the interval holds
		`closure`, and what it reaches.

		@param interval The interval, in seconds.
		@param closure The function to call.
		@return The id to pass to `clearInterval`.
	**/
	overload extern public static inline function setInterval(interval:Float, closure:Void->Void):UInt {
		return __setIntervalVoid(interval, closure);
	}

	/**
		`setInterval` for any function, called with `args`: through a
		dynamic call, and through reflection past four arguments. A
		`Void->Void` function is taken by the overload above, which calls it
		directly.
	**/
	overload extern public static inline function setInterval(interval:Float, closure:Function, args:Array<Dynamic> = null):UInt {
		return __setInterval(interval, closure, args);
	}

	@:noCompletion private static function __setIntervalVoid(interval:Float, closure:Void->Void):UInt {
		var id = __nextID();
		__setTimer(id, __running(interval, closure));
		return id;
	}

	@:noCompletion private static function __setInterval(interval:Float, closure:Function, args:Array<Dynamic>):UInt {
		var id = __nextID();
		__setTimer(id, __running(interval, __onInterval.bind(id, closure, args)));
		return id;
	}

	/**
		A `haxe.Timer` running `run` every `interval` seconds, given before the
		timer is handed to its runtime: given after, a runtime on another
		thread could run the timer before it had one. See
		`haxe.Timer.__given`.
	**/
	@:noCompletion private static inline function __running(interval:Float, run:Void->Void):HxTimer {
		#if lime_cffi
		var timer = new HxTimer(crossbyte._internal.Millis.of(interval));
		timer.run = run;
		return timer;
		#else
		return @:privateAccess HxTimer.__givenSeconds(interval, _ -> run());
		#end
	}

	/** A `haxe.Timer` that stops itself and runs `run` once, `delay` seconds from now. **/
	@:noCompletion private static inline function __once(delay:Float, run:Void->Void):HxTimer {
		#if lime_cffi
		return HxTimer.delay(run, crossbyte._internal.Millis.of(delay));
		#else
		return @:privateAccess HxTimer.__givenSeconds(delay, timer -> {
			timer.stop();
			run();
		});
		#end
	}

	/**
		Calls `closure` once, `delay` seconds from now, unless `clearTimeout`
		is called first with the id this returns.

		@param delay The delay, in seconds.
		@param closure The function to call.
		@return The id to pass to `clearTimeout`.
	**/
	overload extern public static inline function setTimeout(delay:Float, closure:Void->Void):UInt {
		return __setTimeoutVoid(delay, closure);
	}

	/**
		`setTimeout` for any function, called with `args`: through a dynamic
		call, and through reflection past four arguments. A `Void->Void`
		function is taken by the overload above.
	**/
	overload extern public static inline function setTimeout(delay:Float, closure:Function, args:Array<Dynamic> = null):UInt {
		return __setTimeout(delay, closure, args);
	}

	@:noCompletion private static function __setTimeoutVoid(delay:Float, closure:Void->Void):UInt {
		var id = __nextID();
		__setTimer(id, __once(delay, () -> {
			__removeTimer(id);
			closure();
		}));
		return id;
	}

	@:noCompletion private static function __setTimeout(delay:Float, closure:Function, args:Array<Dynamic>):UInt {
		var id = __nextID();
		__setTimer(id, __once(delay, __onTimeout.bind(id, closure, args)));
		return id;
	}

	@:noCompletion private static inline function __onTimeout(id:UInt, closure:Function, args:Array<Dynamic>):Void {
		__removeTimer(id);
		__invoke(closure, args);
	}

	@:noCompletion private static inline function __onInterval(id:UInt, closure:Function, args:Array<Dynamic>):Void {
		__invoke(closure, args);
	}

	@:noCompletion private static inline function __invoke(closure:Function, args:Array<Dynamic>):Void {
		if (args == null || args.length == 0) {
			closure();
		} else if (args.length > 4) {
			Reflect.callMethod(closure, closure, args);
		} else if (args.length == 1) {
			closure(args[0]);
		} else if (args.length == 2) {
			closure(args[0], args[1]);
		} else if (args.length == 3) {
			closure(args[0], args[1], args[2]);
		} else if (args.length == 4) {
			closure(args[0], args[1], args[2], args[3]);
		}
	}

	/**
		A new id, held in the map (with no timer yet) until `__setTimer` puts
		its timer there, so no other thread can be given it meanwhile.
	**/
	@:noCompletion private static function __nextID():UInt {
		var id:UInt = 0;
		__lock();
		// The counter wraps after 2^32 timers. Taking an id still in use
		// would replace that timer in the map, where clearInterval could no
		// longer reach it, so ids in use (and 0) are skipped.
		do {
			id = ++__lastTimerID;
			if (id == 0) {
				__wrapped = true;
			}
		} while (id == 0 || (__wrapped && __timers.exists(id)));
		__timers.set(id, null);
		__unlock();
		return id;
	}

	@:noCompletion private static function __setTimer(id:UInt, timer:HxTimer):Void {
		__lock();
		// Cleared already, by an id the caller had not been given yet: only
		// after the counter wraps. The timer goes rather than running on.
		var cleared:Bool = !__timers.exists(id);
		if (!cleared) {
			__timers.set(id, timer);
		}
		__unlock();
		if (cleared) {
			timer.stop();
		}
	}

	/**
		Lets go of the timers on a runtime that has exited, which never run:
		their ids would hold them, and whatever their functions held, for as
		long as the process ran. Called by the runtime as it exits.
	**/
	@:allow(crossbyte.core.CrossByte)
	@:noCompletion private static function __runtimeExited(runtime:crossbyte.core.CrossByte):Void {
		#if !lime_cffi
		__lock();
		var gone:Array<UInt> = null;
		for (id => timer in __timers) {
			if (timer != null && @:privateAccess timer.__home == runtime) {
				if (gone == null) {
					gone = [];
				}
				gone.push(id);
			}
		}
		if (gone != null) {
			for (id in gone) {
				__timers.remove(id);
			}
		}
		__unlock();
		#end
	}

	@:noCompletion private static function __removeTimer(id:UInt):HxTimer {
		__lock();
		var timer:HxTimer = __timers.get(id);
		__timers.remove(id);
		__unlock();
		return timer;
	}

	// Map operations only, which do not throw, between each pair: no closure
	// and no try to allocate on the way.
	@:noCompletion private static inline function __lock():Void {
		#if target.threaded
		__mutex.acquire();
		#end
	}

	@:noCompletion private static inline function __unlock():Void {
		#if target.threaded
		__mutex.release();
		#end
	}
}
