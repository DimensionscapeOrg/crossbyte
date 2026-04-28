package crossbyte.events;

/**
 * Dispatched by `NativeProcess` for stdout, stderr, and exit lifecycle updates.
 */
class NativeProcessEvent extends TextEvent {
	/** Fired when stdout data is available. */
	public static inline var STANDARD_OUTPUT_DATA:EventType<NativeProcessEvent> = "standardOutputData";
	/** Fired when stderr data is available. */
	public static inline var STANDARD_ERROR_DATA:EventType<NativeProcessEvent> = "standardErrorData";
	/** Fired when the stdout stream closes. */
	public static inline var STANDARD_OUTPUT_CLOSE:EventType<NativeProcessEvent> = "standardOutputClose";
	/** Fired when the stderr stream closes. */
	public static inline var STANDARD_ERROR_CLOSE:EventType<NativeProcessEvent> = "standardErrorClose";
	/** Fired after the process exits. */
	public static inline var EXIT:EventType<NativeProcessEvent> = "exit";

	/** Exit code reported by the child process. */
	public var exitCode:Int;
	/** Process identifier when known, otherwise `-1`. */
	public var pid:Int;

	/**
	 * Creates a native process event.
	 *
	 * @param type Event type such as `EXIT` or `STANDARD_OUTPUT_DATA`.
	 * @param text Captured stream text for stdout/stderr events.
	 * @param exitCode Process exit code for `EXIT`.
	 * @param pid Child process identifier when available.
	 */
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
