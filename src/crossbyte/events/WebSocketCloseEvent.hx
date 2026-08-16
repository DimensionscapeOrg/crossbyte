package crossbyte.events;

import crossbyte.events.Event;

/**
	Dispatched when a WebSocket session closes, carrying the reason it did.

	The type is `Event.CLOSE`, the same string a plain `Socket` dispatches,
	so a listener that only cares that the connection ended needs no
	change. A listener that cares *why* casts:

	```haxe
	socket.addEventListener(Event.CLOSE, function(e:Event):Void {
		var close = Std.downcast(e, WebSocketCloseEvent);
		if (close != null && close.code == WebSocketCloseEvent.PROTOCOL_ERROR) {
			Logger.warn('peer sent a malformed frame: ${close.reason}');
		}
	});
	```

	That distinction is worth having: a peer disconnecting mid-conversation
	and a peer being dropped for sending a malformed frame are the same
	event to a bare `Event.CLOSE`, and they call for different responses —
	one is routine, the other says something is wrong with a client or an
	intermediary.
**/
class WebSocketCloseEvent extends Event {
	/** The session ended normally. */
	public static inline var NORMAL:Int = 1000;

	/** The endpoint is going away, for example a server shutting down. */
	public static inline var GOING_AWAY:Int = 1001;

	/** The peer sent something that violates the protocol. */
	public static inline var PROTOCOL_ERROR:Int = 1002;

	/** The peer sent a data type this endpoint cannot accept. */
	public static inline var UNSUPPORTED_DATA:Int = 1003;

	/**
		The connection ended without a close frame.

		The ordinary case for a client that simply disappeared — a closed
		tab, a dropped mobile connection — and so the most common code seen
		in practice. Not a fault by itself.
	**/
	public static inline var ABNORMAL:Int = 1006;

	/** A text frame did not contain valid UTF-8. */
	public static inline var INVALID_PAYLOAD:Int = 1007;

	/** The message violated a policy of this endpoint. */
	public static inline var POLICY_VIOLATION:Int = 1008;

	/** The message exceeded what this endpoint will accept. */
	public static inline var MESSAGE_TOO_BIG:Int = 1009;

	/** A required extension was not negotiated. */
	public static inline var MISSING_EXTENSION:Int = 1010;

	/** The endpoint hit an unexpected condition, including a full output buffer. */
	public static inline var INTERNAL_ERROR:Int = 1011;

	/**
		RFC 6455 close code, or `0` when the session ended without one being
		determined.
	**/
	public var code(default, null):Int;

	/**
		Human-readable reason. Supplied by the peer when it sent a close
		frame, otherwise filled in from `code`.
	**/
	public var reason(default, null):String;

	/**
		Whether this closure is one an application should treat as routine.

		True for a normal closure, a peer going away, and a connection that
		simply ended — the cases a chat server sees constantly. False for
		the codes that indicate a protocol or policy fault worth logging.
	**/
	public var expected(get, never):Bool;

	public function new(type:String, code:Int = 0, reason:String = null) {
		super(type);
		this.code = code;
		this.reason = (reason == null) ? describe(code) : reason;
	}

	@:noCompletion private function get_expected():Bool {
		return code == NORMAL || code == GOING_AWAY || code == ABNORMAL || code == 0;
	}

	/**
		A short description of a close code, per RFC 6455 section 7.4.1.
	**/
	public static function describe(code:Int):String {
		return switch (code) {
			case NORMAL: "Normal closure";
			case GOING_AWAY: "Going away";
			case PROTOCOL_ERROR: "Protocol error";
			case UNSUPPORTED_DATA: "Unsupported data";
			case ABNORMAL: "Closed without a close frame";
			case INVALID_PAYLOAD: "Invalid frame payload data";
			case POLICY_VIOLATION: "Policy violation";
			case MESSAGE_TOO_BIG: "Message too big";
			case MISSING_EXTENSION: "Mandatory extension missing";
			case INTERNAL_ERROR: "Internal error";
			case 1015: "TLS handshake failed";
			default: "";
		}
	}

	public override function clone():Event {
		var event = new WebSocketCloseEvent(type, code, reason);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	override public function toString():String {
		return '[WebSocketCloseEvent type=$type code=$code reason=$reason]';
	}
}
