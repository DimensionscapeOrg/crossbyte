package crossbyte._internal.net;

/**
	Something that sends through a `DatagramSocket`'s batch for the pass, and
	is told when a datagram of its could not go: the batch goes when the pass
	ends, after the send that queued it has returned. See
	`DatagramSocket.__sendInPass`.
**/
interface DatagramSender {
	function __datagramFailed(error:String):Void;
}
