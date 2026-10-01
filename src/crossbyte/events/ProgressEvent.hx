package crossbyte.events;

import crossbyte.events.Event;

/** Event carrying `bytesLoaded` and `bytesTotal` progress counters. */
class ProgressEvent extends Event {
	public static inline var PROGRESS:String = "progress";

	/**
		A socket has data to read. On a `Socket`, on every target,
		`bytesLoaded` is how many bytes arrived for this event; the socket's
		`bytesAvailable` is how many are unread in all, these and any left
		from before. `bytesTotal` is 0.
	**/
	public static inline var SOCKET_DATA:String = "socketData";

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
}
