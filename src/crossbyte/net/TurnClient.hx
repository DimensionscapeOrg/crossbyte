package crossbyte.net;

import crossbyte.Future;
import crossbyte.crypto.SecureRandom;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunMessage.StunAttribute;
import haxe.io.Bytes;

/**
	An address on a relay, for when no direct path exists.

	ICE tries every direct route first and usually finds one. When it does not
	-- symmetric NAT at both ends, a corporate firewall that permits only
	outbound TCP, a mobile carrier's CGNAT -- there is no packet either peer can
	send that the other will receive, and no amount of hole punching invents
	one. TURN is the answer to that: a server both peers *can* reach agrees to
	forward between them.

	It is last for a reason. Every byte crosses a third party twice, the latency
	is whatever the detour costs, and somebody pays for the bandwidth. A relayed
	candidate is worth having precisely because the alternative is no connection
	at all.

	```haxe
	var relay = new TurnClient("turn.example.com", 3478, "user", "secret");
	relay.onSend = (payload, address, port) -> server.sendTo(payload, address, port);

	relay.allocated.then(function(relayed) {
		agent.addLocalCandidate(new IceCandidate(RELAYED, relayed.address, relayed.port));
	});

	relay.allocate(haxe.Timer.stamp());
	```

	## No socket, for the same reason as the agent

	`onSend` out, `receive` in, `poll` for time. A relayed candidate has to be
	allocated through the socket the peer will actually use, or the permissions
	the relay grants describe traffic from somewhere else -- and it means the
	whole exchange can be tested against a server standing in memory.

	## What this does not do

	Channel binding, RFC 8656 section 12. Once a peer is settled, a four-byte
	channel header can replace the thirty-six a Send indication costs. It is
	worth having on a busy relay and it changes nothing about whether a
	connection works, so it is left out rather than half-built.
**/
class TurnClient {
	/** How long an allocation is asked to last, in seconds. **/
	public static inline var DEFAULT_LIFETIME:Int = 600;

	/**
		How long to wait before retransmitting an unanswered request.

		TURN runs over UDP like everything else here, so the same rule holds: a
		request that reached nothing looks exactly like one still in flight.
	**/
	public static inline var RETRY_AFTER:Float = 0.5;

	/** Attempts before the allocation is given up on. **/
	public static inline var MAX_ATTEMPTS:Int = 7;

	private static inline var TRANSACTION_LENGTH:Int = 12;

	/**
		Whether a relay can be used from here.

		Every request carries a transaction id that must be unguessable, so this
		is `SecureRandom` reported under another name.
	**/
	public static var isSupported(default, null):Bool = SecureRandom.isSupported;

	public var serverAddress(default, null):String;
	public var serverPort(default, null):Int;

	/** The address peers should be told to send to, once there is one. **/
	public var relayedAddress(default, null):Null<ReflexiveAddress>;

	/** Where the relay sees this client, which is an ordinary reflexive address. **/
	public var mappedAddress(default, null):Null<ReflexiveAddress>;

	/**
		Resolves with the relayed address, or fails if the relay refuses.

		One shot. An allocation that expires is a new client rather than a
		second result on this one.
	**/
	public var allocated(default, null):Future<ReflexiveAddress>;

	/** Whether an allocation is currently held. **/
	public var active(default, null):Bool = false;

	/** Datagrams a peer sent through the relay. **/
	public dynamic function onData(payload:ByteArray, fromAddress:String, fromPort:Int):Void {}

	/** Called with a datagram bound for the relay. **/
	public dynamic function onSend(payload:ByteArray, address:String, port:Int):Void {}

	@:noCompletion private var __username:String;
	@:noCompletion private var __password:String;
	@:noCompletion private var __realm:String;
	@:noCompletion private var __nonce:String;
	@:noCompletion private var __key:Bytes;
	@:noCompletion private var __pending:StunMessage;
	@:noCompletion private var __pendingType:Int = 0;
	@:noCompletion private var __attempts:Int = 0;
	@:noCompletion private var __retryAt:Float = 0;
	@:noCompletion private var __refreshAt:Float = 0;
	@:noCompletion private var __lifetime:Int = DEFAULT_LIFETIME;
	@:noCompletion private var __closed:Bool = false;
	@:noCompletion private var __permitted:Array<String> = [];

	/**
		Requests waiting for the one in flight to finish.

		A relay correlates by transaction id and only one request is tracked at
		a time, so starting a second while the first is outstanding would
		abandon it -- and the one most likely to be abandoned is the refresh,
		since permissions are asked for at arbitrary moments and refreshes come
		round on a timer. Losing a refresh does not fail loudly: the allocation
		simply stops being renewed and the connection dies when it expires.
	**/
	@:noCompletion private var __queued:Array<{type:Int, attributes:Array<StunAttribute>}> = [];

	/**
		@param username Long-term credentials, which a relay always requires --
		it is forwarding somebody's traffic and needs to know whose.
	**/
	public function new(serverAddress:String, serverPort:Int = 3478, username:String, password:String) {
		if (serverAddress == null || serverAddress.length == 0) {
			throw new ArgumentError("A relay address is required.");
		}

		if (username == null || password == null) {
			throw new ArgumentError("A relay needs credentials: it forwards traffic on somebody's behalf and has to know whose.");
		}

		this.serverAddress = serverAddress;
		this.serverPort = serverPort;
		this.__username = username;
		this.__password = password;
		this.allocated = new Future<ReflexiveAddress>();
	}

	/**
		Asks the relay for an address.

		The first request goes out unauthenticated on purpose. A relay does not
		publish its realm, and the nonce it wants a request signed against is
		chosen per client -- so the refusal that comes back is not a failure, it
		is how the exchange starts. RFC 8656 section 9.2.
	**/
	public function allocate(now:Float):Void {
		if (__closed || active || __pending != null) {
			return;
		}

		__request(StunMessage.ALLOCATE_REQUEST, [
			StunMessage.requestedTransport(),
			StunMessage.lifetime(DEFAULT_LIFETIME)
		], now);
	}

	/**
		Lets a peer's traffic through.

		A relay drops anything from an address it has not been told to expect,
		which is what stops an allocation being an open forwarder for whoever
		finds it. Permissions expire after five minutes and are renewed with the
		allocation.
	**/
	public function permit(peerAddress:String, now:Float):Void {
		if (__closed || !active || peerAddress == null) {
			return;
		}

		if (__permitted.indexOf(peerAddress) < 0) {
			__permitted.push(peerAddress);
		}

		__request(StunMessage.CREATE_PERMISSION_REQUEST, [StunMessage.xorPeerAddress(peerAddress, 0)], now);
	}

	/**
		Sends a datagram to a peer through the relay.

		Wrapped in a Send indication, which is not acknowledged and not
		retransmitted -- the relay forwards it or it does not, exactly as a
		datagram sent directly would arrive or not.
	**/
	public function sendTo(payload:ByteArray, peerAddress:String, peerPort:Int):Void {
		if (__closed || !active) {
			return;
		}

		var indication = new StunMessage(StunMessage.SEND_INDICATION, __transaction(), [
			StunMessage.xorPeerAddress(peerAddress, peerPort),
			StunMessage.data(payload)
		]);

		// Indications carry no integrity: there is no response to correlate and
		// RFC 8656 does not authenticate them, the permission list being what
		// decides whose traffic the relay will carry.
		onSend(indication.encode(), serverAddress, serverPort);
	}

	/**
		Moves time forward: retransmits, refreshes, and gives up.
	**/
	public function poll(now:Float):Void {
		if (__closed) {
			return;
		}

		if (__pending != null && now >= __retryAt) {
			if (__attempts >= MAX_ATTEMPTS) {
				__fail("The relay at " + serverAddress + ":" + serverPort + " did not answer.");
				return;
			}

			__transmit(now);
		}

		// Refreshed at half the lifetime, so a lost refresh has one more chance
		// before the allocation the whole connection rests on disappears.
		if (active && __pending == null && now >= __refreshAt) {
			__request(StunMessage.REFRESH_REQUEST, [StunMessage.lifetime(__lifetime)], now);
		}

		__drain(now);
	}

	/** Starts whatever was waiting on the request that just finished. **/
	@:noCompletion private function __drain(now:Float):Void {
		if (__pending != null || __queued.length == 0 || __closed) {
			return;
		}

		var next = __queued.shift();
		__request(next.type, next.attributes, now);
	}

	/**
		Offers an arriving datagram to the relay client.

		@return Whether it was TURN traffic. Anything else belongs to whatever
		shares the socket -- an ICE check, or a session already running.
	**/
	public function receive(payload:ByteArray, fromAddress:String, fromPort:Int, now:Float):Bool {
		if (__closed || payload == null) {
			return false;
		}

		var message = StunMessage.decode(payload);

		if (message == null) {
			return false;
		}

		switch (message.type) {
			case StunMessage.DATA_INDICATION:
				__deliver(message);
			case StunMessage.ALLOCATE_SUCCESS:
				__allocated(message, now);
			case StunMessage.REFRESH_SUCCESS:
				__refreshed(message, now);
			case StunMessage.CREATE_PERMISSION_SUCCESS:
				__pending = null;
				__drain(now);
			case StunMessage.ALLOCATE_ERROR, StunMessage.REFRESH_ERROR, StunMessage.CREATE_PERMISSION_ERROR:
				__refused(message, now);
			default:
				// A binding response, most likely: this client and an ICE agent
				// commonly share a socket. Not ours.
				return false;
		}

		return true;
	}

	public function close():Void {
		__closed = true;
		active = false;
		__pending = null;
	}

	// ------------------------------------------------------------------

	@:noCompletion private function __request(type:Int, attributes:Array<StunAttribute>, now:Float):Void {
		if (__pending != null) {
			__queued.push({type: type, attributes: attributes});
			return;
		}

		__pendingType = type;
		__pending = new StunMessage(type, __transaction(), attributes);
		__attempts = 0;
		__transmit(now);
	}

	@:noCompletion private function __transmit(now:Float):Void {
		if (__pending == null) {
			return;
		}

		__attempts++;
		__retryAt = now + RETRY_AFTER * Math.pow(2, __attempts - 1);

		// Signed only once the relay has said which realm and nonce to sign
		// against. Before that there is nothing to key with, which is the whole
		// point of the first exchange.
		if (__key != null && __realm != null && __nonce != null) {
			var signed = new StunMessage(__pending.type, __pending.transactionId, __pending.attributes.concat([
				StunMessage.text(StunMessage.ATTR_USERNAME, __username),
				StunMessage.text(StunMessage.ATTR_REALM, __realm),
				StunMessage.text(StunMessage.ATTR_NONCE, __nonce)
			]));

			onSend(signed.encodeSignedWithKey(__key, false), serverAddress, serverPort);
			return;
		}

		onSend(__pending.encode(), serverAddress, serverPort);
	}

	@:noCompletion private function __refused(message:StunMessage, now:Float):Void {
		if (__pending == null || !__pending.matches(message)) {
			return;
		}

		var code = message.errorCodeValue();

		// 401 the first time, 438 when the nonce a request was signed against
		// has expired. Both mean the same thing: take the credentials offered
		// and ask again. Only once for 401, so a relay that keeps refusing
		// cannot hold this in a loop.
		if (code == StunMessage.UNAUTHORIZED || code == StunMessage.STALE_NONCE) {
			var realm = message.textOf(StunMessage.ATTR_REALM);
			var nonce = message.textOf(StunMessage.ATTR_NONCE);

			if (realm == null || nonce == null) {
				__fail("The relay refused the request without saying what credentials it wants.");
				return;
			}

			if (code == StunMessage.UNAUTHORIZED && __key != null) {
				__fail("The relay rejected these credentials.");
				return;
			}

			__realm = realm;
			__nonce = nonce;
			__key = StunMessage.longTermKey(__username, realm, __password);
			__attempts = 0;
			__transmit(now);
			return;
		}

		__fail("The relay refused the request: " + (message.errorMessage() != null ? message.errorMessage() : Std.string(code)));
	}

	@:noCompletion private function __allocated(message:StunMessage, now:Float):Void {
		if (__pending == null || __pendingType != StunMessage.ALLOCATE_REQUEST || !__pending.matches(message)) {
			return;
		}

		var relayed = message.addressOf(StunMessage.ATTR_XOR_RELAYED_ADDRESS);

		if (relayed == null) {
			__fail("The relay allocated nothing: its reply carried no relayed address.");
			return;
		}

		__pending = null;
		relayedAddress = relayed;
		mappedAddress = message.addressOf(StunMessage.ATTR_XOR_MAPPED_ADDRESS);
		__lifetime = message.uintOf(StunMessage.ATTR_LIFETIME, DEFAULT_LIFETIME);
		__refreshAt = now + __lifetime / 2;
		active = true;

		@:privateAccess allocated.__resolve(relayed);
		__drain(now);
	}

	@:noCompletion private function __refreshed(message:StunMessage, now:Float):Void {
		if (__pending == null || !__pending.matches(message)) {
			return;
		}

		__pending = null;
		__lifetime = message.uintOf(StunMessage.ATTR_LIFETIME, __lifetime);

		if (__lifetime <= 0) {
			// A zero lifetime is how a relay says the allocation is gone.
			active = false;
			return;
		}

		__refreshAt = now + __lifetime / 2;
		__drain(now);
	}

	@:noCompletion private function __deliver(message:StunMessage):Void {
		var peer = message.addressOf(StunMessage.ATTR_XOR_PEER_ADDRESS);
		var payload = message.attribute(StunMessage.ATTR_DATA);

		if (peer == null || payload == null) {
			return;
		}

		payload.position = 0;
		onData(payload, peer.address, peer.port);
	}

	@:noCompletion private function __fail(reason:String):Void {
		__pending = null;
		active = false;

		if (!__closed) {
			@:privateAccess allocated.__fail(reason, null);
		}

		__closed = true;
	}

	@:noCompletion private static function __transaction():ByteArray {
		return SecureRandom.getSecureRandomBytes(TRANSACTION_LENGTH);
	}
}
