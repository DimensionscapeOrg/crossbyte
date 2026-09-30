package crossbyte.net.rtc;

// A UDP socket, like PeerConnection: a page has RTCPeerConnection instead.
#if !(js && !nodejs)
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.DatagramSocket;
import crossbyte.net.ice.IceCandidate;
import crossbyte.net.ice.IceCredentials;
import crossbyte.net._internal.stun.StunMessage;
import haxe.ds.ObjectMap;

/**
	Many peer connections on one UDP port, driven by one tick.

	A `PeerConnection` that binds a socket of its own costs a port, that
	socket's buffers and a tick listener, for as long as it lives. A server
	holding ten thousand browser peers held ten thousand of each, and had to
	open a port range as wide as its peak to reach them through a firewall.
	Connections made here share this host's socket and its one tick instead:
	one port to open, one socket, one listener however many peers there are.

	```haxe
	var host = new PeerConnectionHost();
	host.bind(5000, "0.0.0.0");
	host.addLocalCandidate(IceCandidate.host(publicAddress, host.localPort));

	signalling.onOffer = function(offer) {
		var connection = host.createConnection(false);
		connection.connect(offer);
		signalling.answer(connection.description());
	};
	```

	## How a datagram finds its connection

	A connectivity check names its connection: its USERNAME begins with the
	receiving side's ufrag, and each connection here has its own. An answer to
	a check this side sent carries that check's transaction id, which is
	remembered as it goes out. A DTLS record carries nothing of the kind, and
	goes by the address it came from -- to the connection that has proved a
	path to that address, and to no other.

	That last rule is the one that matters. A peer's candidates are its to
	choose, and one that listed another peer's address as its own would, if
	sending there were enough to claim it, take that peer's records and break
	its connection. Proving a path is not something a peer can do for an
	address that is not its own: the check has to be answered from there, and
	signed with this connection's credentials.

	## What a shared socket does not do

	Relaying and asking a STUN server. Both belong to one socket's mapping,
	and here that mapping is every connection's: `gatherReflexive` and
	`gatherRelayed` refuse on a connection made here. A server with a public
	address -- what this is for -- needs neither; give that address to
	`addLocalCandidate`, and every connection offers it.

	The socket also reads at most 64 datagrams each time the runtime services
	it, which the DEFAULT main loop does once a tick: shared, that is a limit
	on every connection together. Run the host on a runtime with the POLL main
	loop, which services sockets as often as datagrams arrive.
**/
class PeerConnectionHost {
	/**
		Transactions remembered per connection, oldest forgotten first.

		A check that is answered is forgotten as the answer arrives; this bounds
		the ones that never are -- checks to a candidate nothing answers from --
		which a peer listing many such candidates could otherwise pile up.
	**/
	@:noCompletion private static inline var MAX_TRANSACTIONS:Int = 256;

	/** Addresses one connection may hold at once: its path, and the few it moved from. **/
	@:noCompletion private static inline var MAX_ADDRESSES:Int = 8;

	/** The port every connection on this host is reached at, once bound. **/
	public var localPort(get, never):Int;

	/** How many connections are open on this host. **/
	public var connectionCount(get, never):Int;

	@:noCompletion private var __socket:DatagramSocket;
	@:noCompletion private var __tick:TickEvent->Void;
	@:noCompletion private var __closed:Bool = false;
	@:noCompletion private var __connections:Array<PeerConnection> = [];
	@:noCompletion private var __candidates:Array<IceCandidate> = [];
	@:noCompletion private var __byFragment:Map<String, PeerConnection> = new Map();
	@:noCompletion private var __byTransaction:Map<String, PeerConnection> = new Map();
	@:noCompletion private var __byAddress:Map<String, PeerConnection> = new Map();
	@:noCompletion private var __routes:ObjectMap<PeerConnection, HostedRoutes> = new ObjectMap();

	public function new() {
		if (!PeerConnection.isSupported) {
			throw new ArgumentError("A peer connection host cannot run on this target: it needs what PeerConnection needs. Check PeerConnection.isSupported.");
		}
	}

	/**
		Opens the socket every connection here will share, and starts the one
		tick that drives them.

		@param localAddress Binding to a concrete address also makes it a host
		candidate of every connection. A wildcard bind names no address; give
		the one peers should dial to `addLocalCandidate`.
	**/
	public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		if (__closed) {
			throw new ArgumentError("This host has been closed.");
		}

		if (__socket != null) {
			return;
		}

		__socket = new DatagramSocket();
		__socket.bind(localPort, localAddress);
		__socket.addEventListener(DatagramSocketDataEvent.DATA, __onDatagram);
		__socket.receive();

		var bound:String = __socket.localAddress;

		if (bound != null && bound.length > 0 && bound != "0.0.0.0" && bound != "::") {
			addLocalCandidate(IceCandidate.host(bound, __socket.localPort));
		}

		__tick = function(_:TickEvent):Void {
			poll(haxe.Timer.stamp());
		};

		CrossByte.current().addEventListener(TickEvent.TICK, __tick);
	}

	/**
		Adds an address every connection here can be reached at: this host's
		public address, typically, which a wildcard bind cannot know.

		Connections already open offer it too, from now on.
	**/
	public function addLocalCandidate(candidate:IceCandidate):Void {
		if (candidate == null) {
			throw new ArgumentError("A candidate is required.");
		}

		__candidates.push(candidate);

		for (connection in __connections) {
			connection.addLocalCandidate(candidate);
		}
	}

	/**
		A new connection on this host's socket, used as one that bound its own
		would be -- without `bind`.

		@param credentials Its ICE credentials, generated when omitted. Their
		username fragment is what the peer's checks are routed by, so it has to
		be unique on this host; a generated one is, and one passed in that is
		already taken is refused.
		@throws ArgumentError Before `bind`, after `close`, or given credentials
		whose fragment another connection here already has.
	**/
	public function createConnection(isOfferer:Bool, ?certificate:DtlsCertificate, ?credentials:IceCredentials):PeerConnection {
		if (__closed || __socket == null) {
			throw new ArgumentError(__closed ? "This host has been closed." : "Bind the host before creating connections on it.");
		}

		if (credentials == null) {
			do {
				credentials = IceCredentials.generate();
			} while (__byFragment.exists(credentials.usernameFragment));
		} else if (__byFragment.exists(credentials.usernameFragment)) {
			throw new ArgumentError("Another connection on this host already has the username fragment \""
				+ credentials.usernameFragment + "\", and checks are routed by it.");
		}

		var connection = new PeerConnection(isOfferer, certificate, credentials);
		var routes = new HostedRoutes();
		__connections.push(connection);
		__byFragment.set(credentials.usernameFragment, connection);
		routes.fragments.push(credentials.usernameFragment);
		__routes.set(connection, routes);

		@:privateAccess connection.__attach(this);

		for (candidate in __candidates) {
			connection.addLocalCandidate(candidate);
		}

		return connection;
	}

	/**
		Moves every connection forward. Driven from the runtime tick once
		bound; public so a test can drive it with a clock of its own.
	**/
	public function poll(now:Float):Void {
		// Backwards, so a connection that closes during its own poll -- and
		// leaves the list -- does not make the next one be skipped.
		var i:Int = __connections.length - 1;

		while (i >= 0) {
			if (i < __connections.length) {
				__connections[i].poll(now);
			}

			i--;
		}
	}

	/** Closes every connection here, telling each peer, and then the socket. **/
	public function close():Void {
		if (__closed) {
			return;
		}

		__closed = true;

		for (connection in __connections.copy()) {
			connection.close();
		}

		if (__tick != null) {
			try {
				CrossByte.current().removeEventListener(TickEvent.TICK, __tick);
			} catch (_:Dynamic) {}

			__tick = null;
		}

		if (__socket != null) {
			try {
				__socket.close();
			} catch (_:Dynamic) {}

			__socket = null;
		}
	}

	@:noCompletion private function get_localPort():Int {
		return __socket != null ? __socket.localPort : 0;
	}

	@:noCompletion private function get_connectionCount():Int {
		return __connections.length;
	}

	// ------------------------------------------------------------------
	// For the connections sharing the socket
	// ------------------------------------------------------------------

	/** Out through the shared socket. **/
	@:noCompletion private function __send(payload:ByteArray, address:String, port:Int):Void {
		if (__socket == null) {
			return;
		}

		try {
			__socket.send(payload, 0, payload.length, address, port);
		} catch (_:Dynamic) {
			// As for a connection's own socket: an address that cannot be
			// reached is an ordinary outcome of trying every candidate.
		}
	}

	/**
		A connection's ICE agent is sending: a check's transaction is
		remembered, so its answer comes back to this connection.
	**/
	@:noCompletion private function __sending(connection:PeerConnection, payload:ByteArray):Void {
		if (payload.length < StunMessage.HEADER_LENGTH || !__isRequest(payload)) {
			return;
		}

		var key = __transaction(payload);

		if (__byTransaction.exists(key)) {
			// A retransmission, already remembered.
			return;
		}

		var routes = __routes.get(connection);

		if (routes == null) {
			return;
		}

		__byTransaction.set(key, connection);
		routes.transactions.push(key);

		if (routes.transactions.length > MAX_TRANSACTIONS) {
			var oldest = routes.transactions.shift();

			if (__byTransaction.get(oldest) == connection) {
				__byTransaction.remove(oldest);
			}
		}
	}

	/**
		A connection proved a path to this address, so what arrives from it is
		that connection's -- whoever else has sent there.
	**/
	@:noCompletion private function __proved(connection:PeerConnection, address:String, port:Int):Void {
		var routes = __routes.get(connection);

		if (routes == null) {
			return;
		}

		var key = address + " " + port;
		var previous = __byAddress.get(key);

		if (previous == connection) {
			return;
		}

		if (previous != null) {
			var theirs = __routes.get(previous);

			if (theirs != null) {
				theirs.addresses.remove(key);
			}
		}

		__byAddress.set(key, connection);
		routes.addresses.push(key);

		if (routes.addresses.length > MAX_ADDRESSES) {
			var oldest = routes.addresses.shift();

			if (__byAddress.get(oldest) == connection) {
				__byAddress.remove(oldest);
			}
		}
	}

	/**
		Credentials for a connection's ICE restart, with a ufrag no connection
		here has, routed to it alongside the one it had until the restart is
		done -- checks for the old session still arrive meanwhile.
	**/
	@:noCompletion private function __freshCredentials(connection:PeerConnection):IceCredentials {
		var credentials:IceCredentials;

		do {
			credentials = IceCredentials.generate();
		} while (__byFragment.exists(credentials.usernameFragment));

		var routes = __routes.get(connection);

		if (routes != null) {
			__byFragment.set(credentials.usernameFragment, connection);
			routes.fragments.push(credentials.usernameFragment);
		}

		return credentials;
	}

	/** A connection's ICE restart is done, and checks naming its old ufrag are no longer its. **/
	@:noCompletion private function __retire(connection:PeerConnection, fragment:String):Void {
		if (__byFragment.get(fragment) == connection) {
			__byFragment.remove(fragment);
		}

		var routes = __routes.get(connection);

		if (routes != null) {
			routes.fragments.remove(fragment);
		}
	}

	/** A connection has closed: everything routed to it is forgotten. **/
	@:noCompletion private function __detach(connection:PeerConnection):Void {
		__connections.remove(connection);

		var routes = __routes.get(connection);
		__routes.remove(connection);

		if (routes == null) {
			return;
		}

		for (fragment in routes.fragments) {
			if (__byFragment.get(fragment) == connection) {
				__byFragment.remove(fragment);
			}
		}

		for (key in routes.transactions) {
			if (__byTransaction.get(key) == connection) {
				__byTransaction.remove(key);
			}
		}

		for (key in routes.addresses) {
			if (__byAddress.get(key) == connection) {
				__byAddress.remove(key);
			}
		}
	}

	// ------------------------------------------------------------------
	// Routing
	// ------------------------------------------------------------------

	@:noCompletion private function __onDatagram(e:DatagramSocketDataEvent):Void {
		var data = e.data;

		if (__closed || data == null || data.length == 0) {
			return;
		}

		data.position = 0;
		var first:Int = data.readUnsignedByte();
		data.position = 0;

		var target:PeerConnection = null;
		__routedMessage = null;

		// RFC 7983's first-byte ranges, as a connection with its own socket
		// reads them: under 4 is STUN, 20 to 63 DTLS. Nothing else is carried
		// here -- no relay -- so anything else is noise.
		if (first < 4) {
			target = __stunTarget(data);
		} else if (first >= 20 && first <= 63) {
			target = __byAddress.get(e.srcAddress + " " + e.srcPort);
		}

		if (target != null) {
			data.position = 0;

			// With the check as decoded for routing, so the connection does not
			// decode it again.
			var decoded = __routedMessage;
			__routedMessage = null;
			@:privateAccess target.__receiveDatagram(data, e.srcAddress, e.srcPort, decoded);
		}
	}

	/** The check `__stunTarget` decoded to route, handed on with it; null for anything routed without decoding. **/
	@:noCompletion private var __routedMessage:Null<StunMessage> = null;

	/** A check by the ufrag it is addressed to; an answer by the transaction it answers. **/
	@:noCompletion private function __stunTarget(data:ByteArray):Null<PeerConnection> {
		if (data.length < StunMessage.HEADER_LENGTH) {
			return null;
		}

		if (__isRequest(data)) {
			var message = StunMessage.decode(data);

			if (message == null) {
				return null;
			}

			__routedMessage = message;
			var fragment = IceCredentials.receiverFragment(message.textOf(StunMessage.ATTR_USERNAME));
			return fragment != null ? __byFragment.get(fragment) : null;
		}

		// Answered once: a second answer to a retransmitted check finds nothing
		// here, which the agent would have ignored anyway.
		var key = __transaction(data);
		var connection = __byTransaction.get(key);

		if (connection != null) {
			__byTransaction.remove(key);
		}

		return connection;
	}

	/** A STUN request, rather than an answer or an indication: both class bits clear. **/
	@:noCompletion private static function __isRequest(data:ByteArray):Bool {
		data.endian = Endian.BIG_ENDIAN;
		data.position = 0;
		var type:Int = data.readUnsignedShort();
		data.position = 0;
		return (type & 0x0110) == 0;
	}

	/** The ninety-six bit transaction id, as a key. **/
	@:noCompletion private static function __transaction(data:ByteArray):String {
		data.endian = Endian.BIG_ENDIAN;
		data.position = 8;
		var key = data.readInt() + " " + data.readInt() + " " + data.readInt();
		data.position = 0;
		return key;
	}
}

/** What the host routes to one connection, kept so it can all be forgotten when the connection closes. **/
private class HostedRoutes {
	/** Its ufrag, and during an ICE restart the new one beside it. **/
	public var fragments:Array<String> = [];

	public var transactions:Array<String> = [];
	public var addresses:Array<String> = [];

	public function new() {}
}
#end
