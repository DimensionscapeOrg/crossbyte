package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.IOError;
import crossbyte.net.Endpoint.parseURL;
import crossbyte.errors.SecurityError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.Event;
import crossbyte.io.ByteArrayInput;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.events.ReliableDatagramSocketConnectEvent;

/**
 * High-level connection wrapper over CrossByte's supported stream transports.
 *
 * `NetConnection` normalizes TCP, WebSocket, and reliable datagram sockets
 * behind the `INetConnection` contract. Use the callback properties for the hot
 * data path and the static conversion helpers when you need to reach the
 * underlying transport type.
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
	/** Called when the connection closes. */
	public var onClose(get, set):Reason->Void;
	/** Called when the transport reports an error. */
	public var onError(get, set):Reason->Void;
	/** Called once the connection becomes ready for I/O. */
	public var onReady(get, set):Void->Void;

	/**
	 * Connects to a transport URI and wraps the resulting connection.
	 *
	 * Supported schemes are `tcp://`, `ws://`, `wss://`, and `rudp://`.
	 */
	public inline function new(uri:String, ?onData:ByteArrayInput->Void, ?onReady:Void->Void, ?onClose:Reason->Void, ?onError:Reason->Void,
			readEnabled:Bool = false):Void {
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

	/** Closes the wrapped transport. */
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

	@:from
	/** Wraps an existing TCP socket as a `NetConnection`. */
	public static inline function fromSocket(socket:Socket):NetConnection {
		var nc:NetConnection = new TCPConnection(socket);
		return nc;
	}

	@:from
	/** Wraps an arbitrary `INetConnection`, adapting external implementations when needed. */
	public static inline function fromINetConnection(connection:INetConnection):NetConnection {
		if (Std.isOfType(connection, NetConnectionBase)) {
			return cast connection;
		}
		return new NetConnectionAdapter(connection);
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
		return __connection.onClose;
	}

	@:noCompletion private inline function set_onClose(value:Reason->Void):Reason->Void {
		return __connection.onClose = value;
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __connection.onError;
	}

	@:noCompletion private inline function set_onError(value:Reason->Void):Reason->Void {
		return __connection.onError = value;
	}

	@:noCompletion private inline function get_onReady():Void->Void {
		return __connection.onReady;
	}

	@:noCompletion private inline function set_onReady(value:Void->Void):Void->Void {
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
		readEnabled = false;
		__disposeLifecycle();
		__onClose(Reason.Closed);
		try {
			__socket.close();
		} catch (_:Dynamic) {}
	}

	@:noCompletion private inline function __writeBytes(bytes:ByteArray, offset:Int, length:Int):Void {
		if (__socket.__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__socket.__output.writeBytes(bytes, offset, length);
		outTimestamp = __socket.__cbInstance.uptime;
	}

	@:noCompletion private inline function socket_onData(_e:ProgressEvent):Void {
		inTimestamp = __socket.__cbInstance.uptime;
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
		readEnabled = false;
		__onClose(Reason.Closed);
	}

	@:noCompletion private inline function socket_onReady(_e:Event):Void {
		__socket.removeEventListener(Event.CONNECT, socket_onReady);
		__onReady();
	}

	@:noCompletion private inline function socket_onIoError(e:IOErrorEvent):Void {
		readEnabled = false;
		__onError(Reason.Error(e.text));
	}

	@:noCompletion private inline function socket_onSecError(e:SecurityError):Void {
		readEnabled = false;
		__onError(Reason.Error(e.message));
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
		readEnabled = false;
		__disposeLifecycle();
		__onClose(Reason.Closed);
		__socket.close();
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
		readEnabled = false;
		__onClose(Reason.Closed);
	}

	@:noCompletion private inline function socket_onReady(_e:Event):Void {
		__socket.removeEventListener(Event.CONNECT, socket_onReady);
		__onReady();
	}

	@:noCompletion private inline function socket_onIoError(e:IOErrorEvent):Void {
		readEnabled = false;
		__onError(Reason.Error(e.text));
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
		readEnabled = false;
		__disposeLifecycle();
		__onClose(Reason.Closed);
		__socket.close();
	}

	@:noCompletion private inline function socket_onData(_e:ProgressEvent):Void {
		@:privateAccess {
			inTimestamp = __socket.__cbInstance != null ? __socket.__cbInstance.uptime : 0.0;
			__onData(__socket.__input);
		}
	}

	@:noCompletion private inline function socket_onClose(_e:Event):Void {
		readEnabled = false;
		__onClose(Reason.Closed);
	}

	@:noCompletion private inline function socket_onReady(_e:Event):Void {
		__socket.removeEventListener(Event.CONNECT, socket_onReady);
		__onReady();
	}

	@:noCompletion private inline function socket_onIoError(e:IOErrorEvent):Void {
		readEnabled = false;
		__onError(Reason.Error(e.text));
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
