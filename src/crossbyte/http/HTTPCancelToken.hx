package crossbyte.http;

#if (cpp || neko || hl || java || jvm)
import sys.thread.Mutex;
#end

/**
 * Cancels a request that is already in flight.
 *
 * A token rather than a handle returned from `load()`, because `load()` is
 * blocking: it returns when the request is over, which is exactly when a
 * handle would stop being useful. Whoever wants to cancel is on another
 * thread, and needs something to hold *before* the request starts.
 *
 * Cancelling is one-way and idempotent. Handlers registered after the fact run
 * immediately, which closes the race a consumer would otherwise lose: a
 * request cancelled in the instant between a backend accepting it and
 * registering its handler would otherwise run to completion with nobody left
 * to stop it.
 */
class HTTPCancelToken {
	/** True once `cancel()` has been called. Never returns to false. */
	public var cancelled(default, null):Bool = false;

	private var __handlers:Array<Void->Void> = [];

	#if (cpp || neko || hl || java || jvm)
	private final __lock:Mutex = new Mutex();
	#end

	public function new() {}

	/**
	 * Requests cancellation, running every registered handler once.
	 *
	 * Safe from any thread, and safe to call more than once: only the first
	 * call does anything.
	 */
	public function cancel():Void {
		__acquire();
		if (cancelled) {
			__release();
			return;
		}
		cancelled = true;

		var pending:Array<Void->Void> = __handlers;
		__handlers = [];
		__release();

		for (handler in pending) {
			try {
				handler();
			} catch (_:Dynamic) {
				// A handler that throws must not stop the others: each one is
				// a different resource that still needs releasing.
			}
		}
	}

	/**
	 * Registers work to do when cancellation is requested.
	 *
	 * Runs immediately when the token is already cancelled, so a backend that
	 * registers late still stops.
	 */
	public function onCancel(handler:Void->Void):Void {
		if (handler == null) {
			return;
		}

		__acquire();
		if (cancelled) {
			__release();
			handler();
			return;
		}

		__handlers.push(handler);
		__release();
	}

	/** Forgets a handler whose request has finished on its own. */
	public function removeHandler(handler:Void->Void):Void {
		__acquire();
		__handlers.remove(handler);
		__release();
	}

	private inline function __acquire():Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		#end
	}

	private inline function __release():Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.release();
		#end
	}
}
