package crossbyte.net;

/** Tagged union exposing the concrete transport wrapped by a `NetConnection`. */
enum Transport {
	/** TCP stream socket transport. */
	TCP(socket:Socket);
	/** Plain datagram socket transport. */
	UDP(socket:DatagramSocket);
	/** WebSocket transport. */
	WEBSOCKET(socket:WebSocket);
	/** Reliable datagram transport. */
	RUDP(socket:ReliableDatagramSocket);
	/** Local IPC transport. */
	LOCAL(connection:crossbyte.ipc.LocalConnection);
}
