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

	public static function resolve(version:HTTPVersion):Null<HTTPBackend> {
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
