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
		__crossByte.addEventListener(Event.INIT, __onInit);
		__crossByte.addEventListener(Event.EXIT, __onExit);
	}
}
