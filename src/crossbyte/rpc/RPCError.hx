package crossbyte.rpc;

import crossbyte.errors.Error;

/**
	An error an RPC handler means its caller to see.

	Thrown from a handler method, its `message` becomes the caller's answer:
	the `RPCResponse` the call returned fails with it, word for word, and the
	connection carries on. Use it for what the caller can act on -- a player
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
		@param message What the caller is told.
		@param id A number for the error, kept on this side; only the message
		crosses the wire.
	**/
	public function new(message:String = "", id:Int = 0) {
		super(message, id);
		name = "RPCError";
	}
}
