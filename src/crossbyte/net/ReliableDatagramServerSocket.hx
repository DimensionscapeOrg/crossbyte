package crossbyte.net;

import crossbyte.errors.IOError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import haxe.ds.StringMap;

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

	@:noCompletion private var __closed:Bool = false;
	@:noCompletion private var __connections:StringMap<ReliableDatagramSocket>;
	@:noCompletion private var __socket:DatagramSocket;

	/**
		Creates a new reliable datagram server socket.
	**/
	public function new() {
		super();

		__connections = new StringMap();
		__socket = new DatagramSocket();
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
		Stops listening, closes every accepted reliable session, and closes the
		underlying UDP transport.
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

		var connections:Array<ReliableDatagramSocket> = [];
		for (connection in __connections) {
			connections.push(connection);
		}
		__connections = new StringMap();

		for (connection in connections) {
			try {
				connection.__dispose(true);
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

	@:noCompletion private inline function __endpointKey(address:String, port:Int):String {
		return address + ":" + port;
	}

	@:noCompletion private function __onData(e:DatagramSocketDataEvent):Void {
		var key:String = __endpointKey(e.srcAddress, e.srcPort);
		var connection:ReliableDatagramSocket = __connections.get(key);
		var frame = ReliableDatagramProtocol.decode(e.data);
		if (frame == null) {
			return;
		}

		if (connection != null) {
			connection.__acceptFrame(frame);
			return;
		}

		if (!listening || frame.type != ReliableDatagramFrameType.CONNECT) {
			return;
		}

		connection = ReliableDatagramSocket.__createAccepted(__socket, e.srcAddress, e.srcPort, this, socketMode);
		__connections.set(key, connection);
	}

	@:noCompletion private function __onSocketClosed(socket:ReliableDatagramSocket):Void {
		__connections.remove(__endpointKey(socket.remoteAddress, socket.remotePort));
	}

	@:noCompletion private function __onSocketConnected(socket:ReliableDatagramSocket):Void {
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
