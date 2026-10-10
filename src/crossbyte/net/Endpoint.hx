package crossbyte.net;

using StringTools;

@:structInit
/**
 * Parsed endpoint data produced from a transport URI.
 */
class Endpoint {
	/** Parsed protocol scheme. */
	public var protocol:Protocol;
	/** Hostname or IP literal without brackets. */
	public var address:String;
	/** Explicit or inferred port number. */
	public var port:Int;
	/** `true` when the original URI requested a secure WebSocket (`wss://`). */
	public var secure:Bool = false;
	/** WebSocket resource path including query string when present. */
	public var resource:String = "";
}

/**
 * Parses a transport URI into an `Endpoint`.
 *
 * Supports `tcp://`, `rudp://`, `local://`, `ws://`, and `wss://`. Plain TCP/RUDP
 * endpoints require an explicit port and do not accept path or query
 * components. `local://` endpoints treat the remainder as a local pipe name.
 * WebSocket endpoints accept optional paths and infer port `80` or
 * `443` when omitted.
 *
 * Port 0 is refused: it names nowhere to connect to. A `NetHost` made from
 * a URI reads it as a port the system chooses, as `ServerSocket.bind(0)`
 * does.
 */
function parseURL(input:String, defaultProtocol:Protocol = Protocol.TCP, ?endpoint:Endpoint):Endpoint {
	return __parseURL(input, defaultProtocol, endpoint, false);
}

/**
	`parseURL` for an endpoint to listen on, where port 0 is the system's
	choice of a free port rather than nowhere: `NetHost`'s. Read as one to
	dial, port 0 would be refused, and a host made from a URI could only be
	given a port someone had found free a moment before.
**/
@:noCompletion function __parseListenURL(input:String):Endpoint {
	return __parseURL(input, Protocol.TCP, null, true);
}

@:noCompletion function __parseURL(input:String, defaultProtocol:Protocol, endpoint:Null<Endpoint>, listening:Bool):Endpoint {
	// What is wrong is said as a short phrase below; the caller is told it
	// with the URL it gave, as an ArgumentError.
	try {
		return __readURL(input, defaultProtocol, endpoint, listening);
	} catch (problem:String) {
		throw new crossbyte.errors.ArgumentError('Cannot use "$input" as an address: $problem.');
	}
}

@:noCompletion private function __readURL(input:String, defaultProtocol:Protocol, endpoint:Null<Endpoint>, listening:Bool):Endpoint {
	if (input == null) {
		throw "empty url";
	}

	var s:String = input.trim();
	var len:Int = s.length;
	if (len == 0) {
		throw "empty url";
	}

	var proto:Protocol = defaultProtocol;
	var rest:String = s;
	var i:Int = s.indexOf("://");
	// only used to choose 443 default for websockets
	var wasWss:Bool = false;

	if (i >= 0) {
		var scheme = s.substr(0, i).toLowerCase();
		rest = s.substr(i + 3);
		switch (scheme) {
			case "tcp":
				proto = Protocol.TCP;
			case "udp":
				proto = Protocol.UDP;
			case "rudp":
				proto = Protocol.RUDP;
			case "local":
				proto = Protocol.LOCAL;
			case "ws":
				proto = Protocol.WEBSOCKET;
			case "wss":
				proto = Protocol.WEBSOCKET;
				wasWss = true;
			default:
				throw 'unknown scheme "$scheme" (tcp, ws, wss, rudp and local are known)';
		}
	}

	if (proto == Protocol.LOCAL) {
		if (rest.length == 0) {
			throw "missing local endpoint";
		}
		if (endpoint != null) {
			endpoint.address = rest;
			endpoint.port = 0;
			endpoint.protocol = proto;
			endpoint.secure = false;
			endpoint.resource = "";
		} else {
			endpoint = {protocol: proto, address: rest, port: 0, secure: false, resource: ""};
		}

		return endpoint;
	}

	var cut:Int = indexOfAny(rest, SLASHQF);
	var auth:String = (cut >= 0) ? rest.substr(0, cut) : rest;
	var tail:String = (cut >= 0) ? rest.substr(cut) : "";
	if (auth.length == 0) {
		throw "missing host";
	}

	if (auth.indexOf("@") >= 0) {
		throw "userinfo not supported";
	}

	var host:String;
	var port:Int = -1;

	if (auth.charCodeAt(0) == 91) {
		var rb:Int = auth.indexOf("]");
		if (rb <= 0) {
			throw "invalid IPv6 literal";
		}

		host = auth.substr(1, rb - 1);
		if (rb + 1 < auth.length) {
			if (auth.charCodeAt(rb + 1) != 58) {
				throw "unexpected after IPv6 literal";
			}
			port = parsePort(auth.substr(rb + 2));
		}
	} else {
		if (auth.indexOf(":") != auth.lastIndexOf(":")) {
			throw "invalid IPv6 literal";
		}

		var lastColon:Int = auth.lastIndexOf(":");
		if (lastColon >= 0) {
			host = auth.substr(0, lastColon);
			port = parsePort(auth.substr(lastColon + 1));
		} else {
			host = auth;
		}
	}

	if (host.length == 0) {
		throw "empty host";
	}

	var resource = "";
	if (proto == Protocol.WEBSOCKET) {
		resource = __parseWebSocketResource(tail);
	} else if (tail.length > 0) {
		throw "a path or query is taken only by ws:// and wss://";
	}

	if (proto == Protocol.WEBSOCKET) {
		if (port < 0) {
			port = wasWss ? 443 : 80;
		}

		if (port == 0 && !listening) {
			throw "invalid port: 0";
		}
	} else {
		if (port < 0) {
			throw "a port is required for tcp://, udp:// and rudp://";
		}

		if (port == 0 && !listening) {
			throw "invalid port: 0";
		}
	}

	if (endpoint != null) {
		endpoint.address = host;
		endpoint.port = port;
		endpoint.protocol = proto;
		endpoint.secure = wasWss;
		endpoint.resource = resource;
	} else {
		endpoint = {protocol: proto, address: host, port: port, secure: wasWss, resource: resource};
	}

	return endpoint;
}

@:noCompletion final SLASHQF:Array<String> = ["/", "?", "#"];

@:noCompletion inline function indexOfAny(s:String, needles:Array<String>):Int {
	var best:Int = -1;
	for (n in needles) {
		var k:Int = s.indexOf(n);
		if (k >= 0 && (best < 0 || k < best)) {
			best = k;
		}
	}
	return best;
}

@:noCompletion inline function parsePort(p:String):Int {
	var n:Int = p.length;
	if (n == 0) {
		throw "empty port";
	}

	// Bounded as it is read, rather than read and then compared: Std.parseInt
	// answers a number too big for an Int differently on every target, and on
	// Linux native kept its low 32 bits, so a port of 4294967296 read as 0.
	var v:Int = crossbyte.utils.IntParse.decimal(p, 65535);
	if (v < 0) {
		throw 'invalid port: $p';
	}

	return v;
}

@:noCompletion inline function __parseWebSocketResource(tail:String):String {
	if (tail == null || tail.length == 0) {
		return "/";
	}

	var fragmentIndex = tail.indexOf("#");
	var withoutFragment = (fragmentIndex >= 0) ? tail.substr(0, fragmentIndex) : tail;
	if (withoutFragment.length == 0) {
		return "/";
	}

	return switch (withoutFragment.charAt(0)) {
		case "?": "/" + withoutFragment;
		case "/": withoutFragment;
		default: "/" + withoutFragment;
	}
}
