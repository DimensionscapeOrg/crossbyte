package crossbyte.net;

import crossbyte.Future;
import crossbyte._internal.net.IPv6;
import crossbyte.crypto.SecureRandom;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunMessage.StunAttribute;
import haxe.io.Bytes;

/**
	An address on a relay, for when no direct path exists.

	ICE tries every direct route first and usually finds one. When it does not,
	symmetric NAT at both ends, a corporate firewall that permits only
	outbound TCP, a mobile carrier's CGNAT, there is no packet either peer can
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
	the relay grants describe traffic from somewhere else, and it means the
	whole exchange can be tested against a server standing in memory.

	## A relay named by hostname is resolved once

	The first request goes to `serverAddress` as given, and the relay's first
	answer fixes where every later one goes: the address it came from. A name
	sent to for the life of an allocation was looked up again under it,
	natively every minute, on Node for every datagram, and a round-robin pool
	of relays answers each lookup with another member, which knows neither the
	allocation nor the nonce: 96,000 stale-nonce refusals in eleven seconds, and
	nothing allocated.

	## Over TCP, over IPv6, and RFC 8489's credentials

	A network that lets nothing out but TCP blocks the UDP a relay is usually
	reached by; `transport` reaches it over a TCP or TLS connection instead,
	with every message framed for a stream (RFC 8656 section 3.1), hand
	what arrives to `receiveStream`, and `streamClosed` when the connection
	ends. `requestIPv6` asks for an IPv6 relayed address, for peers on IPv6.
	A relay that offers RFC 8489's password algorithms is answered with
	SHA-256 keys and MESSAGE-INTEGRITY-SHA256, and one that offers username
	anonymity with USERHASH in place of USERNAME.

	## Requests in flight

	Each request is a transaction of its own, matched to its answer by its id,
	and several can be outstanding at once, up to `MAX_IN_FLIGHT`, with up to
	`MAX_QUEUED` more waiting for room. A refresh never waits: it goes the
	moment it is due. It used to be sent only when nothing else was in flight,
	so a caller asking for permissions faster than the relay answered them kept
	it waiting until the allocation expired. Asking for a permission that is
	already in place, or already being asked for, sends nothing.

	## Channels, and why they are off unless asked for

	A Send indication costs thirty-six bytes of STUN wrapper on every datagram.
	RFC 8656 section 12 replaces that with a channel: bind a number to a peer
	once, and everything afterwards carries a four-byte header instead. On a
	relay forwarding a stream of kilobyte chunks that is most of three percent
	of the traffic, paid on every packet, in both directions.

	`useChannels` turns it on, and it is off by default because getting it
	wrong is not a slower connection but a dead one. A `ChannelData` message is
	not STUN, its first two bits are not zero, which is exactly how it is told
	apart, so a relay that binds a channel and then drops what it is sent over
	it has no way to say so. UDP reports nothing, the datagrams stop, and there
	is nothing to fall back from.

	That is not hypothetical. node-turn, which this repository tests against,
	answers a ChannelBind with success and forwards over the channel in the
	peer-to-client direction, while its receive path rejects every datagram
	whose top two bits are set, so a client that believes the success and
	starts sending `ChannelData` is talking to nothing. Widely deployed relays
	are not like this and browsers bind channels by default; the point is only
	that a saving of thirty-two bytes is not worth a connection that dies
	silently against a relay nobody checked first.

	Once on, it happens on its own. The first datagram for a peer goes as an
	indication and asks for a channel at the same time; once the relay agrees,
	the rest go as `ChannelData`. A relay that refuses the bind outright is the
	safe case, the indications simply keep working.

	Channels last ten minutes and are rebound at eight. A rebind the relay
	refuses leaves the binding it has until its ten minutes are up, and the
	traffic goes back to indications then, rather than on into a channel the
	relay has let lapse.
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

	/** Transmissions of one request before it is given up on. **/
	public static inline var MAX_ATTEMPTS:Int = 7;

	/**
		How long the last transmission is given to be answered, in seconds:
		RFC 8489's Rm of sixteen times the first timeout.

		So a request nothing answers is given up on 39.5 seconds after it was
		first sent, which is what section 6.2.1 works out. It waited one more
		doubling instead, and gave up at 63.5.
	**/
	public static inline var FINAL_WAIT:Float = 8.0;

	/**
		How long a request over TCP or TLS is given to be answered: RFC 8489's
		Ti, the same 39.5 seconds as over UDP, spent waiting rather than
		retransmitting, since a stream already delivers or fails.
	**/
	public static inline var STREAM_TIMEOUT:Float = 39.5;

	/**
		Stale-nonce refusals one request takes before it is given up on.

		A 438 is ordinary, a relay rotates its nonces, and is answered by
		asking again with the new one. A relay that refuses the new one too,
		and the next, is not rotating anything, and asking without a limit
		asked it some nine thousand times a second.
	**/
	public static inline var MAX_STALE_NONCES:Int = 3;

	/**
		Requests outstanding at once, not counting a refresh or the Allocate.

		RFC 8489 section 6.2 asks a client to keep to ten with one server. The
		ones past this wait their turn.
	**/
	public static inline var MAX_IN_FLIGHT:Int = 8;

	/**
		Requests waiting for room, past which a new one is dropped: a
		permission or a channel, which is asked for again the next time it is
		wanted. The queue had no bound, and a caller asking faster than the
		relay answered grew it by thousands a minute.
	**/
	public static inline var MAX_QUEUED:Int = 64;

	private static inline var TRANSACTION_LENGTH:Int = 12;

	/** Superseded transactions remembered, so their late answers are known for what they are. **/
	private static inline var RETIRED_KEPT:Int = 16;

	/** Try Alternate redirections followed for one allocation before it is given up on. **/
	private static inline var MAX_REDIRECTS:Int = 4;

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

	/** How long a relay keeps a permission for. RFC 5766 section 8. **/
	public static inline var PERMISSION_LIFETIME:Float = 300;

	/** Renewed well inside that, the way a channel is. **/
	public static inline var PERMISSION_REFRESH:Float = 240;

	/**
		Whether a relay can be used from here.

		Every request carries a transaction id that must be unguessable, so this
		is `SecureRandom` reported under another name.
	**/
	public static var isSupported(default, null):Bool = SecureRandom.isSupported;

	/**
		Where requests go: the relay as given, until it first answers, and from
		then on the address that answer came from. See the class documentation
		for why a name is not sent to for the life of an allocation.
	**/
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

	/**
		Why the allocation failed or was lost, once it has: the relay's code and
		reason where it gave them. The same object `allocated` fails with as
		its `cause`; null while all is well.
	**/
	public var failure(default, null):Null<TurnError> = null;

	/** Datagrams a peer sent through the relay. **/
	public dynamic function onData(payload:ByteArray, fromAddress:String, fromPort:Int):Void {}

	/** Called with a datagram bound for the relay. **/
	public dynamic function onSend(payload:ByteArray, address:String, port:Int):Void {}

	/**
		Called once when an allocation that was granted is gone: a refresh the
		relay refused or never answered, a permission it never answered or
		answered by saying it holds no such allocation, or a refresh answered
		with a lifetime of zero. Not called for `close()`, nor for one peer the
		relay would not let through, see `onPermissionRefused`.

		`allocated` resolved long before, so it cannot say this, and `active`
		going false is a flag nothing is obliged to read. A connection whose
		path ran through the relay otherwise went silent with no reason given.
	**/
	public dynamic function onLost(reason:String):Void {}

	/**
		Called when the relay refuses to let one peer through: a CreatePermission
		answered with an error, 403 most often. The allocation carries on for
		every other peer, and that one is not asked for again.

		A refusal is ordinary, and it used to end the whole allocation. A
		hardened relay refuses private and loopback addresses, coturn's
		`denied-peer-ip`: and ICE pairs a relayed candidate with every one of
		the peer's candidates, host addresses first, so the permission asked for
		first was often one the relay would never grant: the relay was torn
		down before the relayed pair that would have worked was tried.

		@param code The relay's error code, such as 403, or 0 when it gave none.
	**/
	public dynamic function onPermissionRefused(peerAddress:String, code:Int, reason:String):Void {}

	/**
		Whether to ask for a channel per peer, trading thirty-two bytes a
		datagram for a relay that has to implement RFC 8656 section 12 in both
		directions. Off unless set; see the class documentation for what a
		half-implementation does.
	**/
	public var useChannels:Bool = false;

	/**
		How the relay is reached: datagrams, or a TCP or TLS stream whose
		arriving bytes go to `receiveStream`. See `TurnTransport`.
	**/
	public var transport(default, null):TurnTransport;

	#if !(js && !nodejs)
	/**
		For a relay reached over TLS: whether its certificate is checked, which
		it is unless this is turned off. Turn it off for a test against a
		relay with a throwaway certificate, never otherwise, and prefer
		`certAuthority` even then. As `Socket.verifyCert`.
	**/
	public var verifyCert:Bool = true;

	#if !macro
	/**
		For a relay reached over TLS: the authority its certificate must chain
		to, where that is not one the system trusts, a private relay's own.
		As `Socket.certAuthority`; `null` trusts the system's.
	**/
	public var certAuthority:Null<Certificate> = null;
	#end
	#end

	/**
		Whether to ask for an IPv6 relayed address, with RFC 8656's
		REQUESTED-ADDRESS-FAMILY, rather than the IPv4 one a relay allocates
		otherwise. Set before `allocate`. An allocation's peers are its own
		family, so an IPv6 one permits and sends to IPv6 peers only.
	**/
	public var requestIPv6:Bool = false;

	@:noCompletion private var __username:String;
	@:noCompletion private var __password:String;
	@:noCompletion private var __realm:String;
	@:noCompletion private var __nonce:String;
	@:noCompletion private var __key:Bytes;
	@:noCompletion private var __refreshAt:Float = 0;
	@:noCompletion private var __lifetime:Int = DEFAULT_LIFETIME;
	@:noCompletion private var __closed:Bool = false;

	/** Whether the relay has answered, and `serverAddress` is the address it answered from. **/
	@:noCompletion private var __pinned:Bool = false;

	/** Every server this allocation has been asked of, as "address:port", so a redirection back to one is caught. **/
	@:noCompletion private var __asked:Array<String> = [];

	/** Counts `setCredentials`, so a 401 to a request signed with the old ones can be retried with the new. **/
	@:noCompletion private var __generation:Int = 0;

	/** Requests sent and not yet answered, given up on, or superseded. **/
	@:noCompletion private var __inFlight:Array<TurnTransaction> = [];

	/** Requests waiting for room among those in flight. **/
	@:noCompletion private var __queued:Array<TurnTransaction> = [];

	/** Whether an Allocate is in flight, and a Refresh. One of each at a time. **/
	@:noCompletion private var __allocating:Bool = false;

	@:noCompletion private var __refreshing:Bool = false;

	/** Peers by address: what has been asked for each, and what the relay said. **/
	@:noCompletion private var __permissions:Map<String, TurnPermission> = new Map();

	/**
		Transactions a request has moved on from: the unsigned one a 401
		answered, the one a stale nonce was refused on. Kept so that an answer
		to one of them, arriving late, is recognised as this client's traffic
		and ignored rather than taken for an answer to what replaced it.
	**/
	@:noCompletion private var __retired:Array<ByteArray> = [];

	/** Peers with a channel bound, or one asked for. **/
	@:noCompletion private var __channels:Array<TurnChannel> = [];

	@:noCompletion private var __nextChannel:Int = FIRST_CHANNEL;

	/** The last time anything told this client, so `sendTo` can have one. **/
	@:noCompletion private var __clock:Float = 0;

	/**
		RFC 8489's password algorithm the key is derived with, MD5 unless the
		relay offered SHA-256, and the PASSWORD-ALGORITHMS it offered, echoed
		in every request as it came, or null when it offered none.
	**/
	@:noCompletion private var __algorithm:Int = StunMessage.PASSWORD_ALGORITHM_MD5;

	@:noCompletion private var __offeredAlgorithms:Null<Bytes> = null;

	/** Whether the relay asked for USERHASH in place of USERNAME. **/
	@:noCompletion private var __anonymous:Bool = false;

	/** Whether the relayed address, and so every peer, is IPv6. **/
	@:noCompletion private var __relayedIPv6:Bool = false;

	/** Bytes from the stream not yet read as whole messages, and how far they have been. **/
	@:noCompletion private var __stream:ByteArray = null;

	@:noCompletion private var __streamAt:Int = 0;

	/**
		The last IPv4 peer sent to, and its XOR-PEER-ADDRESS, which for IPv4
		does not change with the transaction: a stream of datagrams to one peer
		writes it once rather than parsing the address for each.
	**/
	@:noCompletion private var __lastPeer:String = null;

	@:noCompletion private var __lastPeerPort:Int = 0;
	@:noCompletion private var __lastPeerAttribute:StunAttribute = null;

	/**
		Random bytes for indications' transaction ids, drawn from the CSPRNG
		sixteen ids at a time: RFC 8489 wants every one cryptographically
		random, and asking the system for twelve bytes per datagram cost most
		of what a Send indication did.
	**/
	@:noCompletion private var __indicationIds:ByteArray = null;

	@:noCompletion private var __indicationAt:Int = 0;

	/**
		@param username Long-term credentials, which a relay always requires,
		it is forwarding somebody's traffic and needs to know whose.
		@param transport How the relay is reached; UDP when left out.
	**/
	public function new(serverAddress:String, serverPort:Int = 3478, username:String, password:String, ?transport:TurnTransport) {
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
		this.transport = transport != null ? transport : UDP;
		this.allocated = new Future<ReflexiveAddress>();

		// An address is where the relay's answers will come from, spelled the
		// way a socket reports a source. A name waits for the first answer,
		// unless the relay is reached over a stream, which only it is on.
		if (IPv6.isNumericAddress(serverAddress)) {
			this.serverAddress = IPv6.compress(serverAddress);
			__pinned = true;
		} else if (this.transport != UDP) {
			__pinned = true;
		}

		__asked.push(this.serverAddress + ":" + serverPort);
	}

	/**
		Replaces the credentials requests are signed with from now on.

		For a credential that expires, the TURN REST convention, where a
		relay's operator hands out a password good for an hour, or one that
		is rotated. A request already signed with the old ones and refused with
		401 is retried with these, which RFC 8489 allows a client to do only
		when something about its credentials has changed.

		A relay ties an allocation to the username that made it and refuses a
		request on it signed with another (441), so a new username is for the
		next allocation, another client, and a new password for the same
		username applies to this one.

		@throws ArgumentError When either is null, or when `username` is not
		the one an allocation held or being made was signed with. It was taken,
		and the relay refused the next Refresh with 441, ending the allocation.
	**/
	public function setCredentials(username:String, password:String):Void {
		if (username == null || password == null) {
			throw new ArgumentError("A relay needs credentials: it forwards traffic on somebody's behalf and has to know whose.");
		}

		if (username != __username && (active || (__allocating && __key != null))) {
			throw new ArgumentError("This client's allocation was made under another username, and a relay refuses a request on it signed as anyone else (441). A new username is for a new client.");
		}

		__username = username;
		__password = password;
		__generation++;

		if (__realm != null) {
			__deriveKey();
		}
	}

	/** The key requests are signed with, from the credentials, the realm and the password algorithm in use. **/
	@:noCompletion private function __deriveKey():Void {
		__key = __algorithm == StunMessage.PASSWORD_ALGORITHM_SHA256 ? StunMessage.longTermKeySha256(__username, __realm, __password) : StunMessage.longTermKey(__username,
			__realm, __password);
	}

	/**
		Renews the allocation now, rather than when half its lifetime is up.

		For after something that may have cost it: a network change, which
		moves the 5-tuple the relay knows this client by, answers the next
		refresh with 437, and waiting up to five minutes to hear that is
		five minutes of advertising a relayed address nothing reaches. A lost
		allocation is reported through `onLost` as ever.
	**/
	public function refresh(now:Float):Void {
		if (__closed || !active || __refreshing) {
			return;
		}

		__clock = now;
		__refreshing = true;
		__start(new TurnTransaction(StunMessage.REFRESH_REQUEST, [StunMessage.lifetime(__lifetime)]), now);
	}

	/**
		Asks the relay for an address.

		The first request goes out unauthenticated on purpose. A relay does not
		publish its realm, and the nonce it wants a request signed against is
		chosen per client, so the refusal that comes back is not a failure, it
		is how the exchange starts. RFC 8656 section 9.2.
	**/
	public function allocate(now:Float):Void {
		if (__closed || active || __allocating) {
			return;
		}

		__clock = now;
		__allocating = true;

		var attributes:Array<StunAttribute> = [StunMessage.requestedTransport(), StunMessage.lifetime(DEFAULT_LIFETIME)];

		if (requestIPv6) {
			attributes.push(StunMessage.requestedAddressFamily(true));
		}

		__start(new TurnTransaction(StunMessage.ALLOCATE_REQUEST, attributes), now);
	}

	/**
		Lets a peer's traffic through.

		A relay drops anything from an address it has not been told to expect,
		which is what stops an allocation being an open forwarder for whoever
		finds it. A permission lasts five minutes, and refreshing the allocation
		does not renew it (RFC 5766 section 8), `poll` asks again well inside
		that, the way it does for a channel.

		Cheap to call as often as a datagram is sent: a permission already in
		place, or already being asked for, sends nothing, and neither does one
		the relay has refused. It used to ask again on every call, and a caller
		doing that had requests queued by the thousand.

		@throws ArgumentError When `peerAddress` is not an address of the
		allocation's own family: an IPv4 allocation reaches IPv4 peers, an IPv6
		one IPv6 peers.
	**/
	public function permit(peerAddress:String, now:Float):Void {
		if (__closed || !active || peerAddress == null) {
			return;
		}

		__clock = now;
		peerAddress = __spelled(peerAddress);
		var permission = __permissions.get(peerAddress);

		if (permission == null) {
			// Before it is kept, or `poll` would renew it, and throw, for good.
			__requirePeer(peerAddress);
			permission = new TurnPermission(peerAddress);
			__permissions.set(peerAddress, permission);
		}

		// The relay said no, and asking again changes nothing; or it is being
		// asked already; or it said yes recently enough.
		if (permission.refused || permission.pending || (permission.granted && now - permission.grantedAt < PERMISSION_REFRESH)) {
			return;
		}

		permission.pending = true;

		// Its XOR-PEER-ADDRESS is written with each transaction it is sent
		// under, which for an IPv6 peer is part of the XOR: see __attributesFor.
		var request = new TurnTransaction(StunMessage.CREATE_PERMISSION_REQUEST, []);
		request.permission = permission;
		__start(request, now);
	}

	/**
		Sends a datagram to a peer through the relay.

		Wrapped in a Send indication, which is not acknowledged and not
		retransmitted, the relay forwards it or it does not, exactly as a
		datagram sent directly would arrive or not.

		@param offset Where in `payload` the datagram starts.
		@param length How many bytes it is; the rest of `payload` from
		`offset` when negative.
		@throws ArgumentError When `peerAddress` is not an address of the
		allocation's own family.
	**/
	public function sendTo(payload:ByteArray, peerAddress:String, peerPort:Int, offset:Int = 0, length:Int = -1):Void {
		if (__closed || !active) {
			return;
		}

		if (length < 0) {
			length = payload.length - offset;
		}

		peerAddress = __spelled(peerAddress);
		var channel = __channelFor(peerAddress, peerPort);

		// While the relay still holds the binding: one it refused to renew
		// lapses at ten minutes, and past that it drops what arrives on it.
		if (channel != null && channel.bound && __clock - channel.boundAt < CHANNEL_LIFETIME) {
			onSend(__channelData(channel.number, payload, offset, length), serverAddress, serverPort);
			return;
		}

		var data = new ByteArray();

		if (length > 0) {
			data.writeBytes(payload, offset, length);
		}

		data.position = 0;

		var transaction = __indicationId();
		var indication = new StunMessage(StunMessage.SEND_INDICATION, transaction, [
			__peerAttribute(peerAddress, peerPort, transaction),
			new StunAttribute(StunMessage.ATTR_DATA, data)
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
		describes it as doing both, but the permission is still asked for
		separately, since it has to be in place for the indications that carry
		the traffic in the meantime.

		@throws ArgumentError When `peerAddress` is not an address of the
		allocation's own family.
	**/
	public function bindChannel(peerAddress:String, peerPort:Int, now:Float):Void {
		if (__closed || !active || !useChannels || peerAddress == null) {
			return;
		}

		__clock = now;
		peerAddress = __spelled(peerAddress);
		var channel = __channelFor(peerAddress, peerPort);

		if (channel == null) {
			// Here rather than first: this runs for every datagram relayed, and
			// a channel already kept was checked when it was made.
			__requirePeer(peerAddress);

			if (__nextChannel > LAST_CHANNEL) {
				// Sixteen thousand peers on one allocation is not a case this
				// will meet, and silently reusing a number would send one
				// peer's traffic to another.
				return;
			}

			channel = new TurnChannel(__nextChannel++, peerAddress, peerPort);
			__channels.push(channel);
		}

		if (channel.refused || channel.pending || (channel.bound && now - channel.boundAt < CHANNEL_REFRESH)) {
			return;
		}

		channel.pending = true;

		var request = new TurnTransaction(StunMessage.CHANNEL_BIND_REQUEST, []);
		request.channel = channel;
		__start(request, now);
	}

	/**
		Refuses a peer that is not an address of the allocation's own family:
		IPv4 for an IPv4 allocation, IPv6 for an IPv6 one, as RFC 8656 section
		9.1 has a relay refuse the rest with 443.

		An IPv4 peer's octets were read with `Std.parseInt` and written modulo
		256, so 1.2.3.999 was permitted as 1.2.3.231 and an IPv6 address as
		whatever its first group read as, the relay then forwarding to a host
		nobody named.
	**/
	@:noCompletion private function __requirePeer(peerAddress:String):Void {
		if (__relayedIPv6) {
			if (StunMessage.ipv6Bytes(peerAddress) == null) {
				throw new ArgumentError("The allocation relays to IPv6 peers, and \"" + peerAddress + "\" is not an IPv6 address.");
			}
		} else if (StunMessage.ipv4Octets(peerAddress) == null) {
			throw new ArgumentError("The allocation relays to IPv4 peers, and \"" + peerAddress + "\" is not an IPv4 address.");
		}
	}

	/**
		A peer's address as the relay will report it: an IPv6 one in canonical
		form, so the Data indications it forwards find the permission asked for
		under whatever spelling. An IPv4 one, or anything that is not an IPv6
		address, as it is, the check that refuses it comes after.
	**/
	@:noCompletion private inline function __spelled(address:String):String {
		if (!__relayedIPv6 || address.indexOf(":") < 0) {
			return address;
		}

		var canonical = StunMessage.canonicalIPv6(address);
		return canonical != null ? canonical : address;
	}

	/**
		`XOR-PEER-ADDRESS` for a peer, under `transaction`, refusing one of the
		other family. An IPv4 peer's does not depend on the transaction and is
		kept for the next datagram to the same peer; an IPv6 peer's is written
		each time.
	**/
	@:noCompletion private function __peerAttribute(address:String, port:Int, transaction:ByteArray):StunAttribute {
		if (__relayedIPv6) {
			__requirePeer(address);
			return StunMessage.xorPeerAddress(address, port, transaction);
		}

		if (address == __lastPeer && port == __lastPeerPort) {
			return __lastPeerAttribute;
		}

		__requirePeer(address);
		__lastPeerAttribute = StunMessage.xorPeerAddress(address, port);
		__lastPeer = address;
		__lastPeerPort = port;
		return __lastPeerAttribute;
	}

	/** A request's attributes under `transaction`: a peer's address is written with it. **/
	@:noCompletion private function __attributesFor(request:TurnTransaction, transaction:ByteArray):Array<StunAttribute> {
		return switch (request.type) {
			case StunMessage.CREATE_PERMISSION_REQUEST:
				[StunMessage.xorPeerAddress(request.permission.address, 0, transaction)];
			case StunMessage.CHANNEL_BIND_REQUEST:
				[
					StunMessage.channelNumber(request.channel.number),
					StunMessage.xorPeerAddress(request.channel.address, request.channel.port, transaction)
				];
			default:
				request.attributes;
		}
	}

	/**
		Twelve cryptographically random bytes for an indication, from a pool
		drawn sixteen ids at a time.
	**/
	@:noCompletion private function __indicationId():ByteArray {
		if (__indicationIds == null || __indicationAt + TRANSACTION_LENGTH > __indicationIds.length) {
			__indicationIds = SecureRandom.getSecureRandomBytes(TRANSACTION_LENGTH * 16);
			__indicationAt = 0;
		}

		var id = new ByteArray();
		id.writeBytes(__indicationIds, __indicationAt, TRANSACTION_LENGTH);
		id.position = 0;
		__indicationAt += TRANSACTION_LENGTH;
		return id;
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

		Padded to four bytes over a stream only. RFC 8656 section 12.5 requires
		it there, where a reader has to find the end of one message to find the
		start of the next; a datagram already has an end.
	**/
	@:noCompletion private function __channelData(number:Int, payload:ByteArray, offset:Int, length:Int):ByteArray {
		var out = new ByteArray();
		out.writeByte((number >> 8) & 0xFF);
		out.writeByte(number & 0xFF);
		out.writeByte((length >> 8) & 0xFF);
		out.writeByte(length & 0xFF);

		if (length > 0) {
			out.writeBytes(payload, offset, length);
		}

		if (transport != UDP) {
			for (_ in 0...((4 - (length % 4)) % 4)) {
				out.writeByte(0);
			}
		}

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

		__clock = now;

		for (request in __inFlight.copy()) {
			// Finished meanwhile: an allocation that failed takes every request
			// with it.
			if (__closed || __inFlight.indexOf(request) < 0 || now < request.retryAt) {
				continue;
			}

			if (request.attempts >= MAX_ATTEMPTS) {
				__timedOut(request, now);
			} else {
				__transmit(request, now);
			}
		}

		if (__closed) {
			return;
		}

		// Refreshed at half the lifetime, so a lost refresh has one more chance
		// before the allocation the whole connection rests on disappears, and
		// the moment it is due, whatever else is waiting.
		if (active && !__refreshing && now >= __refreshAt) {
			__refreshing = true;
			__start(new TurnTransaction(StunMessage.REFRESH_REQUEST, [StunMessage.lifetime(__lifetime)]), now);
		}

		// And every channel well inside its ten minutes. One that lapses is not
		// reported: the relay simply stops recognising what it is sent.
		if (active) {
			for (channel in __channels) {
				if (channel.bound && !channel.pending && !channel.refused && now - channel.boundAt >= CHANNEL_REFRESH) {
					bindChannel(channel.address, channel.port, now);
				}
			}
		}

		// And every permission well inside its five minutes. Nothing did this:
		// the allocation was refreshed and the channels were, but a permission
		// simply lapsed, after which the relay drops that peer's traffic
		// without saying so.
		if (active) {
			for (permission in __permissions) {
				if (permission.granted && !permission.pending && !permission.refused && now - permission.grantedAt >= PERMISSION_REFRESH) {
					permit(permission.address, now);
				}
			}
		}

		__drain(now);
	}

	/**
		Offers an arriving datagram to the relay client.

		@param message The datagram already decoded, when the caller has done
		that: a socket that TURN shares with ICE decodes each datagram once and
		offers the message to both, rather than having each decode it again.
		@return Whether it was TURN traffic. Anything else belongs to whatever
		shares the socket, an ICE check, or a session already running.
	**/
	public function receive(payload:ByteArray, fromAddress:String, fromPort:Int, now:Float, ?message:StunMessage):Bool {
		// A relay reached over a stream says everything over the stream.
		if (__closed || payload == null || transport != UDP) {
			return false;
		}

		__clock = now;

		// Only the relay speaks for the relay. Relayed data and answers were
		// taken from any sender: anyone who could reach the socket could hand
		// the application a datagram as though a peer had sent it, on the
		// first channel number or wrapped as a Data indication. Once the relay
		// has an address, given as one, or the first answer's, nothing from
		// anywhere else is TURN traffic, and it is left for whoever else is on
		// the socket.
		if (fromPort != serverPort || (__pinned && fromAddress != serverAddress)) {
			return false;
		}

		return __handle(payload, message, fromAddress, now);
	}

	/**
		Offers bytes that arrived on the stream to the relay, when `transport`
		is TCP or TLS: any amount, split anywhere. Whole messages are taken out
		as they complete, a STUN message by the length in its header, a
		ChannelData message by its own, padded to four bytes, and the rest
		kept for the next call.

		A stream that carries something that is neither ends the allocation:
		past it there is no telling where the next message starts.
	**/
	public function receiveStream(bytes:ByteArray, now:Float):Void {
		if (__closed || transport == UDP || bytes == null || bytes.length == 0) {
			return;
		}

		__clock = now;

		if (__stream == null) {
			__stream = new ByteArray();
		}

		__stream.position = __stream.length;
		__stream.writeBytes(bytes, 0, bytes.length);

		while (!__closed) {
			var available:Int = __stream.length - __streamAt;

			if (available < CHANNEL_HEADER) {
				break;
			}

			var first:Int = __stream[__streamAt];
			var length:Int = (__stream[__streamAt + 2] << 8) | __stream[__streamAt + 3];
			var size:Int;
			var framed:Int;

			if (first < 0x40) {
				if (available < StunMessage.HEADER_LENGTH) {
					break;
				}

				size = StunMessage.HEADER_LENGTH + length;
				framed = size;
			} else if (first < 0x80) {
				size = CHANNEL_HEADER + length;
				framed = CHANNEL_HEADER + length + ((4 - (length % 4)) % 4);
			} else {
				__fail("The connection to the relay at " + __serverName() + " carried something that is neither STUN nor ChannelData.");
				return;
			}

			if (available < framed) {
				break;
			}

			var message = new ByteArray();
			message.writeBytes(__stream, __streamAt, size);
			message.position = 0;
			__streamAt += framed;
			__handle(message, null, serverAddress, now);
		}

		// Kept compact: what is read is let go, and a stream that only ever
		// holds part of one message stays one message long.
		if (__stream != null) {
			if (__streamAt >= __stream.length) {
				__stream = null;
				__streamAt = 0;
			} else if (__streamAt > 0) {
				var rest = new ByteArray();
				rest.writeBytes(__stream, __streamAt, __stream.length - __streamAt);
				__stream = rest;
				__streamAt = 0;
			}
		}
	}

	/**
		Says the stream to the relay has ended, when `transport` is TCP or TLS.
		The allocation ends with it, a relay deletes an allocation whose
		connection closes, and is reported the way any other loss is.
	**/
	public function streamClosed(reason:String):Void {
		if (__closed || transport == UDP) {
			return;
		}

		__fail("The connection to the relay at " + __serverName() + " closed" + (reason != null && reason.length > 0 ? ": " + reason : "."));
	}

	/** A message from the relay, off the socket or out of the stream. **/
	@:noCompletion private function __handle(payload:ByteArray, message:Null<StunMessage>, fromAddress:String, now:Float):Bool {
		// Before decoding: a ChannelData message is not STUN, and its first two
		// bytes are a channel number that would read as a message type nothing
		// here has.
		if (message == null && __deliverChannelData(payload)) {
			return true;
		}

		if (message == null) {
			message = StunMessage.decode(payload);
		}

		if (message == null) {
			return false;
		}

		if (message.type == StunMessage.DATA_INDICATION) {
			__deliver(message);
			return true;
		}

		if (!__isTurnResponse(message.type)) {
			// A binding response, most likely: this client and an ICE agent
			// commonly share a socket. Not ours.
			return false;
		}

		// Every answer is matched to the request it answers, by transaction,
		// before anything is done with it.
		var request = __requestFor(message);

		if (request == null) {
			// An answer to a transaction this client has moved on from: the
			// unsigned request a 401 answered twice, say. Its own, and nothing
			// to act on. Anything else is somebody else's.
			return __isRetired(message);
		}

		// An answer that fails its checks is dropped as though it never came,
		// and the request goes on being retransmitted: RFC 8489 section 9.2.5.
		// A signed request's answer was believed without its integrity being
		// looked at, so whoever saw a request go by could answer it, with a
		// relayed address of their own choosing.
		if (!__authentic(request, message)) {
			request.discarded++;
			return true;
		}

		// Where requests go from here: the address the relay answered from,
		// which is the one lookup of its name this allocation needs.
		if (!__pinned) {
			__pinned = true;
			serverAddress = fromAddress;
			__asked.push(fromAddress + ":" + serverPort);
		}

		// One the relay requires understood and this client does not, which
		// changes the answer in a way it cannot see: not an answer it can act
		// on (section 7.3.3).
		var unknown:Int = message.unknownRequiredAttribute();

		if (unknown >= 0) {
			__requestFailed(request, 0, "The relay answered with an attribute it requires understood and this client does not: 0x"
				+ StringTools.hex(unknown, 4) + ".", false, now);
			return true;
		}

		if ((message.type & 0x0110) == 0x0110) {
			__answeredWithError(request, message, now);
		} else {
			__answeredWithSuccess(request, message, now);
		}

		return true;
	}

	/**
		Whether an answer can be believed.

		A FINGERPRINT, when there is one, has to match. And an answer to a
		signed request has to be signed with the same key, except a 401 or a
		438, which ask for credentials and cannot carry them. An unsigned
		request's answer has nothing to be checked against, which is why the
		first exchange only ever asks for credentials.
	**/
	@:noCompletion private function __authentic(request:TurnTransaction, message:StunMessage):Bool {
		if (message.attribute(StunMessage.ATTR_FINGERPRINT) != null && !message.verifyFingerprint()) {
			return false;
		}

		if (!request.signed) {
			return true;
		}

		if ((message.type & 0x0110) == 0x0110) {
			var code:Int = message.errorCodeValue();

			if (code == StunMessage.UNAUTHORIZED || code == StunMessage.STALE_NONCE) {
				return true;
			}
		}

		// Whichever integrity the relay wrote: SHA-256 once it offered its
		// password algorithms, SHA-1 before.
		return request.key != null && message.verifyAnyIntegrityWithKey(request.key);
	}

	/** A success or an error for one of the four methods this client asks. **/
	@:noCompletion private static function __isTurnResponse(type:Int):Bool {
		return switch (type) {
			case StunMessage.ALLOCATE_SUCCESS, StunMessage.ALLOCATE_ERROR, StunMessage.REFRESH_SUCCESS, StunMessage.REFRESH_ERROR,
				StunMessage.CREATE_PERMISSION_SUCCESS, StunMessage.CREATE_PERMISSION_ERROR, StunMessage.CHANNEL_BIND_SUCCESS,
				StunMessage.CHANNEL_BIND_ERROR:
				true;
			default:
				false;
		}
	}

	/** The request in flight that `message` answers, of the method it answers for. **/
	@:noCompletion private function __requestFor(message:StunMessage):Null<TurnTransaction> {
		var method:Int = message.type & 0x3EEF;

		for (request in __inFlight) {
			if (request.type == method && request.message.matches(message)) {
				return request;
			}
		}

		return null;
	}

	/** Whether `message` answers a transaction this client superseded. **/
	@:noCompletion private function __isRetired(message:StunMessage):Bool {
		for (retired in __retired) {
			if (new StunMessage(0, retired).matches(message)) {
				return true;
			}
		}

		return false;
	}

	/**
		Stops, and tells the relay to free the allocation.

		The telling is a Refresh with a lifetime of zero, which is how RFC 8656
		deletes an allocation, sent once and not retransmitted: nothing is left
		to hear the answer. Without it the relay held the allocation and its
		port for as long as it had been granted, an hour on some relays,
		so the next client on the same socket was refused with 437, and an
		application that reconnected ran into the relay's quota. Sent too when
		the Allocate is still unanswered but signed, since the relay may have
		granted it already.
	**/
	public function close():Void {
		if (__closed) {
			return;
		}

		var holding:Bool = active || (__allocating && __key != null);

		__closed = true;
		active = false;
		__inFlight = [];
		__queued = [];
		__allocating = false;
		__refreshing = false;

		if (holding && __key != null && __realm != null && __nonce != null) {
			var release = new TurnTransaction(StunMessage.REFRESH_REQUEST, [StunMessage.lifetime(0)]);
			release.message = new StunMessage(StunMessage.REFRESH_REQUEST, __transaction(), release.attributes);
			onSend(__encode(release), serverAddress, serverPort);
		}

		// Same as the others in this stack: nothing settled `allocated` on a
		// close, so a caller that closed a client mid-allocation waited on a
		// future that could never complete either way.
		@:privateAccess allocated.__cancel("The client was closed before the relay answered.");
	}

	// ------------------------------------------------------------------
	// Requests
	// ------------------------------------------------------------------

	/**
		Sends a request, or queues it behind those in flight.

		An Allocate and a Refresh are never queued. Nothing else can be in
		flight before the Allocate is answered, and a Refresh queued behind
		permissions was how an allocation expired while the client was busy
		asking for them.
	**/
	@:noCompletion private function __start(request:TurnTransaction, now:Float):Void {
		var exempt:Bool = request.type == StunMessage.ALLOCATE_REQUEST || request.type == StunMessage.REFRESH_REQUEST;

		if (!exempt && __inFlight.length >= MAX_IN_FLIGHT) {
			if (__queued.length >= MAX_QUEUED) {
				// Dropped, and asked for again the next time it is wanted.
				__abandon(request);
				return;
			}

			__queued.push(request);
			return;
		}

		var transaction = __transaction();
		request.message = new StunMessage(request.type, transaction, __attributesFor(request, transaction));
		__inFlight.push(request);
		__transmit(request, now);
	}

	/** Starts what was waiting, as far as there is room. **/
	@:noCompletion private function __drain(now:Float):Void {
		while (!__closed && __queued.length > 0 && __inFlight.length < MAX_IN_FLIGHT) {
			__start(__queued.shift(), now);
		}
	}

	@:noCompletion private function __transmit(request:TurnTransaction, now:Float):Void {
		request.attempts++;

		if (transport != UDP) {
			// Sent once: a stream delivers or fails, and retransmitting over it
			// only sends the relay the same request twice. The whole of Ti is
			// then the wait for the answer.
			request.attempts = MAX_ATTEMPTS;
			request.retryAt = now + STREAM_TIMEOUT;
		} else {
			// Doubling from half a second, and the last transmission given
			// sixteen times the first to be answered: RFC 8489 section 6.2.1.
			request.retryAt = now + (request.attempts >= MAX_ATTEMPTS ? FINAL_WAIT : RETRY_AFTER * Math.pow(2, request.attempts - 1));
		}

		if (request.encoded == null) {
			request.encoded = __encode(request);
		}

		request.encoded.position = 0;
		onSend(request.encoded, serverAddress, serverPort);
	}

	/**
		The request's bytes, signed once the relay has said which realm and
		nonce to sign against. Before that there is nothing to key with, which
		is the whole point of the first exchange.
	**/
	@:noCompletion private function __encode(request:TurnTransaction):ByteArray {
		if (__key != null && __realm != null && __nonce != null) {
			request.signed = true;
			request.nonce = __nonce;
			request.key = __key;
			request.generation = __generation;

			// USERHASH in place of USERNAME where the relay offered username
			// anonymity, so the name never crosses the network in the clear.
			var credentials:Array<StunAttribute> = [
				__anonymous ? StunMessage.bytesAttribute(StunMessage.ATTR_USERHASH,
					StunMessage.userHash(__username, __realm)) : StunMessage.text(StunMessage.ATTR_USERNAME, __username),
				StunMessage.text(StunMessage.ATTR_REALM, __realm),
				StunMessage.text(StunMessage.ATTR_NONCE, __nonce)
			];

			// And where it offered password algorithms, the one chosen, the list
			// echoed as it came, which is what tells the relay nothing
			// stripped it on the way, and SHA-256 integrity alone, as RFC 8489
			// section 9.2.5 has it.
			if (__offeredAlgorithms != null) {
				credentials.push(StunMessage.passwordAlgorithm(__algorithm));
				credentials.push(StunMessage.bytesAttribute(StunMessage.ATTR_PASSWORD_ALGORITHMS, __offeredAlgorithms));
			}

			var signed = new StunMessage(request.type, request.message.transactionId, request.message.attributes.concat(credentials));
			return __offeredAlgorithms != null ? signed.encodeSignedSha256WithKey(__key, false) : signed.encodeSignedWithKey(__key, false);
		}

		request.signed = false;
		request.nonce = null;
		request.key = null;
		return request.message.encode();
	}

	/**
		Moves a request to a new transaction and sends it, remembering the old.

		RFC 8489 section 9.2.5: a request retried with credentials, or with a
		fresh nonce, is a new transaction. Retrying under the old one meant a
		second answer to the first attempt, a 401 to an unsigned request that
		had been retransmitted, because its answer was slow, matched the
		signed retry and read as the credentials being rejected.
	**/
	@:noCompletion private function __retry(request:TurnTransaction, now:Float):Void {
		__retired.push(request.message.transactionId);

		if (__retired.length > RETIRED_KEPT) {
			__retired.shift();
		}

		var transaction = __transaction();
		request.message = new StunMessage(request.type, transaction, __attributesFor(request, transaction));
		request.encoded = null;
		request.attempts = 0;
		__transmit(request, now);
	}

	/** Takes a request out of flight, answered or given up on. **/
	@:noCompletion private function __finish(request:TurnTransaction):Void {
		__inFlight.remove(request);

		switch (request.type) {
			case StunMessage.ALLOCATE_REQUEST:
				__allocating = false;
			case StunMessage.REFRESH_REQUEST:
				__refreshing = false;
			default:
		}
	}

	/** Forgets a permission or a channel request that will not be sent, so it is asked for again when wanted. **/
	@:noCompletion private function __abandon(request:TurnTransaction):Void {
		if (request.permission != null) {
			request.permission.pending = false;
		}

		if (request.channel != null) {
			request.channel.pending = false;
		}
	}

	@:noCompletion private function __timedOut(request:TurnTransaction, now:Float):Void {
		__finish(request);

		// A channel is a saving and not the path: the indications still work,
		// so a bind nobody answered costs the channel and nothing else.
		if (request.type == StunMessage.CHANNEL_BIND_REQUEST) {
			request.channel.pending = false;
			request.channel.refused = true;
			__drain(now);
			return;
		}

		// Answered, but never by anything that could sign for the relay: RFC
		// 8489 has that said as what it is rather than as a timeout.
		if (request.discarded > 0) {
			__fail("The relay at " + __serverName() + " answered only with messages that failed their integrity check, so none of them could be believed.");
			return;
		}

		__fail("The relay at " + __serverName() + " did not answer.");
	}

	/** Where requests go, as "address:port", with an IPv6 address bracketed. **/
	@:noCompletion private function __serverName():String {
		return (serverAddress.indexOf(":") >= 0 ? "[" + serverAddress + "]" : serverAddress) + ":" + serverPort;
	}

	// ------------------------------------------------------------------
	// Answers
	// ------------------------------------------------------------------

	@:noCompletion private function __answeredWithSuccess(request:TurnTransaction, message:StunMessage, now:Float):Void {
		__finish(request);

		switch (request.type) {
			case StunMessage.ALLOCATE_REQUEST:
				__allocated(message, now);
			case StunMessage.REFRESH_REQUEST:
				__refreshed(message, now);
			case StunMessage.CREATE_PERMISSION_REQUEST:
				request.permission.pending = false;
				request.permission.granted = true;
				request.permission.grantedAt = now;
			case StunMessage.CHANNEL_BIND_REQUEST:
				request.channel.pending = false;
				request.channel.bound = true;
				request.channel.boundAt = now;
			default:
		}

		__drain(now);
	}

	@:noCompletion private function __answeredWithError(request:TurnTransaction, message:StunMessage, now:Float):Void {
		var code = message.errorCodeValue();

		// 401 the first time, 438 when the nonce a request was signed against
		// has expired. Both mean the same thing: take the credentials offered
		// and ask again, as a new transaction. For any request, a ChannelBind
		// included, which was not retried, so a nonce that went stale between
		// refreshes left the channel marked bound while the relay dropped
		// everything sent on it.
		if (code == StunMessage.UNAUTHORIZED || code == StunMessage.STALE_NONCE) {
			var realm = message.textOf(StunMessage.ATTR_REALM);
			var nonce = message.textOf(StunMessage.ATTR_NONCE);

			if (realm == null || nonce == null) {
				__requestFailed(request, code, "The relay refused the request without saying what credentials it wants.", true, now);
				return;
			}

			// Only once for 401, so a relay that keeps refusing cannot hold
			// this in a loop: a signed request refused is refused credentials,
			// unless they have been replaced since it was signed, which is
			// the one change RFC 8489 lets a client retry a 401 for.
			if (code == StunMessage.UNAUTHORIZED && request.signed && request.generation == __generation) {
				__requestFailed(request, code, "The relay rejected these credentials.", true, now);
				return;
			}

			// Counted only when the nonce refused was the newest this client
			// had. Several requests in flight can each be refused a nonce that
			// another's refusal has already replaced; that is the rotation
			// catching up, not the relay refusing everything.
			if (code == StunMessage.STALE_NONCE && request.signed && request.nonce == __nonce && ++request.staleNonces > MAX_STALE_NONCES) {
				__requestFailed(request, code, "The relay refused every nonce it offered as stale.", true, now);
				return;
			}

			// RFC 8489's security features, which the nonce declares. A nonce
			// saying the relay offers password algorithms, on an answer that
			// lists none, is the list stripped on the way, a downgrade to
			// MD5, and section 9.2.5 has the client not retry at all.
			var features:Int = StunMessage.nonceFeatures(nonce);
			var offered = message.attribute(StunMessage.ATTR_PASSWORD_ALGORITHMS);

			if ((features & StunMessage.FEATURE_PASSWORD_ALGORITHMS) != 0 && offered == null) {
				__requestFailed(request, code, "The relay's nonce offers password algorithms and its answer lists none, "
					+ "which is what stripping them on the way looks like, so it was not answered.", true, now);
				return;
			}

			var algorithm:Int = __algorithm;

			if (offered != null) {
				algorithm = -1;

				// The first the relay lists that this client knows.
				for (candidate in message.passwordAlgorithms()) {
					if (candidate == StunMessage.PASSWORD_ALGORITHM_SHA256 || candidate == StunMessage.PASSWORD_ALGORITHM_MD5) {
						algorithm = candidate;
						break;
					}
				}

				if (algorithm < 0) {
					__requestFailed(request, code, "The relay offers no password algorithm this client supports.", true, now);
					return;
				}

				var copy = Bytes.alloc(offered.length);
				copy.blit(0, offered, 0, offered.length);
				__offeredAlgorithms = copy;
			} else if (code == StunMessage.UNAUTHORIZED) {
				// A relay from before RFC 8489: MD5, SHA-1 integrity, as ever.
				algorithm = StunMessage.PASSWORD_ALGORITHM_MD5;
				__offeredAlgorithms = null;
			}

			__anonymous = (features & StunMessage.FEATURE_USERNAME_ANONYMITY) != 0;

			if (realm != __realm || __key == null || algorithm != __algorithm) {
				__realm = realm;
				__algorithm = algorithm;
				__deriveKey();
			}

			__nonce = nonce;
			__retry(request, now);
			return;
		}

		var phrase = message.errorReason();

		// 300: this relay would rather another did it. Followed for the
		// Allocate, and the relay it names asked afresh, since its realm and
		// nonce are its own.
		if (code == StunMessage.TRY_ALTERNATE && request.type == StunMessage.ALLOCATE_REQUEST) {
			var alternate = message.alternateServerAddress();

			if (alternate != null) {
				__redirect(request, alternate, phrase != null ? phrase : "", now);
				return;
			}
		}

		// 437: the relay holds no such allocation. Whatever the request was
		// about, the allocation it was about is gone.
		__requestFailed(request, code, phrase != null ? phrase : "", code == StunMessage.ALLOCATION_MISMATCH, now);
	}

	/**
		Follows a 300 Try Alternate: the Allocate goes to the server it names,
		as a new transaction, with the same credentials (RFC 8489 section 10).

		It was a failure like any other, so a relay deployment that balanced
		its load by redirecting turned every client away from all of it. A
		server already asked is not asked again, RFC 8489 has a redirection
		back to one ignored and the transaction failed, which is what stops two
		relays sending a client back and forth for good, and neither is a
		fifth, however many different ones are named.
	**/
	@:noCompletion private function __redirect(request:TurnTransaction, alternate:ReflexiveAddress, phrase:String, now:Float):Void {
		var address:String = IPv6.compress(alternate.address);
		var target:String = address + ":" + alternate.port;

		if (__asked.indexOf(target) >= 0 || __asked.length > MAX_REDIRECTS) {
			__finish(request);
			__fail("The relay at " + __serverName() + " redirected to " + target + ", which had already been asked.",
				new TurnError(StunMessage.TRY_ALTERNATE, phrase.length > 0 ? phrase : "Try Alternate", __serverName(), alternate));
			return;
		}

		__asked.push(target);
		serverAddress = address;
		serverPort = alternate.port;
		__pinned = true;

		// Another server's realm, nonce and features, which it will state.
		__realm = null;
		__nonce = null;
		__key = null;
		__offeredAlgorithms = null;
		__algorithm = StunMessage.PASSWORD_ALGORITHM_MD5;
		__anonymous = false;

		__retry(request, now);
	}

	/**
		A request the relay will not grant.

		@param reason The relay's reason phrase, or what went wrong in words
		when the relay's answer was not the problem.
		@param fatal Whether it ends the allocation whatever the request was:
		credentials the relay will not take, or an allocation it says it does
		not hold. Otherwise a permission refuses that peer and a bind that
		channel, and only an Allocate or a Refresh ends anything.
	**/
	@:noCompletion private function __requestFailed(request:TurnTransaction, code:Int, reason:String, fatal:Bool, now:Float):Void {
		__finish(request);

		if (!fatal) {
			switch (request.type) {
				case StunMessage.CREATE_PERMISSION_REQUEST:
					// A peer the relay will not forward to, which is that
					// peer's problem and nobody else's.
					request.permission.pending = false;
					__refusePermission(request.permission, code, reason);
					__drain(now);
					return;
				case StunMessage.CHANNEL_BIND_REQUEST:
					// The relay would not, so this peer keeps costing a
					// wrapper. Not a failure of the connection: indications
					// still work, and treating it as one would give up a
					// working path over a saving.
					request.channel.pending = false;
					request.channel.refused = true;
					__drain(now);
					return;
				default:
			}
		}

		// Credentials and nonces are this client's own words for what went
		// wrong; anything else is the relay's code and phrase.
		var credentials:Bool = fatal && code != StunMessage.ALLOCATION_MISMATCH;
		__fail(credentials ? reason : "The relay refused the request: " + code + (reason.length > 0 ? " " + reason : ""),
			new TurnError(code, reason.length > 0 ? reason : Std.string(code), __serverName()));
	}

	/** Marks a peer refused, so it is neither asked for again nor renewed, and says so. **/
	@:noCompletion private function __refusePermission(permission:TurnPermission, code:Int, reason:String):Void {
		if (permission.refused) {
			return;
		}

		permission.refused = true;
		onPermissionRefused(permission.address, code, reason);
	}

	@:noCompletion private function __allocated(message:StunMessage, now:Float):Void {
		var relayed = message.addressOf(StunMessage.ATTR_XOR_RELAYED_ADDRESS);

		if (relayed == null) {
			__fail("The relay allocated nothing: its reply carried no relayed address.");
			return;
		}

		relayedAddress = relayed;
		mappedAddress = message.addressOf(StunMessage.ATTR_XOR_MAPPED_ADDRESS);
		__lifetime = message.uintOf(StunMessage.ATTR_LIFETIME, DEFAULT_LIFETIME);
		__refreshAt = now + __lifetime / 2;

		// The family every peer of this allocation is written in.
		__relayedIPv6 = relayed.address.indexOf(":") >= 0;
		active = true;

		@:privateAccess allocated.__resolve(relayed);
	}

	@:noCompletion private function __refreshed(message:StunMessage, now:Float):Void {
		__lifetime = message.uintOf(StunMessage.ATTR_LIFETIME, __lifetime);

		if (__lifetime <= 0) {
			// A zero lifetime is how a relay says the allocation is gone. This
			// client asks for one only from close(), which is not listening by
			// the time the answer comes, so one arriving here is the relay's
			// decision, and the caller has to hear it.
			__fail("The relay at " + __serverName() + " ended the allocation.");
			return;
		}

		__refreshAt = now + __lifetime / 2;
	}

	// ------------------------------------------------------------------
	// Data
	// ------------------------------------------------------------------

	/**
		Unwraps a `ChannelData` message, if that is what this is.

		@return Whether it was. A channel number is one this client handed out,
		so anything else, including a datagram that merely starts in the same
		byte range, is left for whoever else is on the socket.
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

	@:noCompletion private function __deliver(message:StunMessage):Void {
		var peer = message.addressOf(StunMessage.ATTR_XOR_PEER_ADDRESS);
		var payload = message.attribute(StunMessage.ATTR_DATA);

		if (peer == null || payload == null) {
			return;
		}

		// Only from a peer this client let through. A relay forwards nothing
		// else, so anything else claiming to be relayed was not.
		var permission = __permissions.get(peer.address);

		if (permission == null || permission.refused || !(permission.granted || permission.pending)) {
			return;
		}

		payload.position = 0;
		onData(payload, peer.address, peer.port);
	}

	/**
		Ends the allocation, or the attempt at one, saying why.

		@param error The relay's code and reason, when it gave them; one with a
		code of 0 is made from `reason` when it did not.
	**/
	@:noCompletion private function __fail(reason:String, ?error:TurnError):Void {
		var wasActive:Bool = active;

		__inFlight = [];
		__queued = [];
		__allocating = false;
		__refreshing = false;
		active = false;

		if (failure == null) {
			failure = error != null ? error : new TurnError(0, reason, __serverName());
		}

		if (!__closed) {
			@:privateAccess allocated.__fail(reason, failure);
		}

		__closed = true;

		// An allocation that was working and now is not. Before one was
		// granted, `allocated` failing is the report.
		if (wasActive) {
			onLost(reason);
		}
	}

	@:noCompletion private static function __transaction():ByteArray {
		return SecureRandom.getSecureRandomBytes(TRANSACTION_LENGTH);
	}
}

/**
	One request, and where it has got to: its transaction, which changes each
	time it is retried with new credentials, and its retransmission schedule.
**/
private class TurnTransaction {
	public var type(default, null):Int;
	public var attributes(default, null):Array<StunAttribute>;

	/** The request as it stands, unsigned: its type, its current transaction, its attributes. **/
	public var message:StunMessage;

	/** What goes on the wire, encoded once per transaction and resent as it is. **/
	public var encoded:Null<ByteArray> = null;

	public var attempts:Int = 0;
	public var retryAt:Float = 0;

	/** Whether the transaction in flight was signed, against which nonce, and with which key. **/
	public var signed:Bool = false;

	public var nonce:Null<String> = null;

	public var key:Null<Bytes> = null;

	/** Which credentials it was signed with, counted by `TurnClient.setCredentials`. **/
	public var generation:Int = 0;

	/** Answers dropped for failing their checks: what a request that then times out is reported as. **/
	public var discarded:Int = 0;

	/** Stale-nonce refusals counted against it; see `TurnClient.MAX_STALE_NONCES`. **/
	public var staleNonces:Int = 0;

	/** The peer a CreatePermission asks for, or the channel a ChannelBind binds. **/
	public var permission:Null<TurnPermission> = null;

	public var channel:Null<TurnChannel> = null;

	public function new(type:Int, attributes:Array<StunAttribute>) {
		this.type = type;
		this.attributes = attributes;
	}
}

/** A peer, and what the relay has said about letting it through. **/
private class TurnPermission {
	public var address(default, null):String;

	/** Whether a CreatePermission for it is in flight or queued. **/
	public var pending:Bool = false;

	/** Whether the relay granted it, and when it last did. **/
	public var granted:Bool = false;

	public var grantedAt:Float = 0;

	/** Whether the relay refused it, which it is not asked twice about. **/
	public var refused:Bool = false;

	public function new(address:String) {
		this.address = address;
	}
}

/**
	One channel: a number the relay agreed stands for a peer.

	`boundAt` is when the relay last agreed, which is what the rebind at eight
	minutes and the lapse at ten are both measured from.
**/
private class TurnChannel {
	public var number(default, null):Int;
	public var address(default, null):String;
	public var port(default, null):Int;

	/** Whether the relay has agreed. Until then traffic goes as indications. **/
	public var bound:Bool = false;

	public var boundAt:Float = 0;

	/** Whether a ChannelBind for it is in flight or queued. **/
	public var pending:Bool = false;

	/** Whether the relay refused a bind, or never answered one; it is not asked again. **/
	public var refused:Bool = false;

	public function new(number:Int, address:String, port:Int) {
		this.number = number;
		this.address = address;
		this.port = port;
	}
}
