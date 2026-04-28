package crossbyte.http;

/**
 * Registry for optional HTTP client backends such as HTTP/2 or HTTP/3.
 */
class HTTPBackendRegistry {
	private static var __backends:Array<HTTPBackend> = [];

	public static function register(backend:HTTPBackend):Void {
		if (backend == null || __backends.indexOf(backend) >= 0) {
			return;
		}

		__backends.push(backend);
	}

	public static function unregister(backend:HTTPBackend):Bool {
		return __backends.remove(backend);
	}

	public static function resolve(version:HTTPVersion):Null<HTTPBackend> {
		var index:Int = __backends.length - 1;
		while (index >= 0) {
			var backend = __backends[index];
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
		__backends = [];
	}
}
