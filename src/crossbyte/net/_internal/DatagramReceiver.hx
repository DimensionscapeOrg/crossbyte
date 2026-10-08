package crossbyte.net._internal;

import crossbyte.io.ByteArray;

/**
	Whoever a `DatagramSocket` hands each datagram to directly, ahead of its
	`DatagramSocketDataEvent.DATA` listeners: a reliable session's transport
	and a reliable server's socket, which are private and read every datagram.

	A call rather than an event made and dispatched for each one, to a
	single listener that would take the datagram straight back out of it.
**/
interface DatagramReceiver {
	/**
		One datagram. `data` is valid only during the call, as an event's
		payload is: the socket fills the same `ByteArray` with the next
		datagram. The receiver may change it in place (listeners see it
		afterwards as the receiver left it) and copies whatever it keeps
		past the call: a frame held past a gap, a fragment, a CONNECT's
		payload. Under `-D crossbyte_check_events` it is killed once the
		call returns, so one kept by reference reads dead.
	**/
	function __receiveDatagram(data:ByteArray, address:String, port:Int):Void;
}
