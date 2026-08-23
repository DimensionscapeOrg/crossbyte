package crossbyte.net;

// Not built for the browser: it listens, over UDP, neither of which a page can do.
#if !(js && !nodejs)

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import haxe.ds.StringMap;
#if nodejs
import crossbyte._internal.net.IPv6;
#else
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

		@param timeoutMs Session timeout in milliseconds, or `0` for the default.
		@throws IOError if this server is closed, unbound, or not listening.
		@throws ArgumentError if the address cannot be resolved, or a session to
		this endpoint already exists.
	**/
	public function connect(address:String, port:Int, timeoutMs:Int = 0):ReliableDatagramSocket {
		if (__closed) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (!bound) {
			throw new IOError("Cannot dial from a server socket that is not bound.");
		}

		if (!listening) {
			throw new IOError("Cannot dial from a server socket that is not listening: replies are routed by the listen pump, so nothing would deliver them.");
		}

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

		var socket = ReliableDatagramSocket.__createDialed(__socket, resolved, port, this, socketMode, timeoutMs);
		__connections.set(key, socket);
		return socket;
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
