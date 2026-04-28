package crossbyte.net;

/** Supported transport protocols understood by `NetConnection`, `NetHost`, and URI parsing. */
enum abstract Protocol(Int) from Int to Int {
	/** TCP stream socket. */
	var TCP:Int = 0;
	/** Plain datagram socket. Not used by `NetConnection`. */
	var UDP:Int = 1;
	/** WebSocket stream transport. */
	var WEBSOCKET:Int = 2;
	/** CrossByte reliable datagram transport. */
	var RUDP:Int = 3;
}
