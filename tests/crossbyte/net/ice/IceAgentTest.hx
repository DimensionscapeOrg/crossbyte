package crossbyte.net.ice;

import crossbyte.io.ByteArray;
import haxe.Int64;
import crossbyte.net._internal.stun.StunMessage;
import utest.Assert;

/**
	Two agents, pointed at each other, with no socket between them.

	The agent was built without a transport precisely so this is possible: a
	`Wire` carries datagrams from one to the other, a counter stands in for the
	clock, and the whole exchange runs to completion deterministically on every
	target. What is being tested is the thing that is hardest to test over a
	real network and easiest to get wrong -- that two peers, each seeing only
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
		decides by looking at the checks -- and close() empties them, so after a
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
		properly drops all of it -- which would show up as two peers that never
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

		Assert.isTrue(bob.receive(backwards.encodeSigned(bob.localCredentials.password), ALICE_ADDRESS, PORT, 0),
			"a STUN message should still be consumed even when it is not answered");
		Assert.equals(0, sent.length, "a check addressed to another session was answered");

		// And the same message addressed correctly is answered, so what the
		// case above proves is the direction and not merely that nothing works.
		var forwards = new StunMessage(StunMessage.BINDING_REQUEST, StunMessage.bindingRequest().transactionId, [
			StunMessage.username(IceCredentials.username(bob.localCredentials, credentials("alice")))
		]);

		bob.receive(forwards.encodeSigned(bob.localCredentials.password), ALICE_ADDRESS, PORT, 0);
		Assert.isTrue(sent.length > 0, "a correctly addressed check went unanswered");
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
		A mapping neither peer could have known about.

		When a NAT gives a peer a different address for this destination than
		for the STUN server it asked earlier, the check arrives from somewhere
		that is on nobody's candidate list. The receiver reports where it saw
		it, and that becomes a peer-reflexive candidate -- frequently the only
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

		Roles are agreed out of band, and any exchange that can be raced -- both
		sides offering at once, a restart, a signalling path that reordered two
		messages -- leaves both convinced they are controlling. Nothing detects
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
		without recomputing would be relabelled rather than switched -- still
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
		// on what it is worth -- which is only true if both recomputed.
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

			queue.push(new Packet(endpoint, payload, toAddress, toPort));
		};
	}

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
