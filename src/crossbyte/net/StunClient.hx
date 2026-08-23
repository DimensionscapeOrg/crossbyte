package crossbyte.net;

// Needs UDP, which a page has not got. A browser discovers its own reflexive
// address through RTCPeerConnection's ICE gathering instead.
#if !(js && !nodejs)
import crossbyte.Future;
import crossbyte.net._internal.stun.StunMessage;
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

		Discovery needs a UDP socket. Reported rather than assumed, in the same
		way `DatagramSocket` and the reliable sockets report it, so a caller can
		branch instead of finding out from a failed future.
	**/
	public static var isSupported(default, null):Bool = DatagramSocket.isSupported;

	/** The port STUN is registered on, and where public servers listen. */
	public static inline var DEFAULT_PORT:Int = 3478;

	/**
		Asks `server` for this host's reflexive address.

		@param timeoutMs How long to wait before giving up. UDP has no failure
		to report -- a request that reaches nothing looks exactly like one still
		in flight -- so a deadline is the only thing that ends this.
	**/
	public static function discover(server:String, port:Int = DEFAULT_PORT, timeoutMs:Int = 3000):Future<ReflexiveAddress> {
		var future = new Future<ReflexiveAddress>();

		if (server == null || server == "") {
			@:privateAccess future.__fail("A STUN server address is required.", new ArgumentError("server"));
			return future;
		}

		var request:StunMessage = StunMessage.bindingRequest();
		var socket = new DatagramSocket();
		var runtime:CrossByte = CrossByte.current();
		var deadline:Float = Sys.time() + (timeoutMs > 0 ? timeoutMs / 1000 : 3.0);
		var settled:Bool = false;
		var onTick:TickEvent->Void = null;

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

			var response:StunMessage = StunMessage.decode(event.data);

			// Anything can arrive on a bound UDP port. Not a STUN message, or
			// not an answer to the question this client asked, means keep
			// waiting rather than fail -- and refusing a mismatched
			// transaction is what stops somebody handing this peer an address
			// of their choosing.
			if (response == null || !request.matches(response)) {
				return;
			}

			if (response.type == StunMessage.BINDING_ERROR) {
				var reported:String = response.errorMessage();
				finish(null, "The STUN server refused the request" + (reported != null ? ": " + reported : "."));
				return;
			}

			if (response.type != StunMessage.BINDING_SUCCESS) {
				return;
			}

			var address:ReflexiveAddress = response.mappedAddress();

			if (address == null) {
				// A success carrying no address is a server that answered
				// without answering; saying so beats waiting out the deadline.
				finish(null, "The STUN server replied without a mapped address, so this host's public address is still unknown.");
				return;
			}

			finish(address, null);
		});

		onTick = function(_:TickEvent):Void {
			if (!settled && Sys.time() >= deadline) {
				finish(null, "No reply from the STUN server at " + server + ":" + port + " within " + timeoutMs
					+ "ms. UDP reports nothing when it is dropped, so a silent network and a wrong address look the same from here.");
			}
		};

		try {
			socket.bind(0, "0.0.0.0");
			socket.receive();

			var payload:ByteArray = request.encode();
			socket.send(payload, 0, payload.length, server, port);

			runtime.addEventListener(TickEvent.TICK, onTick);
		} catch (e:Dynamic) {
			finish(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e));
		}

		return future;
	}
}
#end
