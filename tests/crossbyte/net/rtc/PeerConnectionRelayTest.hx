package crossbyte.net.rtc;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunMessage.StunAttribute;
import crossbyte.net.ice.IceCandidate;
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

		var server = new FakeTurnServer();
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
			Assert.equals(1, server.refusedUnauthenticated);
			Assert.equals(1, server.allocations);
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

		var server = new FakeTurnServer();
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
			Assert.isTrue(server.forwarded > 0, "nothing was ever forwarded");

			// And the short way round was tried and refused, which is what makes
			// the connection attributable to the relay. Each peer pairs its host
			// candidate with the other's relayed address too -- that pair has the
			// higher priority and goes first -- and the datagram arrives at the
			// relay socket from an address no permission covers, so the server
			// drops it exactly as a real one would. That the connection came up
			// anyway is the whole claim.
			Assert.isTrue(server.refusedInbound > 0,
				"nothing was refused, so the direct pair was never tried and the relay was not what carried this");
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

		var server = new FakeTurnServer();
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
			pumpUntil(() -> server.forwarded > 0, 5.0);

			Assert.isTrue(server.forwarded > 0, "no check was ever wrapped for the relay");
			Assert.isTrue(server.permittedBeforeFirstSend, "traffic was sent to a peer the relay had not been told to expect");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/** Credentials the relay does not accept are reported, not retried forever. **/
	public function testCredentialsTheRelayRejectsAreReported():Void {
		if (unsupported()) return;

		var server = new FakeTurnServer();
		var connection = new PeerConnection(true);

		try {
			server.rejectCredentials = true;
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

		var server = new FakeTurnServer();
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

		var server = new FakeTurnServer();
		var connection = new PeerConnection(true);

		try {
			server.ignoreEverything = true;
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

		var server = new FakeTurnServer();
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
			Assert.equals(2, server.channels);
			Assert.isTrue(server.overChannel > 0, "a channel was bound and then never used");
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

		var server = new FakeTurnServer();
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
			Assert.equals(0, server.channels);
			Assert.equals(0, server.overChannel);
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

		var server = new FakeTurnServer();
		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		var heard:String = null;

		try {
			server.refuseChannels = true;
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

			Assert.equals(0, server.channels, "a refused bind was recorded as one");
			Assert.equals(0, server.overChannel, "traffic went over a channel that was refused");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		alice.close();
		bob.close();
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
}

/**
	A TURN server that actually forwards, standing in memory.

	Enough of RFC 8656 to be told apart from a stub: it refuses an
	unauthenticated allocation, checks the integrity of the signed one against
	the long-term key, lends a real socket as the relayed address, and forwards
	between that socket and its client in both directions.

	It enforces permissions, which is the part that gives the test its teeth. A
	relay drops what it is asked to forward from an address no permission covers
	and reports nothing, so a peer whose answers leave by the wrong route simply
	never connects -- and a server that skipped this would let those answers
	through and bless the bug.
**/
private class FakeTurnServer {
	public var port(default, null):Int = 0;

	/** Allocations granted, not counting the ones refused for credentials. **/
	public var allocations(default, null):Int = 0;

	/** Requests turned away because they carried no credentials. **/
	public var refusedUnauthenticated(default, null):Int = 0;

	/** Datagrams forwarded from a client out to a peer. **/
	public var forwarded(default, null):Int = 0;

	/** Datagrams that arrived for a client from an address it never permitted. **/
	public var refusedInbound(default, null):Int = 0;

	/** Whether every peer sent to had been permitted first. **/
	public var permittedBeforeFirstSend(default, null):Bool = true;

	/** Datagrams a client sent wrapped in a channel rather than an indication. **/
	public var overChannel(default, null):Int = 0;

	/** Channels bound. **/
	public var channels(default, null):Int = 0;

	/**
		Refuse to bind a channel, as a relay without them would.

		The safe half of getting channels wrong: a client told no keeps using
		indications. The dangerous half -- agreeing and then dropping what
		arrives -- is what `TurnClient` documents and why they are off by
		default.
	**/
	public var refuseChannels:Bool = false;

	/** Refuse even correctly signed requests, as a relay with other credentials would. **/
	public var rejectCredentials:Bool = false;

	/** Say nothing at all, as a relay that is not there would. **/
	public var ignoreEverything:Bool = false;

	private var __socket:DatagramSocket;
	private var __allocations:Array<Allocation> = [];

	public function new() {}

	public function start():Void {
		__socket = new DatagramSocket();
		__socket.bind(0, "127.0.0.1");
		port = __socket.localPort;
		__socket.addEventListener(DatagramSocketDataEvent.DATA, __onControl);
		__socket.receive();
	}

	public function close():Void {
		for (allocation in __allocations) {
			try {
				allocation.relay.close();
			} catch (_:Dynamic) {}
		}

		__allocations = [];

		if (__socket != null) {
			try {
				__socket.close();
			} catch (_:Dynamic) {}

			__socket = null;
		}
	}

	private function __onControl(e:DatagramSocketDataEvent):Void {
		if (ignoreEverything) {
			return;
		}

		// Before the STUN parse, because ChannelData is not STUN: its first two
		// bits are set, which is exactly what tells it apart. A relay that
		// parses first and asks afterwards drops every one of these silently.
		if (__forwardChannelData(e)) {
			return;
		}

		var message = StunMessage.decode(e.data);

		if (message == null) {
			return;
		}

		switch (message.type) {
			case StunMessage.ALLOCATE_REQUEST:
				__allocate(message, e.srcAddress, e.srcPort);
			case StunMessage.CREATE_PERMISSION_REQUEST:
				__permit(message, e.srcAddress, e.srcPort);
			case StunMessage.REFRESH_REQUEST:
				__reply(new StunMessage(StunMessage.REFRESH_SUCCESS, message.transactionId, [StunMessage.lifetime(600)]), e.srcAddress,
					e.srcPort);
			case StunMessage.SEND_INDICATION:
				__forward(message, e.srcAddress, e.srcPort);
			case StunMessage.CHANNEL_BIND_REQUEST:
				__bind(message, e.srcAddress, e.srcPort);
			default:
		}
	}

	private function __allocate(message:StunMessage, from:String, fromPort:Int):Void {
		// Unsigned: say which realm and nonce to sign against, and nothing else.
		// A relay that allocated here would relay for anybody who asked.
		if (message.attribute(StunMessage.ATTR_MESSAGE_INTEGRITY) == null) {
			refusedUnauthenticated++;
			__reply(new StunMessage(StunMessage.ALLOCATE_ERROR, message.transactionId, [
				StunMessage.errorCode(401, "Unauthorized"),
				StunMessage.text(StunMessage.ATTR_REALM, PeerConnectionRelayTest.REALM),
				StunMessage.text(StunMessage.ATTR_NONCE, "nonce-for-the-test")
			]), from, fromPort);
			return;
		}

		var username = message.textOf(StunMessage.ATTR_USERNAME);
		var key = StunMessage.longTermKey(username != null ? username : "", PeerConnectionRelayTest.REALM, PeerConnectionRelayTest.PASSWORD);

		if (rejectCredentials || !message.verifyIntegrityWithKey(key)) {
			__reply(new StunMessage(StunMessage.ALLOCATE_ERROR, message.transactionId, [
				StunMessage.errorCode(401, "Unauthorized"),
				StunMessage.text(StunMessage.ATTR_REALM, PeerConnectionRelayTest.REALM),
				StunMessage.text(StunMessage.ATTR_NONCE, "nonce-for-the-test")
			]), from, fromPort);
			return;
		}

		var allocation = new Allocation(from, fromPort);
		allocation.relay = new DatagramSocket();
		allocation.relay.bind(0, "127.0.0.1");
		allocation.relay.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			__deliver(allocation, e);
		});
		allocation.relay.receive();

		__allocations.push(allocation);
		allocations++;

		__reply(new StunMessage(StunMessage.ALLOCATE_SUCCESS, message.transactionId, [
			StunMessage.xorRelayed("127.0.0.1", allocation.relay.localPort),
			StunMessage.xorMappedAddress(from, fromPort),
			StunMessage.lifetime(600)
		]), from, fromPort);
	}

	/**
		Binds a channel number to a peer, and permits it at the same time.

		RFC 8656 section 12 has a ChannelBind do both, which is why a client
		that has one still works without asking for a permission separately.
	**/
	private function __bind(message:StunMessage, from:String, fromPort:Int):Void {
		var allocation = __find(from, fromPort);
		var peer = message.addressOf(StunMessage.ATTR_XOR_PEER_ADDRESS);
		var number = message.uintOf(StunMessage.ATTR_CHANNEL_NUMBER, 0) >> 16;

		if (refuseChannels || allocation == null || peer == null || number < 0x4000 || number > 0x7FFE) {
			__reply(new StunMessage(StunMessage.CHANNEL_BIND_ERROR, message.transactionId,
				[StunMessage.errorCode(400, "Bad Request")]), from, fromPort);
			return;
		}

		if (allocation.permitted.indexOf(peer.address) < 0) {
			allocation.permitted.push(peer.address);
		}

		allocation.channels.set(number, peer.address + ":" + peer.port);
		channels++;

		__reply(new StunMessage(StunMessage.CHANNEL_BIND_SUCCESS, message.transactionId), from, fromPort);
	}

	/**
		A client's ChannelData, unwrapped and sent on to the peer it stands for.

		@return Whether that is what this was. A number outside the range or one
		no channel was bound to belongs to somebody else on the socket.
	**/
	private function __forwardChannelData(e:DatagramSocketDataEvent):Bool {
		if (e.data.length < 4) {
			return false;
		}

		e.data.position = 0;
		var number = (e.data.readUnsignedByte() << 8) | e.data.readUnsignedByte();
		var length = (e.data.readUnsignedByte() << 8) | e.data.readUnsignedByte();

		if (number < 0x4000 || number > 0x7FFE || 4 + length > e.data.length) {
			e.data.position = 0;
			return false;
		}

		var allocation = __find(e.srcAddress, e.srcPort);

		if (allocation == null || !allocation.channels.exists(number)) {
			e.data.position = 0;
			return false;
		}

		var peer = allocation.channels.get(number).split(":");
		var payload = new ByteArray();

		if (length > 0) {
			e.data.readBytes(payload, 0, length);
		}

		e.data.position = 0;
		payload.position = 0;
		overChannel++;
		forwarded++;
		allocation.relay.send(payload, 0, payload.length, peer[0], Std.parseInt(peer[1]));
		return true;
	}

	private function __permit(message:StunMessage, from:String, fromPort:Int):Void {
		var allocation = __find(from, fromPort);
		var peer = message.addressOf(StunMessage.ATTR_XOR_PEER_ADDRESS);

		if (allocation != null && peer != null && allocation.permitted.indexOf(peer.address) < 0) {
			allocation.permitted.push(peer.address);
		}

		__reply(new StunMessage(StunMessage.CREATE_PERMISSION_SUCCESS, message.transactionId), from, fromPort);
	}

	/** Client to peer: unwrap and send it on from the allocation's own socket. **/
	private function __forward(message:StunMessage, from:String, fromPort:Int):Void {
		var allocation = __find(from, fromPort);
		var peer = message.addressOf(StunMessage.ATTR_XOR_PEER_ADDRESS);
		var payload = message.attribute(StunMessage.ATTR_DATA);

		if (allocation == null || peer == null || payload == null) {
			return;
		}

		if (allocation.permitted.indexOf(peer.address) < 0) {
			permittedBeforeFirstSend = false;
			return;
		}

		forwarded++;
		payload.position = 0;
		allocation.relay.send(payload, 0, payload.length, peer.address, peer.port);
	}

	/** Peer to client: wrap it up, if the client asked to hear from there. **/
	private function __deliver(allocation:Allocation, e:DatagramSocketDataEvent):Void {
		if (allocation.permitted.indexOf(e.srcAddress) < 0) {
			refusedInbound++;
			return;
		}

		e.data.position = 0;

		// Over the channel if one stands for this peer, which is the direction
		// that saves the bytes on the way back.
		var key = e.srcAddress + ":" + e.srcPort;

		for (number in allocation.channels.keys()) {
			if (allocation.channels.get(number) == key) {
				var framed = new ByteArray();
				framed.writeByte((number >> 8) & 0xFF);
				framed.writeByte(number & 0xFF);
				framed.writeByte((e.data.length >> 8) & 0xFF);
				framed.writeByte(e.data.length & 0xFF);
				framed.writeBytes(e.data, 0, e.data.length);
				framed.position = 0;

				__socket.send(framed, 0, framed.length, allocation.address, allocation.port);
				return;
			}
		}

		__reply(new StunMessage(StunMessage.DATA_INDICATION, __transaction(), [
			StunMessage.xorPeerAddress(e.srcAddress, e.srcPort),
			StunMessage.data(e.data)
		]), allocation.address, allocation.port);
	}

	private function __find(address:String, port:Int):Null<Allocation> {
		for (allocation in __allocations) {
			if (allocation.address == address && allocation.port == port) {
				return allocation;
			}
		}

		return null;
	}

	private function __reply(message:StunMessage, address:String, port:Int):Void {
		if (__socket == null) {
			return;
		}

		var payload = message.encode();
		__socket.send(payload, 0, payload.length, address, port);
	}

	private var __counter:Int = 0;

	private function __transaction():ByteArray {
		var bytes = new ByteArray();

		for (i in 0...12) {
			bytes.writeByte((__counter + i * 7) & 0xFF);
		}

		__counter++;
		bytes.position = 0;
		return bytes;
	}
}

private class Allocation {
	public var address:String;
	public var port:Int;
	public var relay:DatagramSocket;
	public var permitted:Array<String> = [];

	/** Channel number to "address:port" of the peer it stands for. **/
	public var channels:Map<Int, String> = new Map();

	public function new(address:String, port:Int) {
		this.address = address;
		this.port = port;
	}
}
