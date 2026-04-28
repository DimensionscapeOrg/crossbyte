package crossbyte.url;

/**
 * ...
 * @author Christopher Speciale
 */
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
		@:privateAccess return this.__uri;
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

	@:private @:noCompletion private function parseUri(uri:String):Void {
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
		if (authority.length == 0 || authority.indexOf("@") >= 0) {
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
		if (rawPort.length == 0 || !~/^[0-9]+$/.match(rawPort)) {
			throw "Uri must be well-formed";
		}

		var parsed:Null<Int> = Std.parseInt(rawPort);
		if (parsed == null || parsed < 0 || parsed > 65535) {
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
