package crossbyte.net.rtc;

import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.net.FakeTurnRelaySocket;
import crossbyte.net.ice.IceCandidate;
import crossbyte.test.Require;
import crossbyte.net.rtc.PeerDescription;
import utest.Assert;

/**
	Two peers with no path between them but a relay.

	The hard part of testing this is that a loopback machine always has a path,
	so a connection made through a relay and one made round the side of it look
	identical from the outside. Three things make the difference visible.

	The peers are given only their relayed candidates, so neither is told any
	address of the other's it could dial. They bind different loopback
	addresses -- 127.0.0.2 and 127.0.0.3 -- so that a datagram sent from a peer
	directly and one forwarded by the relay do not share a source address. And
	the relay refuses to forward anything from an address no permission covers,
	which is what RFC 8656 requires and what turns "the answer went out the
	wrong way" from an invisible detail into a connection that does not come up.

	Without all three, a peer answering a check straight back at the relayed
	address it appears to come from would reach the relay's own socket, be
	forwarded, and work perfectly -- proving nothing about whether the routing
	is right.
**/
class PeerConnectionRelayTest extends utest.Test {
	public static inline var REALM:String = "crossbyte.test";
	public static inline var USERNAME:String = "peer";
	public static inline var PASSWORD:String = "secret";

	private function unsupported():Bool {
		if (!PeerConnection.isSupported) {
			Assert.isFalse(PeerConnection.isSupported);
			return true;
		}

		return false;
	}

	/** A relay lends an address, and it becomes a candidate like any other. **/
	public function testARelayLendsAnAddressThatBecomesACandidate():Void {
		if (unsupported()) return;

		var server = relayServer();
		var connection = new PeerConnection(true);

		try {
			server.start();
			connection.bind(0, "127.0.0.1");

			var gathered:IceCandidate = null;
			var failure:String = null;

			connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(c -> gathered = c, e -> failure = e);
			pumpUntil(() -> gathered != null || failure != null, 8.0);

			Assert.isNull(failure, failure);
			Assert.notNull(gathered, "the relay allocated nothing");

			if (gathered == null) {
				return;
			}

			Assert.equals("relay", (gathered.type : String));
			Assert.equals(gathered.address, connection.relayedCandidate.address);

			// The address is the relay's, not this machine's: that is the whole
			// point, and a candidate carrying the local port would be a peer
			// telling the far side to dial somewhere it cannot reach.
			Assert.notEquals(connection.localPort, gathered.port);

			var carried = false;

			for (candidate in connection.description().candidates) {
				if (candidate.address == gathered.address && candidate.port == gathered.port) {
					carried = true;
				}
			}

			Assert.isTrue(carried, "the relayed address never reached the description");

			// One exchange refused for want of credentials, then one signed
			// with them. A relay that granted the first would be one that
			// relays for anybody who asks.
			Assert.equals(1, server.relay.count("refused-401"));
			Assert.equals(1, server.relay.count("allocated"));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/**
		The whole stack over a relay, with no other path in existence.

		Neither peer is told an address of the other's except the one the relay
		lends, so every check, the DTLS handshake and the message itself cross
		the server twice.
	**/
	public function testTwoPeersConnectThroughARelayAlone():Void {
		if (unsupported()) return;

		var server = relayServer();
		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		var heard:String = null;

		try {
			server.start();

			// Different loopback addresses, so a datagram a peer sent itself and
			// one the relay forwarded do not look alike to the server.
			alice.bind(0, "127.0.0.2");
			bob.bind(0, "127.0.0.3");

			var relays = 0;
			var failure:String = null;

			alice.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> relays++, e -> failure = e);
			bob.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> relays++, e -> failure = e);

			pumpUntil(() -> relays == 2 || failure != null, 10.0);

			Assert.isNull(failure, failure);
			Assert.equals(2, relays);

			if (relays != 2) {
				return;
			}

			bob.onChannel = function(channel:DataChannel):Void {
				channel.onMessage = text -> heard = text;
			};

			// Only the relayed candidate crosses. Anything else would give the
			// peers a way round the relay and make this a test of loopback.
			alice.connect(relayOnly(bob));
			bob.connect(relayOnly(alice));

			pumpUntil(() -> alice.connected && bob.connected, 25.0);

			Assert.isTrue(alice.connected, "the offering peer never connected through the relay");
			Assert.isTrue(bob.connected, "the answering peer never connected through the relay");

			if (!alice.connected || !bob.connected) {
				return;
			}

			// And the path it settled on is the relayed one, since it is the
			// only one either peer was ever given.
			Assert.equals("relay", (alice.agent.selectedPair.local.type : String));

			var chat = alice.createDataChannel("chat");
			pumpUntil(() -> chat.open, 8.0);
			Assert.isTrue(chat.open, "the channel never opened over the relay");

			if (!chat.open) {
				return;
			}

			chat.send("across a relay");
			pumpUntil(() -> heard != null, 8.0);
			Assert.equals("across a relay", heard, "a message did not survive the relay");

			// Traffic went the long way round rather than the peers finding
			// each other.
			Assert.isTrue(forwarded(server) > 0, "nothing was ever forwarded");

			// And the short way round was tried and refused, which is what makes
			// the connection attributable to the relay. Each peer pairs its host
			// candidate with the other's relayed address too -- that pair has the
			// higher priority and goes first -- and the datagram arrives at the
			// relay socket from an address no permission covers, so the server
			// drops it exactly as a real one would. That the connection came up
			// anyway is the whole claim.
			Assert.isTrue(server.relay.count("peer-dropped") > 0,
				"nothing was refused, so the direct pair was never tried and the relay was not what carried this");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		alice.close();
		bob.close();
		server.close();
	}

	/**
		A relay that goes away takes the connection that ran through it, and
		says so.

		The allocation failing to refresh set a flag nothing read. `allocated`
		had resolved long before and could not report it, so a connection
		whose only path was the relay simply went quiet -- until consent gave
		up on it half a minute later, blaming the peer.
	**/
	public function testLosingTheRelayEndsAConnectionThatRanThroughIt():Void {
		if (unsupported()) return;

		var server = relayServer();
		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		try {
			server.start();
			alice.bind(0, "127.0.0.2");
			bob.bind(0, "127.0.0.3");

			var relays = 0;
			var failure:String = null;
			alice.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> relays++, e -> failure = e);
			bob.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> relays++, e -> failure = e);
			pumpUntil(() -> relays == 2 || failure != null, 10.0);

			if (relays != 2) {
				Assert.fail("the relay never allocated: " + failure);
				alice.close();
				bob.close();
				server.close();
				return;
			}

			alice.connect(relayOnly(bob));
			bob.connect(relayOnly(alice));
			pumpUntil(() -> alice.connected && bob.connected, 25.0);

			if (!alice.connected || !bob.connected) {
				Assert.fail("the two never connected through the relay");
				alice.close();
				bob.close();
				server.close();
				return;
			}

			var reasons:Array<String> = [];
			alice.onClose = reason -> reasons.push(reason);

			// The relay stops renewing, and the next refresh is brought forward
			// from five minutes to now rather than waited out.
			server.relay.refuseRefresh = true;
			@:privateAccess alice.__turn.__refreshAt = 0;

			pumpUntil(() -> reasons.length > 0, 5.0);

			Assert.equals(1, reasons.length, "losing the relay the path ran through was reported " + reasons.length + " times");
			Assert.isFalse(alice.connected, "the connection still reports itself up with its relay gone");

			if (reasons.length > 0) {
				Assert.isTrue(reasons[0].indexOf("relay") >= 0, "the reason does not say the relay went: " + reasons[0]);
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		alice.close();
		bob.close();
		server.close();
	}

	/**
		A peer is permitted before anything is sent to it.

		A relay discards a Send indication for a peer no permission covers, and
		says nothing about it. From the sending end that is indistinguishable
		from a peer that is not there, and the connection simply never comes up.
	**/
	public function testAPeerIsPermittedBeforeAnythingIsSentToIt():Void {
		if (unsupported()) return;

		var server = relayServer();
		var connection = new PeerConnection(true);

		try {
			server.start();
			connection.bind(0, "127.0.0.2");

			var gathered:IceCandidate = null;
			connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(c -> gathered = c, _ -> {});
			pumpUntil(() -> gathered != null, 8.0);

			Assert.notNull(gathered);

			if (gathered == null) {
				return;
			}

			// A peer that exists nowhere: what matters is the order of what
			// leaves, not whether anybody answers.
			var remote:PeerDescription = {
				usernameFragment: "remoteufrag",
				password: "remotepasswordlongenough",
				fingerprint: connection.description().fingerprint,
				candidates: [{address: "127.0.0.9", port: 40404, type: "host", priority: 2130706431}]
			};

			connection.connect(remote);
			pumpUntil(() -> forwarded(server) > 0, 5.0);

			Assert.isTrue(forwarded(server) > 0, "no check was ever wrapped for the relay");
			Assert.equals(0, server.relay.count("send-unpermitted"), "traffic was sent to a peer the relay had not been told to expect");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/** Credentials the relay does not accept are reported, not retried forever. **/
	public function testCredentialsTheRelayRejectsAreReported():Void {
		if (unsupported()) return;

		var server = relayServer();
		var connection = new PeerConnection(true);

		try {
			server.start();
			connection.bind(0, "127.0.0.1");

			var gathered:IceCandidate = null;
			var failure:String = null;

			connection.gatherRelayed("127.0.0.1", USERNAME, "wrong", server.port).then(c -> gathered = c, e -> failure = e);
			pumpUntil(() -> gathered != null || failure != null, 8.0);

			Assert.isNull(gathered);
			Assert.notNull(failure, "a relay that refuses twice left the request outstanding");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/** One allocation at a time; a second would leak the first. **/
	public function testASecondRelayIsRefused():Void {
		if (unsupported()) return;

		var server = relayServer();
		var connection = new PeerConnection(true);

		try {
			server.start();
			connection.bind(0, "127.0.0.1");

			var second:String = null;
			connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> {}, _ -> {});
			connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> {}, e -> second = e);

			Assert.notNull(second, "a second allocation neither ran nor was refused");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/** Closing settles what was outstanding, rather than leaving it pending forever. **/
	public function testClosingEndsAnOutstandingAllocation():Void {
		if (unsupported()) return;

		var server = relayServer();
		var connection = new PeerConnection(true);

		try {
			server.relay.dropAll = true;
			server.start();
			connection.bind(0, "127.0.0.1");

			var settled = false;
			connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> settled = true, _ -> settled = true);

			Assert.isFalse(settled, "the allocation ended before anything happened");
			connection.close();

			Assert.isTrue(settled, "closing left a future nobody will ever complete");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/**
		Asked for, a channel carries the traffic and the wrapper goes away.

		Thirty-six bytes of STUN around every datagram becomes four. The
		connection is the same one either way, which is the point: nothing above
		the relay knows or has to.
	**/
	public function testChannelsCarryTheTrafficWhenAskedFor():Void {
		if (unsupported()) return;

		var server = relayServer();
		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		var heard:String = null;

		try {
			server.start();
			alice.bind(0, "127.0.0.2");
			bob.bind(0, "127.0.0.3");

			var relays = 0;
			var failure:String = null;

			alice.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port, true).then(_ -> relays++, e -> failure = e);
			bob.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port, true).then(_ -> relays++, e -> failure = e);

			pumpUntil(() -> relays == 2 || failure != null, 10.0);

			Assert.isNull(failure, failure);

			if (relays != 2) {
				Assert.fail("only " + relays + " allocations were granted");
				return;
			}

			bob.onChannel = function(channel:DataChannel):Void {
				channel.onMessage = text -> heard = text;
			};

			alice.connect(relayOnly(bob));
			bob.connect(relayOnly(alice));

			pumpUntil(() -> alice.connected && bob.connected, 25.0);

			Assert.isTrue(alice.connected, "the offering peer never connected over a channel");
			Assert.isTrue(bob.connected, "the answering peer never connected over a channel");

			if (!alice.connected || !bob.connected) {
				return;
			}

			var chat = alice.createDataChannel("chat");
			pumpUntil(() -> chat.open, 8.0);

			if (!chat.open) {
				Assert.fail("the data channel never opened over a relay channel");
				return;
			}

			chat.send("four bytes instead of thirty-six");
			pumpUntil(() -> heard != null, 8.0);
			Assert.equals("four bytes instead of thirty-six", heard);

			// Both peers bound one, and the traffic really went through them
			// rather than the connection quietly staying on indications.
			Assert.equals(2, server.relay.count("channel-bound"));
			Assert.isTrue(server.relay.count("channeldata-relayed") > 0, "a channel was bound and then never used");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		alice.close();
		bob.close();
		server.close();
	}

	/** Not asked for, nothing is bound and nothing changes. **/
	public function testChannelsAreNotAskedForUnlessWanted():Void {
		if (unsupported()) return;

		var server = relayServer();
		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		try {
			server.start();
			alice.bind(0, "127.0.0.2");
			bob.bind(0, "127.0.0.3");

			var relays = 0;
			alice.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> relays++, _ -> {});
			bob.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> relays++, _ -> {});
			pumpUntil(() -> relays == 2, 10.0);

			alice.connect(relayOnly(bob));
			bob.connect(relayOnly(alice));
			pumpUntil(() -> alice.connected && bob.connected, 25.0);

			Assert.isTrue(alice.connected, "the default path stopped working");
			Assert.equals(0, server.relay.count("channel-bound"));
			Assert.equals(0, server.relay.count("channeldata-relayed"));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		alice.close();
		bob.close();
		server.close();
	}

	/**
		A relay that refuses to bind is the safe half of getting this wrong.

		Told no, the client keeps wrapping every datagram in an indication and
		the connection is the same one at the old price. It is the relay that
		says yes and then drops what arrives that has nothing to fall back
		from -- see `TurnClient`, and node-turn, which does exactly that.
	**/
	public function testARelayThatRefusesAChannelStillCarriesTheConnection():Void {
		if (unsupported()) return;

		var server = relayServer();
		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		var heard:String = null;

		try {
			server.relay.refuseChannels = true;
			server.start();
			alice.bind(0, "127.0.0.2");
			bob.bind(0, "127.0.0.3");

			var relays = 0;
			alice.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port, true).then(_ -> relays++, _ -> {});
			bob.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port, true).then(_ -> relays++, _ -> {});
			pumpUntil(() -> relays == 2, 10.0);

			bob.onChannel = function(channel:DataChannel):Void {
				channel.onMessage = text -> heard = text;
			};

			alice.connect(relayOnly(bob));
			bob.connect(relayOnly(alice));
			pumpUntil(() -> alice.connected && bob.connected, 25.0);

			Assert.isTrue(alice.connected, "a refused channel took the connection with it");

			if (!alice.connected || !bob.connected) {
				return;
			}

			var chat = alice.createDataChannel("chat");
			pumpUntil(() -> chat.open, 8.0);

			if (!chat.open) {
				Assert.fail("the data channel never opened after the refusal");
				return;
			}

			chat.send("still going");
			pumpUntil(() -> heard != null, 8.0);
			Assert.equals("still going", heard);

			Assert.equals(0, server.relay.count("channel-bound"), "a refused bind was recorded as one");
			Assert.equals(0, server.relay.count("channeldata-relayed"), "traffic went over a channel that was refused");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		alice.close();
		bob.close();
		server.close();
	}

	/**
		A relay that refuses one of the peer's addresses still carries the
		connection.

		The auditor's case, end to end. Alice binds a wildcard, so she records
		no host candidate and her only way out is her relay. Bob offers his host
		address and his relayed one, and the relay refuses to forward to the
		host address, the way a hardened relay refuses a private or loopback one.
		ICE pairs Alice's relayed candidate with Bob's host address first, and
		the relay's 403 for it closed her whole allocation -- so the relayed pair
		that would have worked was never tried, and neither peer connected.
	**/
	public function testARelayRefusingOneOfThePeersAddressesStillConnects():Void {
		if (unsupported()) return;

		var server = relayServer();
		server.relay.denyPeers = ["127.0.0.3"];

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		try {
			server.start();
			alice.bind(0, "0.0.0.0");
			bob.bind(0, "127.0.0.3");

			var relays = 0;
			var failure:String = null;
			alice.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> relays++, e -> failure = e);
			bob.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(_ -> relays++, e -> failure = e);
			pumpUntil(() -> relays == 2 || failure != null, 10.0);

			if (relays != 2) {
				Assert.fail("the relay never allocated: " + failure);
				alice.close();
				bob.close();
				server.close();
				return;
			}

			// Bob's host address as well as his relayed one.
			alice.connect(bob.description());
			bob.connect(relayOnly(alice));
			pumpUntil(() -> (alice.connected && bob.connected) || alice.closeReason != null || bob.closeReason != null, 20.0);

			Assert.isTrue(server.relay.count("permission-403") > 0, "the relay never refused Bob's host address, so this proved nothing");
			Assert.isTrue(alice.connected, "one refused address took Alice's relay down with it: " + alice.closeReason);
			Assert.isTrue(bob.connected, "Bob never connected: " + bob.closeReason);

			if (alice.connected) {
				Assert.equals("relay", (alice.agent.selectedPair.local.type : String));
				Assert.equals("relay", (alice.agent.selectedPair.remote.type : String));
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		alice.close();
		bob.close();
		server.close();
	}

	/**
		Closing a connection frees the allocation it made on the relay.

		It did not: the relay held it for its whole lifetime, and a
		reconnecting application ran into the relay's quota.
	**/
	public function testClosingFreesTheRelayAllocation():Void {
		if (unsupported()) return;

		var server = relayServer();
		var connection = new PeerConnection(true);

		try {
			server.start();
			connection.bind(0, "127.0.0.1");

			var gathered:IceCandidate = null;
			connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(c -> gathered = c, _ -> {});
			pumpUntil(() -> gathered != null, 8.0);

			Assert.equals(1, server.relay.allocations, "the relay never allocated, so this proved nothing");

			connection.close();
			pumpUntil(() -> server.relay.allocations == 0, 3.0);

			Assert.equals(1, server.relay.count("deallocated"), "closing the connection left its allocation on the relay");
			Assert.equals(0, server.relay.allocations);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/**
		A relay that refuses is followed by the next in the list, and the one
		that allocates lends the candidate.
	**/
	public function testTheNextRelayIsAskedWhenOneRefuses():Void {
		if (unsupported()) return;

		var full = relayServer();
		full.relay.allocateError = {code: 486, reason: "Allocation Quota Reached"};
		var good = relayServer();
		var connection = new PeerConnection(true);

		try {
			full.start();
			good.start();
			connection.bind(0, "127.0.0.1");

			var gathered:IceCandidate = null;
			var failure:String = null;
			connection.gatherRelayedFrom([
				{address: "127.0.0.1", port: full.port, username: USERNAME, password: PASSWORD},
				{address: "127.0.0.1", port: good.port, username: USERNAME, password: PASSWORD}
			]).then(c -> gathered = c, e -> failure = e);
			pumpUntil(() -> gathered != null || failure != null, 10.0);

			Assert.isNull(failure, failure);
			Assert.notNull(gathered, "neither relay lent an address");
			Assert.equals(1, full.relay.count("allocate-error"), "the first relay was never asked");
			Assert.equals(1, good.relay.allocations, "the second relay holds no allocation");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		full.close();
		good.close();
	}

	/**
		A relay that refused is not in the way of asking another, and its
		refusal says why in a form code can read.

		The auditor's case. The first relay's 486 left the connection holding
		a dead relay for good -- asking a second was refused as "already has a
		relay" -- and the failure was a sentence with no code in it.
	**/
	public function testARelayThatRefusedIsNotInTheWayOfAnother():Void {
		if (unsupported()) return;

		var full = relayServer();
		full.relay.allocateError = {code: 486, reason: "Allocation Quota Reached"};
		var good = relayServer();
		var connection = new PeerConnection(true);

		try {
			full.start();
			good.start();
			connection.bind(0, "127.0.0.1");

			var refused:Future<IceCandidate> = connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, full.port);
			pumpUntil(() -> refused.completed, 10.0);

			Assert.isTrue(refused.completed && !refused.succeeded, "the full relay did not refuse");

			var cause:crossbyte.net.TurnError = Std.downcast(refused.cause, crossbyte.net.TurnError);
			Require.notNull(cause, "the refusal carried no TurnError");
			Assert.equals(486, cause.code);

			var gathered:IceCandidate = null;
			var failure:String = null;
			connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, good.port).then(c -> gathered = c, e -> failure = e);
			pumpUntil(() -> gathered != null || failure != null, 10.0);

			Assert.isNull(failure, "a relay that had refused was still in the way: " + failure);
			Assert.notNull(gathered);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		full.close();
		good.close();
	}

	/**
		A relay that loses the allocation is asked for another, and the new
		address announced for the peer to be told of.

		A relay restarting, or a network change moving the 5-tuple it knew the
		connection by, cost the connection its relayed candidate for good.
	**/
	public function testALostRelayIsReplaced():Void {
		if (unsupported()) return;

		var server = relayServer();
		var connection = new PeerConnection(true);

		try {
			server.start();
			connection.bind(0, "127.0.0.1");

			var first:IceCandidate = null;
			connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(c -> first = c, _ -> {});
			pumpUntil(() -> first != null, 8.0);
			Require.notNull(first, "the relay never allocated");

			var announced:Array<CandidateDescription> = [];
			connection.onLocalCandidate = candidate -> announced.push(candidate);

			// The relay restarts and forgets every allocation; the next refresh
			// finds out, brought forward from five minutes to now.
			server.relay.forgetEverything();
			@:privateAccess connection.__turn.refresh(haxe.Timer.stamp());
			pumpUntil(() -> announced.length > 0, 8.0);

			Assert.equals(1, announced.length, "no replacement relayed candidate was announced");

			if (announced.length > 0) {
				Assert.equals("relay", announced[0].type);
				Assert.notEquals(first.port, announced[0].port, "the candidate announced is the lost one");
			}

			Require.notNull(connection.relayedCandidate, "the connection has no relayed candidate after the replacement");
			Assert.equals(1, server.relay.allocations);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/**
		An ICE restart asks the relay whether it is still there, and replaces
		one that is not, so the restart has a relayed candidate to offer.
	**/
	public function testAnIceRestartReplacesARelayThatWent():Void {
		if (unsupported()) return;

		var server = relayServer();
		var connection = new PeerConnection(true);

		try {
			server.start();
			connection.bind(0, "127.0.0.2");

			var first:IceCandidate = null;
			connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, server.port).then(c -> first = c, _ -> {});
			pumpUntil(() -> first != null, 8.0);
			Require.notNull(first, "the relay never allocated");

			// A peer that exists nowhere: what matters is what the restart asks
			// of the relay, not whether anybody answers.
			connection.connect({
				usernameFragment: "remoteufrag",
				password: "remotepasswordlongenough",
				fingerprint: connection.description().fingerprint,
				candidates: [{address: "127.0.0.9", port: 40404, type: "host", priority: 2130706431}]
			});

			var announced:Array<CandidateDescription> = [];
			connection.onLocalCandidate = candidate -> announced.push(candidate);

			// The relay lost the allocation, and nothing here knows yet.
			server.relay.forgetEverything();
			connection.restartIce();
			pumpUntil(() -> announced.length > 0, 8.0);

			Assert.equals(1, announced.length, "the restart has no replacement relayed candidate");
			Assert.isTrue(server.relay.count("refused-437") > 0, "the relay was never asked whether it still held the allocation");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/** There is no socket to allocate through before `bind`. **/
	public function testRelayingBeforeBindingIsRefused():Void {
		if (unsupported()) return;

		var connection = new PeerConnection(true);
		var failure:String = null;

		connection.gatherRelayed("127.0.0.1", USERNAME, PASSWORD, 3478).then(_ -> {}, e -> failure = e);

		Assert.notNull(failure, "allocating without a socket did not say so");

		if (failure != null) {
			Assert.isTrue(failure.indexOf("bind") >= 0, "the failure should name what is missing: " + failure);
		}

		connection.close();
	}

	// ------------------------------------------------------------------

	/**
		The peer's description with everything but the relayed candidate taken
		out, which is what the signalling channel would carry if the relay were
		the only address that worked.
	**/
	private static function relayOnly(connection:PeerConnection):PeerDescription {
		var described = connection.description();
		var kept:Array<CandidateDescription> = [];

		for (candidate in described.candidates) {
			if (candidate.type == "relay") {
				kept.push(candidate);
			}
		}

		described.candidates = kept;
		return described;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;

		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	/**
		A TURN relay that actually forwards, on real sockets: `FakeTurnRelay`,
		with this suite's realm and credential.

		It refuses an unauthenticated allocation, checks the signed one against
		the long-term key, signs what it answers, lends a real socket as the
		relayed address and forwards between that socket and its client in both
		directions. And it enforces permissions, which is the part that gives
		these tests their teeth: a relay drops what it is asked to forward from
		an address no permission covers and reports nothing, so a peer whose
		answers leave by the wrong route never connects -- where a relay that
		skipped this would let them through and bless the bug.
	**/
	private static function relayServer():FakeTurnRelaySocket {
		var server = new FakeTurnRelaySocket();
		server.relay.realm = REALM;
		server.relay.users = [USERNAME => PASSWORD];
		return server;
	}

	/** Datagrams the relay forwarded from a client to a peer, either way they were wrapped. **/
	private static function forwarded(server:FakeTurnRelaySocket):Int {
		return server.relay.count("send-relayed") + server.relay.count("channeldata-relayed");
	}
}
