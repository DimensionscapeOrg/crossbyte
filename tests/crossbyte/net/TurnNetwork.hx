package crossbyte.net;

import crossbyte.io.ByteArray;

/**
	A network standing in memory between `TurnClient`s, `FakeTurnRelay`s and
	whatever peers a test invents, on a clock the test owns.

	Every datagram takes `latency` seconds each way, and time moves in ticks
	the way a runtime moves it: what is due is delivered, then every client is
	polled. So a round trip longer than the first retransmission, a lookup that
	holds datagrams back and lets them go together, or ten minutes of nonce
	rotation all run in a few milliseconds and the same way every time.
**/
class TurnNetwork {
	/** The relay clients are pointed at unless a test says otherwise. **/
	public var relay(default, null):FakeTurnRelay;

	/** The clock every client and relay is given. **/
	public var now:Float = 0;

	/** Seconds each datagram spends in flight, each way. **/
	public var latency:Float = 0.01;

	/** The address the first relay answers from. **/
	public var relayAddress:String = "203.0.113.10";

	public var relayPort:Int = 3478;

	/**
		Names that reach a relay, as a resolver would answer them. A client
		given one sends to it; nothing here answers from it.
	**/
	public var names:Map<String, String> = new Map();

	/**
		Holds everything a client sends until this time, then lets it all go
		together, which is what a native socket does with datagrams to a name
		it is still looking up.
	**/
	public var holdUntil:Float = 0;

	/** Everything the clients sent, in order. **/
	public var sent(default, null):Array<SentDatagram> = [];

	/** What the relays sent on to peers, in order. **/
	public var toPeers(default, null):Array<PeerDatagram> = [];

	/** Called every tick once the clients are polled: an application's own traffic, say. **/
	public dynamic function onTick():Void {}

	/**
		How many bytes at a time a stream client is handed what arrived for it,
		so a message split across reads, and several run together in one, both
		happen; 0 for all of it at once.
	**/
	public var streamChunk:Int = 0;

	@:noCompletion private var __relays:Map<String, FakeTurnRelay> = new Map();
	@:noCompletion private var __clients:Array<NetworkClient> = [];
	@:noCompletion private var __queue:Array<InFlight> = [];
	@:noCompletion private var __nextPort:Int = 50000;

	public function new(?relay:FakeTurnRelay) {
		this.relay = addRelay(relayAddress, relayPort, relay);
	}

	/**
		Another relay, answering from `address`:`port`: somewhere a Try
		Alternate can send a client, or a second relay to fail over to.
	**/
	public function addRelay(address:String, port:Int, ?relay:FakeTurnRelay):FakeTurnRelay {
		var added = relay != null ? relay : new FakeTurnRelay();

		added.onToClient = function(bytes:ByteArray, to:String, toPort:Int):Void {
			__queue.push({
				at: now + latency,
				relay: null,
				bytes: __copy(bytes),
				address: to,
				port: toPort,
				fromAddress: address,
				fromPort: port
			});
		};

		added.onToPeer = function(relayPort:Int, bytes:ByteArray, to:String, toPort:Int):Void {
			toPeers.push({relayPort: relayPort, bytes: __copy(bytes), address: to, port: toPort, at: now});
		};

		__relays.set(address + ":" + port, added);
		return added;
	}

	/**
		A client whose datagrams leave from `clientAddress` and a port of its
		own, pointed at `server` (the first relay's address unless a test
		names something else).

		@param sharePort The port an earlier client used, for one that takes
		over its socket; a new port when 0.
	**/
	public function client(?server:String, username:String = "user", password:String = "secret", clientAddress:String = "192.0.2.10",
			sharePort:Int = 0, ?serverPort:Int, ?transport:TurnTransport):TurnClient {
		var made = new TurnClient(server != null ? server : relayAddress, serverPort != null ? serverPort : relayPort, username, password, transport);
		var port:Int = sharePort > 0 ? sharePort : __nextPort++;

		// A socket delivers to whoever holds it now.
		if (sharePort > 0) {
			for (entry in __clients.copy()) {
				if (entry.port == sharePort && entry.address == clientAddress) {
					__clients.remove(entry);
				}
			}
		}

		__clients.push(new NetworkClient(made, clientAddress, port, transport != null && transport != UDP));

		made.onSend = function(payload:ByteArray, address:String, toPort:Int):Void {
			sent.push({at: now, bytes: __copy(payload), address: address, port: toPort, fromPort: port});

			var target:String = names.exists(address) ? names.get(address) : address;
			var reached = __relays.get(target + ":" + toPort);

			if (reached == null) {
				return;
			}

			var leaves:Float = now < holdUntil ? holdUntil : now;
			__queue.push({
				at: leaves + latency,
				relay: reached,
				bytes: __copy(payload),
				address: clientAddress,
				port: port,
				fromAddress: clientAddress,
				fromPort: port
			});
		};

		return made;
	}

	/** The port a client's datagrams leave from. **/
	public function portOf(client:TurnClient):Int {
		for (entry in __clients) {
			if (entry.client == client) {
				return entry.port;
			}
		}

		return 0;
	}

	/**
		Moves time forward a tick at a time until `done` or `seconds` have
		passed, delivering what is due and polling every client each tick.

		@return Whether `done` came true.
	**/
	public function run(done:Void->Bool, seconds:Float, tick:Float = 1 / 60):Bool {
		var until:Float = now + seconds;

		while (true) {
			__deliverDue();

			if (done()) {
				return true;
			}

			if (now >= until) {
				return false;
			}

			now += tick;

			for (each in __relays) {
				each.flush(now);
			}

			__deliverDue();

			for (entry in __clients) {
				entry.client.poll(now);
			}

			onTick();
		}
	}

	/** Moves time forward by `seconds`, whatever happens. **/
	public function advance(seconds:Float, tick:Float = 1 / 60):Void {
		run(() -> false, seconds, tick);
	}

	/** Hands a client a datagram now, as though `fromAddress` had sent it. **/
	public function inject(client:TurnClient, bytes:ByteArray, fromAddress:String, fromPort:Int):Bool {
		return client.receive(__copy(bytes), fromAddress, fromPort, now);
	}

	/** A peer sends to a relayed address of the first relay; it handles it at once. **/
	public function peerSends(relayPort:Int, text:String, fromAddress:String, fromPort:Int):Void {
		var payload = new ByteArray();
		payload.writeUTFBytes(text);
		payload.position = 0;
		relay.fromPeer(relayPort, payload, fromAddress, fromPort, now);
	}

	/** What a client sent that decodes as `type`, oldest first. **/
	public function sentOfType(type:Int):Array<SentDatagram> {
		var found:Array<SentDatagram> = [];

		for (datagram in sent) {
			var message = crossbyte.net._internal.stun.StunMessage.decode(__copy(datagram.bytes));

			if (message != null && message.type == type) {
				found.push(datagram);
			}
		}

		return found;
	}

	@:noCompletion private function __deliverDue():Void {
		// In time order, and what delivering one causes to be due is delivered
		// in the same pass: a reply with no latency arrives in the tick that
		// provoked it.
		while (true) {
			var index:Int = -1;

			for (i in 0...__queue.length) {
				if (__queue[i].at <= now && (index < 0 || __queue[i].at < __queue[index].at)) {
					index = i;
				}
			}

			if (index < 0) {
				break;
			}

			var item = __queue[index];
			__queue.splice(index, 1);

			if (item.relay != null) {
				item.relay.receive(item.bytes, item.fromAddress, item.fromPort, now);
				item.relay.flush(now);
				continue;
			}

			for (entry in __clients) {
				if (entry.address == item.address && entry.port == item.port) {
					if (entry.stream) {
						entry.pending.position = entry.pending.length;
						entry.pending.writeBytes(item.bytes, 0, item.bytes.length);
					} else {
						entry.client.receive(item.bytes, item.fromAddress, item.fromPort, now);
					}
				}
			}
		}

		// What arrived for a stream client, as a stream: run together, then
		// read in pieces that need not line up with the messages.
		for (entry in __clients) {
			if (!entry.stream || entry.pending.length == 0) {
				continue;
			}

			var bytes = entry.pending;
			entry.pending = new ByteArray();
			var at:Int = 0;

			while (at < bytes.length) {
				var size:Int = streamChunk > 0 && bytes.length - at > streamChunk ? streamChunk : bytes.length - at;
				var piece = new ByteArray();
				piece.writeBytes(bytes, at, size);
				piece.position = 0;
				at += size;
				entry.client.receiveStream(piece, now);
			}
		}
	}

	@:noCompletion private static function __copy(bytes:ByteArray):ByteArray {
		var copy = new ByteArray();

		if (bytes.length > 0) {
			copy.writeBytes(bytes, 0, bytes.length);
		}

		copy.position = 0;
		return copy;
	}
}

typedef SentDatagram = {
	at:Float,
	bytes:ByteArray,
	address:String,
	port:Int,
	fromPort:Int
}

typedef PeerDatagram = {
	relayPort:Int,
	bytes:ByteArray,
	address:String,
	port:Int,
	at:Float
}

/** A client on the network: where it sends from, and for one on a stream, what has arrived and not been read. **/
private class NetworkClient {
	public var client(default, null):TurnClient;
	public var address(default, null):String;
	public var port(default, null):Int;
	public var stream(default, null):Bool;
	public var pending:ByteArray = new ByteArray();

	public function new(client:TurnClient, address:String, port:Int, stream:Bool) {
		this.client = client;
		this.address = address;
		this.port = port;
		this.stream = stream;
	}
}

private typedef InFlight = {
	at:Float,

	/** The relay it is for, or null for a datagram to a client. **/
	relay:Null<FakeTurnRelay>,

	bytes:ByteArray,
	address:String,
	port:Int,
	fromAddress:String,
	fromPort:Int
}
