package crossbyte.http;

#if (cpp || neko || hl || java || jvm)
import sys.thread.Mutex;
#end

/**
 * Registry for optional HTTP client backends such as HTTP/2 or HTTP/3.
 *
 * Backends are normally registered once during startup, but `resolve()`
 * runs on whichever thread is making a request, so mutation and lookup are
 * synchronized: an unguarded array can be reallocated mid-read by a
 * concurrent `register()`, which on a native target is a use-after-free
 * rather than a merely stale result.
 */
class HTTPBackendRegistry {
	private static var __backends:Array<HTTPBackend> = [];

	#if (cpp || neko || hl || java || jvm)
	private static final __lock:Mutex = new Mutex();
	#end

	public static function register(backend:HTTPBackend):Void {
		if (backend == null) {
			return;
		}

		__acquire();
		if (__backends.indexOf(backend) < 0) {
			// Replace rather than push so a concurrent resolve() keeps
			// iterating the snapshot it already holds.
			var updated:Array<HTTPBackend> = __backends.copy();
			updated.push(backend);
			__backends = updated;
		}
		__release();
	}

	public static function unregister(backend:HTTPBackend):Bool {
		if (backend == null) {
			return false;
		}

		__acquire();
		var updated:Array<HTTPBackend> = __backends.copy();
		var removed:Bool = updated.remove(backend);
		if (removed) {
			__backends = updated;
		}
		__release();

		return removed;
	}

	/**
	 * Whether an unresolved HTTP/2 request may fall back to the bundled
	 * backend.
	 *
	 * On by default, because a program that asked for HTTP/2 and got told to
	 * register a class shipped in the same library has been given a chore, not
	 * a choice. Set it to `false` before the first request to guarantee that
	 * only backends you registered are ever used.
	 *
	 * The cost is that `crossbyte.http.HTTP2Backend` -- and the framing layer
	 * behind it -- is reachable from here, so it links into any build that
	 * makes HTTP requests at all rather than only into ones that ask for
	 * HTTP/2. Measured at roughly 170 KB on a 4 MB native binary.
	 *
	 * Setting this to `false` stops the registration but not the linkage: the
	 * reference still exists, so the code is still reachable. Compile with
	 * `-D crossbyte_no_http2` to remove the reference entirely and let dead
	 * code elimination take the subsystem with it. Explicit registration keeps
	 * working either way, because the reference is then the caller's own.
	 */
	public static var autoRegisterBundled:Bool = true;

	private static var __bundledRegistered:Bool = false;

	public static function resolve(version:HTTPVersion):Null<HTTPBackend> {
		var found:Null<HTTPBackend> = __search(version);
		if (found != null) {
			return found;
		}

		if (!__registerBundled(version)) {
			return null;
		}

		return __search(version);
	}

	/**
	 * Registers the bundled HTTP/2 backend, once, if that is what was asked
	 * for. Returns whether anything was added.
	 *
	 * Registered rather than returned directly so an explicitly registered
	 * backend still wins: `__search` walks newest first, so anything the
	 * caller adds afterwards takes precedence over this.
	 */
	private static function __registerBundled(version:HTTPVersion):Bool {
		#if (!js && !crossbyte_no_http2)
		if (!autoRegisterBundled || __bundledRegistered || version != HTTPVersion.HTTP_2) {
			return false;
		}

		__acquire();
		if (__bundledRegistered) {
			__release();
			return false;
		}
		__bundledRegistered = true;
		__release();

		register(new HTTP2Backend());
		return true;
		#else
		return false;
		#end
	}

	private static function __search(version:HTTPVersion):Null<HTTPBackend> {
		__acquire();
		var snapshot:Array<HTTPBackend> = __backends;
		__release();

		var index:Int = snapshot.length - 1;
		while (index >= 0) {
			var backend = snapshot[index];
			if (backend.supports(version)) {
				return backend;
			}
			index--;
		}

		return null;
	}

	public static function isRegistered(version:HTTPVersion):Bool {
		return resolve(version) != null;
	}

	@:noCompletion public static function clear():Void {
		__acquire();
		__backends = [];
		// Cleared too, or a test that empties the registry would find the
		// bundled backend permanently absent rather than re-registered on
		// demand like it is in a fresh process.
		__bundledRegistered = false;
		__release();
	}

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
}
