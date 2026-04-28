package crossbyte._internal.socket.poll;

import crossbyte._internal.socket.HaxePollBackend;

@:noCompletion
class PollBackendRegistry {
	private static var __factory:Int->PollBackend;

	public static function register(factory:Int->PollBackend):Void {
		__factory = factory;
	}

	public static function unregister(factory:Int->PollBackend):Bool {
		if (__factory == factory) {
			__factory = null;
			return true;
		}

		return false;
	}

	public static function create(capacity:Int):PollBackend {
		if (__factory != null) {
			var backend = __factory(capacity);
			if (backend != null) {
				return backend;
			}
		}

		return new HaxePollBackend(capacity);
	}

	@:noCompletion public static function clear():Void {
		__factory = null;
	}
}
