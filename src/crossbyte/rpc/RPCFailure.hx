package crossbyte.rpc;

import crossbyte.net.Reason;

/**
	Why a call made with a receiver (see `RPCReceiver`) was not answered
	with a value. Told to `RPCReceiver.onFailure`.

	The reasons with nothing to say beyond themselves are single values, so
	telling a receiver of one allocates nothing.
**/
enum RPCFailure {
	/** No answer came within the session's `RPCSession.callTimeout`. **/
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
		The other side answered with an error: the `RPCError` its handler
		threw, or one of `RPCError`'s messages (no such method, too many
		calls waiting, its handler timed out).
	**/
	Refused(message:String);

	/**
		The call could not be sent: it was over the session's
		`RPCSession.maxFrameLength`, the connection's `send` threw, or the
		commands are bound to no session.
	**/
	Unsent(message:String);

	/** The answer arrived but could not be read as this call's. **/
	Unreadable(message:String);
}
