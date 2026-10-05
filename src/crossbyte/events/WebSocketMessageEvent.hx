package crossbyte.events;

import crossbyte.events._internal.Arrivals;
import crossbyte.io.ByteArray;

/**
	One whole WebSocket message, as its sender sent it.

	A `WebSocket` otherwise delivers what arrives as a stream, every message
	appended to the bytes `ProgressEvent.SOCKET_DATA` announces, which is the
	shape a `Socket` has, and loses where one message ends and the next
	begins. A session with a listener for this event delivers each message
	here instead, whole, with whether it was sent as text or as binary, and
	adds nothing to the stream.

	Valid only during the listener call, with its `data`: the session hands
	the same event and the same bytes out again for the next message. Copy
	what you need, `text` is a string of its own, safe to keep, or keep
	a `clone()`; see `Event`.
**/
class WebSocketMessageEvent extends Event {
	/** Dispatched for each message a WebSocket session receives. **/
	public static inline var MESSAGE:EventType<WebSocketMessageEvent> = "webSocketMessage";

	/**
		The message, from its start.

		Valid only during the listener call: the session fills the same
		`ByteArray` with its next message, and empties it, length and
		position 0, once the call returns. To keep the bytes, copy them
		out, as `data.readBytes(mine)` does, or keep a `clone()`. Sending
		them back from the listener is safe: every send copies what it is
		given before it returns.
	**/
	public var data(default, null):ByteArray;

	/** Whether the message was sent as text rather than as binary. **/
	public var isText(default, null):Bool;

	/**
		The message as text. Checked as UTF-8 on arrival when it was sent as
		text; a binary message is decoded as UTF-8 too, which is only
		meaningful when it holds some.

		Made when first asked for, and a string of its own: safe to keep
		after the listener call, as `data` is not.
	**/
	public var text(get, never):String;

	@:noCompletion private var __text:String;

	public function new(type:String, data:ByteArray, isText:Bool) {
		super(type);
		this.data = data;
		this.isText = isText;
	}

	@:noCompletion private function get_text():String {
		if (__text == null && data != null) {
			var at:Int = data.position;
			data.position = 0;
			__text = data.readUTFBytes(data.length);
			data.position = at;
		}
		return __text;
	}

	/**
		A copy of this event, its message copied too: safe to keep after the
		listener call, with bytes of its own.
	**/
	override public function clone():Event {
		var event = new WebSocketMessageEvent(type, Arrivals.copyOf(data), isText);
		event.__text = __text;
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	override public function toString():String {
		return '[WebSocketMessageEvent type=$type isText=$isText length=${data == null ? 0 : data.length}]';
	}

	/** Filled again for the next message; see `Arrivals`. **/
	@:noCompletion public function __refill(data:ByteArray, isText:Bool):Void {
		__retarget();
		this.data = data;
		this.isText = isText;
		__text = null;
	}

	/**
		Its call has returned and its message been emptied: the text made
		from the message goes too, so a reference kept past the call reads
		an empty message whichever it asks for.
	**/
	@:noCompletion public inline function __release():Void {
		__text = null;
	}

	@:noCompletion override private function __kill():Void {
		super.__kill();
		isText = false;
		__text = null;
	}
}
