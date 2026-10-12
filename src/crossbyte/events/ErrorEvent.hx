package crossbyte.events;

import crossbyte.events.Event;

/** Event carrying an error text payload through the event system. */
class ErrorEvent extends TextEvent {
	public static inline var ERROR:EventType<ErrorEvent> = "error";

	public var errorId(default, null):Int;

	public function new(type:String, text:String = "", id:Int = 0) {
		super(type, text);
		this.errorId = id;
	}

	override public function clone():Event {
		var event = new ErrorEvent(type, text, errorId);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	@:noCompletion override private function __kill():Void {
		super.__kill();
		errorId = -1;
	}
}
