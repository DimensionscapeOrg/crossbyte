package crossbyte.utils;

import haxe.ds.Map;
import haxe.Timer as HxTimer;

/**
 * ...
 * @author Christopher Speciale
 */
class Timer {
	@:noCompletion private static var __lastTimerID:UInt = 0;
	@:noCompletion private static var __timers:Map<UInt, HxTimer> = new Map();

	/**
			Cancels a specified `setInterval()` call.
		@param	id	The ID of the `setInterval()` call, which you set to a variable, as
			in the following:
	**/
	public static function clearInterval(id:UInt):Void {
		if (__timers.exists(id)) {
			var timer = __timers[id];
			timer.stop();
			__timers.remove(id);
		}
	}

	/**
		Cancels a specified `setTimeout()` call.
		@param	id	The ID of the `setTimeout()` call, which you set to a variable, as in
		the following
	**/
	public static function clearTimeout(id:UInt):Void {
		if (__timers.exists(id)) {
			var timer:HxTimer = __timers[id];
			timer.stop();
			__timers.remove(id);
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
		var id = ++__lastTimerID;
		var timer = new HxTimer(delay);
		__timers[id] = timer;
		timer.start();
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
		var id = ++__lastTimerID;
		__timers[id] = HxTimer.delay(__onTimeout.bind(id, closure, args), delay);

		return id;
	}

	@:noCompletion private static inline function __onTimeout(id:UInt, closure:Function, args:Array<Dynamic>):Void {
		__timers.remove(id);

		if (args == null) {
			closure();
		} else if (args.length > 4) {
			Reflect.callMethod(closure, closure, args == null ? [] : args);
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

	@:noCompletion private static inline function __onInterval(id:UInt, closure:Function, args:Array<Dynamic>):Void {
		if (args == null) {
			closure();
		} else if (args.length > 4) {
			Reflect.callMethod(closure, closure, args == null ? [] : args);
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
}
