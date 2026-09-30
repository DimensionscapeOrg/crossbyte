package crossbyte.net;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunMessage.StunAttribute;
import haxe.io.Bytes;

/**
	A TURN relay written for the tests, from RFC 8656 and RFC 8489 rather than
	from `TurnClient`, with a switch for each way a relay can be awkward.

	The round-two audit found most of what these switches do with a relay it
	wrote in Node; this is that relay in Haxe, so the same cases run wherever
	`TurnClient` does -- and in memory on every target, the browser included,
	since nothing here needs a socket or a clock.

	`receive` takes a datagram, where it came from and the time. Whatever the
	relay sends goes out through `onToClient` and `onToPeer`, at once or
	`delay` seconds later from `flush`. `FakeTurnRelaySocket` puts it on real
	sockets; `TurnNetwork` runs it against a client in memory.

	It signs every answer to an authenticated request, errors included, the
	way RFC 8489 section 9.2.4 asks and coturn does -- except where a switch
	says otherwise.
**/
class FakeTurnRelay {
	/** What RFC 5389 and 8489 put in every message. **/
	public static inline var MAGIC_COOKIE:Int = 0x2112A442;

	public var realm:String = "fake.test";

	/** Username to password. **/
	public var users:Map<String, String>;

	public var maxLifetime:Int = 3600;
	public var permissionLifetime:Float = 300;
	public var channelLifetime:Float = 600;

	/** Seconds a nonce is good for, from when it was issued; 0 for ever. **/
	public var staleNonceAfter:Float = 0;

	/** Peers a permission or a channel is refused for, with 403, as a hardened relay refuses private addresses. **/
	public var denyPeers:Array<String> = [];

	/** An authenticated Allocate refused with this code, and an ALTERNATE-SERVER when it names one. **/
	public var allocateError:Null<RelayRefusal> = null;

	/** Corrupts MESSAGE-INTEGRITY in every success it sends. **/
	public var badIntegrity:Bool = false;

	/** Adds a comprehension-required attribute nobody understands to every success. **/
	public var unknownAttribute:Bool = false;

	/** Answers every signed request with 438 and a fresh nonce. **/
	public var always438:Bool = false;

	/** Refuses to bind channels, with 400. **/
	public var refuseChannels:Bool = false;

	/** Signs a ChannelBind success. node-turn leaves it unsigned. **/
	public var signChannelBind:Bool = true;

	/** Answers a Refresh with 437, as a relay that has lost the allocation does. **/
	public var refuseRefresh:Bool = false;

	/** Says nothing at all. **/
	public var dropAll:Bool = false;

	/** Drops the first this many datagrams from clients. **/
	public var dropFirst:Int = 0;

	/** Seconds before anything the relay sends leaves. **/
	public var delay:Float = 0;

	/** Sends each CreatePermission success again this many seconds later; 0 for never. **/
	public var duplicatePermissionSuccess:Float = 0;

	/** What happened, one word each, in order: "allocated", "refused-401", "deallocated" and so on. **/
	public var events(default, null):Array<String> = [];

	/** Datagrams from clients, dropped ones included. **/
	public var received(default, null):Int = 0;

	/** Requests by method, signed or not: "allocate", "refresh", "permission", "bind". **/
	public var requests(default, null):Map<String, Int> = new Map();

	/** The LIFETIME each Refresh asked for, in order. **/
	public var refreshLifetimes(default, null):Array<Int> = [];

	/** Called with a datagram for a client. **/
	public dynamic function onToClient(bytes:ByteArray, address:String, port:Int):Void {}

	/** Called with a datagram a relayed address sends to a peer. **/
	public dynamic function onToPeer(relayPort:Int, bytes:ByteArray, address:String, port:Int):Void {}

	/**
		Called for each allocation, for the address it relays from. In memory
		that is an address that exists nowhere; on sockets, one bound for it.
	**/
	public dynamic function openRelay():RelayEndpoint {
		return {address: "203.0.113.10", port: __nextRelayPort++};
	}

	/** Called when an allocation ends, with the port `openRelay` gave it. **/
	public dynamic function closeRelay(port:Int):Void {}

	@:noCompletion private var __nextRelayPort:Int = 49152;
	@:noCompletion private var __allocations:Map<String, FakeAllocation> = new Map();
	@:noCompletion private var __nonces:Map<String, FakeNonce> = new Map();
	@:noCompletion private var __nonceCount:Int = 0;
	@:noCompletion private var __transactionCount:Int = 0;
	@:noCompletion private var __outbox:Array<FakeOutbound> = [];

	public function new() {
		users = ["user" => "secret"];
	}

	/** How many times `kind` happened. **/
	public function count(kind:String):Int {
		var n:Int = 0;

		for (event in events) {
			if (event == kind) {
				n++;
			}
		}

		return n;
	}

	/** Requests of one method so far. **/
	public function requestsOf(method:String):Int {
		return requests.exists(method) ? requests.get(method) : 0;
	}

	/** Allocations the relay holds now. **/
	public var allocations(get, never):Int;

	@:noCompletion private function get_allocations():Int {
		var n:Int = 0;

		for (_ in __allocations) {
			n++;
		}

		return n;
	}

	/** The allocation made for a client, if it holds one. **/
	public function allocationFor(address:String, port:Int):Null<FakeAllocation> {
		return __allocations.get(address + ":" + port);
	}

	/** Every allocation it holds. **/
	public function allAllocations():Array<FakeAllocation> {
		return [for (allocation in __allocations) allocation];
	}

	/** Ends every allocation, as a relay restarting would. **/
	public function forgetEverything():Void {
		for (allocation in __allocations) {
			closeRelay(allocation.relayPort);
		}

		__allocations = new Map();
		__nonces = new Map();
	}

	/** Sends what is due by `now`. **/
	public function flush(now:Float):Void {
		if (__outbox.length == 0) {
			return;
		}

		var due:Array<FakeOutbound> = [];
		var kept:Array<FakeOutbound> = [];

		for (item in __outbox) {
			if (item.at <= now) {
				due.push(item);
			} else {
				kept.push(item);
			}
		}

		__outbox = kept;

		for (item in due) {
			__deliver(item);
		}
	}

	// ------------------------------------------------------------------
	// From clients
	// ------------------------------------------------------------------

	/** A datagram from a client, to the relay's own address. **/
	public function receive(data:ByteArray, fromAddress:String, fromPort:Int, now:Float):Void {
		received++;

		if (dropAll || received <= dropFirst) {
			events.push("dropped");
			return;
		}

		var key:String = fromAddress + ":" + fromPort;
		__expire(key, now);

		if (data.length >= 4 && data[0] >= 0x40 && data[0] <= 0x7F) {
			__channelData(key, data, now);
			return;
		}

		var message = StunMessage.decode(data);

		if (message == null) {
			events.push("noise");
			return;
		}

		switch (message.type) {
			case StunMessage.SEND_INDICATION:
				__sendIndication(key, message, now);
			case StunMessage.ALLOCATE_REQUEST:
				__count("allocate");
				__allocate(key, fromAddress, fromPort, message, now);
			case StunMessage.REFRESH_REQUEST:
				__count("refresh");
				__refresh(key, fromAddress, fromPort, message, now);
			case StunMessage.CREATE_PERMISSION_REQUEST:
				__count("permission");
				__permit(key, fromAddress, fromPort, message, now);
			case StunMessage.CHANNEL_BIND_REQUEST:
				__count("bind");
				__bind(key, fromAddress, fromPort, message, now);
			default:
				events.push("unhandled");
		}
	}

	/** A datagram a peer sent to the relayed address on `relayPort`. **/
	public function fromPeer(relayPort:Int, data:ByteArray, fromAddress:String, fromPort:Int, now:Float):Void {
		var allocation:FakeAllocation = null;

		for (candidate in __allocations) {
			if (candidate.relayPort == relayPort) {
				allocation = candidate;
			}
		}

		if (allocation == null) {
			events.push("peer-no-allocation");
			return;
		}

		__expire(allocation.key, now);

		if (!__allocations.exists(allocation.key)) {
			return;
		}

		if (!allocation.permitted(fromAddress, now)) {
			events.push("peer-dropped");
			return;
		}

		var number:Int = allocation.channelTo(fromAddress, fromPort, now);

		if (number > 0) {
			var framed = new ByteArray();
			framed.writeByte((number >> 8) & 0xFF);
			framed.writeByte(number & 0xFF);
			framed.writeByte((data.length >> 8) & 0xFF);
			framed.writeByte(data.length & 0xFF);
			framed.writeBytes(data, 0, data.length);
			framed.position = 0;
			events.push("to-client-channel");
			__send(framed, allocation.clientAddress, allocation.clientPort, now);
			return;
		}

		var indication = new StunMessage(StunMessage.DATA_INDICATION, __transaction(), [
			StunMessage.xorPeerAddress(fromAddress, fromPort),
			StunMessage.data(data)
		]);

		events.push("to-client-indication");
		__send(indication.encode(), allocation.clientAddress, allocation.clientPort, now);
	}

	// ------------------------------------------------------------------
	// Methods
	// ------------------------------------------------------------------

	@:noCompletion private function __allocate(key:String, from:String, fromPort:Int, message:StunMessage, now:Float):Void {
		var credential = __authenticate(key, from, fromPort, message, now);

		if (credential == null) {
			return;
		}

		var existing = __allocations.get(key);

		if (existing != null) {
			// A retransmission of the request that made it is answered again;
			// anything else on this 5-tuple is a second allocation, refused.
			if (existing.allocateTransaction != null && __sameTransaction(existing.allocateTransaction, message.transactionId)) {
				events.push("allocate-retransmit");
				__reply(message, StunMessage.ALLOCATE_SUCCESS, existing.successAttributes, credential, from, fromPort, now);
			} else {
				__refuseSigned(message, 437, "Allocation Mismatch", credential, from, fromPort, now);
			}

			return;
		}

		if (allocateError != null) {
			var attributes:Array<StunAttribute> = [StunMessage.errorCode(allocateError.code, allocateError.reason)];

			if (allocateError.alternate != null) {
				attributes.push(FakeTurnRelay.alternateServer(allocateError.alternate.address, allocateError.alternate.port));
			}

			events.push("allocate-error");
			__send(__sign(new StunMessage(StunMessage.ALLOCATE_ERROR, message.transactionId, attributes), credential), from, fromPort, now);
			return;
		}

		var asked:Int = message.uintOf(StunMessage.ATTR_LIFETIME, 600);
		var granted:Int = asked < maxLifetime ? asked : maxLifetime;
		var endpoint = openRelay();

		var allocation = new FakeAllocation(key, from, fromPort, credential.username, endpoint.address, endpoint.port);
		allocation.expires = now + granted;
		allocation.allocateTransaction = message.transactionId;
		allocation.successAttributes = [
			StunMessage.xorRelayed(endpoint.address, endpoint.port),
			StunMessage.xorMappedAddress(from, fromPort),
			StunMessage.lifetime(granted)
		];

		__allocations.set(key, allocation);
		events.push("allocated");
		__reply(message, StunMessage.ALLOCATE_SUCCESS, allocation.successAttributes, credential, from, fromPort, now);
	}

	@:noCompletion private function __refresh(key:String, from:String, fromPort:Int, message:StunMessage, now:Float):Void {
		var credential = __authenticate(key, from, fromPort, message, now);

		if (credential == null) {
			return;
		}

		var allocation = __allocations.get(key);
		var asked:Int = message.uintOf(StunMessage.ATTR_LIFETIME, 600);
		refreshLifetimes.push(asked);

		if (allocation == null || refuseRefresh) {
			__refuseSigned(message, 437, "Allocation Mismatch", credential, from, fromPort, now);
			return;
		}

		if (asked == 0) {
			__allocations.remove(key);
			closeRelay(allocation.relayPort);
			events.push("deallocated");
			__reply(message, StunMessage.REFRESH_SUCCESS, [StunMessage.lifetime(0)], credential, from, fromPort, now);
			return;
		}

		var granted:Int = asked < maxLifetime ? asked : maxLifetime;
		allocation.expires = now + granted;
		events.push("refreshed");
		__reply(message, StunMessage.REFRESH_SUCCESS, [StunMessage.lifetime(granted)], credential, from, fromPort, now);
	}

	@:noCompletion private function __permit(key:String, from:String, fromPort:Int, message:StunMessage, now:Float):Void {
		var credential = __authenticate(key, from, fromPort, message, now);

		if (credential == null) {
			return;
		}

		var allocation = __allocations.get(key);

		if (allocation == null) {
			__refuseSigned(message, 437, "Allocation Mismatch", credential, from, fromPort, now);
			return;
		}

		var peers:Array<ReflexiveAddress> = [];

		for (attribute in message.attributes) {
			if (attribute.type == StunMessage.ATTR_XOR_PEER_ADDRESS) {
				var peer = new StunMessage(StunMessage.CREATE_PERMISSION_REQUEST, message.transactionId, [attribute]).addressOf(StunMessage.ATTR_XOR_PEER_ADDRESS);

				if (peer == null) {
					__refuseSigned(message, 400, "Bad Request", credential, from, fromPort, now);
					return;
				}

				peers.push(peer);
			}
		}

		if (peers.length == 0) {
			__refuseSigned(message, 400, "Bad Request", credential, from, fromPort, now);
			return;
		}

		for (peer in peers) {
			if (denyPeers.indexOf(peer.address) >= 0) {
				events.push("permission-403");
				__refuseSigned(message, 403, "Forbidden IP", credential, from, fromPort, now);
				return;
			}
		}

		for (peer in peers) {
			allocation.permissions.set(peer.address, now + permissionLifetime);
		}

		events.push("permitted");
		__reply(message, StunMessage.CREATE_PERMISSION_SUCCESS, [], credential, from, fromPort, now);

		if (duplicatePermissionSuccess > 0) {
			var again = __sign(new StunMessage(StunMessage.CREATE_PERMISSION_SUCCESS, message.transactionId, []), credential);
			__outbox.push({at: now + delay + duplicatePermissionSuccess, toPeer: false, relayPort: 0, bytes: again, address: from, port: fromPort});
		}
	}

	@:noCompletion private function __bind(key:String, from:String, fromPort:Int, message:StunMessage, now:Float):Void {
		var credential = __authenticate(key, from, fromPort, message, now);

		if (credential == null) {
			return;
		}

		var allocation = __allocations.get(key);

		if (allocation == null) {
			__refuseSigned(message, 437, "Allocation Mismatch", credential, from, fromPort, now);
			return;
		}

		var number:Int = message.uintOf(StunMessage.ATTR_CHANNEL_NUMBER, 0) >>> 16;
		var peer = message.addressOf(StunMessage.ATTR_XOR_PEER_ADDRESS);

		if (peer == null || number < 0x4000 || number > 0x7FFE || refuseChannels) {
			events.push("bind-400");
			__refuseSigned(message, 400, "Bad Request", credential, from, fromPort, now);
			return;
		}

		if (denyPeers.indexOf(peer.address) >= 0) {
			events.push("bind-403");
			__refuseSigned(message, 403, "Forbidden IP", credential, from, fromPort, now);
			return;
		}

		allocation.channels.set(number, new FakeChannel(peer.address, peer.port, now + channelLifetime));
		allocation.permissions.set(peer.address, now + permissionLifetime);
		events.push("channel-bound");
		__reply(message, StunMessage.CHANNEL_BIND_SUCCESS, [], signChannelBind ? credential : null, from, fromPort, now);
	}

	@:noCompletion private function __sendIndication(key:String, message:StunMessage, now:Float):Void {
		var allocation = __allocations.get(key);
		var peer = message.addressOf(StunMessage.ATTR_XOR_PEER_ADDRESS);
		var payload = message.attribute(StunMessage.ATTR_DATA);

		if (allocation == null || peer == null || payload == null) {
			events.push("send-dropped");
			return;
		}

		if (!allocation.permitted(peer.address, now)) {
			events.push("send-unpermitted");
			return;
		}

		events.push("send-relayed");
		var copy = new ByteArray();

		if (payload.length > 0) {
			copy.writeBytes(payload, 0, payload.length);
		}

		copy.position = 0;
		onToPeer(allocation.relayPort, copy, peer.address, peer.port);
	}

	@:noCompletion private function __channelData(key:String, data:ByteArray, now:Float):Void {
		var allocation = __allocations.get(key);
		var number:Int = (data[0] << 8) | data[1];
		var length:Int = (data[2] << 8) | data[3];

		if (allocation == null || 4 + length > data.length) {
			events.push("channeldata-dropped");
			return;
		}

		var channel = allocation.channels.get(number);

		if (channel == null || now >= channel.expires) {
			events.push("channeldata-dropped");
			return;
		}

		var payload = new ByteArray();

		if (length > 0) {
			payload.writeBytes(data, 4, length);
		}

		payload.position = 0;
		events.push("channeldata-relayed");
		onToPeer(allocation.relayPort, payload, channel.address, channel.port);
	}

	// ------------------------------------------------------------------
	// Authentication
	// ------------------------------------------------------------------

	/**
		The credential a request was signed with, or null having answered it
		with the refusal it earned: 401 for none or a wrong one, 400 for a
		signed request missing its username, realm or nonce, 438 for a nonce
		that is not the current one.
	**/
	@:noCompletion private function __authenticate(key:String, from:String, fromPort:Int, message:StunMessage, now:Float):Null<FakeCredential> {
		if (message.attribute(StunMessage.ATTR_MESSAGE_INTEGRITY) == null) {
			__challenge(message, 401, "Unauthorized", key, from, fromPort, now);
			return null;
		}

		var username = message.textOf(StunMessage.ATTR_USERNAME);
		var askedRealm = message.textOf(StunMessage.ATTR_REALM);
		var nonce = message.textOf(StunMessage.ATTR_NONCE);

		if (username == null || askedRealm == null || nonce == null) {
			events.push("refused-400");
			__send(new StunMessage(message.type | 0x0110, message.transactionId, [StunMessage.errorCode(400, "Bad Request")]).encode(), from,
				fromPort, now);
			return null;
		}

		var password = users.get(username);

		if (password == null) {
			__challenge(message, 401, "Unauthorized", key, from, fromPort, now);
			return null;
		}

		var credential = new FakeCredential(username, StunMessage.longTermKey(username, askedRealm, password));

		if (!message.verifyIntegrityWithKey(credential.key)) {
			__challenge(message, 401, "Unauthorized", key, from, fromPort, now);
			return null;
		}

		var current = __nonces.get(key);

		if (always438 || current == null || current.nonce != nonce || (staleNonceAfter > 0 && now - current.issued > staleNonceAfter)) {
			__challenge(message, 438, "Stale Nonce", key, from, fromPort, now);
			return null;
		}

		return credential;
	}

	/**
		A 401 or a 438, with the realm and a nonce. One nonce per 5-tuple until
		it goes stale, as coturn keeps one per session; a 438 always issues a
		new one.
	**/
	@:noCompletion private function __challenge(message:StunMessage, code:Int, reason:String, key:String, from:String, fromPort:Int, now:Float):Void {
		var current = __nonces.get(key);
		var fresh:Bool = code == StunMessage.STALE_NONCE || current == null || (staleNonceAfter > 0 && now - current.issued > staleNonceAfter);

		if (fresh) {
			current = new FakeNonce("nonce-" + (++__nonceCount), now);
			__nonces.set(key, current);
		}

		events.push("refused-" + code);
		__send(new StunMessage(message.type | 0x0110, message.transactionId, [
			StunMessage.errorCode(code, reason),
			StunMessage.text(StunMessage.ATTR_REALM, realm),
			StunMessage.text(StunMessage.ATTR_NONCE, current.nonce)
		]).encode(), from, fromPort, now);
	}

	@:noCompletion private function __refuseSigned(message:StunMessage, code:Int, reason:String, credential:FakeCredential, from:String, fromPort:Int,
			now:Float):Void {
		events.push("refused-" + code);
		__send(__sign(new StunMessage(message.type | 0x0110, message.transactionId, [StunMessage.errorCode(code, reason)]), credential), from, fromPort,
			now);
	}

	@:noCompletion private function __reply(request:StunMessage, type:Int, attributes:Array<StunAttribute>, credential:Null<FakeCredential>, to:String,
			toPort:Int, now:Float):Void {
		var answer = attributes.copy();

		if (unknownAttribute) {
			var value = new ByteArray();
			value.writeInt(0x01020304);
			value.position = 0;
			answer.push(new StunAttribute(0x7FAA, value));
		}

		var message = new StunMessage(type, request.transactionId, answer);
		__send(credential != null ? __sign(message, credential, badIntegrity) : message.encode(), to, toPort, now);
	}

	@:noCompletion private function __sign(message:StunMessage, credential:FakeCredential, corrupt:Bool = false):ByteArray {
		var bytes = message.encodeSignedWithKey(credential.key, false);

		if (corrupt) {
			// The last byte of the integrity value, which is the last byte of
			// the message: signed, but not by anyone who knew the key.
			bytes[bytes.length - 1] = bytes[bytes.length - 1] ^ 0xFF;
		}

		bytes.position = 0;
		return bytes;
	}

	// ------------------------------------------------------------------

	@:noCompletion private function __expire(key:String, now:Float):Void {
		var allocation = __allocations.get(key);

		if (allocation != null && now >= allocation.expires) {
			__allocations.remove(key);
			closeRelay(allocation.relayPort);
			events.push("expired");
		}
	}

	@:noCompletion private function __count(method:String):Void {
		requests.set(method, requestsOf(method) + 1);
	}

	@:noCompletion private function __send(bytes:ByteArray, address:String, port:Int, now:Float):Void {
		if (delay > 0) {
			__outbox.push({at: now + delay, toPeer: false, relayPort: 0, bytes: bytes, address: address, port: port});
			return;
		}

		bytes.position = 0;
		onToClient(bytes, address, port);
	}

	@:noCompletion private function __deliver(item:FakeOutbound):Void {
		item.bytes.position = 0;

		if (item.toPeer) {
			onToPeer(item.relayPort, item.bytes, item.address, item.port);
		} else {
			onToClient(item.bytes, item.address, item.port);
		}
	}

	/** Ninety-six bits nobody chose, for an indication: a counter is enough, since nothing answers one. **/
	@:noCompletion private function __transaction():ByteArray {
		var bytes = new ByteArray();
		__transactionCount++;

		for (i in 0...12) {
			bytes.writeByte((__transactionCount * 31 + i * 7) & 0xFF);
		}

		bytes.position = 0;
		return bytes;
	}

	@:noCompletion private static function __sameTransaction(a:ByteArray, b:ByteArray):Bool {
		if (a == null || b == null || a.length != 12 || b.length != 12) {
			return false;
		}

		for (i in 0...12) {
			if (a[i] != b[i]) {
				return false;
			}
		}

		return true;
	}

	/**
		`ALTERNATE-SERVER`, as RFC 8489 section 14.15 writes it: an address in
		the MAPPED-ADDRESS format, not XORed.
	**/
	public static function alternateServer(address:String, port:Int):StunAttribute {
		var octets = StunMessage.ipv4Octets(address);
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeByte(0);
		value.writeByte(1);
		value.writeShort(port);

		for (octet in octets) {
			value.writeByte(octet);
		}

		value.position = 0;
		return new StunAttribute(0x8023, value);
	}
}

/** Where an allocation relays from. **/
typedef RelayEndpoint = {address:String, port:Int};

/** An Allocate refusal a relay can be told to give. **/
typedef RelayRefusal = {
	code:Int,
	reason:String,
	?alternate:RelayEndpoint
}

/** One client's allocation, as the relay keeps it. **/
class FakeAllocation {
	public var key(default, null):String;
	public var clientAddress(default, null):String;
	public var clientPort(default, null):Int;
	public var username(default, null):String;
	public var relayAddress(default, null):String;
	public var relayPort(default, null):Int;
	public var expires:Float = 0;
	public var allocateTransaction:ByteArray;
	public var successAttributes:Array<StunAttribute>;

	/** Peer address to when its permission lapses. **/
	public var permissions:Map<String, Float> = new Map();

	public var channels:Map<Int, FakeChannel> = new Map();

	public function new(key:String, clientAddress:String, clientPort:Int, username:String, relayAddress:String, relayPort:Int) {
		this.key = key;
		this.clientAddress = clientAddress;
		this.clientPort = clientPort;
		this.username = username;
		this.relayAddress = relayAddress;
		this.relayPort = relayPort;
	}

	public function permitted(peer:String, now:Float):Bool {
		var until = permissions.get(peer);
		return until != null && now < until;
	}

	/** The channel bound to a peer and still live, or 0. **/
	public function channelTo(address:String, port:Int, now:Float):Int {
		for (number in channels.keys()) {
			var channel = channels.get(number);

			if (channel.address == address && channel.port == port && now < channel.expires) {
				return number;
			}
		}

		return 0;
	}
}

class FakeChannel {
	public var address(default, null):String;
	public var port(default, null):Int;
	public var expires:Float;

	public function new(address:String, port:Int, expires:Float) {
		this.address = address;
		this.port = port;
		this.expires = expires;
	}
}

private class FakeNonce {
	public var nonce(default, null):String;
	public var issued(default, null):Float;

	public function new(nonce:String, issued:Float) {
		this.nonce = nonce;
		this.issued = issued;
	}
}

private class FakeCredential {
	public var username(default, null):String;
	public var key(default, null):Bytes;

	public function new(username:String, key:Bytes) {
		this.username = username;
		this.key = key;
	}
}

private typedef FakeOutbound = {
	at:Float,
	toPeer:Bool,
	relayPort:Int,
	bytes:ByteArray,
	address:String,
	port:Int
}
