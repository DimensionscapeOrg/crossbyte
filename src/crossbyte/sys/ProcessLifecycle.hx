package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import crossbyte.utils.LogLevel;
import crossbyte.utils.Logger;
#if cpp
import crossbyte.sys._internal.NativeLifecycle;
import crossbyte.sys._internal.NativeServiceControl;
#end
#if (java || jvm)
import crossbyte.sys._internal.JvmSignals.JvmSignal;
import crossbyte.sys._internal.JvmSignals.JvmSignalHandler;
#end

/**
 * Cooperative process-shutdown coordination.
 *
 * `installDefaultHandlers()` arms the platform shutdown source, natively the
 * console control handler on Windows (`Ctrl+C`, console close, logoff, system
 * shutdown) and `SIGINT`, `SIGTERM` and `SIGHUP` on POSIX; listeners for the
 * same three on Node; the JVM's own signal hook for `INT`, `TERM` and `HUP` on
 * the jvm. The handler only records the request, and asks the watching runtime
 * to look; nothing else runs on the handler's thread.
 *
 * `SIGHUP`: the terminal a server was started from going away, ends a
 * process at once by default, with no callbacks; it runs the same graceful
 * shutdown as `SIGTERM` instead. A server here does not reload, which is the
 * other thing `SIGHUP` is used for. It is left alone when it was ignored as
 * the process started, `nohup`, which asks for the process to outlive its
 * terminal, or when something else already handles it: natively, on the
 * jvm (whose own hook leaves an ignored `HUP` ignored), and on Node on Linux.
 * On Node on macOS, which cannot see that it was ignored, it is left to its
 * default. On Node on Windows it is how a console window closing arrives.
 *
 * For a console window closing, a logoff or a system shutdown, Windows ends
 * the process as soon as the console handler returns. The handler therefore
 * holds the event while the runtime runs the callbacks and exits, the
 * process ending on its own lets it go, for as long as Windows allows:
 * about five seconds for a closed console window, and at most 20 seconds.
 * Ctrl+C and Ctrl+Break do not end the process, and are not held.
 *
 * Windows tells a process that has loaded user32.dll, any window, a GUI
 * toolkit, a Shell function that calls into it, of a logoff or a shutdown
 * through its windows instead of its console. Natively,
 * `installDefaultHandlers()` gives such a process a hidden window that runs
 * the same shutdown and holds the session's end the same way. CrossByte
 * loads none of user32 itself, so call it after whatever does: each call
 * looks again.
 *
 * A process in session 0, a service, or one a service started, is sent a
 * logoff whenever anyone signs out, and Windows does not end it then. It
 * ignores the logoff and keeps serving.
 *
 * A process started by the Windows Service Control Manager has no console for
 * a Ctrl+C or a close to reach, and the SCM is what stops it. A service
 * therefore needs `installServiceControl()` as well: it adds the SCM as a
 * second signal source feeding the same latch, and reports service status
 * back so that a stop waits for the shutdown callbacks rather than killing the
 * process on a timeout.
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
	 * Set this from a shutdown callback that finishes asynchronously,
	 * `HTTPServer.drain(timeout, onComplete)` being the case that matters,
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
	#if target.threaded
	@:noCompletion private static final __lock:sys.thread.Mutex = new sys.thread.Mutex();
	#end

	@:noCompletion private static inline function __acquire():Void {
		#if target.threaded
		__lock.acquire();
		#end
	}

	@:noCompletion private static inline function __release():Void {
		#if target.threaded
		__lock.release();
		#end
	}

	/**
	 * Arms the native shutdown-signal handlers and, when a CrossByte runtime
	 * is current on this thread, a tick listener that dispatches shutdown
	 * callbacks automatically.
	 *
	 * Idempotent. Returns `true` when handlers are armed: natively, on Node
	 * and on the jvm. Elsewhere, the interpreter, hl, neko, a browser, it
	 * returns `false`, and shutdown remains fully usable through
	 * `requestShutdown()`/`poll()`.
	 *
	 * Natively on Windows each call also looks for user32.dll, and makes the
	 * hidden window a process that has loaded it hears a logoff or shutdown
	 * through (see the class). Call it again after loading user32 late.
	 */
	public static function installDefaultHandlers():Bool {
		__attachToCurrentRuntime();

		#if cpp
		return NativeLifecycle.install();
		#elseif nodejs
		return __installNodeHandlers();
		#elseif (java || jvm)
		return __installJvmHandlers();
		#else
		return false;
		#end
	}

	/**
		What a signal does, on whatever thread delivers it: latches the
		request, as the native handlers do, and asks the watching runtime to
		look now rather than at its next tick.
	**/
	@:noCompletion private static function __onSignal():Void {
		requestShutdown();
		var runtime:CrossByte = __watchedRuntime;
		if (runtime != null) {
			runtime.post(__pollFromSignal);
		}
	}

	@:noCompletion private static function __pollFromSignal():Void {
		poll();
	}

	#if nodejs
	@:noCompletion private static var __nodeHandlersInstalled:Bool = false;

	// Node exits on SIGTERM and SIGINT unless something listens, so `docker
	// stop` or Ctrl+C on a Node service skipped the drain entirely. Listening
	// is also what keeps it from exiting: shutdown is then the application's.
	@:noCompletion private static function __installNodeHandlers():Bool {
		if (!__nodeHandlersInstalled) {
			__nodeHandlersInstalled = true;
			js.Node.process.on("SIGTERM", __onSignal);
			js.Node.process.on("SIGINT", __onSignal);
			if (__hangupIsUnclaimed()) {
				js.Node.process.on("SIGHUP", __onSignal);
			}
		}
		return true;
	}

	/**
		Whether SIGHUP is Node's to end the process with, as it does unless
		something listens: no listener of the application's, and not ignored
		when Node started (nohup), which only Linux shows, the process's
		ignored signals are in /proc/self/status. On Windows it is a console
		window closing, which nothing ignores; on macOS it is left alone.
	**/
	@:noCompletion private static function __hangupIsUnclaimed():Bool {
		if (js.Node.process.listenerCount("SIGHUP") > 0) {
			return false;
		}
		switch (js.Node.process.platform) {
			case "win32":
				return true;
			case "linux":
				try {
					var status:String = js.node.Fs.readFileSync("/proc/self/status", {encoding: "utf8"});
					var ignored:EReg = ~/SigIgn:\s*([0-9a-fA-F]+)/;
					if (!ignored.match(status)) {
						return false;
					}
					// SIGHUP is signal 1, the mask's lowest bit.
					var mask:String = ignored.matched(1);
					var lowest:Int = crossbyte.utils.IntParse.hex(mask.charAt(mask.length - 1), 15);
					return lowest >= 0 && (lowest & 1) == 0;
				} catch (_:Dynamic) {
					return false;
				}
			default:
				return false;
		}
	}
	#end

	#if (java || jvm)
	@:noCompletion private static var __jvmHandlersInstalled:Bool = false;

	// The JVM's default for SIGTERM and SIGINT runs its shutdown hooks and
	// halts, so `docker stop` or Ctrl+C on a jvm service skipped the drain.
	// Its own signal hook replaces that; a JVM without one reports false.
	@:noCompletion private static function __installJvmHandlers():Bool {
		if (__jvmHandlersInstalled) {
			return true;
		}

		var handler = new LatchOnSignal();
		try {
			JvmSignal.handle(new JvmSignal("TERM"), handler);
			JvmSignal.handle(new JvmSignal("INT"), handler);
			__jvmHandlersInstalled = true;
		} catch (_:Dynamic) {}

		// HUP, which the JVM also answers by halting. Asked for on its own: a
		// JVM on Windows has no such signal and refuses the name. The JVM's
		// hook installs nothing for a HUP ignored as it started, nohup,
		// and it stays ignored.
		if (__jvmHandlersInstalled) {
			try {
				JvmSignal.handle(new JvmSignal("HUP"), handler);
			} catch (_:Dynamic) {}
		}
		return __jvmHandlersInstalled;
	}
	#end

	/**
	 * Attaches to the Windows Service Control Manager, so that a `sc stop`,
	 * a service restart or a system shutdown latches the same request
	 * `Ctrl+C` does and runs the same callbacks. Also calls
	 * `installDefaultHandlers()`, so one call covers both running as a service
	 * and running from a console during development.
	 *
	 * Returns `true` only when this process really was started by the SCM.
	 * A console run returns `false` and is fully functional, that is the
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
			crossbyte._internal.system.Sleep.sleep(0.002);
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
	 * immediately. An exception thrown by a callback is logged with
	 * `Logger.error` (category "runtime") and goes no further, so later
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

	@:noCompletion private static function __invoke(callback:() -> Void):Void {
		try {
			callback();
		} catch (error:Dynamic) {
			// A failing shutdown callback must not block the remaining
			// callbacks or the exit path. It is logged, as the runtime logs
			// any other callback's failure: this was swallowed without a
			// word, so a drain that never flushed left nothing behind to say
			// why.
			Logger.log(LogLevel.ERROR, "A shutdown callback threw: " + Std.string(error), null, "runtime");
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

#if (java || jvm)
// Runs on the JVM's signal-dispatch thread, so it only latches and posts.
private class LatchOnSignal implements JvmSignalHandler {
	public function new() {}

	public function handle(signal:JvmSignal):Void {
		@:privateAccess ProcessLifecycle.__onSignal();
	}
}
#end
