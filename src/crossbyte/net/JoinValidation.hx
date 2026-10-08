package crossbyte.net;

/**
	When a `ReliableDatagramServerSocket` makes a peer show that it receives
	at the address its CONNECT came from before opening a session for it;
	see `ReliableDatagramServerSocket.joinValidation`.

	A session is opened, and held for its handshake, on the strength of a
	source address that UDP lets a sender write for itself. A validated
	join is answered first with a cookie (the server's keyed hash of the
	address, the port, the CONNECT's connection id and the time, which it
	keeps nothing for), and only a CONNECT that returns it opens a
	session. A peer on 1.0 or later does that by itself; it costs one more
	round trip.
**/
enum abstract JoinValidation(Int) from Int to Int {
	/**
		Once the sessions waiting to finish their handshakes reach
		`ReliableDatagramServerSocket.joinValidationThreshold`, as a TCP
		stack sends SYN cookies once its backlog fills: an ordinary join
		costs nothing extra, and during a flood of CONNECTs from forged
		addresses a real one costs a round trip more. The default.
	**/
	var UNDER_PRESSURE = 0;

	/** Every join, whatever is pending: each costs one more round trip. **/
	var ALWAYS = 1;

	/**
		No join: every CONNECT is taken at its word, up to
		`maxPendingConnections`, so CONNECTs from forged addresses can take
		every slot.
	**/
	var NEVER = 2;
}
