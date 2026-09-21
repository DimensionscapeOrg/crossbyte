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
import crossbyte.net.ice.IceAgentState;
import crossbyte.net.ice.IceCredentials;
import crossbyte.net.TurnClient;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunQuery;
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
	var connection = new PeerConnection(weOffer);
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

	## Who is what: two roles, not one

	There are two of these and they are decided separately, which is easy to
	miss because for two CrossByte peers they usually land on opposite sides and
	one bit would appear to serve.

	**The ICE role** follows the offer. The peer that offers is controlling: it
	nominates the pair. That is settled by `isOfferer` and can still change
	during checking, if both peers turn out to have claimed it and the
	tiebreakers say otherwise.

	**The DTLS role** is negotiated in the description. An offer says `actpass`
	-- whichever you like -- and the answer chooses `active` or `passive`. The
	DTLS client is the one that sends the ClientHello, and everything above DTLS
	follows *it* rather than the ICE role: RFC 8831 has the DTLS client open the
	SCTP association, and RFC 8832 gives it the even data channel streams.

	A browser makes the distinction unavoidable. It offers, so it is
	ICE-controlling, and it offers `actpass`, so a peer answering it is
	ICE-controlled and the DTLS client at the same time. A connection that drove
	both from one bit would have to be wrong about one of them -- and would be
	wrong quietly, since the ICE half would still connect.

	## Browsers hide their addresses, and it does not matter

	A browser does not publish the addresses of the machine it runs on. Every
	host candidate it offers is a random name ending in `.local`, registered with
	the local multicast DNS responder and meaningless anywhere else -- a privacy
	measure, so that a page cannot learn a visitor's network layout simply by
	opening a peer connection.

	Nothing here resolves those names, so every pair built from a browser's
	description is one that cannot be dialled, and the checks sent to it fail to
	resolve and are dropped. The connection is made anyway, from the other
	direction: this peer's addresses are real, so the browser's own checks arrive,
	and the source address one arrives from is a place the browser demonstrably
	is. ICE calls that a peer-reflexive candidate, and it is what the mechanism
	exists for.

	So browser interoperability needs no mDNS resolver, and one would not help
	much if it were here: those names only resolve on the link the browser is on,
	and a peer on that link can already be reached the way just described.

	A browser on some *other* network is a different problem. What it needs is
	an address a peer elsewhere can send to, and `gatherReflexive` asks a STUN
	server for one. That has to happen over this very socket, which is why it is
	a method here rather than something a caller could assemble outside: a NAT
	keeps one translation per socket, so an address discovered on a second
	socket describes a mapping nothing will ever send to.

	That covers a NAT that gives a socket one mapping whatever it talks to, and
	those are most of them. It does not cover a symmetric NAT, which makes a
	fresh mapping per destination so that the address a STUN server reports is
	not the one the peer would reach. Two of those, or one of those and a
	firewall that drops unsolicited datagrams, leave no datagram either peer can
	send that the other receives. `gatherRelayed` is the answer to that: a TURN
	server both peers can reach agrees to forward between them, and the address
	it lends becomes a candidate like any other.

	It is asked for last and used last on purpose. Every byte crosses a third
	party twice and somebody pays for the bandwidth, so ICE prefers any direct
	path it can prove -- a relayed candidate carries the lowest priority there
	is. It is worth having because the alternative is no connection at all.

	Gathering it does not commit the connection to it. Relayed, reflexive and
	host candidates are checked together and the best one that works wins, which
	is the whole point of ICE and the reason all three can simply be asked for
	up front.

	The one thing this does require is that this peer advertise an address the
	browser can reach. Gathering only toward the candidates a browser offered
	yields nothing at all, since none of them resolve -- ask `LocalAddress` for
	the default route as well, or the peer ends up advertising loopback and
	reachable only from its own machine.

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

	/**
		Whether this peer offered, and so nominates the ICE pair.

		May change during checking if both peers claimed it; see `IceAgent`. It
		decides nothing above ICE.
	**/
	public var iceControlling(default, null):Bool;

	/**
		Whether this peer sends the DTLS ClientHello.

		Also whether it opens the SCTP association and takes the even data
		channel streams, both of which follow the DTLS role rather than the ICE
		one. Undecided until a description has been exchanged: an offerer
		proposes `actpass` and learns its role from the answer.
	**/
	public var dtlsClient(default, null):Bool;

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
	@:noCompletion private var __isOfferer:Bool;

	/**
		@param isOfferer Whether this peer produces the offer. The two peers must
		pass opposite values. It makes this peer ICE-controlling, and it decides
		what `description()` proposes for the DTLS role -- an offerer proposes
		`actpass` and takes whatever the answer leaves it, while an answerer
		takes the client role unless the offer has already claimed it.
		@param certificate An existing identity to present, generated when
		omitted -- which is the normal case, a certificate here only having to
		outlive the session.
	**/
	public function new(isOfferer:Bool, ?certificate:DtlsCertificate, ?credentials:IceCredentials) {
		if (!isSupported) {
			throw new ArgumentError("A peer connection cannot run on this target: it needs a UDP socket, a CSPRNG and mbedTLS, and one of them is missing here. Check PeerConnection.isSupported. In a browser, use RTCPeerConnection -- this class is what it talks to.");
		}

		this.__isOfferer = isOfferer;
		this.iceControlling = isOfferer;

		// An answerer is the DTLS client by convention, which is what a browser
		// expects when it offers `actpass`. An offerer does not know yet and
		// finds out from the answer; until then this value is not used, because
		// nothing above ICE starts before a description has been exchanged.
		this.dtlsClient = !isOfferer;

		this.certificate = certificate != null ? certificate : DtlsCertificate.generate();
		this.credentials = credentials != null ? credentials : IceCredentials.generate();
		this.ready = new Future<PeerConnection>();

		agent = new IceAgent(isOfferer, this.credentials);
		agent.connected.then(pair -> __onPathFound(pair), error -> __fail("No path to the peer was found: " + error));

		// A role conflict changes which peer nominates, and nothing else. It
		// used to overwrite the DTLS role too, on the assumption that the two
		// were the same bit -- they are not, and a peer that rewrote its DTLS
		// role here would abandon a handshake already agreed in the
		// description over an ICE detail settled afterwards.
		agent.onRoleChanged = function(nowControlling:Bool):Void {
			iceControlling = nowControlling;
		};
	}

	/**
		Opens the socket everything will share, and starts the clock.

		@param localAddress Binding to a concrete address also records it as a
		host candidate. A wildcard bind does not -- `0.0.0.0` names every
		interface and so names none -- so a caller behind one should ask
		`LocalAddress` which interface reaches the peer and pass the answer to
		`addLocalCandidate`. Reflexive and relayed candidates go in the same
		way, but nothing here discovers them yet; see the class documentation.
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
			// Kept, because it is the base of anything reflexive gathered later:
			// a NAT's view of this connection is a place to be reached and not
			// one to send from, and the address that sends is this one.
			__hostCandidate = IceCandidate.host(bound, __socket.localPort);
			addLocalCandidate(__hostCandidate);
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
			candidates: candidates,
			// An offer leaves the choice open; an answer states what this peer
			// has settled on, which `connect` has already worked out if the
			// offer arrived first.
			setup: __isOfferer ? SessionDescription.SETUP_ACTPASS : (dtlsClient ? SessionDescription.SETUP_ACTIVE : SessionDescription.SETUP_PASSIVE)
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
		__resolveDtlsRole(remote.setup);

		// Built before the agent is touched. IceCredentials validates the
		// fragment and the password, and a description that fails that used to
		// throw below -- after every candidate had been added and before
		// agent.start was reached -- leaving the agent configured for a
		// connection that could never be started.
		var credentials = new IceCredentials(remote.usernameFragment, remote.password);

		for (candidate in remote.candidates) {
			// Skipped rather than thrown on, which is what SessionDescription
			// already does for a line it cannot use: "skipped rather than
			// accepted into a check that could only fail". Constructing one of
			// these validates the port and the component, so a description
			// carrying a single unusable candidate used to abort this loop
			// part-way -- some candidates added, the rest not, and the
			// agent.start below never reached, leaving a connection that could
			// never come up and said nothing about why. The candidates are the
			// peer's to choose, so one bad one is not the application's fault
			// to catch.
			try {
				agent.addRemoteCandidate(new IceCandidate((candidate.type : String), candidate.address, candidate.port, 1, candidate.priority));
			} catch (_:Dynamic) {}
		}

		agent.start(credentials, haxe.Timer.stamp());
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

		__pollReflexive(now);

		// Before the agent, so an allocation that is still being asked for keeps
		// asking and a granted one keeps being refreshed whatever else is happening.
		if (__turn != null) {
			__turn.poll(now);
		}

		agent.poll(now);

		// Consent is the agent's to lose and this connection's to act on. The
		// `ready` future resolved when the path came up, so a path that stops
		// being one has no other way to be reported -- and RFC 7675 asks the
		// sender to stop, which is something only the layer that sends can do.
		if (connected && agent.state == IceAgentState.FAILED) {
			__fail("The peer stopped answering consent checks, so the path to it is no longer usable.");
			return;
		}

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

		var wasConnected = connected;

		__closed = true;
		connected = false;

		// Closing before the server answered: the caller is holding a future,
		// and leaving it forever pending is worse than saying what happened.
		__settleReflexive(null, "The connection closed before the STUN server replied.");
		__settleRelayed(null, "The connection closed before the relay answered.");

		// And `ready`, which this did not settle. Those two above only exist
		// when the caller asked for them, so the omission was invisible unless
		// someone awaited the connection itself and then closed it -- after
		// which neither handler could ever run. __fail settles it first with a
		// reason that says what went wrong; Future.__fail is idempotent, so by
		// the time it reaches here there is nothing left to do.
		if (!wasConnected) {
			@:privateAccess ready.__cancel("The connection was closed before it was ready.");
		}

		if (__turn != null) {
			__turn.close();
		}

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
	/**
		Asks a STUN server what address this connection appears from, and adds
		the answer as a candidate.

		A peer behind NAT cannot work this out locally: `bind` records the
		private side of the mapping, and the side another peer has to dial is
		the public one, which only something outside the NAT can report.

		The question is asked through the socket this connection already owns,
		and it has to be. A NAT keeps its translation per socket, so an address
		discovered on a socket of its own -- which is what `StunClient` binds --
		answers a question about a mapping this connection does not have and no
		peer will ever send to.

		Candidates may arrive after checking has started, so this need not
		finish before `connect`. Host candidates are tried meanwhile, and the
		reflexive one joins the checking when it lands.

		@param timeoutMs How long to keep asking. UDP reports nothing when a
		datagram is dropped, so a server that never answers and one that was
		never reached look identical from here and only a deadline ends it.

		@return The candidate that was added, or a failure naming why none was.
		One query at a time: a second while one is outstanding fails rather than
		displacing it, and chaining off this future asks the next server.
	**/
	public function gatherReflexive(server:String, port:Int = 3478, timeoutMs:Int = 3000):Future<IceCandidate> {
		var future = new Future<IceCandidate>();

		if (__closed || __socket == null) {
			@:privateAccess future.__fail("A reflexive address can only be discovered through a bound connection; call bind first.", null);
			return future;
		}

		if (server == null || server == "") {
			@:privateAccess future.__fail("A STUN server address is required.", new ArgumentError("server"));
			return future;
		}

		if (__reflexiveFuture != null) {
			@:privateAccess future.__fail("A reflexive query is already outstanding on this connection.", null);
			return future;
		}

		var now:Float = haxe.Timer.stamp();

		// The schedule is RFC 5389's -- ask, and if nothing comes back ask
		// again after twice as long each time -- because a single datagram
		// carrying the only question this connection asks about its own
		// address is a thing to lose to one dropped packet, and a deadline
		// alone would report the loss as a server that is not there.
		__reflexiveQuery = new StunQuery(now, timeoutMs);
		__reflexiveFuture = future;
		__reflexiveServer = server;
		__reflexivePort = port;

		__send(__reflexiveQuery.request.encode(), server, port);
		return future;
	}

	/**
		Asks a TURN server to relay for this connection, and adds the address it
		lends as a candidate.

		For the peer no direct path reaches. A symmetric NAT gives a socket a
		fresh mapping per destination, so what `gatherReflexive` learned describes
		the route to the STUN server and nothing about the route to the peer; two
		of those, or one and a firewall that drops anything unsolicited, and there
		is no datagram either end can send that the other will receive. A relay is
		the address both can reach.

		Allocated through this connection's own socket, for the same reason the
		reflexive query is: the permissions a relay grants describe traffic from
		the socket that asked, and an allocation made on another one would forward
		for a connection that does not exist.

		Once it is granted, checks and data addressed to a peer over the relayed
		candidate are wrapped for the server to forward, and what comes back is
		unwrapped and handled as though it had arrived directly -- so nothing
		above ICE knows or needs to.

		@param useChannels Whether to ask the relay for a channel per peer, which
		costs four bytes a datagram where an indication costs thirty-six. Off by
		default: a relay that agrees to a channel and then drops what it is sent
		over it cannot say so, and the connection stops with nothing to report.
		See `TurnClient` for the one that does exactly that.

		@return The candidate that was added, or a failure naming why none was.
	**/
	public function gatherRelayed(server:String, username:String, password:String, port:Int = 3478,
			useChannels:Bool = false):Future<IceCandidate> {
		var future = new Future<IceCandidate>();

		if (__closed || __socket == null) {
			@:privateAccess future.__fail("A relay can only be allocated through a bound connection; call bind first.", null);
			return future;
		}

		if (server == null || server == "") {
			@:privateAccess future.__fail("A TURN server address is required.", new ArgumentError("server"));
			return future;
		}

		if (__turn != null) {
			@:privateAccess future.__fail("This connection already has a relay allocated.", null);
			return future;
		}

		var relay = new TurnClient(server, port, username, password);
		relay.useChannels = useChannels;
		__turn = relay;
		__relayedFuture = future;

		// Out to the server directly. The relay is reached the ordinary way; it
		// is only traffic for a peer that gets wrapped.
		relay.onSend = function(payload:ByteArray, address:String, sendPort:Int):Void {
			__send(payload, address, sendPort);
		};

		relay.onData = function(payload:ByteArray, fromAddress:String, fromPort:Int):Void {
			__onRelayed(payload, fromAddress, fromPort);
		};

		relay.allocated.then(function(relayed:ReflexiveAddress):Void {
			if (__closed) {
				return;
			}

			var candidate = new IceCandidate(RELAYED, relayed.address, relayed.port);
			__relayedCandidate = candidate;

			// The candidate and the way to send from it, together: its address is
			// the server's, so a datagram addressed there straightforwardly would
			// arrive at the relay as ordinary traffic rather than as something to
			// forward.
			agent.addLocalCandidate(candidate, function(payload:ByteArray, address:String, peerPort:Int):Void {
				__relayTo(payload, address, peerPort);
			});

			__localCandidates.push(candidate);
			__settleRelayed(candidate, null);
		}, function(error:String):Void {
			__settleRelayed(null, error);
		});

		relay.allocate(__clock());
		return future;
	}

	/** The relayed candidate, once a server has granted one. **/
	public var relayedCandidate(get, never):Null<IceCandidate>;

	@:noCompletion private function get_relayedCandidate():Null<IceCandidate> {
		return __relayedCandidate;
	}

	/** This connection's own address, when the bind named one. **/
	@:noCompletion private var __hostCandidate:IceCandidate;

	@:noCompletion private var __turn:TurnClient;
	@:noCompletion private var __relayedCandidate:IceCandidate;
	@:noCompletion private var __relayedFuture:Future<IceCandidate>;
	@:noCompletion private var __permitted:Map<String, Float> = new Map();

	/** Whether the nominated pair reaches the peer through the relay. **/
	@:noCompletion private var __peerRelayed:Bool = false;

	/**
		How long a permission is assumed to last before it is asked for again.

		RFC 8656 gives one five minutes. Renewed well inside that, because a
		permission that lapses does not fail loudly -- the relay simply drops what
		it is asked to forward, and the connection goes quiet for no stated reason.
	**/

	/**
		Wraps one datagram for the relay to forward, permitting the peer first.

		A relay forwards to an address only once it has been told to expect it,
		and a Send indication to a peer with no permission is discarded without
		any reply -- which from here looks exactly like a peer that is not there.
	**/
	@:noCompletion private function __relayTo(payload:ByteArray, address:String, port:Int):Void {
		if (__turn == null) {
			return;
		}

		var now = __clock();

		// Once per address. Renewing it used to happen here too, on the same
		// four minutes, which only renewed a permission while traffic was
		// flowing -- an idle-but-receiving connection lapsed and the relay
		// began dropping the peer inbound. TurnClient renews on its own tick
		// now, so keeping a second copy of that policy here would just send
		// the relay a redundant request every cycle.
		if (!__permitted.exists(address)) {
			__permitted.set(address, now);
			__turn.permit(address, now);
		}

		// And a channel, which costs four bytes a datagram where an indication
		// costs thirty-six. Asked for every time and ignored when one is
		// already fresh; until the relay agrees, `sendTo` keeps using
		// indications, so a relay that will not bind is a connection at the old
		// price rather than no connection.
		__turn.bindChannel(address, port, now);

		__turn.sendTo(payload, address, port);
	}

	/**
		A datagram the relay forwarded, put back where it would have arrived.

		The same demultiplexing as anything off the socket, and deliberately so:
		by this point the wrapper is gone and what is left is exactly what the peer
		sent. What it is told in addition is which candidate it came in on, so that
		an answer goes back out the same way rather than straight at an address
		nothing here can reach.
	**/
	@:noCompletion private function __onRelayed(payload:ByteArray, fromAddress:String, fromPort:Int):Void {
		if (__closed || payload == null || payload.length == 0) {
			return;
		}

		var now = __clock();

		payload.position = 0;
		var first:Int = payload.readUnsignedByte();
		payload.position = 0;

		if (first < 4) {
			agent.receive(payload, fromAddress, fromPort, now, __relayedCandidate);
			return;
		}

		if (first >= 20 && first <= 63 && __dtls != null) {
			__dtls.receive(payload, now);
		}
	}

	@:noCompletion private function __settleRelayed(candidate:Null<IceCandidate>, error:String):Void {
		var future = __relayedFuture;
		__relayedFuture = null;

		if (future == null) {
			return;
		}

		if (candidate == null) {
			@:privateAccess future.__fail(error, null);
			return;
		}

		@:privateAccess future.__resolve(candidate);
	}

	/**
		The time every layer here is driven from.

		One clock, so that a permission granted during a poll and a retransmission
		scheduled during a receive are measured against the same thing.
	**/
	@:noCompletion private function __clock():Float {
		return haxe.Timer.stamp();
	}

	/**
		The question outstanding, if one is: its transaction, its schedule, and
		how to read a reply. `StunQuery` owns all three, shared with the other
		two places here that ask a STUN server the same thing.
	**/
	@:noCompletion private var __reflexiveQuery:StunQuery;

	@:noCompletion private var __reflexiveFuture:Future<IceCandidate>;
	@:noCompletion private var __reflexiveServer:String;
	@:noCompletion private var __reflexivePort:Int = 0;

	/** Asks again, or gives up. **/
	@:noCompletion private function __pollReflexive(now:Float):Void {
		if (__reflexiveFuture == null) {
			return;
		}

		if (__reflexiveQuery.expired(now)) {
			__settleReflexive(null, "No reply from the STUN server at " + __reflexiveServer + ":" + __reflexivePort
				+ " within the time allowed, so this connection still has no address to advertise beyond its own network.");
			return;
		}

		if (__reflexiveQuery.shouldRetransmit(now)) {
			__send(__reflexiveQuery.request.encode(), __reflexiveServer, __reflexivePort);
		}
	}

	/**
		Whether this STUN message is the answer being waited for.

		Decided by the transaction alone, and deliberately not by where it came
		from: the server may have been named as a hostname, and the datagram
		arrives from whichever address that resolved to. The transaction is
		ninety-six bits chosen at random per request, which is what RFC 5389
		gives an implementation to recognise its own replies by.
	**/
	@:noCompletion private function __receiveReflexive(payload:ByteArray, now:Float):Bool {
		if (__reflexiveFuture == null || __reflexiveQuery == null) {
			return false;
		}

		switch (__reflexiveQuery.interpret(payload)) {
			case NOT_OURS:
				return false;
			case ANSWERED(mapped):
				__settleReflexive(mapped, null);
			case REFUSED(reason):
				__settleReflexive(null, "The STUN server refused the request" + (reason != null ? ": " + reason : "."));
			case ANSWERED_WITHOUT_ADDRESS:
				__settleReflexive(null, "The STUN server replied without a mapped address, so this connection's public address is still unknown.");
		}

		return true;
	}

	@:noCompletion private function __settleReflexive(mapped:Null<ReflexiveAddress>, error:String):Void {
		var future = __reflexiveFuture;

		__reflexiveFuture = null;
		__reflexiveQuery = null;
		__reflexiveServer = null;

		if (future == null) {
			return;
		}

		if (mapped == null) {
			@:privateAccess future.__fail(error, null);
			return;
		}

		// With the host candidate as its base, so that pairing collapses the
		// two rather than sending every check twice from the one socket. Null
		// when the bind was a wildcard, which leaves the reflexive candidate
		// standing on its own -- there is no recorded address it is a view of.
		var candidate = IceCandidate.serverReflexive(mapped, IceCandidate.COMPONENT_RTP, IceCandidate.DEFAULT_LOCAL_PREFERENCE,
			__hostCandidate);
		addLocalCandidate(candidate);
		@:privateAccess future.__resolve(candidate);
	}

	@:noCompletion private function __onDatagram(e:DatagramSocketDataEvent):Void {
		if (__closed || e.data == null || e.data.length == 0) {
			return;
		}

		var now:Float = haxe.Timer.stamp();

		e.data.position = 0;
		var first:Int = e.data.readUnsignedByte();
		e.data.position = 0;

		if (first < 4) {
			// The answer to this connection's own question about its address,
			// if that is what it is. Offered here first because it shares the
			// socket and the byte range with everything ICE sends; the
			// transaction says which, and the agent would only refuse it.
			if (__receiveReflexive(e.data, now)) {
				return;
			}

			// Then the relay, which recognises its own by message type and hands
			// back anything else. Its replies and the traffic it forwards share the
			// STUN byte range with every connectivity check on this socket, and
			// where they came from cannot decide it -- the server may have been
			// named as a hostname, and it answers from whatever that resolved to.
			e.data.position = 0;

			if (__turn != null && __turn.receive(e.data, e.srcAddress, e.srcPort, now)) {
				return;
			}

			e.data.position = 0;
			agent.receive(e.data, e.srcAddress, e.srcPort, now);
			return;
		}

		// A relay's ChannelData, which is neither STUN nor DTLS and says so by
		// where its first byte lands: RFC 7983 leaves 64 to 127 free, and RFC
		// 8656 puts channel numbers there for exactly this reason.
		if (first >= 0x40 && first <= 0x7F) {
			if (__turn != null) {
				__turn.receive(e.data, e.srcAddress, e.srcPort, now);
			}

			return;
		}

		if (first >= 20 && first <= 63 && __dtls != null) {
			__dtls.receive(e.data, now);
		}
	}

	/**
		Settles which end sends the ClientHello, from what the peer proposed.

		`actpass` leaves it here, and an answerer keeps the client role it
		already assumed. A peer that has committed gets the opposite, because
		both ends taking the same role is two peers waiting for a handshake
		neither will open -- and both taking *different* halves of it is a
		handshake that completes and an SCTP association that never does, since
		the association is opened by the DTLS client.

		A description carrying no setup at all is a CrossByte peer from before
		this was negotiated, or an application passing the structure directly.
		The value each side already holds is opposite by construction, so
		leaving it alone is right.
	**/
	@:noCompletion private function __resolveDtlsRole(offered:Null<String>):Void {
		if (offered == null || offered == SessionDescription.SETUP_ACTPASS) {
			return;
		}

		dtlsClient = !SessionDescription.isClient(offered);
	}

	@:noCompletion private function __onPathFound(pair:IceCandidatePair):Void {
		if (__closed || __dtls != null) {
			return;
		}

		__peerAddress = pair.remote.address;
		__peerPort = pair.remote.port;

		// Which of this peer's addresses the path was proved on. It matters only
		// when it is the relayed one, and then it matters entirely: the session's
		// records have to travel the same way its connectivity checks did.
		__peerRelayed = __relayedCandidate != null && pair.local.sameAs(__relayedCandidate);

		// The DTLS role, not the ICE one. A peer answering a browser is
		// ICE-controlled and the DTLS client at once, and using the ICE role
		// here would have it wait for a ClientHello the browser is waiting for
		// it to send.
		__dtls = new DtlsTransport(certificate, __remote.fingerprint, dtlsClient);

		__dtls.onSend = function(payload:ByteArray):Void {
			// To the nominated pair, always, and by the route it was nominated on.
			// The path ICE proved is the path the session uses; sending anywhere
			// else would open a NAT mapping the peer knows nothing about.
			if (__peerRelayed) {
				__relayTo(payload, __peerAddress, __peerPort);
			} else {
				__send(payload, __peerAddress, __peerPort);
			}
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

		// RFC 8831: the DTLS client opens the association. Following the ICE
		// role here would have both peers listen, or both associate, whenever
		// the two roles differ -- which is every connection with a browser.
		if (dtlsClient) {
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
		// RFC 8832: the DTLS client takes the even streams. Two peers that
		// disagreed about which of them that is would collide on every channel
		// they opened at the same moment.
		__channels = new DataChannelSet(__transfer, dtlsClient);
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

		// Before close(), which settles `ready` too but only knows that the
		// connection was closed. Whichever runs first wins, and this one knows
		// what actually went wrong.
		if (!connected) {
			@:privateAccess ready.__fail(reason, null);
		}

		close();
	}
}
#end
