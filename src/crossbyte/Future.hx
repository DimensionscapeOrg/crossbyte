package crossbyte;

import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.EventType;
import crossbyte.events.IEventDispatcher;

/**
 * The eventual result of something that has not finished yet.
 *
 * This was `crossbyte.rpc.RPCResponse`, and nothing about it was ever
 * RPC-specific: a value that arrives later, callbacks for the two ways that can
 * go, and events for anyone who would rather observe than be called. Promoting
 * it is not tidying. It is the difference between a framework with one way of
 * saying "later" and a framework with four -- events on `URLLoader`, threads on
 * `Task`, `then` on RPC, and whatever the next asynchronous API invented for
 * itself.
 *
 * `RPCResponse` remains, extending this and adding the two fields that really
 * are about RPC, so nothing on that side moves.
 *
 * Resolution is deliberately not public. A `Future` handed to a caller is
 * something they read; the code that created it keeps the ability to complete
 * it through `@:allow`. A future anyone can resolve is a future nobody can
 * trust.
 */
@:allow(crossbyte)
class Future<T> implements IEventDispatcher {
	/** Dispatched, once, when the value arrives. */
	public static inline final RESULT:String = "futureResult";

	/** Dispatched, once, when it will not. */
	public static inline final ERROR:String = "futureError";

	/** `true` once this has either resolved or failed. */
	public var completed(default, null):Bool = false;

	/** `true` only when it resolved. */
	public var succeeded(default, null):Bool = false;

	/** The value, when `succeeded`. */
	public var result(default, null):Null<T>;

	/** Why not, when it did not. */
	public var error(default, null):String;

	@:noCompletion private var __onResult:Null<T->Void>;
	@:noCompletion private var __onError:Null<String->Void>;
	@:noCompletion private var __dispatcher:Null<EventDispatcher>;

	public function new() {}

	/**
	 * Registers what to do with the value, and optionally with a failure.
	 *
	 * Safe to call after the fact: a future that has already completed calls
	 * back immediately rather than silently never calling. That asymmetry --
	 * where registering a moment too late means never hearing -- is the
	 * classic way an asynchronous API loses a result.
	 */
	public function then(onResult:T->Void, ?onError:String->Void):Future<T> {
		__onResult = onResult;
		__onError = onError;

		if (completed) {
			__notify();
		}

		return this;
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

	@:noCompletion private function __resolve(value:T):Void {
		if (completed) {
			return;
		}

		completed = true;
		succeeded = true;
		result = value;
		__notify();

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
		__notify();

		if (hasEventListener(ERROR)) {
			dispatchEvent(new Event(ERROR));
		}
	}

	@:noCompletion private function __notify():Void {
		if (succeeded) {
			if (__onResult != null) {
				__onResult(result);
			}
		} else if (__onError != null) {
			__onError(error);
		}
	}

	@:noCompletion private inline function __ensureDispatcher():EventDispatcher {
		if (__dispatcher == null) {
			__dispatcher = new EventDispatcher(cast this);
		}
		return __dispatcher;
	}
}
