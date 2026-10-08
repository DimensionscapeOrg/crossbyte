package crossbyte.rpc;

/**
	What a call fails with when it is not answered in time: the `cause` of
	an `RPCResponse` whose deadline passed, on the side that made the call,
	and of the answer a handler that took too long sends on the side that
	answers it.

	Its own type, so a caller can tell a call that timed out from one that
	was refused without matching on the words:

	```haxe
	response.catchError(message -> {
		if (Std.isOfType(response.cause, RPCTimeoutError)) {
			// try again, or elsewhere
		}
	});
	```

	It is an `RPCError`, so a handler answering its own caller with the
	response that timed out (forwarding it) tells that caller the call
	timed out, word for word, where anything else it failed with would reach
	the caller as `RPCError.INTERNAL_MESSAGE`. And it is reported to
	`RPCSession.onHandlerError` as well, since a handler whose answers do not
	come is news on the side it runs.

	Only the message crosses the wire: the caller of a handler that timed
	out is failed with an `RPCError` carrying `RPCError.TIMEOUT_MESSAGE`.
**/
class RPCTimeoutError extends RPCError {
	/**
		@param message What the caller is told.
	**/
	public function new(message:String = RPCError.TIMEOUT_MESSAGE) {
		super(message);
		name = "RPCTimeoutError";
	}
}
