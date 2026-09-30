package crossbyte.url;

import utest.Assert;

class URLTest extends utest.Test {
	public function testParsesDefaultPortsAndReferenceParts():Void {
		var url = new URL("http://example.com/path/to/file?x=1#top");

		Assert.equals("http", url.scheme);
		Assert.isFalse(url.ssl);
		Assert.equals("example.com", url.host);
		Assert.equals(80, url.port);
		Assert.equals("/path/to/file", url.path);
		Assert.equals("x=1", url.query);
		Assert.equals("top", url.fragment);
	}

	public function testNormalizesSchemeCaseForSslAndDefaultPort():Void {
		var url = new URL("HTTPS://example.com");

		Assert.equals("https", url.scheme);
		Assert.isTrue(url.ssl);
		Assert.equals(443, url.port);
		Assert.equals("/", url.path);
	}

	public function testParsesIpv6LiteralWithPort():Void {
		var url = new URL("http://[::1]:8080/socket?debug=true");

		Assert.equals("::1", url.host);
		Assert.equals(8080, url.port);
		Assert.equals("/socket", url.path);
		Assert.equals("debug=true", url.query);
	}

	public function testParsesQueryAndFragmentWithoutExplicitPath():Void {
		var url = new URL("http://example.com?x=1#frag");

		Assert.equals("/", url.path);
		Assert.equals("x=1", url.query);
		Assert.equals("frag", url.fragment);
	}

	public function testRejectsMalformedUrls():Void {
		Assert.isTrue(throws(() -> new URL("http:///missing-host")));
		Assert.isTrue(throws(() -> new URL("1http://example.com")));
		Assert.isTrue(throws(() -> new URL("http://example.com:abc")));
		Assert.isTrue(throws(() -> new URL("http://example.com:65536")));
		Assert.isTrue(throws(() -> new URL("http://user@example.com/")));
		Assert.isTrue(throws(() -> new URL("http://::1/")));
	}

	public function testParsesExplicitPort():Void {
		var url = new URL("http://host:8080/path");

		Assert.equals("host", url.host);
		Assert.equals(8080, url.port);
		Assert.equals("/path", url.path);
	}

	public function testRejectsOverflowingPort():Void {
		// A 10+ digit port can wrap into the valid 0-65535 range when parsed
		// with fixed-width integers; it must be rejected as malformed.
		Assert.isTrue(throws(() -> new URL("http://host:99999999999/")));
	}

	public function testRejectsTooLongButInRangePort():Void {
		// Six digits that happen to parse within range must still be rejected
		// because the raw text is longer than any valid port.
		Assert.isTrue(throws(() -> new URL("http://host:000080/")));
	}

	public function testPortBoundsAndSpelling():Void {
		Assert.equals(65535, new URL("http://host:65535/").port);
		Assert.equals(1, new URL("http://host:1/").port);
		Assert.isTrue(throws(() -> new URL("http://host:65536/")), "a port past 65535 was accepted");
		Assert.isTrue(throws(() -> new URL("http://host:4294967376/")), "a port that wraps to 80 was accepted");
		Assert.isTrue(throws(() -> new URL("http://host:080/")), "a leading zero was accepted");
		Assert.isTrue(throws(() -> new URL("http://host:+80/")), "a signed port was accepted");
		Assert.isTrue(throws(() -> new URL("http://host:8 0/")), "a port with a space was accepted");
	}

	public function testControlCharactersAreRefused():Void {
		// The client writes the path, query and host into the request as they
		// are, so a CR or LF here ended the request line and started a header
		// of the URL's choosing: "http://host/a\r\nX-Injected: evil" did just
		// that on the wire. Built from char codes so the test does not depend
		// on how this file's line endings were checked out.
		var cr:String = String.fromCharCode(13);
		var lf:String = String.fromCharCode(10);
		for (control in [cr, lf, cr + lf, String.fromCharCode(0), String.fromCharCode(9), String.fromCharCode(31), String.fromCharCode(127)]) {
			var shown:String = StringTools.hex(StringTools.fastCodeAt(control, 0), 2);
			Assert.isTrue(throws(() -> new URL("http://host/a" + control + "X-Injected: evil")), "a control character (" + shown + ") in the path was kept");
			Assert.isTrue(throws(() -> new URL("http://host/p?x=1" + control + "Evil: 1")), "a control character (" + shown + ") in the query was kept");
			Assert.isTrue(throws(() -> new URL("http://ho" + control + "st.com/a")), "a control character (" + shown + ") in the host was kept");
			Assert.isTrue(throws(() -> new URL("http://host/a#frag" + control)), "a control character (" + shown + ") in the fragment was kept");
		}
		Assert.isTrue(throws(() -> new URL("http://ho st/a")), "a space in the host was kept");
		Assert.isTrue(throws(() -> new URL("http://host :80/a")), "a space in the authority was kept");

		// A space in the path is not the URL's to refuse: the client encodes
		// it on the way out, as a browser would.
		Assert.equals("/a b", new URL("http://host/a b").path);
	}

	@:noCompletion private static function throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
