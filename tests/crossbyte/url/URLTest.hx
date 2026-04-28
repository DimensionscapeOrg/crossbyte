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

	@:noCompletion private static function throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
