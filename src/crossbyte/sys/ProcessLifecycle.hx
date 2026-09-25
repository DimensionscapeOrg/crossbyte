package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import crossbyte.utils.Logger;
#if cpp
import crossbyte.sys._internal.NativeLifecycle;
import crossbyte.sys._internal.NativeServiceControl;
#end

/**
 * Cooperative process-shutdown coordination.
 *
 * `installDefaultHandlers()` arms the platform shutdown source — the console
 * control handler on Windows (`Ctrl+C`, console close, logoff, system
 * shutdown) and `SIGINT`/`SIGTERM` on POSIX targets. The OS-level handler only
 * records the request; nothing runs on the handler thread.
 *
 * A process started by the Windows Service Control Manager has no console and
 * receives none of those events, so a service needs
 * `installServiceControl()` instead: it adds the SCM as a second signal source
 * feeding the same latch, and reports service status back so that a stop waits
 * for the shutdown callbacks rather than killing the process on a timeout.
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
	 *
	 * Set it to `false` when a shutdown callback finishes asynchronously.
	 * `HTTPServer.drain(timeout, onComplete)` returns immediately and polls the
	 * connection count on each tick, so exiting the runtime as soon as the
	 * callback returns leaves the drain without another tick to finish on: it
	 * never completes and `onComplete` never runs. The application then owns
	 * calling `exit()` from its completion handler.
	 */
	public static var exitOnShutdown:Bool = true;

	/**
	 * Whether shutdown has been requested by any source (signal, console
	 * control, service control, or `requestShutdown()`).
	 */
	public static var shutdownRequested(get, never):Bool;

	/**
	 * Whether this process is attached to the Windows Service Control Manager.
	 * `false` for an ordinary console run and on every non-Windows target.
	 */
	public static var isService(get, never):Bool;

	/**
	 * When `true`, `poll()` stops reporting `SERVICE_STOPPED` for you and the
	 * application takes that on with `reportServiceStopped()`.
	 *
	 * Set this from a shutdown callback that finishes asynchronously —
	 * `HTTPServer.drain(timeout, onComplete)` being the case that matters —
	 * because `poll()` returns as soon as the callbacks have been *started*,
	 * and reporting the service stopped there would tell the SCM the drain was
	 * finished while connections were still being served.
	 */
	public static var deferServiceStop:Bool = false;

	@:noCompletion private static var __requested:Bool = false;
	@:noCompletion private static var __dispatched:Bool = false;
	@:noCompletion private static var __callbacks:Array<() -> Void> = [];
	@:noCompletion private static var __watchedRuntime:CrossByte = null;
	@:noCompletion private static var __tickListener:TickEvent->Void = null;

	// onShutdown() may be called from a worker thread while poll() runs on
	// the runtime thread; without this, a registration racing the dispatch
	// sweep can be silently dropped or double-run.
	#if (cpp || neko || hl || java || jvm)
	@:noCompletion private static final __lock:sys.thread.Mutex = new sys.thread.Mutex();
	#end

	@:noCompletion private static inline function __acquire():Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		#end
	}

	@:noCompletion private static inline function __release():Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.release();
		#end
	}

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
	 * Attaches to the Windows Service Control Manager, so that a `sc stop`,
	 * a service restart or a system shutdown latches the same request
	 * `Ctrl+C` does and runs the same callbacks. Also calls
	 * `installDefaultHandlers()`, so one call covers both running as a service
	 * and running from a console during development.
	 *
	 * Returns `true` only when this process really was started by the SCM.
	 * A console run returns `false` and is fully functional — that is the
	 * expected answer in development, not a failure.
	 *
	 * The SCM is told the service is stopping as soon as the control arrives,
	 * and is told it has stopped once `poll()` has run the shutdown callbacks.
	 * A callback that finishes asynchronously must set `deferServiceStop` and
	 * call `reportServiceStopped()` itself.
	 *
	 * ```haxe
	 * ProcessLifecycle.onShutdown(() -> server.drainAndClose());
	 * ProcessLifecycle.installServiceControl("MyService");
	 * ```
	 *
	 * @param serviceName The name the service is registered under. Ignored by
	 *        Windows for a single-service process, but it is what appears in
	 *        the service's own error reporting, so pass the real one.
	 * @param connectTimeoutMs How long to wait for the handshake to settle.
	 *        Reaching it means neither outcome was reported, which should not
	 *        happen; it is a bound, not a delay, and both outcomes normally
	 *        arrive in a few milliseconds.
	 */
	public static function installServiceControl(serviceName:String, connectTimeoutMs:Int = 5000):Bool {
		installDefaultHandlers();

		#if cpp
		NativeServiceControl.attach(serviceName);

		// Polled here rather than waited on in native code: a Haxe thread
		// parked inside a Win32 wait is a thread hxcpp's collector cannot see
		// stop, which would block collection for every other thread.
		var deadline:Float = haxe.Timer.stamp() + connectTimeoutMs / 1000;
		while (NativeServiceControl.attachState() == NativeServiceControl.PENDING && haxe.Timer.stamp() < deadline) {
			Sys.sleep(0.002);
		}

		var state:Int = NativeServiceControl.attachState();

		if (state == NativeServiceControl.PENDING) {
			Logger.error('Service control handshake did not settle within ${connectTimeoutMs}ms; continuing as a console process');
		}

		return state == NativeServiceControl.ATTACHED;
		#else
		return false;
		#end
	}

	/**
	 * Tells the SCM the stop is still in progress and to allow another
	 * `waitHintMs` before treating the process as hung. Call it repeatedly
	 * from a drain that outlasts the default 30-second hint.
	 *
	 * A no-op when not running as a service.
	 */
	public static function reportServiceStopPending(waitHintMs:Int = 30000):Void {
		#if cpp
		NativeServiceControl.reportStopPending(waitHintMs);
		#end
	}

	/**
	 * Reports `SERVICE_STOPPED`. `poll()` does this for you unless
	 * `deferServiceStop` is set.
	 *
	 * The SCM may terminate the process as soon as it sees this, so call it
	 * after teardown rather than before. A no-op when not running as a service.
	 */
	public static function reportServiceStopped(exitCode:Int = 0):Void {
		#if cpp
		NativeServiceControl.reportStopped(exitCode);
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

		__acquire();
		var alreadyDispatched:Bool = __dispatched;
		if (!alreadyDispatched) {
			__callbacks.push(callback);
		}
		__release();

		// Run outside the lock so a callback registered after shutdown
		// cannot deadlock by re-entering this API.
		if (alreadyDispatched) {
			__invoke(callback);
		}
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

		// Claim the dispatch under the lock so two threads polling at once
		// cannot both run the callback list.
		__acquire();
		if (__dispatched) {
			__release();
			return false;
		}
		__dispatched = true;
		var pending:Array<() -> Void> = __callbacks;
		__callbacks = [];
		__release();

		for (callback in pending) {
			__invoke(callback);
		}
		__detach();

		if (exitOnShutdown) {
			var runtime:CrossByte = __currentRuntimeOrNull();
			if (runtime != null) {
				runtime.exit();
			}
		}

		// Last, and only once the callbacks and the runtime teardown are done:
		// the SCM is entitled to kill the process the moment it sees the service
		// report itself stopped.
		if (!deferServiceStop) {
			reportServiceStopped(0);
		}

		return true;
	}

	@:noCompletion private static function get_isService():Bool {
		#if cpp
		return NativeServiceControl.attachState() == NativeServiceControl.ATTACHED;
		#else
		return false;
		#end
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
		__acquire();
		__requested = false;
		__dispatched = false;
		__callbacks = [];
		__release();
		__detach();
		exitOnShutdown = true;
		deferServiceStop = false;
		#if cpp
		NativeLifecycle.reset();
		#end
	}
}
