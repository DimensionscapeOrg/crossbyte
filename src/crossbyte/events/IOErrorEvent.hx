package crossbyte.events;

import crossbyte.events.Event;

/**
 * ...
 * @author Christopher Speciale
 */
class IOErrorEvent extends ErrorEvent {
	public static inline var IO_ERROR:String = "ioError";

	public function new(type:EventType<IOErrorEvent>, text:String = "", id:Int = 0) {
		super(type, text, id);
	}
}
