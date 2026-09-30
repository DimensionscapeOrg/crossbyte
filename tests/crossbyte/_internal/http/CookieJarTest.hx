package crossbyte._internal.http;

import crossbyte.test.Require;
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

	public function testHostsMatchWhateverTheirCase():Void {
		// Host names are case-insensitive, and the jar compared them exactly:
		// a redirect that changed only the host's case kept the caller's
		// credentials, Http compares origins lowercased, and dropped the
		// session cookie.
		var jar = new CookieJar();
		jar.store("session=abc123", "Example.COM");

		Assert.equals("session=abc123", jar.headerFor("example.com", false));
		Assert.equals("session=abc123", jar.headerFor("EXAMPLE.com", false));
	}

	public function testOneNameFromTwoHostsIsKeptForEach():Void {
		// Keyed by name alone, the second host's cookie replaced the first's,
		// so going back to the first host sent nothing.
		var jar = new CookieJar();
		jar.store("session=from-a", "a.example");
		jar.store("session=from-b", "b.example");

		Assert.equals("session=from-a", jar.headerFor("a.example", false));
		Assert.equals("session=from-b", jar.headerFor("b.example", false));
	}

	public function testCookiesGoBackInTheOrderTheyWereSet():Void {
		// They came back in a map's iteration order, which differs by target.
		var jar = new CookieJar();
		for (name in ["zeta", "alpha", "mid", "beta"]) {
			jar.store(name + "=1", "example.com");
		}
		Assert.equals("zeta=1; alpha=1; mid=1; beta=1", jar.headerFor("example.com", false));
	}

	public function testAHostKeepsABoundedNumberOfCookiesTheNewestFirst():Void {
		// Nothing bounded the jar: a server could set as many cookies as it
		// cared to send, and every request read through all of them.
		var jar = new CookieJar();
		for (i in 0...500) {
			jar.store("c" + i + "=1", "example.com");
		}
		var header:Null<String> = jar.headerFor("example.com", false);
		Require.notNull(header);
		var parts:Array<String> = header.split("; ");
		// 180, as a browser keeps: CookieJar.MAX_COOKIES_PER_HOST.
		Assert.equals(180, parts.length);
		// The oldest went to make room.
		Assert.equals("c320=1", parts[0]);
		Assert.equals("c499=1", parts[parts.length - 1]);
	}

	public function testAnOversizedCookieIsIgnored():Void {
		var jar = new CookieJar();
		var big:StringBuf = new StringBuf();
		for (_ in 0...5000) {
			big.add("x");
		}
		jar.store("big=" + big.toString(), "example.com");
		jar.store("small=1", "example.com");
		var header:Null<String> = jar.headerFor("example.com", false);
		Assert.isTrue(header == "small=1", "a 5,000 character cookie was kept: " + (header == null ? "null" : header.length + " characters"));
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

	public function testMaxAgeIsReadTheSameOnEveryTarget():Void {
		// Std.parseInt made 4294967296 a zero on Linux native, deleting a
		// cookie meant to last a century, and threw out of the request on
		// the jvm. Digits past an Int are still a number; text is ignored.
		var jar = new CookieJar();
		jar.store("long=1; Max-Age=4294967296", "example.com");
		jar.store("longer=1; Max-Age=99999999999999999999", "example.com");
		jar.store("junk=1; Max-Age=abc", "example.com");
		jar.store("signed=1; Max-Age=+5", "example.com");
		var kept:String = jar.headerFor("example.com", false);
		Require.notNull(kept, "every cookie was deleted");
		Assert.isTrue(kept.indexOf("long=1") >= 0, "a Max-Age past an Int deleted the cookie: " + kept);
		Assert.isTrue(kept.indexOf("longer=1") >= 0, kept);
		Assert.isTrue(kept.indexOf("junk=1") >= 0, "an unreadable Max-Age was not ignored: " + kept);
		Assert.isTrue(kept.indexOf("signed=1") >= 0, kept);

		jar.store("long=; Max-Age=-1", "example.com");
		jar.store("longer=; Max-Age=-99999999999999999999", "example.com");
		jar.store("junk=; Max-Age=00", "example.com");
		kept = jar.headerFor("example.com", false);
		Require.notNull(kept);
		Assert.isTrue(kept.indexOf("long=") < 0, "a negative Max-Age did not delete: " + kept);
		Assert.isTrue(kept.indexOf("longer=") < 0, "a negative Max-Age past an Int did not delete: " + kept);
		Assert.isTrue(kept.indexOf("junk=") < 0, "Max-Age=00 did not delete: " + kept);
		Assert.equals("signed=1", kept);
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

	public function testACookieCarryingAControlCharacterIsIgnored():Void {
		// It goes back out in a Cookie header, and a lone CR there is a line
		// break to some servers: a cookie could add a header to every request
		// after it. RFC 6265bis 5.6 ignores such a line whole.
		var jar = new CookieJar();
		jar.store("a=1" + String.fromCharCode(13) + "Injected: yes", "example.com");
		jar.store("b=2" + String.fromCharCode(0), "example.com");
		jar.store("c=3; Path=/" + String.fromCharCode(1), "example.com");
		jar.store("d=4" + String.fromCharCode(9) + "tab", "example.com");

		// Compared rather than printed: a NUL in an assertion message hides
		// every failure reported after it on hxcpp.
		var header:Null<String> = jar.headerFor("example.com", false);
		Assert.isTrue(header == "d=4" + String.fromCharCode(9) + "tab", "a cookie carrying a control character was kept: " + __visible(header));
	}

	private static function __visible(text:Null<String>):String {
		if (text == null) {
			return "null";
		}
		var out:StringBuf = new StringBuf();
		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			if (code < 32 || code == 127) {
				out.add("<" + StringTools.hex(code, 2) + ">");
			} else {
				out.addChar(code);
			}
		}
		return out.toString();
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
