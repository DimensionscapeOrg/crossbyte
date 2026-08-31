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

	## Channels, and why they are off unless asked for

	A Send indication costs thirty-six bytes of STUN wrapper on every datagram.
	RFC 8656 section 12 replaces that with a channel: bind a number to a peer
	once, and everything afterwards carries a four-byte header instead. On a
	relay forwarding a stream of kilobyte chunks that is most of three percent
	of the traffic, paid on every packet, in both directions.

	`useChannels` turns it on, and it is off by default because getting it
	wrong is not a slower connection but a dead one. A `ChannelData` message is
	not STUN -- its first two bits are not zero, which is exactly how it is told
	apart -- so a relay that binds a channel and then drops what it is sent over
	it has no way to say so. UDP reports nothing, the datagrams stop, and there
	is nothing to fall back from.

	That is not hypothetical. node-turn, which this repository tests against,
	answers a ChannelBind with success and forwards over the channel in the
	peer-to-client direction, while its receive path rejects every datagram
	whose top two bits are set -- so a client that believes the success and
	starts sending `ChannelData` is talking to nothing. Widely deployed relays
	are not like this and browsers bind channels by default; the point is only
	that a saving of thirty-two bytes is not worth a connection that dies
	silently against a relay nobody checked first.

	Once on, it happens on its own. The first datagram for a peer goes as an
	indication and asks for a channel at the same time; once the relay agrees,
	the rest go as `ChannelData`. A relay that refuses the bind outright is the
	safe case -- the indications simply keep working.

	Channels last ten minutes and are rebound well inside that. A binding that
	lapses does not fail loudly either, so it is rebound at eight.
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
		The range RFC 8656 reserves for channels.

		Chosen so a `ChannelData` message cannot be mistaken for anything else
		sharing the socket: its first byte lands between 0x40 and 0x7F, where
		RFC 7983 has neither STUN below 4 nor DTLS from 20 to 63.
	**/
	public static inline var FIRST_CHANNEL:Int = 0x4000;

	public static inline var LAST_CHANNEL:Int = 0x7FFE;

	/** Channel number, then length: what a bound peer costs per datagram. **/
	public static inline var CHANNEL_HEADER:Int = 4;

	/** RFC 8656 gives a binding ten minutes. **/
	public static inline var CHANNEL_LIFETIME:Float = 600;

	/** Rebound at eight, so a lost bind has another go before it lapses. **/
	private static inline var CHANNEL_REFRESH:Float = 480;

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

	/** Peers with a channel bound, or one asked for. **/
	/**
		Whether to ask for a channel per peer, trading thirty-two bytes a
		datagram for a relay that has to implement RFC 8656 section 12 in both
		directions. Off unless set; see the class documentation for what a
		half-implementation does.
	**/
	public var useChannels:Bool = false;

	@:noCompletion private var __channels:Array<TurnChannel> = [];

	@:noCompletion private var __nextChannel:Int = FIRST_CHANNEL;

	/** The last time anything told this client, so `sendTo` can have one. **/
	@:noCompletion private var __clock:Float = 0;

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

		var channel = __channelFor(peerAddress, peerPort);

		if (channel != null && channel.bound) {
			onSend(__channelData(channel.number, payload), serverAddress, serverPort);
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
		Asks for a channel to a peer, so later datagrams cost four bytes.

		Idempotent, and safe to call before the relay has answered anything: a
		peer already bound and fresh is left alone, and everything keeps going
		as indications until a bind succeeds.

		A channel bind installs a permission as well, which is why RFC 8656
		describes it as doing both -- but the permission is still asked for
		separately, since it has to be in place for the indications that carry
		the traffic in the meantime.
	**/
	public function bindChannel(peerAddress:String, peerPort:Int, now:Float):Void {
		if (__closed || !active || !useChannels || peerAddress == null) {
			return;
		}

		__clock = now;
		var channel = __channelFor(peerAddress, peerPort);

		if (channel != null && now - channel.askedAt < CHANNEL_REFRESH) {
			return;
		}

		if (channel == null) {
			if (__nextChannel > LAST_CHANNEL) {
				// Sixteen thousand peers on one allocation is not a case this
				// will meet, and silently reusing a number would send one
				// peer's traffic to another.
				return;
			}

			channel = new TurnChannel(__nextChannel++, peerAddress, peerPort);
			__channels.push(channel);
		}

		channel.askedAt = now;

		__request(StunMessage.CHANNEL_BIND_REQUEST, [
			StunMessage.channelNumber(channel.number),
			StunMessage.xorPeerAddress(peerAddress, peerPort)
		], now);
	}

	/** The channel bound to a peer, if one was ever asked for. **/
	@:noCompletion private function __channelFor(address:String, port:Int):Null<TurnChannel> {
		for (channel in __channels) {
			if (channel.address == address && channel.port == port) {
				return channel;
			}
		}

		return null;
	}

	/**
		`ChannelData`: two bytes of channel, two of length, then the payload.

		No padding. RFC 8656 section 12.4 requires it only over a stream
		transport, where a reader has to find the end of one message to find the
		start of the next; a datagram already has an end.
	**/
	@:noCompletion private function __channelData(number:Int, payload:ByteArray):ByteArray {
		var out = new ByteArray();
		out.writeByte((number >> 8) & 0xFF);
		out.writeByte(number & 0xFF);
		out.writeByte((payload.length >> 8) & 0xFF);
		out.writeByte(payload.length & 0xFF);

		payload.position = 0;
		out.writeBytes(payload, 0, payload.length);
		payload.position = 0;
		out.position = 0;
		return out;
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

		__clock = now;

		// Refreshed at half the lifetime, so a lost refresh has one more chance
		// before the allocation the whole connection rests on disappears.
		if (active && __pending == null && now >= __refreshAt) {
			__request(StunMessage.REFRESH_REQUEST, [StunMessage.lifetime(__lifetime)], now);
		}

		// And every channel well inside its ten minutes. One that lapses is not
		// reported: the relay simply stops recognising what it is sent.
		if (active) {
			for (channel in __channels) {
				if (channel.bound && now - channel.askedAt >= CHANNEL_REFRESH) {
					bindChannel(channel.address, channel.port, now);
				}
			}
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

		__clock = now;

		// Before decoding: a ChannelData message is not STUN, and its first two
		// bytes are a channel number that would read as a message type nothing
		// here has.
		if (__deliverChannelData(payload)) {
			return true;
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
			case StunMessage.CHANNEL_BIND_SUCCESS:
				__channelBound(message, now);
			case StunMessage.CHANNEL_BIND_ERROR:
				// The relay would not, so this peer keeps costing a wrapper.
				// Not a failure of the connection: indications still work, and
				// treating it as one would give up a working path over a
				// saving.
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

	/**
		Unwraps a `ChannelData` message, if that is what this is.

		@return Whether it was. A channel number is one this client handed out,
		so anything else -- including a datagram that merely starts in the same
		byte range -- is left for whoever else is on the socket.
	**/
	@:noCompletion private function __deliverChannelData(payload:ByteArray):Bool {
		if (payload.length < CHANNEL_HEADER) {
			return false;
		}

		payload.position = 0;
		var number = (payload.readUnsignedByte() << 8) | payload.readUnsignedByte();
		var length = (payload.readUnsignedByte() << 8) | payload.readUnsignedByte();

		if (number < FIRST_CHANNEL || number > LAST_CHANNEL || CHANNEL_HEADER + length > payload.length) {
			payload.position = 0;
			return false;
		}

		var channel = null;

		for (known in __channels) {
			if (known.number == number && known.bound) {
				channel = known;
				break;
			}
		}

		if (channel == null) {
			payload.position = 0;
			return false;
		}

		var data = new ByteArray();

		if (length > 0) {
			payload.readBytes(data, 0, length);
		}

		data.position = 0;
		payload.position = 0;
		onData(data, channel.address, channel.port);
		return true;
	}

	@:noCompletion private function __channelBound(message:StunMessage, now:Float):Void {
		if (__pending == null || __pendingType != StunMessage.CHANNEL_BIND_REQUEST || !__pending.matches(message)) {
			return;
		}

		var number = __pending.uintOf(StunMessage.ATTR_CHANNEL_NUMBER, 0) >> 16;

		for (channel in __channels) {
			if (channel.number == number) {
				channel.bound = true;
				channel.askedAt = now;
			}
		}

		__pending = null;
		__drain(now);
	}

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

/**
	One channel: a number the relay agreed stands for a peer.

	`askedAt` is when the bind was last requested rather than when it was
	granted, because that is what the retry and the refresh are both measured
	against -- and a bind that was never answered should not look fresh.
**/
private class TurnChannel {
	public var number(default, null):Int;
	public var address(default, null):String;
	public var port(default, null):Int;

	/** Whether the relay has agreed. Until then traffic goes as indications. **/
	public var bound:Bool = false;

	public var askedAt:Float = 0;

	public function new(number:Int, address:String, port:Int) {
		this.number = number;
		this.address = address;
		this.port = port;
	}
}
