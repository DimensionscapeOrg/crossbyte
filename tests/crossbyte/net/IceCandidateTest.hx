package crossbyte.net;

import crossbyte.errors.ArgumentError;
import haxe.Int64;
import utest.Assert;

/**
	Pure arithmetic and ordering, so these mean the same thing on every target
	and need no socket, no peer and no network. The numbers are not invented
	here: they are what RFC 8445's formulas produce, and several of them are
	values anyone who has read a real SDP offer will recognise on sight.
**/
class IceCandidateTest extends utest.Test {
	/**
		The values a browser puts in its own offers.

		2130706431 and 1694498815 are not arbitrary constants -- they are what
		the formula gives for a host and a server-reflexive candidate at the
		default local preference, and they appear verbatim in the SDP of every
		WebRTC implementation that follows the recommended type preferences. A
		formula that is merely self-consistent would pass a round-trip test and
		still order pairs differently from the peer on the other end.
	**/
	public function testPrioritiesMatchTheRecommendedValues():Void {
		Assert.equals(2130706431, IceCandidate.computePriority(HOST));
		Assert.equals(1862270975, IceCandidate.computePriority(PEER_REFLEXIVE));
		Assert.equals(1694498815, IceCandidate.computePriority(SERVER_REFLEXIVE));
		Assert.equals(16777215, IceCandidate.computePriority(RELAYED));
	}

	/**
		The formula was built to fit, and this is where that would break first.

		Every target holds an `Int` differently -- 32 bits natively, a double on
		JavaScript -- so a priority that overflowed would not fail in the same
		way everywhere, or necessarily at all. The largest value the formula can
		produce is below the signed 32-bit ceiling by design.
	**/
	public function testTheLargestPriorityFitsInAnInt():Void {
		var largest = IceCandidate.computePriority(HOST, 65535, 1);

		Assert.equals(2130706431, largest);
		Assert.isTrue(largest > 0, "the largest priority came back negative, which is what overflow looks like");
		Assert.isTrue(largest < 2147483647);
	}

	/**
		The ordering the type preferences exist to produce.

		Direct beats translated, translated beats relayed, and a mapping the
		peer itself observed beats one a server reported.
	**/
	public function testTypesRankInTheOrderTheyAreWorthTrying():Void {
		var host = IceCandidate.computePriority(HOST);
		var peerReflexive = IceCandidate.computePriority(PEER_REFLEXIVE);
		var serverReflexive = IceCandidate.computePriority(SERVER_REFLEXIVE);
		var relayed = IceCandidate.computePriority(RELAYED);

		Assert.isTrue(host > peerReflexive);
		Assert.isTrue(peerReflexive > serverReflexive);
		Assert.isTrue(serverReflexive > relayed);
	}

	/**
		The component term is subtracted, not added.

		A stream is useless without its data even if its control channel
		connects, so component 1 has to come first -- which means the term has
		to fall as the id rises.
	**/
	public function testTheFirstComponentOutranksTheSecond():Void {
		var data = IceCandidate.computePriority(HOST, 65535, IceCandidate.COMPONENT_RTP);
		var control = IceCandidate.computePriority(HOST, 65535, IceCandidate.COMPONENT_RTCP);

		Assert.isTrue(data > control);
		Assert.equals(1, data - control);
	}

	/**
		A type dominates whatever the lower terms do.

		The exponents are what guarantee it: a host candidate at the worst
		possible local preference still outranks a reflexive one at the best.
		If the terms were closer together this would not hold, and a peer would
		sometimes try a relay before an interface it holds.
	**/
	public function testTypeBeatsLocalPreferenceOutright():Void {
		var worstHost = IceCandidate.computePriority(HOST, 0, 1);
		var bestReflexive = IceCandidate.computePriority(SERVER_REFLEXIVE, 65535, 1);

		Assert.isTrue(worstHost > bestReflexive, "a local preference outweighed a candidate type, which the exponents are chosen to prevent");
	}

	/**
		A candidate from a peer keeps the peer's number.

		Recomputing it locally is the one thing that would break the agreement
		the whole ordering rests on: the peer sent the priority it used, and two
		sides disagreeing about a candidate's worth is two sides working the
		list in different orders.
	**/
	public function testARemoteCandidateKeepsThePriorityItArrivedWith():Void {
		// Deliberately not a number this implementation would ever compute.
		var fromPeer = new IceCandidate(HOST, "203.0.113.9", 40000, 1, 12345);

		Assert.equals(12345, fromPeer.priority);
		Assert.notEquals(IceCandidate.computePriority(HOST), fromPeer.priority);
	}

	public function testAHostCandidateComputesItsOwnPriority():Void {
		var mine = IceCandidate.host("10.0.0.2", 50000);

		Assert.equals(2130706431, mine.priority);
		Assert.equals("host", (mine.type : String));
		Assert.equals(IceCandidate.COMPONENT_RTP, mine.component);
	}

	/**
		Built from what the discovery call actually hands back.

		The port matters as much as the address: a NAT translated it, so pairing
		the reflexive address with any other port describes somewhere nobody can
		reach.
	**/
	public function testAReflexiveCandidateKeepsTheTranslatedPort():Void {
		var discovered:ReflexiveAddress = {address: "203.0.113.5", port: 61000};
		var candidate = IceCandidate.serverReflexive(discovered);

		Assert.equals("203.0.113.5", candidate.address);
		Assert.equals(61000, candidate.port);
		Assert.equals(1694498815, candidate.priority);
	}

	/**
		A candidate exists to be dialled, so it needs somewhere dialable.

		Port 0 is the one a socket binds with to mean "any", and it is exactly
		what a caller would pass by accident after reading it off a socket that
		has not bound yet.
	**/
	public function testACandidateWithNothingToDialIsRefused():Void {
		Assert.raises(() -> new IceCandidate(HOST, "10.0.0.2", 0), ArgumentError);
		Assert.raises(() -> new IceCandidate(HOST, "10.0.0.2", 70000), ArgumentError);
		Assert.raises(() -> new IceCandidate(HOST, "", 50000), ArgumentError);
		Assert.raises(() -> new IceCandidate(HOST, null, 50000), ArgumentError);
		Assert.raises(() -> new IceCandidate(HOST, "10.0.0.2", 50000, 0), ArgumentError);
	}

	/**
		Two families cannot reach each other, and pairing them would say so a
		round trip later.
	**/
	public function testCandidatesOfDifferentFamiliesCannotBePaired():Void {
		var v4 = IceCandidate.host("10.0.0.2", 50000);
		var v6 = IceCandidate.host("2001:db8::1", 50000);

		Assert.isFalse(v4.canReach(v6));
		Assert.isFalse(v6.canReach(v4));
		Assert.isTrue(v4.canReach(IceCandidate.host("10.0.0.7", 50000)));
		Assert.isTrue(v6.canReach(IceCandidate.host("2001:db8::2", 50000)));
	}

	public function testCandidatesOfDifferentComponentsCannotBePaired():Void {
		var data = IceCandidate.host("10.0.0.2", 50000, IceCandidate.COMPONENT_RTP);
		var control = IceCandidate.host("10.0.0.2", 50001, IceCandidate.COMPONENT_RTCP);

		Assert.isFalse(data.canReach(control));
	}

	/**
		The same place, however it was found.

		A host candidate and a reflexive one can name the same address and port
		when there is no NAT in the way. That is one place to try, and identity
		here deliberately ignores the type and the priority so the duplicate can
		be dropped rather than checked twice.
	**/
	public function testTheSamePlaceFoundTwiceIsOneCandidate():Void {
		var asHost = IceCandidate.host("203.0.113.5", 50000);
		var asReflexive = IceCandidate.serverReflexive({address: "203.0.113.5", port: 50000});

		Assert.isTrue(asHost.sameAs(asReflexive));
		Assert.notEquals(asHost.priority, asReflexive.priority);
		Assert.isFalse(asHost.sameAs(IceCandidate.host("203.0.113.5", 50001)));
	}

	// ------------------------------------------------------------------
	// Pairs
	// ------------------------------------------------------------------

	/**
		The exact numbers, checked against arithmetic done outside Haxe.

		These were computed with unbounded integers rather than by running this
		code, which is the only way the check means anything: an `Int64` that
		silently lost the top bits would agree with itself perfectly.
	**/
	public function testPairPrioritiesMatchTheFormula():Void {
		var host = IceCandidate.computePriority(HOST);
		var reflexive = IceCandidate.computePriority(SERVER_REFLEXIVE);

		Assert.equals("9151314442783293438", Int64.toStr(IceCandidatePair.computePriority(host, host, true)));
		Assert.equals("7277816997797167103", Int64.toStr(IceCandidatePair.computePriority(host, reflexive, true)));
		Assert.equals("7277816997797167102", Int64.toStr(IceCandidatePair.computePriority(reflexive, host, true)));
	}

	/**
		The formula needs more than 32 bits, and this is what proves it.

		The largest pair priority is about 9.15e18 against a signed 64-bit
		ceiling of about 9.22e18 -- the RFC chose exponents that fill an
		`Int64` almost exactly. Had this been computed in an `Int`, the value
		would have wrapped to something small or negative on a target with real
		32-bit integers, and merely lost precision on one where numbers are
		doubles: a disagreement between targets rather than a crash.
	**/
	public function testTheLargestPairPriorityNeedsSixtyFourBits():Void {
		var host = IceCandidate.computePriority(HOST);
		var largest = IceCandidatePair.computePriority(host, host, true);

		Assert.equals("9151314442783293438", Int64.toStr(largest));
		Assert.isTrue(Int64.isNeg(largest) == false, "the largest pair priority came back negative, which is what a 64-bit overflow looks like");
		// Comfortably past anything an Int could hold, which is the point.
		Assert.isTrue(Int64.compare(largest, Int64.ofInt(2147483647)) > 0);
	}

	/**
		The tiebreaker bit, which exists only to stop a collision.

		Swapping which side is controlling leaves the same two numbers going
		into MIN and MAX, so without the final term the two orderings would be
		identical and a pair could not be distinguished from its mirror. The
		difference is exactly one.
	**/
	public function testTheTiebreakerDistinguishesAPairFromItsMirror():Void {
		var host = IceCandidate.computePriority(HOST);
		var reflexive = IceCandidate.computePriority(SERVER_REFLEXIVE);

		var greater = IceCandidatePair.computePriority(host, reflexive, true);
		var lesser = IceCandidatePair.computePriority(reflexive, host, true);

		Assert.equals("1", Int64.toStr(Int64.sub(greater, lesser)));
	}

	/**
		The property the whole ordering exists for.

		Two peers pair the same candidates from opposite ends: what is local to
		one is remote to the other, and one is controlling while the other is
		controlled. If they do not arrive at the same order, the checks they
		send go to different pairs and the cheapest working path is found late
		or not at all.

		This is the case that would catch the controlling flag being applied to
		the wrong side of the formula, which is a mistake that leaves each peer
		internally consistent and the two of them disagreeing.
	**/
	public function testBothPeersSortTheSamePairsIntoTheSameOrder():Void {
		var alice = [
			IceCandidate.host("10.0.0.2", 50000),
			IceCandidate.serverReflexive({address: "203.0.113.5", port: 61000})
		];
		var bob = [
			IceCandidate.host("10.0.0.7", 50000),
			IceCandidate.serverReflexive({address: "198.51.100.9", port: 62000}),
			new IceCandidate(RELAYED, "198.51.100.200", 3478)
		];

		// Alice is controlling; Bob is not. Each sees its own as local.
		var fromAlice = IceCandidatePair.pair(alice, bob, true);
		var fromBob = IceCandidatePair.pair(bob, alice, false);

		Assert.equals(6, fromAlice.length);
		Assert.equals(fromAlice.length, fromBob.length);

		for (i in 0...fromAlice.length) {
			var a = fromAlice[i];
			var b = fromBob[i];

			Assert.isTrue(a.local.sameAs(b.remote), "at position " + i + " the two peers were looking at different pairs: " + a + " against " + b);
			Assert.isTrue(a.remote.sameAs(b.local), "at position " + i + " the two peers were looking at different pairs: " + a + " against " + b);
			Assert.equals(Int64.toStr(a.priority), Int64.toStr(b.priority));
		}
	}

	public function testPairsComeBackHighestFirst():Void {
		var locals = [
			new IceCandidate(RELAYED, "198.51.100.200", 3478),
			IceCandidate.host("10.0.0.2", 50000),
			IceCandidate.serverReflexive({address: "203.0.113.5", port: 61000})
		];
		var remotes = [IceCandidate.host("10.0.0.7", 50000)];

		var pairs = IceCandidatePair.pair(locals, remotes, true);

		Assert.equals(3, pairs.length);
		Assert.equals("host", (pairs[0].local.type : String));
		Assert.equals("srflx", (pairs[1].local.type : String));
		Assert.equals("relay", (pairs[2].local.type : String));

		for (i in 1...pairs.length) {
			Assert.isTrue(Int64.compare(pairs[i - 1].priority, pairs[i].priority) >= 0, "the list was not sorted at position " + i);
		}
	}

	/**
		Families are filtered out during pairing, not failed during checking.

		A peer that offers both an IPv4 and an IPv6 address should produce two
		pairs against a dual-stack peer, not four.
	**/
	public function testPairingLeavesOutWhatCannotReach():Void {
		var locals = [IceCandidate.host("10.0.0.2", 50000), IceCandidate.host("2001:db8::1", 50000)];
		var remotes = [IceCandidate.host("10.0.0.7", 50000), IceCandidate.host("2001:db8::2", 50000)];

		var pairs = IceCandidatePair.pair(locals, remotes, true);

		Assert.equals(2, pairs.length);

		for (pair in pairs) {
			Assert.equals(pair.local.isIPv6(), pair.remote.isIPv6());
		}
	}

	public function testAPairAcrossFamiliesIsRefusedOutright():Void {
		var v4 = IceCandidate.host("10.0.0.2", 50000);
		var v6 = IceCandidate.host("2001:db8::1", 50000);

		Assert.raises(() -> new IceCandidatePair(v4, v6, true), ArgumentError);
	}

	/**
		One place is one check, however many ways it was found.

		Without a NAT the host address and the reflexive address are the same
		place, and a peer that gathered both would otherwise pair each of them
		against every remote candidate.
	**/
	public function testTheSamePlaceIsNotPairedTwice():Void {
		var locals = [
			IceCandidate.host("203.0.113.5", 50000),
			IceCandidate.serverReflexive({address: "203.0.113.5", port: 50000})
		];
		var remotes = [IceCandidate.host("10.0.0.7", 50000), IceCandidate.host("10.0.0.7", 50000)];

		var pairs = IceCandidatePair.pair(locals, remotes, true);

		Assert.equals(1, pairs.length);
	}

	public function testPairingNothingIsEmptyRatherThanAFailure():Void {
		Assert.equals(0, IceCandidatePair.pair([], [IceCandidate.host("10.0.0.7", 50000)], true).length);
		Assert.equals(0, IceCandidatePair.pair([IceCandidate.host("10.0.0.2", 50000)], [], true).length);
		Assert.equals(0, IceCandidatePair.pair(null, null, true).length);
	}
}
