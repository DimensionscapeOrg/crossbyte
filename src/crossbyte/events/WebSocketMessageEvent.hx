package crossbyte.events;

import crossbyte.io.ByteArray;

/**
	One whole WebSocket message, as its sender sent it.

	A `WebSocket` otherwise delivers what arrives as a stream -- every message
	appended to the bytes `ProgressEvent.SOCKET_DATA` announces -- which is the
	shape a `Socket` has, and loses where one message ends and the next
	begins. A session with a listener for this event delivers each message
	here instead, whole, with whether it was sent as text or as binary, and
	adds nothing to the stream.
**/
class WebSocketMessageEvent extends Event {
	/** Dispatched for each message a WebSocket session receives. **/
	public static inline var MESSAGE:EventType<WebSocketMessageEvent> = "webSocketMessage";

	/** The message, from its start. **/
	public var data(default, null):ByteArray;

	/** Whether the message was sent as text rather than as binary. **/
	public var isText(default, null):Bool;

	/**
		The message as text. Checked as UTF-8 on arrival when it was sent as
		text; a binary message is decoded as UTF-8 too, which is only
		meaningful when it holds some.
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

	override public function clone():Event {
		var event = new WebSocketMessageEvent(type, data, isText);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	override public function toString():String {
		return '[WebSocketMessageEvent type=$type isText=$isText length=${data == null ? 0 : data.length}]';
	}
}
