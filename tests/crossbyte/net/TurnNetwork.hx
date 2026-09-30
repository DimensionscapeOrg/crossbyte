package crossbyte.net;

import crossbyte.io.ByteArray;

/**
	A network standing in memory between `TurnClient`s, a `FakeTurnRelay` and
	whatever peers a test invents, on a clock the test owns.

	Every datagram takes `latency` seconds each way, and time moves in ticks
	the way a runtime moves it: what is due is delivered, then every client is
	polled. So a round trip longer than the first retransmission, a lookup that
	holds datagrams back and lets them go together, or ten minutes of nonce
	rotation all run in a few milliseconds and the same way every time.
**/
class TurnNetwork {
	public var relay(default, null):FakeTurnRelay;

	/** The clock every client and the relay are given. **/
	public var now:Float = 0;

	/** Seconds each datagram spends in flight, each way. **/
	public var latency:Float = 0.01;

	/** The address the relay answers from. **/
	public var relayAddress:String = "203.0.113.10";

	public var relayPort:Int = 3478;

	/**
		Names that reach the relay, as a resolver would answer them. A client
		given one sends to it; nothing here answers from it.
	**/
	public var names:Map<String, String> = new Map();

	/**
		Holds everything a client sends until this time, then lets it all go
		together -- which is what a native socket does with datagrams to a name
		it is still looking up.
	**/
	public var holdUntil:Float = 0;

	/** Everything the clients sent, in order. **/
	public var sent(default, null):Array<SentDatagram> = [];

	/** What the relay sent on to peers, in order. **/
	public var toPeers(default, null):Array<PeerDatagram> = [];

	@:noCompletion private var __clients:Array<{client:TurnClient, address:String, port:Int}> = [];
	@:noCompletion private var __queue:Array<InFlight> = [];
	@:noCompletion private var __nextPort:Int = 50000;

	public function new(?relay:FakeTurnRelay) {
		this.relay = relay != null ? relay : new FakeTurnRelay();

		this.relay.onToClient = function(bytes:ByteArray, address:String, port:Int):Void {
			__queue.push({at: now + latency, toRelay: false, bytes: __copy(bytes), address: address, port: port, fromAddress: relayAddress, fromPort: relayPort});
		};

		this.relay.onToPeer = function(relayPort:Int, bytes:ByteArray, address:String, port:Int):Void {
			toPeers.push({relayPort: relayPort, bytes: __copy(bytes), address: address, port: port, at: now});
		};
	}

	/**
		A client whose datagrams leave from `clientAddress` and a port of its
		own, pointed at `server` -- the relay's address unless a test names
		something else.
	**/
	public function client(?server:String, username:String = "user", password:String = "secret", clientAddress:String = "192.0.2.10"):TurnClient {
		var made = new TurnClient(server != null ? server : relayAddress, relayPort, username, password);
		var port:Int = __nextPort++;
		__clients.push({client: made, address: clientAddress, port: port});

		made.onSend = function(payload:ByteArray, address:String, toPort:Int):Void {
			sent.push({at: now, bytes: __copy(payload), address: address, port: toPort, fromPort: port});

			var target:String = names.exists(address) ? names.get(address) : address;

			if (target != relayAddress || toPort != relayPort) {
				return;
			}

			var leaves:Float = now < holdUntil ? holdUntil : now;
			__queue.push({at: leaves + latency, toRelay: true, bytes: __copy(payload), address: clientAddress, port: port, fromAddress: clientAddress, fromPort: port});
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
			relay.flush(now);
			__deliverDue();

			for (entry in __clients) {
				entry.client.poll(now);
			}
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

	/** A peer sends to a relayed address; the relay handles it at once. **/
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
				return;
			}

			var item = __queue[index];
			__queue.splice(index, 1);

			if (item.toRelay) {
				relay.receive(item.bytes, item.fromAddress, item.fromPort, now);
				relay.flush(now);
				continue;
			}

			for (entry in __clients) {
				if (entry.address == item.address && entry.port == item.port) {
					entry.client.receive(item.bytes, item.fromAddress, item.fromPort, now);
				}
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

private typedef InFlight = {
	at:Float,
	toRelay:Bool,
	bytes:ByteArray,
	address:String,
	port:Int,
	fromAddress:String,
	fromPort:Int
}
