package crossbyte.rpc;

import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.EventType;
import crossbyte.events.IEventDispatcher;

@:allow(crossbyte.rpc.RPCCommands)
@:allow(crossbyte.rpc.RPCSession)
/**
 * Represents the eventual result of a request/response RPC invocation.
 *
 * `RPCResponse` supports both callback-style consumption through `Responder`
 * and event-style observation through `IEventDispatcher`. It dispatches
 * `RESULT` or `ERROR` once and then becomes immutable.
 */
class RPCResponse<T> implements IEventDispatcher {
	/** Dispatched when the response resolves successfully. */
	public static inline final RESULT:String = "rpcResponseResult";
	/** Dispatched when the response resolves with an error. */
	public static inline final ERROR:String = "rpcResponseError";

	/** Request identifier assigned by the originating `RPCCommands` instance. */
	public final requestId:Int;
	/** Operation code associated with the request. */
	public final op:Int;
	/** `true` after the response has either resolved or rejected. */
	public var completed(default, null):Bool = false;
	/** `true` only when the response resolved successfully. */
	public var succeeded(default, null):Bool = false;
	/** Typed result value when `succeeded` is `true`. */
	public var result(default, null):Null<T>;
	/** Error message when `succeeded` is `false`. */
	public var error(default, null):String;

	@:noCompletion private var __responder:Responder<T>;
	@:noCompletion private var __dispatcher:Null<EventDispatcher>;

	public function new(requestId:Int, op:Int, ?responder:Responder<T>) {
		this.requestId = requestId;
		this.op = op;
		this.__responder = responder;
		this.__dispatcher = null;
	}

	/** Registers an event listener for `RESULT` or `ERROR`. */
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

	/** Binds or replaces the responder that should receive the final result. */
	public inline function respond(responder:Responder<T>):RPCResponse<T> {
		__responder = responder;
		if (completed) {
			__notifyResponder();
		}
		return this;
	}

	/** Convenience alias for `respond(new Responder(onResult, onError))`. */
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
