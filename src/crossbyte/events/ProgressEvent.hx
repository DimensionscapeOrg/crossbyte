package crossbyte.events;

import crossbyte.events.Event;

/**
 * ...
 * @author Christopher Speciale
 */
class ProgressEvent extends Event {
	public static inline var PROGRESS:String = "progress";
	public static inline var SOCKET_DATA:String = "socketData";

	public var bytesTotal:UInt = 0;
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
