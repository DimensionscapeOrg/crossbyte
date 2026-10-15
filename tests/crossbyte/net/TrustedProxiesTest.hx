package crossbyte.net;

import utest.Assert;

/**
	`TrustedProxies`: the client's address through `Forwarded` and
	`X-Forwarded-For`, believed only as far as trusted proxies wrote them.
**/
class TrustedProxiesTest extends utest.Test {
	public function testTheClientIsTheRightMostHopNotTrusted():Void {
		var proxies = new TrustedProxies(["loopback", "10.0.0.0/8", "fd00::/8", "203.0.113.7"]);
		// [peer, Forwarded, X-Forwarded-For, the client]
		var cases:Array<Array<Null<String>>> = [
			// A peer not trusted is the client, whatever it says.
			["198.51.100.4", null, "1.2.3.4", "198.51.100.4"],
			["198.51.100.4", "for=1.2.3.4", null, "198.51.100.4"],
			// A trusted peer with nothing to say is the client.
			["10.0.0.1", null, null, "10.0.0.1"],
			// Read from the right, past trusted hops.
			["10.0.0.1", null, "198.51.100.9", "198.51.100.9"],
			["10.0.0.1", null, "6.6.6.6, 198.51.100.9, 10.0.0.2", "198.51.100.9"],
			["203.0.113.7", null, "198.51.100.9 , 127.0.0.1", "198.51.100.9"],
			// Every hop trusted: the farthest.
			["10.0.0.1", null, "10.0.0.3, 10.0.0.2", "10.0.0.3"],
			// Ports and brackets are not part of the address.
			["10.0.0.1", null, "198.51.100.9:5050", "198.51.100.9"],
			["10.0.0.1", null, "[2001:db8::17]:4711", "2001:db8::17"],
			// IPv6, and an IPv4 block matching a dual-stack peer.
			["fd00::1", null, "2001:db8::17", "2001:db8::17"],
			["::ffff:10.0.0.1", null, "198.51.100.9", "198.51.100.9"],
			["::1", null, "198.51.100.9", "198.51.100.9"],
			// RFC 7239, which wins over X-Forwarded-For.
			["10.0.0.1", "for=192.0.2.60;proto=http;by=203.0.113.43", null, "192.0.2.60"],
			["10.0.0.1", "for=192.0.2.60, for=\"[2001:db8:cafe::17]:4711\"", null, "2001:db8:cafe::17"],
			["10.0.0.1", "For=\"192.0.2.43:47011\", for=10.0.0.9", null, "192.0.2.43"],
			["10.0.0.1", "for=192.0.2.60", "6.6.6.6", "192.0.2.60"],
			// What names no address ends the chain at the proxy that said it.
			["10.0.0.1", "for=unknown", null, "10.0.0.1"],
			["10.0.0.1", "for=_hidden, for=10.0.0.5", null, "10.0.0.5"],
			["10.0.0.1", null, "not-an-address", "10.0.0.1"],
			["10.0.0.1", null, "198.51.100.9:99999", "10.0.0.1"],
			// A header that cannot be read is no chain at all.
			["10.0.0.1", "for=\"192.0.2.60", null, "10.0.0.1"],
			["10.0.0.1", "proto=http", null, "10.0.0.1"],
		];
		for (c in cases) {
			Assert.equals(c[3], proxies.clientAddress(c[0], c[1], c[2]), 'peer ${c[0]}, Forwarded ${c[1]}, X-Forwarded-For ${c[2]}');
		}
	}

	public function testTrustIsByAddressAndBlock():Void {
		var proxies = new TrustedProxies(["uniquelocal", "2001:db8::/32", "198.51.100.1"]);
		Assert.isTrue(proxies.trusts("172.31.255.255"));
		Assert.isFalse(proxies.trusts("172.32.0.0"));
		Assert.isTrue(proxies.trusts("192.168.1.1"));
		Assert.isTrue(proxies.trusts("fc00::5"));
		Assert.isTrue(proxies.trusts("2001:db8:ffff::1"));
		Assert.isFalse(proxies.trusts("2001:db9::1"));
		Assert.isTrue(proxies.trusts("198.51.100.1"));
		Assert.isFalse(proxies.trusts("198.51.100.2"));
		Assert.isFalse(proxies.trusts("not an address"));
		Assert.isFalse(new TrustedProxies([]).trusts("127.0.0.1"));
		for (bad in ["not-an-ip", "10.0.0.0/33", "::/129", "10.0.0/8", "loopbackish", ""]) {
			Assert.raises(() -> new TrustedProxies([bad]), crossbyte.errors.ArgumentError, '"$bad" was taken as a proxy');
		}
	}
}
