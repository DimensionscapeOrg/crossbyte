package crossbyte.net;

import crossbyte.core.CrossByte;

/**
	Pumps the test runtime until something happens, on every target.

	A loop that pumps and sleeps works natively and cannot work on JavaScript:
	Node and a browser deliver socket I/O by returning to their event loop, and
	a loop holding the thread never returns to it -- so nothing arrives and the
	wait spends its whole timeout. There the pumping is spread over turns of
	the event loop instead. Everywhere else it stays a plain loop, so a
	failing assertion still unwinds through the test body.

	The socket tests' own copy rather than `HTTPTestSupport`'s: that one only
	knows Node, and some of these run in a page.

	Deadlines are `haxe.Timer.stamp()`, the one monotonic clock.
**/
class NetPump {
	/**
		Pumps until `done` reports true or `timeout` seconds pass, then calls
		`then` with whether it finished rather than timed out.
	**/
	public static function until(done:Void->Bool, timeout:Float, then:Bool->Void):Void {
		var runtime:CrossByte = CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + timeout;
		var last:Float = haxe.Timer.stamp();

		// Each pump advances the runtime's timers by the time that really
		// passed, not by a nominal frame. A fixed 1/60 per pump, with the
		// pumps a millisecond apart, ran timers -- utest's own timeout among
		// them -- about ten times faster than the clock, so a case that waited
		// ten real seconds had long since been declared timed out.
		function step():Void {
			var now:Float = haxe.Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;
		}

		#if js
		function turn():Void {
			step();

			if (done()) {
				then(true);
				return;
			}

			if (haxe.Timer.stamp() >= deadline) {
				then(false);
				return;
			}

			// A timer rather than an immediate: an immediate runs before the
			// loop polls for I/O, so a chain of them starves the sockets
			// being waited on.
			#if nodejs
			js.Node.setTimeout(turn, 1);
			#else
			js.Browser.window.setTimeout(turn, 1);
			#end
		}

		turn();
		#else
		while (!done() && haxe.Timer.stamp() < deadline) {
			step();
			Sys.sleep(0.001);
		}

		then(done());
		#end
	}

	/** Pumps for `seconds` whatever happens, then calls `then`. **/
	public static function wait(seconds:Float, then:Void->Void):Void {
		until(() -> false, seconds, _ -> then());
	}
}
