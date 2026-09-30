package crossbyte.net;

import crossbyte.io.ByteArray;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunMessage.StunAttribute;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

/**
	A relay standing in memory, and a client talking to it.

	`TurnClient` owns no socket, so the server here is a function that takes the
	bytes the client would have sent and answers with the bytes a relay would
	have sent back. That means the whole exchange -- including the refusal the
	handshake actually begins with -- runs deterministically on every target,
	and the awkward cases a real relay will not produce on demand (an expired
	nonce, a rejected credential) can simply be asked for.
**/
class TurnClientTest extends utest.Test {
	private static inline var RELAY:String = "203.0.113.10";
	private static inline var RELAY_PORT:Int = 3478;
	private static inline var REALM:String = "example.org";
	private static inline var NONCE:String = "nonce-one";

	private function unsupported():Bool {
		if (!TurnClient.isSupported) {
			Assert.isFalse(TurnClient.isSupported);
			return true;
		}

		return false;
	}

	/**
		The key a long-term credential signs with, pinned to arithmetic done
		outside Haxe.

		Not the password: TURN hashes username, realm and password together, so
		a relay can hold the digest instead of the password and a credential is
		bound to the realm it was issued for. Getting this wrong produces a
		client that authenticates against nothing.
	**/
	public function testTheLongTermKeyIsTheDigestAndNotThePassword():Void {
		var key = StunMessage.longTermKey("user", REALM, "secret");

		Assert.equals("a9832fed4a7567b40e43443f9f30c272", key.toHex());
		Assert.notEquals(Bytes.ofString("secret").toHex(), key.toHex());
	}

	/**
		The handshake begins with a refusal, and that is not a failure.

		A relay does not publish its realm, and the nonce it wants a request
		signed against is chosen per client -- so the first request has nothing
		to sign with and goes out bare. A client that treated the 401 as an
		error would never allocate anything.
	**/
	public function testAnAllocationSurvivesTheRefusalItStartsWith():Void {
		if (unsupported()) return;

		var relay = new Relay();
		var client = relay.client();
		var granted:ReflexiveAddress = null;

		client.allocated.then(address -> granted = address, _ -> {});
		client.allocate(0);
		relay.run(client, () -> client.active);

		Assert.isTrue(client.active, "the allocation never completed");
		Assert.notNull(granted, "the allocated future never resolved");
		Assert.equals("203.0.113.10", client.relayedAddress.address);
		Assert.equals(49152, client.relayedAddress.port);

		// The first request went out unsigned, the second signed. Anything else
		// means the exchange did not happen the way TURN specifies.
		Assert.equals(2, relay.allocateRequests, "the allocation did not take exactly one refusal and one retry");
		Assert.isFalse(relay.firstWasSigned, "the first request was signed against a realm the relay had not sent yet");
		Assert.isTrue(relay.lastWasSigned);
	}

	/**
		A nonce expires and the relay says so; the client takes the new one.

		Relays rotate nonces deliberately, so this is ordinary operation rather
		than an error path. A client that gave up here would lose its allocation
		on a timer.
	**/
	public function testAnExpiredNonceIsRetriedWithTheNewOne():Void {
		if (unsupported()) return;

		var relay = new Relay();
		relay.staleOnce = true;

		var client = relay.client();
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(0);
		relay.run(client, () -> client.active);

		Assert.isTrue(client.active, "an expired nonce ended the allocation instead of being retried");
		Assert.equals("nonce-two", relay.lastNonceSeen, "the client kept using the nonce the relay had rejected");
	}

	/**
		Credentials the relay will not accept fail once rather than looping.

		A 401 answered by a client that already had credentials means those
		credentials are wrong -- retrying with the same ones forever is how a
		client turns a rejected password into a flood.
	**/
	public function testRejectedCredentialsFailRatherThanLoop():Void {
		if (unsupported()) return;

		var relay = new Relay();
		relay.alwaysUnauthorized = true;

		var client = relay.client();
		var failure:String = null;
		client.allocated.then(_ -> {}, error -> failure = error);

		client.allocate(0);
		relay.run(client, () -> failure != null);

		Assert.notNull(failure, "a relay that refuses every credential never produced a failure");
		Assert.isFalse(client.active);
		// Two: the bare one, and one retry with credentials. Not more.
		Assert.equals(2, relay.allocateRequests, "the client kept retrying credentials the relay had already rejected");
	}

	/**
		A peer's traffic arrives wrapped, and comes out unwrapped.
	**/
	public function testDataFromAPeerIsDelivered():Void {
		if (unsupported()) return;

		var relay = new Relay();
		var client = relay.client();
		var received:String = null;
		var from:String = null;

		client.onData = function(payload, address, port):Void {
			payload.position = 0;
			received = payload.readUTFBytes(payload.length);
			from = address + ":" + port;
		};

		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(0);
		relay.run(client, () -> client.active);

		relay.deliver(client, "198.51.100.4", 40000, "through the relay");

		Assert.equals("through the relay", received);
		Assert.equals("198.51.100.4:40000", from);
	}

	/**
		Traffic to a peer goes out as an indication naming that peer.
	**/
	public function testSendingWrapsThePayloadForThePeer():Void {
		if (unsupported()) return;

		var relay = new Relay();
		var client = relay.client();

		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(0);
		relay.run(client, () -> client.active);

		var payload = new ByteArray();
		payload.writeUTFBytes("to the peer");
		client.sendTo(payload, "198.51.100.4", 40000);
		relay.run(client, () -> relay.lastIndication != null);

		var indication = relay.lastIndication;
		Assert.notNull(indication, "nothing was sent to the relay");

		if (indication == null) {
			return;
		}
		Assert.equals(StunMessage.SEND_INDICATION, indication.type);

		var peer = indication.addressOf(StunMessage.ATTR_XOR_PEER_ADDRESS);
		Require.notNull(peer);
		Assert.equals("198.51.100.4", peer.address);
		Assert.equals(40000, peer.port);

		var carried = indication.attribute(StunMessage.ATTR_DATA);
		Require.notNull(carried);
		carried.position = 0;
		Assert.equals("to the peer", carried.readUTFBytes(carried.length));
	}

	/**
		A peer that is not an IPv4 address is refused, and nothing is kept.

		XOR-PEER-ADDRESS is written as IPv4 here, as the allocation is, and its
		octets were read with `Std.parseInt` and written modulo 256: a peer
		named 1.2.3.999 was permitted as 1.2.3.231, and an IPv6 one as whatever
		its first group read as, so the relay forwarded to a host nobody named.
		A refused permission is not kept either, or every renewal would throw
		from `poll`.
	**/
	public function testOnlyAnIPv4PeerIsPermitted():Void {
		if (unsupported()) return;

		var relay = new Relay();
		var client = relay.client();
		client.useChannels = true;
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(0);
		relay.run(client, () -> client.active);

		var payload = new ByteArray();
		payload.writeUTFBytes("to nobody");

		for (address in ["1.2.3.999", "2001:db8::1", "010.1.1.1"]) {
			Assert.raises(() -> client.permit(address, 1), crossbyte.errors.ArgumentError, address + " was permitted");
			Assert.raises(() -> client.bindChannel(address, 40000, 1), crossbyte.errors.ArgumentError, address + " was bound");
			Assert.raises(() -> client.sendTo(payload, address, 40000), crossbyte.errors.ArgumentError, address + " was sent to");
		}

		relay.pump(client, 1);
		Assert.equals(0, relay.permissionRequests, "the relay was asked to let through a peer nobody named");
		Assert.isNull(relay.lastIndication, "the relay was asked to forward to a peer nobody named");

		// Past when a kept permission would be renewed.
		client.poll(1 + TurnClient.PERMISSION_REFRESH + 1);
		relay.pump(client, 1 + TurnClient.PERMISSION_REFRESH + 1);
		Assert.equals(0, relay.permissionRequests, "a refused permission was kept and renewed");
	}

	/**
		A permission asked for while a refresh is outstanding does not lose it.

		Only one request used to be tracked at a time, so a second started
		underneath the first would have abandoned it -- and the one abandoned
		was whichever was already running, which on a timer is the refresh.
		That does not fail loudly: the allocation just stops being renewed and
		the connection dies when it expires. Each request is its own
		transaction now, so the permission goes out beside the refresh and the
		refresh's answer is still recognised when it comes.
	**/
	public function testARequestStartedDuringAnotherDoesNotAbandonIt():Void {
		if (unsupported()) return;

		var relay = new Relay();
		relay.holdRefresh = true;

		var client = relay.client();
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(0);
		relay.run(client, () -> client.active);

		// Far enough past the halfway mark that a refresh is due.
		var now = 400.0;
		client.poll(now);
		relay.pump(client, now);
		Assert.equals(1, relay.refreshRequests, "no refresh was attempted");

		// A permission asked for while that refresh is still unanswered.
		client.permit("198.51.100.4", now);
		relay.pump(client, now);
		Assert.equals(1, relay.permissionRequests, "the permission was never sent");

		relay.holdRefresh = false;
		relay.answerHeld(client, now);
		relay.pump(client, now);
		client.poll(now + 0.1);
		relay.pump(client, now + 0.1);

		Assert.equals(1, relay.refreshRequests, "the refresh was retried, which means its answer was not matched");
		Assert.isTrue(client.active, "the allocation was lost with its refresh answered");
	}

	/**
		A permission is renewed before the relay forgets it.

		The allocation was refreshed on the tick, and so was every channel. A
		permission was asked for once and never again -- and refreshing an
		allocation does not renew its permissions (RFC 5766 section 8). Five
		minutes into a relayed call the relay starts dropping that peer and says
		nothing, which is the worst shape this can fail in: the connection is up,
		the allocation is healthy, and the media simply stops.
	**/
	public function testAPermissionIsRenewedBeforeItLapses():Void {
		if (unsupported()) return;

		var relay = new Relay();
		var client = relay.client();
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(0);
		relay.run(client, () -> client.active);

		var asked = 1.0;
		client.permit("198.51.100.4", asked);
		relay.run(client, () -> relay.permissionRequests > 0, asked);
		Assert.equals(1, relay.permissionRequests, "the permission was never asked for at all");

		// Past the renewal mark and still well inside the five minutes, so the
		// relay would still honour it -- and inside the allocation refresh at
		// 300, so nothing else is competing for the one request in flight.
		var later = asked + TurnClient.PERMISSION_REFRESH + 1;
		client.poll(later);
		relay.run(client, () -> relay.permissionRequests > 1, later);

		Assert.isTrue(relay.permissionRequests > 1,
			"the permission was never renewed, so the relay stops passing this peer at five minutes");
	}

	/**
		An allocation that stops being renewed is reported as lost.

		`allocated` resolved when the relay granted it and cannot be settled
		again, so a refresh the relay never answered only set `active` to
		false -- a flag nothing is obliged to read. A connection whose path ran
		through the relay went quiet with no reason given.
	**/
	public function testAnAllocationThatCannotBeRenewedIsReportedLost():Void {
		if (unsupported()) return;

		var relay = new Relay();
		var client = relay.client();
		var lost:Array<String> = [];
		client.onLost = reason -> lost.push(reason);
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(0);
		relay.run(client, () -> client.active);

		Assert.isTrue(client.active, "the relay never granted an allocation");

		// The refresh goes unanswered through every retransmission.
		relay.holdRefresh = true;
		var now = 400.0;

		for (_ in 0...200) {
			client.poll(now);
			relay.pump(client, now);
			now += 1.0;
		}

		Assert.isFalse(client.active);
		Assert.equals(1, lost.length, "an allocation that could not be renewed was reported lost " + lost.length + " times");
	}

	/**
		A lifetime of zero is the relay ending the allocation, and is reported.
	**/
	public function testARelayEndingTheAllocationIsReportedLost():Void {
		if (unsupported()) return;

		var relay = new Relay();
		var client = relay.client();
		var lost:Array<String> = [];
		client.onLost = reason -> lost.push(reason);
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(0);
		relay.run(client, () -> client.active);

		relay.endOnRefresh = true;
		client.poll(400.0);
		relay.pump(client, 400.0);

		Assert.isFalse(client.active, "a refresh granting no lifetime left the allocation active");
		Assert.equals(1, lost.length, "the relay ending the allocation was reported " + lost.length + " times");

		// And closing is not a loss: the caller already knows.
		var other = relay.client();
		var otherLost:Int = 0;
		other.onLost = _ -> otherLost++;
		other.allocated.then(_ -> {}, _ -> {});
		relay.endOnRefresh = false;
		other.allocate(0);
		relay.run(other, () -> other.active);
		other.close();

		Assert.equals(0, otherLost, "closing a client reported its allocation lost");
	}

	/**
		Closing before it completes tells whoever was waiting.

		Every path that settled this future ran from the handshake, and closing
		is what stops the handshake -- so a caller that closed mid-negotiation
		was left holding a future that could not settle either way. The same gap
		existed in every class in this stack that hands one out.
	**/
	public function testClosingBeforeTheRelayAnswersTellsWhoeverWaited():Void {
		if (unsupported()) return;

		var relay = new Relay();
		var client = relay.client();

		var got:Bool = false;
		var failure:String = null;
		client.allocated.then(_ -> got = true, error -> failure = error);

		client.allocate(0);
		client.close();

		Assert.isFalse(got, "a closed client reported an allocation");
		Assert.notNull(failure, "closing before the relay answered left `allocated` pending forever");
	}

	/**
		Anything that is not TURN belongs to whoever else shares the socket.

		A relay client and an ICE agent commonly sit on one socket, and binding
		responses are not this client's to take.
	**/
	public function testTrafficThatIsNotTurnIsLeftAlone():Void {
		if (unsupported()) return;

		var relay = new Relay();
		var client = relay.client();

		var binding = new StunMessage(StunMessage.BINDING_SUCCESS, StunMessage.bindingRequest().transactionId, []);
		Assert.isFalse(client.receive(binding.encode(), RELAY, RELAY_PORT, 0), "a binding response was taken by the relay client");

		var noise = new ByteArray();
		noise.writeUTFBytes("not stun at all");
		noise.position = 0;
		Assert.isFalse(client.receive(noise, RELAY, RELAY_PORT, 0));
	}

	public function testARelayNeedsCredentials():Void {
		Assert.raises(() -> new TurnClient(RELAY, RELAY_PORT, null, "secret"), crossbyte.errors.ArgumentError);
		Assert.raises(() -> new TurnClient(RELAY, RELAY_PORT, "user", null), crossbyte.errors.ArgumentError);
		Assert.raises(() -> new TurnClient("", RELAY_PORT, "user", "secret"), crossbyte.errors.ArgumentError);
	}

	// ------------------------------------------------------------------
	// Transactions: each request its own, and every answer matched to one
	// ------------------------------------------------------------------

	/**
		A relay whose first answer takes longer than the first retransmission
		still grants an allocation, and only one.

		The signed retry after the 401 reused the unsigned request's
		transaction. The unsigned Allocate had been sent twice by then -- the
		answer was late -- so its second 401 arrived after the signed retry had
		gone and matched it, which read as the relay rejecting the credentials.
		Meanwhile the relay had granted the signed request, so it held an
		allocation nobody would use or free: on a satellite link, a mobile
		network or a first lookup, every allocation failed and leaked one.
	**/
	public function testAFirstAnswerSlowerThanTheRetransmissionStillAllocates():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		network.relay.delay = 0.6;

		var client = network.client();
		var failure:String = null;
		client.allocated.then(_ -> {}, error -> failure = error);
		client.allocate(network.now);
		network.run(() -> client.active || failure != null, 10);

		Assert.isNull(failure, "a slow first answer failed the allocation: " + failure);
		Assert.isTrue(client.active, "the allocation never completed");
		Assert.equals(1, network.relay.allocations, "the relay should hold exactly the one allocation the client is using");
		Assert.isTrue(network.relay.count("refused-401") >= 2, "the unsigned request was not answered twice, so this proved nothing");
	}

	/**
		Datagrams held while the relay's name is looked up, then sent together,
		do not fail the allocation either.

		Natively a socket holds datagrams to a name until the lookup answers and
		then sends them all at once, so a slow resolver on a fast path looks,
		to the relay, like two copies of the unsigned Allocate -- and to the old
		client, like the slow path above.
	**/
	public function testAllocatesWhenTheFirstRequestsAreHeldAndSentTogether():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		network.holdUntil = 0.7;

		var client = network.client();
		var failure:String = null;
		client.allocated.then(_ -> {}, error -> failure = error);
		client.allocate(network.now);
		network.run(() -> client.active || failure != null, 10);

		Assert.isNull(failure, "two copies of the first request failed the allocation: " + failure);
		Assert.isTrue(client.active, "the allocation never completed");
		Assert.equals(1, network.relay.allocations);
	}

	/**
		A CreatePermission success nobody asked for does not end an Allocate.

		It cleared whatever request was in flight, whatever that was. If that
		was the Allocate, nothing was left to retransmit or to time out, and
		`allocated` never settled either way -- from one datagram, from anyone.
	**/
	public function testAStrangersPermissionSuccessDoesNotStopTheAllocation():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		network.relay.delay = 0.2;

		var client = network.client();
		var settled:Bool = false;
		client.allocated.then(_ -> settled = true, _ -> settled = true);
		client.allocate(network.now);

		var stray = new StunMessage(StunMessage.CREATE_PERMISSION_SUCCESS, transaction(1), []);
		network.inject(client, stray.encode(), network.relayAddress, network.relayPort);

		network.run(() -> settled, 60);

		Assert.isTrue(settled, "a stray success left the allocation pending with nothing retransmitting it");
		Assert.isTrue(client.active, "the allocation did not complete after a stray success");
	}

	/**
		A ChannelBind error nobody asked for does not cancel a bind in flight.

		It did, and the real success then found nothing pending and was
		dropped: the relay had bound the channel and would forward the peer's
		traffic over it, while the client never marked it bound -- so for the
		ten minutes the binding lasted it dropped every ChannelData message
		from that peer.
	**/
	public function testAStrangersChannelBindErrorDoesNotCancelTheBind():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		var client = network.client();
		client.useChannels = true;
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(network.now);
		network.run(() -> client.active, 5);

		network.relay.delay = 0.3;
		client.permit(PEER, network.now);
		network.run(() -> network.relay.count("permitted") > 0, 5);
		network.advance(0.5);

		client.bindChannel(PEER, PEER_PORT, network.now);
		var stray = new StunMessage(StunMessage.CHANNEL_BIND_ERROR, transaction(2), [StunMessage.errorCode(400, "Bad Request")]);
		network.inject(client, stray.encode(), network.relayAddress, network.relayPort);

		network.advance(2);

		Assert.equals(1, network.relay.count("channel-bound"), "the relay never bound the channel, so this proved nothing");
		Assert.isTrue(sendsOverAChannel(network, client), "the relay bound the channel and the client never used it");
	}

	/**
		A second copy of an old success does not clear the request after it.

		The auditor's case: a permission, then a channel, on a path that
		duplicates. The duplicate success for the permission arrived while the
		bind was in flight and cleared the bind, which the relay then granted
		unheard.
	**/
	public function testADuplicateSuccessDoesNotClearTheNextRequest():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		var client = network.client();
		client.useChannels = true;
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(network.now);
		network.run(() -> client.active, 5);

		network.relay.delay = 0.5;
		network.relay.duplicatePermissionSuccess = 0.1;
		client.permit(PEER, network.now);
		client.bindChannel(PEER, PEER_PORT, network.now);

		network.advance(4);

		// At least once: an answer half a second late is retransmitted for.
		Assert.isTrue(network.relay.count("permitted") >= 1, "the relay never permitted the peer, so this proved nothing");
		Assert.isTrue(network.relay.count("channel-bound") >= 1, "the relay never bound the channel, so this proved nothing");
		Assert.isTrue(sendsOverAChannel(network, client), "a duplicated permission success cancelled the channel bind behind it");
	}

	/**
		A relay that never answers is given up on after 39.5 seconds.

		RFC 8489 section 6.2.1: seven transmissions, doubling from half a
		second, then sixteen times the first timeout for the last one to be
		answered. This waited another doubling instead and gave up at 63.5.
	**/
	public function testASilentRelayIsGivenUpOnAtThirtyNineAndAHalfSeconds():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		network.relay.dropAll = true;

		var client = network.client();
		var failedAt:Float = -1;
		client.allocated.then(_ -> {}, _ -> failedAt = network.now);
		client.allocate(network.now);
		network.run(() -> failedAt >= 0, 120);

		Assert.equals(TurnClient.MAX_ATTEMPTS, network.sent.length, "the request was not sent seven times");
		Assert.isTrue(failedAt >= 39.4 && failedAt <= 39.6, "gave up at " + failedAt + " s rather than at 39.5");
	}

	// ------------------------------------------------------------------
	// Permissions
	// ------------------------------------------------------------------

	/**
		A relay refusing one peer refuses that peer, and nothing else.

		Any CreatePermission error but 401 and 438 closed the client, so one
		address the relay would not forward to took every other peer down with
		it. That is the ordinary case, not an edge: a hardened relay refuses
		private and loopback addresses, and ICE asks for the peer's host
		addresses first.
	**/
	public function testARefusedPermissionRefusesOnlyThatPeer():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		network.relay.denyPeers = [PRIVATE_PEER];

		var client = network.client();
		var lost:Array<String> = [];
		var refused:Array<String> = [];
		client.onLost = reason -> lost.push(reason);
		client.onPermissionRefused = (peer, code, reason) -> refused.push(peer + " " + code + " " + reason);
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(network.now);
		network.run(() -> client.active, 5);

		client.permit(PRIVATE_PEER, network.now);
		network.run(() -> network.relay.count("permission-403") > 0, 5);
		network.advance(0.1);

		Assert.equals(1, network.relay.count("permission-403"), "the relay never refused the peer, so this proved nothing");
		Assert.isTrue(client.active, "one refused permission ended the whole allocation");
		Assert.equals(0, lost.length, "one refused peer was reported as the allocation lost: " + lost);
		Assert.equals(1, refused.length, "the refusal was not reported for the peer it was about");

		if (refused.length > 0) {
			Assert.equals(PRIVATE_PEER + " 403 Forbidden IP", refused[0]);
		}

		// Every other peer still gets through.
		client.permit(PEER, network.now);
		network.run(() -> network.relay.count("permitted") > 0, 5);

		var payload = new ByteArray();
		payload.writeUTFBytes("still relaying");
		payload.position = 0;
		client.sendTo(payload, PEER, PEER_PORT);
		network.advance(0.1);

		Assert.equals(1, network.toPeers.length, "the relay forwarded nothing for a peer it had permitted");

		// And the refused one is asked about once, however often it is
		// permitted and however long the allocation lasts.
		client.permit(PRIVATE_PEER, network.now);
		network.advance(TurnClient.PERMISSION_REFRESH + 10, 0.25);

		Assert.equals(1, network.relay.count("permission-403"), "a peer the relay refused was asked about again");
		Assert.isTrue(client.active);
	}

	// ------------------------------------------------------------------
	// Names, nonces and queues
	// ------------------------------------------------------------------

	/**
		A relay named by hostname is sent to by name once, and after that at
		the address that answered.

		Every datagram went to the name, which natively is looked up again
		every minute and on Node for every datagram. Against a round-robin pool
		each lookup can name another relay -- one that knows neither this
		allocation nor its nonce -- so the requests bounced between relays that
		refused each other's nonces and nothing was ever allocated.
	**/
	public function testARelayNamedByHostnameIsAskedWhereItAnswered():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		network.names.set(RELAY_NAME, network.relayAddress);

		var client = network.client(RELAY_NAME);
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(network.now);
		network.run(() -> client.active, 5);

		client.permit(PEER, network.now);
		network.run(() -> network.relay.count("permitted") > 0, 5);

		Assert.isTrue(client.active, "the allocation never completed");
		Assert.equals(RELAY_NAME, network.sent[0].address, "the first request did not go to the name it was given");

		var byName:Int = 0;

		for (i in 1...network.sent.length) {
			if (network.sent[i].address == RELAY_NAME) {
				byName++;
			}
		}

		Assert.equals(0, byName, byName + " requests after the relay answered were sent to its name, to be looked up again");
		Assert.equals(network.relayAddress, client.serverAddress);
	}

	/**
		A relay that calls every nonce stale is given up on, not asked forever.

		A 438 is answered by asking again with the new nonce, as it should be
		-- but without a limit, so a relay that refused every nonce it handed
		out was asked some nine thousand times a second, for good.
	**/
	public function testARelayThatCallsEveryNonceStaleIsGivenUpOn():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		network.relay.always438 = true;

		var client = network.client();
		var failure:String = null;
		client.allocated.then(_ -> {}, error -> failure = error);
		client.allocate(network.now);
		network.run(() -> failure != null, 10);

		var asked:Int = network.relay.requestsOf("allocate");
		Assert.notNull(failure, "a relay refusing every nonce was asked " + asked + " times and never given up on");
		Assert.isTrue(asked <= TurnClient.MAX_STALE_NONCES + 2, "a relay refusing every nonce was asked " + asked + " times");
	}

	/**
		Asking for a permission before every datagram does not starve the
		refresh.

		The auditor's measurement, in memory: thirty datagrams a second, each
		permitted first, on a path whose round trip the relay answers slower
		than that. Every call queued another CreatePermission, the refresh was
		sent only when nothing else was in flight -- which was never -- and the
		allocation expired at ten minutes with ten thousand requests queued.
	**/
	public function testPermittingBeforeEveryDatagramDoesNotStarveTheRefresh():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		network.latency = 0.035;

		var client = network.client();
		var lost:Array<String> = [];
		client.onLost = reason -> lost.push(reason);
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(network.now);
		network.run(() -> client.active, 5);

		var payload = new ByteArray();

		for (i in 0...64) {
			payload.writeByte(i);
		}

		network.onTick = function():Void {
			client.permit(PEER, network.now);
			client.sendTo(payload, PEER, PEER_PORT);
		};

		network.run(() -> !client.active, 1800, 1 / 30);
		network.onTick = function():Void {};

		Assert.isTrue(client.active, "the allocation was lost: " + lost);
		Assert.equals(0, lost.length);

		var permissions:Int = network.relay.requestsOf("permission");
		Assert.isTrue(permissions <= Std.int(1800 / TurnClient.PERMISSION_REFRESH) + 2,
			"one peer's permission was asked for " + permissions + " times in half an hour");
		Assert.isTrue(network.relay.requestsOf("refresh") >= 5, "the allocation was refreshed only " + network.relay.requestsOf("refresh") + " times");
	}

	/**
		A refresh goes when it is due, however many requests are waiting.
	**/
	public function testARefreshDoesNotWaitBehindPermissions():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		var client = network.client();
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(network.now);
		network.run(() -> client.active, 5);

		var due:Float = network.now + TurnClient.DEFAULT_LIFETIME / 2;

		// A slow relay, and a new peer every second: there is always a
		// permission in flight and more waiting.
		network.relay.delay = 3;
		var next:Float = network.now;
		var peers:Int = 0;

		network.onTick = function():Void {
			if (network.now >= next) {
				next += 1;
				peers++;
				client.permit("198.51." + (100 + (peers >> 8)) + "." + (peers & 0xFF), network.now);
			}
		};

		network.run(() -> network.sentOfType(StunMessage.REFRESH_REQUEST).length > 0, 400, 0.25);
		network.onTick = function():Void {};

		var refreshes = network.sentOfType(StunMessage.REFRESH_REQUEST);
		Assert.isTrue(refreshes.length > 0, "the refresh was never sent while permissions were waiting");

		if (refreshes.length > 0) {
			Assert.isTrue(refreshes[0].at - due < 1.0, "the refresh went " + (refreshes[0].at - due) + " s after it was due");
		}
	}

	/**
		Requests waiting behind those in flight are bounded.

		A caller asking for more than the relay answers grew the queue without
		limit -- by thousands a minute in the auditor's measurement.
	**/
	public function testTheRequestsWaitingAreBounded():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		var client = network.client();
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(network.now);
		network.run(() -> client.active, 5);

		// Nothing answers from here, so nothing leaves the queue.
		network.relay.dropAll = true;

		for (i in 0...500) {
			client.permit("198.51." + (100 + (i >> 8)) + "." + (i & 0xFF), network.now);
		}

		var queued:Int = @:privateAccess client.__queued.length;
		Assert.isTrue(queued <= TurnClient.MAX_QUEUED, queued + " requests were queued");
	}

	/**
		A stale nonce on a channel rebind is retried, and the channel stays up.

		A 438 on a ChannelBind was neither retried nor used to take the new
		nonce, and the channel stayed marked bound -- while the relay, whose
		binding lapsed at ten minutes, dropped everything sent on it. With a
		600 second nonce, 58 of 300 simulated two-hour sessions lost their
		channel that way, the worst for six minutes, with nothing reported.
	**/
	public function testAStaleNonceOnAChannelRebindIsRetried():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		var client = network.client();
		client.useChannels = true;
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(network.now);
		network.run(() -> client.active, 5);

		client.permit(PEER, network.now);
		network.run(() -> network.relay.count("permitted") > 0, 5);
		network.advance(10);
		client.bindChannel(PEER, PEER_PORT, network.now);
		network.run(() -> network.relay.count("channel-bound") > 0, 5);

		// A nonce lasts 485 s: still good for the permission's renewals at 240
		// and 480 and the refresh at 300, and stale by the channel's rebind at
		// 490 -- the first request to meet it.
		network.relay.staleNonceAfter = 485;
		network.advance(700 - network.now, 0.25);

		Assert.isTrue(network.relay.count("refused-438") > 0, "no nonce went stale, so this proved nothing");
		Assert.isTrue(network.relay.count("channel-bound") >= 2, "the rebind refused for its nonce was never retried");

		var before:Int = network.toPeers.length;
		var payload = new ByteArray();
		payload.writeUTFBytes("input frame");
		payload.position = 0;
		client.sendTo(payload, PEER, PEER_PORT);
		network.advance(0.1);

		Assert.equals(0, network.relay.count("channeldata-dropped"), "the client went on sending on a channel the relay had let lapse");
		Assert.equals(before + 1, network.toPeers.length, "the datagram never reached the peer");
	}

	/**
		A rebind the relay refuses leaves the channel only until its binding
		lapses, and the traffic goes back to indications then.
	**/
	public function testARebindTheRelayRefusesFallsBackToIndications():Void {
		if (unsupported()) return;

		var network = new TurnNetwork();
		var client = network.client();
		client.useChannels = true;
		client.allocated.then(_ -> {}, _ -> {});
		client.allocate(network.now);
		network.run(() -> client.active, 5);

		client.permit(PEER, network.now);
		client.bindChannel(PEER, PEER_PORT, network.now);
		network.run(() -> network.relay.count("channel-bound") > 0, 5);

		// Every bind from here is refused, the rebind at 480 included; the
		// binding the relay has lapses at 600.
		network.relay.refuseChannels = true;
		network.advance(700 - network.now, 0.25);

		Assert.equals(1, network.relay.count("bind-400"), "the rebind was never refused, so this proved nothing");

		var payload = new ByteArray();
		payload.writeUTFBytes("input frame");
		payload.position = 0;
		client.sendTo(payload, PEER, PEER_PORT);
		network.advance(0.1);

		Assert.equals(0, network.relay.count("channeldata-dropped"), "the client went on sending on a channel the relay had let lapse");
		Assert.isTrue(network.relay.count("send-relayed") > 0, "the traffic did not go back to indications");
	}

	// ------------------------------------------------------------------

	private static inline var RELAY_NAME:String = "relay.example.test";

	private static inline var PEER:String = "198.51.100.4";
	private static inline var PEER_PORT:Int = 40000;

	/** A private address, of the kind a hardened relay refuses to forward to. **/
	private static inline var PRIVATE_PEER:String = "10.0.0.5";

	/** A transaction id no request of the client's has. **/
	private static function transaction(seed:Int):ByteArray {
		var bytes = new ByteArray();

		for (i in 0...12) {
			bytes.writeByte((seed * 53 + i * 17 + 5) & 0xFF);
		}

		bytes.position = 0;
		return bytes;
	}

	/** Whether the client's next datagram to the peer goes over a channel rather than as a Send indication. **/
	private static function sendsOverAChannel(network:TurnNetwork, client:TurnClient):Bool {
		var payload = new ByteArray();
		payload.writeUTFBytes("game state");
		payload.position = 0;

		var before:Int = network.sent.length;
		client.sendTo(payload, PEER, PEER_PORT);

		if (network.sent.length == before) {
			return false;
		}

		var first:Int = network.sent[network.sent.length - 1].bytes[0];
		return first >= 0x40 && first <= 0x7F;
	}
}

/**
	A relay that exists only as a function from request bytes to reply bytes.

	It behaves the way RFC 8656 says one does -- refusing an unsigned request
	with a realm and nonce, granting an allocation to a signed one -- and can be
	told to misbehave in the specific ways a real relay will not do on request.
**/
private class Relay {
	public var allocateRequests:Int = 0;
	public var refreshRequests:Int = 0;
	public var permissionRequests:Int = 0;
	public var firstWasSigned:Bool = false;
	public var lastWasSigned:Bool = false;
	public var lastNonceSeen:String = null;
	public var lastIndication:StunMessage = null;

	public var staleOnce:Bool = false;
	public var alwaysUnauthorized:Bool = false;
	public var holdRefresh:Bool = false;

	/** Answer a refresh with a lifetime of zero, which ends the allocation. **/
	public var endOnRefresh:Bool = false;

	private var nonce:String = "nonce-one";
	private var staleSent:Bool = false;
	private var seenAnyRequest:Bool = false;
	private var held:StunMessage = null;
	private var outbound:Array<ByteArray> = [];

	public function new() {}

	public function client():TurnClient {
		var made = new TurnClient("203.0.113.10", 3478, "user", "secret");
		made.onSend = function(payload:ByteArray, _, _):Void {
			outbound.push(payload);
		};
		return made;
	}

	/** Pumps until `done`, answering everything the client sends. **/
	public function run(client:TurnClient, done:Void->Bool, from:Float = 0):Void {
		var now = from;

		for (_ in 0...50) {
			var inFlight = outbound;
			outbound = [];

			for (payload in inFlight) {
				var reply = answer(payload);

				if (reply != null) {
					client.receive(reply, "203.0.113.10", 3478, now);
				}
			}

			if (done()) {
				return;
			}

			client.poll(now);
			now += 0.6;
		}
	}

	/** Delivers whatever the client has sent so far, once, without advancing. **/
	public function pump(client:TurnClient, now:Float):Void {
		var inFlight = outbound;
		outbound = [];

		for (payload in inFlight) {
			var reply = answer(payload);

			if (reply != null) {
				client.receive(reply, "203.0.113.10", 3478, now);
			}
		}
	}

	/** Answers a request that was deliberately left hanging. **/
	public function answerHeld(client:TurnClient, now:Float):Void {
		if (held == null) {
			return;
		}

		var reply = new StunMessage(StunMessage.REFRESH_SUCCESS, held.transactionId, [StunMessage.lifetime(600)]);
		held = null;
		client.receive(reply.encode(), "203.0.113.10", 3478, now);
	}

	/** Hands the client a datagram as though a peer had sent it. **/
	public function deliver(client:TurnClient, peerAddress:String, peerPort:Int, text:String):Void {
		var payload = new ByteArray();
		payload.writeUTFBytes(text);
		payload.position = 0;

		var indication = new StunMessage(StunMessage.DATA_INDICATION, StunMessage.bindingRequest().transactionId, [
			StunMessage.xorPeerAddress(peerAddress, peerPort),
			StunMessage.data(payload)
		]);

		client.receive(indication.encode(), "203.0.113.10", 3478, 0);
	}

	private function answer(payload:ByteArray):Null<ByteArray> {
		var request = StunMessage.decode(payload);

		if (request == null) {
			return null;
		}

		if (request.type == StunMessage.SEND_INDICATION) {
			lastIndication = request;
			return null;
		}

		var signed = request.attribute(StunMessage.ATTR_MESSAGE_INTEGRITY) != null;

		if (!seenAnyRequest) {
			firstWasSigned = signed;
			seenAnyRequest = true;
		}

		lastWasSigned = signed;

		if (signed) {
			lastNonceSeen = request.textOf(StunMessage.ATTR_NONCE);
		}

		switch (request.type) {
			case StunMessage.ALLOCATE_REQUEST:
				allocateRequests++;
			case StunMessage.REFRESH_REQUEST:
				refreshRequests++;
			case StunMessage.CREATE_PERMISSION_REQUEST:
				permissionRequests++;
			default:
		}

		if (alwaysUnauthorized || !signed) {
			return refuse(request, StunMessage.UNAUTHORIZED, nonce);
		}

		if (staleOnce && !staleSent) {
			staleSent = true;
			nonce = "nonce-two";
			return refuse(request, StunMessage.STALE_NONCE, nonce);
		}

		return switch (request.type) {
			case StunMessage.ALLOCATE_REQUEST:
				sign(new StunMessage(StunMessage.ALLOCATE_SUCCESS, request.transactionId, [
					StunMessage.xorRelayed("203.0.113.10", 49152),
					StunMessage.xorMappedAddress("198.51.100.77", 51000),
					StunMessage.lifetime(600)
				]));
			case StunMessage.REFRESH_REQUEST:
				if (holdRefresh) {
					held = request;
					null;
				} else {
					sign(new StunMessage(StunMessage.REFRESH_SUCCESS, request.transactionId, [StunMessage.lifetime(endOnRefresh ? 0 : 600)]));
				}
			case StunMessage.CREATE_PERMISSION_REQUEST:
				sign(new StunMessage(StunMessage.CREATE_PERMISSION_SUCCESS, request.transactionId, []));
			default:
				null;
		}
	}

	private function refuse(request:StunMessage, code:Int, withNonce:String):ByteArray {
		return new StunMessage(request.type | 0x0110, request.transactionId, [
			StunMessage.errorCode(code, code == StunMessage.UNAUTHORIZED ? "Unauthorized" : "Stale Nonce"),
			StunMessage.text(StunMessage.ATTR_REALM, "example.org"),
			StunMessage.text(StunMessage.ATTR_NONCE, withNonce)
		]).encode();
	}

	private function sign(message:StunMessage):ByteArray {
		return message.encodeSignedWithKey(StunMessage.longTermKey("user", "example.org", "secret"), false);
	}
}
