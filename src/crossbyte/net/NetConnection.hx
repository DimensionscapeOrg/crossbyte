package crossbyte.net;

// Not built for the browser. It wraps the Transport union across every transport CrossByte offers, most of which a page does not have; browser code connects with crossbyte.net.Socket directly.

import crossbyte.core.CrossByte;
import crossbyte.errors.IOError;
#if !js
import crossbyte.ipc.LocalConnection;
#end
import crossbyte.net.Endpoint.parseURL;
import crossbyte.net._internal.CloseObservable;
import crossbyte.errors.SecurityError;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.Event;
import crossbyte.events.WebSocketCloseEvent;
import crossbyte.io.ByteArrayInput;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
// The two events that belong to transports a page has not got.
#if !(js && !nodejs)
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
#end

/**
 * High-level connection wrapper over CrossByte's supported stream transports.
 *
 * `NetConnection` normalizes TCP, WebSocket, local IPC, and reliable datagram sockets
 * behind the `INetConnection` contract. Use the callback properties for the hot
 * data path and the static conversion helpers when you need to reach the
 * underlying transport type.
 *
 * Over TCP, WebSocket and reliable UDP alike, a connection tells its
 * callbacks the same story, whatever its transport's own events are:
 *
 * - `onReady` once, when it is up.
 * - `onError` for what went wrong: a connect that failed -- refused, not
 *   found, not made within its timeout -- or a transport error. Reads stop
 *   there.
 * - `onClose` exactly once, when it is over, however it ended: closed by
 *   either end, failed, or timed out, before or after it was ready. It is
 *   given why -- `Reason.Closed`, a WebSocket peer's `Reason.Code`, or the
 *   reason `onError` was given when that is what ended it. Nothing is
 *   called after it.
 *
 * A deadline that passed is `Reason.Timeout`, to both: a connect not made
 * within its socket's `timeout`, and anything else its transport reports
 * as an `ioError` with `IOErrorEvent.TIMEOUT_ERROR_ID`.
 */
abstract NetConnection(NetConnectionBase) from NetConnectionBase to NetConnectionBase {
	/** Remote peer address. */
	public var remoteAddress(get, never):String;
	/** Remote peer port. */
	public var remotePort(get, never):Int;
	/** Local bound address. */
	public var localAddress(get, never):String;
	/** Local bound port. */
	public var localPort(get, never):Int;
	/** Active transport protocol. */
	public var protocol(get, set):Protocol;
	/** `true` while the wrapped transport is connected. */
	public var connected(get, never):Bool;
	/** Enables or disables delivery to `onData`. */
	public var readEnabled(get, set):Bool;
	/** Timestamp of the most recent inbound payload, in uptime seconds. */
	public var inTimestamp(get, set):Float;
	/** Timestamp of the most recent outbound payload, in uptime seconds. */
	public var outTimestamp(get, set):Float;
	/** Called when incoming data is available. */
	public var onData(get, set):ByteArrayInput->Void;
	/** Called once, when the connection is over, with why; see the class notes. */
	public var onClose(get, set):Reason->Void;
	/** Called when a connect fails or the transport reports an error; `onClose` follows. */
	public var onError(get, set):Reason->Void;
	/** Called once the connection becomes ready for I/O. */
	public var onReady(get, set):Void->Void;

	/**
	 * Connects to a transport URI and wraps the resulting connection.
	 *
	 * Supported schemes are `tcp://`, `ws://`, `wss://`, `rudp://`, and `local://`.
	 *
	 * A `wss://` connection verifies the server's certificate against the
	 * system's trust store. To trust a private CA, or a development server's
	 * self-signed certificate, make the socket yourself so its settings are in
	 * place before it connects:
	 *
	 * ```haxe
	 * var socket = new WebSocket();
	 * socket.secure = true;
	 * socket.certAuthority = Certificate.fromFile("dev-ca.pem");
	 * socket.connect("rpc.internal/rpc", 8443);
	 * var connection = NetConnection.fromWebSocket(socket);
	 * ```
	 *
	 * @param connectTimeout For `local://`, whose connect waits for a listener
	 * on the calling thread: how long, in milliseconds, 0 for a single try.
	 * `LocalConnection.timeout` when left out. The other transports connect
	 * without waiting and ignore it.
	 * @throws crossbyte.errors.ArgumentError For `local://`, when no listener
	 * took the connection within `connectTimeout`, where the other
	 * transports report a failed connect through `onError` and `onClose`
	 * alone.
	 */
	public inline function new(uri:String, ?onData:ByteArrayInput->Void, ?onReady:Void->Void, ?onClose:Reason->Void, ?onError:Reason->Void,
			readEnabled:Bool = false, ?connectTimeout:Int):Void {
		var endpoint:Endpoint = parseURL(uri);
		var protocol:Protocol = endpoint.protocol;
		this = switch (protocol) {
			case TCP:
				var socket:Socket = new Socket();
				var nc:TCPConnection = new TCPConnection(socket);
				nc.onData = onData;
				nc.onClose = onClose;
				nc.onReady = onReady;
				nc.onError = onError;
				nc.readEnabled = readEnabled;

				socket.connect(endpoint.address, endpoint.port);
				nc;
			#if !(js && !nodejs)
			case WEBSOCKET:
				var socket = new WebSocket();
				var nc = new WSConnection(socket);
				nc.onData = onData;
				nc.onClose = onClose;
				nc.onReady = onReady;
				nc.onError = onError;
				nc.readEnabled = readEnabled;

				socket.secure = endpoint.secure;
				socket.connect(endpoint.address + endpoint.resource, endpoint.port);
				nc;
			case RUDP:
				var socket = new ReliableDatagramSocket();
				var nc = new RUDPConnection(socket);
				nc.onData = onData;
				nc.onClose = onClose;
				nc.onReady = onReady;
				nc.onError = onError;
				nc.readEnabled = readEnabled;

				socket.connect(endpoint.address, endpoint.port);
				nc;
			#end
			#if !js
			case LOCAL:
				var connection = new LocalConnection();
				connection.onData = onData;
				connection.onClose = onClose;
				connection.onReady = onReady;
				connection.onError = onError;
				connection.readEnabled = readEnabled;
				if (connectTimeout != null) {
					connection.timeout = connectTimeout;
				}
				connection.connect(endpoint.address);
				new NetConnectionAdapter(connection);
			#end
			default:
				throw('Protocol error');
				null;
		}
	}

	@:to public inline function toINetConnection():INetConnection {
		return cast this;
	}

	/** Exposes the wrapped transport-specific value. */
	public inline function expose():Transport {
		return this.expose();
	}

	/** Sends a payload over the wrapped transport. */
	public inline function send(data:ByteArray):Void {
		this.send(data);
	}

	/**
		Closes the wrapped transport, and tells `onClose` `Reason.Closed` if
		the connection had not already ended. On one that has -- closed by
		its peer, failed, closed already -- it does nothing, and does not
		throw.
	**/
	public inline function close():Void {
		this.close();
	}

	@:noCompletion private inline function get_remoteAddress():String {
		return (cast this : INetConnection).remoteAddress;
	}

	@:noCompletion private inline function get_remotePort():Int {
		return (cast this : INetConnection).remotePort;
	}

	@:noCompletion private inline function get_localAddress():String {
		return (cast this : INetConnection).localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return (cast this : INetConnection).localPort;
	}

	@:noCompletion private inline function get_protocol():Protocol {
		return this.protocol;
	}

	@:noCompletion private inline function set_protocol(value:Protocol):Protocol {
		return this.protocol = value;
	}

	@:noCompletion private inline function get_connected():Bool {
		return (cast this : INetConnection).connected;
	}

	@:noCompletion private inline function get_readEnabled():Bool {
		return (cast this : INetConnection).readEnabled;
	}

	@:noCompletion private inline function set_readEnabled(value:Bool):Bool {
		return (cast this : INetConnection).readEnabled = value;
	}

	@:noCompletion private inline function get_inTimestamp():Float {
		return this.inTimestamp;
	}

	@:noCompletion private inline function set_inTimestamp(value:Float):Float {
		this.inTimestamp = value;
		return value;
	}

	@:noCompletion private inline function get_outTimestamp():Float {
		return this.outTimestamp;
	}

	@:noCompletion private inline function set_outTimestamp(value:Float):Float {
		this.outTimestamp = value;
		return value;
	}

	@:noCompletion private inline function get_onData():ByteArrayInput->Void {
		return (cast this : INetConnection).onData;
	}

	@:noCompletion private inline function set_onData(value:ByteArrayInput->Void):ByteArrayInput->Void {
		return (cast this : INetConnection).onData = value;
	}

	@:noCompletion private inline function get_onClose():Reason->Void {
		return (cast this : INetConnection).onClose;
	}

	@:noCompletion private inline function set_onClose(value:Reason->Void):Reason->Void {
		return (cast this : INetConnection).onClose = value;
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return (cast this : INetConnection).onError;
	}

	@:noCompletion private inline function set_onError(value:Reason->Void):Reason->Void {
		return (cast this : INetConnection).onError = value;
	}

	@:noCompletion private inline function get_onReady():Void->Void {
		return (cast this : INetConnection).onReady;
	}

	@:noCompletion private inline function set_onReady(value:Void->Void):Void->Void {
		return (cast this : INetConnection).onReady = value;
	}

	/** Returns the wrapped TCP socket when this connection uses `Protocol.TCP`. */
	public static inline function toSocket(connection:NetConnection):Socket {
		var socket:Socket = null;

		if (connection.protocol == TCP) {
			socket = (cast connection : TCPConnection).__socket;
		}

		return socket;
	}

	#if !(js && !nodejs)
	/** Returns the wrapped WebSocket when this connection uses `Protocol.WEBSOCKET`. */
	public static inline function toWebSocket(connection:NetConnection):WebSocket {
		var socket:WebSocket = null;

		if (connection.protocol == WEBSOCKET) {
			socket = (cast connection : WSConnection).__socket;
		}

		return socket;
	}

	/** Returns the wrapped reliable datagram socket when this connection uses `Protocol.RUDP`. */
	public static inline function toReliableDatagramSocket(connection:NetConnection):ReliableDatagramSocket {
		var socket:ReliableDatagramSocket = null;

		if (connection.protocol == RUDP) {
			socket = (cast connection : RUDPConnection).__socket;
		}

		return socket;
	}

	// The IPC transport, and only it. Node has the other three -- TCP,
	// WebSocket and reliable datagram all run there -- but LocalConnection
	// needs an operating-system IPC channel and shared memory, which it has
	// not got. Protocol.LOCAL is therefore not a case that exists there
	// rather than one that fails at runtime.
	#if !js
	/** Returns the wrapped local IPC transport when this connection uses `Protocol.LOCAL`. */
	public static inline function toLocalConnection(connection:NetConnection):LocalConnection {
		var local:LocalConnection = null;

		if (connection.protocol == LOCAL) {
			var base:Dynamic = connection;
			if (Std.isOfType(base, LocalConnection)) {
				local = cast base;
			} else if (Std.isOfType(base, NetConnectionAdapter)) {
				var adapter:NetConnectionAdapter = cast base;
				if (Std.isOfType(adapter.__connection, LocalConnection)) {
					local = cast adapter.__connection;
				}
			}
		}

		return local;
	}
	#end

	#end

	@:from
	/** Wraps an existing TCP socket as a `NetConnection`. */
	public static inline function fromSocket(socket:Socket):NetConnection {
		var nc:NetConnection = new TCPConnection(socket);
		return nc;
	}

	@:from
	/**
		Wraps an arbitrary `INetConnection`, adapting external implementations
		when needed. The same connection wrapped again, while an `RPCSession`
		is observing it, is the same `NetConnection`.
	**/
	public static inline function fromINetConnection(connection:INetConnection):NetConnection {
		if (Std.isOfType(connection, NetConnectionBase)) {
			return cast connection;
		}
		return NetConnectionAdapter.of(connection);
	}

	/** Wraps an existing TCP socket and immediately binds connection callbacks. */
	public static inline function fromSocketWith(socket:Socket, ?onData:ByteArrayInput->Void, ?onReady:Void->Void, ?onClose:Reason->Void,
			?onError:Reason->Void, readEnabled:Bool = false):NetConnection {
		var nc:TCPConnection = new TCPConnection(socket);

		nc.onData = onData;
		nc.onClose = onClose;
		nc.onReady = onReady;
		nc.onError = onError;
		nc.readEnabled = readEnabled;
		if (nc.connected) {
			nc.onReady();
		}

		return nc;
	}

	#if !(js && !nodejs)
	@:from
	/** Wraps an existing WebSocket as a `NetConnection`. */
	public static inline function fromWebSocket(webSocket:WebSocket):NetConnection {
		@:privateAccess
		var nc:NetConnection = new WSConnection(webSocket);
		return nc;
	}

	@:from
	/** Wraps an existing reliable datagram socket as a `NetConnection`. */
	public static inline function fromReliableDatagramSocket(reliableDatagramSocket:ReliableDatagramSocket):NetConnection {
		@:privateAccess
		var nc:NetConnection = new RUDPConnection(reliableDatagramSocket);
		return nc;
	}

	#end

	#if !js
	@:from
	/** Wraps an existing local IPC transport as a `NetConnection`. */
	public static inline function fromLocalConnection(localConnection:LocalConnection):NetConnection {
		return fromINetConnection(localConnection);
	}
	#end
}

@:allow(crossbyte.net.NetConnection)
private class NetConnectionAdapter extends NetConnectionBase implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;

	@:noCompletion private var __connection:INetConnection;
	// Set once this has wrapped the inner connection's onClose to tell an
	// observer; the application's callback is then kept here. The same for
	// onReady.
	@:noCompletion private var __forwardingClose:Bool = false;
	@:noCompletion private var __applicationOnClose:Reason->Void = null;
	@:noCompletion private var __forwardingReady:Bool = false;
	@:noCompletion private var __applicationOnReady:Void->Void = null;

	/*
		The adapters forwarding a connection's onClose or onReady to an
		observer, by the connection they wrap. A connection an application
		wrote has only those callbacks to be observed through, and the one
		adapter observing it keeps the application's own behind its forwarder.
		Wrapped a second time -- `(connection : NetConnection).onClose = ...`
		after a session was made on it -- a new adapter set the callback on the
		connection itself, over the forwarder: the session never heard it end,
		and the calls waiting on it waited for good. So a connection that is
		being observed is wrapped by the adapter observing it, until it ends.

		Only connections that are not CrossByte's own come here, and only while
		observed; guarded, since runtimes on other threads wrap their own.
	*/
	@:noCompletion private static var __observed:Null<haxe.ds.ObjectMap<INetConnection, NetConnectionAdapter>> = null;
	#if (cpp || neko || hl || java || jvm || eval)
	@:noCompletion private static final __observedLock:sys.thread.Mutex = new sys.thread.Mutex();
	#end

	/** The adapter for `connection`: the one observing it, if one is, or a new one. **/
	@:noCompletion private static function of(connection:INetConnection):NetConnectionAdapter {
		var adapter:Null<NetConnectionAdapter> = null;
		#if (cpp || neko || hl || java || jvm || eval)
		__observedLock.acquire();
		#end
		if (__observed != null) {
			adapter = __observed.get(connection);
		}
		#if (cpp || neko || hl || java || jvm || eval)
		__observedLock.release();
		#end
		return adapter != null ? adapter : new NetConnectionAdapter(connection);
	}

	@:noCompletion private function __setObserved(observed:Bool):Void {
		#if (cpp || neko || hl || java || jvm || eval)
		__observedLock.acquire();
		#end
		if (observed) {
			if (__observed == null) {
				__observed = new haxe.ds.ObjectMap();
			}
			__observed.set(__connection, this);
		} else if (__observed != null && __observed.get(__connection) == this) {
			__observed.remove(__connection);
		}
		#if (cpp || neko || hl || java || jvm || eval)
		__observedLock.release();
		#end
	}

	private function new(connection:INetConnection) {
		__connection = connection;
		protocol = connection.protocol;
		inTimestamp = connection.inTimestamp;
		outTimestamp = connection.outTimestamp;
	}

	@:noCompletion private inline function get_remoteAddress():String {
		return __connection.remoteAddress;
	}

	@:noCompletion private inline function get_remotePort():Int {
		return __connection.remotePort;
	}

	@:noCompletion private inline function get_localAddress():String {
		return __connection.localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return __connection.localPort;
	}

	@:noCompletion private inline function get_connected():Bool {
		return __connection.connected;
	}

	@:noCompletion private inline function get_readEnabled():Bool {
		return __connection.readEnabled;
	}

	@:noCompletion private inline function set_readEnabled(value:Bool):Bool {
		return __connection.readEnabled = value;
	}

	@:noCompletion private inline function get_onData():ByteArrayInput->Void {
		return __connection.onData;
	}

	@:noCompletion private inline function set_onData(value:ByteArrayInput->Void):ByteArrayInput->Void {
		return __connection.onData = value;
	}

	@:noCompletion private inline function get_onClose():Reason->Void {
		return __forwardingClose ? __applicationOnClose : __connection.onClose;
	}

	@:noCompletion private inline function set_onClose(value:Reason->Void):Reason->Void {
		if (__forwardingClose) {
			return __applicationOnClose = value;
		}
		return __connection.onClose = value;
	}

	/**
		Handed on to the wrapped connection when it can be told itself -- a
		`LocalConnection` can. Any other has only its `onClose` to go by, so
		this wraps that, keeping the application's callback here: set through
		this `NetConnection` afterwards, it stays wrapped. Set on the wrapped
		connection directly, it replaces the wrapper, as it would any callback.
	**/
	override public function __observeClose(observer:Null<Reason->Void>):Void {
		if (Std.isOfType(__connection, CloseObservable)) {
			(cast __connection : CloseObservable).__observeClose(observer);
			return;
		}
		super.__observeClose(observer);
		if (!__forwardingClose) {
			__applicationOnClose = __connection.onClose;
			__connection.onClose = __forwardClose;
			__forwardingClose = true;
		}
		__setObserved(observer != null);
	}

	@:noCompletion private function __forwardClose(reason:Reason):Void {
		// Ended: wrapped again from here on, it may have a new adapter.
		__setObserved(false);
		__notifyClose(reason);
		final onClose = __applicationOnClose;
		if (onClose != null) {
			onClose(reason);
		}
	}

	/** As `__observeClose`, for the connection becoming ready. **/
	override public function __observeReady(observer:Null<Void->Void>):Void {
		if (Std.isOfType(__connection, CloseObservable)) {
			(cast __connection : CloseObservable).__observeReady(observer);
			return;
		}
		super.__observeReady(observer);
		if (!__forwardingReady) {
			__applicationOnReady = __connection.onReady;
			__connection.onReady = __forwardReady;
			__forwardingReady = true;
		}
		if (observer != null) {
			__setObserved(true);
		}
	}

	@:noCompletion private function __forwardReady():Void {
		__notifyReady();
		final onReady = __applicationOnReady;
		if (onReady != null) {
			onReady();
		}
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __connection.onError;
	}

	@:noCompletion private inline function set_onError(value:Reason->Void):Reason->Void {
		return __connection.onError = value;
	}

	@:noCompletion private inline function get_onReady():Void->Void {
		return __forwardingReady ? __applicationOnReady : __connection.onReady;
	}

	@:noCompletion private inline function set_onReady(value:Void->Void):Void->Void {
		if (__forwardingReady) {
			return __applicationOnReady = value;
		}
		return __connection.onReady = value;
	}

	public inline function expose():Transport {
		return __connection.expose();
	}

	public inline function send(data:ByteArray):Void {
		__connection.send(data);
		outTimestamp = __connection.outTimestamp;
	}

	public inline function close():Void {
		__connection.close();
	}
}

@:access(crossbyte.net.Socket)
@:allow(crossbyte.net.NetConnection)
private class TCPConnection extends NetConnectionBase implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var autoFlush:Bool = true;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;

	@:noCompletion private var __socket:Socket;
	@:noCompletion private var __onData:ByteArrayInput->Void = __noopData;
	@:noCompletion private var __onClose:Reason->Void = __noopClose;
	@:noCompletion private var __onError:Reason->Void = __noopError;
	@:noCompletion private var __onReady:Void->Void = __noopReady;
	@:noCompletion private var __isReceiving:Bool = false;
	@:noCompletion private var __lifecycleReady:Bool = false;

	@:noCompletion private inline function get_remoteAddress():String {
		return __socket.remoteAddress;
	}

	@:noCompletion private inline function get_remotePort():Int {
		return __socket.remotePort;
	}

	@:noCompletion private inline function get_localAddress():String {
		return __socket.localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return __socket.localPort;
	}

	@:noCompletion private inline function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	@:noCompletion private inline function get_onClose():Reason->Void {
		return __onClose;
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __onError;
	}

	@:noCompletion private inline function get_onReady():Void->Void {
		return __onReady;
	}

	@:noCompletion private inline function set_onData(v:ByteArrayInput->Void):ByteArrayInput->Void {
		__onData = (v != null) ? v : __noopData;
		return __onData;
	}

	@:noCompletion private inline function set_onClose(v:Reason->Void):Reason->Void {
		__onClose = (v != null) ? v : __noopClose;
		return __onClose;
	}

	@:noCompletion private inline function set_onError(v:Reason->Void):Reason->Void {
		__onError = (v != null) ? v : __noopError;
		return __onError;
	}

	@:noCompletion private inline function set_onReady(v:Void->Void):Void->Void {
		__onReady = (v != null) ? v : __noopReady;
		return __onReady;
	}

	@:noCompletion private inline function get_connected():Bool {
		return __socket.connected;
	}

	@:noCompletion inline function get_readEnabled():Bool {
		return __isReceiving;
	}

	@:noCompletion inline function set_readEnabled(v:Bool):Bool {
		if (v == __isReceiving) {
			return v;
		}
		__isReceiving = v;
		if (v) {
			__socket.addEventListener(ProgressEvent.SOCKET_DATA, socket_onData);
		} else {
			__socket.removeEventListener(ProgressEvent.SOCKET_DATA, socket_onData);
		}

		return v;
	}

	@:noCompletion private function new(socket:Socket) {
		protocol = TCP;
		this.__socket = socket;
		__prepareLifecycle();
	}

	public inline function expose():Transport {
		return TCP(__socket);
	}

	public inline function send(data:ByteArray):Void {
		// TODO: bypass and write to directly to sys.net.socket?
		this.__writeBytes(data, 0, 0);
		this.flush();
	}

	public inline function writeBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		__writeBytes(bytes, offset, length);
		if (autoFlush) {
			__socket.__queueWrite();
		}
	}

	public inline function flush():Void {
		__socket.flush();
	}

	public inline function close():Void {
		__closeWith(Reason.Closed);
	}

	override public function __closeWith(reason:Reason):Void {
		__disposeLifecycle();
		__end(reason);
		try {
			__socket.close();
		} catch (_:Dynamic) {}
	}

	/**
		The connection is over: the observer and then `onClose` are told,
		once, and nothing is told after. Closed by this side, it used to be
		told every time `close()` was called, and once more on top of the
		peer's close.
	**/
	@:noCompletion private function __end(reason:Reason):Void {
		if (__ended) {
			return;
		}
		__ended = true;
		readEnabled = false;
		__notifyClose(reason);
		__onClose(reason);
	}

	@:noCompletion private inline function __writeBytes(bytes:ByteArray, offset:Int, length:Int):Void {
		if (__socket.__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__socket.__output.writeBytes(bytes, offset, length);
		outTimestamp = __uptime();
	}

	/**
		The uptime of the runtime the socket is on. Read from the native
		socket's own runtime field, it was a TypeError on a Node client --
		every send, and the first arrival, which closed the connection.
	**/
	@:noCompletion private inline function __uptime():Float {
		final runtime:CrossByte = __socket.__runtime();
		return runtime != null ? runtime.uptime : 0.0;
	}

	@:noCompletion private inline function socket_onData(_e:ProgressEvent):Void {
		inTimestamp = __uptime();
		final input:ByteArrayInput = __socket.__input;
		#if debug
		try
			__onData(input)
		catch (_:Dynamic) {/* swallow/log */}
		#else
		__onData(input);
		#end
	}

	private inline function socket_onClose(_e:Event):Void {
		__end(__failure != null ? __failure : Reason.Closed);
	}

	@:noCompletion private inline function socket_onReady(_e:Event):Void {
		__socket.removeEventListener(Event.CONNECT, socket_onReady);
		__notifyReady();
		__onReady();
	}

	/**
		An error stops the reads, and `onError` is told. A `Socket` whose
		connect failed says so with this alone -- no connection came up, so
		no `close` follows -- and the connection ends here; one that was up
		ends with the `close` its socket dispatches next. A connect that
		failed used to end with `onError` and no `onClose`, where a
		WebSocket's and a reliable UDP one's ended with both.
	**/
	@:noCompletion private function socket_onIoError(e:IOErrorEvent):Void {
		if (__ended) {
			return;
		}
		final reason:Reason = NetConnectionBase.__reasonOf(e);
		if (__failure == null) {
			__failure = reason;
		}
		readEnabled = false;
		__notifyClose(reason);
		__onError(reason);
		if (!__socket.connected) {
			__end(reason);
		}
	}

	@:noCompletion private inline function socket_onSecError(e:SecurityError):Void {
		readEnabled = false;
		final reason = Reason.Error(e.message);
		__notifyClose(reason);
		__onError(reason);
	}

	@:noCompletion private inline function __prepareLifecycle():Void {
		if (__lifecycleReady || __socket == null) {
			return;
		}

		__lifecycleReady = true;

		if (!connected) {
			__socket.addEventListener(Event.CONNECT, socket_onReady);
		} else {
			__onReady();
		}

		__socket.addEventListener(Event.CLOSE, socket_onClose);
		__socket.addEventListener(IOErrorEvent.IO_ERROR, socket_onIoError);
		// __socket.addEventListener(SecurityError.SECURITY_ERROR, socket_onSecError);
	}

	@:noCompletion private inline function __disposeLifecycle():Void {
		if (!__lifecycleReady || __socket == null)
			return;
		__lifecycleReady = false;
		__socket.removeEventListener(Event.CONNECT, socket_onReady);
		__socket.removeEventListener(Event.CLOSE, socket_onClose);
		__socket.removeEventListener(IOErrorEvent.IO_ERROR, socket_onIoError);
		// __socket.removeEventListener(SecurityError.SECURITY_ERROR, socket_onSecError);
	}

	@:noCompletion private static inline function __noopReady():Void {}

	@:noCompletion private static inline function __noopData(_:ByteArrayInput):Void {}

	@:noCompletion private static inline function __noopClose(_:Reason):Void {}

	@:noCompletion private static inline function __noopError(_:Reason):Void {}
}

@:allow(crossbyte.net.NetConnection)
#if !(js && !nodejs)
private class RUDPConnection extends NetConnectionBase implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;

	@:noCompletion private var __socket:ReliableDatagramSocket;
	@:noCompletion private var __onData:ByteArrayInput->Void = __noopData;
	@:noCompletion private var __onClose:Reason->Void = __noopClose;
	@:noCompletion private var __onError:Reason->Void = __noopError;
	@:noCompletion private var __onReady:Void->Void = __noopReady;
	@:noCompletion private var __receiving:Bool = false;
	@:noCompletion private var __lifecycleReady:Bool = false;

	@:noCompletion private inline function get_remoteAddress():String {
		return __socket.remoteAddress;
	}

	@:noCompletion private inline function get_remotePort():Int {
		return __socket.remotePort;
	}

	@:noCompletion private inline function get_localAddress():String {
		return __socket.localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return __socket.localPort;
	}

	@:noCompletion private inline function get_connected():Bool {
		return __socket.connected;
	}

	@:noCompletion private inline function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	@:noCompletion private inline function get_onClose():Reason->Void {
		return __onClose;
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __onError;
	}

	@:noCompletion private inline function get_onReady():Void->Void {
		return __onReady;
	}

	@:noCompletion private inline function set_onData(v:ByteArrayInput->Void):ByteArrayInput->Void {
		__onData = (v != null) ? v : __noopData;
		return __onData;
	}

	@:noCompletion private inline function set_onClose(v:Reason->Void):Reason->Void {
		__onClose = (v != null) ? v : __noopClose;
		return __onClose;
	}

	@:noCompletion private inline function set_onError(v:Reason->Void):Reason->Void {
		__onError = (v != null) ? v : __noopError;
		return __onError;
	}

	@:noCompletion private inline function set_onReady(v:Void->Void):Void->Void {
		__onReady = (v != null) ? v : __noopReady;
		return __onReady;
	}

	@:noCompletion private inline function set_readEnabled(v:Bool):Bool {
		if (v == __receiving) {
			return v;
		}

		__receiving = v;
		if (v) {
			switch (__socket.mode) {
				case DATAGRAM:
					__socket.addEventListener(DatagramSocketDataEvent.DATA, socket_onDatagramData);
				case STREAM:
					__socket.addEventListener(ProgressEvent.SOCKET_DATA, socket_onStreamData);
			}
		} else {
			__socket.removeEventListener(DatagramSocketDataEvent.DATA, socket_onDatagramData);
			__socket.removeEventListener(ProgressEvent.SOCKET_DATA, socket_onStreamData);
		}

		return v;
	}

	@:noCompletion private inline function get_readEnabled():Bool {
		return __receiving;
	}

	private function new(socket:ReliableDatagramSocket) {
		protocol = RUDP;
		__socket = socket;
		__prepareLifecycle();
	}

	public inline function expose():Transport {
		return RUDP(__socket);
	}

	public function send(data:ByteArray):Void {
		switch (__socket.mode) {
			case DATAGRAM:
				__socket.send(data);
			case STREAM:
				__socket.writeBytes(data);
				__socket.flush();
		}
		outTimestamp = CrossByte.current().uptime;
	}

	public function close():Void {
		__closeWith(Reason.Closed);
	}

	override public function __closeWith(reason:Reason):Void {
		__disposeLifecycle();
		__end(reason);
		try {
			__socket.close();
		} catch (_:Dynamic) {}
	}

	/** As `TCPConnection.__end`: `onClose` once, and nothing after. **/
	@:noCompletion private function __end(reason:Reason):Void {
		if (__ended) {
			return;
		}
		__ended = true;
		readEnabled = false;
		__notifyClose(reason);
		__onClose(reason);
	}

	@:noCompletion private inline function socket_onDatagramData(event:DatagramSocketDataEvent):Void {
		inTimestamp = CrossByte.current().uptime;
		event.data.position = 0;
		__onData(event.data);
	}

	@:noCompletion private function socket_onStreamData(_event:ProgressEvent):Void {
		inTimestamp = CrossByte.current().uptime;
		var bytes = new ByteArray();
		var available = __socket.bytesAvailable;
		if (available > 0) {
			__socket.readBytes(bytes, 0, available);
		}
		bytes.position = 0;
		__onData(bytes);
	}

	@:noCompletion private inline function socket_onClose(_e:Event):Void {
		__end(__failure != null ? __failure : Reason.Closed);
	}

	@:noCompletion private inline function socket_onReady(_e:Event):Void {
		__socket.removeEventListener(Event.CONNECT, socket_onReady);
		__notifyReady();
		__onReady();
	}

	/**
		As a TCP connection's: the reads stop and `onError` is told; a
		connect that failed ends here, and one that was up with the `close`
		that follows.
	**/
	@:noCompletion private function socket_onIoError(e:IOErrorEvent):Void {
		if (__ended) {
			return;
		}
		final reason:Reason = NetConnectionBase.__reasonOf(e);
		if (__failure == null) {
			__failure = reason;
		}
		readEnabled = false;
		__notifyClose(reason);
		__onError(reason);
		if (!__socket.connected) {
			__end(reason);
		}
	}

	@:noCompletion private inline function __prepareLifecycle():Void {
		if (__lifecycleReady || __socket == null) {
			return;
		}

		__lifecycleReady = true;
		if (!connected) {
			__socket.addEventListener(Event.CONNECT, socket_onReady);
		} else {
			__onReady();
		}
		__socket.addEventListener(Event.CLOSE, socket_onClose);
		__socket.addEventListener(IOErrorEvent.IO_ERROR, socket_onIoError);
	}

	@:noCompletion private inline function __disposeLifecycle():Void {
		if (!__lifecycleReady || __socket == null) {
			return;
		}

		__lifecycleReady = false;
		__socket.removeEventListener(Event.CONNECT, socket_onReady);
		__socket.removeEventListener(Event.CLOSE, socket_onClose);
		__socket.removeEventListener(IOErrorEvent.IO_ERROR, socket_onIoError);
	}

	@:noCompletion private static inline function __noopReady():Void {}

	@:noCompletion private static inline function __noopData(_:ByteArrayInput):Void {}

	@:noCompletion private static inline function __noopClose(_:Reason):Void {}

	@:noCompletion private static inline function __noopError(_:Reason):Void {}
}

@:access(crossbyte.net.WebSocket)
@:allow(crossbyte.net.NetConnection)
private class WSConnection extends NetConnectionBase implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;

	@:noCompletion private var __socket:WebSocket;
	@:noCompletion private var __onData:ByteArrayInput->Void = __noopData;
	@:noCompletion private var __onClose:Reason->Void = __noopClose;
	@:noCompletion private var __onError:Reason->Void = __noopError;
	@:noCompletion private var __onReady:Void->Void = __noopReady;
	@:noCompletion private var __receiving:Bool = false;
	@:noCompletion private var __lifecycleReady:Bool = false;

	@:noCompletion private inline function get_remoteAddress():String {
		return __socket.remoteAddress;
	}

	@:noCompletion private inline function get_remotePort():Int {
		return __socket.remotePort;
	}

	@:noCompletion private inline function get_localAddress():String {
		return __socket.localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return __socket.localPort;
	}

	private inline function get_connected():Bool {
		return __socket.connected;
	}

	@:noCompletion private inline function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	@:noCompletion private inline function get_onClose():Reason->Void {
		return __onClose;
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __onError;
	}

	@:noCompletion private inline function get_onReady():Void->Void {
		return __onReady;
	}

	@:noCompletion private inline function set_onData(v:ByteArrayInput->Void):ByteArrayInput->Void {
		__onData = (v != null) ? v : __noopData;
		return __onData;
	}

	@:noCompletion private inline function set_onClose(v:Reason->Void):Reason->Void {
		__onClose = (v != null) ? v : __noopClose;
		return __onClose;
	}

	@:noCompletion private inline function set_onError(v:Reason->Void):Reason->Void {
		__onError = (v != null) ? v : __noopError;
		return __onError;
	}

	@:noCompletion private inline function set_onReady(v:Void->Void):Void->Void {
		__onReady = (v != null) ? v : __noopReady;
		return __onReady;
	}

	@:noCompletion private inline function set_readEnabled(v:Bool):Bool {
		if (v == __receiving) {
			return v;
		}

		__receiving = v;
		if (v) {
			__socket.addEventListener(ProgressEvent.SOCKET_DATA, socket_onData);
		} else {
			__socket.removeEventListener(ProgressEvent.SOCKET_DATA, socket_onData);
		}

		return v;
	}

	@:noCompletion private inline function get_readEnabled():Bool {
		return __receiving;
	}

	private function new(socket:WebSocket) {
		protocol = WEBSOCKET;
		this.__socket = socket;
		__prepareLifecycle();
	}

	public inline function expose():Transport {
		return WEBSOCKET(__socket);
	}

	public inline function toSocket<T>():T {
		return cast __socket;
	}

	public function send(data:ByteArray):Void {
		__socket.writeBytes(data);
		__socket.flush();
		var runtime = CrossByte.current();
		outTimestamp = runtime != null ? runtime.uptime : 0.0;
	}

	public function close():Void {
		__closeWith(Reason.Closed);
	}

	/**
		Closed once. A WebSocket already closed -- by its peer, or by a
		close() before this one -- throws from its own close(), and so did
		this: closing a connection whose peer had gone was an error.
	**/
	override public function __closeWith(reason:Reason):Void {
		__disposeLifecycle();
		__end(reason);
		try {
			__socket.close();
		} catch (_:Dynamic) {}
	}

	/** As `TCPConnection.__end`: `onClose` once, and nothing after. **/
	@:noCompletion private function __end(reason:Reason):Void {
		if (__ended) {
			return;
		}
		__ended = true;
		readEnabled = false;
		__notifyClose(reason);
		__onClose(reason);
	}

	@:noCompletion private inline function socket_onData(_e:ProgressEvent):Void {
		@:privateAccess {
			inTimestamp = __socket.__cbInstance != null ? __socket.__cbInstance.uptime : 0.0;
			__onData(__socket.__input);
		}
	}

	@:noCompletion private inline function socket_onClose(e:Event):Void {
		__end(__failure != null ? __failure : __closeReason(e));
	}

	/**
		How the peer closed: `Reason.Code` with the close frame's code and
		reason, or `Reason.Closed` when the session ended with no code known.
		It was `Reason.Closed` whatever the peer said -- a server going away
		and a server refusing a protocol violation were one close to the
		application, and to an RPC call that failed because of it.
	**/
	@:noCompletion private static function __closeReason(e:Event):Reason {
		final closed:WebSocketCloseEvent = Std.downcast(e, WebSocketCloseEvent);
		if (closed == null || closed.code == 0) {
			return Reason.Closed;
		}
		return Reason.Code(closed.code, closed.reason);
	}

	@:noCompletion private inline function socket_onReady(_e:Event):Void {
		__socket.removeEventListener(Event.CONNECT, socket_onReady);
		__notifyReady();
		__onReady();
	}

	/**
		As a TCP connection's: the reads stop and `onError` is told; a
		connect that failed ends here, and one that was up with the close
		that follows -- told the error's reason rather than the 1006 a
		WebSocket closes with after one.
	**/
	@:noCompletion private function socket_onIoError(e:IOErrorEvent):Void {
		if (__ended) {
			return;
		}
		final reason:Reason = NetConnectionBase.__reasonOf(e);
		if (__failure == null) {
			__failure = reason;
		}
		readEnabled = false;
		__notifyClose(reason);
		__onError(reason);
		if (!__socket.connected) {
			__end(reason);
		}
	}

	@:noCompletion private inline function __prepareLifecycle():Void {
		if (__lifecycleReady || __socket == null) {
			return;
		}

		__lifecycleReady = true;
		if (!connected) {
			__socket.addEventListener(Event.CONNECT, socket_onReady);
		}
		__socket.addEventListener(Event.CLOSE, socket_onClose);
		__socket.addEventListener(IOErrorEvent.IO_ERROR, socket_onIoError);
	}

	@:noCompletion private inline function __disposeLifecycle():Void {
		if (!__lifecycleReady || __socket == null) {
			return;
		}

		__lifecycleReady = false;
		__socket.removeEventListener(Event.CONNECT, socket_onReady);
		__socket.removeEventListener(Event.CLOSE, socket_onClose);
		__socket.removeEventListener(IOErrorEvent.IO_ERROR, socket_onIoError);
	}

	@:noCompletion private static inline function __noopReady():Void {}

	@:noCompletion private static inline function __noopData(_:ByteArrayInput):Void {}

	@:noCompletion private static inline function __noopClose(_:Reason):Void {}

	@:noCompletion private static inline function __noopError(_:Reason):Void {}
}
#end
