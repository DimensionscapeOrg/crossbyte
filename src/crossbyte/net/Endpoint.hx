package crossbyte.net;

using StringTools;

@:structInit
class Endpoint {
	public var protocol:Protocol;
	public var address:String;
	public var port:Int;
}

function parseURL(input:String, defaultProtocol:Protocol = Protocol.TCP, ?endpoint:Endpoint):Endpoint {
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
			case "ws":
				proto = Protocol.WEBSOCKET;
			case "wss":
				proto = Protocol.WEBSOCKET;
				wasWss = true;
			default:
				throw 'unsupported scheme: $scheme';
		}
	}

	var cut:Int = indexOfAny(rest, SLASHQF);
	var auth:String = (cut >= 0) ? rest.substr(0, cut) : rest;
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

	if (proto == Protocol.WEBSOCKET) {
		if (port < 0) {
			port = wasWss ? 443 : 80;
		}

		if (port == 0) {
			throw "invalid port: 0";
		}
	} else {
		if (port < 0) {
			throw "port required for tcp/udp";
		}

		if (port == 0) {
			throw "invalid port: 0";
		}
	}

	if (endpoint != null) {
		endpoint.address = host;
		endpoint.port = port;
		endpoint.protocol = proto;
	} else {
		endpoint = {protocol: proto, address: host, port: port};
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

	for (i in 0...n) {
		var c:Int = p.charCodeAt(i);
		if (c < 48 || c > 57) {
			throw 'invalid port: $p';
		}
	}
	var v:Null<Int> = Std.parseInt(p);
	if (v == null || v < 0 || v > 65535) {
		throw 'invalid port: $p';
	}

	return v;
}
