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
import crossbyte.net.TurnError;
import crossbyte.net.TurnServer;
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

	## Many on one port

	A connection that binds costs a socket of its own, that socket's buffers
	and a tick listener. A server holding many peers makes them on a
	`PeerConnectionHost` instead, and they share one socket and one tick; see
	there for how a datagram finds its connection.

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

	/**
		Resolves once, when the connection has closed, with the reason.

		Whichever end closed it and however: `close()` here, the peer closing
		its own connection (an SCTP ABORT or SHUTDOWN, or a DTLS close_notify),
		a fatal alert, the peer no longer answering consent checks, the relay
		carrying the path going away, or a connection that never came up. By
		the time it resolves every channel has been closed and has reported
		`onClose`.
	**/
	public var closed(default, null):Future<String>;

	/**
		Called once when the connection closes, with the same reason `closed`
		resolves with.

		A peer that went away used to be reported by nothing at all. An
		application had to poll `connected` on every connection every tick to
		notice, and even then learned of a browser's `pc.close()` only when ICE
		consent ran out half a minute later, because the ABORT and close_notify
		that said so on the wire were swallowed below this class.
	**/
	public dynamic function onClose(reason:String):Void {}

	/** Why the connection closed, once it has; null until then. **/
	public var closeReason(default, null):Null<String> = null;

	/** The default for `readyTimeout`, in seconds. **/
	public static inline var DEFAULT_READY_TIMEOUT:Float = 30.0;

	@:noCompletion private static inline var SHARED_SOCKET_GATHERS_NOTHING:String = "A connection sharing a host's socket gathers no address of its own: that socket's mapping is every connection's. Give the host's public address to PeerConnectionHost.addLocalCandidate.";

	/**
		How long, in seconds from `connect`, the whole stack has to come up
		before the connection gives up and fails `ready`.

		Every phase had its own ending except the ones that waited on the
		peer to go first: a DTLS server waits for a ClientHello with no timer
		running, an SCTP listener for an INIT, and a peer whose tab closed
		just after ICE left this end holding a socket, a tick listener and a
		TLS session for as long as the process ran. The reason `ready` fails
		with names the phase that did not finish. Read at every poll, so it
		can be changed after `connect`.
	**/
	public var readyTimeout:Float = DEFAULT_READY_TIMEOUT;

	/** Called when the peer opens a channel rather than answering one. **/
	public dynamic function onChannel(channel:DataChannel):Void {}

	/**
		Called with each candidate this connection gains: its own address when
		`bind` names one, a reflexive or relayed one as a server grants it, and
		any passed to `addLocalCandidate`.

		For trickle ICE: send each to the peer as it arrives -- written with
		`SessionDescription.writeCandidate` for a browser -- instead of waiting
		to put them all in a description. A candidate already in a description
		the peer has is harmless to send again.
	**/
	public dynamic function onLocalCandidate(candidate:CandidateDescription):Void {}

	/**
		A slot for whatever the application wants this connection to carry.

		Untouched by the framework, and it goes when the connection does. The
		same as `DataChannel.userData`: without one, per-peer state -- a
		session, a player -- lives in a map beside the connection that has to be
		cleaned up by hand when it closes.
	**/
	public var userData:Any = null;

	@:noCompletion private var __socket:DatagramSocket;

	/** The host whose socket and tick this connection shares, when one made it; null when it binds its own. **/
	@:noCompletion private var __host:PeerConnectionHost;

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
		Whether the next description this side writes is an offer -- which
		leaves the DTLS role open -- or an answer, which states it. The first
		exchange decides it, and each ICE restart again: an answer to a
		restart the peer offered says `active` or `passive` whoever offered
		first, since a browser refuses an answer saying `actpass`.
	**/
	@:noCompletion private var __offering:Bool;

	/**
		The agent of an ICE restart under way, checking with new credentials
		while the session carries on over the old path; it replaces `agent`
		once it has one. Null when no restart is under way.
	**/
	@:noCompletion private var __restartAgent:IceAgent = null;

	/** Whether `connect` has started things, and when, for `readyTimeout`. **/
	@:noCompletion private var __connecting:Bool = false;

	@:noCompletion private var __connectStartedAt:Float = 0;

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
		this.closed = new Future<String>();

		this.__offering = isOfferer;

		var first = __makeAgent(isOfferer, this.credentials);
		agent = first;

		first.connected.then(pair -> __onPathFound(pair), function(error:String):Void {
			// Not when an ICE restart replaced it, or is under way to: the new
			// agent decides then, and closing this one fails its future.
			if (first == agent && __restartAgent == null) {
				__fail("No path to the peer was found: " + error);
			}
		});
	}

	/**
		An agent wired to this connection: the first, or one an ICE restart
		makes. Each callback acts only while its agent is the one carrying the
		session, so an agent being replaced cannot move it.
	**/
	@:noCompletion private function __makeAgent(controlling:Bool, credentials:IceCredentials):IceAgent {
		var made = new IceAgent(controlling, credentials);

		// Out through this connection's socket, or its host's -- which, told
		// first, sends the answer to a check back here.
		made.onSend = function(payload:ByteArray, address:String, port:Int):Void {
			if (__host != null) {
				@:privateAccess __host.__sending(this, payload);
			}

			__send(payload, address, port);
		};

		// A role conflict changes which peer nominates, and nothing else. It
		// used to overwrite the DTLS role too, on the assumption that the two
		// were the same bit -- they are not, and a peer that rewrote its DTLS
		// role here would abandon a handshake already agreed in the
		// description over an ICE detail settled afterwards.
		made.onRoleChanged = function(nowControlling:Bool):Void {
			if (made == agent) {
				iceControlling = nowControlling;
			}
		};

		// The controlling peer nominated another pair -- a browser whose
		// network changed nominates the pair from its new address -- and the
		// session goes where the agent now points. It used to stay on the
		// first pair for good, sending into an address that had gone until
		// consent to it ran out.
		made.onSelectedPairChanged = function(pair:IceCandidatePair):Void {
			if (__closed || __dtls == null || made != agent) {
				return;
			}

			__route(pair);
		};

		return made;
	}

	/** Where the session's records go: the selected pair's remote end, by the route it was proved on. **/
	@:noCompletion private function __route(pair:IceCandidatePair):Void {
		__peerAddress = pair.remote.address;
		__peerPort = pair.remote.port;

		// Which of this peer's addresses the path was proved on. It matters only
		// when it is the relayed one, and then it matters entirely: the session's
		// records have to travel the same way its connectivity checks did.
		__peerRelayed = __relayedCandidate != null && pair.local.sameAs(__relayedCandidate);

		// On a shared socket, records from there are this connection's now.
		if (__host != null) {
			@:privateAccess __host.__proved(this, __peerAddress, __peerPort);
		}
	}

	/**
		Shares a host's socket and tick instead of binding its own. Called by
		`PeerConnectionHost.createConnection`, once.
	**/
	@:noCompletion private function __attach(host:PeerConnectionHost):Void {
		__host = host;
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
		if (__host != null) {
			throw new ArgumentError("This connection shares its host's socket, so it has none of its own to bind.");
		}

		if (__closed || __socket != null) {
			return;
		}

		__socket = new DatagramSocket();
		__socket.bind(localPort, localAddress);
		__socket.addEventListener(DatagramSocketDataEvent.DATA, __onDatagram);
		__socket.receive();

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
		if (__host != null) {
			return __host.localPort;
		}

		return __socket != null ? __socket.localPort : 0;
	}

	/**
		Adds an address this peer can be reached at.

		`bind` adds the socket's own when it names one; reflexive and relayed
		candidates arrive here from whatever gathered them.
	**/
	public function addLocalCandidate(candidate:IceCandidate):Void {
		agent.addLocalCandidate(candidate);

		if (__restartAgent != null) {
			__restartAgent.addLocalCandidate(candidate);
		}

		__gained(candidate);
	}

	/**
		Adds a candidate the peer trickled, before or after `connect`.

		What arrives from a browser's `onicecandidate` is a line; read it with
		`SessionDescription.readCandidate` first. The agent had to be reached
		directly for this, through a field documented as being for inspection.

		@return Whether it was taken. One that cannot be used -- a name rather
		than an address, which is what a browser hiding its addresses sends,
		or a port that cannot be dialled -- is skipped, the way a
		description's are, since the candidates are the peer's to choose.
	**/
	public function addRemoteCandidate(candidate:CandidateDescription):Bool {
		if (__closed || candidate == null) {
			return false;
		}

		// During an ICE restart a trickled candidate is for the new session:
		// the peer has already moved to it.
		var target = __restartAgent != null ? __restartAgent : agent;

		try {
			return target.addRemoteCandidate(new IceCandidate((candidate.type : String), candidate.address, candidate.port, 1, candidate.priority));
		} catch (_:Dynamic) {
			return false;
		}
	}

	/** A candidate this connection now has, recorded for `description` and announced for trickling. **/
	@:noCompletion private function __gained(candidate:IceCandidate):Void {
		__localCandidates.push(candidate);
		onLocalCandidate(__describe(candidate));
	}

	@:noCompletion private static function __describe(candidate:IceCandidate):CandidateDescription {
		return {
			address: candidate.address,
			port: candidate.port,
			type: (candidate.type : String),
			priority: candidate.priority
		};
	}

	/**
		Everything the peer needs to reach this connection.

		Sent over the application's own signalling channel -- the one part of
		WebRTC that is deliberately not CrossByte's to carry.
	**/
	public function description():PeerDescription {
		var candidates:Array<CandidateDescription> = [];

		for (candidate in __localCandidates) {
			candidates.push(__describe(candidate));
		}

		return {
			usernameFragment: credentials.usernameFragment,
			password: credentials.password,
			fingerprint: certificate.fingerprint,
			candidates: candidates,
			// An offer leaves the choice open; an answer states what this peer
			// has settled on, which `connect` has already worked out if the
			// offer arrived first.
			setup: __offering ? SessionDescription.SETUP_ACTPASS : (dtlsClient ? SessionDescription.SETUP_ACTIVE : SessionDescription.SETUP_PASSIVE),
			// What the receiver here reassembles, which is what a peer may send.
			maxMessageSize: SctpDataTransfer.MAX_REASSEMBLY,
			// An answer repeats the offer's section id, which a browser matches
			// the two by; it was always "0", so an offer that said "data" got
			// an answer it could not place.
			mid: __remote != null ? __remote.mid : null
		};
	}

	/**
		The largest message the peer takes, in bytes, or 0 for any size.

		From its description's `maxMessageSize` -- `a=max-message-size` in SDP,
		64 KB when a document leaves it out -- and `send` on a channel refuses
		anything larger, as RFC 8841 says a sender must. Known once `connect`
		has been given the description.
	**/
	public var maxMessageSize(get, never):Int;

	@:noCompletion private function get_maxMessageSize():Int {
		return __peerMaxMessageSize;
	}

	@:noCompletion private var __peerMaxMessageSize:Int = SctpDataTransfer.MAX_REASSEMBLY;

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

		if (__socket == null && __host == null) {
			throw new ArgumentError("Bind before connecting: the checks have to leave from the socket the peer will be told about.");
		}

		if (remote.fingerprint == null || remote.fingerprint.length == 0) {
			throw new ArgumentError("The peer's description carries no certificate fingerprint. Without one the handshake would accept any certificate at all, so this connection is refused rather than left unauthenticated.");
		}

		if (__remote != null) {
			__reconnect(remote);
			return;
		}

		__remote = remote;
		__resolveDtlsRole(remote.setup);

		// Absent from a structure means a CrossByte peer, which takes what
		// this stack takes; SDP that left it out has already been given the
		// RFC's default by `SessionDescription.fromSdp`.
		if (remote.maxMessageSize != null && remote.maxMessageSize >= 0) {
			__peerMaxMessageSize = remote.maxMessageSize;
		}

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

		var now:Float = haxe.Timer.stamp();

		if (!__connecting) {
			__connecting = true;
			__connectStartedAt = now;
		}

		agent.start(credentials, now);
	}

	/**
		Restarts ICE from this side: new credentials, and a new agent that
		finds a path afresh while the session carries on over the old one.

		For when the path may have gone -- this device changed network, say,
		and its old address is no longer anywhere. Send `description()` to the
		peer as a new offer and give its answer to `connect`; once the new agent
		has a path the session moves to it. DTLS and SCTP carry on untouched:
		channels stay open, and what was sent meanwhile is retransmitted over
		the new path as over any other.

		A peer can restart too: a description from it with new credentials,
		given to `connect`, restarts this side, and `description()` is then
		the answer to send back. A browser does that after `restartIce()`.

		@throws ArgumentError Before `connect`, or once closed.
	**/
	public function restartIce():Void {
		if (__closed || __remote == null) {
			throw new ArgumentError("ICE can only be restarted on a connection that has been given the peer's description and has not closed.");
		}

		// Already under way: the description carries it.
		if (__restartAgent != null) {
			return;
		}

		__beginRestart(true);
	}

	/** Whether an ICE restart is under way: begun, and its new agent not yet carrying the session. **/
	public var iceRestarting(get, never):Bool;

	@:noCompletion private function get_iceRestarting():Bool {
		return __restartAgent != null;
	}

	/**
		New credentials and a new agent, given every candidate this connection
		has. Not started: that waits for the peer's credentials.

		@param offering Whether this side offers the restart, and so controls
		it: RFC 8445 section 6.1.1 lets a restart decide the roles afresh, and
		a browser does, taking control of a restart it offers. The two agents
		settle it by tie-breaker if they disagree.
	**/
	@:noCompletion private function __beginRestart(offering:Bool):Void {
		var fresh:IceCredentials = __host != null ? @:privateAccess __host.__freshCredentials(this) : IceCredentials.generate();
		var restarting = __makeAgent(offering, fresh);

		__offering = offering;
		credentials = fresh;
		__restartAgent = restarting;

		for (candidate in __localCandidates) {
			if (candidate == __relayedCandidate) {
				restarting.addLocalCandidate(candidate, __relaySend);
			} else {
				restarting.addLocalCandidate(candidate);
			}
		}

		restarting.connected.then(pair -> __onRestarted(restarting, pair), function(error:String):Void {
			if (restarting == __restartAgent) {
				__fail("The ICE restart found no path to the peer: " + error);
			}
		});

		// A restart is often a network change, which takes the allocation with
		// it: the relay is asked now rather than at the next refresh, and one
		// that has gone is replaced, so the restart has a relayed candidate.
		__renewRelay();
	}

	/**
		A description after the first: the peer's answer to a restart this side
		began, a restart the peer began, or the same session again with more
		candidates.
	**/
	@:noCompletion private function __reconnect(remote:PeerDescription):Void {
		// Another certificate is another DTLS session, which a restart is not.
		if (remote.fingerprint.toLowerCase() != __remote.fingerprint.toLowerCase()) {
			throw new ArgumentError("The description carries another certificate, which makes it a new session rather than this one. Make a new connection for it.");
		}

		// Validated before anything changes, as on the first connect.
		var remoteCredentials = new IceCredentials(remote.usernameFragment, remote.password);
		var restarted:Bool = remote.usernameFragment != __remote.usernameFragment || remote.password != __remote.password;

		if (restarted && __restartAgent == null) {
			// The peer offered it; this side answers.
			__beginRestart(false);
		}

		if (remote.mid == null) {
			remote.mid = __remote.mid;
		}

		__remote = remote;

		var target = __restartAgent != null ? __restartAgent : agent;

		for (candidate in remote.candidates) {
			try {
				target.addRemoteCandidate(new IceCandidate((candidate.type : String), candidate.address, candidate.port, 1, candidate.priority));
			} catch (_:Dynamic) {}
		}

		// Started once: by the peer's answer to a restart this side offered, or
		// straight away for one the peer offered.
		if (__restartAgent != null && __restartAgent.state == IceAgentState.NEW) {
			__restartAgent.start(remoteCredentials, haxe.Timer.stamp());
		}
	}

	/**
		The restart's agent has a path: it carries the session from now on, and
		the old one is closed.
	**/
	@:noCompletion private function __onRestarted(restarting:IceAgent, pair:IceCandidatePair):Void {
		if (__closed || restarting != __restartAgent) {
			return;
		}

		var previous = agent;
		agent = restarting;
		__restartAgent = null;
		iceControlling = restarting.controlling;

		if (__host != null) {
			@:privateAccess __host.__retire(this, previous.localCredentials.usernameFragment);
		}

		// Its `connected`, if still pending, fails as it closes; that handler
		// sees it is no longer the agent and lets it go.
		previous.close();

		// A restart before the session was up finds its first path here.
		if (__dtls == null) {
			__onPathFound(pair);
		} else {
			__route(pair);
		}
	}

	/**
		Opens a channel. The connection must be `ready`.

		Refused before then rather than queued, for the reason every layer here
		refuses early sends: a caller cannot tell a queued message from a sent
		one, and `ready.then` makes waiting explicit and cheap.

		@param maxRetransmits How many times a message may be sent again
		before it is given up on -- 0 sends each once -- for a channel that
		would rather lose a message than wait for it, as a game's state
		channel does. See `DataChannel.maxRetransmits`.
		@param maxPacketLifeTime Milliseconds a message is tried for, the other
		way to say the same. One or the other, not both.
	**/
	public function createDataChannel(label:String, ordered:Bool = true, protocol:String = "", ?maxRetransmits:Int,
			?maxPacketLifeTime:Int):DataChannel {
		if (!connected || __channels == null) {
			throw new ArgumentError("This connection is not ready yet. Wait on `ready` before creating channels.");
		}

		return __channels.create(label, ordered, protocol, maxRetransmits, maxPacketLifeTime);
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

			// A relay that went away may have taken the connection with it.
			if (__closed) {
				return;
			}
		}

		agent.poll(now);

		// Every pair failing fails the agent's own future, which has already
		// closed this.
		if (__closed) {
			return;
		}

		if (__restartAgent != null) {
			__restartAgent.poll(now);

			if (__closed) {
				return;
			}
		}

		// Consent is the agent's to lose and this connection's to act on, and
		// from the moment the path is found rather than once everything above
		// it is up: a peer that went away mid-handshake was ignored until the
		// association opened, which it never would. RFC 7675 asks the sender
		// to stop, which is something only the layer that sends can do, and
		// stopping includes the goodbyes: nothing is sent on the way out.
		//
		// Except while an ICE restart is under way. The old path going is often
		// why there is one, and the new agent decides: it replaces this one if
		// it finds a path, and fails the connection if it cannot.
		if (agent.state == IceAgentState.FAILED && __restartAgent == null) {
			__shutdown(connected ? "The peer stopped answering consent checks, so the path to it is no longer usable." : "The peer stopped answering consent checks before the connection was ready.",
				false, false);
			return;
		}

		if (!connected && __connecting && now - __connectStartedAt >= readyTimeout) {
			__fail("The connection did not become ready within " + readyTimeout + " seconds: " + __phase() + ".");
			return;
		}

		if (__dtls != null) {
			__dtls.poll(now);
		}

		// Each layer below can end the connection -- a close_notify read, an
		// association the peer stopped answering -- and the rest are then
		// closed and have nothing to do.
		if (__closed) {
			return;
		}

		if (__association != null) {
			__association.poll(now);
		}

		if (__transfer != null && !__closed) {
			__transfer.poll(now);
		}
	}

	/**
		Closes the connection, its channels, and the peer's end of it.

		Every open channel is closed and reports `onClose`. The peer is told in
		both of the ways it listens for, an SCTP ABORT inside the session and
		then a DTLS close_notify, so a browser's channels close now rather than
		when its own consent checks run out. Then `closed` resolves and
		`onClose` runs.
	**/
	public function close():Void {
		__shutdown("The connection was closed.", true, true);
	}

	/**
		The one way this connection ends, whoever ends it.

		@param notifyPeer Whether the peer is sent an ABORT and a close_notify
		on the way out. Not when the path is already known to be dead: RFC 7675
		asks a sender whose consent has expired to stop sending, and the relay
		a path ran through cannot carry a goodbye once it has gone.
		@param local Whether this end asked. It decides only how a `ready` still
		waiting is settled -- a close the caller asked for is a cancellation,
		anything else a failure with its reason.
	**/
	@:noCompletion private function __shutdown(reason:String, notifyPeer:Bool, local:Bool):Void {
		if (__closed) {
			return;
		}

		var wasConnected = connected;

		__closed = true;
		connected = false;
		closeReason = reason;

		// The channels first, so an application tearing down what it keeps per
		// channel hears about each before it hears the connection has gone.
		if (__channels != null) {
			__channels.closeAll();
		}

		// Then the peer, while the session is still there to carry it: the
		// ABORT inside DTLS, and the close_notify after it. Either can fail on
		// a session the peer already ended, which is not worth an exception on
		// the way out.
		if (__association != null) {
			if (notifyPeer) {
				try {
					__association.abort(local ? null : reason);
				} catch (_:Dynamic) {}
			}

			__association.close();
		}

		if (__dtls != null) {
			try {
				__dtls.close(notifyPeer);
			} catch (_:Dynamic) {}
		}

		// Closing before the server answered: the caller is holding a future,
		// and leaving it forever pending is worse than saying what happened.
		__settleReflexive(null, "The connection closed before the STUN server replied.");
		__settleRelayed(null, "The connection closed before the relay answered.");

		// And `ready`. Those two above only exist when the caller asked for
		// them, so leaving this one out was invisible unless someone awaited
		// the connection itself and then closed it -- after which neither
		// handler could ever run.
		if (!wasConnected) {
			if (local) {
				@:privateAccess ready.__cancel("The connection was closed before it was ready.");
			} else {
				@:privateAccess ready.__fail(reason, null);
			}
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

		// Cleared first: closing it fails its future, whose handler would
		// otherwise find it still the restart under way.
		if (__restartAgent != null) {
			var restarting = __restartAgent;
			__restartAgent = null;
			restarting.close();
		}

		if (__socket != null) {
			try {
				__socket.close();
			} catch (_:Dynamic) {}

			__socket = null;
		}

		// A shared socket stays open for the others; this one stops being
		// routed to, and stops sending with it.
		if (__host != null) {
			@:privateAccess __host.__detach(this);
			__host = null;
		}

		@:privateAccess closed.__resolve(reason);
		onClose(reason);
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

		if (__host != null) {
			@:privateAccess future.__fail(SHARED_SOCKET_GATHERS_NOTHING, null);
			return future;
		}

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

		The same as `gatherRelayedFrom` with one server; see there for what
		happens when the relay fails or goes away.

		@param useChannels Whether to ask the relay for a channel per peer, which
		costs four bytes a datagram where an indication costs thirty-six. Off by
		default: a relay that agrees to a channel and then drops what it is sent
		over it cannot say so, and the connection stops with nothing to report.
		See `TurnClient` for the one that does exactly that.

		@return The candidate that was added, or a failure naming why none was,
		whose `cause` is a `TurnError` with the relay's code.
	**/
	public function gatherRelayed(server:String, username:String, password:String, port:Int = 3478,
			useChannels:Bool = false):Future<IceCandidate> {
		if (server == null || server == "") {
			var future = new Future<IceCandidate>();
			@:privateAccess future.__fail("A TURN server address is required.", new ArgumentError("server"));
			return future;
		}

		return gatherRelayedFrom([{address: server, port: port, username: username, password: password}], useChannels);
	}

	/**
		Asks each relay in turn until one lends an address, and keeps one lent
		for as long as the connection lasts.

		A connection got one attempt at a relay, for life. A relay that was full
		(486), out of capacity (508), silent, or refused the credentials left it
		with no relay and no way to ask another -- asking again was refused as
		"already has a relay" -- and a relay that later went away, after a
		network change or a restart of its own, was not replaced either.

		- Each server is asked in order, the next when one refuses or does not
		  answer. A relay redirecting with 300 Try Alternate is followed by
		  `TurnClient`.
		- The future fails only when every one has, with every reason in its
		  message and the last relay's `TurnError` -- its code, its reason, and
		  where it redirected to -- as its `cause`.
		- A relay that goes away is replaced, from the top of the list, and the
		  new relayed candidate announced through `onLocalCandidate` for the peer
		  to be told of. A connection whose path ran through the lost relay
		  still ends, since the path went with it -- unless an ICE restart is
		  under way to find another.
		- `restartIce` checks the relay is still there, and asks for another
		  when it is not, so a restart after a network change has one.
		- `setRelayCredentials` replaces the credentials for what is asked from
		  then on.

		Nothing is thrown: a list that cannot be used fails the future.
	**/
	public function gatherRelayedFrom(servers:Array<TurnServer>, useChannels:Bool = false):Future<IceCandidate> {
		var future = new Future<IceCandidate>();

		if (__host != null) {
			@:privateAccess future.__fail(SHARED_SOCKET_GATHERS_NOTHING, null);
			return future;
		}

		if (__closed || __socket == null) {
			@:privateAccess future.__fail("A relay can only be allocated through a bound connection; call bind first.", null);
			return future;
		}

		if (servers == null || servers.length == 0) {
			@:privateAccess future.__fail("A TURN server address is required.", new ArgumentError("servers"));
			return future;
		}

		for (server in servers) {
			if (server == null || server.address == null || server.address == "" || server.username == null || server.password == null) {
				@:privateAccess future.__fail("Every TURN server needs an address, a username and a password.", new ArgumentError("servers"));
				return future;
			}
		}

		// One allocation at a time: a second would leak the first. One that
		// failed or was lost is not in the way.
		if (__turn != null) {
			@:privateAccess future.__fail("This connection already has a relay allocated.", null);
			return future;
		}

		__relayServers = [
			for (server in servers)
				{
					address: server.address,
					port: server.port != null ? server.port : 3478,
					username: server.username,
					password: server.password
				}
		];
		__relayUseChannels = useChannels;
		__relayedFuture = future;
		__allocateFrom(0, []);
		return future;
	}

	/**
		Replaces the credentials relays are asked with from now on: those in the
		list `gatherRelayedFrom` was given, and the one holding the allocation.

		For credentials that expire, as the TURN REST convention's do: fetch new
		ones before they lapse and pass them here, so the next relay asked -- a
		replacement, or one for an ICE restart -- is not refused. A relay ties an
		allocation to the username that made it, so the one held now takes a new
		password for the same username and keeps its old username otherwise.

		@param server The relay these are for, as its address was given; every
		relay when omitted.
		@throws ArgumentError When either is null.
	**/
	public function setRelayCredentials(username:String, password:String, ?server:String):Void {
		if (username == null || password == null) {
			throw new ArgumentError("A relay needs credentials: it forwards traffic on somebody's behalf and has to know whose.");
		}

		if (__relayServers != null) {
			for (entry in __relayServers) {
				if (server == null || entry.address == server) {
					entry.username = username;
					entry.password = password;
				}
			}
		}

		if (__turn != null && __turnServer != null && (server == null || __turnServer.address == server) && __turnServer.username == username) {
			__turn.setCredentials(username, password);
		}
	}

	/** The relayed candidate, once a server has granted one; null again if that relay goes. **/
	public var relayedCandidate(get, never):Null<IceCandidate>;

	@:noCompletion private function get_relayedCandidate():Null<IceCandidate> {
		return __relayedCandidate;
	}

	/** This connection's own address, when the bind named one. **/
	@:noCompletion private var __hostCandidate:IceCandidate;

	/** The relay allocating or holding an allocation, and the server it was made for; null when there is neither. **/
	@:noCompletion private var __turn:TurnClient;

	@:noCompletion private var __turnServer:TurnServer;

	@:noCompletion private var __relayedCandidate:IceCandidate;

	/** How to send from `__relayedCandidate`, handed to each agent with it. **/
	@:noCompletion private var __relaySend:(ByteArray, String, Int) -> Void;

	@:noCompletion private var __relayedFuture:Future<IceCandidate>;

	/** The relays `gatherRelayedFrom` was given, asked again to replace one that goes. **/
	@:noCompletion private var __relayServers:Array<TurnServer>;

	@:noCompletion private var __relayUseChannels:Bool = false;

	/** Whether the nominated pair reaches the peer through the relay. **/
	@:noCompletion private var __peerRelayed:Bool = false;

	/**
		Asks the relay at `index` in the list, and the next when it fails.

		@param failures What each relay asked so far said, for the message the
		future fails with when none will.
	**/
	@:noCompletion private function __allocateFrom(index:Int, failures:Array<TurnError>):Void {
		if (__closed) {
			return;
		}

		if (index >= __relayServers.length) {
			__settleRelayed(null, "No relay would allocate: " + [for (failure in failures) failure.toString()].join("; ") + ".",
				failures.length > 0 ? failures[failures.length - 1] : null);
			return;
		}

		var server = __relayServers[index];
		var relay = new TurnClient(server.address, server.port, server.username, server.password);
		relay.useChannels = __relayUseChannels;
		__turn = relay;
		__turnServer = server;

		// Out to the server directly. The relay is reached the ordinary way; it
		// is only traffic for a peer that gets wrapped.
		relay.onSend = function(payload:ByteArray, address:String, sendPort:Int):Void {
			__send(payload, address, sendPort);
		};

		relay.onData = function(payload:ByteArray, fromAddress:String, fromPort:Int):Void {
			if (relay == __turn) {
				__onRelayed(payload, fromAddress, fromPort);
			}
		};

		relay.onLost = function(reason:String):Void {
			__relayLost(relay, reason);
		};

		// One peer address the relay will not forward to -- a hardened relay
		// refuses private ones, and ICE pairs the relayed candidate with the
		// peer's host addresses first. Those pairs are dead, and the rest of the
		// relay is fine; said to the agents so they stop checking into nothing.
		relay.onPermissionRefused = function(peerAddress:String, code:Int, reason:String):Void {
			if (__closed || relay != __turn || __relayedCandidate == null) {
				return;
			}

			agent.refusePairs(__relayedCandidate, peerAddress);

			if (__restartAgent != null) {
				__restartAgent.refusePairs(__relayedCandidate, peerAddress);
			}
		};

		relay.allocated.then(function(relayed:ReflexiveAddress):Void {
			__relayGranted(relay, relayed);
		}, function(error:String):Void {
			// Replaced, or closed with the connection: nothing to go on to.
			if (relay != __turn || __closed) {
				return;
			}

			__turn = null;
			__turnServer = null;
			failures.push(relay.failure != null ? relay.failure : new TurnError(0, error, server.address + ":" + server.port));
			__allocateFrom(index + 1, failures);
		});

		relay.allocate(__clock());
	}

	/** A relay lent an address: it becomes a candidate, with the way to send from it. **/
	@:noCompletion private function __relayGranted(relay:TurnClient, relayed:ReflexiveAddress):Void {
		if (__closed || relay != __turn) {
			return;
		}

		var candidate = new IceCandidate(RELAYED, relayed.address, relayed.port);
		__relayedCandidate = candidate;

		// The candidate and the way to send from it, together: its address is
		// the server's, so a datagram addressed there straightforwardly would
		// arrive at the relay as ordinary traffic rather than as something to
		// forward. Bound to this relay, so a check on the candidate of one that
		// has since gone is dropped rather than sent through its replacement.
		__relaySend = function(payload:ByteArray, address:String, peerPort:Int):Void {
			if (relay == __turn) {
				__relayTo(payload, address, peerPort);
			}
		};

		agent.addLocalCandidate(candidate, __relaySend);

		if (__restartAgent != null) {
			__restartAgent.addLocalCandidate(candidate, __relaySend);
		}

		__gained(candidate);
		__settleRelayed(candidate, null, null);
	}

	/**
		A relay that was carrying an allocation lost it.

		A path through the relay ends with the relay, with no goodbye: what
		would carry it is what just went. Unless an ICE restart is under way,
		which is often why the relay went -- a network change moves the 5-tuple
		it knew this connection by -- and the restart decides. Otherwise the
		connection loses a candidate it no longer needs and asks for another,
		so a later restart, or checking still under way, has one.
	**/
	@:noCompletion private function __relayLost(relay:TurnClient, reason:String):Void {
		if (__closed || relay != __turn) {
			return;
		}

		__turn = null;
		__turnServer = null;

		if (__relayedCandidate != null) {
			__localCandidates.remove(__relayedCandidate);
		}

		__relayedCandidate = null;
		__relaySend = null;

		if (__peerRelayed && __restartAgent == null) {
			__shutdown("The relay carrying this connection went away: " + reason, false, false);
			return;
		}

		if (__relayServers != null) {
			__allocateFrom(0, []);
		}
	}

	/**
		For an ICE restart: a relay that is there is asked whether it still is,
		and one that is not is replaced.
	**/
	@:noCompletion private function __renewRelay():Void {
		if (__closed || __relayServers == null) {
			return;
		}

		if (__turn == null) {
			__allocateFrom(0, []);
			return;
		}

		__turn.refresh(__clock());
	}

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

		// Every time, which costs a lookup: TurnClient sends nothing for a
		// permission already in place, already being asked for, or refused.
		// It was asked once per address here, so a request the relay never
		// answered, or one dropped from a full queue, was never asked again.
		// Renewal is TurnClient's too, on its own tick, so that a connection
		// that only receives keeps its peer permitted.
		__turn.permit(address, now);

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

			if (__restartAgent != null) {
				payload.position = 0;
				__restartAgent.receive(payload, fromAddress, fromPort, now, __relayedCandidate);
			}

			return;
		}

		if (first >= 20 && first <= 63 && __dtls != null) {
			__dtls.receive(payload, now);
		}
	}

	@:noCompletion private function __settleRelayed(candidate:Null<IceCandidate>, error:String, ?cause:TurnError):Void {
		var future = __relayedFuture;
		__relayedFuture = null;

		if (future == null) {
			return;
		}

		if (candidate == null) {
			@:privateAccess future.__fail(error, cause);
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
		__receiveDatagram(e.data, e.srcAddress, e.srcPort);
	}

	/** A datagram from this connection's own socket, or routed here by its host. **/
	@:noCompletion private function __receiveDatagram(data:ByteArray, srcAddress:String, srcPort:Int):Void {
		if (__closed || data == null || data.length == 0) {
			return;
		}

		var now:Float = haxe.Timer.stamp();

		data.position = 0;
		var first:Int = data.readUnsignedByte();
		data.position = 0;

		if (first < 4) {
			// The answer to this connection's own question about its address,
			// if that is what it is. Offered here first because it shares the
			// socket and the byte range with everything ICE sends; the
			// transaction says which, and the agent would only refuse it.
			if (__receiveReflexive(data, now)) {
				return;
			}

			// Then the relay, which recognises its own by message type and hands
			// back anything else. Its replies and the traffic it forwards share the
			// STUN byte range with every connectivity check on this socket, and
			// where they came from cannot decide it -- the server may have been
			// named as a hostname, and it answers from whatever that resolved to.
			data.position = 0;

			if (__turn != null && __turn.receive(data, srcAddress, srcPort, now)) {
				return;
			}

			data.position = 0;
			agent.receive(data, srcAddress, srcPort, now);

			// And the restart's, which checks with other credentials: each agent
			// takes only checks addressed to its own and answers to its own.
			if (__restartAgent != null) {
				data.position = 0;
				__restartAgent.receive(data, srcAddress, srcPort, now);
			}

			return;
		}

		// A relay's ChannelData, which is neither STUN nor DTLS and says so by
		// where its first byte lands: RFC 7983 leaves 64 to 127 free, and RFC
		// 8656 puts channel numbers there for exactly this reason.
		if (first >= 0x40 && first <= 0x7F) {
			if (__turn != null) {
				__turn.receive(data, srcAddress, srcPort, now);
			}

			return;
		}

		if (first >= 20 && first <= 63 && __dtls != null) {
			__dtls.receive(data, now);
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

		__route(pair);

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

		// The peer's close_notify or a fatal alert. The association inside
		// cannot outlive the session carrying it.
		__dtls.onClose = reason -> __fail(reason);

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

		// The peer's ABORT, or data it stopped acknowledging.
		__association.onClose = reason -> __fail(reason);

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
		__transfer.peerMaxMessageSize = __peerMaxMessageSize;
		// RFC 8832: the DTLS client takes the even streams. Two peers that
		// disagreed about which of them that is would collide on every channel
		// they opened at the same moment.
		__channels = new DataChannelSet(__transfer, dtlsClient);
		__channels.onChannel = channel -> onChannel(channel);

		connected = true;
		@:privateAccess ready.__resolve(this);
	}

	@:noCompletion private function __send(payload:ByteArray, address:String, port:Int):Void {
		// Not refused once closing has begun: the ABORT and the close_notify
		// are sent from inside __shutdown, after the flag is up. The socket
		// is dropped as the last step, and that is what ends sending.
		if (__host != null) {
			@:privateAccess __host.__send(payload, address, port);
			return;
		}

		if (__socket == null) {
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

	/** How far a connection that is not ready got, for the reason it gives up with. **/
	@:noCompletion private function __phase():String {
		if (__dtls == null) {
			return "no path to the peer was found";
		}

		if (__association == null) {
			return "the DTLS handshake did not complete";
		}

		return "the SCTP association did not open";
	}

	@:noCompletion private function __fail(reason:String):Void {
		// With the reason rather than through close(), which only knows that
		// the connection was closed: `ready`, `closed` and `onClose` all carry
		// what actually went wrong.
		__shutdown(reason, true, false);
	}
}
#end
