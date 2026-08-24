package crossbyte.net;

// `LocalAddress` is absent on the browser, along with the rest of the UDP
// family, so there is nothing here to run there and nothing to assert about.
// Node is a different matter and does run these -- `JsTestMain` registers
// them, the way it registers the server suite the browser also cannot have.
#if !(js && !nodejs)
import utest.Assert;
import utest.Async;

/**
	These need no network and no peer. The routing table is local, and asking it
	sends nothing -- so every case here is deterministic on a machine that is
	entirely offline, and none of them depend on what this machine's addresses
	happen to be.
**/
class LocalAddressTest extends utest.Test {
	/**
		The one thing a support flag exists to do.

		Not a tautology: `DatagramSocket.isSupported` said `true` on neko and
		then threw "Not available on this platform" from the constructor, so a
		caller that checked it had already been told the only lie that mattered.
		This case is what catches that happening again on any target -- it does
		not care which answer is right, only that the flag and the behaviour
		agree.
	**/
	@:timeout(4000)
	public function testSupportIsReportedHonestly(async:Async):Void {
		LocalAddress.primary().then(function(address) {
			Assert.isTrue(LocalAddress.isSupported, "an address came back on a target that reports no support: " + address);
			async.done();
		}, function(error) {
			// A target without UDP has to fail. What it must not do is throw
			// out of the call or never answer at all, and arriving here at all
			// proves it did neither.
			Assert.isFalse(LocalAddress.isSupported, "the lookup failed on a target that claims support: " + error);
			Assert.notNull(error);
			async.done();
		});
	}

	/**
		The promise the class makes.

		A wildcard answer would mean the socket never committed to an interface,
		which leaves the caller exactly where it started -- holding an address
		no peer can dial.
	**/
	@:timeout(4000)
	public function testTheAnswerIsNeverTheWildcard(async:Async):Void {
		if (!LocalAddress.isSupported) {
			Assert.isFalse(LocalAddress.isSupported);
			async.done();
			return;
		}

		LocalAddress.primary().then(function(address) {
			Assert.notEquals("0.0.0.0", address);
			Assert.notEquals("::", address);
			Assert.isTrue(address != null && address.length > 0, "an empty address is not an address");
			async.done();
		}, function(error) {
			Assert.fail("no route to the documentation range, which means no default route at all: " + error);
			async.done();
		});
	}

	/**
		Loopback routes to loopback, on every operating system.

		This is the case that proves the routing table is genuinely being
		consulted. A stub that returned the machine's LAN address regardless
		would pass every other assertion here and fail this one.
	**/
	@:timeout(4000)
	public function testLoopbackRoutesToLoopback(async:Async):Void {
		if (!LocalAddress.isSupported) {
			Assert.isFalse(LocalAddress.isSupported);
			async.done();
			return;
		}

		LocalAddress.forDestination("127.0.0.1").then(function(address) {
			Assert.equals("127.0.0.1", address);
			async.done();
		}, function(error) {
			Assert.fail("no route to loopback: " + error);
			async.done();
		});
	}

	/**
		The same question in IPv6, which needs a socket of the other family.

		Machine-independent in the only way it can be: a host with no IPv6 stack
		has no route to `::1` and says so, which is a real network condition and
		not a wrong answer. What it must not do is hang or throw, and arriving in
		either branch proves it did neither.
	**/
	@:timeout(4000)
	public function testIPv6LoopbackRoutesToIPv6Loopback(async:Async):Void {
		if (!LocalAddress.isSupported) {
			Assert.isFalse(LocalAddress.isSupported);
			async.done();
			return;
		}

		LocalAddress.forDestination("::1").then(function(address) {
			Assert.equals("::1", address);
			async.done();
		}, function(error) {
			Assert.notNull(error);
			async.done();
		});
	}

	/**
		Two destinations, two answers.

		The other half of the same proof: loopback and the outside world are
		reached on different interfaces, so a per-destination lookup must
		distinguish them. A machine with no route out fails `primary()` instead,
		which the error branch accepts -- that is a real network condition, not
		a wrong answer.
	**/
	@:timeout(6000)
	public function testTheRoutingTableIsConsultedPerDestination(async:Async):Void {
		if (!LocalAddress.isSupported) {
			Assert.isFalse(LocalAddress.isSupported);
			async.done();
			return;
		}

		LocalAddress.forDestination("127.0.0.1").then(function(loopback) {
			LocalAddress.primary().then(function(outward) {
				Assert.notEquals(loopback, outward, "loopback and the default route came back on the same interface, so nothing was actually looked up");
				async.done();
			}, function(_) {
				// No route out. Nothing to compare against, and nothing wrong.
				Assert.equals("127.0.0.1", loopback);
				async.done();
			});
		}, function(error) {
			Assert.fail("no route to loopback: " + error);
			async.done();
		});
	}

	/**
		A name is refused rather than resolved.

		Resolving one blocks on sys targets and needs a callback on Node, so
		accepting names would make the same call cheap on one target and
		expensive on another. Refusing is the honest option, and the refusal has
		to arrive through the future like every other failure.
	**/
	@:timeout(4000)
	public function testANameIsRefused(async:Async):Void {
		LocalAddress.forDestination("stun.example.com").then(function(address) {
			Assert.fail("a hostname was accepted and answered with " + address);
			async.done();
		}, function(error) {
			Assert.notNull(error);
			Assert.isTrue(error.indexOf("numeric") >= 0, "the refusal does not say what was wrong with the argument: " + error);
			async.done();
		});
	}

	@:timeout(4000)
	public function testAnEmptyDestinationIsRefused(async:Async):Void {
		LocalAddress.forDestination("").then(function(address) {
			Assert.fail("an empty destination was accepted and answered with " + address);
			async.done();
		}, function(error) {
			Assert.notNull(error);
			async.done();
		});
	}

	@:timeout(4000)
	public function testANullDestinationIsRefused(async:Async):Void {
		LocalAddress.forDestination(null).then(function(address) {
			Assert.fail("a null destination was accepted and answered with " + address);
			async.done();
		}, function(error) {
			Assert.notNull(error);
			async.done();
		});
	}

	/**
		What a socket can answer, and what it cannot.

		This is the gap the class was written to close, stated as the only thing
		that is true on every target: after the wildcard bind that every
		listener actually uses, the socket has nothing a peer could dial. On sys
		targets it reports `0.0.0.0`, which is every interface and so names
		none. On Node it reports the empty string, because `bind` there is
		asynchronous and `localAddress` is read back when the callback lands
		rather than asked for on demand -- a difference worth knowing about
		separately, and not one this class can paper over.

		Either way the caller is left with nothing to advertise, which is why
		`LocalAddress` exists.
	**/
	public function testAWildcardBoundSocketHasNothingToAdvertise():Void {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return;
		}

		var socket = new DatagramSocket();

		try {
			socket.bind(0, "0.0.0.0");

			var reported = socket.localAddress;
			var advertisable = reported != null && reported.length > 0 && reported != "0.0.0.0" && reported != "::";

			Assert.isFalse(advertisable,
				"a wildcard bind reported " + reported + ", an address a peer could dial, which would make this whole class unnecessary");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try socket.close() catch (_:Dynamic) {}
	}
}
#end
