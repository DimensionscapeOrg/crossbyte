package crossbyte.core;

import crossbyte.events.Event;
import sys.thread.Thread;

@:access(crossbyte.core.CrossByte)
class ServerApplication extends Application {
	private function new():Void {
		super();
	}

	override function initialize() {
		if (Application.__application != null) {
			throw "ServerApplication must only be instantiated once by extending it.";
		}

		// Ensure we're in the main thread
		if (Thread.current() != Application.__mainThread) {
			throw "ServerApplication must only be instantiated in the main thread!";
		}

		Application.__application = this;
		__crossByte = new CrossByte(true, POLL);
		__crossByte.addEventListener(Event.INIT, __onInit);
		__crossByte.addEventListener(Event.EXIT, __onExit);
	}
}
