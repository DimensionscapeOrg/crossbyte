package crossbyte.http;

import crossbyte.net.RateLimiter;
import crossbyte._internal.http.HttpSyntax;
import crossbyte.test.Require;
import utest.Assert;

/**
 * Hardening coverage for HTTP header injection, request smuggling and
 * unbounded chunked body accumulation.
 *
 * Against `HttpSyntax` rather than `Http`. These are the rules that hold on any
 * target, which is exactly why they were extracted out of the client, but the
 * cases went on calling them through `Http`, and `Http` drives a raw socket with
 * its own TLS and so exists on no JavaScript target. So the extraction bought
 * nothing until this import changed: header injection and request smuggling
 * were unchecked on both the targets a page or a Node server would run on.
 */
@:access(crossbyte.http.HTTPRequestHandler)
class HTTPHardeningTest extends utest.Test {
	/**
		The server's `Content-Length` reader gives the same answer on every
		target, and never a small number for a large one.

		4294967296 is 2^32: `Std.parseInt` read it as 0 on Linux and macOS
		native, as 2147483647 on Windows native, threw on the jvm and gave
		null on eval, and the checks around it were right on none of them.
	**/
	public function testContentLengthPastAnIntIsNotALength():Void {
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength("4294967296"));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength("4294967396"));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength("2147483648"));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength("18446744073709551616"));
		Assert.equals(2147483647, HTTPRequestHandler.__parseContentLength("2147483647"));
	}

	public function testContentLengthReadsOnlyPlainDigits():Void {
		Assert.equals(0, HTTPRequestHandler.__parseContentLength("0"));
		Assert.equals(42, HTTPRequestHandler.__parseContentLength(" 42 "));
		Assert.equals(7, HTTPRequestHandler.__parseContentLength("007"));
		Assert.equals(5, HTTPRequestHandler.__parseContentLength("5, 5"));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength("5, 6"));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength("+5"));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength("-1"));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength("0x10"));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength("1 2"));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength(""));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength("5,"));
		Assert.equals(-1, HTTPRequestHandler.__parseContentLength(null));
	}

	/**
		A byte range is read the same on every target. `bytes=4294967296-`
		was a range from 0 on Linux native and threw on the jvm.
	**/
	public function testRangePastAnIntIsReadAsAHugeNumber():Void {
		// A start past every file is unsatisfiable...
		Assert.isNull(HTTPRequestHandler.__parseRange("bytes=4294967296-", 100));
		Assert.isNull(HTTPRequestHandler.__parseRange("bytes=4294967296-4294967300", 100));
		// ...an end or a suffix past it covers the whole file (RFC 9110 14.1.2).
		__range(0, 99, HTTPRequestHandler.__parseRange("bytes=0-4294967296", 100));
		__range(0, 99, HTTPRequestHandler.__parseRange("bytes=-4294967296", 100));
	}

	public function testRangeKeepsItsOrdinaryAnswers():Void {
		__range(5, 99, HTTPRequestHandler.__parseRange("bytes=5-", 100));
		__range(90, 99, HTTPRequestHandler.__parseRange("bytes=-10", 100));
		__range(0, 0, HTTPRequestHandler.__parseRange("bytes=0-0", 100));
		__range(10, 20, HTTPRequestHandler.__parseRange(" bytes=10-20 ", 100));
		__range(0, 1, HTTPRequestHandler.__parseRange("BYTES=0-1", 100));
		Assert.isNull(HTTPRequestHandler.__parseRange("bytes=10-5", 100));
		Assert.isNull(HTTPRequestHandler.__parseRange("bytes=100-", 100));
		Assert.isNull(HTTPRequestHandler.__parseRange("bytes=-0", 100));
		Assert.isNull(HTTPRequestHandler.__parseRange("bytes=-", 100));
		Assert.isNull(HTTPRequestHandler.__parseRange("bytes=+5-10", 100));
		Assert.isNull(HTTPRequestHandler.__parseRange("bytes=0-1,5-6", 100));
		Assert.isNull(HTTPRequestHandler.__parseRange("items=0-1", 100));
		// Nothing of an empty file can be satisfied.
		Assert.isNull(HTTPRequestHandler.__parseRange("bytes=-5", 0));
	}

	public function testHttpDateIsReadByPosition():Void {
		var time:Null<Float> = HTTPRequestHandler.__parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT");
		Require.notNull(time);
		Assert.equals(784111777000.0, time);
		Assert.notNull(HTTPRequestHandler.__parseHttpDate("  Sun, 06 Nov 1994 08:49:37 GMT  "));
		Assert.isNull(HTTPRequestHandler.__parseHttpDate("Sun, 32 Nov 1994 08:49:37 GMT"));
		Assert.isNull(HTTPRequestHandler.__parseHttpDate("Sun, 06 Nov 1994 24:49:37 GMT"));

		Assert.isNull(HTTPRequestHandler.__parseHttpDate("Sun, 06 Foo 1994 08:49:37 GMT"));
		Assert.isNull(HTTPRequestHandler.__parseHttpDate("Sun, 06 Nov 1994 08:49:37 UTC"));
		Assert.isNull(HTTPRequestHandler.__parseHttpDate("Sun, 6 Nov 1994 08:49:37 GMT"));
		Assert.isNull(HTTPRequestHandler.__parseHttpDate("Sun, +6 Nov 1994 08:49:37 GMT"));
		Assert.isNull(HTTPRequestHandler.__parseHttpDate("Sunday, 06-Nov-94 08:49:37 GMT"));
		Assert.isNull(HTTPRequestHandler.__parseHttpDate(""));
	}

	/**
		An HTTP date is read and written in UTC by arithmetic, the same on
		every target and in every time zone, past 2038 included. Both went
		through a local `Date`: neko keeps its time in 32 bits, so 2100 read
		back as a date long gone there, and the local offset was taken at one
		instant and applied at another, an hour out around a daylight-saving
		change.
	**/
	public function testHttpDatesRoundTripPast2038():Void {
		var cases:Array<{text:String, time:Float}> = [
			{text: "Thu, 01 Jan 1970 00:00:00 GMT", time: 0.0},
			{text: "Sun, 06 Nov 1994 08:49:37 GMT", time: 784111777000.0},
			{text: "Tue, 29 Feb 2000 12:00:00 GMT", time: 951825600000.0},
			{text: "Tue, 19 Jan 2038 03:14:08 GMT", time: 2147483648000.0},
			{text: "Fri, 01 Jan 2100 00:00:00 GMT", time: 4102444800000.0},
			// Hours either side of the daylight-saving changes in the United
			// States (10 March) and Europe (31 March) that year.
			{text: "Sun, 10 Mar 2024 04:30:00 GMT", time: 1710045000000.0},
			{text: "Sun, 31 Mar 2024 01:30:00 GMT", time: 1711848600000.0}
		];
		for (item in cases) {
			Assert.equals(item.time, HTTPRequestHandler.__parseHttpDate(item.text), item.text);
			Assert.equals(item.text, HTTPRequestHandler.__toHttpDate(item.time));
		}
		// Within a second, as a header is: the milliseconds are dropped.
		Assert.equals("Sun, 06 Nov 1994 08:49:37 GMT", HTTPRequestHandler.__toHttpDate(784111777999.0));
	}

	private static function __range(start:Int, end:Int, range:{start:Int, end:Int}, ?pos:haxe.PosInfos):Void {
		if (range == null) {
			Assert.fail("expected " + start + "-" + end + ", got no range", pos);
			return;
		}
		Assert.equals(start, range.start, pos);
		Assert.equals(end, range.end, pos);
	}

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
		//
		// The NUL is made at run time. HashLink reads a string constant up to
		// its first NUL and no further, so on hl "a\x00b" was an "a" with two
		// characters of whatever lay past HashLink's copy of it, NULs, here,
		// and the case failed with the "b" never having been there.
		Assert.equals("ab", HttpSyntax.sanitizeHeaderValue("a" + String.fromCharCode(0) + "b"));
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
