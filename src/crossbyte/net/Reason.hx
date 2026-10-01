package crossbyte.net;

/** Describes why a connection or host lifecycle callback fired. */
enum Reason {
	/**
		A deadline passed: a connect not made within its socket's `timeout`
		(an `ioError` whose `errorID` is `IOErrorEvent.TIMEOUT_ERROR_ID`), or
		a connection its owner closed for silence.
	**/
	Timeout;
	/** The transport closed cleanly. */
	Closed;
	/** The transport closed with a protocol-specific code and optional message. */
	Code(code:Int, ?message:String);
	/** The transport reported an error message. */
	Error(msg:String);
}
