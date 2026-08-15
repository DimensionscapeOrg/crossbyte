package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
#if cpp
import crossbyte.sys._internal.NativeLifecycle;
#end

/**
 * Cooperative process-shutdown coordination.
 *
 * `installDefaultHandlers()` arms the platform shutdown source — the console
 * control handler on Windows (`Ctrl+C`, console close, logoff, system
 * shutdown; also the path a service-control STOP wrapper feeds) and
 * `SIGINT`/`SIGTERM` on POSIX targets. The OS-level handler only records the
 * request; nothing runs on the handler thread.
 *
 * Registered `onShutdown` callbacks are dispatched exactly once, in
 * registration order, on the thread that calls `poll()`. Installing while a
 * CrossByte runtime is current arms a tick listener that polls
 * automatically, so applications normally never call `poll()` themselves.
 * After the callbacks run, the polling runtime's `exit()` is invoked when
 * `exitOnShutdown` is `true` (the default).
 *
 * Typical server usage:
 *
 * ```haxe
 * ProcessLifecycle.onShutdown(() -> server.drainAndClose());
 * ProcessLifecycle.installDefaultHandlers();
 * ```
 *
 * @author Christopher Speciale
 */
final class ProcessLifecycle {
	/**
	 * When `true` (the default), the current CrossByte runtime's `exit()` is
	 * called after shutdown callbacks complete.
	 */
	public static var exitOnShutdown:Bool = true;

	/**
	 * Whether shutdown has been requested by any source (signal, console
	 * control, or `requestShutdown()`).
	 */
	public static var shutdownRequested(get, never):Bool;

	@:noCompletion private static var __requested:Bool = false;
	@:noCompletion private static var __dispatched:Bool = false;
	@:noCompletion private static var __callbacks:Array<() -> Void> = [];
	@:noCompletion private static var __watchedRuntime:CrossByte = null;
	@:noCompletion private static var __tickListener:TickEvent->Void = null;

	/**
	 * Arms the native shutdown-signal handlers and, when a CrossByte runtime
	 * is current on this thread, a tick listener that dispatches shutdown
	 * callbacks automatically.
	 *
	 * Idempotent. Returns `true` when native handlers are armed; targets
	 * without native handler support return `false` but remain fully usable
	 * through `requestShutdown()`/`poll()`.
	 */
	public static function installDefaultHandlers():Bool {
		__attachToCurrentRuntime();

		#if cpp
		return NativeLifecycle.install();
		#else
		return false;
		#end
	}

	/**
	 * Registers a shutdown callback. Callbacks run exactly once, in
	 * registration order; a callback registered after dispatch runs
	 * immediately. Exceptions thrown by a callback are swallowed so later
	 * callbacks and the exit path still run.
	 */
	public static function onShutdown(callback:() -> Void):Void {
		if (callback == null) {
			return;
		}

		if (__dispatched) {
			__invoke(callback);
			return;
		}

		__callbacks.push(callback);
	}

	/**
	 * Requests shutdown programmatically. Shares the code path of the native
	 * handlers: the request latches, and callbacks run on the next `poll()`
	 * (or the next tick of an attached runtime).
	 */
	public static function requestShutdown():Void {
		__requested = true;
		#if cpp
		NativeLifecycle.requestShutdown();
		#end
	}

	/**
	 * Dispatches shutdown callbacks when a request is pending. Called
	 * automatically each tick once `installDefaultHandlers()` has attached a
	 * runtime; call manually from custom loops.
	 *
	 * @return `true` when this call performed the dispatch.
	 */
	public static function poll():Bool {
		if (__dispatched || !shutdownRequested) {
			return false;
		}

		__dispatched = true;

		for (callback in __callbacks) {
			__invoke(callback);
		}
		__callbacks = [];
		__detach();

		if (exitOnShutdown) {
			var runtime:CrossByte = __currentRuntimeOrNull();
			if (runtime != null) {
				runtime.exit();
			}
		}

		return true;
	}

	@:noCompletion private static function get_shutdownRequested():Bool {
		#if cpp
		return __requested || NativeLifecycle.isShutdownRequested();
		#else
		return __requested;
		#end
	}

	@:noCompletion private static function __currentRuntimeOrNull():CrossByte {
		// CrossByte.current() throws on threads without an attached runtime.
		try {
			return CrossByte.current();
		} catch (_:Dynamic) {
			return null;
		}
	}

	@:noCompletion private static function __attachToCurrentRuntime():Void {
		if (__watchedRuntime != null) {
			return;
		}

		var runtime:CrossByte = __currentRuntimeOrNull();
		if (runtime == null) {
			return;
		}

		__tickListener = function(_:TickEvent):Void {
			poll();
		};
		runtime.addEventListener(TickEvent.TICK, __tickListener);
		__watchedRuntime = runtime;
	}

	@:noCompletion private static function __detach():Void {
		if (__watchedRuntime == null) {
			return;
		}

		__watchedRuntime.removeEventListener(TickEvent.TICK, __tickListener);
		__watchedRuntime = null;
		__tickListener = null;
	}

	@:noCompletion private static inline function __invoke(callback:() -> Void):Void {
		try {
			callback();
		} catch (_:Dynamic) {
			// A failing shutdown callback must not block the remaining
			// callbacks or the exit path.
		}
	}

	/**
	 * Test hook: returns lifecycle state to its initial configuration.
	 */
	@:noCompletion public static function __resetForTesting():Void {
		__requested = false;
		__dispatched = false;
		__callbacks = [];
		__detach();
		exitOnShutdown = true;
		#if cpp
		NativeLifecycle.reset();
		#end
	}
}
