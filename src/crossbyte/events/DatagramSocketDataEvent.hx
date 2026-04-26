package crossbyte.events;

import crossbyte.io.ByteArray;

/**
	A `DatagramSocket` or datagram-mode `ReliableDatagramSocket` dispatches a
	`DatagramSocketDataEvent` object when a complete payload is received.
	The event includes both the source and destination endpoint information along
	with the received payload bytes.
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
		The received payload bytes.
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
		Creates a copy of this event instance.
		@return A new `DatagramSocketDataEvent` with the same endpoint and payload data.
	**/
	override public function clone():Event {
		return new DatagramSocketDataEvent(type, srcAddress, srcPort, dstAddress, dstPort, data);
	}
}
