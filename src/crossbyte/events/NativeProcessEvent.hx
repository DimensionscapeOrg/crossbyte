package crossbyte.events;

class NativeProcessEvent extends TextEvent {
	public static inline var STANDARD_OUTPUT_DATA:EventType<NativeProcessEvent> = "standardOutputData";
	public static inline var STANDARD_ERROR_DATA:EventType<NativeProcessEvent> = "standardErrorData";
	public static inline var STANDARD_OUTPUT_CLOSE:EventType<NativeProcessEvent> = "standardOutputClose";
	public static inline var STANDARD_ERROR_CLOSE:EventType<NativeProcessEvent> = "standardErrorClose";
	public static inline var EXIT:EventType<NativeProcessEvent> = "exit";

	public var exitCode:Int;
	public var pid:Int;

	public function new(type:EventType<NativeProcessEvent>, text:String = "", exitCode:Int = 0, pid:Int = -1) {
		super(type, text);

		this.exitCode = exitCode;
		this.pid = pid;
	}

	public override function clone():NativeProcessEvent {
		var cloned = new NativeProcessEvent(type, text, exitCode, pid);
		cloned.target = target;
		cloned.currentTarget = currentTarget;

		return cloned;
	}
}
