package crossbyte.net;

/** Tagged union exposing the concrete transport wrapped by a `NetConnection`. */
enum Transport {
	/** TCP stream socket transport. */
	TCP(socket:Socket);
	// Only TCP survives in a browser, and there it is a WebSocket underneath.
	// The rest need a listening socket, UDP, or an OS IPC channel, and a page
	// has none of them.
	#if !(js && !nodejs)
	/** Plain datagram socket transport. */
	UDP(socket:DatagramSocket);
	/** WebSocket transport. */
	WEBSOCKET(socket:WebSocket);
	/** Reliable datagram transport. */
	RUDP(socket:ReliableDatagramSocket);
	/** Local IPC transport. */
	LOCAL(connection:crossbyte.ipc.LocalConnection);
	#end
}
