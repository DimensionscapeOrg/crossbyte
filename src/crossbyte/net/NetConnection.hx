package crossbyte.net;

import crossbyte.errors.IOError;
import crossbyte.net.Endpoint.parseURL;
import crossbyte.errors.SecurityError;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.Event;
import crossbyte.io.ByteArrayInput;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;

@:forward
abstract NetConnection(INetConnection) from INetConnection to INetConnection {
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
			default:
				throw('Protocol error');
				null;
		}
	}

	public static inline function toSocket(connection:NetConnection):Socket {
		var socket:Socket = null;

		if (connection.protocol == TCP) {
			socket = (cast connection : TCPConnection).__socket;
		}

		return socket;
	}

	@:from
	public static inline function fromSocket(socket:Socket):NetConnection {
		var nc:NetConnection = new TCPConnection(socket);
		return nc;
	}

	public static inline function fromSocketWith(socket:Socket, ?onData:ByteArrayInput->Void, ?onReady:Void->Void, ?onClose:Reason->Void,
			?onError:Reason->Void, readEnabled:Bool = false):NetConnection {
		var nc:TCPConnection = new TCPConnection(socket);

		nc.onData = onData;
		nc.onClose = onClose;
		nc.onReady = onReady;
		nc.onError = onError;
		nc.readEnabled = readEnabled;

		return nc;
	}

	@:from
	public static inline function fromWebSocket(webSocket:WebSocket):NetConnection {
		@:privateAccess
		var nc:NetConnection = new WSConnection(webSocket);
		return nc;
	}

	@:from
	public static inline function fromDatagramSocket(datagramSocket:DatagramSocket):NetConnection {
		@:privateAccess
		var nc:NetConnection = new UDPConnection(datagramSocket);
		return nc;
	}
}

@:access(crossbyte.net.Socket)
@:allow(crossbyte.net.NetConnection)
private class TCPConnection implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var autoFlush:Bool = true;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var inTimestamp:Float = 0.0;
	public var outTimestamp:Float = 0.0;
	public var protocol:Protocol = TCP;
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

private class UDPConnection implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var socket:DatagramSocket;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var protocol:Protocol = UDP;
	public var inTimestamp:Float = 0.0;
	public var outTimestamp:Float = 0.0;

	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;

	@:noCompletion private var __socket:DatagramSocket;
	@:noCompletion private var __onData:ByteArrayInput->Void;
	@:noCompletion private var __onClose:Reason->Void;
	@:noCompletion private var __onError:Reason->Void;
	@:noCompletion private var __onReady:Void->Void;
	@:noCompletion private var __hasOnData:Bool;
	@:noCompletion private var __receiving:Bool = false;

	@:noCompletion private inline function get_remoteAddress():String {
		return ""; // __socket.remoteAddress;
	}

	@:noCompletion private inline function get_remotePort():Int {
		return 0; // __socket.remotePort;
	}

	@:noCompletion private inline function get_localAddress():String {
		return ""; // __socket.localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return 0; // __socket.localPort;
	}

	@:noCompletion private inline function get_connected():Bool {
		return false; // this.socket.connected;
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
		return false;
	}

	@:noCompletion private inline function get_readEnabled():Bool {
		return false;
	}

	private function new(socket:DatagramSocket) {
		this.socket = socket;
	}

	public inline function expose():Transport {
		return UDP(__socket);
	}

	public function send(data:ByteArray):Void {
		trace("SEND");
	}

	public inline function startReceiving():Void {}

	public inline function stopReceiving():Void {}

	public function close():Void {
		// socket.close();
	}

	@:noCompletion private static inline function __noopReady():Void {}

	@:noCompletion private static inline function __noopData(_:ByteArrayInput):Void {}

	@:noCompletion private static inline function __noopClose(_:Reason):Void {}

	@:noCompletion private static inline function __noopError(_:Reason):Void {}
}

private class WSConnection implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var socket:WebSocket;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var protocol:Protocol = WEBSOCKET;
	public var inTimestamp:Float = 0.0;
	public var outTimestamp:Float = 0.0;

	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;

	@:noCompletion private var __socket:WebSocket;
	@:noCompletion private var __onData:ByteArrayInput->Void;
	@:noCompletion private var __onClose:Reason->Void;
	@:noCompletion private var __onError:Reason->Void;
	@:noCompletion private var __onReady:Void->Void;
	@:noCompletion private var __hasOnData:Bool;
	@:noCompletion private var __receiving:Bool = false;

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
		return this.socket.connected;
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
		return false;
	}

	@:noCompletion private inline function get_readEnabled():Bool {
		return false;
	}

	private function new(socket:WebSocket) {
		this.socket = socket;
	}

	public inline function expose():Transport {
		return WEBSOCKET(__socket);
	}

	public inline function toSocket<T>():T {
		return cast __socket;
	}

	public function send(data:ByteArray):Void {
		trace("SEND");
	}

	public inline function startReceiving():Void {}

	public inline function stopReceiving():Void {}

	public function close():Void {
		socket.close();
	}

	@:noCompletion private static inline function __noopReady():Void {}

	@:noCompletion private static inline function __noopData(_:ByteArrayInput):Void {}

	@:noCompletion private static inline function __noopClose(_:Reason):Void {}

	@:noCompletion private static inline function __noopError(_:Reason):Void {}
}
