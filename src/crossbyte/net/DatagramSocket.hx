package crossbyte.net;

// Not built for the browser. UDP has no web equivalent, WebRTC data channels are the nearest thing and are a different protocol with a different API, not a drop-in. Node has dgram, so it has real UDP.
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
import crossbyte.net._internal.RuntimeHandOff;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events._internal.Arrivals;
import crossbyte.events.EventType;
import crossbyte.events.IOErrorEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import haxe.io.Bytes;
import haxe.io.Eof;
import haxe.io.Error as HxIOError;
#if !js
import crossbyte._internal.net.Resolver;
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
// to that file, and checked by class id before it is trusted, as NativeAlpn
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
class DatagramSocket extends EventDispatcher #if !nodejs implements IPollableSocket #end #if cpp implements crossbyte.core._internal.PassFlush #end {
	/**
		Indicates whether UDP sockets are supported by the current target.

		The interpreter has no UDP socket. Neko has one of CrossByte's own:
		Haxe's `sys.net.UdpSocket` constructor throws "Not available on this
		platform" there, and this once said `true` and then threw on the first
		socket, the one thing a support flag exists to prevent, since a
		caller checks it so it can take the other path, and a flag that lies
		leaves no other path to take. It then said `false` for a while after
		neko's socket worked.
	**/
	public static var isSupported(default, null):Bool = #if (nodejs || (sys && !eval)) true #else false #end;

	/**
		Whether `receiveBufferSize` and `sendBufferSize` reach the operating
		system here: natively, on the jvm and on Node.

		HashLink and Neko have UDP sockets and no way to ask a socket for its
		buffers or to size them, neither has a native for either option,
		so there both read 0, which means not known rather than empty, and
		setting either throws. It used to do nothing, silently, which left a
		caller that sized its buffers for a burst no way to find out it had
		not.
	**/
	public static var bufferSizeSupported(default, null):Bool = #if (cpp || java || jvm || nodejs) true #else false #end;

	/**
		Indicates whether the socket is currently bound to a local address and port.
	**/
	public var bound(get, never):Bool;

	/**
		Indicates whether the socket is connected to a default remote endpoint.
		When connected, `send()` can omit the `address` and `port` arguments.
		True from the moment `connect()` is given a name, while the name is
		looked up.
	**/
	public var connected(get, never):Bool;

	/**
		The byte order used for `ByteArray` payloads dispatched by this socket.

		`ByteArray.defaultEndian` when the socket is made, little-endian
		unless the application changed it, as a ByteArray it makes is, so a
		number written into a new ByteArray reads back as itself from the
		datagram that carried it. Set `Endian.BIG_ENDIAN` for a protocol in
		network byte order. Payloads came big-endian whatever the rest of the
		application did.
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
		the socket is not connected, or while a name given to `connect()` is
		looked up.
	**/
	public var remoteAddress(get, never):String;

	/**
		The default remote UDP port for a connected socket, or `0` when the socket is
		not connected.
	**/
	public var remotePort(get, never):Int;

	/**
		How many bytes of arriving datagrams the operating system holds for
		this socket until they are read. Past it, what arrives is dropped.

		The system's default is small, 64 KB on Windows, a little over 200 KB
		on Linux, and a burst larger than it that arrives while the program
		is busy elsewhere is mostly lost. A socket that many peers send to, or
		a peer that sends a window of datagrams at once, wants more.

		What is granted may not be what was asked. Linux caps it at
		`net.core.rmem_max` unless that is raised, and reports twice what it
		keeps, counting its own bookkeeping; every system rounds. Read it back
		to know. On Node it is applied once the socket is bound, and reads as
		what was asked until then. Where `bufferSizeSupported` is false,
		HashLink and Neko, it reads 0, meaning not known, and cannot be set.

		@throws RangeError If set below 1.
		@throws IOError If set once the socket is closed, or if the system
		        refuses it.
		@throws IllegalOperationError If set where `bufferSizeSupported` is
		        false.
	**/
	public var receiveBufferSize(get, set):Int;

	/**
		How many bytes of datagrams being sent the operating system holds for
		this socket before they leave. As `receiveBufferSize`, for the other
		direction.

		@throws RangeError If set below 1.
		@throws IOError If set once the socket is closed, or if the system
		        refuses it.
		@throws IllegalOperationError If set where `bufferSizeSupported` is
		        false.
	**/
	public var sendBufferSize(get, set):Int;

	@:noCompletion private static inline var DEFAULT_BUFFER_SIZE:Int = 65535;
	// Most datagrams read in one go before the other sockets get their turn.
	// It was 64, and the registry asks once a pass, so a socket could take in
	// no more than 64 datagrams a pass, at 60 passes a second, 3,840 a
	// second, whatever was arriving, with the rest left to overflow the
	// kernel's buffer. Reading one costs a microsecond or two, so this still
	// bounds a flood's hold on the loop to a few milliseconds.
	@:noCompletion private static inline var MAX_DATAGRAMS_PER_TICK:Int = 1024;

	// How long a name's answer is used before it is looked up again, how soon
	// a lookup that failed to refresh one is tried again, and how many
	// datagrams wait on a name's first answer before more are dropped.
	@:noCompletion private static inline var NAME_LIFETIME:Float = 60.0;
	@:noCompletion private static inline var NAME_RETRY:Float = 5.0;
	@:noCompletion private static inline var MAX_HELD_PER_NAME:Int = 64;

	// Failed reads in a row, with nothing succeeding between them, before the
	// socket is called broken rather than merely complained at. Generous on
	// purpose: the cost of guessing high is a socket that stays deaf a little
	// longer than it might, and the cost of guessing low is the bug this
	// replaces, one stray ICMP silencing a working socket.
	@:noCompletion private static inline var MAX_CONSECUTIVE_READ_FAILURES:Int = 64;

	@:noCompletion private var __bound:Bool = false;
	@:noCompletion private var __cbInstance:CrossByte;

	/**
		Handed each datagram before any listener, with no event made for it;
		see `DatagramReceiver`. Set through `__setReceiver`, which polls the
		socket for it as a listener would be.
	**/
	@:noCompletion public var __receiver(default, null):crossbyte.net._internal.DatagramReceiver = null;

	// The payload and the event each datagram is handed out in: one of each
	// per socket, made with the first datagram and filled again for every
	// one after it, so receiving makes no garbage (see Arrivals). Taken
	// afresh while they are out, a listener that pumps the runtime can be
	// handed the next datagram inside its own call, and never under
	// -D crossbyte_fresh_events or -D crossbyte_check_events.
	@:noCompletion private var __arrival:ByteArray = null;
	@:noCompletion private var __arrivalEvent:DatagramSocketDataEvent = null;
	@:noCompletion private var __arrivalOut:Bool = false;
	#if cpp
	// What senders handed this socket during the pass, gathered for one call
	// when the pass ends; see __sendInPass. Kept between passes, emptied.
	@:noCompletion private var __outBytes:Bytes = null;
	@:noCompletion private var __outLength:Int = 0;
	@:noCompletion private var __outSpans:Array<Int> = [];
	@:noCompletion private var __outTargets:Array<Dynamic> = [];
	@:noCompletion private var __outSenders:Array<crossbyte._internal.net.DatagramSender> = [];
	@:noCompletion private var __outQueued:Bool = false;
	#end
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
	@:noCompletion private var __endian:Endian = ByteArray.defaultEndian;
	@:noCompletion private var __readBuffer:Bytes;
	@:noCompletion private var __receiving:Bool = false;
	@:noCompletion private var __registered:Bool = false;
	@:noCompletion private var __remoteAddress:String = "";
	@:noCompletion private var __remotePort:Int = 0;
	#if nodejs
	@:noCompletion private var __socket:NodeDatagram;

	// Sends Node has not finished, and a close waiting for them. Node sends a
	// turn later even to a numeric address, it looks the address up first,
	// so closing straight after a send cancelled it: the FIN a closing
	// session sends last was the datagram that never left.
	@:noCompletion private var __sendsInFlight:Int = 0;
	@:noCompletion private var __closeWhenSent:NodeDatagram = null;
	@:noCompletion private var __onSent:js.lib.Error->Int->Void = null;

	// Chosen from the first address this socket is given, because Node fixes
	// the family when the socket is made where a sys.net.UdpSocket does not.
	@:noCompletion private var __family:String = null;
	@:noCompletion private var __localAddress:String = "";
	@:noCompletion private var __localPort:Int = 0;
	#else
	@:noCompletion private var __socket:UdpSocket;
	@:noCompletion private var __tempAddress:Address;

	// What the last datagram's source host read as, so a run of datagrams
	// from one peer names it once; and this socket's own address as a
	// datagram reports it, asked once rather than for every datagram. Each
	// datagram used to cost a Host, its formatting, and a getsockname() call.
	@:noCompletion private var __sourceHost:Int = 0;
	@:noCompletion private var __sourceText:String = null;

	// And what the last few hundred did, by host: a server's datagrams come
	// from many peers in turn, so the last one's alone missed nearly every
	// time and each named its sender afresh. One slot per host's low bits, a
	// new one taking the slot over; made on first use.
	@:noCompletion private var __sourceHosts:haxe.ds.Vector<Int> = null;
	@:noCompletion private var __sourceTexts:haxe.ds.Vector<String> = null;
	@:noCompletion private var __localText:String = null;
	@:noCompletion private var __localNumber:Int = 0;

	// Where the last datagram went, so a run of them to one peer builds the
	// address once rather than once each. A name's answer is good until
	// `__sendExpires`; an address's never goes stale.
	@:noCompletion private var __sendAddress:String = null;
	@:noCompletion private var __sendPort:Int = 0;
	@:noCompletion private var __sendTarget:Address = null;
	@:noCompletion private var __sendByName:Bool = false;
	@:noCompletion private var __sendExpires:Float = 0;

	// The names this socket has sent to: what each resolved to, and the
	// datagrams waiting on one still being looked up.
	@:noCompletion private var __names:haxe.ds.StringMap<DatagramName> = null;

	// The name connect() was given, while it is looked up, and the datagrams
	// sent to the peer meanwhile; and a count of connect() calls, so that only
	// the latest one's answer is acted on.
	@:noCompletion private var __peerName:String = null;
	@:noCompletion private var __peerHeld:Array<HeldDatagram> = null;
	@:noCompletion private var __connects:Int = 0;
	#end

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
			// a failure here arrives as ioError rather than out of this call,
			// the same shape ServerSocket takes on Node, and for the same
			// reason.
			var socket = __nodeSocket(localAddress);
			socket.bind(localPort, localAddress, function():Void {
				__rememberLocalEndpoint();
			});
			__bound = true;
			#else
			__socket.bind(new Host(localAddress), localPort);
			__bound = true;
			__localText = null;
			#end
		} catch (e:Dynamic) {
			switch (Std.string(e)) {
				case "Unresolved host":
					throw new ArgumentError("One of the parameters is invalid");
				default:
					// Named for what actually failed, and carrying the reason.
					// "Bind failed" used to be answered with "Operation
					// attempted on invalid socket.", which describes a socket
					// that was in fact fine, it was the address or the port
					// that would not take.
					throw new IOError("Could not bind to " + localAddress + ":" + localPort + ": " + Std.string(e));
			}
		}
	}

	/**
		Closes the socket and stops any active receive loop.
		After a socket has been closed, create a new instance to use UDP again.

		It may be called from any thread, as `Socket.close()` may. From one
		that is not the runtime's the socket receives on, the close is handed
		to the runtime, as `CrossByte.post` hands work over, and happens there
		after this returns: `close` is dispatched on the runtime's thread, and
		a datagram may still be delivered until then. Made elsewhere, it took
		the socket out of the runtime's poll set from the wrong thread, while
		the runtime might be polling it, and told the `close` listeners there.
	**/
	public function close():Void {
		if (__socket == null) {
			return;
		}

		var runtime:Null<CrossByte> = __cbInstance;
		if (RuntimeHandOff.offThread(runtime)) {
			var socket = __socket;
			if (runtime.post(function():Void {
				if (__socket == socket) {
					close();
				}
			})) {
				return;
			}
		}

		stopReceiving();
		#if nodejs
		if (__sendsInFlight > 0) {
			// Closed once the last send is done; see __onSent.
			__closeWhenSent = __socket;
		} else {
			try {
				__socket.close();
			} catch (_:Dynamic) {}
		}
		#else
		#if cpp
		// What the pass had gathered goes before the socket does: a server
		// closing tells each client so in its last datagram, and those were
		// waiting for a pass this close would have ended first.
		if (__outTargets.length > 0) {
			__flushPass();
		}
		#end
		try {
			__socket.close();
		} catch (_:Dynamic) {}
		// Datagrams still waiting on a name go with the socket they were
		// waiting to leave by; an answer arriving later finds nothing to do.
		__names = null;
		__peerName = null;
		__peerHeld = null;
		__sendTarget = null;
		__sendAddress = null;
		__localText = null;
		__sourceText = null;
		#end
		__socket = null;
		__bound = false;
		__connected = false;
		__closed = true;
		// A closed socket holds nothing for datagrams that will not come; a
		// payload still out is finished with by the call it is out in.
		__arrival = null;
		__arrivalEvent = null;
		dispatchEvent(new Event(Event.CLOSE));
	}

	/**
		Connects the socket to a default remote UDP endpoint.
		Once connected, `send()` can omit its `address` and `port` parameters and
		received datagrams are limited to the connected peer.

		`host` may be a name everywhere but Node, and it is not looked up on
		the runtime's thread: `connect()` returns at once, and the socket is
		connected to the address the name resolves to when the answer comes.
		Until then `connected` reads true and `remoteAddress` reads empty;
		datagrams sent with no destination wait for the answer, up to 64 of
		them, as datagrams sent to a name do; and the socket receives as it
		did before the call, having no address yet to tell its peer by. A
		name that does not resolve, or an answer the socket cannot be
		connected to, is reported as an `ioError` event after the call
		returns: the datagrams waiting on it are dropped, and the socket is
		left unconnected. On a thread with no CrossByte runtime a name is
		looked up in the call, as it always was.

		@param host The remote address, or a name, to connect to.
		@param port The remote UDP port to connect to.
		@throws ArgumentError If `host` is empty.
		@throws RangeError If `port` is outside the valid UDP port range.
		@throws IOError If the socket is closed, or cannot be connected to
		        `host` there and then: an address it cannot take, a name on
		        Node, or, on a thread with no runtime, a name that does
		        not resolve.
	**/
	public function connect(host:String, port:Int):Void {
		if (host == null || host.length == 0) {
			throw new ArgumentError("One of the parameters is invalid");
		}

		__validateRemotePort(port);

		// Refused here, where the caller hears of it. A name looked up for a
		// closed socket would find nothing to connect when the answer came,
		// and nobody to tell.
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		try {
			#if nodejs
			// Node grew a connect() for datagram sockets in v12, but the
			// extern predates it. Emulated instead: the remote is remembered,
			// send() names it every time, and __receiveNode drops anything
			// from anywhere else, which is the whole of what connecting a
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
			// Whatever an earlier connect() was waiting on, its answer is not
			// this one's, and what was sent to that peer does not go to this.
			// Abandoned, it leaves the socket unconnected, whatever this call
			// comes to.
			__connects++;
			if (__peerName != null) {
				__peerName = null;
				__peerHeld = null;
				__connected = false;
				__remotePort = 0;
			}

			// Without a runtime on this thread there is nothing to hand an
			// answer back to, so a name is looked up here, as it always was.
			if (Resolver.needsLookup(host) && Resolver.runtimeHere() != null) {
				__connectByName(host, port);
				return;
			}

			var remote:Host = new Host(host);
			__socket.connect(remote, port);
			// Connecting can narrow the local address to one interface.
			__localText = null;
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
					// that was in fact fine, it was the address or the port
					// that would not take.
					throw new IOError("Could not connect to " + host + ":" + port + ": " + Std.string(e));
			}
		}
	}

	#if !nodejs
	/**
		`connect()` to a name: looked up off the runtime's thread (see
		`Resolver`), and the socket connected when the answer comes.

		It used to be looked up in the call, on the runtime's thread, so every
		socket and timer there waited on the resolver, a second, for a name
		that does not exist, and one that did not resolve was thrown. The
		socket counts as connected from the call, so `send()` with no
		destination is taken meanwhile and waits for the answer.
	**/
	@:noCompletion private function __connectByName(host:String, port:Int):Void {
		__connected = true;
		__remoteAddress = "";
		__remotePort = port;
		__peerName = host;

		var attempt:Int = __connects;
		var socket:UdpSocket = __socket;
		Resolver.resolve(host, function(resolved:Null<Host>, failure:Null<String>):Void {
			// Closed, or connected somewhere else, meanwhile.
			if (__socket != socket || attempt != __connects) {
				return;
			}
			__onPeerAnswer(host, port, resolved, failure);
		});
	}

	/**
		The answer for a peer `connect()` was given by name: the socket is
		connected to it, and what waited on it is sent. A name that did not
		resolve, or an address the system would not connect to, leaves the
		socket unconnected instead, and what waited is dropped and reported,
		once for all of it.
	**/
	@:noCompletion private function __onPeerAnswer(host:String, port:Int, resolved:Null<Host>, failure:Null<String>):Void {
		var held:Null<Array<HeldDatagram>> = __peerHeld;
		__peerHeld = null;
		__peerName = null;

		var problem:String = null;
		if (resolved == null) {
			problem = "the name did not resolve" + (failure != null ? " (" + failure + ")" : "");
		} else {
			try {
				__socket.connect(resolved, port);
			} catch (e:Dynamic) {
				problem = Std.string(e);
			}
		}

		if (problem != null) {
			__connected = false;
			__remotePort = 0;
			var dropped:Int = held != null ? held.length : 0;
			// Not __dispatchIoError, which stops the socket receiving: nothing
			// is wrong with it, only with the peer it was asked to connect to.
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "Could not connect to " + host + ":" + port + ": " + problem
				+ (dropped == 0 ? "." : ", so " + dropped + (dropped == 1 ? " datagram waiting on it was" : " datagrams waiting on it were") + " dropped.")));
			return;
		}

		// Connecting can narrow the local address to one interface.
		__localText = null;
		__remoteAddress = IPv6.compress(resolved.toString());
		__bound = __getLocalEndpoint() != null;

		if (held == null) {
			return;
		}
		var target:Address = new Address();
		target.setHost(resolved);
		target.port = port;
		for (datagram in held) {
			// A listener told of a failed send may have closed the socket.
			if (__socket == null) {
				return;
			}
			try {
				__socket.sendTo(datagram.bytes, 0, datagram.bytes.length, target);
			} catch (e:Dynamic) {
				__dispatchSendError("Send to " + host + ":" + port + " failed: " + Std.string(e));
			}
		}
	}
	#end

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

		`address` may be a name, and it is not looked up on the runtime's
		thread. Natively it is looked up on a thread of its own the first
		time, and the datagram leaves when the answer comes; up to 64
		datagrams to a name wait for its first answer, and more are dropped,
		as a full send buffer drops them. The answer is used for a minute and
		then refreshed while it goes on being used, so a name in use never
		waits again. On Node, Node looks the name up for each datagram,
		asynchronously. Either way a name that does not resolve is reported
		as an `ioError` event, and the datagrams sent to it are dropped. On a
		thread with no CrossByte runtime a name is looked up in the call, as
		it always was. A datagram sent with no destination while a name given
		to `connect()` is looked up waits for that answer the same way.

		@param bytes The payload bytes to send.
		@param offset The zero-based offset into `bytes` at which sending should begin.
		@param length The number of bytes to send. Use `0` to send all remaining bytes from `offset`.
		@param address The destination address or name for an unconnected socket.
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

			#if !nodejs
			if (__peerName != null) {
				// Connected to a name still being looked up: kept for the
				// answer, which sends it.
				__peerHeld = __keep(__peerHeld, __remotePort, bytes, offset, length);
				return;
			}
			#end

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
			// gets round to it, so anything the caller wrote to this
			// ByteArray in the meantime would go out instead of what it asked
			// to send.
			var payload:ByteArray = new ByteArray();
			payload.writeBytes(bytes, offset, length);
			if (__onSent == null) {
				__onSent = __sent;
			}
			__nodeSocket(address).send(Buffer.hxFromBytes(payload), 0, length, port, address, __onSent);
			__sendsInFlight++;
			__rememberLocalEndpoint();
			#else
			var target:Null<Address> = __targetFor(address, port);
			if (target == null) {
				// A name still being looked up: held until the answer comes.
				__holdForName(address, port, bytes, offset, length);
				return;
			}
			__socket.sendTo(cast bytes, offset, length, target);
			// Asked once, not per datagram: a bound socket stays bound.
			if (!__bound) {
				__bound = __getLocalEndpoint() != null;
			}
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

	#if nodejs
	/**
		Node's word that a send has finished, one way or the other. The last
		one to finish closes a socket that was closed while they were out.

		A send that failed is reported, as one natively is. Node reports it
		here once a send is given a callback, instead of as the socket's
		"error" event, so without this a name that did not resolve, or a
		datagram too large to send, went unreported.
	**/
	@:noCompletion private function __sent(error:js.lib.Error, _:Int):Void {
		__sendsInFlight--;

		if (__sendsInFlight <= 0 && __closeWhenSent != null) {
			var socket:NodeDatagram = __closeWhenSent;
			__closeWhenSent = null;
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}

		if (error != null && !__closed) {
			// Contained: this runs from Node's event loop.
			try {
				__dispatchSendError("A datagram could not be sent: " + Std.string(error.message));
			} catch (thrown:Dynamic) {
				CrossByte.__socketListenerThrew(thrown, this, 'An "ioError" listener threw');
			}
		}
	}
	#else
	/**
		The address to send a datagram for `address`:`port` to, or null while
		`address` is a name still being looked up.

		A name used to be looked up here on every datagram, on the runtime's
		thread: each send to one waited on the resolver, and one that did not
		resolve held every socket and timer on the runtime for as long as the
		resolver took to say so. It is now looked up once, off the thread (see
		`Resolver`), and the answer used for `NAME_LIFETIME` seconds; after
		that the old answer goes on being used while a new one is fetched.

		The last destination is kept as well, so a run of datagrams to one
		peer, the usual shape, builds its address once rather than a
		`Host` and an `Address` per datagram.
	**/
	@:noCompletion private function __targetFor(address:String, port:Int):Null<Address> {
		if (__sendTarget != null && port == __sendPort && address == __sendAddress
			&& (!__sendByName || haxe.Timer.stamp() < __sendExpires)) {
			return __sendTarget;
		}

		var host:Host;
		var expires:Float = 0;
		// Without a runtime on this thread there is nothing to hand an answer
		// back to, so a name is looked up here, as it always was.
		var byName:Bool = Resolver.needsLookup(address) && Resolver.runtimeHere() != null;

		if (byName) {
			if (__names == null) {
				__names = new haxe.ds.StringMap();
			}
			var name:DatagramName = __names.get(address);
			if (name == null) {
				name = new DatagramName();
				__names.set(address, name);
			}

			var now:Float = haxe.Timer.stamp();
			if (name.host == null || now >= name.expires) {
				__lookUp(address, name);
			}
			if (name.host == null) {
				return null;
			}
			host = name.host;
			expires = name.expires;
		} else {
			host = new Host(address);
		}

		var target:Address = new Address();
		target.setHost(host);
		target.port = port;

		__sendAddress = address;
		__sendPort = port;
		__sendTarget = target;
		__sendByName = byName;
		__sendExpires = expires;
		return target;
	}

	/** Looks `address` up for `name`, unless it is already being. **/
	@:noCompletion private function __lookUp(address:String, name:DatagramName):Void {
		if (name.pending) {
			return;
		}
		name.pending = true;

		var socket:UdpSocket = __socket;
		Resolver.resolve(address, function(host:Null<Host>, failure:Null<String>):Void {
			name.pending = false;
			// Closed meanwhile: nothing to send, and nobody to tell.
			if (__socket == socket) {
				__onNameAnswer(address, name, host, failure);
			}
		});
	}

	/**
		A name's answer. What waited on it is sent, or, for a name that did
		not resolve, dropped and reported, once for all of it.
	**/
	@:noCompletion private function __onNameAnswer(address:String, name:DatagramName, host:Null<Host>, failure:Null<String>):Void {
		var now:Float = haxe.Timer.stamp();

		// An address built from the old answer is rebuilt from this one.
		if (__sendAddress == address) {
			__sendTarget = null;
		}

		if (host != null) {
			name.host = host;
			name.expires = now + NAME_LIFETIME;
		} else if (name.host != null) {
			// A refresh that failed. The answer it would have replaced is
			// the best there is, and the name is asked about again soon.
			name.expires = now + NAME_RETRY;
		} else if (__names != null) {
			// Never resolved: forgotten, so the next send asks again rather
			// than being refused on the strength of one failure.
			__names.remove(address);
		}

		var held:Array<HeldDatagram> = name.held;
		name.held = null;
		if (held == null) {
			return;
		}

		if (name.host == null) {
			__dispatchSendError("Could not send to " + address + ": the name did not resolve"
				+ (failure != null ? " (" + failure + ")" : "") + ", so " + held.length
				+ (held.length == 1 ? " datagram waiting on it was" : " datagrams waiting on it were") + " dropped.");
			return;
		}

		var target:Address = new Address();
		target.setHost(name.host);
		for (datagram in held) {
			// A listener told of a failed send may have closed the socket.
			if (__socket == null) {
				return;
			}
			target.port = datagram.port;
			try {
				__socket.sendTo(datagram.bytes, 0, datagram.bytes.length, target);
			} catch (e:Dynamic) {
				__dispatchSendError("Send to " + address + ":" + datagram.port + " failed: " + Std.string(e));
			}
		}

		if (!__bound) {
			__bound = __getLocalEndpoint() != null;
		}
	}

	/** Keeps a copy of a datagram to `address` until the name's answer comes. **/
	@:noCompletion private function __holdForName(address:String, port:Int, bytes:ByteArray, offset:Int, length:Int):Void {
		var name:DatagramName = __names.get(address);
		name.held = __keep(name.held, port, bytes, offset, length);
	}

	/**
		`held`, or a new list if it is null, with a copy of a datagram waiting
		on a name added, unless `MAX_HELD_PER_NAME` wait already, when it is
		dropped, as a full send buffer drops one.
	**/
	@:noCompletion private static function __keep(held:Null<Array<HeldDatagram>>, port:Int, bytes:ByteArray, offset:Int, length:Int):Array<HeldDatagram> {
		if (held == null) {
			held = [];
		}
		if (held.length >= MAX_HELD_PER_NAME) {
			return held;
		}

		var copy:Bytes = Bytes.alloc(length);
		copy.blit(0, bytes, offset, length);
		held.push(new HeldDatagram(port, copy));
		return held;
	}
	#end

	/**
		Stops receiving datagrams and removes the socket from the registry if it is
		currently being polled.

		It may be called from any thread, as `close()` may, and is handed to
		the runtime the same way.
	**/
	public function stopReceiving():Void {
		var runtime:Null<CrossByte> = __cbInstance;
		if (__receiving && RuntimeHandOff.offThread(runtime) && runtime.post(stopReceiving)) {
			return;
		}

		__receiving = false;
		__syncPolling();
	}

	override public function addEventListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		var shouldSync:Bool = type == DatagramSocketDataEvent.DATA && !hasEventListener(DatagramSocketDataEvent.DATA);
		super.addEventListener(type, listener, priority);
		if (type == DatagramSocketDataEvent.DATA) {
			__hasDataListener = true;
		}
		if (shouldSync) {
			__syncPolling();
		}
	}

	override public function removeEventListener<T>(type:EventType<T>, listener:T->Void):Void {
		super.removeEventListener(type, listener);
		if (type == DatagramSocketDataEvent.DATA && !hasEventListener(DatagramSocketDataEvent.DATA)) {
			__hasDataListener = false;
			__syncPolling();
		}
	}

	// Whether anyone listens for DATA, kept rather than asked for each
	// datagram a receiver has already taken.
	@:noCompletion private var __hasDataListener:Bool = false;

	/** Sets, or with null clears, the `DatagramReceiver` each datagram goes to first. **/
	@:noCompletion public function __setReceiver(receiver:crossbyte.net._internal.DatagramReceiver):Void {
		__receiver = receiver;
		__syncPolling();
	}

	/**
		Hands one datagram out: to the receiver first, then to the `DATA`
		listeners, when there are any. This is the outermost call that hands
		`payload` out, on every target, so once it has returned, or a
		listener has thrown, the datagram is done with. `pooled` says
		`payload` is the socket's own (`__arrival`), which is emptied here
		for the next datagram, its event with it; otherwise, under
		`-D crossbyte_check_events`, the payload and its event are killed
		here, and a receiver or listener that kept either reads them dead.
	**/
	@:noCompletion private function __deliver(payload:ByteArray, pooled:Bool, source:String, port:Int, local:String, localPort:Int):Void {
		var receiver = __receiver;
		var event:DatagramSocketDataEvent = null;
		if (pooled) {
			__arrivalOut = true;
		}
		try {
			if (receiver != null) {
				receiver.__receiveDatagram(payload, source, port);
			}
			if (receiver == null || __hasDataListener) {
				if (pooled) {
					event = __arrivalEvent;
					if (event == null) {
						event = __arrivalEvent = new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, source, port, local, localPort, payload);
					} else {
						event.__refill(source, port, local, localPort, payload);
					}
				} else {
					event = new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, source, port, local, localPort, payload);
				}
				dispatchEvent(event);
			}
		} catch (e:Dynamic) {
			__delivered(payload, event, pooled);
			Arrivals.rethrow(e);
		}
		__delivered(payload, event, pooled);
	}

	/** A datagram handed out and done with: the socket's own emptied for the next, or one of its own killed under the check. **/
	@:noCompletion private inline function __delivered(payload:ByteArray, event:DatagramSocketDataEvent, pooled:Bool):Void {
		if (pooled) {
			Arrivals.release(payload);
			__arrivalOut = false;
		} else {
			Arrivals.done(payload);
			Arrivals.doneWith(event);
		}
	}

	/**
		Whether the next datagram is handed out in the socket's own payload
		and event: unless they are out, or either define turns reuse off.
	**/
	@:noCompletion private inline function __pooledArrival():Bool {
		return Arrivals.REUSE && !__arrivalOut;
	}

	/**
		The payload a datagram is handed out in, `length` bytes of `bytes`
		from `offset`: the socket's own, filled again, when `pooled`, and
		one of its own otherwise.
	**/
	@:noCompletion private function __payloadOf(bytes:Bytes, offset:Int, length:Int, pooled:Bool):ByteArray {
		var payload:ByteArray;
		if (pooled) {
			payload = __arrival;
			if (payload == null) {
				payload = __arrival = new ByteArray();
			}
			Arrivals.refill(payload, bytes, offset, length);
		} else {
			var own:Bytes = Bytes.alloc(length);
			own.blit(0, bytes, offset, length);
			payload = ByteArray.fromBytes(own);
		}
		payload.endian = __endian;
		return payload;
	}

	#if !nodejs
	public function registryOnReadable():Void {
		if (!__receiving || __socket == null) {
			return;
		}

		var processed:Int = 0;
		while (__receiving && processed < MAX_DATAGRAMS_PER_TICK) {
			var bytesReady:Int = 0;
			// -1 when nothing is waiting, which ends every pass that read:
			// readFrom threw Blocked for it, an exception made and caught each
			// time the socket was drained.
			try {
				bytesReady = @:privateAccess __socket.__tryReadFrom(__readBuffer, 0, __readBuffer.length, __tempAddress);
			} catch (_:Eof) {
				break;
			} catch (e:Dynamic) {
				if (__isBlockedError(e)) {
					return;
				}
				__onReadFailed(Std.string(e));
				return;
			}

			// Nothing waiting (-1), or the empty read readFrom ended the pass
			// with as Eof (0).
			if (bytesReady <= 0) {
				return;
			}

			__consecutiveReadFailures = 0;

			// Copied out of the read buffer, which the next read fills: into
			// the socket's own payload, used again for every datagram, or one
			// of the datagram's own while that one is out. Each datagram had a
			// Bytes, a ByteArray and an event of its own.
			var pooled:Bool = __pooledArrival();
			var payload:ByteArray = __payloadOf(__readBuffer, 0, bytesReady, pooled);

			if (__localText == null) {
				var local = __getLocalEndpoint();
				if (local != null) {
					__localText = IPv6.compress(local.host.toString());
					__localNumber = local.port;
				}
			}

			// An IPv4 source is its number, named once; an IPv6 one is named
			// afresh.
			var source:String = __sourceText;
			if (@:privateAccess __tempAddress.ipv6 != null) {
				source = IPv6.compress(__tempAddress.getHost().toString());
			} else if (source == null || __tempAddress.host != __sourceHost) {
				source = __sourceOf(__tempAddress.host);
				__sourceText = source;
				__sourceHost = __tempAddress.host;
			}

			processed++;
			__deliver(payload, pooled, source, __tempAddress.port, __localText != null ? __localText : "", __localText != null ? __localNumber : 0);
		}

		// Stopped at the cap, not at an empty socket: the loop is told, so
		// the rest are read before it waits rather than a frame later. A
		// server polled once a frame otherwise took at most 1,024 datagrams
		// a frame, 12,288 a second at twelve ticks, however many came.
		if (processed >= MAX_DATAGRAMS_PER_TICK && __cbInstance != null) {
			@:privateAccess __cbInstance.__noteMoreToRead();
		}
	}

	/** An IPv4 source host's text, from the cache by host or made and kept there. **/
	@:noCompletion private function __sourceOf(host:Int):String {
		if (__sourceHosts == null) {
			__sourceHosts = new haxe.ds.Vector<Int>(SOURCE_SLOTS);
			__sourceTexts = new haxe.ds.Vector<String>(SOURCE_SLOTS);
		}
		var slot:Int = (host ^ (host >>> 8) ^ (host >>> 16) ^ (host >>> 24)) & (SOURCE_SLOTS - 1);
		var text:String = __sourceTexts[slot];
		if (text == null || __sourceHosts[slot] != host) {
			text = IPv6.compress(__tempAddress.getHost().toString());
			__sourceTexts[slot] = text;
			__sourceHosts[slot] = host;
		}
		return text;
	}

	@:noCompletion private static inline var SOURCE_SLOTS:Int = 256;

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
		`stopReceiving()`: so one failed read deafened the socket for good. On
		a connectionless socket that is the wrong reading of what a read error
		is. Send a datagram to a port nothing listens on and the peer's stack
		answers ICMP port unreachable; Windows reports that back to the sender
		as an error on a *later* read, which is then consumed by it. The
		datagram it complains about is already gone, and the socket is fine.

		Measured before changing anything: one datagram to a closed local port
		and a socket that had just completed a STUN exchange stopped receiving
		entirely, reporting `Custom(Socket operation failed)`. For a
		peer-to-peer mesh that is not an edge case, dialling peers that have
		since left is ordinary, and one departed peer should not silence
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
		only way anything reaches this endpoint, so stopping reception because
		one destination was unroutable throws away every other peer over an
		error about one of them.

		That is not hypothetical. ICE finds a path by trying every candidate a
		peer offered, and most of them fail: a candidate on a network this host
		cannot reach, or an IPv6 address on a socket bound to IPv4, refuses at
		the `sendto` and is meant to. Routing that into `__dispatchIoError`,
		which is what this did, meant the first such attempt stopped the
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

	#if !nodejs
	/**
		The address `send` would send to for `address` and `port`, or null
		while a name is still being looked up, for a sender that keeps it,
		as a reliable session keeps its peer's, rather than have one built
		for each datagram: this socket keeps only the last.
	**/
	@:noCompletion public function __resolveTarget(address:String, port:Int):Null<Address> {
		return __targetFor(address, port);
	}

	/**
		Sends `length` bytes of `bytes` from `offset` to `target` when the
		runtime's pass ends, together with everything else sent this way from
		this socket in the pass: on Linux in as few system calls as the
		kernel allows, a run to one peer cut up by the kernel from a single
		send, the rest 64 to a call, and elsewhere one send each, as now.
		`sender` is told if this one could not go.

		Sending a datagram at a time cost its system call each, which was
		most of what a server sending reliable UDP spent: 5.9 us a 1,200-byte
		datagram on Windows, against 6.2 for the bare call. Over Linux
		loopback a run cut by the kernel cost a seventh of the CPU of the same
		datagrams sent one by one.

		Goes now where there is no pass to wait for: no runtime, a runtime
		that has stopped, or a target without the batch call.
	**/
	@:noCompletion public function __sendInPass(bytes:Bytes, offset:Int, length:Int, target:Address,
			sender:Null<crossbyte._internal.net.DatagramSender>):Void {
		#if cpp
		// This socket's runtime, or for one that only sends, set at
		// receive(), the thread's.
		var runtime:CrossByte = __cbInstance;
		if (runtime == null) {
			try {
				runtime = CrossByte.current();
			} catch (_:Dynamic) {}
		}
		if (runtime != null && !runtime.__didExit && __socket != null) {
			var end:Int = __outLength + length;
			if (__outBytes == null || __outBytes.length < end) {
				var grown:Bytes = Bytes.alloc(end > 32768 ? end * 2 : 65536);
				if (__outLength > 0) {
					grown.blit(0, __outBytes, 0, __outLength);
				}
				__outBytes = grown;
			}
			__outBytes.blit(__outLength, bytes, offset, length);
			__outSpans.push(__outLength);
			__outSpans.push(length);
			__outTargets.push(target);
			__outSenders.push(sender);
			__outLength = end;
			if (!__outQueued) {
				__outQueued = true;
				runtime.__queuePassFlush(this);
			}
			return;
		}
		#end
		__sendNow(bytes, offset, length, target, sender);
	}

	@:noCompletion private function __sendNow(bytes:Bytes, offset:Int, length:Int, target:Address,
			sender:Null<crossbyte._internal.net.DatagramSender>):Void {
		try {
			if (__socket == null) {
				throw new IOError("Operation attempted on invalid socket.");
			}
			// A full send buffer (-1) drops the datagram, as a full queue
			// anywhere on the path would; it is not the sender's failure.
			@:privateAccess __socket.__trySendTo(bytes, offset, length, target);
		} catch (e:Dynamic) {
			if (crossbyte._internal.socket.BlockedError.isBlocked(e)) {
				return;
			}
			if (sender != null) {
				sender.__datagramFailed(Std.string(e));
			} else {
				__dispatchSendError(Std.string(e));
			}
		}
	}

	#end

	#if cpp
	/**
		Sends what the pass gathered; see __sendInPass. A datagram the batch
		stopped at is sent alone, which says why: a full send buffer drops it
		and what follows, as a full queue drops a datagram anywhere, and
		anything else is its sender's to hear. Senders are told after the
		batch is emptied, so one that sends again from there starts afresh.
	**/
	@:noCompletion public function __flushPass():Void {
		__outQueued = false;
		var count:Int = __outTargets.length;
		if (count == 0) {
			return;
		}

		var failed:Array<Int> = null;
		var failures:Array<String> = null;
		var first:Int = 0;
		while (first < count && __socket != null) {
			first += crossbyte._internal.net.NativeSocketAddress.sendBatch(__socket, __outBytes.getData(), __outSpans, __outTargets, first, count);
			if (first >= count) {
				break;
			}

			var stopped:Int = first++;
			try {
				var target:Address = __outTargets[stopped];
				// A full send buffer: it and what follows are dropped.
				if (@:privateAccess __socket.__trySendTo(__outBytes, __outSpans[2 * stopped], __outSpans[2 * stopped + 1], target) < 0) {
					break;
				}
			} catch (e:Dynamic) {
				if (crossbyte._internal.socket.BlockedError.isBlocked(e)) {
					break;
				}
				if (failed == null) {
					failed = [];
					failures = [];
				}
				failed.push(stopped);
				failures.push(Std.string(e));
			}
		}

		var senders:Array<crossbyte._internal.net.DatagramSender> = failed == null ? null : [for (i in failed) __outSenders[i]];
		__outLength = 0;
		__outSpans.resize(0);
		__outTargets.resize(0);
		__outSenders.resize(0);

		if (failed != null) {
			for (i in 0...failed.length) {
				var sender = senders[i];
				if (sender != null) {
					sender.__datagramFailed(failures[i]);
				} else {
					__dispatchSendError(failures[i]);
				}
			}
		}
	}
	#end

	@:noCompletion private function __syncPolling():Void {
		#if nodejs
		// Nothing to synchronise. There is no descriptor to hand the registry,
		// Node calls __receiveNode when a datagram arrives, so whether
		// anything is delivered turns on __receiving alone, which the caller
		// has already set.
		return;
		#else
		var shouldPoll:Bool = __receiving && (__receiver != null || hasEventListener(DatagramSocketDataEvent.DATA));
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

		// Contained: these run from Node's event loop, and a listener that
		// threw there ended the process. A datagram socket is not closed for
		// it, one socket carries every peer of a server, and one handler
		// failing on one datagram is no reason to stop hearing the rest, so
		// the failure is logged and the next datagram delivered as usual.
		__socket.on("message", function(message:Buffer, remote:js.node.dgram.Socket.MessageRemoteInfo):Void {
			try {
				__receiveNode(message, remote);
			} catch (e:Dynamic) {
				CrossByte.__socketListenerThrew(e, this, 'A datagram listener threw handling a datagram from ${remote.address}:${remote.port}');
			}
		});

		__socket.on("error", function(e:Dynamic):Void {
			try {
				__dispatchIoError(Std.string(e));
			} catch (thrown:Dynamic) {
				CrossByte.__socketListenerThrew(thrown, this, 'An "ioError" listener threw');
			}
		});
	}

	/**
	 * Returns the socket, swapping its address family first if the address
	 * about to be used needs the other one.
	 *
	 * Node fixes the family when the socket is created; a `sys.net.UdpSocket`
	 * does not, and takes whatever address it is later handed. So a socket
	 * that has not been bound or connected yet is simply replaced, which is
	 * free, nothing has been done with it. One that has is left alone, and
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
	 * peer, Node's own `connect()` would enforce the second, but the extern
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

		// Node hands each datagram over in a Buffer of its own, which nothing
		// here can spare it: its bytes are copied into the socket's payload,
		// used again for every datagram, where they were sliced into a buffer
		// of their own and wrapped in a ByteArray, with an event, each time.
		var pooled:Bool = __pooledArrival();
		var payload:ByteArray;
		if (pooled) {
			payload = __arrival;
			if (payload == null) {
				payload = __arrival = new ByteArray();
			}
			Arrivals.refillView(payload, message);
		} else {
			payload = ByteArray.fromBytes(Bytes.ofData(message.buffer.slice(message.byteOffset, message.byteOffset + message.byteLength)));
		}
		payload.endian = __endian;

		__deliver(payload, pooled, source, remote.port, __localAddress, __localPort);
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
		return __knownLocal() ? __localText : "";
		#end
	}

	@:noCompletion private inline function get_localPort():Int {
		#if nodejs
		return __localPort;
		#else
		return __knownLocal() ? __localNumber : 0;
		#end
	}

	#if !nodejs
	/**
		Whether this socket's own address is known, asking the system only when
		it is not: the answer is kept until a bind, connect or close, which are
		all that can change it, and kept only once it has a port, since a
		socket that was never bound is given one by its first send. Each read of
		`localAddress` or `localPort` was a getsockname() call, and a reliable
		session reads both for every message it hands over.
	**/
	@:noCompletion private function __knownLocal():Bool {
		if (__localText == null || __localNumber == 0) {
			var local = __getLocalEndpoint();
			if (local == null) {
				return false;
			}
			__localText = IPv6.compress(local.host.toString());
			__localNumber = local.port;
		}
		return true;
	}
	#end

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
		#else
		throw new IllegalOperationError('This target cannot size a socket\'s $which buffer: check DatagramSocket.bufferSizeSupported.');
		#end
	}
}

#if !nodejs
/** A name a socket has sent to: its answer, and what waits on the first. **/
private class DatagramName {
	public var host:Null<Host> = null;
	public var expires:Float = 0;
	public var pending:Bool = false;
	public var held:Null<Array<HeldDatagram>> = null;

	public function new() {}
}

/** A datagram waiting on its destination's name, copied when it was sent. **/
private class HeldDatagram {
	public final port:Int;
	public final bytes:Bytes;

	public function new(port:Int, bytes:Bytes) {
		this.port = port;
		this.bytes = bytes;
	}
}
#end
#end
