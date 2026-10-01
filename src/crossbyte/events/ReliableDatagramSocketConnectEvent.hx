package crossbyte.events;

// Not built for the browser: it carries a ReliableDatagramSocket, which is not built there either.
#if !(js && !nodejs)

import crossbyte.net.ReliableDatagramSocket;

/**
	A `ReliableDatagramServerSocket` dispatches a `ReliableDatagramSocketConnectEvent`
	when a reliable session a peer opened has completed its handshake and is
	ready for use. The `socket` property provides the accepted peer session.

	A session the server dials itself, with `connect` or `connectRelayed`, is
	not announced this way: the caller holds it from the call, and it
	dispatches `Event.CONNECT` when its handshake completes.
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
		var event = new ReliableDatagramSocketConnectEvent(type, socket);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
#end
