package crossbyte.net;

/** Describes why a connection or host lifecycle callback fired. */
enum Reason {
	/** The connection exceeded its heartbeat or idle timeout. */
	Timeout;
	/** The transport closed cleanly. */
	Closed;
	/** The transport closed with a protocol-specific code and optional message. */
	Code(code:Int, ?message:String);
	/** The transport reported an error message. */
	Error(msg:String);
}
