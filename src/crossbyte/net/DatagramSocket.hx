package crossbyte.net;

// Not built for the browser. UDP has no web equivalent -- WebRTC data channels are the nearest thing and are a different protocol with a different API, not a drop-in. Node has dgram, so it has real UDP.
#if !(js && !nodejs)

#if nodejs
import js.node.Buffer;
import js.node.Dgram;
import js.node.dgram.Socket as NodeDatagram;
#else
import crossbyte._internal.socket.IPollableSocket;
#end
import crossbyte.core.CrossByte;
import crossbyte._internal.net.IPv6;
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
#if !js
import sys.net.Address;
import sys.net.Host;
import sys.net.UdpSocket;
#end

#if cpp
@:cppFileCode("
#ifdef HX_WINDOWS
#include <winsock2.h>
#else
#include <sys/socket.h>
#endif

namespace {
// hxcpp's socket handle as its Socket.cpp declares it: an hx::Object holding
// the descriptor. Mirrored rather than reached, since hxcpp keeps it private
// to that file, and checked by class id before it is trusted -- as NativeAlpn
// does for the TLS handles.
struct CrossByteSocketHandle : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdSocket };
#ifdef HX_WINDOWS
	SOCKET socket;
#else
	int socket;
#endif
};

bool crossbyte_socket_of(::Dynamic handle, CrossByteSocketHandle **out) {
	if (handle.mPtr == 0 || !handle.mPtr->_hx_isInstanceOf(hx::clsIdSocket)) {
		return false;
	}
	*out = reinterpret_cast<CrossByteSocketHandle *>(handle.mPtr);
	return true;
}
}

// One of a socket's buffer sizes, or -1 where it cannot be read.
static int crossbyte_udp_buffer(::Dynamic handle, bool receive) {
	CrossByteSocketHandle *s;
	if (!crossbyte_socket_of(handle, &s)) {
		return -1;
	}
	int size = 0;
#ifdef HX_WINDOWS
	int length = sizeof(size);
#else
	socklen_t length = sizeof(size);
#endif
	if (getsockopt(s->socket, SOL_SOCKET, receive ? SO_RCVBUF : SO_SNDBUF, (char *)&size, &length) != 0) {
		return -1;
	}
	return size;
}

// Asks for one of a socket's buffer sizes; false if the system refused.
static bool crossbyte_udp_set_buffer(::Dynamic handle, bool receive, int size) {
	CrossByteSocketHandle *s;
	if (!crossbyte_socket_of(handle, &s)) {
		return false;
	}
	return setsockopt(s->socket, SOL_SOCKET, receive ? SO_RCVBUF : SO_SNDBUF, (const char *)&size, sizeof(size)) == 0;
}
")
#end
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
class DatagramSocket extends EventDispatcher #if !nodejs implements IPollableSocket #end {
	/**
		Indicates whether UDP sockets are supported by the current target.

		Neko is excluded despite being a sys target, because its
		`sys.net.UdpSocket` constructor throws "Not available on this platform".
		This said `true` there and then threw on the first socket, which is the
		one thing a support flag exists to prevent -- a caller checks it so it
		can take the other path, and a flag that lies leaves no other path to
		take.
	**/
	public static var isSupported(default, null):Bool = #if (nodejs || (sys && !eval && !neko)) true #else false #end;

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

	/**
		How many bytes of arriving datagrams the operating system holds for
		this socket until they are read. Past it, what arrives is dropped.

		The system's default is small -- 64 KB on Windows, a little over 200 KB
		on Linux -- and a burst larger than it that arrives while the program
		is busy elsewhere is mostly lost. A socket that many peers send to, or
		a peer that sends a window of datagrams at once, wants more.

		What is granted may not be what was asked. Linux caps it at
		`net.core.rmem_max` unless that is raised, and reports twice what it
		keeps, counting its own bookkeeping; every system rounds. Read it back
		to know. On Node it is applied once the socket is bound, and reads as
		what was asked until then. It reads 0 on targets with no way to size
		a socket's buffers -- eval, HashLink and Neko -- and setting it there
		changes nothing.

		@throws RangeError If set below 1.
		@throws IOError If set once the socket is closed, or if the system
		        refuses it.
	**/
	public var receiveBufferSize(get, set):Int;

	/**
		How many bytes of datagrams being sent the operating system holds for
		this socket before they leave. As `receiveBufferSize`, for the other
		direction.

		@throws RangeError If set below 1.
		@throws IOError If set once the socket is closed, or if the system
		        refuses it.
	**/
	public var sendBufferSize(get, set):Int;

	@:noCompletion private static inline var DEFAULT_BUFFER_SIZE:Int = 65535;
	@:noCompletion private static inline var MAX_DATAGRAMS_PER_TICK:Int = 64;

	// Failed reads in a row, with nothing succeeding between them, before the
	// socket is called broken rather than merely complained at. Generous on
	// purpose: the cost of guessing high is a socket that stays deaf a little
	// longer than it might, and the cost of guessing low is the bug this
	// replaces -- one stray ICMP silencing a working socket.
	@:noCompletion private static inline var MAX_CONSECUTIVE_READ_FAILURES:Int = 64;

	@:noCompletion private var __bound:Bool = false;
	@:noCompletion private var __cbInstance:CrossByte;
	#if nodejs
	// Buffer sizes asked for, applied when the socket is bound: Node cannot
	// size a socket before then, and replaces an unbound one freely.
	@:noCompletion private var __receiveBufferRequest:Int = 0;
	@:noCompletion private var __sendBufferRequest:Int = 0;
	#end
	@:noCompletion private var __closed:Bool = false;

	// Reads that failed with nothing succeeding in between. A stray ICMP error
	// produces one; a socket that has genuinely stopped working produces them
	// without end, which is the difference this counts.
	@:noCompletion private var __consecutiveReadFailures:Int = 0;
	@:noCompletion private var __connected:Bool = false;
	@:noCompletion private var __endian:Endian = Endian.BIG_ENDIAN;
	@:noCompletion private var __readBuffer:Bytes;
	@:noCompletion private var __receiving:Bool = false;
	@:noCompletion private var __registered:Bool = false;
	@:noCompletion private var __remoteAddress:String = "";
	@:noCompletion private var __remotePort:Int = 0;
	#if nodejs
	@:noCompletion private var __socket:NodeDatagram;
	// Chosen from the first address this socket is given, because Node fixes
	// the family when the socket is made where a sys.net.UdpSocket does not.
	@:noCompletion private var __family:String = null;
	@:noCompletion private var __localAddress:String = "";
	@:noCompletion private var __localPort:Int = 0;
	#else
	@:noCompletion private var __socket:UdpSocket;
	@:noCompletion private var __tempAddress:Address;
	#end
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
		#if !nodejs
		__tempAddress = new Address();
		#end
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
			#if nodejs
			// Node binds asynchronously and reports a refusal as an event, so
			// a failure here arrives as ioError rather than out of this call
			// -- the same shape ServerSocket takes on Node, and for the same
			// reason.
			var socket = __nodeSocket(localAddress);
			socket.bind(localPort, localAddress, function():Void {
				__rememberLocalEndpoint();
			});
			__bound = true;
			#else
			__socket.bind(new Host(localAddress), localPort);
			__bound = true;
			#end
		} catch (e:Dynamic) {
			switch (Std.string(e)) {
				case "Unresolved host":
					throw new ArgumentError("One of the parameters is invalid");
				default:
					// Named for what actually failed, and carrying the reason.
					// "Bind failed" used to be answered with "Operation
					// attempted on invalid socket.", which describes a socket
					// that was in fact fine -- it was the address or the port
					// that would not take.
					throw new IOError("Could not bind to " + localAddress + ":" + localPort + ": " + Std.string(e));
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

		__validateRemotePort(port);

		try {
			#if nodejs
			// Node grew a connect() for datagram sockets in v12, but the
			// extern predates it. Emulated instead: the remote is remembered,
			// send() names it every time, and __receiveNode drops anything
			// from anywhere else -- which is the whole of what connecting a
			// UDP socket does.
			//
			// That filter is why a name is refused here. A reply arrives
			// carrying the numeric address it came from, so a name kept as
			// given would match nothing and the socket would silently receive
			// none of its peer's traffic. Resolving one needs a callback on
			// Node, which connect() has no way to wait for.
			if (!IPv6.isNumericAddress(host)) {
				throw new ArgumentError("A connected DatagramSocket needs a numeric address on Node, not a name: a datagram reports the address it came from, and a session is matched on it. Resolve the name first, or leave the socket unconnected and name the destination in send().");
			}

			__nodeSocket(host);
			__connected = true;
			__remoteAddress = IPv6.compress(host);
			__remotePort = port;
			__rememberLocalEndpoint();
			#else
			var remote:Host = new Host(host);
			__socket.connect(remote, port);
			__connected = true;
			__remoteAddress = IPv6.compress(remote.toString());
			__remotePort = port;
			__bound = __getLocalEndpoint() != null;
			#end
		} catch (e:Dynamic) {
			switch (Std.string(e)) {
				case "Unresolved host":
					throw new ArgumentError("One of the parameters is invalid");
				default:
					// Named for what actually failed, and carrying the reason.
					// "Bind failed" used to be answered with "Operation
					// attempted on invalid socket.", which describes a socket
					// that was in fact fine -- it was the address or the port
					// that would not take.
					throw new IOError("Could not connect to " + host + ":" + port + ": " + Std.string(e));
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
		if (bytes == null) {
			throw new ArgumentError("One of the parameters is invalid");
		}

		var totalLength:Int = bytes.length;
		if (offset < 0 || offset > totalLength) {
			throw new RangeError("The supplied index is out of bounds.");
		}

		if (length == 0) {
			length = totalLength - offset;
		}

		// Against the bytes left after `offset` rather than `offset +
		// length`. That sum overflows for a large length and wraps
		// negative, so the range check passed and the send read past the
		// end of the buffer.
		if (length < 0 || length > totalLength - offset) {
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

		__validateRemotePort(port);

		try {
			#if nodejs
			// Copied into a buffer of its own: Buffer.hxFromBytes wraps the
			// storage it is given rather than copying, and Node sends when it
			// gets round to it -- so anything the caller wrote to this
			// ByteArray in the meantime would go out instead of what it asked
			// to send.
			var payload:ByteArray = new ByteArray();
			payload.writeBytes(bytes, offset, length);
			__nodeSocket(address).send(Buffer.hxFromBytes(payload), 0, length, port, address);
			__rememberLocalEndpoint();
			#else
			var host:Host = new Host(address);
			var target:Address = new Address();
			target.setHost(host);
			target.port = port;
			__socket.sendTo(cast bytes, offset, length, target);
			__bound = __getLocalEndpoint() != null;
			#end
		} catch (e:HxIOError) {
			// The listener already gets the real reason; so does the caller.
			__dispatchSendError(Std.string(e));
			throw new IOError("Send to " + address + ":" + port + " failed: " + Std.string(e));
		} catch (e:Dynamic) {
			switch (Std.string(e)) {
				case "Unresolved host":
					throw new ArgumentError("One of the parameters is invalid");
				default:
					throw new IOError("Send to " + address + ":" + port + " failed: " + Std.string(e));
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

	#if !nodejs
	public function registryOnReadable():Void {
		if (!__receiving || __socket == null) {
			return;
		}

		var processed:Int = 0;
		while (__receiving && processed < MAX_DATAGRAMS_PER_TICK) {
			var bytesReady:Int = 0;
			try {
				bytesReady = __socket.readFrom(__readBuffer, 0, __readBuffer.length, __tempAddress);
			} catch (_:Eof) {
				break;
			} catch (e:HxIOError) {
				if (__isBlockedError(e)) {
					return;
				}
				__onReadFailed(Std.string(e));
				return;
			} catch (e:Dynamic) {
				if (__isBlockedError(e)) {
					return;
				}
				__onReadFailed(Std.string(e));
				return;
			}

			if (bytesReady <= 0) {
				return;
			}

			__consecutiveReadFailures = 0;

			var packetBytes:Bytes = Bytes.alloc(bytesReady);
			packetBytes.blit(0, __readBuffer, 0, bytesReady);

			var local = __getLocalEndpoint();
			var srcHost:Host = __tempAddress.getHost();
			var payload:ByteArray = ByteArray.fromBytes(packetBytes);
			payload.endian = __endian;

			dispatchEvent(new DatagramSocketDataEvent(
				DatagramSocketDataEvent.DATA,
				IPv6.compress(srcHost.toString()),
				__tempAddress.port,
				local != null ? IPv6.compress(local.host.toString()) : "",
				local != null ? local.port : 0,
				payload
			));

			processed++;
		}
	}

	public inline function registryOnWritable():Void {}

	/**
		Never. UDP carries no TLS here, so the kernel is the only place a
		datagram can be waiting.
	**/
	public inline function registryHasBufferedInput():Bool {
		return false;
	}
	#end

	/**
		A read that failed, on a socket that has no connection to lose.

		This used to go straight to `__dispatchIoError`, which calls
		`stopReceiving()` -- so one failed read deafened the socket for good. On
		a connectionless socket that is the wrong reading of what a read error
		is. Send a datagram to a port nothing listens on and the peer's stack
		answers ICMP port unreachable; Windows reports that back to the sender
		as an error on a *later* read, which is then consumed by it. The
		datagram it complains about is already gone, and the socket is fine.

		Measured before changing anything: one datagram to a closed local port
		and a socket that had just completed a STUN exchange stopped receiving
		entirely, reporting `Custom(Socket operation failed)`. For a
		peer-to-peer mesh that is not an edge case -- dialling peers that have
		since left is ordinary -- and one departed peer should not silence
		every other.

		So a failed read ends this tick's loop and nothing more. A socket that
		is genuinely broken keeps failing, and the run counter is what tells
		the two apart: nothing succeeds in between, the count climbs, and the
		error is reported for real rather than swallowed.
	**/
	@:noCompletion private function __onReadFailed(message:String):Void {
		__consecutiveReadFailures++;

		if (__consecutiveReadFailures >= MAX_CONSECUTIVE_READ_FAILURES) {
			__consecutiveReadFailures = 0;
			__dispatchIoError(message);
		}
	}

	@:noCompletion private function __dispatchIoError(message:String):Void {
		stopReceiving();
		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
	}

	/**
		Reports a send that failed, without deafening the socket.

		A datagram that could not be sent is one datagram. Nothing about the
		socket has changed: it is still bound, still readable, and still the
		only way anything reaches this endpoint -- so stopping reception because
		one destination was unroutable throws away every other peer over an
		error about one of them.

		That is not hypothetical. ICE finds a path by trying every candidate a
		peer offered, and most of them fail: a candidate on a network this host
		cannot reach, or an IPv6 address on a socket bound to IPv4, refuses at
		the `sendto` and is meant to. Routing that into `__dispatchIoError` --
		which is what this did -- meant the first such attempt stopped the
		socket receiving, permanently and silently. A browser interoperability
		run found it: every check went out, none came back, and nothing said
		why.

		The caller still gets an `IOError` thrown, and the event still fires, so
		nothing that was reported before is reported less. What no longer
		happens is the socket going deaf over it.

		This is the same rule the read path already follows for the same reason.
		See `__onReadFailed`.
	**/
	@:noCompletion private function __dispatchSendError(message:String):Void {
		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
	}

	@:noCompletion private function __syncPolling():Void {
		#if nodejs
		// Nothing to synchronise. There is no descriptor to hand the registry
		// -- Node calls __receiveNode when a datagram arrives -- so whether
		// anything is delivered turns on __receiving alone, which the caller
		// has already set.
		return;
		#else
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
		#end
	}

	#if !nodejs
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
	#end

	#if nodejs
	@:noCompletion private function __initSocket():Void {
		// IPv4, matching the "0.0.0.0" that bind() defaults to and the family
		// most callers want. It is replaced below if an address turns up that
		// needs the other one.
		__makeNodeSocket("udp4");
		__closed = false;
	}

	@:noCompletion private function __makeNodeSocket(family:String):Void {
		__family = family;
		__socket = Dgram.createSocket({type: family});

		__socket.on("message", function(message:Buffer, remote:js.node.dgram.Socket.MessageRemoteInfo):Void {
			__receiveNode(message, remote);
		});

		__socket.on("error", function(e:Dynamic):Void {
			__dispatchIoError(Std.string(e));
		});
	}

	/**
	 * Returns the socket, swapping its address family first if the address
	 * about to be used needs the other one.
	 *
	 * Node fixes the family when the socket is created; a `sys.net.UdpSocket`
	 * does not, and takes whatever address it is later handed. So a socket
	 * that has not been bound or connected yet is simply replaced, which is
	 * free -- nothing has been done with it. One that has is left alone, and
	 * Node reports the mismatch itself rather than having it hidden here.
	 */
	@:noCompletion private function __nodeSocket(forAddress:String):NodeDatagram {
		var wanted:String = (forAddress != null && forAddress.indexOf(":") >= 0) ? "udp6" : "udp4";

		if (wanted != __family && !__bound && !__connected) {
			try {
				__socket.close();
			} catch (_:Dynamic) {}

			__makeNodeSocket(wanted);
		}

		return __socket;
	}

	/**
	 * Delivers one datagram.
	 *
	 * Two things gate it, and both are what the polled path does by asking the
	 * operating system rather than by checking. `receive()` not having been
	 * called means nothing should arrive, and a connected socket sees only its
	 * peer -- Node's own `connect()` would enforce the second, but the extern
	 * predates it, so the filter is here and the send path names the
	 * destination every time instead.
	 */
	@:noCompletion private function __receiveNode(message:Buffer, remote:js.node.dgram.Socket.MessageRemoteInfo):Void {
		if (!__receiving) {
			return;
		}

		var source:String = IPv6.compress(remote.address);

		if (__connected && (source != __remoteAddress || remote.port != __remotePort)) {
			return;
		}

		var payload:ByteArray = ByteArray.fromBytes(Bytes.ofData(message.buffer.slice(message.byteOffset, message.byteOffset + message.byteLength)));
		payload.endian = __endian;

		dispatchEvent(new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, source, remote.port, __localAddress, __localPort, payload));
	}

	@:noCompletion private function __rememberLocalEndpoint():Void {
		if (__socket == null) {
			return;
		}

		try {
			var local = __socket.address();

			if (local != null) {
				__localAddress = IPv6.compress(local.address);
				__localPort = local.port;
				__bound = true;
				__applyNodeBuffers();
			}
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __applyNodeBuffers():Void {
		if (__socket == null || !__bound) {
			return;
		}
		var socket:Dynamic = __socket;
		try {
			if (__receiveBufferRequest > 0) {
				socket.setRecvBufferSize(__receiveBufferRequest);
			}
			if (__sendBufferRequest > 0) {
				socket.setSendBufferSize(__sendBufferRequest);
			}
		} catch (e:Dynamic) {
			__dispatchIoError("Could not size the socket's buffers: " + Std.string(e));
		}
	}
	#else
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
	#end

	@:noCompletion private inline function __validatePort(port:Int):Void {
		if (port < 0 || port > 65535) {
			throw new RangeError("Invalid socket port number specified.");
		}
	}

	@:noCompletion private inline function __validateRemotePort(port:Int):Void {
		if (port <= 0 || port > 65535) {
			throw new RangeError("Invalid socket port number specified.");
		}
	}

	@:noCompletion private inline function __isBlockedError(error:Dynamic):Bool {
		return crossbyte._internal.socket.BlockedError.isBlocked(error);
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
		#if nodejs
		// Read from the socket when it was bound rather than asked for now:
		// Node's address() throws on a socket that is not bound yet, where
		// host() on a sys socket answers with the unbound endpoint.
		return __localAddress;
		#else
		var local = __getLocalEndpoint();
		return local != null ? IPv6.compress(local.host.toString()) : "";
		#end
	}

	@:noCompletion private inline function get_localPort():Int {
		#if nodejs
		return __localPort;
		#else
		var local = __getLocalEndpoint();
		return local != null ? local.port : 0;
		#end
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

	@:noCompletion private inline function get_receiveBufferSize():Int {
		return __bufferSize(true);
	}

	@:noCompletion private function set_receiveBufferSize(value:Int):Int {
		__setBufferSize(true, value);
		return value;
	}

	@:noCompletion private inline function get_sendBufferSize():Int {
		return __bufferSize(false);
	}

	@:noCompletion private function set_sendBufferSize(value:Int):Int {
		__setBufferSize(false, value);
		return value;
	}

	@:noCompletion private function __bufferSize(receive:Bool):Int {
		if (__socket == null) {
			return 0;
		}
		#if cpp
		var size:Int = untyped __cpp__("crossbyte_udp_buffer({0}, {1})", @:privateAccess __socket.__s, receive);
		return size < 0 ? 0 : size;
		#elseif ((java || jvm) && !macro)
		try {
			var channel:java.nio.channels.NetworkChannel = cast @:privateAccess __socket.channel;
			var size:java.lang.Integer = cast channel.getOption(cast(receive ? java.net.StandardSocketOptions.SO_RCVBUF : java.net.StandardSocketOptions.SO_SNDBUF));
			return size.intValue();
		} catch (_:Dynamic) {
			return 0;
		}
		#elseif nodejs
		if (!__bound) {
			return receive ? __receiveBufferRequest : __sendBufferRequest;
		}
		var socket:Dynamic = __socket;
		try {
			return receive ? socket.getRecvBufferSize() : socket.getSendBufferSize();
		} catch (_:Dynamic) {
			return 0;
		}
		#else
		return 0;
		#end
	}

	@:noCompletion private function __setBufferSize(receive:Bool, value:Int):Void {
		if (value < 1) {
			throw new RangeError('A socket buffer holds at least one byte, not $value.');
		}
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}
		var which:String = receive ? "receive" : "send";
		#if cpp
		var granted:Bool = untyped __cpp__("crossbyte_udp_set_buffer({0}, {1}, {2})", @:privateAccess __socket.__s, receive, value);
		if (!granted) {
			throw new IOError('The system refused a $which buffer of $value bytes.');
		}
		#elseif ((java || jvm) && !macro)
		try {
			var channel:java.nio.channels.NetworkChannel = cast @:privateAccess __socket.channel;
			channel.setOption(cast(receive ? java.net.StandardSocketOptions.SO_RCVBUF : java.net.StandardSocketOptions.SO_SNDBUF),
				cast java.lang.Integer.valueOf(value));
		} catch (e:Dynamic) {
			throw new IOError('The system refused a $which buffer of $value bytes: ' + Std.string(e));
		}
		#elseif nodejs
		if (receive) {
			__receiveBufferRequest = value;
		} else {
			__sendBufferRequest = value;
		}
		__applyNodeBuffers();
		#end
	}

	@:noCompletion private function set_timeout(value:Int):Int {
		if (value < 0) {
			throw new RangeError("Invalid socket timeout specified.");
		}

		__timeout = value;
		#if !nodejs
		// A read timeout is a property of a blocking read, and Node has none:
		// a datagram is delivered when it arrives or not at all. The value is
		// still kept, so reading `timeout` back gives what was set.
		if (__socket != null) {
			__socket.setTimeout(value / 1000);
		}
		#end
		return value;
	}
}
#end
