package crossbyte.events;

import crossbyte.events.Event;

/** Event dispatched when an asynchronous I/O operation fails. */
class IOErrorEvent extends ErrorEvent {
	public static inline var IO_ERROR:String = "ioError";

	public function new(type:EventType<IOErrorEvent>, text:String = "", id:Int = 0) {
		super(type, text, id);
	}

	override public function clone():Event {
		var event = new IOErrorEvent(type, text, errorID);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
