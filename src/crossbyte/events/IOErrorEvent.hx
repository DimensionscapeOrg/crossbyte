package crossbyte.events;

import crossbyte.events.Event;

/** Event dispatched when an asynchronous I/O operation fails. */
class IOErrorEvent extends ErrorEvent {
	public static inline var IO_ERROR:String = "ioError";

	/**
		The `errorID` of an `ioError` that reports a deadline passing rather
		than a refusal or a failure -- a `Socket` connect not made within its
		`timeout`, the name's lookup and the TLS handshake counted with it --
		so a listener can tell the two apart without reading `text`.
		`NetConnection` reports one as `Reason.Timeout`. A socket's other
		`ioError`s carry 0.
	**/
	public static inline var TIMEOUT_ERROR_ID:Int = 1;

	public function new(type:EventType<IOErrorEvent>, text:String = "", id:Int = 0) {
		super(type, text, id);
	}

	override public function clone():Event {
		var event = new IOErrorEvent(type, text, errorID);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
