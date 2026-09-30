package crossbyte._internal.socket.poll;

// Not built for the browser: it polls OS socket descriptors, which a page does not have. The browser socket is driven by the runtime tick instead.
#if !js

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

	/**
		The factory registered now, or null for the built-in backend. A
		registry takes it once, when it is made, and keeps making its
		backends with it: installing a backend later does not move a runtime
		already polling onto it partway through its run.
	**/
	public static function current():Null<Int->PollBackend> {
		return __factory;
	}

	public static function create(capacity:Int):PollBackend {
		return createWith(__factory, capacity);
	}

	/**
		A backend from `factory`, or the built-in one when there is none, or
		when it answers null or throws: a backend that cannot be made must not
		leave a runtime with nothing to poll with.
	**/
	public static function createWith(factory:Null<Int->PollBackend>, capacity:Int):PollBackend {
		if (factory != null) {
			try {
				var backend = factory(capacity);
				if (backend != null) {
					return backend;
				}
			} catch (error:Dynamic) {
				crossbyte.utils.Logger.warn("A poll backend could not be made, and the built-in one is used instead: " + Std.string(error));
			}
		}

		return new HaxePollBackend(capacity);
	}

	@:noCompletion public static function clear():Void {
		__factory = null;
	}
}
#end
