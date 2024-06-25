package crossbyte.events;

import crossbyte.events.Event;

/**
 * ...
 * @author Christopher Speciale
 */
class TextEvent extends Event {
	public var text(default, null):String;

	public function new(type:String, text:String = "") {
		super(type);
		this.text = text;
	}

	override public function clone():Event {
		return new TextEvent(type, text);
	}
}
