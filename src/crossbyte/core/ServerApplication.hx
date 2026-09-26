package crossbyte.core;

import crossbyte.events.Event;
#if !js
import sys.thread.Thread;
#end

/**
 * A primordial CrossByte application with a poll-driven main loop.
 *
 * `ServerApplication` is intended for standalone server-style programs where
 * CrossByte should own the primary application runtime and continuously poll
 * sockets on the main thread.
 *
 * This is a good fit for:
 * - dedicated network services
 * - headless daemons
 * - standalone CrossByte server processes
 *
 * If CrossByte is being embedded into another framework that already owns the
 * process main thread, prefer `HostApplication` for the primordial app and
 * create additional child `CrossByte` instances for worker or server-style
 * threaded runtimes.
 */
@:access(crossbyte.core.CrossByte)
class ServerApplication extends Application {
	/**
	 * Tick rate a `ServerApplication` starts at, or `0` to inherit the
	 * runtime's own default.
	 *
	 * Defaults to `0`. The runtime ticks at 12 per second, a deliberately
	 * low-power cadence: an idle service costs twelve wakeups a second
	 * rather than sixty, which is what most networked mechanisms want when
	 * nothing is happening.
	 *
	 * Raise it when tick cadence is your latency bound. The `POLL` loop spends
	 * the rest of each frame inside poll, so a socket that becomes ready, or
	 * work posted from another thread, wakes it at once; what waits for the
	 * next tick is timers and tick listeners. On JavaScript, where nothing is
	 * polled, `POLL` runs the `DEFAULT` loop.
	 *
	 * Assign before instantiating, or set `crossByte.tps` afterwards.
	 */
	public static var defaultTicksPerSecond:UInt = 0;

	/**
	 * Creates the primordial poll-driven application.
	 */
	private function new(timers:TimerStrategy = HEAP):Void {
		super(POLL, false, timers);
	}

	/**
	 * Initializes the primordial application with a poll-based CrossByte root.
	 *
	 * This may only be constructed once and must still occur on the process
	 * main thread.
	 */
	override function initialize() {
		if (Application.__application != null) {
			throw "ServerApplication must only be instantiated once by extending it.";
		}

		// Ensure we're in the main thread
		#if !js
		// A negated ==, not !=: see Application.initialize.
		if (!(Thread.current() == Application.__mainThread)) {
			throw "ServerApplication must only be instantiated in the main thread!";
		}
		#end

		Application.__application = this;
		// Built from what the constructor passed up, timer strategy included.
		// This named POLL and nothing else, so `new ServerApplication(WHEEL)`
		// ran on the heap.
		__crossByte = __createRuntime();

		// A service default rather than the runtime's general-purpose one;
		// see defaultTicksPerSecond. Applied before INIT so a subclass can
		// still override it from its own handler.
		if (defaultTicksPerSecond > 0) {
			__crossByte.tps = defaultTicksPerSecond;
		}

		__crossByte.addEventListener(Event.INIT, __onInit);
		__crossByte.addEventListener(Event.EXIT, __onExit);
	}
}
