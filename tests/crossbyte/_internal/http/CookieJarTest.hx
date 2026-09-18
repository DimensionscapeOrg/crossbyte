package crossbyte._internal.http;

import utest.Assert;

/**
 * The rules `CookieJar` exists to keep.
 *
 * Every one of these is a way a cookie jar hands a credential to somewhere it
 * should not, which is why this jar is as small as it is: it has no `Domain`
 * attribute, no path matching and no persistence, so those cannot go wrong.
 * What is left is host, `Secure`, and deletion, and those are here.
 */
class CookieJarTest extends utest.Test {
	public function testACookieGoesBackToTheHostThatSetIt():Void {
		var jar = new CookieJar();
		jar.store("session=abc123; Path=/; HttpOnly", "example.com");

		Assert.equals("session=abc123", jar.headerFor("example.com", false));
	}

	public function testACookieIsNotSentToAnotherHost():Void {
		var jar = new CookieJar();
		jar.store("session=abc123", "example.com");

		// The redirect that leaves the site leaves the cookie behind. Getting
		// this wrong is how a session token reaches somebody else's server.
		Assert.isNull(jar.headerFor("evil.example", false));
		Assert.isNull(jar.headerFor("sub.example.com", false), "a subdomain is not the host that set it");
		Assert.isNull(jar.headerFor("example.com.evil.test", false), "a suffix match is not a host match");
	}

	public function testASecureCookieIsWithheldFromAPlaintextHop():Void {
		var jar = new CookieJar();
		jar.store("session=abc123; Secure", "example.com");

		Assert.isNull(jar.headerFor("example.com", false), "a Secure cookie went out over plaintext");
		Assert.equals("session=abc123", jar.headerFor("example.com", true));
	}

	public function testSecureIsReadWhateverItsCase():Void {
		var jar = new CookieJar();
		jar.store("a=1; secure", "example.com");
		jar.store("b=2; SECURE", "example.com");

		Assert.isNull(jar.headerFor("example.com", false));
	}

	public function testMaxAgeZeroDeletesTheCookie():Void {
		var jar = new CookieJar();
		jar.store("session=abc123", "example.com");
		Assert.equals("session=abc123", jar.headerFor("example.com", false));

		// How a server signs you out mid-chain.
		jar.store("session=; Max-Age=0", "example.com");
		Assert.isNull(jar.headerFor("example.com", false));
	}

	public function testALaterValueReplacesAnEarlierOne():Void {
		var jar = new CookieJar();
		jar.store("session=first", "example.com");
		jar.store("session=second", "example.com");

		Assert.equals("session=second", jar.headerFor("example.com", false));
	}

	public function testRepeatedSetCookieHeadersAreAllKept():Void {
		// Http joins repeated Set-Cookie headers with a newline rather than a
		// comma, because a cookie's own Expires attribute contains a comma and
		// folding them together makes the pair unparseable.
		var jar = new CookieJar();
		jar.store("a=1; Path=/\nb=2; Expires=Wed, 09 Jun 2100 10:18:14 GMT\nc=3", "example.com");

		var header:String = jar.headerFor("example.com", false);
		Assert.notNull(header);
		Assert.isTrue(header.indexOf("a=1") >= 0, header);
		Assert.isTrue(header.indexOf("b=2") >= 0, "an Expires containing a comma lost its cookie: " + header);
		Assert.isTrue(header.indexOf("c=3") >= 0, header);
	}

	public function testNothingToSendIsNullRatherThanAnEmptyHeader():Void {
		var jar = new CookieJar();

		Assert.isNull(jar.headerFor("example.com", false));
		Assert.isNull(jar.headerFor(null, false));
	}

	public function testMalformedLinesAreIgnoredRatherThanStored():Void {
		var jar = new CookieJar();
		jar.store("", "example.com");
		jar.store("novalue", "example.com");
		jar.store("=orphaned", "example.com");
		jar.store("   ", "example.com");
		jar.store(null, "example.com");
		jar.store("a=1", null);

		Assert.isNull(jar.headerFor("example.com", false));
	}

	public function testAValueMayBeEmptyOrContainAnEqualsSign():Void {
		var jar = new CookieJar();
		// Base64 payloads end in '=' padding, and an empty value is legal.
		jar.store("token=YWJjZA==; Path=/", "example.com");
		jar.store("empty=", "example.com");

		var header:String = jar.headerFor("example.com", false);
		Assert.isTrue(header.indexOf("token=YWJjZA==") >= 0, header);
		Assert.isTrue(header.indexOf("empty=") >= 0, header);
	}
}
