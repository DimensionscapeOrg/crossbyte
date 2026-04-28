package crossbyte.events;

import crossbyte.events.Event;

/** Event carrying outbound write progress counters. */
class OutputProgressEvent extends Event {
	public static inline var OUTPUT_PROGRESS:EventType<OutputProgressEvent> = "outputProgress";

	public var bytesPending:Float;
	public var bytesTotal:Float;

	public function new(type:String, bytesPending:Float = 0, bytesTotal:Float = 0) {
		super(type);
		this.bytesPending = bytesPending;
		this.bytesTotal = bytesTotal;
	}

	override public function clone():Event {
		var event = new OutputProgressEvent(type, bytesPending, bytesTotal);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
