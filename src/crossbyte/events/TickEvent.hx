package crossbyte.events;

import crossbyte.events.Event;

/** Event dispatched once per runtime tick with the elapsed delta time. */
class TickEvent extends Event {
	public static inline var TICK:String = "tick";

	public var delta:Float;

	public function new(type:String, delta:Float) {
		super(type);

		this.delta = delta;
	}

	override public function clone():Event {
		var event = new TickEvent(type, delta);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
