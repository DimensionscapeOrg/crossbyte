package crossbyte.net;

/**
	The proxies a server trusts to say who their client was, and the
	client's address read through them, as Express's `trust proxy` and
	Laravel's `TrustProxies` read it.

	Behind a load balancer, a CDN or a shared host's front server, a
	connection comes from the proxy, and each proxy adds the address it was
	reached from to `Forwarded` (RFC 7239) or `X-Forwarded-For`. Anyone can
	send those headers, so only what trusted proxies wrote is believed: the
	chain is read from the right, starting at the connection's own peer and
	going past every hop that is a trusted proxy, and the first that is not
	is the client. A peer that is not trusted is the client itself, whatever
	its headers say, so a client cannot name itself someone else.

	```hx
	// Given peer:String, forwarded:Null<String>, forwardedFor:Null<String>, limiter:crossbyte.net.RateLimiter.
	var proxies = new crossbyte.net.TrustedProxies(["loopback", "10.0.0.0/8", "203.0.113.7"]);
	var client = proxies.clientAddress(peer, forwarded, forwardedFor);
	limiter.tryAcquire(crossbyte.net.RateLimiter.addressKey(client));
	```

	On PHP, `peer` is `$_SERVER['REMOTE_ADDR']` and the headers are
	`HTTP_FORWARDED` and `HTTP_X_FORWARDED_FOR`.

	A proxy is an address (`203.0.113.7`, `::1`), a CIDR block
	(`10.0.0.0/8`, `fd00::/8`), or one of Express's names: `loopback`
	(127.0.0.0/8 and ::1), `linklocal` (169.254.0.0/16 and fe80::/10) and
	`uniquelocal` (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 and fc00::/7).
	An IPv4 block also matches the IPv4-mapped IPv6 form a dual-stack
	listener reports (`::ffff:10.0.0.1`).
**/
class TrustedProxies {
	@:noCompletion private final __blocks:Array<Block> = [];

	/**
		@param proxies Addresses, CIDR blocks and names, as the class notes
			say.
		@throws crossbyte.errors.ArgumentError For an entry that is none of
			them.
	**/
	public function new(proxies:Array<String>) {
		if (proxies == null) {
			proxies = [];
		}
		for (entry in proxies) {
			var trimmed:String = entry == null ? "" : StringTools.trim(entry);
			var named:Null<Array<String>> = switch (trimmed.toLowerCase()) {
				case "loopback": ["127.0.0.0/8", "::1/128"];
				case "linklocal": ["169.254.0.0/16", "fe80::/10"];
				case "uniquelocal": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"];
				default: null;
			};
			for (block in (named != null ? named : [trimmed])) {
				var parsed:Null<Block> = __block(block);
				if (parsed == null) {
					throw new crossbyte.errors.ArgumentError('"$entry" is not an address, a CIDR block or one of loopback, linklocal and uniquelocal.');
				}
				__blocks.push(parsed);
			}
		}
	}

	/** Whether `address` is one of the trusted proxies. Anything that is not an address is not. **/
	public function trusts(address:String):Bool {
		var groups:Null<Array<Int>> = address == null ? null : __groups(StringTools.trim(address));
		if (groups == null) {
			return false;
		}
		for (block in __blocks) {
			if (block.contains(groups)) {
				return true;
			}
		}
		return false;
	}

	/**
		The client's address: `peer` when it is not a trusted proxy;
		otherwise, read from the right of the chain `forwarded` (a
		`Forwarded` header) or, without one, `forwardedFor` (an
		`X-Forwarded-For` header) give, the first hop that is not a trusted
		proxy, and the farthest hop when every one is. A hop that names no
		address (RFC 7239 allows `unknown` and obfuscated names) ends the
		chain at the trusted proxy that reported it, whose address is
		answered, as it is when a header cannot be read at all.

		Several headers of a kind are one, joined with commas, as HTTP joins
		them. A port, and the brackets around an IPv6 address, are not part
		of the answer.
	**/
	public function clientAddress(peer:String, ?forwarded:String, ?forwardedFor:String):String {
		var nearest:Null<String> = peer == null ? null : __addressOf(StringTools.trim(peer));
		if (nearest == null || !trusts(nearest)) {
			return peer;
		}
		var hops:Null<Array<String>> = if (forwarded != null && StringTools.trim(forwarded).length > 0) {
			__forwardedHops(forwarded);
		} else if (forwardedFor != null) {
			[for (hop in forwardedFor.split(",")) StringTools.trim(hop)];
		} else {
			[];
		}
		if (hops == null) {
			return nearest;
		}
		var i:Int = hops.length - 1;
		while (i >= 0) {
			var address:Null<String> = __addressOf(hops[i]);
			if (address == null) {
				return nearest;
			}
			if (!trusts(address)) {
				return address;
			}
			nearest = address;
			i--;
		}
		return nearest;
	}

	/**
		The `for` of each element of a `Forwarded` header, in order, or null
		when it cannot be read: an unclosed quote, or an element without one.
	**/
	@:noCompletion private static function __forwardedHops(header:String):Null<Array<String>> {
		var hops:Array<String> = [];
		var element:Null<String> = null;
		var i:Int = 0;
		var n:Int = header.length;
		while (i <= n) {
			// One element: pairs separated by ';', ended by ',' or the end.
			var found:Null<String> = null;
			var ended:Bool = false;
			while (!ended) {
				while (i < n && __space(header.charCodeAt(i))) {
					i++;
				}
				var nameStart:Int = i;
				while (i < n && header.charAt(i) != "=" && header.charAt(i) != ";" && header.charAt(i) != ",") {
					i++;
				}
				var name:String = StringTools.trim(header.substring(nameStart, i)).toLowerCase();
				var value:Null<String> = null;
				if (i < n && header.charAt(i) == "=") {
					i++;
					if (i < n && header.charAt(i) == "\"") {
						i++;
						var quoted:StringBuf = new StringBuf();
						var closed:Bool = false;
						while (i < n) {
							var c:String = header.charAt(i);
							if (c == "\\" && i + 1 < n) {
								quoted.add(header.charAt(i + 1));
								i += 2;
							} else if (c == "\"") {
								i++;
								closed = true;
								break;
							} else {
								quoted.add(c);
								i++;
							}
						}
						if (!closed) {
							return null;
						}
						value = quoted.toString();
					} else {
						var valueStart:Int = i;
						while (i < n && header.charAt(i) != ";" && header.charAt(i) != ",") {
							i++;
						}
						value = StringTools.trim(header.substring(valueStart, i));
					}
				}
				if (name == "for" && value != null && found == null) {
					found = value;
				}
				while (i < n && __space(header.charCodeAt(i))) {
					i++;
				}
				if (i >= n || header.charAt(i) == ",") {
					ended = true;
				} else if (header.charAt(i) == ";") {
					i++;
				} else {
					// Text after a value that is neither ';' nor ',': unreadable.
					return null;
				}
			}
			if (found == null) {
				// An element must say whom it was for, or the chain cannot be followed.
				return null;
			}
			hops.push(found);
			i++;
			if (i > n) {
				break;
			}
		}
		return hops;
	}

	@:noCompletion private static inline function __space(code:Null<Int>):Bool {
		return code == " ".code || code == "\t".code;
	}

	/**
		The address in a hop, without a port or brackets: `192.0.2.60` from
		`192.0.2.60:8080`, `2001:db8::17` from `[2001:db8::17]:4711`. Null
		when it holds none.
	**/
	@:noCompletion private static function __addressOf(hop:String):Null<String> {
		if (hop == null || hop.length == 0) {
			return null;
		}
		var address:String = hop;
		if (StringTools.startsWith(hop, "[")) {
			var close:Int = hop.indexOf("]");
			if (close < 0) {
				return null;
			}
			var rest:String = hop.substr(close + 1);
			if (rest.length > 0 && !(StringTools.startsWith(rest, ":") && __port(rest.substr(1)))) {
				return null;
			}
			address = hop.substring(1, close);
			return __ipv6(address) != null ? address : null;
		}
		var colon:Int = hop.indexOf(":");
		if (colon >= 0 && hop.indexOf(":", colon + 1) < 0) {
			// One colon: an IPv4 address and its port.
			if (!__port(hop.substr(colon + 1))) {
				return null;
			}
			address = hop.substr(0, colon);
		}
		return __groups(address) != null ? address : null;
	}

	@:noCompletion private static function __port(text:String):Bool {
		return text.length > 0 && text.length <= 5 && crossbyte.utils.IntParse.decimal(text, 65535) >= 0;
	}

	/** An address as eight 16-bit groups, IPv4 as the IPv4-mapped IPv6 address; null when it is none. **/
	@:noCompletion private static function __groups(address:String):Null<Array<Int>> {
		if (address.indexOf(":") >= 0) {
			return __ipv6(address);
		}
		var octets:Array<String> = address.split(".");
		if (octets.length != 4) {
			return null;
		}
		var values:Array<Int> = [];
		for (octet in octets) {
			if (octet.length == 0 || octet.length > 3) {
				return null;
			}
			var value:Int = crossbyte.utils.IntParse.decimal(octet, 255);
			if (value < 0) {
				return null;
			}
			values.push(value);
		}
		return [0, 0, 0, 0, 0, 0xFFFF, (values[0] << 8) | values[1], (values[2] << 8) | values[3]];
	}

	@:noCompletion private static inline function __ipv6(address:String):Null<Array<Int>> {
		return @:privateAccess RateLimiter.__parseIPv6(address);
	}

	@:noCompletion private static function __block(text:String):Null<Block> {
		var slash:Int = text.indexOf("/");
		var address:String = slash < 0 ? text : text.substr(0, slash);
		var groups:Null<Array<Int>> = __groups(address);
		if (groups == null) {
			return null;
		}
		var ipv4:Bool = address.indexOf(":") < 0;
		var most:Int = ipv4 ? 32 : 128;
		var bits:Int = most;
		if (slash >= 0) {
			var written:String = text.substr(slash + 1);
			if (written.length == 0 || written.length > 3) {
				return null;
			}
			bits = crossbyte.utils.IntParse.decimal(written, most);
			if (bits < 0) {
				return null;
			}
		}
		return new Block(groups, ipv4 ? bits + 96 : bits);
	}
}

/** One trusted block: an address's groups and how many leading bits must match. **/
@:noCompletion private class Block {
	final __groups:Array<Int>;
	final __bits:Int;

	public function new(groups:Array<Int>, bits:Int) {
		__groups = groups;
		__bits = bits;
	}

	public function contains(groups:Array<Int>):Bool {
		for (i in 0...8) {
			var kept:Int = __bits - i * 16;
			if (kept <= 0) {
				return true;
			}
			var mask:Int = kept >= 16 ? 0xFFFF : (0xFFFF << (16 - kept)) & 0xFFFF;
			if (((__groups[i] ^ groups[i]) & mask) != 0) {
				return false;
			}
		}
		return true;
	}
}
