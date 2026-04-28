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
	/** Binds the host to a local address and port. */
	public function bind(address:String, port:Int):Void;
	/** Starts accepting incoming connections. */
	public function listen():Void;
	/** Stops the listener and closes the host. */
	public function close():Void;
}
