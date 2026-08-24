package crossbyte.net;

import crossbyte.Future;

/**
 * Common listener contract for server-side transport hosts.
 *
 * Hosts accept incoming client transports and surface them through the
 * `onAccept` callback. Connection shutdowns are reported through
 * `onDisconnect`, while listener failures are reported through `onError`.
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
	/** Maximum backlog / connection hint used by supported listeners. */
	public var maxConnections:Int;
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

	/** Binds the host to a local address and port. */
	public function bind(address:String, port:Int):Void;

	/**
	 * Opens an outgoing session from this host's listening endpoint.
	 *
	 * @throws crossbyte.errors.IllegalOperationError when `canDial` is false.
	 */
	public function dial(address:String, port:Int, timeoutMs:Int = 0):INetConnection;

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
	 * this host can be reached -- which is the only thing worth publishing.
	 *
	 * @throws crossbyte.errors.IllegalOperationError when `canDial` is false.
	 */
	public function discoverPublicAddress(server:String, port:Int = 3478, timeoutMs:Int = 3000):Future<ReflexiveAddress>;

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
	 * will not do -- while the two peers are one hop apart on the same subnet.
	 *
	 * No port comes back, and that is deliberate. A reflexive address carries a
	 * translated port because a NAT assigned one; nothing translates a local
	 * address, so the port to dial is `localPort`.
	 *
	 * @param destination The peer's address, numeric. Which one it is matters:
	 * a peer on this subnet and a peer across the internet are reached on
	 * different interfaces.
	 * @throws crossbyte.errors.IllegalOperationError when the host is not
	 * running, because `localPort` has nothing to pair the answer with.
	 */
	public function localAddressFor(destination:String):Future<String>;
	/** Starts accepting incoming connections. */
	public function listen():Void;
	/** Stops the listener and closes the host. */
	public function close():Void;
}
