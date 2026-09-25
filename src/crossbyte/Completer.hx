package crossbyte;

import crossbyte.errors.Error;

/**
	The side of a `Future` that completes it.

	A `Future` is read by whoever is handed it, and completing one is kept
	from them: a future anyone can resolve is a future nobody can trust. Code
	that makes a promise of its own -- an answer that arrives when a lobby
	fills, a query finishes on another thread, a peer replies -- makes a
	`Completer`, hands out its `future`, and keeps the ability to complete it
	here.

	```haxe
	var completer = new Completer<Int>();
	var answer:Future<Int> = completer.future;
	answer.then(value -> trace('got $value'));
	completer.complete(42);
	```

	Completing from any thread is safe; the future's callbacks run on the
	thread that completes it. The first of `complete` and `fail` decides; any
	later call does nothing and returns `false`.

	The name is Dart's, whose `Completer` completes a `Future` in the same
	way. "Promise" is the other name this has elsewhere, but in JavaScript --
	and so in `js.lib.Promise` -- a promise is the side that is read.
**/
class Completer<T> {
	/** The future this completes, to hand to whoever is waiting. **/
	public final future:Future<T>;

	/** `true` once `complete` or `fail` has been called. **/
	public var completed(get, never):Bool;

	public function new() {
		future = new Future<T>();
	}

	/**
		Completes the future with `value`.

		@return `false` if it had already been completed, when nothing changes.
	**/
	public function complete(value:T):Bool {
		// Decided under the future's lock, so of two threads completing at
		// once exactly one is told it did.
		return future.__resolve(value);
	}

	/**
		Fails the future with `error`, as a function fails by throwing it.

		The future's `error` is the message -- an `Error`'s or an exception's
		`message`, a `String` as it is, anything else as `Std.string` gives it
		-- and its `cause` is `error` itself. An RPC handler answering with this
		future passes a `crossbyte.rpc.RPCError`'s message to its caller, as it
		would one it threw, and anything else as an internal error.

		@return `false` if it had already been completed, when nothing changes.
	**/
	public function fail(error:Dynamic):Bool {
		return future.__fail(__messageOf(error), error);
	}

	@:noCompletion private inline function get_completed():Bool {
		return future.completed;
	}

	@:noCompletion private static function __messageOf(error:Dynamic):String {
		if (error == null) {
			return "failed";
		}
		if (Std.isOfType(error, String)) {
			return error;
		}
		if (Std.isOfType(error, Error)) {
			return (cast error : Error).message;
		}
		if (Std.isOfType(error, haxe.Exception)) {
			return (cast error : haxe.Exception).message;
		}
		return Std.string(error);
	}
}
