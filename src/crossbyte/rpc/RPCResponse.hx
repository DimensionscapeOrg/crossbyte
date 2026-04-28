package crossbyte.rpc;

import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.EventType;
import crossbyte.events.IEventDispatcher;

@:allow(crossbyte.rpc.RPCCommands)
class RPCResponse<T> implements IEventDispatcher {
	public static inline final RESULT:String = "rpcResponseResult";
	public static inline final ERROR:String = "rpcResponseError";

	public final requestId:Int;
	public final op:Int;
	public var completed(default, null):Bool = false;
	public var succeeded(default, null):Bool = false;
	public var result(default, null):Null<T>;
	public var error(default, null):String;

	@:noCompletion private var __responder:Responder<T>;
	@:noCompletion private var __dispatcher:Null<EventDispatcher>;

	public function new(requestId:Int, op:Int, ?responder:Responder<T>) {
		this.requestId = requestId;
		this.op = op;
		this.__responder = responder;
		this.__dispatcher = null;
	}

	public inline function addEventListener<U>(type:EventType<U>, listener:U->Void, priority:Int = 0):Void {
		__ensureDispatcher().addEventListener(type, listener, priority);
	}

	public inline function removeEventListener<U>(type:EventType<U>, listener:U->Void):Void {
		if (__dispatcher != null) {
			__dispatcher.removeEventListener(type, listener);
		}
	}

	public inline function hasEventListener(type:String):Bool {
		return __dispatcher != null && __dispatcher.hasEventListener(type);
	}

	public inline function removeAllListeners():Void {
		if (__dispatcher != null) {
			__dispatcher.removeAllListeners();
		}
	}

	public inline function dispatchEvent<E:Event>(event:E):Bool {
		return __dispatcher != null && __dispatcher.dispatchEvent(event);
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
		if (hasEventListener(RESULT)) {
			dispatchEvent(new Event(RESULT));
		}
	}

	@:noCompletion private function __reject(message:String):Void {
		if (completed) {
			return;
		}
		completed = true;
		succeeded = false;
		error = message;
		__notifyResponder();
		if (hasEventListener(ERROR)) {
			dispatchEvent(new Event(ERROR));
		}
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

	@:noCompletion private inline function __ensureDispatcher():EventDispatcher {
		if (__dispatcher == null) {
			__dispatcher = new EventDispatcher(cast this);
		}
		return __dispatcher;
	}
}

typedef RPCResonse<T> = RPCResponse<T>;
