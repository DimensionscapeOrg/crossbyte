package crossbyte.events;

import crossbyte.Object;

/**
 * ...
 * @author Christopher Speciale
 */
class Event {
	public static inline var TICK:String = "tick";
	public static inline var CLOSE:String = "close";
	public static inline var CONNECT:String = "connect";
	public static inline var COMPLETE:String = "complete";
	public static inline var CANCEL:String = "cancel";
	public static inline var EXIT:String = "exit";
	public static inline var INIT:String = "init";

	public var currentTarget(default, null):Object;
	public var target(default, null):Object;
	public var type(default, null):String;

	public function new(type:String) {
		this.type = type;
	}

	public function clone():Event {
		var event = new Event(type);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	public function toString():String {
		return '$type';
	}
}
