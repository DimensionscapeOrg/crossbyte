package crossbyte.http;

import crossbyte._internal.http.Http;
import utest.Assert;

/**
 * Hardening coverage for HTTP header injection, request smuggling and
 * unbounded chunked body accumulation. These exercise the pure decision
 * helpers so they run under the eval/interp target.
 */
class HTTPHardeningTest extends utest.Test {
	public function testSanitizeHeaderValueStripsCrLf():Void {
		var sanitized = Http.sanitizeHeaderValue("x\r\nInjected: 1");

		Assert.equals("xInjected: 1", sanitized);
		Assert.isTrue(sanitized.indexOf("\r") == -1);
		Assert.isTrue(sanitized.indexOf("\n") == -1);
	}

	public function testSanitizeHeaderValueStripsBareCrAndLf():Void {
		Assert.equals("ab", Http.sanitizeHeaderValue("a\rb"));
		Assert.equals("ab", Http.sanitizeHeaderValue("a\nb"));
		Assert.equals("", Http.sanitizeHeaderValue("\r\n"));
	}

	public function testSanitizeHeaderValueStripsControlCharsButKeepsTab():Void {
		// NUL and other C0 controls removed, horizontal tab preserved.
		Assert.equals("ab", Http.sanitizeHeaderValue("a\x00b"));
		Assert.equals("a\tb", Http.sanitizeHeaderValue("a\tb"));
		Assert.equals("plain value", Http.sanitizeHeaderValue("plain value"));
	}

	public function testSanitizeHeaderValueHandlesNull():Void {
		Assert.equals("", Http.sanitizeHeaderValue(null));
	}

	public function testSanitizeHeaderNameStripsCrLfControlAndColon():Void {
		// A name carrying CRLF + a smuggled name/colon collapses to a safe token.
		Assert.equals("X-SafeInjected", Http.sanitizeHeaderName("X-Safe\r\nInjected"));
		Assert.equals("XEvil", Http.sanitizeHeaderName("X\nEvil"));
		Assert.equals("ContentType", Http.sanitizeHeaderName("Content:Type"));
	}

	public function testSanitizeHeaderNameStripsWhitespace():Void {
		Assert.equals("X-Foo", Http.sanitizeHeaderName("X-Foo"));
		Assert.equals("X-Foo", Http.sanitizeHeaderName("X- Foo"));
		Assert.equals("X-Foo", Http.sanitizeHeaderName("X-\tFoo"));
	}

	public function testSanitizeHeaderNameHandlesNullAndEmpty():Void {
		Assert.equals("", Http.sanitizeHeaderName(null));
		// A name made entirely of illegal characters yields an empty token,
		// signalling the caller to skip the header entirely.
		Assert.equals("", Http.sanitizeHeaderName(":\r\n "));
	}

	public function testConflictingFramingIsRejected():Void {
		// Both Transfer-Encoding and Content-Length present -> smuggling vector.
		Assert.isTrue(Http.hasConflictingFraming(true, true));
	}

	public function testNonConflictingFramingIsAccepted():Void {
		Assert.isFalse(Http.hasConflictingFraming(true, false));
		Assert.isFalse(Http.hasConflictingFraming(false, true));
		Assert.isFalse(Http.hasConflictingFraming(false, false));
	}

	public function testChunkedBodyLimitDetectsOverflow():Void {
		Assert.isTrue(Http.exceedsChunkedBodyLimit(90, 20, 100));
		Assert.isFalse(Http.exceedsChunkedBodyLimit(80, 20, 100));
		// Exactly at the limit is allowed.
		Assert.isFalse(Http.exceedsChunkedBodyLimit(0, 100, 100));
	}

	public function testChunkedBodyLimitDisabledWhenNonPositive():Void {
		Assert.isFalse(Http.exceedsChunkedBodyLimit(1000, 1000, 0));
		Assert.isFalse(Http.exceedsChunkedBodyLimit(1000, 1000, -1));
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
