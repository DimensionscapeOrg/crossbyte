package crossbyte.net.ice;

import crossbyte.io.ByteArray;
import haxe.Int64;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.test.Require;
import utest.Assert;

/**
	Two agents, pointed at each other, with no socket between them.

	The agent was built without a transport precisely so this is possible: a
	`Wire` carries datagrams from one to the other, a counter stands in for the
	clock, and the whole exchange runs to completion deterministically on every
	target. What is being tested is the thing that is hardest to test over a
	real network and easiest to get wrong, that two peers, each seeing only
	its own half, converge on the same pair.

	A real network would make these slower, flakier, and no more convincing.
**/
class IceAgentTest extends utest.Test {
	private static inline var ALICE_ADDRESS:String = "10.0.0.1";
	private static inline var BOB_ADDRESS:String = "10.0.0.2";
	private static inline var PORT:Int = 50000;

	private static function credentials(name:String):IceCredentials {
		// Long enough to satisfy the minimums, and fixed so a run is repeatable.
		return new IceCredentials(name + "frag", name + "-password-padded-to-length");
	}

	private function unsupported():Bool {
		if (!IceAgent.isSupported) {
			// No CSPRNG here, so there are no transaction ids and no agent. The
			// candidate arithmetic still runs everywhere; this does not.
			Assert.isFalse(IceAgent.isSupported);
			return true;
		}

		return false;
	}

	/**
		The whole point, in one case.

		Both peers check, both answer, the controlling one nominates, and both
		end up naming the same path from opposite ends.
	**/
	public function testTwoAgentsConvergeOnOnePair():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		var bob = new IceAgent(false, credentials("bob"));
		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		var resolved:IceCandidatePair = null;
		alice.connected.then(pair -> resolved = pair, _ -> {});

		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);

		Assert.isTrue(wire.run(() -> alice.state == CONNECTED && bob.state == CONNECTED), "the two agents never connected");

		Assert.notNull(alice.selectedPair);
		Assert.notNull(bob.selectedPair);

		if (alice.selectedPair == null || bob.selectedPair == null) {
			// utest carries on after a failed assertion, so without this the lines
			// below dereference null and the run reports a crash where it should
			// report a clear failure.
			return;
		}

		// The same path, described from each end.
		Assert.isTrue(alice.selectedPair.local.sameAs(bob.selectedPair.remote), "the two agents selected different paths");
		Assert.isTrue(alice.selectedPair.remote.sameAs(bob.selectedPair.local), "the two agents selected different paths");

		Assert.notNull(resolved, "the connected future never resolved");
		Assert.equals(BOB_ADDRESS, alice.selectedPair.remote.address);
		Assert.equals(ALICE_ADDRESS, bob.selectedPair.remote.address);
	}

	/**
		Closing an agent tells whoever was waiting on a path.

		`connected` had exactly one failure path, __settleIfFinished, which
		decides by looking at the checks, and close() empties them, so after a
		close it could never conclude anything. An agent closed mid-negotiation
		therefore left its caller holding a future that could not settle either
		way, and PeerConnection is one such caller: it wires agent.connected to
		its own failure path in the constructor.
	**/
	public function testClosingAnAgentTellsWhoeverWaitedForAPath():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		var bob = new IceAgent(false, credentials("bob"));

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));

		var resolved:Bool = false;
		var failure:String = null;
		alice.connected.then(_ -> resolved = true, error -> failure = error);

		// Mid-negotiation: checks outstanding, nothing concluded either way.
		alice.start(bob.localCredentials, 0);
		alice.close();

		Assert.isFalse(resolved, "a closed agent reported that it had found a path");
		Assert.notNull(failure, "closing an agent left `connected` pending forever");
	}

	/**
		An agent bounds how many remote candidates it will hold.

		Every remote candidate pairs with every local one, and __rebuild scans
		the whole checklist for each pair, so the cost grows faster than the
		list, and the list is the peer's to choose. Nothing bounded it, and the
		candidates arrive in the description a peer sends.
	**/
	public function testAnAgentBoundsHowManyRemoteCandidatesItWillHold():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		// Distinct and well formed, so nothing else would refuse them, and far
		// more than any real peer offers.
		for (i in 0...(IceAgent.MAX_REMOTE_CANDIDATES * 3)) {
			alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT + i));
		}

		var held:Int = @:privateAccess alice.__remotes.length;

		Assert.isTrue(held <= IceAgent.MAX_REMOTE_CANDIDATES,
			"the agent held " + held + " remote candidates, so a peer chooses how much work this does");
	}

	/**
		And a peer cannot get round that by checking from new places rather
		than advertising them.

		Each check from an address the agent had not heard of became a
		peer-reflexive candidate, paired and checked back, with nothing
		bounding how many: the cap applied to what a description carried and
		not to this, so checks from 192 ports left 192 candidates and drew 384
		datagrams. Past the cap a check from a new place goes unanswered.
	**/
	public function testChecksFromNewPlacesAreBoundedLikeAdvertisedCandidates():Void {
		if (unsupported()) return;

		var alice = credentials("alice");
		var bob = new IceAgent(false, credentials("bob"));
		var sent:Int = 0;
		bob.onSend = (_, _, _) -> sent++;
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.start(alice, 0);

		for (i in 0...(IceAgent.MAX_REMOTE_CANDIDATES * 3)) {
			var check = new StunMessage(StunMessage.BINDING_REQUEST, crossbyte.crypto.SecureRandom.getSecureRandomBytes(12), [
				StunMessage.username(IceCredentials.username(bob.localCredentials, alice)),
				StunMessage.priority(IceCandidate.computePriority(PEER_REFLEXIVE)),
				StunMessage.iceRole(true, Int64.make(0, 5))
			]);

			bob.receive(check.encodeSigned(bob.localCredentials.password), ALICE_ADDRESS, 40000 + i, 0);
		}

		var held:Int = @:privateAccess bob.__remotes.length;

		Assert.equals(IceAgent.MAX_REMOTE_CANDIDATES, held, "checks from new places left " + held + " remote candidates");

		// Each place taken was answered and checked back, two datagrams; the
		// rest were not answered at all.
		Assert.equals(IceAgent.MAX_REMOTE_CANDIDATES * 2, sent, "the agent sent " + sent + " datagrams");
	}

	/**
		A candidate that is a name rather than an address is not dialled.

		Browsers publish their host candidates as random .local mDNS names by
		default, and a name reaching the socket went through `sys.net.Host`,
		which resolves synchronously on the event loop on every send, a
		second's block and a throw for a .local name nothing answers, per
		check. Against a real browser that made connecting take 15.8 seconds
		with CrossByte controlling, the whole loop frozen meanwhile.

		The addresses are real and the names are not, so the names are what
		must be missing afterwards: an agent that kept them would pair them
		and check them, which is the stall.
	**/
	public function testANameIsNotDialledAsIfItWereAnAddress():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		alice.addRemoteCandidate(IceCandidate.host("8f21c9eb-1565-459c-8b08-2666fbf74b81.local", PORT));
		alice.addRemoteCandidate(IceCandidate.host("peer.example.com", PORT + 1));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT + 2));
		alice.addRemoteCandidate(IceCandidate.host("fe80::1", PORT + 3));

		var held:Array<String> = [for (remote in @:privateAccess alice.__remotes) remote.address];

		Assert.equals(BOB_ADDRESS + ",fe80::1", held.join(","),
			"the agent kept " + held.join(",") + "; a name kept is a name looked up on the event loop");
	}

	/**
		Nor is an address that only looks like one.

		Four runs of digits was the whole test, so 1.2.3.999 passed as numeric.
		It is not an address to the socket: hxcpp's resolver finds no literal
		in it and looks it up as a name, blocking the loop per check just as a
		name does. And 010.1.1.1 is 8.1.1.1 to `inet_addr`, which reads a
		leading zero as octal, but ten to anything reading decimal.
	**/
	public function testAnAddressThatOnlyLooksLikeOneIsNotDialled():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		var bob = new IceAgent(false, credentials("bob"));
		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		var dialled:Array<String> = [];
		alice.onSend = (_, address:String, _) -> if (dialled.indexOf(address) < 0) dialled.push(address);

		for (address in ["1.2.3.999", "256.0.0.1", "1.2.3.4294967296", "010.1.1.1"]) {
			Assert.isFalse(alice.addRemoteCandidate(IceCandidate.host(address, PORT)), address + " was taken as an address");
		}

		Assert.isTrue(alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT)));
		alice.start(bob.localCredentials, 0);

		for (i in 0...100) {
			alice.poll(i * 0.05);
		}

		Assert.equals(BOB_ADDRESS, dialled.join(","), "the agent sent checks to " + dialled.join(","));
	}

	/**
		Two agents on IPv6 connect without either inventing an address.

		The answer to a check names where it came from, and the attribute says
		IPv4 alone. An IPv6 source was split on dots and read as numbers, so
		every answer named 0.0.0.0, and the agent that asked took that for a
		reflexive view of itself, a local candidate that does not exist.
		Answered without it, the check succeeds and nothing is learned.
	**/
	public function testAgentsOnIPv6InventNoAddress():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		var bob = new IceAgent(false, credentials("bob"));
		var wire = new Wire(alice, "fe80::1", bob, "fe80::2");

		alice.addLocalCandidate(IceCandidate.host("fe80::1", PORT));
		bob.addLocalCandidate(IceCandidate.host("fe80::2", PORT));
		alice.addRemoteCandidate(IceCandidate.host("fe80::2", PORT));
		bob.addRemoteCandidate(IceCandidate.host("fe80::1", PORT));

		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);

		Assert.isTrue(wire.run(() -> alice.state == CONNECTED && bob.state == CONNECTED), "the two agents never connected");

		for (agent in [alice, bob]) {
			var locals:Array<String> = [for (local in @:privateAccess agent.__locals) local.address];
			Assert.equals(1, locals.length, "an agent learned " + locals.join(",") + " from answers over IPv6");
		}
	}

	/**
		A path stays a path only while the peer keeps agreeing to it.

		RFC 7675. ICE proves a path once, and nothing about that proof stays
		true afterwards: a peer can vanish, and the address it was reached at
		can be handed to somebody who never agreed to hear from this agent. So
		the selected pair is re-confirmed on a timer.

		This case is the half that must not fire. A peer answering throughout
		is kept, and it would not be if the checks were never sent, nothing
		else refreshes the timer, so silence on this side expires the path just
		as surely as silence on the other.
	**/
	public function testAPeerThatKeepsAnsweringKeepsThePath():Void {
		if (unsupported()) return;

		var wire = __connected();

		// Twice the timeout, with both ends answering the whole way.
		wire.advance(1.0, IceAgent.CONSENT_TIMEOUT * 2);

		Assert.isTrue(__alice.state == CONNECTED, "a path the peer kept answering for was dropped anyway");
		Assert.isTrue(__bob.state == CONNECTED, "the answering side dropped the path it was answering on");
	}

	/**
		And the half that must: a peer that goes quiet loses the path.

		Without this the agent reports CONNECTED forever and whoever is above it
		goes on transmitting at an address that may now belong to someone else.
		That is the whole reason RFC 7675 exists.
	**/
	public function testAPeerThatStopsAnsweringLosesThePath():Void {
		if (unsupported()) return;

		var wire = __connected();
		Assert.isTrue(__alice.state == CONNECTED, "the two never connected, so there is no path to lose");

		// The peer goes away without saying so, which is the case that cannot
		// be detected any other way.
		wire.delivering = false;
		wire.advance(1.0, IceAgent.CONSENT_TIMEOUT + 5.0);

		Assert.isTrue(__alice.state == FAILED,
			"the peer stopped answering and the agent went on treating the path as usable");
	}

	/**
		Every change of state is told, the consent failure included.

		Losing consent set `state` and called nothing, so a caller holding a
		raw agent, a reliable datagram server with one attached, had to
		poll `state` every tick to learn the path had gone.
	**/
	public function testAnAgentSaysWhenItsStateChanges():Void {
		if (unsupported()) return;

		var states:Array<String> = [];
		__alice = new IceAgent(true, credentials("alice"));
		__bob = new IceAgent(false, credentials("bob"));
		__alice.onStateChanged = state -> states.push(__stateName(state));

		var wire = new Wire(__alice, ALICE_ADDRESS, __bob, BOB_ADDRESS);
		__alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		__bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		__alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		__bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		__alice.start(__bob.localCredentials, 0);
		__bob.start(__alice.localCredentials, 0);

		Assert.isTrue(wire.run(() -> __alice.state == CONNECTED && __bob.state == CONNECTED), "the two never connected");
		Assert.equals("checking,connected", states.join(","));

		wire.delivering = false;
		wire.advance(1.0, IceAgent.CONSENT_TIMEOUT + 5.0);

		Assert.equals("checking,connected,failed", states.join(","), "losing consent was not told");
	}

	/**
		A failed agent stays failed.

		A nomination reaching an agent whose consent had run out went through
		the branch meant for the first selection: CONNECTED again, with no
		`onSelectedPairChanged`, on a path RFC 7675 had it stop using.
	**/
	public function testAFailedAgentStaysFailed():Void {
		if (unsupported()) return;

		var wire = __connected();

		if (__bob.state != CONNECTED) {
			Assert.fail("the two never connected");
			return;
		}

		wire.delivering = false;
		var now = wire.advance(1.0, IceAgent.CONSENT_TIMEOUT + 5.0);
		Assert.equals(IceAgentState.FAILED, __bob.state, "the silent path was never given up on");

		var sent:Int = 0;
		var changes:Int = 0;
		__bob.onSend = (_, _, _) -> sent++;
		__bob.onSelectedPairChanged = _ -> changes++;
		__bob.onStateChanged = _ -> changes++;

		var nomination = new StunMessage(StunMessage.BINDING_REQUEST, crossbyte.crypto.SecureRandom.getSecureRandomBytes(12), [
			StunMessage.username(IceCredentials.username(__bob.localCredentials, __alice.localCredentials)),
			StunMessage.priority(IceCandidate.computePriority(PEER_REFLEXIVE)),
			StunMessage.iceRole(true, __alice.tiebreaker),
			StunMessage.useCandidate()
		]);

		Assert.isFalse(__bob.receive(nomination.encodeSigned(__bob.localCredentials.password), ALICE_ADDRESS, PORT, now),
			"a failed agent took a check");
		Assert.equals(IceAgentState.FAILED, __bob.state, "a nomination brought a failed agent back");
		Assert.equals(0, sent, "a failed agent answered");
		Assert.equals(0, changes, "a failed agent reported a change");
	}

	private static function __stateName(state:IceAgentState):String {
		return switch (state) {
			case NEW: "new";
			case CHECKING: "checking";
			case CONNECTED: "connected";
			case FAILED: "failed";
			case CLOSED: "closed";
		}
	}

	/**
		A peer that moves and nominates the pair from its new address is followed.

		What a browser does when its network changes: the controlling agent
		checks from where it now is and nominates that pair. The controlled
		agent answered the nomination and kept the pair it had, so it went on
		sending to an address that no longer answered until consent to it ran
		out half a minute later. Here Bob is the controlled end, CrossByte
		answering a browser, and Alice moves.
	**/
	public function testAPeerThatMovesAndNominatesAgainIsFollowed():Void {
		if (unsupported()) return;

		var wire = __connected();

		if (__bob.state != CONNECTED) {
			Assert.fail("the two never connected, so there is no path to move");
			return;
		}

		var changes:Array<IceCandidatePair> = [];
		__bob.onSelectedPairChanged = pair -> changes.push(pair);

		// Alice's old address is gone; she is at a new one now.
		wire.unreachable.push(ALICE_ADDRESS + ":" + PORT);
		wire.rewriteSourceOf(__alice, "10.0.0.3", PORT);

		// And nominates from there, as libwebrtc does when it switches.
		var now = 10.0;
		var nomination = new StunMessage(StunMessage.BINDING_REQUEST, crossbyte.crypto.SecureRandom.getSecureRandomBytes(12), [
			StunMessage.username(IceCredentials.username(__bob.localCredentials, __alice.localCredentials)),
			StunMessage.priority(IceCandidate.computePriority(PEER_REFLEXIVE)),
			StunMessage.iceRole(true, __alice.tiebreaker),
			StunMessage.useCandidate()
		]);

		__bob.receive(nomination.encodeSigned(__bob.localCredentials.password), "10.0.0.3", PORT, now);

		// Past the consent timeout, with Alice answering from her new address.
		now = wire.advance(now, IceAgent.CONSENT_TIMEOUT + 5.0);

		Assert.notNull(__bob.selectedPair);

		if (__bob.selectedPair != null) {
			Assert.equals("10.0.0.3", __bob.selectedPair.remote.address, "the agent kept the pair to an address that had gone");
		}

		Assert.equals(1, changes.length, "the change of pair was reported " + changes.length + " times");
		Assert.isTrue(__bob.state == CONNECTED, "the agent lost a peer that had moved and said where to");
	}

	/**
		A candidate trickled after the path was found is still checked.

		`__rebuild` returned unless the agent was checking, so a candidate that
		arrived once it had connected went into the list and was never paired
		or tried, and a peer reachable only there could never be followed.
	**/
	public function testACandidateTrickledAfterConnectingIsChecked():Void {
		if (unsupported()) return;

		var wire = __connected();

		if (__bob.state != CONNECTED) {
			Assert.fail("the two never connected");
			return;
		}

		// Somewhere nothing answers, so the check is sent and simply fails.
		wire.unreachable.push("10.0.0.9:" + PORT);
		Assert.isTrue(__bob.addRemoteCandidate(IceCandidate.host("10.0.0.9", PORT)), "the late candidate was not taken");

		wire.advance(20.0, 2.0, 0.05);

		Assert.isTrue(wire.sentTo.exists("10.0.0.9:" + PORT), "a candidate trickled after connecting was never checked");
		Assert.isTrue(__bob.state == CONNECTED, "checking a late candidate disturbed the path in use");
		Assert.equals(BOB_ADDRESS, __alice.selectedPair.remote.address);
	}

	/**
		A connected agent with nothing late to check scans nothing.

		What it costs to be connected is consent, every few seconds, not a walk
		of the check list on every poll.
	**/
	public function testAConnectedAgentWithNothingLateSendsOnlyConsent():Void {
		if (unsupported()) return;

		var wire = __connected();

		if (__bob.state != CONNECTED) {
			Assert.fail("the two never connected");
			return;
		}

		var before = wire.sentTo.exists(ALICE_ADDRESS + ":" + PORT) ? wire.sentTo.get(ALICE_ADDRESS + ":" + PORT) : 0;
		wire.advance(20.0, 10.0, 0.05);
		var after = wire.sentTo.get(ALICE_ADDRESS + ":" + PORT);

		// Consent every 4 to 6 seconds: two or three in ten seconds, plus the
		// answers to Alice's.
		Assert.isTrue(after - before <= 8, "a connected agent sent " + (after - before) + " datagrams in ten quiet seconds");
		Assert.isFalse(@:privateAccess __bob.__lateChecks, "a connected agent with nothing late still looks for checks to send");
	}

	private var __alice:IceAgent;
	private var __bob:IceAgent;

	/** Two agents with one pair between them, nominated and connected. **/
	private function __connected():Wire {
		__alice = new IceAgent(true, credentials("alice"));
		__bob = new IceAgent(false, credentials("bob"));

		var wire = new Wire(__alice, ALICE_ADDRESS, __bob, BOB_ADDRESS);

		__alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		__bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		__alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		__bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		__alice.start(__bob.localCredentials, 0);
		__bob.start(__alice.localCredentials, 0);

		wire.run(() -> __alice.state == CONNECTED && __bob.state == CONNECTED);
		return wire;
	}

	/**
		The controlling peer decides, and the other does not.

		Two peers both nominating is two peers potentially nominating different
		pairs, which is the situation the roles exist to prevent.
	**/
	public function testOnlyTheControllingAgentNominates():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		var bob = new IceAgent(false, credentials("bob"));
		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);
		wire.run(() -> alice.state == CONNECTED && bob.state == CONNECTED);

		Assert.isTrue(wire.nominationsFrom(alice) > 0, "the controlling agent never nominated");
		Assert.equals(0, wire.nominationsFrom(bob));
	}

	/**
		A check nobody could have signed is not a check.

		Without this, anything that can see a check can answer one, and a peer
		nominates a path to whoever replied first.
	**/
	public function testAnAgentIgnoresChecksSignedWithTheWrongPassword():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		var bob = new IceAgent(false, credentials("bob"));
		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		// Alice has been told a password that is not Bob's, so everything she
		// sends is signed with the wrong key.
		alice.start(credentials("impostor"), 0);
		bob.start(alice.localCredentials, 0);

		Assert.isFalse(wire.run(() -> alice.state == CONNECTED), "a check signed with the wrong password was accepted");
		Assert.notEquals(IceAgentState.CONNECTED, bob.state);
	}

	/**
		The username names the receiver first.

		Reversed, every check is addressed to the wrong session. It looks
		correct, it verifies against its own integrity, and a peer behaving
		properly drops all of it, which would show up as two peers that never
		connect and no error anywhere.
	**/
	public function testACheckAddressedToTheWrongPeerIsDropped():Void {
		if (unsupported()) return;

		var bob = new IceAgent(false, credentials("bob"));
		var sent:Array<{payload:ByteArray, address:String, port:Int}> = [];
		bob.onSend = (payload, address, port) -> sent.push({payload: payload, address: address, port: port});

		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.start(credentials("alice"), 0);

		// Addressed the wrong way round: sender first, receiver second.
		var backwards = new StunMessage(StunMessage.BINDING_REQUEST, StunMessage.bindingRequest().transactionId, [
			StunMessage.username(IceCredentials.username(credentials("alice"), bob.localCredentials))
		]);

		// Nor taken: it is not this agent's, and whatever else shares the
		// socket is entitled to see it. It was reported taken.
		Assert.isFalse(bob.receive(backwards.encodeSigned(bob.localCredentials.password), ALICE_ADDRESS, PORT, 0),
			"a check addressed to another session was reported as taken");
		Assert.equals(0, sent.length, "a check addressed to another session was answered");

		// And the same message addressed correctly is answered, so what the
		// case above proves is the direction and not merely that nothing works.
		var forwards = new StunMessage(StunMessage.BINDING_REQUEST, StunMessage.bindingRequest().transactionId, [
			StunMessage.username(IceCredentials.username(bob.localCredentials, credentials("alice")))
		]);

		Assert.isTrue(bob.receive(forwards.encodeSigned(bob.localCredentials.password), ALICE_ADDRESS, PORT, 0),
			"a check addressed to this agent was not reported as taken");
		Assert.isTrue(sent.length > 0, "a correctly addressed check went unanswered");
	}

	/**
		Only what is this agent's is reported taken.

		`receive` says whether the datagram was the agent's, so whatever else
		shares the socket can have the rest, and it answered yes to every
		binding message there was: a check signed with someone else's
		password, an answer to a transaction it never sent, a refusal of one.
	**/
	public function testOnlyItsOwnTrafficIsReportedTaken():Void {
		if (unsupported()) return;

		var alice = credentials("alice");
		var bob = new IceAgent(true, credentials("bob"));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.start(alice, 0);

		var forged = new StunMessage(StunMessage.BINDING_REQUEST, StunMessage.bindingRequest().transactionId, [
			StunMessage.username(IceCredentials.username(bob.localCredentials, alice))
		]);

		Assert.isFalse(bob.receive(forged.encodeSigned("not-the-password-of-anyone-here"), ALICE_ADDRESS, PORT, 0),
			"a check signed with another password was reported as taken");

		var unasked = new StunMessage(StunMessage.BINDING_SUCCESS, StunMessage.bindingRequest().transactionId, []);
		Assert.isFalse(bob.receive(unasked.encodeSigned(alice.password), ALICE_ADDRESS, PORT, 0),
			"an answer to a check this agent never sent was reported as taken");

		var refusal = new StunMessage(StunMessage.BINDING_ERROR, StunMessage.bindingRequest().transactionId, [
			StunMessage.errorCode(400, "Bad Request")
		]);
		Assert.isFalse(bob.receive(refusal.encodeSigned(alice.password), ALICE_ADDRESS, PORT, 0),
			"a refusal of a check this agent never sent was reported as taken");

		// And an answer to one it did send is.
		var sent:Array<ByteArray> = [];
		bob.onSend = (payload, _, _) -> sent.push(payload);
		bob.poll(0);

		var check = Require.notNull(sent.length > 0 ? StunMessage.decode(sent[0]) : null, "the agent sent no check to answer");
		var answer = new StunMessage(StunMessage.BINDING_SUCCESS, check.transactionId, []);
		Assert.isTrue(bob.receive(answer.encodeSigned(alice.password), ALICE_ADDRESS, PORT, 0),
			"an answer to this agent's own check was not reported as taken");
	}

	/**
		Anything that is not STUN belongs to whoever else shares the socket.

		A peer runs its checks over the same port its data arrives on, so an
		agent that swallowed everything would swallow the connection it just
		finished establishing.
	**/
	public function testTrafficThatIsNotStunIsLeftAlone():Void {
		if (unsupported()) return;

		var agent = new IceAgent(true, credentials("alice"));
		agent.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		agent.start(credentials("bob"), 0);

		var payload = new ByteArray();
		payload.writeUTFBytes("this is application data, not a binding request");
		payload.position = 0;

		Assert.isFalse(agent.receive(payload, BOB_ADDRESS, PORT, 0), "the agent consumed a datagram that was not STUN");
	}

	/**
		When nothing answers, it says so rather than waiting forever.

		A check has no failure to report: a datagram that reaches nothing looks
		exactly like one still in flight. Only the retransmission budget ends
		it, and when it does the caller has to be told.
	**/
	public function testEveryPairFailingIsReportedRatherThanHung():Void {
		if (unsupported()) return;

		var agent = new IceAgent(true, credentials("alice"));
		var failure:String = null;

		agent.connected.then(_ -> {}, error -> failure = error);

		agent.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		agent.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		agent.start(credentials("bob"), 0);

		// Nothing is wired up, so every check goes nowhere. Seven attempts with
		// the delay doubling from half a second spans about half a minute.
		var now = 0.0;

		for (_ in 0...400) {
			agent.poll(now);
			now += 0.25;
		}

		Assert.equals(IceAgentState.FAILED, agent.state);
		Assert.notNull(failure, "no path was found and nothing said so");
	}

	/**
		An agent with no pair to check gives up at its deadline, and says why.

		`__settleIfFinished` waits for every pair to fail, and with none there
		is nothing to fail: an agent whose peer offered only names, and from
		which no check came, was still CHECKING ten minutes on, and so was
		whatever waited on `connected`.
	**/
	public function testAnAgentWithNothingToCheckGivesUpAtItsDeadline():Void {
		if (unsupported()) return;

		var agent = new IceAgent(true, credentials("alice"));
		var now = 0.0;
		var failure:String = null;
		var failedAt:Float = -1;

		agent.connected.then(_ -> {}, function(error:String):Void {
			failure = error;
			failedAt = now;
		});

		agent.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		// What a browser hiding its addresses offers: a name, which is dropped.
		agent.addRemoteCandidate(IceCandidate.host("8f21c9eb-1565-459c-8b08-2666fbf74b81.local", PORT));
		agent.start(credentials("bob"), 0);

		while (now < 600 && failure == null) {
			agent.poll(now);
			now += 0.25;
		}

		Assert.equals(IceAgentState.FAILED, agent.state, "an agent with nothing to check never gave up");
		Assert.isTrue(failedAt >= IceAgent.DEFAULT_TIMEOUT && failedAt < IceAgent.DEFAULT_TIMEOUT + 0.5, "it gave up at " + failedAt + " seconds");
		Require.notNull(failure);
		Assert.isTrue(failure.indexOf("No candidate pair could be formed") >= 0, "the reason does not say what was missing: " + failure);
	}

	/**
		A controlled agent whose pairs answer, and which is never nominated,
		gives up at its deadline.

		Its own checks succeeding keep `__settleIfFinished` from concluding
		anything, and only the controlling peer can select a pair. With the
		nominations lost on the way, or a peer that never sends one, it
		waited for good.
	**/
	public function testAControlledAgentNeverNominatedGivesUpAtItsDeadline():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		var bob = new IceAgent(false, credentials("bob"));
		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);
		wire.loseNominations = true;

		var failure:String = null;
		bob.connected.then(_ -> {}, error -> failure = error);

		// Alice fails too, her nomination never answered. Observed, because an
		// unobserved failure is reported on the next tick by a listener added
		// for it, one that outlives this case and is counted by any later
		// case that counts the runtime's tick listeners.
		alice.connected.then(_ -> {}, _ -> {});

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);

		wire.advance(0, IceAgent.DEFAULT_TIMEOUT + 2.0, 0.05);

		Assert.isTrue(bob.validPairs().length > 0, "no pair answered, so this is not the case being tested");
		Assert.equals(IceAgentState.FAILED, bob.state, "a controlled agent that was never nominated was still waiting");
		Require.notNull(failure, "`connected` was never settled");
		Assert.isTrue(failure.indexOf("nominated none") >= 0, "the reason does not say the nomination never came: " + failure);
	}

	/**
		A nomination that goes unanswered moves on to another pair that
		answered.

		`__nominating` was set as a nomination went out and cleared by nothing
		but a change of role, so a controlling agent whose first choice went
		quiet after it was proved never nominated again, while another pair
		that had answered sat unused. The deadline is off here, so what is
		measured is the agent moving on rather than giving up.
	**/
	public function testAnUnansweredNominationMovesToAnotherPair():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		var bob = new IceAgent(false, credentials("bob"));
		alice.timeout = 0;
		bob.timeout = 0;

		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);
		var second:String = "10.0.0.4";

		// Bob is reachable at two addresses, the first preferred, and a
		// nomination to the first is lost however often it is sent.
		wire.loseNominationsTo.push(BOB_ADDRESS + ":" + PORT);

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(second, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(new IceCandidate(HOST, second, PORT, IceCandidate.COMPONENT_RTP, IceCandidate.computePriority(HOST, 100)));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);

		wire.advance(0, 60, 0.05);

		Assert.equals(IceAgentState.CONNECTED, alice.state, "after its first nomination went unanswered the controlling agent never nominated again");
		Assert.equals(IceAgentState.CONNECTED, bob.state, "the controlled agent was never nominated");

		if (alice.selectedPair != null) {
			Assert.equals(second, alice.selectedPair.remote.address, "the pair selected is not the one that answered");
		}
	}

	/**
		A late copy of the answer that proved a pair is not taken for the
		answer to its nomination.

		The nomination went out under the transaction of the check that had
		proved the pair, so the peer's answer to a retransmission of that
		check, arriving after the nomination left, selected the pair, though
		the peer had never been sent USE-CANDIDATE, and would wait for one.
	**/
	public function testALateAnswerIsNotTakenForTheNominations():Void {
		if (unsupported()) return;

		var bob = credentials("bob");
		var alice = new IceAgent(true, credentials("alice"));
		var sent:Array<ByteArray> = [];
		alice.onSend = (payload, _, _) -> sent.push(payload);
		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.start(bob, 0);
		alice.poll(0);

		var check = Require.notNull(sent.length > 0 ? StunMessage.decode(sent[0]) : null, "no check went out");
		var answer = new StunMessage(StunMessage.BINDING_SUCCESS, check.transactionId, []);

		// The pair is proved, and nominated on the next poll.
		alice.receive(answer.encodeSigned(bob.password), BOB_ADDRESS, PORT, 0.1);
		alice.poll(0.2);

		var nomination = Require.notNull(StunMessage.decode(sent[sent.length - 1]));
		Assert.isTrue(nomination.hasUseCandidate(), "the agent did not nominate the pair it had proved");

		// And the same answer again, late.
		alice.receive(answer.encodeSigned(bob.password), BOB_ADDRESS, PORT, 0.3);

		Assert.equals(IceAgentState.CHECKING, alice.state, "a late copy of the proving answer selected the pair");
	}

	/**
		A pair nothing answers is given up on at 39.5 seconds, as RFC 8489 has
		a transaction given up on: seven transmissions over 31.5 seconds, and
		sixteen times the first timeout for the last to be answered.

		It waited one more doubling after the last, thirty-two seconds, and
		gave up at 63.5, while this class said half a minute.
	**/
	public function testAPairNothingAnswersIsGivenUpOnAtThirtyNineAndAHalfSeconds():Void {
		if (unsupported()) return;

		var agent = new IceAgent(true, credentials("alice"));
		var now = 0.0;
		var failedAt:Float = -1;
		var sent:Int = 0;

		agent.onSend = (_, _, _) -> sent++;
		agent.connected.then(_ -> {}, _ -> failedAt = now);
		agent.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		agent.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		agent.start(credentials("bob"), 0);

		// A fine step, so each transmission goes out within a few milliseconds
		// of when it is due and the total is what the schedule says.
		while (failedAt < 0 && now < 120) {
			agent.poll(now);
			now += 0.01;
		}

		Assert.equals(IceAgent.MAX_ATTEMPTS, sent, "the pair was checked " + sent + " times");
		Assert.isTrue(failedAt >= 39.5 && failedAt < 39.6, "the pair was given up on at " + failedAt + " seconds, not 39.5");
	}

	/**
		STUN that is not a connectivity check is left for whatever else shares
		the socket.

		The agent took every STUN message there was. On a socket it shares
		with a TURN client, a reliable datagram server with an agent attached
		and a relay allocated, that swallowed the relay's answers, so the
		allocation could never complete.
	**/
	public function testStunThatIsNotACheckIsLeftForOthers():Void {
		if (unsupported()) return;

		var agent = new IceAgent(true, credentials("alice"));
		agent.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		agent.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		agent.start(credentials("bob"), 0);

		var relayAnswer = new StunMessage(StunMessage.ALLOCATE_ERROR, StunMessage.bindingRequest().transactionId, [
			StunMessage.errorCode(401, "Unauthorized"),
			StunMessage.text(StunMessage.ATTR_REALM, "example.org"),
			StunMessage.text(StunMessage.ATTR_NONCE, "nonce")
		]);

		Assert.isFalse(agent.receive(relayAnswer.encode(), "203.0.113.10", 3478, 0), "the agent took a relay's answer");

		var indication = new StunMessage(StunMessage.DATA_INDICATION, StunMessage.bindingRequest().transactionId, [
			StunMessage.xorPeerAddress(BOB_ADDRESS, PORT)
		]);

		Assert.isFalse(agent.receive(indication.encode(), "203.0.113.10", 3478, 0), "the agent took a relay's Data indication");
	}

	/**
		Pairs a relay refused to carry fail when it says so, not half a minute
		later.

		A relay drops what it has no permission for without a word, so a check
		it refused to forward looked like one still in flight: seven of them
		over thirty seconds, and an agent whose every other pair had failed
		waited that long to say so.
	**/
	public function testPairsARelayRefusedFailWhenItSaysSo():Void {
		if (unsupported()) return;

		var agent = new IceAgent(true, credentials("alice"));
		var failure:String = null;
		agent.connected.then(_ -> {}, error -> failure = error);

		var relayed = new IceCandidate(RELAYED, "203.0.113.10", 49152);
		var sent:Int = 0;
		agent.addLocalCandidate(relayed, (_, _, _) -> sent++);
		agent.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		agent.addRemoteCandidate(IceCandidate.host("198.51.100.7", PORT));
		agent.start(credentials("bob"), 0);
		agent.poll(0);
		agent.poll(IceAgent.PACING);

		// One peer address refused: the pair to the other is still worth trying.
		agent.refusePairs(relayed, BOB_ADDRESS);
		Assert.equals(IceAgentState.CHECKING, agent.state, "refusing one address gave up on a pair to another");

		agent.refusePairs(relayed, "198.51.100.7");
		Assert.equals(IceAgentState.FAILED, agent.state, "every pair was refused and the agent was still checking");
		Assert.notNull(failure, "every pair was refused and nothing said so");

		// And nothing more goes to either.
		var before:Int = sent;

		for (i in 0...80) {
			agent.poll(0.1 + i * 0.5);
		}

		Assert.equals(before, sent, "checks went on being sent on pairs the relay had refused");
	}

	/**
		A mapping neither peer could have known about.

		When a NAT gives a peer a different address for this destination than
		for the STUN server it asked earlier, the check arrives from somewhere
		that is on nobody's candidate list. The receiver reports where it saw
		it, and that becomes a peer-reflexive candidate, frequently the only
		one that works.
	**/
	public function testAMappingNobodyAdvertisedIsLearnedFromTheCheck():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"));
		var bob = new IceAgent(false, credentials("bob"));
		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);

		// A NAT in front of Alice rewrites her source address to one she never
		// advertised, which is exactly what a symmetric NAT does.
		wire.rewriteSourceOf(alice, "203.0.113.77", 61111);

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);
		wire.run(() -> alice.state == CONNECTED && bob.state == CONNECTED);

		// Bob saw Alice arrive from the translated address, so that is what he
		// now knows her as.
		var learned = false;

		for (pair in bob.validPairs()) {
			if (pair.remote.address == "203.0.113.77" && pair.remote.port == 61111) {
				learned = true;
			}
		}

		Assert.isTrue(learned, "the address the check actually arrived from was never learned");
	}

	// ------------------------------------------------------------------
	// Role conflicts
	// ------------------------------------------------------------------

	/**
		Both peers claiming to be in charge, which is not an exotic case.

		Roles are agreed out of band, and any exchange that can be raced, both
		sides offering at once, a restart, a signalling path that reordered two
		messages, leaves both convinced they are controlling. Nothing detects
		it until a check arrives, because until then each side is perfectly
		consistent with itself.

		The larger tiebreaker keeps the role. Here Bob has it, so Alice is the
		one who moves, and the two still converge.
	**/
	public function testTwoAgentsBothClaimingControlStillConverge():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"), Int64.make(0, 100));
		var bob = new IceAgent(true, credentials("bob"), Int64.make(0, 200));
		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);

		Assert.isTrue(wire.run(() -> alice.state == CONNECTED && bob.state == CONNECTED),
			"two agents that both claimed the controlling role never resolved it");

		// Exactly one of them moved, and it was the one with less to say about it.
		Assert.isFalse(alice.controlling, "the smaller tiebreaker kept the controlling role");
		Assert.isTrue(bob.controlling, "the larger tiebreaker gave up the controlling role");
	}

	/**
		The mirror case, where neither peer thinks it is in charge.

		Left alone this is worse than the conflict above: nobody nominates, so
		both sides check happily forever and neither ever selects a pair. The
		same comparison resolves it, with the larger tiebreaker taking the role
		rather than keeping it.
	**/
	public function testTwoAgentsBothClaimingToBeControlledStillConverge():Void {
		if (unsupported()) return;

		var alice = new IceAgent(false, credentials("alice"), Int64.make(0, 900));
		var bob = new IceAgent(false, credentials("bob"), Int64.make(0, 300));
		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);

		Assert.isTrue(wire.run(() -> alice.state == CONNECTED && bob.state == CONNECTED),
			"two agents that both declined the controlling role never resolved it");

		Assert.isTrue(alice.controlling, "the larger tiebreaker did not take the controlling role");
		Assert.isFalse(bob.controlling);
	}

	/**
		Exactly one side moves, and it does so once.

		This is the case that catches a role change resolving the conflict and
		then undoing itself. A check sent while claiming one role can be refused
		after an inbound check has already changed it, and an agent that acted
		on that stale refusal would switch straight back into the conflict it
		had just left.

		What that costs was measured rather than assumed: the two peers still
		converge, so nothing hangs and no other case here notices. What they
		lose is a round trip and the priority of every pair, recomputed each
		time the role moves. A fault that still arrives at the right answer is
		the kind nothing finds later, which is why it is asserted on directly
		instead of being left to the convergence cases.
	**/
	public function testARoleChangeHappensOnceAndDoesNotUndoItself():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"), Int64.make(0, 100));
		var bob = new IceAgent(true, credentials("bob"), Int64.make(0, 200));
		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);

		var aliceChanges = 0;
		var bobChanges = 0;
		alice.onRoleChanged = _ -> aliceChanges++;
		bob.onRoleChanged = _ -> bobChanges++;

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);
		wire.run(() -> alice.state == CONNECTED && bob.state == CONNECTED);

		Assert.equals(1, aliceChanges, "the agent that gave way changed role more than once");
		Assert.equals(0, bobChanges, "the agent that kept its role changed anyway");
	}

	/**
		Roles agreed correctly are left alone.

		A conflict check that fired on every exchange would be worse than none:
		it would move an agent that had nothing wrong with it.
	**/
	public function testAgentsWithOppositeRolesNeverSwitch():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"), Int64.make(0, 100));
		var bob = new IceAgent(false, credentials("bob"), Int64.make(0, 200));
		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);

		var changes = 0;
		alice.onRoleChanged = _ -> changes++;
		bob.onRoleChanged = _ -> changes++;

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);
		wire.run(() -> alice.state == CONNECTED && bob.state == CONNECTED);

		Assert.equals(0, changes, "a role was changed when the two peers already disagreed correctly");
		Assert.isTrue(alice.controlling);
		Assert.isFalse(bob.controlling);
	}

	/**
		After a switch, both peers are sorting by the same numbers again.

		Pair priority is computed from the role, so an agent that changed sides
		without recomputing would be relabelled rather than switched, still
		ordering its list the old way while the peer orders it the new way,
		which is the disagreement the roles exist to prevent.
	**/
	public function testPairPrioritiesAreRecomputedWhenTheRoleChanges():Void {
		if (unsupported()) return;

		var alice = new IceAgent(true, credentials("alice"), Int64.make(0, 100));
		var bob = new IceAgent(true, credentials("bob"), Int64.make(0, 200));
		var wire = new Wire(alice, ALICE_ADDRESS, bob, BOB_ADDRESS);

		alice.addLocalCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));
		bob.addLocalCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		alice.addRemoteCandidate(IceCandidate.host(BOB_ADDRESS, PORT));
		bob.addRemoteCandidate(IceCandidate.host(ALICE_ADDRESS, PORT));

		alice.start(bob.localCredentials, 0);
		bob.start(alice.localCredentials, 0);
		wire.run(() -> alice.state == CONNECTED && bob.state == CONNECTED);

		if (alice.selectedPair == null || bob.selectedPair == null) {
			Assert.fail("the conflict was resolved without either side selecting a pair");
			return;
		}

		// The same pair seen from both ends, so after the switch the two agree
		// on what it is worth, which is only true if both recomputed.
		Assert.equals(Int64.toStr(alice.selectedPair.priority), Int64.toStr(bob.selectedPair.priority),
			"the two peers disagree on the priority of the pair they both selected");
	}

	public function testAgentCredentialsRefuseWeakValues():Void {
		Assert.raises(() -> new IceCredentials("abc", "a-long-enough-password-here"), crossbyte.errors.ArgumentError);
		Assert.raises(() -> new IceCredentials("goodfrag", "tooshort"), crossbyte.errors.ArgumentError);
		Assert.raises(() -> new IceCredentials(null, null), crossbyte.errors.ArgumentError);
	}

	/**
		The password never reaches a string a caller might log.

		A credential in a log file is a credential that has been published, and
		`toString` is what gets interpolated into one by accident.
	**/
	public function testCredentialsDoNotPrintTheirPassword():Void {
		var subject = credentials("alice");
		var printed = Std.string(subject);

		Assert.isFalse(printed.indexOf(subject.password) >= 0, "the password appeared in toString");
		Assert.isTrue(printed.indexOf(subject.usernameFragment) >= 0);
	}
}

/**
	Carries datagrams between two agents and stands in for the clock.

	Queued rather than delivered inside `onSend`, because delivering there would
	re-enter the sending agent through the receiving one and turn an exchange
	into a recursion.
**/
private class Wire {
	private var endpoints:Array<Endpoint> = [];
	private var queue:Array<Packet> = [];
	private var nominations:Map<Int, Int> = new Map();

	public function new(first:IceAgent, firstAddress:String, second:IceAgent, secondAddress:String) {
		attach(first, firstAddress);
		attach(second, secondAddress);
	}

	private function attach(agent:IceAgent, address:String):Void {
		var endpoint = new Endpoint(agent, address);
		endpoints.push(endpoint);

		agent.onSend = function(payload:ByteArray, toAddress:String, toPort:Int):Void {
			var message = StunMessage.decode(payload);

			if (message != null && message.hasUseCandidate()) {
				var index = endpoints.indexOf(endpoint);
				nominations.set(index, (nominations.exists(index) ? nominations.get(index) : 0) + 1);
			}

			var key = toAddress + ":" + toPort;
			sentTo.set(key, (sentTo.exists(key) ? sentTo.get(key) : 0) + 1);

			if (unreachable.indexOf(key) >= 0) {
				return;
			}

			// Lost on the way, as a nomination can be while the checks before
			// it got through.
			if (message != null && message.hasUseCandidate() && (loseNominations || loseNominationsTo.indexOf(key) >= 0)) {
				return;
			}

			queue.push(new Packet(endpoint, payload, toAddress, toPort));
		};
	}

	/** "address:port" of anywhere that no longer answers: what is sent there is lost. **/
	public var unreachable:Array<String> = [];

	/** Every check carrying USE-CANDIDATE is lost, and nothing else. **/
	public var loseNominations:Bool = false;

	/** "address:port" a check carrying USE-CANDIDATE is lost on the way to. **/
	public var loseNominationsTo:Array<String> = [];

	/** How many datagrams were sent to each "address:port", lost or not. **/
	public var sentTo:Map<String, Int> = new Map();

	/** Makes one endpoint appear to come from somewhere it never advertised. **/
	public function rewriteSourceOf(agent:IceAgent, address:String, port:Int):Void {
		for (endpoint in endpoints) {
			if (endpoint.agent == agent) {
				endpoint.sourceAddress = address;
				endpoint.sourcePort = port;
			}
		}
	}

	public function nominationsFrom(agent:IceAgent):Int {
		for (i in 0...endpoints.length) {
			if (endpoints[i].agent == agent) {
				return nominations.exists(i) ? nominations.get(i) : 0;
			}
		}

		return 0;
	}

	/**
		Runs until `done`, or until the simulated clock runs out.

		@return Whether `done` came true, so a caller can assert either way
		rather than only on success.
	**/
	/** Whether anything still reaches the far side, as a live peer would. **/
	public var delivering:Bool = true;

	/**
		Runs the clock forward at a coarser step than `run` uses.

		`run` steps a hundredth of a second six hundred times, which is six
		seconds of simulated time: right for a handshake, useless for anything
		on the consent timer, which is measured in tens of seconds.
	**/
	public function advance(from:Float, seconds:Float, step:Float = 0.25):Float {
		var now = from;
		var until = from + seconds;

		while (now < until) {
			for (endpoint in endpoints) {
				endpoint.agent.poll(now);
			}

			var inFlight = queue;
			queue = [];

			if (delivering) {
				for (packet in inFlight) {
					for (endpoint in endpoints) {
						if (endpoint.agent != packet.from.agent) {
							endpoint.agent.receive(packet.payload, packet.from.sourceAddress, packet.from.sourcePort, now);
						}
					}
				}
			}

			now += step;
		}

		return now;
	}

	public function run(done:Void->Bool):Bool {
		var now = 0.0;

		for (_ in 0...600) {
			for (endpoint in endpoints) {
				endpoint.agent.poll(now);
			}

			var inFlight = queue;
			queue = [];

			for (packet in inFlight) {
				for (endpoint in endpoints) {
					if (endpoint.agent != packet.from.agent) {
						endpoint.agent.receive(packet.payload, packet.from.sourceAddress, packet.from.sourcePort, now);
					}
				}
			}

			if (done()) {
				return true;
			}

			now += 0.01;
		}

		return done();
	}
}

private class Endpoint {
	public var agent:IceAgent;
	public var sourceAddress:String;
	public var sourcePort:Int;

	public function new(agent:IceAgent, address:String) {
		this.agent = agent;
		this.sourceAddress = address;
		this.sourcePort = 50000;
	}
}

private class Packet {
	public var from:Endpoint;
	public var payload:ByteArray;
	public var address:String;
	public var port:Int;

	public function new(from:Endpoint, payload:ByteArray, address:String, port:Int) {
		this.from = from;
		this.payload = payload;
		this.address = address;
		this.port = port;
	}
}
