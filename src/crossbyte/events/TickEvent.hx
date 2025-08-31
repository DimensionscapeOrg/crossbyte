package crossbyte.events;

import crossbyte.events.Event;

/**
 * ...
 * @author Christopher Speciale
 */
class TickEvent extends Event {
	public static inline var TICK:String = "tick";

	public var delta:Float;

	public function new(type:String, delta:Float) {
		super(type);

		this.delta = delta;
	}

	override public function clone():Event {
		var event:TickEvent = cast super.clone();
		event.delta = delta;

		return event;
	}
}
