package crossbyte._internal.http;

/**
	Cookies for the length of one request, carried across its redirects.

	Deliberately not a browser's cookie jar. It keeps what a response set,
	hands it back only to the host that set it, and forgets all of it when the
	request finishes. There is no domain attribute, no path matching, no
	persistence and no public suffix list -- and the ways a cookie jar hands a
	credential to the wrong site are almost all in those parts. A narrower
	thing that is right beats a wider one that is nearly right.

	What it is for: `followRedirects` is on by default, so a sign-in that
	answers `302` with a session cookie was losing that cookie on the way to
	the page it redirected to. The cookie was read off the wire and then
	dropped with the rest of the response headers when the next hop reset
	them.

	@see `crossbyte.url.URLRequest.manageCookies`, which turns this on and off.
**/
@:noCompletion
class CookieJar {
	private var __cookies:Map<String, StoredCookie> = new Map();

	public function new() {}

	/**
		Records the `Set-Cookie` lines of a response served by `host`.

		`Http` joins repeated `Set-Cookie` headers with a newline rather than a
		comma, because a cookie's own `Expires` attribute contains commas and
		folding them together makes the pair unparseable.
	**/
	public function store(setCookie:Null<String>, host:Null<String>):Void {
		if (setCookie == null || host == null) {
			return;
		}

		for (line in setCookie.split("\n")) {
			__storeOne(line, host);
		}
	}

	/**
		The `Cookie` header value for a request to `host`, or `null` when there
		is nothing to send.

		@param secure Whether the request travels over TLS. A cookie marked
			   `Secure` is withheld from a plaintext request, which is the
			   single attribute here that exists to stop a credential leaking.
	**/
	public function headerFor(host:Null<String>, secure:Bool):Null<String> {
		if (host == null) {
			return null;
		}

		var parts:Array<String> = [];

		for (name => cookie in __cookies) {
			// Same host or nothing. A redirect that leaves the site it came
			// from leaves the cookies behind, which is the conservative
			// direction and the only one that needs no domain rules to be
			// safe.
			if (cookie.host != host) {
				continue;
			}

			if (cookie.secure && !secure) {
				continue;
			}

			parts.push(name + "=" + cookie.value);
		}

		return parts.length > 0 ? parts.join("; ") : null;
	}

	private function __storeOne(line:String, host:String):Void {
		var attributes:Array<String> = line.split(";");
		if (attributes.length == 0) {
			return;
		}

		var pair:String = StringTools.trim(attributes[0]);
		var eq:Int = pair.indexOf("=");
		// A name with no value is not a cookie. `=value` is not one either:
		// an empty name would then collide with every other empty name.
		if (eq <= 0) {
			return;
		}

		var name:String = StringTools.trim(pair.substr(0, eq));
		var value:String = StringTools.trim(pair.substr(eq + 1));
		if (name.length == 0) {
			return;
		}

		var secure:Bool = false;
		var expired:Bool = false;

		for (i in 1...attributes.length) {
			var attribute:String = StringTools.trim(attributes[i]);
			var lower:String = attribute.toLowerCase();

			if (lower == "secure") {
				secure = true;
				continue;
			}

			// `Max-Age=0` is how a server deletes a cookie, and it is the one
			// expiry form that needs no date parsing to read. `Expires` is not
			// honoured: within a single request there is no clock worth
			// speaking of between the response that sets a cookie and the hop
			// that sends it back.
			if (StringTools.startsWith(lower, "max-age=")) {
				var age:Null<Int> = Std.parseInt(StringTools.trim(attribute.substr(8)));
				if (age != null && age <= 0) {
					expired = true;
				}
			}
		}

		if (expired) {
			__cookies.remove(name);
			return;
		}

		__cookies.set(name, {value: value, host: host, secure: secure});
	}
}

private typedef StoredCookie = {
	var value:String;
	var host:String;
	var secure:Bool;
}
