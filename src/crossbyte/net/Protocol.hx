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
	/** Local named-pipe / Unix-domain transport. */
	var LOCAL:Int = 4;

	/**
		The protocol's name. Call it where one is written into text: joined to
		a string, an abstract over `Int` is its number, and a refusal read "A 0
		host cannot dial".
	**/
	public function toString():String {
		return switch (abstract) {
			case TCP: "TCP";
			case UDP: "UDP";
			case WEBSOCKET: "WebSocket";
			case RUDP: "reliable datagram";
			case LOCAL: "local";
			default: "protocol " + this;
		}
	}
}
