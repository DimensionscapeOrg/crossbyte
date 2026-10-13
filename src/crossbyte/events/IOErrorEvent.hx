package crossbyte.events;

import crossbyte.events.Event;

/**
	Event dispatched when an asynchronous I/O operation fails.

	Valid only during the listener call: a `Socket` hands the same one out
	again for its next error, as it does its `connect`, `close` and
	`socketData` events. Read `text` and `errorId` there, or keep a
	`clone()`; see `Event`.
**/
class IOErrorEvent extends ErrorEvent {
	public static inline var IO_ERROR:EventType<IOErrorEvent> = "ioError";

	/**
		The `errorId` of an `ioError` that reports a deadline passing rather
		than a refusal or a failure (a `Socket` connect not made within its
		`connectTimeout`, the name's lookup and the TLS handshake counted with
		it),
		so a listener can tell the two apart without reading `text`.
		`NetConnection` reports one as `Reason.Timeout`. A socket's other
		`ioError`s carry 0, but for `OVERFLOW_ERROR_ID`.
	**/
	public static inline var TIMEOUT_ERROR_ID:Int = 1;

	/**
		The `errorId` of an `ioError` that reports this side's output passing
		its limit: a `Socket`'s or a `WebSocket`'s `maxOutputBufferSize`, or a
		`ReliableDatagramSocket`'s, with a peer that is not reading or a path
		that cannot carry it, under the `CLOSE` policy. The connection closes
		after it. `NetConnection` reports one as `Reason.Overflow`.
	**/
	public static inline var OVERFLOW_ERROR_ID:Int = 2;

	public function new(type:EventType<IOErrorEvent>, text:String = "", id:Int = 0) {
		super(type, text, id);
	}

	override public function clone():Event {
		var event = new IOErrorEvent(type, text, errorId);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
