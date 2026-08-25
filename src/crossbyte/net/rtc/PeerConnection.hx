package crossbyte.net.rtc;

// Owns a UDP socket, which a page has not got: a browser's peer connection is
// `RTCPeerConnection`, and this is the other end of it.
#if !(js && !nodejs)
import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;
import crossbyte.net.ice.IceAgent;
import crossbyte.net.ice.IceCandidate;
import crossbyte.net.ice.IceCandidatePair;
import crossbyte.net.ice.IceCredentials;
import crossbyte.net.rtc.PeerDescription;
import crossbyte.net.rtc._internal.sctp.SctpAssociation;
import crossbyte.net.rtc._internal.sctp.SctpDataTransfer;

/**
	A connection to one peer: found by ICE, encrypted by DTLS, carried by SCTP,
	spoken through data channels.

	Every layer below this was built without a socket so that they could all
	share one. This is the class that owns that socket and does the sharing:
	connectivity checks, encrypted records and everything inside them travel
	over a single UDP port, told apart by RFC 7983's rule -- a first byte under
	4 is STUN and one from 20 to 63 is DTLS -- which exists precisely so that
	one port can carry all of it.

	```haxe
	var connection = new PeerConnection(controlling);
	connection.bind(0, "0.0.0.0");

	// `description()` goes to the peer over whatever channel the application
	// already has; the peer's comes back the same way.
	signalling.send(connection.description());
	signalling.onDescription = remote -> connection.connect(remote);

	connection.ready.then(function(_) {
		var chat = connection.createDataChannel("chat");
		chat.opened.then(_ -> chat.send("hello"));
	});
	```

	## One clock

	Every layer here takes time from its caller, and this class is the caller:
	it drives all of them from `haxe.Timer.stamp()` on the runtime tick. That is
	not bookkeeping trivia. The layers schedule retransmissions against the
	timestamps they were handed, so two layers fed from clocks with different
	epochs would disagree about how old every unacknowledged packet is -- one
	retransmitting everything instantly, the other never -- and nothing would
	name the cause.

	## Who is what

	One peer is constructed `controlling` and the other not, decided by the
	application (conventionally, whoever initiates). Everything else follows
	from that one bit: the controlling peer nominates the ICE pair, opens the
	DTLS handshake as its client, opens the SCTP association, and takes the even
	data channel streams. Passing the same value on both sides produces two
	peers that each wait politely for the other, forever.

	## Native only

	DTLS needs mbedTLS, which hxcpp links and the other targets do not have.
	`isSupported` says so. A browser peer is `RTCPeerConnection`; this class is
	what it talks to.
**/
class PeerConnection {
	/**
		Whether a peer connection can run here.

		The strictest of its parts' requirements: a UDP socket to own, a CSPRNG
		for ICE, and mbedTLS for DTLS -- which in practice means cpp.
	**/
	public static var isSupported(default, null):Bool = DatagramSocket.isSupported && IceAgent.isSupported && DtlsTransport.isSupported;

	/** Whether this peer nominates, dials, associates, and takes even streams. **/
	public var controlling(default, null):Bool;

	/** This peer's certificate. Its fingerprint is in `description()`. **/
	public var certificate(default, null):DtlsCertificate;

	/** This peer's ICE credentials. The public half is in `description()`. **/
	public var credentials(default, null):IceCredentials;

	/** The agent finding the path. Exposed for reflexive gathering and inspection. **/
	public var agent(default, null):IceAgent;

	/** Whether the whole stack is up: path found, session encrypted, association open. **/
	public var connected(default, null):Bool = false;

	/**
		Resolves when data channels can be created, or fails when any layer
		cannot get there -- no path, a certificate that is not the one the peer
		signalled, an association nobody answered.
	**/
	public var ready(default, null):Future<PeerConnection>;

	/** Called when the peer opens a channel rather than answering one. **/
	public dynamic function onChannel(channel:DataChannel):Void {}

	@:noCompletion private var __socket:DatagramSocket;
	@:noCompletion private var __dtls:DtlsTransport;
	@:noCompletion private var __association:SctpAssociation;
	@:noCompletion private var __transfer:SctpDataTransfer;
	@:noCompletion private var __channels:DataChannelSet;
	@:noCompletion private var __localCandidates:Array<IceCandidate> = [];
	@:noCompletion private var __remote:PeerDescription;
	@:noCompletion private var __peerAddress:String;
	@:noCompletion private var __peerPort:Int;
	@:noCompletion private var __tick:TickEvent->Void;
	@:noCompletion private var __closed:Bool = false;

	/**
		@param controlling Whether this peer drives the connection. The two
		peers must pass opposite values.
		@param certificate An existing identity to present, generated when
		omitted -- which is the normal case, a certificate here only having to
		outlive the session.
	**/
	public function new(controlling:Bool, ?certificate:DtlsCertificate, ?credentials:IceCredentials) {
		if (!isSupported) {
			throw new ArgumentError("A peer connection cannot run on this target: it needs a UDP socket, a CSPRNG and mbedTLS, and one of them is missing here. Check PeerConnection.isSupported. In a browser, use RTCPeerConnection -- this class is what it talks to.");
		}

		this.controlling = controlling;
		this.certificate = certificate != null ? certificate : DtlsCertificate.generate();
		this.credentials = credentials != null ? credentials : IceCredentials.generate();
		this.ready = new Future<PeerConnection>();

		agent = new IceAgent(controlling, this.credentials);
		agent.connected.then(pair -> __onPathFound(pair), error -> __fail("No path to the peer was found: " + error));

		// A role conflict makes the agent change sides, and everything above it
		// keys off the same bit: who is the DTLS client, who opens the
		// association, who takes the even streams. A connection that kept its
		// original answer would have both peers claiming the same half of each
		// of those, each waiting for the other. The conflict resolves during
		// checking, so this lands before any of them have started.
		agent.onRoleChanged = function(nowControlling:Bool):Void {
			controlling = nowControlling;
		};
	}

	/**
		Opens the socket everything will share, and starts the clock.

		@param localAddress Binding to a concrete address also records it as a
		host candidate. A wildcard bind does not -- `0.0.0.0` names every
		interface and so names none -- and a caller behind one should gather
		with `LocalAddress` and `addLocalCandidate`, or through the agent's
		reflexive discovery.
	**/
	public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		if (__closed || __socket != null) {
			return;
		}

		__socket = new DatagramSocket();
		__socket.bind(localPort, localAddress);
		__socket.addEventListener(DatagramSocketDataEvent.DATA, __onDatagram);
		__socket.receive();

		agent.onSend = function(payload:ByteArray, address:String, port:Int):Void {
			__send(payload, address, port);
		};

		var bound:String = __socket.localAddress;

		if (bound != null && bound.length > 0 && bound != "0.0.0.0" && bound != "::") {
			addLocalCandidate(IceCandidate.host(bound, __socket.localPort));
		}

		__tick = function(_:TickEvent):Void {
			poll(haxe.Timer.stamp());
		};

		CrossByte.current().addEventListener(TickEvent.TICK, __tick);
	}

	/** The port peers dial, once bound. **/
	public var localPort(get, never):Int;

	@:noCompletion private function get_localPort():Int {
		return __socket != null ? __socket.localPort : 0;
	}

	/**
		Adds an address this peer can be reached at.

		`bind` adds the socket's own when it names one; reflexive and relayed
		candidates arrive here from whatever gathered them.
	**/
	public function addLocalCandidate(candidate:IceCandidate):Void {
		__localCandidates.push(candidate);
		agent.addLocalCandidate(candidate);
	}

	/**
		Everything the peer needs to reach this connection.

		Sent over the application's own signalling channel -- the one part of
		WebRTC that is deliberately not CrossByte's to carry.
	**/
	public function description():PeerDescription {
		var candidates:Array<CandidateDescription> = [];

		for (candidate in __localCandidates) {
			candidates.push({
				address: candidate.address,
				port: candidate.port,
				type: (candidate.type : String),
				priority: candidate.priority
			});
		}

		return {
			usernameFragment: credentials.usernameFragment,
			password: credentials.password,
			fingerprint: certificate.fingerprint,
			candidates: candidates
		};
	}

	/**
		Takes the peer's description and starts connecting.

		@throws ArgumentError if the description carries no fingerprint. Without
		one the DTLS handshake would accept whoever answered, which is an
		encrypted session with an attacker rather than with the peer -- so a
		connection without it is refused at the door rather than half-built.
	**/
	public function connect(remote:PeerDescription):Void {
		if (__closed || remote == null) {
			throw new ArgumentError("A peer description is required.");
		}

		if (__socket == null) {
			throw new ArgumentError("Bind before connecting: the checks have to leave from the socket the peer will be told about.");
		}

		if (remote.fingerprint == null || remote.fingerprint.length == 0) {
			throw new ArgumentError("The peer's description carries no certificate fingerprint. Without one the handshake would accept any certificate at all, so this connection is refused rather than left unauthenticated.");
		}

		__remote = remote;

		for (candidate in remote.candidates) {
			agent.addRemoteCandidate(new IceCandidate((candidate.type : String), candidate.address, candidate.port, 1, candidate.priority));
		}

		agent.start(new IceCredentials(remote.usernameFragment, remote.password), haxe.Timer.stamp());
	}

	/**
		Opens a channel. The connection must be `ready`.

		Refused before then rather than queued, for the reason every layer here
		refuses early sends: a caller cannot tell a queued message from a sent
		one, and `ready.then` makes waiting explicit and cheap.
	**/
	public function createDataChannel(label:String, ordered:Bool = true, protocol:String = ""):DataChannel {
		if (!connected || __channels == null) {
			throw new ArgumentError("This connection is not ready yet. Wait on `ready` before creating channels.");
		}

		return __channels.create(label, ordered, protocol);
	}

	/**
		Moves every layer forward. Driven from the runtime tick once bound;
		public so a test can drive it with a clock of its own.
	**/
	public function poll(now:Float):Void {
		if (__closed) {
			return;
		}

		agent.poll(now);

		if (__dtls != null) {
			__dtls.poll(now);
		}

		if (__association != null) {
			__association.poll(now);
		}

		if (__transfer != null) {
			__transfer.poll(now);
		}
	}

	public function close():Void {
		if (__closed) {
			return;
		}

		__closed = true;
		connected = false;

		if (__tick != null) {
			try {
				CrossByte.current().removeEventListener(TickEvent.TICK, __tick);
			} catch (_:Dynamic) {}

			__tick = null;
		}

		agent.close();

		if (__dtls != null) {
			__dtls.close();
		}

		if (__association != null) {
			__association.close();
		}

		if (__socket != null) {
			try {
				__socket.close();
			} catch (_:Dynamic) {}
		}
	}

	// ------------------------------------------------------------------

	/**
		One socket, three protocols, told apart by the first byte.

		RFC 7983: under 4 is STUN, 20 to 63 is DTLS. SCTP never appears here
		raw -- it lives inside the DTLS records. Anything else is noise on a
		public port, and is dropped rather than guessed at.
	**/
	@:noCompletion private function __onDatagram(e:DatagramSocketDataEvent):Void {
		if (__closed || e.data == null || e.data.length == 0) {
			return;
		}

		var now:Float = haxe.Timer.stamp();

		e.data.position = 0;
		var first:Int = e.data.readUnsignedByte();
		e.data.position = 0;

		if (first < 4) {
			agent.receive(e.data, e.srcAddress, e.srcPort, now);
			return;
		}

		if (first >= 20 && first <= 63 && __dtls != null) {
			__dtls.receive(e.data, now);
		}
	}

	@:noCompletion private function __onPathFound(pair:IceCandidatePair):Void {
		if (__closed || __dtls != null) {
			return;
		}

		__peerAddress = pair.remote.address;
		__peerPort = pair.remote.port;

		// The controlling agent takes the DTLS client role, which is the
		// convention browsers follow -- and it must be a convention both sides
		// share, or both wait for a ClientHello that neither sends.
		__dtls = new DtlsTransport(certificate, __remote.fingerprint, controlling);

		__dtls.onSend = function(payload:ByteArray):Void {
			// To the nominated pair, always. The path ICE proved is the path
			// the session uses; sending anywhere else would open a NAT mapping
			// the peer knows nothing about.
			__send(payload, __peerAddress, __peerPort);
		};

		__dtls.established.then(_ -> __onSecured(), error -> __fail(error));

		// A first poll straight away, so the client's ClientHello leaves now
		// rather than on the next tick.
		__dtls.poll(haxe.Timer.stamp());
	}

	@:noCompletion private function __onSecured():Void {
		if (__closed || __association != null) {
			return;
		}

		__association = new SctpAssociation();

		__association.onSend = function(payload:ByteArray):Void {
			// Inside the session, never beside it. This is the line that makes
			// every message on every channel encrypted.
			__dtls.send(payload);
		};

		__dtls.onMessage = function(payload:ByteArray):Void {
			__association.receive(payload, haxe.Timer.stamp());
		};

		__association.established.then(_ -> __onAssociated(), error -> __fail(error));

		if (controlling) {
			__association.associate(haxe.Timer.stamp());
		} else {
			__association.listen();
		}
	}

	@:noCompletion private function __onAssociated():Void {
		if (__closed || __channels != null) {
			return;
		}

		__transfer = new SctpDataTransfer(__association);
		__channels = new DataChannelSet(__transfer, controlling);
		__channels.onChannel = channel -> onChannel(channel);

		connected = true;
		@:privateAccess ready.__resolve(this);
	}

	@:noCompletion private function __send(payload:ByteArray, address:String, port:Int):Void {
		if (__closed || __socket == null) {
			return;
		}

		try {
			__socket.send(payload, 0, payload.length, address, port);
		} catch (_:Dynamic) {
			// A candidate that cannot be routed is an ordinary outcome of
			// trying every candidate. The layer that sent this has its own
			// retransmission budget, and that is what decides the path is dead.
		}
	}

	@:noCompletion private function __fail(reason:String):Void {
		if (__closed) {
			return;
		}

		var wasConnected = connected;
		close();

		if (!wasConnected) {
			@:privateAccess ready.__fail(reason, null);
		}
	}
}
#end
