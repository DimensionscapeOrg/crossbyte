package crossbyte.events;

import crossbyte.events.Event;

/**
 * ...
 * @author Christopher Speciale
 */
class ErrorEvent extends TextEvent {
	public static inline var ERROR:EventType<ErrorEvent> = "error";

	public var errorID(default, null):Int;

	public function new(type:String, text:String = "", id:Int = 0) {
		super(type, text);
		this.errorID = id;
	}

	override public function clone():Event {
		return new ErrorEvent(type, text, errorID);
	}
}
