package crossbyte.events;

import crossbyte.Object;

/** Base event payload for CrossByte dispatchers and typed event subclasses. */
class Event {
	public static inline var TICK:String = "tick";
	public static inline var CLOSE:String = "close";

	/**
		The peer stopped sending, and the socket is staying open to write.

		Dispatched instead of `CLOSE` when a read ends in `Eof` under
		`PeerShutdownPolicy.HALF_OPEN`. `CLOSE` still follows later, when the
		socket is actually closed.
	**/
	public static inline var PEER_CLOSE:String = "peerClose";
	public static inline var CONNECT:String = "connect";
	public static inline var COMPLETE:String = "complete";
	public static inline var CANCEL:String = "cancel";
	public static inline var EXIT:String = "exit";
	public static inline var INIT:String = "init";

	public var currentTarget(default, null):Object;
	public var target(default, null):Object;
	public var type(default, null):String;

	public function new(type:String) {
		this.type = type;
	}

	public function clone():Event {
		var event = new Event(type);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	public function toString():String {
		return '$type';
	}
}
