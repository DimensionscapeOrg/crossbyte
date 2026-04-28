package crossbyte.rpc;

import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;

@:allow(crossbyte.rpc.RPCCommands)
class RPCResponse<T> extends EventDispatcher {
	public static inline final RESULT:String = "rpcResponseResult";
	public static inline final ERROR:String = "rpcResponseError";

	public final requestId:Int;
	public final op:Int;
	public var completed(default, null):Bool = false;
	public var succeeded(default, null):Bool = false;
	public var result(default, null):Null<T>;
	public var error(default, null):String;

	@:noCompletion private var __responder:Responder<T>;

	public function new(requestId:Int, op:Int, ?responder:Responder<T>) {
		super();
		this.requestId = requestId;
		this.op = op;
		this.__responder = responder;
	}

	public inline function respond(responder:Responder<T>):RPCResponse<T> {
		__responder = responder;
		if (completed) {
			__notifyResponder();
		}
		return this;
	}

	public inline function then(onResult:T->Void, ?onError:String->Void):RPCResponse<T> {
		return respond(new Responder(onResult, onError));
	}

	@:noCompletion private function __resolve(value:T):Void {
		if (completed) {
			return;
		}
		completed = true;
		succeeded = true;
		result = value;
		__notifyResponder();
		dispatchEvent(new Event(RESULT));
	}

	@:noCompletion private function __reject(message:String):Void {
		if (completed) {
			return;
		}
		completed = true;
		succeeded = false;
		error = message;
		__notifyResponder();
		dispatchEvent(new Event(ERROR));
	}

	@:noCompletion private inline function __notifyResponder():Void {
		if (__responder == null) {
			return;
		}
		if (succeeded) {
			__responder.result(result);
		} else {
			__responder.error(error);
		}
	}
}

typedef RPCResonse<T> = RPCResponse<T>;
