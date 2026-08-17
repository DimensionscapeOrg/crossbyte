package crossbyte._internal.net;

import utest.Assert;

/**
 * Canonical IPv6 text.
 *
 * The reason this exists: hxcpp renders the loopback address as `::1` and
 * the jvm renders it as `0:0:0:0:0:0:0:1`. An application comparing what
 * it bound against what it is told back works on one target and fails on
 * the other, which is how four jvm test failures sat unnoticed — nothing
 * in CI ran the jvm suite.
 */
class IPv6Test extends utest.Test {
	public function testExpandedLoopbackCompresses():Void {
		Assert.equals("::1", IPv6.compress("0:0:0:0:0:0:0:1"));
		Assert.equals("::", IPv6.compress("0:0:0:0:0:0:0:0"));
	}

	public function testAlreadyCompressedIsUnchanged():Void {
		Assert.equals("::1", IPv6.compress("::1"));
		Assert.equals("::", IPv6.compress("::"));
		Assert.equals("fe80::1", IPv6.compress("fe80::1"));
	}

	public function testLeadingZerosAreStrippedAndCaseLowered():Void {
		Assert.equals("2001:db8::1", IPv6.compress("2001:0DB8:0000:0000:0000:0000:0000:0001"));
		Assert.equals("2001:db8:0:1:1:1:1:1", IPv6.compress("2001:0db8:0000:0001:0001:0001:0001:0001"));
	}

	/**
	 * RFC 5952: `::` replaces the longest run, and the leftmost when two
	 * runs tie. A shorter run must be written out.
	 */
	public function testLongestZeroRunWinsAndSingleZeroIsWrittenOut():Void {
		// Runs of 1 then 3 — the longer one collapses.
		Assert.equals("2001:0:1::1", IPv6.compress("2001:0000:0001:0000:0000:0000:0000:0001"));
		// Two runs of 2, leftmost collapses.
		Assert.equals("1::1:0:0:1:1", IPv6.compress("0001:0000:0000:0001:0000:0000:0001:0001"));
		// A lone zero group stays written out rather than becoming `::`.
		Assert.equals("1:0:1:1:1:1:1:1", IPv6.compress("0001:0000:0001:0001:0001:0001:0001:0001"));
	}

	/**
	 * Anything that is not a plain eight-group literal comes back
	 * untouched. Mangling a hostname would be far worse than tolerating
	 * one platform's spelling.
	 */
	public function testNonIPv6InputIsLeftAlone():Void {
		Assert.equals("127.0.0.1", IPv6.compress("127.0.0.1"));
		Assert.equals("localhost", IPv6.compress("localhost"));
		Assert.equals("example.com", IPv6.compress("example.com"));
		Assert.equals("", IPv6.compress(""));
		Assert.isNull(IPv6.compress(null));
		// Wrong group count, so not something to rewrite.
		Assert.equals("1:2:3", IPv6.compress("1:2:3"));
		// Non-hex content.
		Assert.equals("zzzz:0:0:0:0:0:0:1", IPv6.compress("zzzz:0:0:0:0:0:0:1"));
		// An IPv4 tail is left exactly as written.
		Assert.equals("0:0:0:0:0:ffff:127.0.0.1", IPv6.compress("0:0:0:0:0:ffff:127.0.0.1"));
	}

	public function testZoneSuffixIsPreserved():Void {
		Assert.equals("fe80::1%eth0", IPv6.compress("fe80::1%eth0"));
	}

	/** Canonicalising an already-canonical address changes nothing. */
	public function testCompressIsIdempotent():Void {
		for (address in ["::1", "::", "fe80::1", "2001:db8::1", "1:0:1:1:1:1:1:1"]) {
			Assert.equals(address, IPv6.compress(IPv6.compress(address)));
		}
	}
}
