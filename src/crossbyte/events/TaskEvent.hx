package crossbyte.events;

import crossbyte.sys.Task;

/**
 * ...
 */
class TaskEvent<T> extends Event {
	public static inline var COMPLETE:String = "complete";
	public static inline var ERROR:String = "error";
	public static inline var CANCEL:String = "cancel";

	public var task:Task<T>;
	public var result:Null<T>;
	public var error:Dynamic;

	public function new(type:String, task:Task<T>, result:Null<T> = null, error:Dynamic = null) {
		super(type);

		this.task = task;
		this.result = result;
		this.error = error;
	}

	override public function clone():Event {
		var event = new TaskEvent(type, task, result, error);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
