package crossbyte.net;

import crossbyte._internal.socket.IPollableSocket;
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.EventType;
import crossbyte.events.IOErrorEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import haxe.io.Bytes;
import haxe.io.Eof;
import haxe.io.Error as HxIOError;
import sys.net.Address;
import sys.net.Host;
import sys.net.UdpSocket;

@:access(crossbyte.core.CrossByte)
/**
	The `DatagramSocket` class provides connectionless User Datagram Protocol (UDP)
	communication in a way that integrates with CrossByte's socket registry and
	thread-local event loop.
	A datagram socket can either be bound for listening and sending to arbitrary
	remote endpoints, or connected to a specific remote endpoint for simpler
	send and receive calls. Incoming payloads are dispatched as
	`DatagramSocketDataEvent.DATA` events.
	Unlike TCP sockets, UDP preserves message boundaries and does not guarantee
	delivery, ordering, or retransmission.
	@event close Dispatched when the socket is closed.
	@event ioError Dispatched when an I/O error occurs while sending or receiving.
	@event data Dispatched when a complete UDP payload has been received.
**/
class DatagramSocket extends EventDispatcher implements IPollableSocket {
	/**
		Indicates whether UDP sockets are supported by the current target.
	**/
	public static var isSupported(default, null):Bool = #if sys true #else false #end;

	/**
		Indicates whether the socket is currently bound to a local address and port.
	**/
	public var bound(get, never):Bool;

	/**
		Indicates whether the socket is connected to a default remote endpoint.
		When connected, `send()` can omit the `address` and `port` arguments.
	**/
	public var connected(get, never):Bool;

	/**
		The byte order used for `ByteArray` payloads dispatched by this socket.
	**/
	public var endian(get, set):Endian;

	/**
		The local IP address the socket is currently bound to, or an empty string if
		the socket is not bound.
	**/
	public var localAddress(get, never):String;

	/**
		The local UDP port the socket is currently bound to, or `0` if the socket is
		not bound.
	**/
	public var localPort(get, never):Int;

	/**
		Indicates whether the socket is actively receiving and dispatching datagrams.
	**/
	public var receiving(get, never):Bool;

	/**
		Used internally by the socket registry to determine whether this socket can
		continue to be polled.
	**/
	public var registryClosed(get, never):Bool;

	/**
		The default remote IP address for a connected socket, or an empty string when
		the socket is not connected.
	**/
	public var remoteAddress(get, never):String;

	/**
		The default remote UDP port for a connected socket, or `0` when the socket is
		not connected.
	**/
	public var remotePort(get, never):Int;

	/**
		The socket timeout, in milliseconds, applied to the underlying UDP socket.
	**/
	public var timeout(get, set):Int;

	@:noCompletion private static inline var DEFAULT_BUFFER_SIZE:Int = 65535;

	@:noCompletion private var __bound:Bool = false;
	@:noCompletion private var __cbInstance:CrossByte;
	@:noCompletion private var __closed:Bool = false;
	@:noCompletion private var __connected:Bool = false;
	@:noCompletion private var __endian:Endian = Endian.BIG_ENDIAN;
	@:noCompletion private var __readBuffer:Bytes;
	@:noCompletion private var __receiving:Bool = false;
	@:noCompletion private var __registered:Bool = false;
	@:noCompletion private var __remoteAddress:String = "";
	@:noCompletion private var __remotePort:Int = 0;
	@:noCompletion private var __socket:UdpSocket;
	@:noCompletion private var __tempAddress:Address;
	@:noCompletion private var __timeout:Int = 20000;

	/**
		Creates a new `DatagramSocket`.
		If `host` and `port` are supplied, the socket attempts to connect to that
		remote endpoint immediately.
		@param host The remote host to connect to. Pass `null` to create an unconnected socket.
		@param port The remote UDP port to connect to. Pass `0` to create an unconnected socket.
	**/
	public function new(host:String = null, port:Int = 0) {
		super();

		__readBuffer = Bytes.alloc(DEFAULT_BUFFER_SIZE);
		__tempAddress = new Address();
		__initSocket();

		if (host != null || port != 0) {
			connect(host, port);
		}
	}

	/**
		Binds the socket to a local UDP port and address.
		@param localPort The local port to bind to. Use `0` to let the operating system choose a free port.
		@param localAddress The local IP address to bind to. Use `"0.0.0.0"` to bind on all IPv4 interfaces.
		@throws RangeError If `localPort` is outside the valid UDP port range.
		@throws ArgumentError If `localAddress` cannot be resolved.
		@throws IOError If the socket cannot be bound.
	**/
	public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		__validatePort(localPort);

		try {
			__socket.bind(new Host(localAddress), localPort);
			__bound = true;
		} catch (e:Dynamic) {
			switch (Std.string(e)) {
				case "Bind failed":
					throw new IOError("Operation attempted on invalid socket.");
				case "Unresolved host":
					throw new ArgumentError("One of the parameters is invalid");
				default:
					throw new IOError("Operation attempted on invalid socket.");
			}
		}
	}

	/**
		Closes the socket and stops any active receive loop.
		After a socket has been closed, create a new instance to use UDP again.
	**/
	public function close():Void {
		if (__socket == null) {
			return;
		}

		stopReceiving();
		try {
			__socket.close();
		} catch (_:Dynamic) {}
		__socket = null;
		__bound = false;
		__connected = false;
		__closed = true;
		dispatchEvent(new Event(Event.CLOSE));
	}

	/**
		Connects the socket to a default remote UDP endpoint.
		Once connected, `send()` can omit its `address` and `port` parameters and
		received datagrams are limited to the connected peer.
		@param host The remote host to connect to.
		@param port The remote UDP port to connect to.
		@throws ArgumentError If `host` is invalid or empty.
		@throws RangeError If `port` is outside the valid UDP port range.
		@throws IOError If the socket cannot connect.
	**/
	public function connect(host:String, port:Int):Void {
		if (host == null || host.length == 0) {
			throw new ArgumentError("One of the parameters is invalid");
		}

		__validatePort(port);

		try {
			var remote:Host = new Host(host);
			__socket.connect(remote, port);
			__connected = true;
			__remoteAddress = remote.toString();
			__remotePort = port;
			__bound = __getLocalEndpoint() != null;
		} catch (e:Dynamic) {
			switch (Std.string(e)) {
				case "Bind failed":
					throw new IOError("Operation attempted on invalid socket.");
				case "Unresolved host":
					throw new ArgumentError("One of the parameters is invalid");
				default:
					throw new IOError("Operation attempted on invalid socket.");
			}
		}
	}

	/**
		Begins receiving datagrams and dispatching `DatagramSocketDataEvent.DATA`
		events on the current CrossByte thread.
		@throws IOError If the socket is not valid.
	**/
	public function receive():Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (__receiving) {
			return;
		}

		__cbInstance = CrossByte.current();
		if (__cbInstance == null) {
			throw "DatagramSocket can only be initiated in a CrossByte threaded instance";
		}

		__receiving = true;
		__syncPolling();
	}

	/**
		Sends a UDP payload.
		If the socket is connected, omit `address` and `port` to send to the connected
		remote endpoint. If the socket is unconnected, `address` and `port` are required.
		@param bytes The payload bytes to send.
		@param offset The zero-based offset into `bytes` at which sending should begin.
		@param length The number of bytes to send. Use `0` to send all remaining bytes from `offset`.
		@param address The destination IP address for an unconnected socket.
		@param port The destination UDP port for an unconnected socket.
		@throws ArgumentError If the destination information is invalid.
		@throws RangeError If `offset`, `length`, or `port` are out of range.
		@throws IllegalOperationError If a connected socket is asked to send to an explicit alternate destination.
		@throws IOError If the send operation fails.
	**/
	public function send(bytes:ByteArray, offset:Int = 0, length:Int = 0, address:String = null, port:Int = 0):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		var totalLength:Int = bytes.length;
		if (offset < 0 || offset > totalLength) {
			throw new RangeError("The supplied index is out of bounds.");
		}

		if (length == 0) {
			length = totalLength - offset;
		}

		if (length < 0 || offset + length > totalLength) {
			throw new RangeError("The supplied index is out of bounds.");
		}

		if (address == null) {
			if (!__connected) {
				throw new ArgumentError("One of the parameters is invalid");
			}

			address = __remoteAddress;
			port = __remotePort;
		} else if (__connected) {
			throw new IllegalOperationError("Cannot send data to a location when connected.");
		}

		__validatePort(port);

		try {
			var host:Host = new Host(address);
			var target:Address = new Address();
			target.host = host.ip;
			target.port = port;
			__socket.sendTo(cast bytes, offset, length, target);
			__bound = __getLocalEndpoint() != null;
		} catch (e:HxIOError) {
			__dispatchIoError(Std.string(e));
			throw new IOError("Operation attempted on invalid socket.");
		} catch (e:Dynamic) {
			switch (Std.string(e)) {
				case "Unresolved host":
					throw new ArgumentError("One of the parameters is invalid");
				default:
					throw new IOError("Operation attempted on invalid socket.");
			}
		}
	}

	/**
		Stops receiving datagrams and removes the socket from the registry if it is
		currently being polled.
	**/
	public function stopReceiving():Void {
		__receiving = false;
		__syncPolling();
	}

	override public function addEventListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		var shouldSync:Bool = type == DatagramSocketDataEvent.DATA && !hasEventListener(DatagramSocketDataEvent.DATA);
		super.addEventListener(type, listener, priority);
		if (shouldSync) {
			__syncPolling();
		}
	}

	override public function removeEventListener<T>(type:EventType<T>, listener:T->Void):Void {
		super.removeEventListener(type, listener);
		if (type == DatagramSocketDataEvent.DATA && !hasEventListener(DatagramSocketDataEvent.DATA)) {
			__syncPolling();
		}
	}

	public function registryOnReadable():Void {
		if (!__receiving || __socket == null) {
			return;
		}

		while (__receiving) {
			var bytesReady:Int = 0;
			try {
				bytesReady = __socket.readFrom(__readBuffer, 0, __readBuffer.length, __tempAddress);
			} catch (_:Eof) {
				break;
			} catch (e:HxIOError) {
				switch (e) {
					case Blocked, Custom(Blocked):
						return;
					default:
						__dispatchIoError(Std.string(e));
						return;
				}
			} catch (e:Dynamic) {
				if (Std.string(e) == "Blocking") {
					return;
				}
				__dispatchIoError(Std.string(e));
				return;
			}

			if (bytesReady <= 0) {
				return;
			}

			var packetBytes:Bytes = Bytes.alloc(bytesReady);
			packetBytes.blit(0, __readBuffer, 0, bytesReady);

			var local = __getLocalEndpoint();
			var srcHost:Host = __tempAddress.getHost();
			var payload:ByteArray = ByteArray.fromBytes(packetBytes);
			payload.endian = __endian;

			dispatchEvent(new DatagramSocketDataEvent(
				DatagramSocketDataEvent.DATA,
				srcHost.toString(),
				__tempAddress.port,
				local != null ? local.host.toString() : "",
				local != null ? local.port : 0,
				payload
			));
		}
	}

	public inline function registryOnWritable():Void {}

	@:noCompletion private function __dispatchIoError(message:String):Void {
		stopReceiving();
		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
	}

	@:noCompletion private function __syncPolling():Void {
		var shouldPoll:Bool = __receiving && hasEventListener(DatagramSocketDataEvent.DATA);
		if (shouldPoll && !__registered && __cbInstance != null && __socket != null) {
			__cbInstance.registerSocket(__socket);
			__registered = true;
			return;
		}

		if (!shouldPoll && __registered && __cbInstance != null && __socket != null) {
			__cbInstance.deregisterSocket(__socket);
			__registered = false;
		}
	}

	@:noCompletion private inline function __getLocalEndpoint():{host:Host, port:Int} {
		if (__socket == null) {
			return null;
		}

		try {
			return __socket.host();
		} catch (_:Dynamic) {
			return null;
		}
	}

	@:noCompletion private function __initSocket():Void {
		__socket = new UdpSocket();
		__socket.setBlocking(false);
		try {
			__socket.setFastSend(true);
		} catch (_:Dynamic) {}
		__socket.setTimeout(__timeout / 1000);
		__socket.custom = this;
		__closed = false;
	}

	@:noCompletion private inline function __validatePort(port:Int):Void {
		if (port < 0 || port > 65535) {
			throw new RangeError("Invalid socket port number specified.");
		}
	}

	@:noCompletion private inline function get_bound():Bool {
		return __bound;
	}

	@:noCompletion private inline function get_connected():Bool {
		return __connected;
	}

	@:noCompletion private inline function get_endian():Endian {
		return __endian;
	}

	@:noCompletion private inline function get_localAddress():String {
		var local = __getLocalEndpoint();
		return local != null ? local.host.toString() : "";
	}

	@:noCompletion private inline function get_localPort():Int {
		var local = __getLocalEndpoint();
		return local != null ? local.port : 0;
	}

	@:noCompletion private inline function get_receiving():Bool {
		return __receiving;
	}

	@:noCompletion private inline function get_registryClosed():Bool {
		return __closed || __socket == null;
	}

	@:noCompletion private inline function get_remoteAddress():String {
		return __remoteAddress;
	}

	@:noCompletion private inline function get_remotePort():Int {
		return __remotePort;
	}

	@:noCompletion private inline function get_timeout():Int {
		return __timeout;
	}

	@:noCompletion private inline function set_endian(value:Endian):Endian {
		return __endian = value;
	}

	@:noCompletion private function set_timeout(value:Int):Int {
		if (value < 0) {
			throw new RangeError("Invalid socket timeout specified.");
		}

		__timeout = value;
		if (__socket != null) {
			__socket.setTimeout(value / 1000);
		}
		return value;
	}
}
