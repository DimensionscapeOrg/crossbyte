package crossbyte.net;

// Not built for the browser: it listens, over UDP, neither of which a page can do.
#if !(js && !nodejs)

import crossbyte.Future;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunQuery;
import crossbyte.net.ice.IceAgent;
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import haxe.ds.StringMap;
import crossbyte._internal.net.IPv6;
#if !nodejs
import crossbyte._internal.net.Resolver;
import sys.net.Host;
#end

@:access(crossbyte.net.ReliableDatagramSocket)
/**
	The `ReliableDatagramServerSocket` class accepts reliable UDP sessions from
	remote peers on top of a single bound `DatagramSocket`.
	Each accepted peer is represented by a `ReliableDatagramSocket` and is exposed
	through `ReliableDatagramSocketConnectEvent.CONNECT` once the reliable handshake
	completes.
	The accepted socket mode is controlled by `socketMode`, allowing the server to
	accept either datagram-style or stream-style sessions.
	@event close Dispatched when the server socket is closed.
	@event connect Dispatched when a remote reliable session completes its handshake.
**/
class ReliableDatagramServerSocket extends EventDispatcher {
	/**
		Indicates whether reliable UDP server sockets are supported by the current target.
	**/
	public static var isSupported(default, null):Bool = DatagramSocket.isSupported;

	/**
		Indicates whether the underlying UDP transport is currently bound.
	**/
	public var bound(get, never):Bool;

	/**
		Indicates whether the server is currently listening for reliable connection attempts.
	**/
	public var listening(default, null):Bool = false;

	/**
		The local IP address on which the server is bound.
	**/
	public var localAddress(get, never):String;

	/**
		The local UDP port on which the server is bound.
	**/
	public var localPort(get, never):Int;

	/**
		The mode applied to newly accepted `ReliableDatagramSocket` instances.
		Set this before calling `listen()`.
	**/
	public var socketMode:ReliableDatagramSocketMode = DATAGRAM;

	/**
		`ReliableDatagramSocket.keepAliveInterval` for each session this
		server accepts or dials, in seconds. Set it before the sessions it is
		for arrive; one already here keeps its own, which can be changed on it.
	**/
	public var keepAliveInterval:Float = ReliableDatagramSocket.DEFAULT_KEEP_ALIVE_INTERVAL;

	/**
		`ReliableDatagramSocket.idleTimeout` for each session this server
		accepts or dials, in seconds, as `keepAliveInterval` is.
	**/
	public var idleTimeout:Float = ReliableDatagramSocket.DEFAULT_IDLE_TIMEOUT;

	@:noCompletion private var __closed:Bool = false;

	// A FIN, written once, for peers that send as though they had a session
	// here and have none.
	@:noCompletion private var __resetScratch:ByteArray;
	/** Half-open inbound sessions allowed at once. */
	public static inline var DEFAULT_MAX_PENDING_CONNECTIONS:Int = 256;

	/**
		Inbound sessions that may be waiting to finish a handshake at once,
		after which a CONNECT from an address with no session is dropped.
		Negative disables the check.

		A CONNECT costs the sender one datagram and costs this side a session
		holding two timers for `timeout` milliseconds -- and UDP lets a sender
		write whatever it likes in the source field, so at that point nothing
		about the peer has been established. Without a ceiling one peer can
		spend a packet each on as many of these as it cares to, from addresses
		that never sent anything.

		Dropped rather than refused, because a refusal is itself a datagram to
		an address that may never have asked for one.
	**/
	public var maxPendingConnections:Int = DEFAULT_MAX_PENDING_CONNECTIONS;

	/**
		The operating system's receive buffer, in bytes, for the one socket
		every session of this server reads from; see
		`DatagramSocket.receiveBufferSize`. At least
		`ReliableDatagramSocket.WINDOW_BUFFER_SIZE` where the system grants it,
		which is one window: a server whose peers send at once may want room
		for several.
	**/
	public var receiveBufferSize(get, set):Int;

	/**
		The operating system's send buffer, in bytes, for this server's socket;
		see `DatagramSocket.sendBufferSize`.
	**/
	public var sendBufferSize(get, set):Int;

	@:noCompletion private inline function get_receiveBufferSize():Int {
		return __socket != null ? __socket.receiveBufferSize : 0;
	}

	@:noCompletion private function set_receiveBufferSize(value:Int):Int {
		return __socket.receiveBufferSize = value;
	}

	@:noCompletion private inline function get_sendBufferSize():Int {
		return __socket != null ? __socket.sendBufferSize : 0;
	}

	@:noCompletion private function set_sendBufferSize(value:Int):Int {
		return __socket.sendBufferSize = value;
	}

	/**
		Decides whether a CONNECT from an address with no session opens one,
		from the address and what the sender's `connect` passed with it. Called
		before anything is allocated for it; return `false` and the datagram is
		dropped, as it is when `maxPendingConnections` is reached. The default
		admits everything.

		The payload is empty when the sender passed nothing, as a peer on an
		older build always does. It is read from its start, and whatever this
		reads, the admitted session's `connectPayload` begins at the start
		again. A CONNECT carrying more than one frame's worth is dropped
		without asking, since no `connect` can send one.

		Neither is proof of anything yet. The address is only a claim -- UDP
		lets a sender write whatever it likes in the source field -- so use it
		to drop traffic, not to accuse anyone: a block list or a `RateLimiter`
		keyed by address protects this side, but an address refused here may
		belong to someone who never sent a thing. And the payload crossed the
		network in the clear, so anyone who saw it can send it again: a token
		this checks should be one only this side could have issued, and short
		lived, or bound to the address it was issued to. This runs for every
		CONNECT from a new address, which is the packet a flood is made of, so
		keep it cheap -- or put a `RateLimiter` in front of anything that is
		not, such as checking a signature.

		A hook that throws refuses the CONNECT.
	**/
	public dynamic function admit(address:String, port:Int, payload:ByteArray):Bool {
		return true;
	}

	/**
		The congestion policy for a session this server accepts or dials,
		given the peer's address and port: a new `CongestionControl` each,
		which is TCP's Reno, unless this is replaced. A server that knows some
		of its peers are on lossy links -- a mobile network, say -- can give
		those a `LossTolerantCongestionControl` and everyone else the default.
		`null` means the default.

		Called once a session, before its handshake. Return a new instance
		each time: a policy keeps the state of the one session it serves. For
		an accepted session a hook that throws refuses the CONNECT, as `admit`
		does; for one dialled by address the throw reaches the caller of
		`connect`, and for one dialled by name -- asked about once the name is
		looked up -- it is reported as that session's `ioError`, and the
		session closed.
		A session's policy can also be changed later, through
		`ReliableDatagramSocket.congestionControl` -- once the peer has said
		in its `connectPayload` what kind of link it is on, for instance.
	**/
	public dynamic function congestionControlFor(address:String, port:Int):CongestionControl {
		return new CongestionControl();
	}

	@:noCompletion private var __connections:StringMap<ReliableDatagramSocket>;

	// Sessions dialled by name whose names are still being looked up. They
	// have no endpoint to be filed under in `__connections` until the answer
	// comes, and are kept here meanwhile so that close() reaches them.
	@:noCompletion private var __dialling:Array<ReliableDatagramSocket> = null;

	// Keys of accepted sessions that have not finished handshaking. Counted
	// alongside rather than measured, because measuring means walking the
	// map on every CONNECT, which is the packet a flood sends most of.
	@:noCompletion private var __pending:StringMap<Bool>;
	@:noCompletion private var __pendingCount:Int = 0;

	// One outstanding reflexive-address query, if any. Held here rather than in
	// a client of its own because the question is about this socket's port, and
	// only this class can ask from it.
	/**
		The question outstanding, if one is: its transaction, its schedule, and
		how to read a reply. See `StunQuery`, which the other two places that
		ask a STUN server share.
	**/
	@:noCompletion private var __stunQuery:StunQuery;

	@:noCompletion private var __stunFuture:Future<ReflexiveAddress>;
	@:noCompletion private var __stunTick:TickEvent->Void;

	// An attached agent, and the tick that moves its clock. Separate from the
	// reflexive query above: that one asks a server a single question, this one
	// runs an exchange with a peer for as long as it takes.
	@:noCompletion private var __ice:IceAgent;
	@:noCompletion private var __iceTick:TickEvent->Void;
	@:noCompletion private var __socket:DatagramSocket;

	/**
		Creates a new reliable datagram server socket.
	**/
	public function new() {
		super();

		__connections = new StringMap();
		__pending = new StringMap();
		__socket = new DatagramSocket();
		ReliableDatagramSocket.__reserveWindow(__socket);
	}

	/**
		Binds the server to a local UDP address and port.
		@param localPort The local port to bind to. Use `0` to allow the operating system to choose a free port.
		@param localAddress The local address to bind to. Use `"0.0.0.0"` to bind on all IPv4 interfaces.
		@throws IOError If the server has already been closed or the bind fails.
	**/
	public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		if (__closed) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__socket.bind(localPort, localAddress);
	}

	/**
		Stops listening, closes every reliable session -- each sending its
		peer a FIN, after whatever it had waiting -- and closes the underlying
		UDP transport.
	**/
	public function close():Void {
		if (__closed) {
			return;
		}

		__closed = true;
		listening = false;
		try {
			__socket.removeEventListener(DatagramSocketDataEvent.DATA, __onData);
		} catch (_:Dynamic) {}

		__settleStun(null, "The server socket closed before the STUN server replied.");
		detachIceAgent();

		var connections:Array<ReliableDatagramSocket> = [];
		for (connection in __connections) {
			connections.push(connection);
		}
		// And those still looking their peer's name up, which are this
		// server's as much, though filed under no endpoint yet.
		if (__dialling != null) {
			for (connection in __dialling) {
				connections.push(connection);
			}
			__dialling = null;
		}
		__connections = new StringMap();
		__pending = new StringMap();
		__pendingCount = 0;

		// Closed, not just disposed: close() tells the peer, which disposing
		// did not, so every client of a server that shut down went on
		// sending into a closed port until its own timeout said the session
		// was gone.
		for (connection in connections) {
			try {
				connection.close();
			} catch (_:Dynamic) {}
		}

		try {
			__socket.close();
		} catch (_:Dynamic) {}
		dispatchEvent(new Event(Event.CLOSE));
	}

	/**
		Begins listening for reliable UDP connection attempts on the bound transport.
		Incoming handshakes that complete successfully dispatch
		`ReliableDatagramSocketConnectEvent.CONNECT`.
		@throws IOError If the server is closed or has not been bound yet.
	**/
	public function listen():Void {
		if (__closed) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (!bound) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (listening) {
			return;
		}

		listening = true;
		__socket.addEventListener(DatagramSocketDataEvent.DATA, __onData);
		__socket.receive();
	}

	/**
		Opens a reliable session to `address`:`port` from the port this server is
		already bound to.

		The distinction from `ReliableDatagramSocket.connect` is the local port.
		That call makes its own transport and so leaves from an arbitrary port;
		this one leaves from the one peers already reach this server on. For a
		peer-to-peer mesh that difference is the whole thing: hole punching
		works only when the port a peer dials out from is the port it is
		reachable on, and a NAT will only hold that mapping open for one socket.

		The returned session is registered with this server, so its replies
		arrive through the same data pump that feeds accepted sessions. It is
		reported through `ReliableDatagramSocketConnectEvent.CONNECT` when the
		handshake completes, exactly as an accepted one is, and it takes
		`socketMode` for the same reason.

		Requires `listen()`: the server's pump is what routes the replies, so a
		session dialled from a bound-but-not-listening server would send its
		handshake and never hear the answer.

		`address` may be a name everywhere but Node, and it is not looked up
		on the runtime's thread: the session is returned at once, and filed
		under the address the name resolves to, its handshake begun, when the
		answer comes. Until then its `remoteAddress` reads empty; its timeout
		counts the lookup. What this call throws for an address it reports on
		such a session instead, as an `ioError` event followed by the
		session's close: a name that does not resolve, an endpoint that has a
		session here already, and a `congestionControlFor` that throws. On a
		thread with no CrossByte runtime a name is looked up in the call, as
		it always was.

		@param address The peer's address, or a name.
		@param timeoutMs Session timeout in milliseconds, or `0` for the default.
		@param payload Sent with every CONNECT, as `ReliableDatagramSocket.connect`
		       sends it: copied now, and at most one frame.
		@throws IOError if this server is closed, unbound, or not listening.
		@throws ArgumentError if the address is malformed, or -- on Node -- a
		name, or if a session to this endpoint already exists.
		@throws RangeError if `payload` is larger than one frame.
	**/
	public function connect(address:String, port:Int, timeoutMs:Int = 0, ?payload:ByteArray):ReliableDatagramSocket {
		if (__closed) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (!bound) {
			throw new IOError("Cannot dial from a server socket that is not bound.");
		}

		if (!listening) {
			throw new IOError("Cannot dial from a server socket that is not listening: replies are routed by the listen pump, so nothing would deliver them.");
		}

		var outgoing:ByteArray = ReliableDatagramSocket.__connectPayloadOf(payload);

		var resolved:String;

		#if nodejs
		// Same rule the socket's own connect() states: a session is matched
		// against the address replies arrive from, and resolving a name on Node
		// needs a callback this call cannot wait for.
		if (!IPv6.isNumericAddress(address)) {
			throw new ArgumentError("A reliable datagram session needs a numeric address on Node, not a name: the session is matched against the address replies arrive from, and resolving a name there needs a callback this call cannot wait for.");
		}

		resolved = address;
		#else
		// Without a runtime on this thread there is nothing to hand an answer
		// back to, so a name is looked up here, as it always was.
		if (Resolver.needsLookup(address) && Resolver.runtimeHere() != null) {
			return __dialByName(address, port, timeoutMs, outgoing);
		}

		try {
			resolved = new Host(address).toString();
		} catch (_:Dynamic) {
			throw new ArgumentError("One of the parameters is invalid");
		}
		#end

		var key:String = __endpointKey(resolved, port);

		// Refused rather than replaced. A second session to an endpoint that
		// already has one would take over its routing entry and strand the
		// first, which is a difficult thing to notice from the outside.
		if (__connections.exists(key)) {
			throw new ArgumentError("A reliable datagram session to " + key + " already exists on this server.");
		}

		var socket = ReliableDatagramSocket.__createDialed(__socket, resolved, port, this, socketMode, timeoutMs, outgoing,
			congestionControlFor(resolved, port));
		__connections.set(key, socket);
		return socket;
	}

	#if !nodejs
	/**
		`connect()` to a name: the session is made and returned now, and the
		name looked up off the runtime's thread (see `Resolver`); the session
		is filed under the address it resolves to, and its handshake begun,
		when the answer comes.

		It used to be looked up in the call, on the runtime's thread, so every
		session this server carries waited on the resolver -- a second, for a
		name that does not exist. What the call refused by throwing it now
		reports on the session, which it has already handed over: a name that
		does not resolve, an endpoint with a session here already, and a
		`congestionControlFor` that throws, each asked about only once the
		address is known.
	**/
	@:noCompletion private function __dialByName(name:String, port:Int, timeoutMs:Int, outgoing:ByteArray):ReliableDatagramSocket {
		var socket = ReliableDatagramSocket.__createDialed(__socket, null, port, this, socketMode, timeoutMs, outgoing, null);
		if (__dialling == null) {
			__dialling = [];
		}
		__dialling.push(socket);

		Resolver.resolve(name, function(host:Null<Host>, failure:Null<String>):Void {
			// Closed meanwhile -- the session, the server with it, or the
			// attempt at its deadline -- and taken off the list then.
			if (__dialling == null || !__dialling.remove(socket)) {
				return;
			}

			if (host == null) {
				__refuseDialled(socket, "Could not connect to " + name + ": the name did not resolve (" + failure + ")");
				return;
			}

			// As the address arrives from the socket, so the session is found
			// by it.
			var resolved:String = IPv6.compress(host.toString());
			var key:String = __endpointKey(resolved, port);
			if (__connections.exists(key)) {
				__refuseDialled(socket, "Could not connect to " + name + ": a reliable datagram session to " + key + " already exists on this server.");
				return;
			}

			var congestion:CongestionControl = null;
			try {
				congestion = congestionControlFor(resolved, port);
			} catch (e:Dynamic) {
				__refuseDialled(socket, "Could not connect to " + name + ": congestionControlFor threw " + Std.string(e));
				return;
			}

			__connections.set(key, socket);
			socket.__beginDialled(resolved, congestion);
		});

		return socket;
	}

	/**
		Tells a session dialled by name why it cannot go ahead, and closes it.
		Its address is never set, so closing it disturbs no session filed under
		the endpoint it would have had.
	**/
	@:noCompletion private static function __refuseDialled(socket:ReliableDatagramSocket, reason:String):Void {
		socket.dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, reason));
		socket.__dispose(true);
	}
	#end

	/**
		Asks a STUN server what address and port this server appears as from
		outside.

		The answer is about *this* socket, which is the only reason this lives
		here rather than in a client of its own. A NAT holds one mapping per
		socket, so a reflexive address discovered on some other port describes
		somewhere nobody can reach this server -- and the port peers dial is
		this one. `StunClient` binds its own socket and answers the more general
		"what is my public address"; this answers "where can I be reached", and
		for a peer-to-peer mesh only the second one is actionable.

		The request goes out through the bound socket and the reply is picked
		out of ordinary inbound traffic by its transaction id, so an ongoing
		query costs no extra socket and does not disturb any session.

		One at a time: a second call while one is outstanding is refused rather
		than queued, because the two would race for the same reply.

		`server` may be a name. It is looked up off the runtime's thread
		before the question is asked, within `timeoutMs`, and a name that does
		not resolve fails the question as soon as that is known. On Node, Node
		looks the name up for each request itself, and one that does not
		resolve leaves the question to its deadline.

		@throws IOError if this server is closed, unbound, or not listening.
	**/
	public function discoverPublicAddress(server:String, port:Int = 3478, timeoutMs:Int = 3000):Future<ReflexiveAddress> {
		var future = new Future<ReflexiveAddress>();

		if (__closed || !bound || !listening) {
			@:privateAccess future.__fail("A reflexive address can only be discovered from a bound, listening server socket.",
				new IOError("Operation attempted on invalid socket."));
			return future;
		}

		if (server == null || server == "") {
			@:privateAccess future.__fail("A STUN server address is required.", new ArgumentError("server"));
			return future;
		}

		if (__stunFuture != null) {
			@:privateAccess future.__fail("A reflexive address query is already outstanding on this server socket.", null);
			return future;
		}

		// The transaction id is what the reply will be believed by, and a weak
		// one would let an off-path party who can guess it answer with an
		// address of its choosing. Refusing beats falling back: this target
		// still runs the reliable protocol -- its sequence seeds degrade
		// deliberately, being hardening rather than the security boundary --
		// but discovery's answer is only worth having if it cannot be forged.
		if (!crossbyte.crypto.SecureRandom.isSupported) {
			@:privateAccess future.__fail("Discovering a public address needs a cryptographically secure random source for the "
				+ "STUN transaction id, which this target does not have.", null);
			return future;
		}

		var query = new StunQuery(haxe.Timer.stamp(), timeoutMs);
		__stunQuery = query;
		__stunFuture = future;

		var runtime:CrossByte = CrossByte.current();

		// Where the question goes: `server`, or for a name the address it
		// resolves to, null until then. The send used to be given the name,
		// and looked it up off the runtime's thread -- but a name that did not
		// resolve then failed as an ioError on the socket every session
		// shares, which told this question nothing, so it waited out its whole
		// deadline. Looked up here, the failure is this question's.
		var target:Null<String> = server;
		#if !nodejs
		if (Resolver.needsLookup(server)) {
			target = null;
		}
		#end

		function ask():Void {
			var payload:ByteArray = query.request.encode();
			__socket.send(payload, 0, payload.length, target, port);
		}

		__stunTick = function(_:TickEvent):Void {
			if (__stunFuture == null) {
				return;
			}

			var now:Float = haxe.Timer.stamp();

			if (query.expired(now)) {
				// UDP reports nothing when it is dropped, so a silent network
				// and a wrong server address look identical from here; the
				// deadline is the only thing that ends this.
				__settleStun(null, "No reply from the STUN server at " + server + ":" + port + " within " + timeoutMs + "ms.");
				return;
			}

			// Nothing to ask again before the name is looked up.
			if (target != null && query.shouldRetransmit(now)) {
				try {
					ask();
				} catch (e:Dynamic) {
					__settleStun(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e));
				}
			}
		};

		runtime.addEventListener(TickEvent.TICK, __stunTick);

		#if !nodejs
		if (target == null) {
			Resolver.resolve(server, function(host:Null<Host>, failure:Null<String>):Void {
				// Settled meanwhile -- at its deadline, or with the server --
				// or a later question asked since.
				if (__stunQuery != query) {
					return;
				}

				if (host == null) {
					__settleStun(null, "Could not ask " + server + ":" + port + " for a reflexive address: the name did not resolve (" + failure + ")");
					return;
				}

				target = host.toString();
				try {
					ask();
				} catch (e:Dynamic) {
					__settleStun(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e));
				}
			});
			return future;
		}
		#end

		try {
			ask();
		} catch (e:Dynamic) {
			__settleStun(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e));
		}

		return future;
	}

	/**
		The address a peer at `destination` would reach this server on, without
		leaving the local network.

		The other candidate a peer can offer, and the one `discoverPublicAddress`
		cannot produce. Two peers behind the same NAT discover reflexive
		addresses on its outside, and dialling those means asking the NAT to
		route a packet back in to the network it came from -- hairpinning, which
		plenty of consumer equipment does not do. They are usually sitting on the
		same subnet, one hop apart, and the address that works is the local one.

		Unlike the reflexive answer this needs nothing on the network and no
		server: it is a routing table lookup, and the socket it asks with sends
		no packet. `destination` need not even be reachable.

		The port is not part of the answer, and that absence is the point. A
		reflexive address comes back with a translated port because a NAT
		assigned one; nothing translates a local address, so the port a peer
		should dial is `localPort` and no query is needed to learn it.

		@param destination The peer's address, numeric. Which one it is matters:
		a peer on this subnet and a peer across the internet are reached on
		different interfaces, and this answers for the one named.
		@throws IOError if this server is closed, unbound, or not listening --
		in which case `localPort` is not settled either, so the answer would have
		nothing to pair with.
	**/
	public function localAddressFor(destination:String):Future<String> {
		if (__closed || !bound || !listening) {
			var future = new Future<String>();
			@:privateAccess future.__fail("A local address can only be reported for a bound, listening server socket.",
				new IOError("Operation attempted on invalid socket."));
			return future;
		}

		return LocalAddress.forDestination(destination);
	}

	/**
		Runs an ICE agent over the socket this server already listens on.

		This is the join between the two halves. The agent knows how to find a
		path and nothing about sockets; the server holds the one socket that can
		be used to look. Attaching wires the three things the agent needs: its
		checks go out through this socket, STUN arriving here is handed to it,
		and its clock is driven from the runtime tick.

		It has to be *this* socket. A NAT keeps one mapping per socket, so a
		check sent from anywhere else opens a hole for a port the peer was never
		told about, and the path it proves would not be the path the session
		then uses.

		Checks are separated from ordinary traffic before the reliable decode,
		because a STUN message is not a reliable frame and would otherwise be
		dropped as noise -- and, in the other direction, anything the agent does
		not recognise is passed straight on, since a peer keeps checking while
		its session is already carrying data.

		```haxe
		var agent = new IceAgent(controlling);
		server.attachIceAgent(agent);

		agent.connected.then(function(pair) {
			var session = server.connect(pair.remote.address, pair.remote.port);
		});
		```

		@param agent The agent to run. Its `onSend` is replaced.
		@throws IOError if this server is closed, unbound, or not listening --
		the socket has to exist before anything can be sent from it.
		@throws ArgumentError if an agent is already attached. Two agents on one
		socket would each answer the other's checks.
	**/
	public function attachIceAgent(agent:IceAgent):Void {
		if (agent == null) {
			throw new ArgumentError("An agent is required.");
		}

		if (__closed || !bound || !listening) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (__ice != null) {
			throw new ArgumentError("An ICE agent is already attached to this server socket.");
		}

		__ice = agent;

		agent.onSend = function(payload:ByteArray, address:String, port:Int):Void {
			if (__closed) {
				return;
			}

			try {
				__socket.send(payload, 0, payload.length, address, port);
			} catch (_:Dynamic) {
				// A check to an address that cannot be routed is an ordinary
				// outcome of trying every candidate, not a fault. The agent's
				// own retransmission budget is what decides that pair is dead.
			}
		};

		__iceTick = function(_:TickEvent):Void {
			agent.poll(haxe.Timer.stamp());
		};

		CrossByte.current().addEventListener(TickEvent.TICK, __iceTick);
	}

	/**
		Stops running an attached agent, leaving the socket otherwise untouched.

		The agent itself is not closed: a caller may want to inspect what it
		found. Detaching only stops this server driving it.
	**/
	public function detachIceAgent():Void {
		if (__iceTick != null) {
			try {
				CrossByte.current().removeEventListener(TickEvent.TICK, __iceTick);
			} catch (_:Dynamic) {}

			__iceTick = null;
		}

		if (__ice != null) {
			__ice.onSend = function(_, _, _):Void {};
			__ice = null;
		}
	}

	@:noCompletion private function __settleStun(address:Null<ReflexiveAddress>, error:String):Void {
		var future = __stunFuture;

		if (future == null) {
			return;
		}

		__stunFuture = null;
		__stunQuery = null;

		if (__stunTick != null) {
			try {
				CrossByte.current().removeEventListener(TickEvent.TICK, __stunTick);
			} catch (_:Dynamic) {}

			__stunTick = null;
		}

		if (address != null) {
			@:privateAccess future.__resolve(address);
		} else {
			@:privateAccess future.__fail(error, null);
		}
	}

	/**
		Whether this datagram was the reply to an outstanding STUN query.

		Checked before the reliable-protocol decode, because a STUN message is
		not one of those and would otherwise be dropped as noise -- which is
		exactly what happened to it before this existed.
	**/
	@:noCompletion private function __takeStunReply(data:ByteArray):Bool {
		if (__stunFuture == null || __stunQuery == null) {
			return false;
		}

		// Not STUN, or an answer to somebody else's question, stays somebody
		// else's: the transaction check is what stops an unrelated sender
		// handing this server an address it would then publish to every peer.
		switch (__stunQuery.interpret(data)) {
			case NOT_OURS:
				return false;
			case ANSWERED(address):
				__settleStun(address, null);
			case REFUSED(reason):
				__settleStun(null, "The STUN server refused the request" + (reason != null ? ": " + reason : "."));
			case ANSWERED_WITHOUT_ADDRESS:
				__settleStun(null, "The STUN server replied without a mapped address, so this socket's public address is still unknown.");
		}

		return true;
	}

	@:noCompletion private inline function __endpointKey(address:String, port:Int):String {
		return address + ":" + port;
	}

	@:noCompletion private function __onData(e:DatagramSocketDataEvent):Void {
		// Before the reliable decode: a STUN reply is not a reliable frame, so
		// it would fall through as noise.
		if (__takeStunReply(e.data)) {
			return;
		}

		// Then the agent, which takes any other STUN message: a check from a
		// peer, or an answer to one of its own. It reports whether it did, so
		// everything else falls through to the session below rather than being
		// swallowed by a component that had no use for it.
		if (__ice != null && __ice.receive(e.data, e.srcAddress, e.srcPort, haxe.Timer.stamp())) {
			return;
		}

		var key:String = __endpointKey(e.srcAddress, e.srcPort);
		var connection:ReliableDatagramSocket = __connections.get(key);

		// Several frames at once, and only ever from a session already here:
		// a peer bundles once it has heard this side, so a bundle from an
		// address with no session has nothing in it to open one with -- only
		// a peer to tell its session is gone.
		if (ReliableDatagramProtocol.isBundle(e.data)) {
			if (connection != null) {
				connection.__acceptBundle(e.data);
			} else {
				__resetStranger(null, e.srcAddress, e.srcPort);
			}
			return;
		}

		var frame = ReliableDatagramProtocol.decode(e.data);
		if (frame == null) {
			return;
		}

		if (connection != null) {
			if (frame.type != ReliableDatagramFrameType.CONNECT || !__isAnotherAttempt(connection, frame)) {
				connection.__acceptFrame(frame);
				return;
			}

			// A CONNECT with a new id, from the address and port of a session
			// already here: not from the peer that session was made for, which
			// sends its own id every time. Either that peer restarted and this
			// session is left over -- and would take every CONNECT the new one
			// sends, answer none, and be kept alive by them -- or somebody is
			// claiming the address. The old peer is asked, and the CONNECT that
			// finds no answer due replaces the session.
			if (!__replaceable(connection)) {
				return;
			}

			// Not closed: a FIN goes to the address, where the new attempt
			// would take it as the end of its own.
			connection.__dispose(true);
			connection = null;
		}

		if (frame.type != ReliableDatagramFrameType.CONNECT) {
			__resetStranger(frame, e.srcAddress, e.srcPort);
			return;
		}

		if (!listening) {
			return;
		}

		if (maxPendingConnections >= 0 && __pendingCount >= maxPendingConnections) {
			return;
		}

		// No connect() sends more than a frame, and each pending session
		// keeps what its CONNECT carried, so a larger one is not held.
		var payload:ByteArray = frame.payload;
		if (payload.length > ReliableDatagramProtocol.MAX_PAYLOAD_SIZE) {
			return;
		}

		var admitted:Bool = false;
		try {
			admitted = admit(e.srcAddress, e.srcPort, payload);
		} catch (_:Dynamic) {}
		if (!admitted) {
			return;
		}

		var congestion:CongestionControl = null;
		try {
			congestion = congestionControlFor(e.srcAddress, e.srcPort);
		} catch (_:Dynamic) {
			return;
		}

		payload.position = 0;
		connection = ReliableDatagramSocket.__createAccepted(__socket, e.srcAddress, e.srcPort, this, socketMode, payload, congestion, frame.sequence);
		connection.__peerTakesBundles = frame.bundles;
		__connections.set(key, connection);
		__pending.set(key, true);
		__pendingCount++;
	}

	/**
		Whether a CONNECT is from another attempt than the one `connection` was
		made for: both carry ids, and they differ. A CONNECT from an older
		build carries none, and is taken by the session as it always was.
	**/
	@:noCompletion private static inline function __isAnotherAttempt(connection:ReliableDatagramSocket, frame:ReliableDatagramFrame):Bool {
		var id:Int = frame.sequence;
		return id != 0 && connection.__peerConnectionId != 0 && id != connection.__peerConnectionId;
	}

	/**
		Whether a session sent a CONNECT with a new id may be replaced: asked
		its old peer whether it is still there, gave it the time to answer,
		and heard nothing. The first such CONNECT asks, and the one that finds
		the answer overdue and missing replaces it -- a restarted peer is let
		back in on its next attempt, a few seconds on. A peer still there
		answers, and keeps its session however many CONNECTs someone sends in
		its name; asking again at most once a window, so they cannot make this
		side send much.
	**/
	@:noCompletion private function __replaceable(connection:ReliableDatagramSocket):Bool {
		var now:Float = haxe.Timer.stamp();

		if (connection.__challengedAt >= 0) {
			if (now - connection.__challengedAt < connection.__challengeWindow()) {
				return false;
			}
			if (!connection.__heardSinceChallenge) {
				return true;
			}
		}

		connection.__challenge(now);
		return false;
	}

	/**
		Tells a peer sending as though it had a session here that it has none,
		with a FIN, which ends the session on its side at once.

		Without it a peer whose session this side had closed or never had --
		the server restarted, or gave the session up -- went on sending into
		nothing until its own timeout ran out. A FIN is the size of the
		smallest frame that can draw one, so answering gains a sender nothing
		it could not send itself. Never sent for a FIN: two sides that each
		thought the other a stranger would answer each other for good.
	**/
	@:noCompletion private function __resetStranger(frame:Null<ReliableDatagramFrame>, address:String, port:Int):Void {
		if (frame != null && frame.type == ReliableDatagramFrameType.FIN) {
			return;
		}

		if (__resetScratch == null) {
			__resetScratch = new ByteArray();
			__resetScratch.length = ReliableDatagramProtocol.HEADER_SIZE;
		}

		var length:Int = ReliableDatagramProtocol.encodeInto(__resetScratch, ReliableDatagramFrameType.FIN, 0, null, 0, 0, false, null, false);
		try {
			__socket.send(__resetScratch, 0, length, address, port);
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __onSocketClosed(socket:ReliableDatagramSocket):Void {
		var key:String = __endpointKey(socket.remoteAddress, socket.remotePort);
		__connections.remove(key);
		__releasePending(key);
		// One closed while its peer's name was looked up was filed only
		// here; its answer, when it comes, finds it gone.
		if (__dialling != null) {
			__dialling.remove(socket);
		}
	}

	// Removal answers whether it was still pending, so this stays exact
	// however a session leaves: handshake done, timed out, or closed under it.
	@:noCompletion private function __releasePending(key:String):Void {
		if (__pending.remove(key)) {
			__pendingCount--;
		}
	}

	@:noCompletion private function __onSocketConnected(socket:ReliableDatagramSocket):Void {
		// The peer answered, so the address is its own and the slot is free
		// again. Done before the outgoing check below, which returns early.
		__releasePending(__endpointKey(socket.remoteAddress, socket.remotePort));

		// Only sessions a peer opened to us. A session `connect()` dialled is
		// registered here too, because that is how its replies get routed, but
		// it was initiated rather than accepted -- and whoever dialled it
		// already holds it. Announcing it as a new arrival would have every
		// caller wire it up twice.
		if (!socket.__incoming) {
			return;
		}

		dispatchEvent(new ReliableDatagramSocketConnectEvent(ReliableDatagramSocketConnectEvent.CONNECT, socket));
	}

	@:noCompletion private inline function get_bound():Bool {
		return !__closed && __socket.bound;
	}

	@:noCompletion private inline function get_localAddress():String {
		return __socket.localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return __socket.localPort;
	}
}
#end
