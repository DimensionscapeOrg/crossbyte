package crossbyte._internal.websocket;

/**
	The host a WebSocket client is asked to dial, IPv6 literals included.

	The pattern this replaces took a host as a run of letters, digits, dots
	and hyphens, so an IPv6 literal, `::1`, `[2001:db8::1]`, was refused
	as "Invalid host" before a socket existed, on every target. Built for the
	browser too, where `Socket` dials a WebSocket the same way.
**/
@:noCompletion
class WebSocketHost {
	/**
		Splits `target`, a host, perhaps after a scheme and before a path,
		into the host and the path, or answers null when it names no host. An
		IPv6 literal may be bracketed, as a URL writes one, or bare, and comes
		back without brackets.
	**/
	public static function split(target:String):Null<WebSocketTarget> {
		if (target == null) {
			return null;
		}

		var rest:String = target;
		var scheme:Int = rest.indexOf("://");
		if (scheme >= 0) {
			rest = rest.substr(scheme + 3);
		}

		if (StringTools.startsWith(rest, "[")) {
			var close:Int = rest.indexOf("]");
			if (close < 0) {
				return null;
			}
			var literal:String = rest.substring(1, close);
			if (!isIPv6(literal)) {
				return null;
			}
			// The port is given apart from the host, so nothing but a path
			// may follow the literal.
			var after:String = rest.substr(close + 1);
			if (after != "" && after.charAt(0) != "/") {
				return null;
			}
			return {host: literal, path: after == "" ? "" : after.substr(1)};
		}

		var slash:Int = rest.indexOf("/");
		var head:String = slash < 0 ? rest : rest.substr(0, slash);
		if (isIPv6(head)) {
			return {host: head, path: slash < 0 ? "" : rest.substr(slash + 1)};
		}

		// A name or an IPv4 address, read exactly as it always was.
		var name:EReg = ~/^([A-Za-z0-9\-\.]+)\/?(.*)/;
		if (!name.match(rest)) {
			return null;
		}
		return {host: name.matched(1), path: name.matched(2)};
	}

	/**
		`host` as a URL and a `Host` header write it: an IPv6 literal in
		brackets, anything else as it is.
	**/
	public static inline function forUrl(host:String):String {
		return host != null && host.indexOf(":") >= 0 ? "[" + host + "]" : host;
	}

	/**
		Whether `text` is an IPv6 literal: hex digits, colons, at least two,
		and dots for an IPv4 tail, with an optional `%` zone. Loose, as
		`IPv6.isNumericAddress` is: a malformed literal is the system's to
		refuse, and it will.
	**/
	public static function isIPv6(text:String):Bool {
		if (text == null || text == "") {
			return false;
		}

		var zone:Int = text.indexOf("%");
		if (zone == 0 || zone == text.length - 1) {
			return false;
		}
		var address:String = zone > 0 ? text.substr(0, zone) : text;

		var colons:Int = 0;
		for (i in 0...address.length) {
			var c:Int = StringTools.fastCodeAt(address, i);
			if (c == ":".code) {
				colons++;
			} else if (!((c >= "0".code && c <= "9".code) || (c >= "a".code && c <= "f".code) || (c >= "A".code && c <= "F".code)
				|| c == ".".code)) {
				return false;
			}
		}
		return colons >= 2;
	}
}

typedef WebSocketTarget = {
	var host:String;
	var path:String;
}
