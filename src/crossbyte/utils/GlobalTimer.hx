package crossbyte.utils;

import haxe.ds.Map;
import haxe.Timer as HxTimer;
#if cpp
import sys.thread.Mutex;
#end

/**
 * ...
 * @author Christopher Speciale
 */
final class GlobalTimer {
	@:noCompletion private static var __lastTimerID:UInt = 0;
	@:noCompletion private static var __timers:Map<UInt, HxTimer> = new Map();
	#if cpp
	@:noCompletion private static final __mutex:Mutex = new Mutex();
	#end

	/**
	 *	Cancels a specified `setInterval()` call.
	 *	@param	id	The ID of the `setInterval()` call, which you set to a variable, as
	 *	in the following:
	**/
	public static function clearInterval(id:UInt):Void {
		var timer = __removeTimer(id);
		if (timer != null) {
			timer.stop();
		}
	}

	/**
	 *	Cancels a specified `setTimeout()` call.
	 *	@param	id	The ID of the `setTimeout()` call, which you set to a variable, as in
	 *	the following
	**/
	public static function clearTimeout(id:UInt):Void {
		var timer = __removeTimer(id);
		if (timer != null) {
			timer.stop();
		}
	}

	/**
		Runs a function at a specified interval (in milliseconds).
		Instead of using the `setInterval()` method, consider creating a Timer object, with
		the specified interval, using 0 as the `repeatCount` parameter (which sets the timer
		to repeat indefinitely).
		If you intend to use the `clearInterval()` method to cancel the `setInterval()`
		call, be sure to assign the `setInterval()` call to a variable (which the
		`clearInterval()` function will later reference). If you do not call the
		`clearInterval()` function to cancel the `setInterval()` call, the object
		containing the set timeout closure function will not be garbage collected.
		@param	closure	The name of the function to execute. Do not include quotation
		marks or parentheses, and do not specify parameters of the function to call. For
		example, use `functionName`, not `functionName()` or `functionName(param)`.
		@param	delay	The interval, in milliseconds.
		@param	args	An optional list of arguments that are passed to the closure
		function.
		@returns	Unique numeric identifier for the timed process. Use this identifier
		to cancel the process, by calling the `clearInterval()` method.
	**/
	public static function setInterval(closure:Function, delay:Int, args:Array<Dynamic> = null):UInt {
		var id = __nextID();
		var timer = new HxTimer(delay);
		__setTimer(id, timer);
		timer.run = __onInterval.bind(id, closure, args);
		return id;
	}

	/**
		Runs a specified function after a specified delay (in milliseconds).
		Instead of using this method, consider creating a Timer object, with the specified
		interval, using 1 as the `repeatCount` parameter (which sets the timer to run only
		once).
		If you intend to use the `clearTimeout()` method to cancel the `setTimeout()` call,
		be sure to assign the `setTimeout()` call to a variable (which the
		`clearTimeout()` function will later reference). If you do not call the
		`clearTimeout()` function to cancel the `setTimeout()` call, the object containing
		the set timeout closure function will not be garbage collected.
		@param	closure	The name of the function to execute. Do not include quotation marks
		or parentheses, and do not specify parameters of the function to call. For
		example, use `functionName`, not `functionName()` or `functionName(param)`.
		@param	delay	The delay, in milliseconds, until the function is executed.
		@param	args	An optional list of arguments that are passed to the closure
		function.
		@returns	Unique numeric identifier for the timed process. Use this identifier to
		cancel the process, by calling the `clearTimeout()` method.
	**/
	public static inline function setTimeout(closure:Function, delay:Int, args:Array<Dynamic> = null):UInt {
		var id = __nextID();
		__setTimer(id, HxTimer.delay(__onTimeout.bind(id, closure, args), delay));
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

	@:noCompletion private static inline function __nextID():UInt {
		var id:UInt = 0;
		__withLock(() -> id = ++__lastTimerID);
		return id;
	}

	@:noCompletion private static inline function __setTimer(id:UInt, timer:HxTimer):Void {
		__withLock(() -> __timers[id] = timer);
	}

	@:noCompletion private static inline function __removeTimer(id:UInt):HxTimer {
		var timer:HxTimer = null;
		__withLock(() -> {
			timer = __timers[id];
			if (timer != null) {
				__timers.remove(id);
			}
		});
		return timer;
	}

	@:noCompletion private static inline function __withLock(fn:Void->Void):Void {
		#if cpp
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
