package crossbyte.events;

import crossbyte.events.Event;

/**
	Event carrying `bytesLoaded` and `bytesTotal` progress counters.

	A socket's `SOCKET_DATA` event is valid only during the listener call:
	a `Socket`, a `WebSocket` or a stream-mode `ReliableDatagramSocket`
	hands the same one out again for what arrives next. Read the counters
	there, or keep a `clone()`; see `Event`.
**/
class ProgressEvent extends Event {
	public static inline var PROGRESS:EventType<ProgressEvent> = "progress";

	/**
		A socket has data to read. On a `Socket`, on every target,
		`bytesLoaded` is how many bytes arrived for this event; the socket's
		`bytesAvailable` is how many are unread in all, these and any left
		from before. `bytesTotal` is 0.

		The bytes themselves are the socket's, read through it, and stay
		there until they are read; the event only says they came, and is
		handed out again for the next arrival.
	**/
	public static inline var SOCKET_DATA:EventType<ProgressEvent> = "socketData";

	/** The whole, where it is known; 0 for `SOCKET_DATA`. **/
	public var bytesTotal:UInt = 0;

	/** How much has loaded; for `SOCKET_DATA`, the bytes that arrived for this event. **/
	public var bytesLoaded:UInt = 0;

	public function new(type:String, bytesLoaded:UInt = 0, bytesTotal:UInt = 0) {
		super(type);

		this.bytesLoaded = bytesLoaded;
		this.bytesTotal = bytesTotal;
	}

	public override function clone():ProgressEvent {
		var event = new ProgressEvent(type, bytesLoaded, bytesTotal);
		event.target = target;
		event.currentTarget = currentTarget;

		return event;
	}

	/** Filled again for the next arrival; see `Arrivals`. **/
	@:noCompletion public function __refill(bytesLoaded:UInt, bytesTotal:UInt):Void {
		__retarget();
		this.bytesLoaded = bytesLoaded;
		this.bytesTotal = bytesTotal;
	}

	@:noCompletion override private function __kill():Void {
		super.__kill();
		bytesLoaded = -1;
		bytesTotal = -1;
	}
}
