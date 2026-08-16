package crossbyte.core;

import crossbyte.events.Event;
import sys.thread.Thread;

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
	 * Tick rate a `ServerApplication` starts at.
	 *
	 * The loop polls sockets with a zero timeout and then waits out the
	 * rest of the frame, so the tick interval bounds how long a ready
	 * socket can sit unserviced. At the runtime's general-purpose default
	 * of 12 ticks per second that is up to ~83 ms of added latency per
	 * hop — reasonable for an application loop, poor for a network
	 * service.
	 *
	 * 60 keeps that under ~17 ms while leaving frames long enough that the
	 * loop is not spinning. Raise it for latency-sensitive services, lower
	 * it to trade responsiveness for fewer idle wakeups. Assign before
	 * instantiating, or set `crossByte.tps` afterwards.
	 */
	public static var defaultTicksPerSecond:UInt = 60;

	/**
	 * Creates the primordial poll-driven application.
	 */
	private function new():Void {
		super(POLL);
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
		if (Thread.current() != Application.__mainThread) {
			throw "ServerApplication must only be instantiated in the main thread!";
		}

		Application.__application = this;
		__crossByte = new CrossByte(true, POLL, false);

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
