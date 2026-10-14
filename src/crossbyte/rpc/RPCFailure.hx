package crossbyte.rpc;

import crossbyte.net.Reason;

/**
	Why a call was not answered with a value: told to `RPCReceiver.onFailure`
	for a call made with a receiver, and read from `RPCResponse.failure` for
	one made with a future.

	The refusals the other side's session makes itself (no such method,
	arguments it could not read, too many calls waiting, nothing to answer
	calls, its handler failing or out of time) each have a case of their
	own, so a caller switches on them rather than comparing messages.
	`Refused` is what its handler meant the caller to see.

	The reasons with nothing to say beyond themselves are single values, so
	telling a receiver of one allocates nothing.
**/
enum RPCFailure {
	/**
		No answer came by the call's deadline: the session's
		`RPCSession.requestTimeout`, or one of its own from `RPCCommands.within`
		or `RPCResponse.within`.
	**/
	TimedOut;

	/** The call was cancelled with `RPCSession.cancelCall`. **/
	Cancelled;

	/** The session was stopped with `RPCSession.stop` while the call waited. **/
	Stopped;

	/**
		The connection ended while the call waited, or had ended when it was
		made, for `reason`. A heartbeat that gave up on the peer is
		`Disconnected(Timeout)`.
	**/
	Disconnected(reason:Reason);

	/**
		The other side's handler refused the call with an `RPCError`, whose
		message this is, word for word: one it threw, one its `beforeCall`
		returned, or one its future failed with.

		`code` is that error's id (`new RPCError(message, id)`, its
		`errorId`), for the caller to switch on rather than the words:
		`null` when the error had none (an id of 0), and from a peer of 1.0,
		which sends none. A pattern that leaves it out, `Refused(message)`,
		matches either.

		```haxe
		// Given failure:RPCFailure.
		switch (failure) {
			case Refused(_, 3): trace("no such player");
			case Refused(message, _): trace('refused: $message');
			case _:
		}
		```
	**/
	Refused(message:String, ?code:Int);

	/**
		The other side has no method for the call: none of its name, or none
		with its signature (a peer built from another version of the
		contract), or, on the runtime lane, no handler registered for its
		number. Its message is `RPCError.UNKNOWN_METHOD_MESSAGE`.
	**/
	UnknownMethod;

	/**
		The other side could not read the call's arguments: they ran past the
		end of their frame, named more than it holds, or carried a value of a
		kind it does not know. Its message is `RPCError.UNREADABLE_MESSAGE`.
	**/
	UnreadableArguments;

	/**
		The other side refused the call before its method ran, and it is worth
		trying again later: it had `RPCSession.maxCallsWaiting` calls waiting
		already (its message `RPCError.BUSY_MESSAGE`), or the call was over its
		method's rate limit, `@:rpcLimit` (`RPCError.RATE_LIMITED_MESSAGE`).
		A handler's `beforeCall` refusing with `RPCError.refusal(Busy)` is
		told so too.
	**/
	Busy;

	/**
		Nothing answers calls on the other side's session: it has commands
		only, or only runtime handlers. Its message is
		`RPCError.NO_HANDLER_MESSAGE`.
	**/
	NoHandler;

	/**
		The other side's handler answered later and did not within its
		session's `RPCSession.answerTimeout`, or failed with an
		`RPCTimeoutError` (a call it was waiting on timed out). Its message is
		`RPCError.TIMEOUT_MESSAGE`.
	**/
	HandlerTimedOut;

	/**
		The other side's handler failed with something other than an
		`RPCError` (a bug, a database error), which stays on its side, told to
		its `RPCSession.onHandlerError`. Its message is
		`RPCError.INTERNAL_MESSAGE`.
	**/
	HandlerFailed;

	/**
		The call, or its answer, was larger than the side reading it takes:
		over that side's `RPCSession.maxFrameSize`, or more than its
		connection holds to read it whole (a TCP socket's
		`maxInputBufferSize`), or, for an answer, more than the answering
		side's connection carries; or a call whose arguments were over its
		method's `@:rpcLimit(bytes = ...)`, refused before they were read. The
		connection carries on. Its message says which limit, or is
		`RPCError.TOO_LARGE_MESSAGE` for a method's.
	**/
	TooLarge;

	/**
		The call could not be sent: it was over the session's
		`RPCSession.maxFrameSize`, the connection's `send` threw, or the
		commands are bound to no session.
	**/
	Unsent(message:String);

	/** The answer arrived but could not be read as this call's. **/
	Unreadable(message:String);
}
