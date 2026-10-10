package crossbyte.rpc;

import crossbyte.errors.Error;

/**
	An error an RPC handler means its caller to see.

	Thrown from a handler method, its `message` becomes the caller's answer:
	the `RPCResponse` the call returned fails with it, word for word, and the
	connection carries on. Use it for what the caller can act on: a player
	that does not exist, an argument out of range, a request refused.

	Anything else a handler throws is the handler failing, and the caller is
	told only `INTERNAL_MESSAGE`. The error itself goes to
	`RPCSession.onHandlerError` on the side it happened, so a stack trace, a
	path or a database error stays on the server rather than crossing to
	whoever made the call.
**/
class RPCError extends Error {
	/**
		What a caller is told when a handler throws anything but an
		`RPCError`.
	**/
	public static inline final INTERNAL_MESSAGE:String = "Internal error";

	/**
		What a caller is told when its call is refused because too many calls
		on its connection are still waiting on an answer; see
		`RPCSession.maxCallsWaiting`.
	**/
	public static inline final BUSY_MESSAGE:String = "Too many calls are waiting on this connection";

	/**
		What a caller is told when the handler of its call has not answered
		within the session's `RPCSession.handlerTimeout`.
	**/
	public static inline final TIMEOUT_MESSAGE:String = "The call timed out";

	/**
		The message of the error a handler's `afterCall` sees for a call its
		caller cancelled, which the caller is not answered: it has stopped
		waiting. See `RPCCall`.
	**/
	public static inline final CANCELLED_MESSAGE:String = "The caller cancelled the call";

	/**
		What a caller is told when its call reaches a session with no handler
		to answer it: one with commands only, or only runtime handlers.
	**/
	public static inline final NO_HANDLER_MESSAGE:String = "Nothing answers calls on this connection";

	/**
		What a caller is told when the other side has no method its call
		names: none of that name, or none with that signature (a peer built
		from another version of the contract, or from before the method was
		added, as in a rolling deploy) and, on the runtime lane, no handler
		registered for its number. See `RPCSession.onUnreadableFrame`.
	**/
	public static inline final UNKNOWN_METHOD_MESSAGE:String = "No method here answers this call";

	/**
		What a caller is told when the other side could not read its call's
		arguments: they ran past the end of their frame, named more than it
		holds, or carried a value of a kind it does not know.
	**/
	public static inline final UNREADABLE_MESSAGE:String = "The call's arguments could not be read";

	/**
		@param message What the caller is told.
		@param id A number for the error, kept on this side; only the message
		crosses the wire.
	**/
	public function new(message:String = "", id:Int = 0) {
		super(message, id);
		name = "RPCError";
	}

	/**
		A refusal its caller is told as `failure`, a status of the
		protocol's own rather than `RPCFailure.Refused`, as a gRPC handler
		answers with a status code: `Busy` from a `beforeCall` that rate
		limits, `UnknownMethod` for one a handler does not serve after all,
		and the rest of the session's own refusals (`UnreadableArguments`,
		`NoHandler`, `HandlerTimedOut`, `HandlerFailed`). Thrown, returned
		from `beforeCall` or `beforeRuntimeCall`, or failing a handler's
		future, as any `RPCError`.

		```haxe
		override public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<RPCError> {
			return tooMany() ? RPCError.refusal(Busy, "Slow down.") : null;
		}
		```

		@param message What a future's `error` says; the case's own
		message (`BUSY_MESSAGE` for `Busy`) when left out.
		@throws ArgumentError For a failure that is not a refusal (`TimedOut`,
		`Cancelled`, and the rest that only this side can find). `Refused(m)`
		is an `RPCError` of `m`.
	**/
	public static function refusal(failure:RPCFailure, ?message:String):RPCError {
		final code:Int = switch (failure) {
			case Refused(words):
				return new RPCError(message != null ? message : words);
			case HandlerFailed: crossbyte.rpc._internal.RPCWire.REFUSED_HANDLER_FAILED;
			case UnknownMethod: crossbyte.rpc._internal.RPCWire.REFUSED_UNKNOWN_METHOD;
			case UnreadableArguments: crossbyte.rpc._internal.RPCWire.REFUSED_UNREADABLE;
			case Busy: crossbyte.rpc._internal.RPCWire.REFUSED_BUSY;
			case NoHandler: crossbyte.rpc._internal.RPCWire.REFUSED_NO_HANDLER;
			case HandlerTimedOut: crossbyte.rpc._internal.RPCWire.REFUSED_HANDLER_TIMEOUT;
			case other:
				throw new crossbyte.errors.ArgumentError('$other is not a refusal a handler can answer with');
		};
		return new crossbyte.rpc._internal.RPCRefusal(message != null ? message : crossbyte.rpc._internal.RPCWire.refusalMessage(code), code);
	}
}
