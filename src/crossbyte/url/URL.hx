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
		var regex:EReg = new EReg('^([\\w-]+):\\/\\/([^\\/?:#]+)(?::(\\d+))?([^?#]*)(?:\\?([^#]*))?(?:#(.*))?$', 'i');

		if (regex.match(uri)) {
			scheme = regex.matched(1);
			ssl = (scheme == "https" || scheme == "wss");
			host = regex.matched(2);
			port = Std.parseInt(regex.matched(3));
			if (port == null) {
				port = ssl ? 443 : 80;
			}
			path = regex.matched(4);
			if (path == "") {
				path = "/";
			}
			query = regex.matched(5);
			if (query == null) {
				query = "";
			}
			fragment = regex.matched(6);
			if (fragment == null) {
				fragment = "";
			}
		} else {
			throw "Uri must be well-formed";
		}
	}
}
