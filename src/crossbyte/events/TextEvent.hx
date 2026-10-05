package crossbyte.events;

import crossbyte.events.Event;

/** Event carrying a single text payload. */
class TextEvent extends Event {
	public var text(default, null):String;

	public function new(type:String, text:String = "") {
		super(type);
		this.text = text;
	}

	override public function clone():Event {
		var event = new TextEvent(type, text);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	@:noCompletion override private function __kill():Void {
		super.__kill();
		text = null;
	}
}
