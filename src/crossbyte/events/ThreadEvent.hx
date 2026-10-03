package crossbyte.events;

/** Event used by worker and task primitives to deliver thread-side messages. */
class ThreadEvent extends Event {
	public static inline var COMPLETE:EventType<ThreadEvent> = "complete";
	public static inline var PROGRESS:EventType<ThreadEvent> = "progress";
	public static inline var ERROR:EventType<ThreadEvent> = "error";

	public var message:Dynamic;

	public function new(type:String, message:Dynamic = null) {
		super(type);

		this.message = message;
	}

	override public function clone():Event {
		var event = new ThreadEvent(type, message);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
