package crossbyte.net;

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
	/** Starts accepting incoming connections. */
	public function listen():Void;
	/** Stops the listener and closes the host. */
	public function close():Void;
}
