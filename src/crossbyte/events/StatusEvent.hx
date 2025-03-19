package crossbyte.events;

class StatusEvent extends Event
{
	
	public static inline var STATUS:EventType<StatusEvent> = "status";
	
	public var code:String;
	public var level:String;
	
	public function new(type:String, code:String = "", level:String = "")
	{
		super(type);
		this.code = code;
		this.level = level;
	}
	
	public override function clone():StatusEvent
	{
		var event:StatusEvent = new StatusEvent(type, code, level);
		event.target = target;
		event.currentTarget = currentTarget;
		
		return event;
	}

	public override function toString():String
	{
		return "" //__formatToString("StatusEvent", ["type", "code", "level"]);
	}
}
