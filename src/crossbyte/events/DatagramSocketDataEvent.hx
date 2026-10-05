package crossbyte.events;

import crossbyte.events._internal.Arrivals;
import crossbyte.io.ByteArray;

/**
	A `DatagramSocket` or datagram-mode `ReliableDatagramSocket` dispatches a
	`DatagramSocketDataEvent` object when a complete payload is received.
	The event includes both the source and destination endpoint information along
	with the received payload bytes.

	Valid only during the listener call, with its `data`: the socket hands
	the same event and the same bytes out again for the next datagram. Copy
	the fields and the bytes you need, or keep a `clone()`; see `Event`.
**/
class DatagramSocketDataEvent extends Event {
	/**
		Dispatched when a datagram payload has been received.
	**/
	public static inline var DATA:EventType<DatagramSocketDataEvent> = "data";

	/**
		The IP address of the remote sender.
	**/
	public var srcAddress(default, null):String;

	/**
		The remote UDP port that sent the payload.
	**/
	public var srcPort(default, null):Int;

	/**
		The local IP address that received the payload.
	**/
	public var dstAddress(default, null):String;

	/**
		The local UDP port that received the payload.
	**/
	public var dstPort(default, null):Int;

	/**
		The received payload bytes, from position 0 to `length`.

		Valid only during the listener call: the socket fills the same
		`ByteArray` with the next datagram, and empties it, length and
		position 0, once the call returns. To keep the bytes, copy them
		out, as `data.readBytes(mine)` does, or keep a `clone()`. Sending
		them back from the listener is safe: every send copies what it is
		given before it returns.
	**/
	public var data(default, null):ByteArray;

	/**
		Creates a `DatagramSocketDataEvent` containing endpoint and payload data.
		@param type The event type. Must be `DatagramSocketDataEvent.DATA`.
		@param srcAddress The IP address of the remote sender.
		@param srcPort The UDP port of the remote sender.
		@param dstAddress The local IP address that received the payload.
		@param dstPort The local UDP port that received the payload.
		@param data The received payload bytes.
	**/
	public function new(type:String, srcAddress:String, srcPort:Int, dstAddress:String, dstPort:Int, data:ByteArray) {
		super(type);
		this.srcAddress = srcAddress;
		this.srcPort = srcPort;
		this.dstAddress = dstAddress;
		this.dstPort = dstPort;
		this.data = data;
	}

	/**
		Creates a copy of this event, its payload copied too: the copy is
		safe to keep after the listener call, with bytes of its own, at the
		same position and in the same byte order.
		@return A new `DatagramSocketDataEvent` with the same endpoints and
		        a copy of the payload.
	**/
	override public function clone():Event {
		var event = new DatagramSocketDataEvent(type, srcAddress, srcPort, dstAddress, dstPort, Arrivals.copyOf(data));
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	/** Filled again for the next arrival; see `Arrivals`. **/
	@:noCompletion public function __refill(srcAddress:String, srcPort:Int, dstAddress:String, dstPort:Int, data:ByteArray):Void {
		__retarget();
		this.srcAddress = srcAddress;
		this.srcPort = srcPort;
		this.dstAddress = dstAddress;
		this.dstPort = dstPort;
		this.data = data;
	}

	@:noCompletion override private function __kill():Void {
		super.__kill();
		srcAddress = null;
		srcPort = -1;
		dstAddress = null;
		dstPort = -1;
	}
}
