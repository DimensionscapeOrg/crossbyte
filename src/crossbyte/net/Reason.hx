package crossbyte.net;

/** Describes why a connection or host lifecycle callback fired. */
enum Reason {
	/**
		A deadline passed: a connect not made within its socket's
		`connectTimeout` (an `ioError` whose `errorId` is
		`IOErrorEvent.TIMEOUT_ERROR_ID`), or a connection its owner closed
		for silence.
	**/
	Timeout;
	/** The transport closed cleanly. */
	Closed;
	/** The transport closed with a protocol-specific code and optional message. */
	Code(code:Int, ?message:String);
	/** The transport reported an error message. */
	Error(msg:String);
	/**
		This side's output passed its limit: what waited unsent for a peer
		that was not reading (a socket's or a WebSocket's
		`maxOutputBufferSize`, a reliable UDP session's queue for its window,
		a local connection's `maxQueuedBytes`), and the connection was closed
		for it. The transport's own `ioError` says how many bytes were
		waiting; `NetConnection.outputHighWater` is the way to hear of a
		backlog before it gets here.
	**/
	Overflow;
}
