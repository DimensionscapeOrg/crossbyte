package crossbyte.events;

/** Generic event carrying a status code and level string. */
class StatusEvent extends Event {
	/** Default event type for simple status notifications. */
	public static inline var STATUS:EventType<StatusEvent> = "status";

	/** Status code or short identifier. */
	public var code:String;
	/** Status level such as `info`, `warning`, or `error`. */
	public var level:String;

	/** Creates a status event with optional code and level payload. */
	public function new(type:String, code:String = "", level:String = "") {
		super(type);
		this.code = code;
		this.level = level;
	}

	public override function clone():StatusEvent {
		var event:StatusEvent = new StatusEvent(type, code, level);
		event.target = target;
		event.currentTarget = currentTarget;

		return event;
	}

	public override function toString():String {
		return '[StatusEvent type=$type code=$code level=$level]';
	}
}
