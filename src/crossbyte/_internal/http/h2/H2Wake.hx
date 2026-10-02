package crossbyte._internal.http.h2;

// Threads, so not any JavaScript target, as the client that uses it.
#if !js
#if eval
/**
	What a thread of the HTTP/2 client waits on: a `sys.thread.Lock`, but on
	eval, where a `Lock` waits by polling, half a core while it waits with
	no timeout and a whole one with, measured on Linux (see the vendored
	`sys.net.Socket`), and holds the interpreter from the very threads it
	waits for. A connection is a reader, a writer and its requests handing
	work to one another, so there its requests timed out behind their own
	connection's waits. This is a `Semaphore` there, whose wait blocks, and a
	timed wait looks for a release once a millisecond between sleeps, since
	the `Semaphore`'s own timed wait spins.
**/
class H2Wake {
	private final __semaphore:sys.thread.Semaphore = new sys.thread.Semaphore(0);

	public function new() {}

	public inline function release():Void {
		__semaphore.release();
	}

	/** Waits for a release, for `timeout` seconds at most when given; false if none came. */
	public function wait(?timeout:Float):Bool {
		if (timeout == null) {
			__semaphore.acquire();
			return true;
		}
		var deadline:Float = haxe.Timer.stamp() + timeout;
		while (!__semaphore.tryAcquire()) {
			var left:Float = deadline - haxe.Timer.stamp();
			if (left <= 0) {
				return false;
			}
			crossbyte._internal.system.Sleep.sleep(left < 0.001 ? left : 0.001);
		}
		return true;
	}
}
#else
/** What a thread of the HTTP/2 client waits on; see the eval build's doc. */
typedef H2Wake = sys.thread.Lock;
#end
#end
