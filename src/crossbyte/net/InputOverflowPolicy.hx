package crossbyte.net;

/**
	What a `Socket` does when what it holds unread reaches
	`maxInputBufferSize`.
**/
enum abstract InputOverflowPolicy(Int) from Int to Int {
	/**
		Stop reading from the connection until the application has read
		below the limit, then go on: backpressure, the default.

		What arrives meanwhile waits in the system's receive buffer (see
		`Socket.receiveBufferSize`), and once that is full TCP's window
		closes and the peer stops sending: TCP's own flow control, as a
		reader that reads only what it wants has with any socket library
		that is read rather than read for. Nothing is lost: everything sent
		arrives, in order, as the application makes room for it.

		The cost is the application's to bear: one that waits for more bytes
		than the limit before it reads any (a whole message larger than the
		limit) waits for good, since nothing more is read until it reads.
		Set the limit above the largest message the application waits for
		whole. A peer that closes, or fails, meanwhile is seen once reading
		goes on.
	**/
	var PAUSE:Int = 0;

	/**
		Dispatch `IOErrorEvent.IO_ERROR` and close the connection as soon as
		a byte arrives past the limit, as `OutputOverflowPolicy.CLOSE` does
		for a peer that is not reading: for an application that reads what
		it is sent as it arrives, where a peer sending faster than that is
		misbehaving rather than waiting its turn.
	**/
	var CLOSE:Int = 1;
}
