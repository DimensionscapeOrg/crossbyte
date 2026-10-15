package crossbyte.net;

import crossbyte.Future;

/**
 * Common listener contract for server-side transport hosts.
 *
 * Hosts accept incoming client transports and surface them through the
 * `onAccept` callback. Connection shutdowns are reported through
 * `onDisconnect`, while listener failures are reported through `onError`.
 *
 * A member that answers with a `Future` reports every failure through it
 * (a refusal included, as a `Future` failed with the error as its `cause`)
 * and never throws. The others throw.
 */
interface INetHost {
	/** Bound local address. */
	public var localAddress(get, never):String;
	/** Bound local port. */
	public var localPort(get, never):Int;
	/** `true` while the underlying listener is accepting connections. */
	public var isRunning(get, null):Bool;
	/** Transport protocol served by this host. */
	public var protocol(default, null):Protocol;
	/**
		The most connections the host serves at once; `0` or less sets no
		limit. 10,000 by default (`ServerSocket.DEFAULT_MAX_CONNECTIONS`).
		A TCP or WebSocket host's is its server's `maxConnections`: a TCP
		connection arriving at the limit is closed as it is accepted, before
		`onAccept` (its peer sees the connection accepted and closed at
		once), and a WebSocket upgrade is answered 503. A reliable datagram
		host counts its sessions itself, and closes one accepted at the limit
		before `onAccept`: its peer sees it connect and then close. Either
		way the refusal is counted in `refusedConnections`.

		A host asks `listen()` for the system's largest backlog.
	**/
	public var maxConnections(get, set):Int;
	/**
		The most connections one address may hold open at once; `0` or less,
		the default, sets no limit. A TCP or WebSocket host's is its server's
		`maxConnectionsPerAddress`, which see: its TLS handshakes included,
		and an IPv6 address counted by its /64, as `RateLimiter.addressKey`
		keys it. A reliable datagram host counts its sessions by address the
		same way, and closes one past the limit as it is accepted, before
		`onAccept`. Either way the refusal is counted in `refusedConnections`.
		Set it before `listen()`.
	**/
	public var maxConnectionsPerAddress(get, set):Int;
	/**
		The TLS handshakes one address may have under way once half of its
		server's `maxPendingHandshakes` are taken, 16 unless set: a TCP or
		WebSocket host's is its server's `maxPendingHandshakesPerAddress`,
		which see. A reliable datagram host keeps the value and has no use
		for it: a join holds nothing until its cookie comes back, so there
		is nothing under way to bound.
	**/
	public var maxPendingHandshakesPerAddress(get, set):Int;
	/**
		Connections the host closed for its own limits: `maxConnections`,
		and a TCP or WebSocket host's server's other limits (see
		`ServerSocket.refusedConnections`). A `Float`, exact to 2^53, so a
		flood that goes on for long enough cannot wrap it.
	**/
	public var refusedConnections(get, never):Float;
	/** Called for each accepted connection. */
	public var onAccept(get, set):INetConnection->Void;
	/** Called when an accepted connection later closes. */
	public var onDisconnect(get, set):(INetConnection, Reason) -> Void;
	/** Called when the host or one of its accepted transports reports an error. */
	public var onError(get, set):Reason->Void;
	/**
	 * Whether this host can open outgoing sessions from its own listening
	 * endpoint.
	 *
	 * True only for connectionless transports, where one socket serves both
	 * directions. A listening TCP or WebSocket host cannot: accepting and
	 * dialling are different sockets there, and no flag changes that.
	 *
	 * It is a declared capability rather than an assumption because it is the
	 * one that decides whether a transport can mesh. Hole punching needs the
	 * port a peer dials out from to be the port it is reachable on, so a host
	 * that answers `false` here cannot carry a peer-to-peer topology however
	 * well it carries a client-server one.
	 */
	public var canDial(get, never):Bool;

	/**
	 * How long, in seconds, a session `dial` or `dialRelayed` opens may take
	 * to connect: 20 unless changed, 0 for no deadline. Read as each is
	 * dialled. A reliable datagram host's sessions hold it as their
	 * `connectTimeout`. A host that cannot dial keeps it and reads it never.
	 *
	 * @throws crossbyte.errors.RangeError If set below zero, or to NaN.
	 */
	public var connectTimeout(get, set):Float;

	/**
	 * How long, in seconds, `discoverPublicAddress` keeps asking: 3 unless
	 * changed (`StunClient.DEFAULT_TIMEOUT`). 0 or less sets no deadline:
	 * the question is asked until it is answered or the host closes.
	 */
	public var stunTimeout(get, set):Float;

	/** Binds the host to a local address and port. */
	public function bind(address:String, port:Int):Void;

	/**
	 * Opens an outgoing session from this host's listening endpoint, whose
	 * connect `connectTimeout` bounds.
	 *
	 * @throws crossbyte.errors.IllegalOperationError when `canDial` is false.
	 */
	public function dial(address:String, port:Int):INetConnection;

	/**
	 * Asks a STUN server how this host's listening endpoint appears from
	 * outside.
	 *
	 * Available exactly where `dial` is, and for the same reason rather than a
	 * coincidence: both need one socket to serve accepting and connecting
	 * alike. A host that cannot dial from its listening endpoint has no single
	 * endpoint to ask about either, so `canDial` gates both and there is no
	 * second flag to drift out of step with the first.
	 *
	 * The answer describes this port specifically. A NAT keeps one mapping per
	 * socket, so an address discovered anywhere else says nothing about where
	 * this host can be reached, which is the only thing worth publishing.
	 *
	 * It is asked for `stunTimeout`.
	 *
	 * Fails, with an `IllegalOperationError` as its cause, when `canDial` is
	 * false.
	 */
	public function discoverPublicAddress(server:String, port:Int = 3478):Future<ReflexiveAddress>;

	/**
	 * The address a peer at `destination` would reach this host on without
	 * leaving the local network.
	 *
	 * The companion to `discoverPublicAddress`, and available where that one is
	 * not: this asks the routing table rather than the network, so it needs no
	 * server, sends no packet, and does not care whether the host has one
	 * endpoint or two. Every host can answer it, including the stream hosts
	 * that refuse `dial`.
	 *
	 * It exists because a reflexive address is the wrong one for a peer on the
	 * same network. Reaching it would mean asking the NAT to route a packet
	 * back in to the network it came from, which plenty of consumer equipment
	 * will not do, while the two peers are one hop apart on the same subnet.
	 *
	 * No port comes back, and that is deliberate. A reflexive address carries a
	 * translated port because a NAT assigned one; nothing translates a local
	 * address, so the port to dial is `localPort`.
	 *
	 * @param destination The peer's address, numeric. Which one it is matters:
	 * a peer on this subnet and a peer across the internet are reached on
	 * different interfaces.
	 *
	 * Fails when the host is not running, because `localPort` has nothing to
	 * pair the answer with.
	 */
	public function localAddressFor(destination:String):Future<String>;

	/**
	 * Asks a TURN relay for an address, through this host's listening
	 * endpoint, for the peers hole punching cannot reach.
	 *
	 * Available exactly where `dial` is: a relay is reached through the one
	 * socket that both listens and dials, and the permissions it grants
	 * describe the traffic that socket sends.
	 *
	 * Fails, with an `IllegalOperationError` as its cause, when `canDial` is
	 * false.
	 */
	public function allocateRelay(server:String, port:Int = 3478, username:String, password:String, useChannels:Bool = false,
		?transport:TurnTransport):Future<ReflexiveAddress>;

	/**
	 * Opens an outgoing session to a peer through the relay `allocateRelay`
	 * was granted. Like one from `dial`, it does not surface through
	 * `onAccept`: the caller already holds it. `connectTimeout` bounds the
	 * connect as it bounds `dial`'s.
	 *
	 * @throws crossbyte.errors.IllegalOperationError when `canDial` is false.
	 */
	public function dialRelayed(address:String, port:Int):INetConnection;

	/**
	 * Lets a peer reach this host through the relay before this host has sent
	 * it anything.
	 *
	 * @throws crossbyte.errors.IllegalOperationError when `canDial` is false.
	 */
	public function permitRelayedPeer(address:String):Void;

	/** Starts accepting incoming connections. */
	public function listen():Void;
	/**
	 * Stops the listener and closes the host. The connections it accepted stay
	 * open: close each, as a server that is stopping does.
	 */
	public function close():Void;

	// Not in a page, which serves nothing and has no certificates to present.
	#if !(js && !nodejs)
	/**
		Replaces the certificate a `tls://` or `wss://` host presents, with
		its key, for every handshake from then on: each connection already up
		keeps the one it began with, so a certificate renewed while the host
		runs (every 60 to 90 days, from Let's Encrypt) is taken without a
		restart and without dropping anyone. A host spread over runtimes
		presents it on every one. See `ServerSocket.setCertificate`.

		@throws crossbyte.errors.IllegalOperationError On a host that
			terminates no TLS: `tcp://`, `ws://` or `rudp://`.
		@throws crossbyte.errors.ArgumentError When the certificate or the
			key is missing.
	**/
	public function setCertificate(certificate:Certificate, key:Key):Void;
	#end
}
