package crossbyte._internal.socket;


interface IPollableSocket {
	public var registryClosed(get, never):Bool;
	public function registryOnReadable():Void;
	public function registryOnWritable():Void;

	/**
		Whether this socket holds readable bytes the kernel no longer has.

		Always false for a plain socket, where the kernel is the only place
		bytes can be. A TLS socket is the exception: it reads whole records off
		the channel, so the tail of a handshake and the first application record
		routinely arrive in one read, and the request then waits in the TLS
		layer while `select` reports an idle connection.

		The registry asks before selecting, because asking afterwards would
		spend the whole poll timeout waiting for data already in hand.
	**/
	public function registryHasBufferedInput():Bool;
}
