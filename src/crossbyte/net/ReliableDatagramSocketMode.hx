package crossbyte.net;

/**
	Describes how a `ReliableDatagramSocket` exposes received and outgoing payloads.
	Use `DATAGRAM` to preserve message boundaries or `STREAM` to buffer ordered payload
	data behind the `IDataInput` and `IDataOutput` APIs.
**/
enum abstract ReliableDatagramSocketMode(Int) from Int to Int {
	/**
		Preserves reliable payload boundaries and dispatches `DatagramSocketDataEvent.DATA`
		for each delivered payload.
	**/
	public var DATAGRAM = 0;

	/**
		Buffers reliable payloads into a continuous ordered byte stream and dispatches
		`ProgressEvent.SOCKET_DATA` when additional bytes become available.
	**/
	public var STREAM = 1;
}
