package crossbyte.events;

import crossbyte.net.ReliableDatagramSocket;

/**
	A `ReliableDatagramServerSocket` dispatches a `ReliableDatagramSocketConnectEvent`
	when a reliable session has completed its handshake and is ready for use.
	The `socket` property provides the accepted peer session.
**/
class ReliableDatagramSocketConnectEvent extends Event {
	/**
		Dispatched when an accepted reliable datagram session becomes connected.
	**/
	public static inline var CONNECT:EventType<ReliableDatagramSocketConnectEvent> = "connect";

	/**
		The accepted reliable datagram session.
	**/
	public var socket(default, null):ReliableDatagramSocket;

	/**
		Creates a new `ReliableDatagramSocketConnectEvent`.
		@param type The event type. Must be `ReliableDatagramSocketConnectEvent.CONNECT`.
		@param socket The accepted reliable session.
	**/
	public function new(type:String, socket:ReliableDatagramSocket) {
		super(type);
		this.socket = socket;
	}

	/**
		Creates a copy of this event instance.
		@return A new `ReliableDatagramSocketConnectEvent` with the same accepted socket.
	**/
	override public function clone():Event {
		return new ReliableDatagramSocketConnectEvent(type, socket);
	}
}
