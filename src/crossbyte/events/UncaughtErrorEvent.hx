package crossbyte.events;

/**
	Dispatched on a `CrossByte` runtime when a callback it ran threw and
	nothing caught it: a timer, a tick or lifecycle listener, a socket's
	handler, a callback posted to the runtime, or the loop itself.

	The runtime contains each one where it was thrown, so one handler's bug
	costs that handler rather than the process. The loop carries on, the other
	timers and connections are served, a recurring timer stays armed, and a
	stream socket whose handler threw is closed, since what it had half read
	can no longer be trusted. Every one is logged at `ERROR` under the
	`runtime` category whether or not anything listens for this; an
	application that reports failures itself can quiet the log with
	`Logger.setLevel("runtime", LogLevel.OFF)`.

	Listen for it to report failures somewhere the log does not reach, or to
	decide that one is fatal and call `exit()`:

	```haxe
	runtime.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, (event:UncaughtErrorEvent) -> {
		reportToCollector(event.source, event.error);
	});
	```

	A listener for this that throws is logged and not dispatched again.
**/
class UncaughtErrorEvent extends Event {
	public static inline var UNCAUGHT_ERROR:EventType<UncaughtErrorEvent> = "uncaughtError";

	/** Where the runtime caught it. **/
	public static inline var TIMER:String = "timer";

	/** A `TickEvent.TICK` listener. **/
	public static inline var TICK:String = "tick";

	/** An `Event.INIT` or `Event.EXIT` listener. **/
	public static inline var LIFECYCLE:String = "lifecycle";

	/** A socket's handler, run because the socket was ready. **/
	public static inline var SOCKET:String = "socket";

	/** A callback handed to the runtime with `post`. **/
	public static inline var POSTED:String = "posted";

	/** The loop, outside any one callback: a flush, a poll, a custom loop body. **/
	public static inline var LOOP:String = "loop";

	/** What was thrown. **/
	public var error(default, null):Dynamic;

	/** Where it was caught: one of the constants above. **/
	public var source(default, null):String;

	/**
		What the failing callback belonged to, where that is known: the socket
		whose handler threw, the task whose listener did. Null otherwise.

		Typed `Any`: what it is varies with the source, so it is read through
		a test and a cast to the type expected,
		`if (Std.isOfType(event.origin, Socket)) (cast event.origin : Socket).close()`.
		It was `Dynamic`, which let a field be read from it unchecked.
	**/
	public var origin(default, null):Any;

	public function new(type:String, error:Dynamic, source:String, origin:Any = null) {
		super(type);

		this.error = error;
		this.source = source;
		this.origin = origin;
	}

	override public function clone():Event {
		var event = new UncaughtErrorEvent(type, error, source, origin);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
