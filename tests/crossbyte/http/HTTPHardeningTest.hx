package crossbyte.http;

import crossbyte._internal.http.HttpSyntax;
import utest.Assert;

/**
 * Hardening coverage for HTTP header injection, request smuggling and
 * unbounded chunked body accumulation.
 *
 * Against `HttpSyntax` rather than `Http`. These are the rules that hold on any
 * target, which is exactly why they were extracted out of the client -- but the
 * cases went on calling them through `Http`, and `Http` drives a raw socket with
 * its own TLS and so exists on no JavaScript target. So the extraction bought
 * nothing until this import changed: header injection and request smuggling
 * were unchecked on both the targets a page or a Node server would run on.
 */
class HTTPHardeningTest extends utest.Test {
	public function testSanitizeHeaderValueStripsCrLf():Void {
		var sanitized = HttpSyntax.sanitizeHeaderValue("x\r\nInjected: 1");

		Assert.equals("xInjected: 1", sanitized);
		Assert.isTrue(sanitized.indexOf("\r") == -1);
		Assert.isTrue(sanitized.indexOf("\n") == -1);
	}

	public function testSanitizeHeaderValueStripsBareCrAndLf():Void {
		Assert.equals("ab", HttpSyntax.sanitizeHeaderValue("a\rb"));
		Assert.equals("ab", HttpSyntax.sanitizeHeaderValue("a\nb"));
		Assert.equals("", HttpSyntax.sanitizeHeaderValue("\r\n"));
	}

	public function testSanitizeHeaderValueStripsControlCharsButKeepsTab():Void {
		// NUL and other C0 controls removed, horizontal tab preserved.
		Assert.equals("ab", HttpSyntax.sanitizeHeaderValue("a\x00b"));
		Assert.equals("a\tb", HttpSyntax.sanitizeHeaderValue("a\tb"));
		Assert.equals("plain value", HttpSyntax.sanitizeHeaderValue("plain value"));
	}

	public function testSanitizeHeaderValueHandlesNull():Void {
		Assert.equals("", HttpSyntax.sanitizeHeaderValue(null));
	}

	public function testSanitizeHeaderNameStripsCrLfControlAndColon():Void {
		// A name carrying CRLF + a smuggled name/colon collapses to a safe token.
		Assert.equals("X-SafeInjected", HttpSyntax.sanitizeHeaderName("X-Safe\r\nInjected"));
		Assert.equals("XEvil", HttpSyntax.sanitizeHeaderName("X\nEvil"));
		Assert.equals("ContentType", HttpSyntax.sanitizeHeaderName("Content:Type"));
	}

	public function testSanitizeHeaderNameStripsWhitespace():Void {
		Assert.equals("X-Foo", HttpSyntax.sanitizeHeaderName("X-Foo"));
		Assert.equals("X-Foo", HttpSyntax.sanitizeHeaderName("X- Foo"));
		Assert.equals("X-Foo", HttpSyntax.sanitizeHeaderName("X-\tFoo"));
	}

	public function testSanitizeHeaderNameHandlesNullAndEmpty():Void {
		Assert.equals("", HttpSyntax.sanitizeHeaderName(null));
		// A name made entirely of illegal characters yields an empty token,
		// signalling the caller to skip the header entirely.
		Assert.equals("", HttpSyntax.sanitizeHeaderName(":\r\n "));
	}

	public function testConflictingFramingIsRejected():Void {
		// Both Transfer-Encoding and Content-Length present -> smuggling vector.
		Assert.isTrue(HttpSyntax.hasConflictingFraming(true, true));
	}

	public function testNonConflictingFramingIsAccepted():Void {
		Assert.isFalse(HttpSyntax.hasConflictingFraming(true, false));
		Assert.isFalse(HttpSyntax.hasConflictingFraming(false, true));
		Assert.isFalse(HttpSyntax.hasConflictingFraming(false, false));
	}

	public function testChunkedBodyLimitDetectsOverflow():Void {
		Assert.isTrue(HttpSyntax.exceedsChunkedBodyLimit(90, 20, 100));
		Assert.isFalse(HttpSyntax.exceedsChunkedBodyLimit(80, 20, 100));
		// Exactly at the limit is allowed.
		Assert.isFalse(HttpSyntax.exceedsChunkedBodyLimit(0, 100, 100));
	}

	public function testChunkedBodyLimitDisabledWhenNonPositive():Void {
		Assert.isFalse(HttpSyntax.exceedsChunkedBodyLimit(1000, 1000, 0));
		Assert.isFalse(HttpSyntax.exceedsChunkedBodyLimit(1000, 1000, -1));
	}

	public function testRateLimiterReturns429AfterThreshold():Void {
		// Default token-bucket limiter allows a burst of 10 per client.
		var limiter = new RateLimiter();
		for (_ in 0...10) {
			Assert.isFalse(limiter.isRateLimited("203.0.113.7"));
		}
		Assert.isTrue(limiter.isRateLimited("203.0.113.7"));
		// A different client is unaffected.
		Assert.isFalse(limiter.isRateLimited("203.0.113.8"));
	}
}
