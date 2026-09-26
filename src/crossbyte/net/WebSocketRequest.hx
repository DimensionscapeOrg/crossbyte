package crossbyte.net;

// Not built for the browser, for the same reason as ServerWebSocket: a page
// never receives an upgrade request, it only sends one.
#if !(js && !nodejs)

import crossbyte.errors.ArgumentError;
import haxe.ds.StringMap;

/**
	The HTTP request a client sent to open a WebSocket session: what a server
	has to decide on before it answers, and what a session keeps afterwards.

	A server used to parse this and throw it away, so nothing about who was
	asking -- the path they asked for, a token in the query, a cookie, the
	page's `Origin`, the subprotocol a browser offered -- reached anything
	that could act on it. `ServerWebSocket.upgrade` is shown it before the
	`101` goes out, and can refuse the session or choose its subprotocol;
	the session then carries it as `WebSocket.request`.

	```haxe
	server.upgrade = function(request:WebSocketRequest):Bool {
		if (request.origin != "https://example.com") {
			return false; // 403
		}
		if (request.protocols.indexOf("chat.v2") < 0) {
			request.status = 426;
			return false;
		}
		request.protocol = "chat.v2";
		return true;
	};
	```

	Nothing in it is proof of anything: a client other than a browser may
	send whatever `Origin` it likes, and the address is the connection's,
	which a proxy in front of the server replaces with its own.
**/
final class WebSocketRequest {
	/** The request method, which for an upgrade is always `GET`. **/
	public var method(default, null):String;

	/** The request target as the client sent it: the path and any query. **/
	public var uri(default, null):String;

	/** The path of `uri`, without its query. **/
	public var path(default, null):String;

	/** The query of `uri`, without the `?`, or an empty string for none. **/
	public var query(default, null):String;

	/**
		The page that opened the session, from the `Origin` header, or `null`
		when there is none. A browser always sends it, and cannot be made to
		lie about it; anything else sends what it likes. Refusing an origin is
		what stops another site's page opening a session with a visitor's
		cookies.
	**/
	public var origin(get, never):Null<String>;

	/**
		The subprotocols the client offered, most preferred first, from
		`Sec-WebSocket-Protocol`. Empty when it offered none.
	**/
	public var protocols(default, null):Array<String>;

	/** The address the connection came from. **/
	public var remoteAddress(default, null):String;

	/** The port the connection came from. **/
	public var remotePort(default, null):Int;

	/**
		The subprotocol the session will speak, echoed to the client in the
		`101`, or `null` for none.

		The first one offered unless the server's `upgrade` hook chooses
		otherwise -- a browser that offers a subprotocol and hears none back
		fails the connection, so accepting the session means accepting one.
		It must be one the client offered.

		@throws ArgumentError if set to one the client did not offer.
	**/
	public var protocol(default, set):Null<String>;

	/**
		The status a refused upgrade is answered with: 403 unless the hook
		says otherwise -- 401 for a missing credential, say, or 426 for a
		subprotocol the server does not speak.
	**/
	public var status:Int = 403;

	@:noCompletion private var __headers:StringMap<String>;

	@:allow(crossbyte._internal.websocket)
	@:noCompletion private function new(requestLine:String, headers:StringMap<String>, remoteAddress:String, remotePort:Int) {
		__headers = headers;
		this.remoteAddress = remoteAddress;
		this.remotePort = remotePort;

		// "GET /path?query HTTP/1.1"
		var parts:Array<String> = requestLine.split(" ");
		method = parts.length > 0 ? parts[0] : "";
		uri = parts.length > 1 ? parts[1] : "/";

		var mark:Int = uri.indexOf("?");
		path = mark < 0 ? uri : uri.substr(0, mark);
		query = mark < 0 ? "" : uri.substr(mark + 1);

		protocols = [];
		var offered:Null<String> = headers.get("sec-websocket-protocol");
		if (offered != null) {
			for (token in offered.split(",")) {
				var name:String = StringTools.trim(token);
				if (name.length > 0) {
					protocols.push(name);
				}
			}
		}

		protocol = protocols.length > 0 ? protocols[0] : null;
	}

	/**
		A request header by name, in any case, or `null` when absent. A header
		sent more than once reads as its values joined with `, ` (a cookie's
		with `; `), as HTTP folds them.
	**/
	public function header(name:String):Null<String> {
		return name == null ? null : __headers.get(name.toLowerCase());
	}

	/** The names of every header sent, lower-cased. **/
	public function headerNames():Iterator<String> {
		return __headers.keys();
	}

	/**
		A cookie from the `Cookie` header, or `null` when the client sent none
		by that name. The value as sent: not decoded.
	**/
	public function cookie(name:String):Null<String> {
		var cookies:Null<String> = __headers.get("cookie");
		if (cookies == null || name == null) {
			return null;
		}

		for (pair in cookies.split(";")) {
			var equals:Int = pair.indexOf("=");
			if (equals < 0) {
				continue;
			}
			if (StringTools.trim(pair.substr(0, equals)) == name) {
				return StringTools.trim(pair.substr(equals + 1));
			}
		}

		return null;
	}

	@:noCompletion private inline function get_origin():Null<String> {
		return __headers.get("origin");
	}

	@:noCompletion private function set_protocol(value:Null<String>):Null<String> {
		if (value != null && protocols.indexOf(value) < 0) {
			throw new ArgumentError('The client did not offer the subprotocol "$value"; it offered ' + (protocols.length == 0 ? "none" : protocols.join(", "))
				+ ".");
		}
		return protocol = value;
	}
}
#end
