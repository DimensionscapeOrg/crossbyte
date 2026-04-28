package crossbyte.rpc;

/** Callback pair used by `RPCResponse` to deliver typed success or error results. */
class Responder<T> {
	@:noCompletion private var __onResult:T->Void;
	@:noCompletion private var __onError:String->Void;

	public function new(?onResult:T->Void, ?onError:String->Void) {
		__onResult = onResult;
		__onError = onError;
	}

	/** Delivers a successful RPC result to the registered callback. */
	public inline function result(value:T):Void {
		if (__onResult != null) {
			__onResult(value);
		}
	}

	/** Delivers an RPC error message to the registered callback. */
	public inline function error(message:String):Void {
		if (__onError != null) {
			__onError(message);
		}
	}
}
