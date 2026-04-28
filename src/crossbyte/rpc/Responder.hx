package crossbyte.rpc;

class Responder<T> {
	@:noCompletion private var __onResult:T->Void;
	@:noCompletion private var __onError:String->Void;

	public function new(?onResult:T->Void, ?onError:String->Void) {
		__onResult = onResult;
		__onError = onError;
	}

	public inline function result(value:T):Void {
		if (__onResult != null) {
			__onResult(value);
		}
	}

	public inline function error(message:String):Void {
		if (__onError != null) {
			__onError(message);
		}
	}
}
