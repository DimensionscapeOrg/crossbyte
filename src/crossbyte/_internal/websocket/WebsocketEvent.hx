package crossbyte._internal.websocket;

/**
 * ...
 * @author Christopher Speciale
 */
class WebsocketEvent {
	public static var OPEN:String = "open";
	public static var MESSAGE:String = "message";
	public static var ERROR:String = "error";
	public static var CLOSE:String = "close";

	public var type:String;
	public var target:Dynamic;
	public var data:Dynamic;
	public var code:Null<Int>;
	public var reason:Null<String>;

	public function new(type:String, target:WebSocket, ?data:Dynamic, ?code:Int, ?reason:String) {
		this.type = type;
		this.target = target;
		this.data = data;
		this.code = code;

		if (type == CLOSE && reason == null) {
			// Shared with the public close event so both layers describe a
			// code the same way. The table here previously reported 1003 as
			// "Message too big" — that is 1009; 1003 is unsupported data —
			// and had no entry for 1006, which is the code a peer that just
			// disappears produces and therefore the most common of all.
			reason = crossbyte.events.WebSocketCloseEvent.describe(code);
		}

		this.reason = reason;
	}
}
