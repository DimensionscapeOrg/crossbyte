package crossbyte.url;

import crossbyte.utils.IntParse;

/** Parsed URL wrapper with convenience accessors for common request parts. */
@:forward
@:transitive
abstract URL(URLAccess) from URLAccess to URLAccess {
	@:private @:noCompletion @:from static private function fromString(uri:String):URL {
		return new URL(uri);
	}

	@:private @:noCompletion @:from static private function fromDynamic(uri:Dynamic):URL {
		return new URL(uri);
	}

	public var scheme(get, never):Null<String>;
	public var host(get, never):Null<String>;
	public var port(get, never):Null<Int>;
	public var path(get, never):Null<String>;
	public var query(get, never):Null<String>;
	public var fragment(get, never):Null<String>;
	public var ssl(get, never):Null<Bool>;

	@:to public inline function toString():String {
		// Route through a (non-inline) public method rather than @:privateAccess
		// on __uri: inlining the private field read into a caller in another
		// class produces an IllegalAccessError on the jvm target.
		return this.getRawUri();
	}

	public inline function new(address:String) {
		this = new URLAccess(address);
	}

	@:private @:noCompletion private inline function get_scheme():Null<String> {
		return this.scheme;
	}

	@:private @:noCompletion private inline function get_host():Null<String> {
		return this.host;
	}

	@:private @:noCompletion private inline function get_port():Null<Int> {
		return this.port;
	}

	@:private @:noCompletion private inline function get_path():Null<String> {
		return this.path;
	}

	@:private @:noCompletion private inline function get_query():Null<String> {
		return this.query;
	}

	@:private @:noCompletion private inline function get_fragment():Null<String> {
		return this.fragment;
	}

	@:private @:noCompletion private inline function get_ssl():Null<Bool> {
		return this.ssl;
	}
}

@:private @:noCompletion class URLAccess {
	public var scheme(default, null):Null<String>;
	public var host(default, null):Null<String>;
	public var port(default, null):Null<Int>;
	public var path(default, null):Null<String>;
	public var query(default, null):Null<String>;
	public var fragment(default, null):Null<String>;
	public var ssl(default, null):Null<Bool>;

	@:private @:noCompletion private var __uri:String;

	public function new(uri:String) {
		__uri = uri;
		parseUri(__uri);
	}

	// Non-inline on purpose: keeps the private __uri read inside this class so a
	// caller in another class (e.g. _internal.http.Http) never emits a direct
	// cross-class field access (IllegalAccessError on jvm).
	public function getRawUri():String {
		return __uri;
	}

	@:private @:noCompletion private function parseUri(uri:String):Void {
		// No control character anywhere. The client writes the path, query
		// and host into its request as they are, so a CR or LF kept here ended
		// the request line and began a header of the URL's choosing:
		// "http://host/a\r\nX-Injected: evil" put that header on the wire, and
		// a longer one could smuggle a second request. WHATWG's parser strips
		// tabs and line breaks and encodes the rest; this refuses them, which
		// says so rather than requesting something the caller did not write.
		for (i in 0...uri.length) {
			var code:Int = StringTools.fastCodeAt(uri, i);
			if (code < 0x20 || code == 0x7F) {
				throw "Uri must be well-formed";
			}
		}

		var schemeEnd:Int = uri.indexOf("://");
		if (schemeEnd <= 0) {
			throw "Uri must be well-formed";
		}

		var rawScheme:String = uri.substr(0, schemeEnd);
		if (!~/^[A-Za-z][A-Za-z0-9+\-.]*$/.match(rawScheme)) {
			throw "Uri must be well-formed";
		}

		scheme = rawScheme.toLowerCase();
		ssl = (scheme == "https" || scheme == "wss");

		var rest:String = uri.substr(schemeEnd + 3);
		var authorityEnd:Int = rest.length;
		for (token in ["/", "?", "#"]) {
			var index:Int = rest.indexOf(token);
			if (index >= 0 && index < authorityEnd) {
				authorityEnd = index;
			}
		}

		var authority:String = rest.substr(0, authorityEnd);
		// A space has no place in a host or a port. One in the path or the
		// query is the client's to encode on the way out, as a browser does.
		if (authority.length == 0 || authority.indexOf("@") >= 0 || authority.indexOf(" ") >= 0) {
			throw "Uri must be well-formed";
		}

		var rawPort:Null<String> = null;
		if (StringTools.startsWith(authority, "[")) {
			var bracketEnd:Int = authority.indexOf("]");
			if (bracketEnd <= 1) {
				throw "Uri must be well-formed";
			}

			host = authority.substr(1, bracketEnd - 1);
			if (host.indexOf(":") < 0) {
				throw "Uri must be well-formed";
			}

			var remainder:String = authority.substr(bracketEnd + 1);
			if (remainder.length > 0) {
				if (!StringTools.startsWith(remainder, ":")) {
					throw "Uri must be well-formed";
				}
				rawPort = remainder.substr(1);
			}
		} else {
			var colon:Int = authority.lastIndexOf(":");
			if (colon >= 0) {
				if (authority.indexOf(":") != colon) {
					throw "Uri must be well-formed";
				}
				rawPort = authority.substr(colon + 1);
				host = authority.substr(0, colon);
			} else {
				host = authority;
			}
		}

		if (host == null || host.length == 0) {
			throw "Uri must be well-formed";
		}

		port = __parsePort(rawPort);
		if (port == null) {
			port = ssl ? 443 : 80;
		}

		var reference:String = rest.substr(authorityEnd);
		__parseReference(reference);
	}

	@:private @:noCompletion private function __parsePort(rawPort:Null<String>):Null<Int> {
		if (rawPort == null) {
			return null;
		}
		// Digits only and within 65535, through IntParse: a regular expression
		// compiled per URL checked the digits, then Std.parseInt read them,
		// which answers differently past an Int on every target. A leading
		// zero is still refused, as it was, so one port has one spelling.
		var parsed:Int = rawPort.length > 5 ? -1 : IntParse.decimal(rawPort, 65535);
		if (parsed < 0 || (rawPort.length > 1 && StringTools.fastCodeAt(rawPort, 0) == "0".code)) {
			throw "Uri must be well-formed";
		}

		return parsed;
	}

	@:private @:noCompletion private function __parseReference(reference:String):Void {
		var pathEnd:Int = reference.length;
		var queryIndex:Int = reference.indexOf("?");
		var fragmentIndex:Int = reference.indexOf("#");
		if (queryIndex >= 0 && (fragmentIndex < 0 || queryIndex < fragmentIndex)) {
			pathEnd = queryIndex;
		} else if (fragmentIndex >= 0) {
			pathEnd = fragmentIndex;
		}

		path = reference.substr(0, pathEnd);
		if (path == "") {
			path = "/";
		}

		query = "";
		fragment = "";
		if (queryIndex >= 0 && (fragmentIndex < 0 || queryIndex < fragmentIndex)) {
			var queryEnd:Int = fragmentIndex >= 0 ? fragmentIndex : reference.length;
			query = reference.substr(queryIndex + 1, queryEnd - queryIndex - 1);
		}
		if (fragmentIndex >= 0) {
			fragment = reference.substr(fragmentIndex + 1);
		}
	}
}
