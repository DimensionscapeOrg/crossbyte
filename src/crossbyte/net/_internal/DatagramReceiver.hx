package crossbyte.net._internal;

import crossbyte.io.ByteArray;

/**
	Whoever a `DatagramSocket` hands each datagram to directly, ahead of its
	`DatagramSocketDataEvent.DATA` listeners: a reliable session's transport
	and a reliable server's socket, which are private and read every datagram.

	A call where there was an event made and dispatched for each one, to a
	single listener that took the datagram straight back out of it.
**/
interface DatagramReceiver {
	/**
		One datagram. `data` was made for it alone, and the receiver may keep
		it or change it: listeners see it afterwards, as the receiver left it.
	**/
	function __receiveDatagram(data:ByteArray, address:String, port:Int):Void;
}
