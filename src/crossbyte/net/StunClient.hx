package crossbyte.net;

// Needs UDP, which a page has not got. A browser discovers its own reflexive
// address through RTCPeerConnection's ICE gathering instead.
#if !(js && !nodejs)
import crossbyte.Future;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunQuery;
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;

/**
	Asks a STUN server what address it sees this socket as.

	A peer behind NAT cannot answer that locally. `localAddress` is the private
	side of the mapping, and the address a peer must publish for others to dial
	is the public side -- which only something outside the NAT can report. That
	is the whole of what STUN does here, and it is the first thing any
	peer-to-peer transport needs: without it a peer can only advertise an
	address nobody else can reach.

	```haxe
	StunClient.discover("stun.l.google.com", 19302).then(function(address) {
		trace("the world sees " + address.address + ":" + address.port);
	}, function(error) {
		trace("could not find out: " + error);
	});
	```

	## Asking about a port you are already using

	This binds a socket of its own, so it answers for a port nothing else
	holds. That is the general question and it is the one most callers want.

	It is not the question a peer-to-peer mesh asks. A NAT keeps one mapping
	per socket, so what matters there is how the *listening* port appears --
	and that port is held by the listener, which no second socket can bind.
	`ReliableDatagramServerSocket.discoverPublicAddress` asks through the
	socket that already owns it, and is the right call for that case.
**/
class StunClient {
	/**
		Whether this target can ask at all.

		Discovery needs a UDP socket, and it needs a cryptographically secure
		source for the transaction id -- both, not either. The id is what a
		reply is believed by, so it is the whole of what stops an off-path
		party who can guess it from handing this host an address of its
		choosing; drawn from a weak generator it would still look random and
		defend nothing. HashLink, python and lua have UDP and no CSPRNG, and
		this flag used to say `true` there while the first thing `discover`
		did threw -- a flag that lies leaves a caller no other path to take,
		which is the one thing a support flag exists to prevent.
	**/
	public static var isSupported(default, null):Bool = DatagramSocket.isSupported && crossbyte.crypto.SecureRandom.isSupported;

	/** The port STUN is registered on, and where public servers listen. */
	public static inline var DEFAULT_PORT:Int = 3478;

	/**
		Asks `server` for this host's reflexive address.

		The request is repeated on RFC 5389's schedule until the deadline, each
		gap twice the last -- see `StunQuery`, which owns the schedule and the
		reading of a reply for all three places here that ask this question.

		@param timeoutMs How long to keep asking before giving up. UDP has no
		failure to report -- a request that reaches nothing looks exactly like
		one still in flight -- so a deadline is the only thing that ends this.
	**/
	public static function discover(server:String, port:Int = DEFAULT_PORT, timeoutMs:Int = 3000):Future<ReflexiveAddress> {
		var future = new Future<ReflexiveAddress>();

		if (server == null || server == "") {
			@:privateAccess future.__fail("A STUN server address is required.", new ArgumentError("server"));
			return future;
		}

		// Before anything is built: a caller that skipped the flag gets the
		// same failed future a checked caller would branch around, rather than
		// a throw from the first line that needed the CSPRNG.
		if (!isSupported) {
			@:privateAccess future.__fail("STUN discovery is not available here: it needs a UDP socket and a cryptographically secure "
				+ "random source for the transaction id, and this target lacks at least one. Check StunClient.isSupported.",
				null);
			return future;
		}

		var query = new StunQuery(haxe.Timer.stamp(), timeoutMs);
		var socket = new DatagramSocket();
		var runtime:CrossByte = CrossByte.current();
		var settled:Bool = false;
		var onTick:TickEvent->Void = null;
		var ask:Void->Void = null;

		function finish(address:Null<ReflexiveAddress>, error:String):Void {
			if (settled) {
				return;
			}

			settled = true;

			if (onTick != null) {
				runtime.removeEventListener(TickEvent.TICK, onTick);
			}

			try {
				socket.close();
			} catch (_:Dynamic) {}

			if (address != null) {
				@:privateAccess future.__resolve(address);
			} else {
				@:privateAccess future.__fail(error, null);
			}
		}

		socket.addEventListener(DatagramSocketDataEvent.DATA, function(event:DatagramSocketDataEvent):Void {
			if (settled) {
				return;
			}

			// Anything at all can arrive on a bound UDP port, so a datagram
			// that is not an answer to this question leaves it waiting rather
			// than failing it.
			switch (query.interpret(event.data)) {
				case NOT_OURS:
				case ANSWERED(address):
					finish(address, null);
				case REFUSED(reason):
					finish(null, "The STUN server refused the request" + (reason != null ? ": " + reason : "."));
				case ANSWERED_WITHOUT_ADDRESS:
					finish(null, "The STUN server replied without a mapped address, so this host's public address is still unknown.");
			}
		});

		ask = function():Void {
			var payload:ByteArray = query.request.encode();
			socket.send(payload, 0, payload.length, server, port);
		};

		onTick = function(_:TickEvent):Void {
			if (settled) {
				return;
			}

			var now:Float = haxe.Timer.stamp();

			if (query.expired(now)) {
				finish(null, "No reply from the STUN server at " + server + ":" + port + " within " + timeoutMs
					+ "ms. UDP reports nothing when it is dropped, so a silent network and a wrong address look the same from here.");
				return;
			}

			if (query.shouldRetransmit(now)) {
				try {
					ask();
				} catch (e:Dynamic) {
					finish(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e));
				}
			}
		};

		try {
			socket.bind(0, "0.0.0.0");
			socket.receive();

			ask();
			runtime.addEventListener(TickEvent.TICK, onTick);
		} catch (e:Dynamic) {
			finish(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e));
		}

		return future;
	}
}
#end
