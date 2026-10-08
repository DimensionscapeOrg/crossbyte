package crossbyte._internal.websocket;

// Not built for the browser: server-side WebSocket framing over a raw socket. A page uses the browser's own WebSocket through crossbyte.net.Socket.
#if !(js && !nodejs)
import crossbyte.io.ByteArray;

/**
 * What a framed session tells its owner, `crossbyte.net.WebSocket`: it
 * opened, a message arrived, something failed, it closed. Typed, so a
 * message's payload is read without a checked conversion.
 *
 * @author Christopher Speciale
 */
class WebsocketEvent {
	public static var OPEN:String = "open";
	public static var MESSAGE:String = "message";
	public static var ERROR:String = "error";
	public static var CLOSE:String = "close";

	public var type:String;
	public var target:WebSocket;

	/** On a message: what it carried. **/
	public var message:ByteArray;

	/** On an error: what went wrong. **/
	public var text:String;

	/** On a close: its code, or 0 for none. **/
	public var code:Int;

	public var reason:Null<String>;

	/** On a message: whether it was sent as text rather than binary. **/
	public var isText:Bool = false;

	/**
		On an error: the `IOErrorEvent` id the owner reports it with:
		`IOErrorEvent.TIMEOUT_ERROR_ID` for a deadline that passed, else 0.
	**/
	public var errorID:Int = 0;

	public function new(type:String, target:WebSocket, ?message:ByteArray, ?text:String, code:Int = 0, ?reason:String) {
		this.type = type;
		this.target = target;
		this.message = message;
		this.text = text;
		this.code = code;

		if (type == CLOSE && reason == null) {
			// Shared with the public close event so both layers describe a
			// code the same way.
			reason = crossbyte.events.WebSocketCloseEvent.describe(code);
		}

		this.reason = reason;
	}
}
#end
