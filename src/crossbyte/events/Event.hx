package crossbyte.events;

import crossbyte.Object;

/** Base event payload for CrossByte dispatchers and typed event subclasses. */
class Event {
	public static inline var TICK:EventType<Event> = "tick";
	public static inline var CLOSE:EventType<Event> = "close";

	/**
		The peer stopped sending, and the socket is staying open to write.

		Dispatched instead of `CLOSE` when a read ends in `Eof` under
		`PeerShutdownPolicy.HALF_OPEN`. `CLOSE` still follows later, when the
		socket is actually closed.
	**/
	public static inline var PEER_CLOSE:EventType<Event> = "peerClose";
	public static inline var CONNECT:EventType<Event> = "connect";
	public static inline var COMPLETE:EventType<Event> = "complete";
	public static inline var CANCEL:EventType<Event> = "cancel";
	public static inline var EXIT:EventType<Event> = "exit";
	public static inline var INIT:EventType<Event> = "init";

	/**
		The dispatcher the event is passing through now; see `target`.
	**/
	public var currentTarget(default, null):Object;

	/**
		The dispatcher the event was dispatched on: always an
		`IEventDispatcher`, typed `Object` as ActionScript types it.

		Assign it to the type it is for typed access,
		`var socket:Socket = event.target;`: which costs at most a type check
		of a few nanoseconds, natively, and nothing elsewhere: the object is
		the same one, and the assignment tells the compiler what it is. Reading
		fields through `Object` instead looks each one up by its name.
	**/
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
