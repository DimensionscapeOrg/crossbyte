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
		A permission asked for while a refresh is outstanding does not lose it.

		Only one request is tracked at a time, so a second started underneath
		the first would abandon it -- and the one abandoned is whichever was
		already running, which on a timer is the refresh. That does not fail
		loudly: the allocation just stops being renewed and the connection dies
		when it expires.
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
		Assert.equals(0, relay.permissionRequests, "the permission displaced the refresh in flight");

		relay.holdRefresh = false;
		relay.answerHeld(client, now);
		relay.run(client, () -> relay.permissionRequests > 0, now);

		Assert.equals(1, relay.refreshRequests, "the refresh was retried, which means its answer was not matched");
		Assert.equals(1, relay.permissionRequests, "the queued permission was never sent");
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
					sign(new StunMessage(StunMessage.REFRESH_SUCCESS, request.transactionId, [StunMessage.lifetime(600)]));
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
