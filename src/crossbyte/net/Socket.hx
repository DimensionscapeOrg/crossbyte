package crossbyte.net;

import haxe.ds.StringMap;
import haxe.ds.IntMap;
import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
#if nodejs
import js.node.net.Socket as NodeSocket;
import js.node.net.Socket.SocketEvent;
import js.lib.Uint8Array;
#end
#if (js && !nodejs)
import js.Browser;
import js.lib.ArrayBuffer;
import js.html.WebSocket;
#elseif nodejs
#end
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
#if cpp
import sys.thread.Tls;
#end
import haxe.io.Eof;
import haxe.io.Error;
import haxe.Serializer;
import haxe.Timer;
import haxe.Unserializer;
import crossbyte._internal.socket.IPollableSocket;
#if cpp
import crossbyte._internal.socket.AlpnSocket;
#end
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.IOError;
import crossbyte.errors.SecurityError;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.io.IDataInput;
import crossbyte.io.IDataOutput;
#if sys
#if !js
import sys.net.Host;
import sys.net.Socket as SysSocket;
#end
#end

/**
	High-level TCP socket with binary read/write helpers, event dispatch, and
	CrossByte runtime integration.
**/
#if !debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
class Socket extends EventDispatcher implements IDataInput implements IDataOutput implements IPollableSocket {
	/**
		The number of bytes of data available for reading in the input buffer.
		Your code must access `bytesAvailable` to ensure that sufficient data
		is available before trying to read it with one of the `read` methods.
	**/
	public var bytesAvailable(get, never):Int;

	/**
		Indicates the number of bytes remaining in the write buffer.
		Use this property in combination with with the OutputProgressEvent. An
		OutputProgressEvent is thrown whenever data is written from the write buffer to
		the network. In the event handler, you can check bytesPending to see how much data
		is still left in the buffer waiting to be written. When bytesPending returns 0, it
		means that all the data has been transferred from the write buffer to the network,
		and it is safe to do things like remove event handlers, null out socket
		references, start the next upload in a queue, etc.
	**/
	public var bytesPending(get, never):Int;

	/**
		Indicates whether this Socket object is currently connected. A call to
		this property returns a value of `true` if the socket is currently
		connected, or `false` otherwise.
	**/
	public var connected(get, never):Bool;

	/**
		Indicates the byte order for the data. Possible values are constants
		from the openfl.utils.Endian class, `Endian.BIG_ENDIAN` or
		`Endian.LITTLE_ENDIAN`.
		@default Endian.BIG_ENDIAN
	**/
	public var endian(get, set):Endian;

	/**
	 * The IP address this socket is bound to on the local machine.
	**/
	public var localAddress(get, never):String;

	/**
		The port this socket is bound to on the local machine.
	 */
	public var localPort(get, never):Int;

	/**
		Controls the version of AMF used when writing or reading an object.
	**/
	public var objectEncoding:ObjectEncoding;

	/**
		The IP address of the remote machine to which this socket is connected.

		You can use this property to determine the IP address of a client socket 
		dispatched in a ServerSocketConnectEvent by a ServerSocket object.
	 */
	public var remoteAddress(get, never):String;

	/**
		The port on the remote machine to which this socket is connected.

		You can use this property to determine the port number of a client socket 
		dispatched in a ServerSocketConnectEvent by a ServerSocket object.
	 */
	public var remotePort(get, never):Int;

	/**
		The application protocol this connection negotiated over TLS, such as
		`"h2"` or `"http/1.1"`, or `null` when none was negotiated.

		Read this on the socket carried by a `ServerSocketConnectEvent` to see
		what a client agreed to during the handshake. It is `null` on a plain
		TCP connection, before the handshake completes, when the server never
		called `ServerSocket.setALPN()`, and on targets where
		`ServerSocket.alpnSupported` is `false`.
	**/
	public var alpnProtocol(get, never):Null<String>;

	public var registryClosed(get, never):Bool;

	@SuppressWarnings("checkstyle:FieldDocComment")
	@:noCompletion @:dox(hide) public var secure:Bool;

	/**
		Indicates the number of milliseconds to wait for a connection.
		If the connection doesn't succeed within the specified time, the
		connection fails. The default value is 20,000 (twenty seconds).
	**/
	public var timeout:Int;

	/**
		Maximum bytes allowed to accumulate in the outgoing buffer, or `0`
		for no limit.

		Writes are buffered until the operating system accepts them, so a
		peer that stops reading — a stalled phone, a half-open connection,
		a deliberately slow client — makes that buffer grow without bound.
		On a server fanning out to many connections, one such peer can
		exhaust process memory.

		Setting a limit bounds that exposure. When the buffer exceeds it
		after a flush, `outputOverflowPolicy` decides what happens.

		Defaults to `0`, preserving the historical behavior. Servers should
		set a limit sized to the largest message they legitimately send,
		with headroom — a few megabytes suits most protocols.

		A property rather than a plain field so subclasses that do not use
		this buffer can redirect it to the one they do use, instead of
		silently accepting a limit that never applies.
	**/
	public var maxOutputBufferSize(get, set):Int;

	@:noCompletion private var __maxOutputBufferSize:Int = 0;

	@:noCompletion private function get_maxOutputBufferSize():Int {
		return __maxOutputBufferSize;
	}

	@:noCompletion private function set_maxOutputBufferSize(value:Int):Int {
		return __maxOutputBufferSize = value;
	}

	/**
		What to do when the outgoing buffer exceeds `maxOutputBufferSize`.

		Defaults to `CLOSE`, which is what a server wants for a slow
		consumer: the connection is dropped and its memory reclaimed
		without every call site having to handle an error.
	**/
	public var outputOverflowPolicy:OutputOverflowPolicy = CLOSE;

	/**
		What happens when the peer stops sending — see `PeerShutdownPolicy`.

		Defaults to `CLOSE`, which is what this has always done. Set
		`HALF_OPEN` for a protocol where a half-close marks the end of a
		request rather than the end of the conversation, and read the hazard
		on that value first: a departed peer is indistinguishable from a
		half-closed one, so `HALF_OPEN` needs a bound of your own.
	**/
	public var peerShutdownPolicy:PeerShutdownPolicy = CLOSE;

	/**
		Whether the peer has stopped sending.

		Set when a read ends in `Eof`, under either policy, so that a consumer
		on `CLOSE` can still tell a graceful end from an error one. Once set,
		nothing further will arrive and the socket stops attempting reads.

		It does **not** mean the peer is still listening. A peer that shut only
		its write side and a peer that vanished both land here; see
		`PeerShutdownPolicy.HALF_OPEN`.
	**/
	public var peerShutdown(get, never):Bool;

	/**
		Bytes currently waiting to be written to the operating system.

		A value that keeps climbing across flushes means the peer is not
		draining as fast as this side is producing. Useful as a metrics
		gauge and as a signal to stop enqueueing more work.
	**/
	public var outputBufferLength(get, never):Int;

	@:noCompletion private function get_outputBufferLength():Int {
		return __output == null ? 0 : __output.length;
	}

	/**
		Invoked after a queued flush attempt, for a writer that produces its
		body incrementally instead of all at once.

		A writer that hands the socket a whole response has nothing to wait
		for, but one that streams needs to know when to offer the next
		piece, and polling for that on a timer couples the transfer's pace
		to the clock rather than to the peer. Every write queues the socket
		on the registry's writable queue, which the runtime drains each
		pass, so this fires whether the flush completed or blocked — and
		only for sockets with something in flight.

		Set it to `null` when the transfer ends. The callback runs inside
		the registry's drain, so it must not close this socket's registry
		registration out from under the loop; closing the socket is fine.
	**/
	@:noCompletion public var __onWritableDrain:Void->Void;

	/**
	 * Bytes handed to one `readBytes` call. Larger than the 4 KB this used to
	 * use, which cost a syscall every 4 KB: a megabyte arrived in 256 reads
	 * where it now takes 16.
	 */
	@:noCompletion private static inline var READ_CHUNK:Int = 64 * 1024;

	/**
	 * Consumed bytes tolerated at the front of `__input` before the unread
	 * tail is moved down. Compacting on every arrival — which is what
	 * rebuilding the buffer per read amounted to — costs a copy of the whole
	 * unread backlog each time, so a consumer that reads slower than the peer
	 * writes paid for its backlog again on every event. Measured at 50x the
	 * arriving bytes after 200 events, and rising, because the cost is
	 * quadratic in the number of arrivals.
	 */
	@:noCompletion private static inline var INPUT_COMPACT_THRESHOLD:Int = 64 * 1024;

	/**
	 * One read buffer per thread rather than one per socket.
	 *
	 * It holds bytes only between a `readBytes` and the append that follows
	 * it, and nothing is dispatched in between, so no listener can re-enter
	 * and find it changed underneath. Sharing it is what makes a large buffer
	 * affordable: per socket, 64 KB across the default 256 connections would
	 * be 16 MB of idle buffer, where one shared buffer is 64 KB no matter how
	 * many connections a thread carries — less than the 1 MB those 256
	 * sockets used to hold between them at 4 KB each.
	 */
	#if cpp
	@:noCompletion private static final __readScratch:Tls<Bytes> = new Tls();
	#else
	@:noCompletion private static var __readScratch:Bytes;
	#end

	/**
	 * Drops bytes already read out of `__input`, so appending does not grow
	 * the buffer past what is still unread.
	 *
	 * A fully drained buffer — the common case, since most protocols consume
	 * what they are given — resets in constant time. Otherwise the tail is
	 * moved only once the consumed prefix is worth the move, which is what
	 * turns compaction from a per-arrival cost into an amortised one.
	 */
	@:noCompletion private function __compactInput():Void {
		var consumed:Int = __input.position;

		if (consumed == 0) {
			return;
		}

		if (consumed >= __input.length) {
			__input.clear();
			__input.endian = __endian;
			return;
		}

		if (consumed < INPUT_COMPACT_THRESHOLD) {
			return;
		}

		// Allocate and swap rather than move within the buffer: a ByteArray
		// blit whose source and destination overlap has no defined behaviour
		// across targets.
		var remaining:Int = __input.length - consumed;
		var carried:ByteArray = new ByteArray();
		carried.writeBytes(__input, consumed, remaining);
		carried.position = 0;
		carried.endian = __endian;
		__input = carried;
	}

	@:noCompletion private static function __scratch():Bytes {
		var buffer:Bytes = #if cpp __readScratch.value #else __readScratch #end;

		if (buffer == null) {
			buffer = Bytes.alloc(READ_CHUNK);
			#if cpp
			__readScratch.value = buffer;
			#else
			__readScratch = buffer;
			#end
		}

		return buffer;
	}
	@:noCompletion private var __connected:Bool;
	@:noCompletion private var __closed:Bool;
	@:noCompletion private var __endian:Endian;
	@:noCompletion private var __host:String;
	@:noCompletion private var __input:ByteArray;
	@:noCompletion private var __output:ByteArray;
	@:noCompletion private var __port:Int;
	@:noCompletion private var __socket:#if sys SysSocket #else Dynamic #end;
	@:noCompletion private var __timestamp:Float;
	@:noCompletion private var __peerShutdown:Bool = false;
	@:noCompletion private var __cbInstance:CrossByte;
	@:noCompletion private var __isConnecting:Bool;
	@:noCompletion private var __isDirty = false;
	@:noCompletion private var flushFull:Bool = false;
	// Hot socket events are reused to reduce steady-state allocation churn.
	// These events are ephemeral during dispatch and must not be retained.
	@:noCompletion private var __pooledConnectEvent:Event;
	@:noCompletion private var __pooledConnectEventInUse:Bool = false;
	@:noCompletion private var __pooledCloseEvent:Event;
	@:noCompletion private var __pooledCloseEventInUse:Bool = false;
	@:noCompletion private var __pooledSocketDataEvent:ProgressEvent;
	@:noCompletion private var __pooledSocketDataEventInUse:Bool = false;
	@:noCompletion private var __pooledIOErrorEvent:IOErrorEvent;
	@:noCompletion private var __pooledIOErrorEventInUse:Bool = false;

	/**
		Creates a new Socket object. If no parameters are specified, an
		initially disconnected socket is created. If parameters are specified,
		a connection is attempted to the specified host and port.

		**Note:** It is strongly advised to use the constructor form **without
		parameters**, then add any event listeners, then call the `connect`
		method with `host` and `port` parameters. This sequence guarantees
		that all event listeners will work properly.

		@param host A fully qualified DNS domain name or an IP address. IPv4
		            addresses are in dot-decimal notation, such as _192.0.2.0_;
		            IPv6 addresses in hexadecimal-colon notation, such as
		            _2001:db8:ccc3:ffff:0:444d:555e:666f_.
		@param port The TCP port number on the target host. A connection is
		            attempted only when this is between 1 and 65535; leave it
		            at 0 for the disconnected socket recommended above.
		@throws SecurityError The port is outside 0-65535.
		@event connect       Dispatched when a network connection has been
		                     established.
		@event ioError       Dispatched when an input/output error occurs that
		                     causes the connection to fail, including a host
		                     that cannot be resolved.
	**/
	public function new(host:String = null, port:Int = 0) {
		super();

		endian = Endian.LITTLE_ENDIAN;
		timeout = 20000;
		__connected = false;
		__closed = false;
		__isConnecting = false;

		// 65535 inclusive, which is what connect() accepts. This read
		// `port < 65535`, so the highest valid TCP port was the one port
		// number for which the constructor quietly declined to connect.
		if (port > 0 && port <= 65535) {
			connect(host, port);
		}
	}

	/**
		Closes the socket. You cannot read or write any data after the
		`close()` method has been called.
		The `close` event is dispatched only when the server closes the
		connection; it is not dispatched when you call the `close()` method.
		You can reuse the Socket object by calling the `connect()` method on
		it again.
		@throws IOError The socket could not be closed, or the socket was not
						open.
	**/
	public function close():Void {
		if (__socket != null) {
			// Mirror the remote-close path (see the read loop): an app-initiated
			// close must also notify listeners via Event.CLOSE, otherwise code
			// that releases per-connection resources on CLOSE (e.g. HTTPServer's
			// connection counter) leaks every time it closes a socket itself.
			var wasConnected:Bool = __connected;
			__cleanSocket();
			if (wasConnected) {
				__dispatchPooledSimpleEvent(Event.CLOSE);
			}
		} else {
			throw new IOError("Operation attempted on invalid socket.");
		}
	}

	/**
		Connects the socket to the specified host and port.

		The outcome is reported by an event, not by this call returning. If the
		socket is already connected, the existing connection is closed first.

		A host that cannot be resolved is reported as an `ioError` event rather
		than thrown, so a listener is the only way to see it.

		@param host The name or IP address of the host to connect to.
		@param port The port number to connect to.
		@throws SecurityError The port is outside 0-65535.
		@event connect       Dispatched when a network connection has been
		                     established.
		@event ioError       Dispatched when an input/output error occurs that
		                     causes the connection to fail, including a host
		                     that cannot be resolved.
	**/
	public function connect(host:String, port:Int):Void {
		if (__socket != null) {
			close();
		}

		if (port < 0 || port > 65535) {
			throw new SecurityError("Invalid socket port number specified.");
		}

		#if js
		// Node resolves the hostname itself when connecting, and a browser has
		// no resolver to offer, so neither needs a Host looked up first.
		__timestamp = Timer.stamp();
		#else
		var h:Host = null;

		try {
			h = new Host(host);
		} catch (e:Dynamic) {
			if (hasEventListener(IOErrorEvent.IO_ERROR)) {
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "Invalid host"));
			}
			return;
		}

		__timestamp = Sys.time();
		#end

		__host = host;
		__port = port;
		__connected = false;
		__closed = false;
		__isDirty = false;
		flushFull = false;

		__output = new ByteArray();
		__output.endian = __endian;

		__input = new ByteArray();
		__input.endian = __endian;

		#if (js && !nodejs)
		if (Browser.location.protocol == "https:") {
			secure = true;
		}

		var schema = secure ? "wss" : "ws";
		var urlReg = ~/^(.*:\/\/)?([A-Za-z0-9\-\.]+)\/?(.*)/g;
		urlReg.match(host);
		var __webHost = urlReg.matched(2);
		var __webPath = urlReg.matched(3);

		__socket = new WebSocket(schema + "://" + __webHost + ":" + port + "/" + __webPath);
		__socket.binaryType = "arraybuffer";
		__socket.onopen = socket_onOpen;
		__socket.onmessage = socket_onMessage;
		__socket.onclose = socket_onClose;
		__socket.onerror = socket_onError;

		CrossByte.current().addEventListener(TickEvent.TICK, this_onTick);
		#elseif nodejs
		// Node gives an asynchronous socket, which is the same shape the browser
		// WebSocket path above already has: events feed __input and the tick
		// only drains what has arrived. There is no descriptor to poll and
		// nothing to register with the runtime.
		var node = new NodeSocket();
		__socket = node;
		node.on(SocketEvent.Connect, function() {
			socket_onOpen(null);
		});
		__bindNodeSocket(node);
		node.connect({port: port, host: host});

		CrossByte.current().addEventListener(TickEvent.TICK, this_onTick);
		#else
		__socket = new SysSocket();
		@:privateAccess
		__cbInstance = CrossByte.current();
		if (__cbInstance == null) {
			__cleanupFailedConnect();
			throw "Socket can only be initiated in a CrossByte threaded instance";
		}

		try {
			__socket.setBlocking(false);
			__socket.connect(h, port);
		} catch (e:Error) {
			if (!__isBlockedError(e)) {
				__cleanupFailedConnect();
				if (hasEventListener(IOErrorEvent.IO_ERROR)) {
					dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "Connection failed"));
				}
				return;
			}
			// A would-block is the normal case on a target with real non-blocking
			// sockets: the connect is in flight, and the tick below waits for it to
			// become writable. Nothing to record -- both completions defer there.
		} catch (e:Dynamic) {
			__cleanupFailedConnect();
			if (hasEventListener(IOErrorEvent.IO_ERROR)) {
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "Connection failed"));
			}
			return;
		}

		__socket.setFastSend(true);
		__socket.custom = this;

		#if eval
		// eval's sockets are blocking -- setBlocking is a no-op there (see the
		// read loop) -- so a connect that returns has genuinely completed and the
		// socket is writable now. There is no tick-driven writability signal to
		// defer to, and forcing the connect through one hangs: the first read the
		// completion tick makes would block on a socket with nothing to say yet.
		// Announce the connect here, which is what every target did before the
		// deferral below and what eval still needs.
		__connected = true;
		@:privateAccess
		__cbInstance.registerSocket(__socket);
		__dispatchPooledSimpleEvent(Event.CONNECT);
		#else
		// Both completions -- pending, and the immediate one a loopback connect
		// can return on Windows -- wait for the tick to confirm the socket is
		// writable before CONNECT is dispatched. The tick gates that dispatch on
		// a select() for writability (see this_onTick); a non-blocking connect
		// that returns success has not necessarily finished the handshake, so a
		// write from a CONNECT listener fired synchronously here could reach a
		// socket the OS was not yet ready to send on and fail with an end-of-file
		// the connect raced. Deferring makes the two completions behave
		// identically and the notification tick-driven like every other socket
		// event, instead of re-entering user code from inside connect() on a
		// socket that has never been pumped.
		__startConnecting();
		#end
		#end
	}

	/**
		Flushes any accumulated data in the socket's output buffer.
		On some operating systems, flush() is called automatically between
		execution frames, but on other operating systems, such as Windows, the
		data is never sent unless you call `flush()` explicitly. To ensure
		your application behaves reliably across all operating systems, it is
		a good practice to call the `flush()` method after writing each
		message (or related group of data) to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	public function flush():Void {
		if (flushFull) {
			// Already blocked with a retry pending; the limit still applies
			// because callers may keep enqueueing while it drains.
			__enforceOutputLimit();
			return;
		}

		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (__output.length > 0) {
			try {
				#if (js && !nodejs)
				var buffer:ArrayBuffer = (__output : haxe.io.Bytes).getData();
				if (buffer.byteLength > __output.length)
					buffer = buffer.slice(0, __output.length);
				__socket.send(buffer);
		#elseif nodejs
				// A view over the pending bytes rather than a copy of them; Node
				// accepts a Uint8Array directly and takes its own reference.
				var pending:Int = __output.length;
				var view = new Uint8Array((__output : haxe.io.Bytes).getData(), 0, pending);
				__socket.write(view);
				__retainPendingOutput(pending, pending);
				#else
				var pendingLength = __output.length;
				var bytesWritten = __socket.output.writeBytes(__output, 0, pendingLength);
				__retainPendingOutput(bytesWritten, pendingLength);
				#end
			} catch (e:Dynamic) {
				var throwError = false;
				if (Std.isOfType(e, Error) && __isBlockedError(cast e)) {
					flushFull = true;
					// The same queue a partial write uses. This used to be
					// Timer.delay(__tryFlush, 0): per-socket work routed
					// through the global timer, when the socket already sits
					// in a registry that drains a writable queue every pump.
					// Two mechanisms for one job, and the timer was the one
					// that could take the whole runtime loop down with it,
					// because an exception there unwinds through the tick
					// dispatch instead of failing the one connection.
					__queueWrite();
				} else {
					throwError = true;
				}
				if (throwError) {
					// The real write error, not a fabricated one. This used to
					// throw "Operation attempted on invalid socket." for every
					// non-blocking-related failure -- a message naming a cause
					// (a null socket) that had nothing to do with what actually
					// happened, which is why an intermittent write failure here
					// was unreadable for so long. Surface what was caught.
					throw new IOError("Socket write failed: " + Std.string(e));
				}
			}

			__enforceOutputLimit();
		}
	}

	/**
		Applies `maxOutputBufferSize` once a flush has moved whatever the
		operating system would accept. Anything still buffered is data the
		peer is not draining.
	**/
	@:noCompletion private function __enforceOutputLimit():Void {
		// Read the property once: it is overridable, so a subclass may
		// redirect it to a buffer of its own.
		var limit:Int = maxOutputBufferSize;

		if (limit <= 0 || __output == null || __output.length <= limit) {
			return;
		}

		var buffered:Int = __output.length;
		var message:String = 'Socket output buffer reached $buffered bytes, exceeding the $limit byte limit; the peer is not reading.';

		switch (outputOverflowPolicy) {
			case CLOSE:
				if (hasEventListener(IOErrorEvent.IO_ERROR)) {
					dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
				}
				close();

			case THROW:
				throw new IOError(message);
		}
	}

	/**
		Reads a Boolean value from the socket. After reading a single byte,
		the method returns `true` if the byte is nonzero, and `false`
		otherwise.
		@return A value of `true` if the byte read is nonzero, otherwise
				`false`.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readBoolean():Bool {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readBoolean();
	}

	/**
		Reads a signed byte from the socket.
		@return A value from -128 to 127.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readByte():Int {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readByte();
	}

	/**
		Reads the number of data bytes specified by the length parameter from
		the socket. The bytes are read into the specified byte array, starting
		at the position indicated by `offset`.
		@param bytes  The ByteArray object to read data into.
		@param offset The offset at which data reading should begin in the
					  byte array.
		@param length The number of bytes to read. The default value of 0
					  causes all available data to be read.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__input.readBytes(bytes, offset, length);
	}

	/**
		Reads an IEEE 754 double-precision floating-point number from the
		socket.
		@return An IEEE 754 double-precision floating-point number.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readDouble():Float {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readDouble();
	}

	/**
		Reads an IEEE 754 single-precision floating-point number from the
		socket.
		@return An IEEE 754 single-precision floating-point number.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readFloat():Float {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readFloat();
	}

	/**
		Reads a signed 32-bit integer from the socket.
		@return A value from -2147483648 to 2147483647.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readInt():Int {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readInt();
	}

	/**
		Reads a multibyte string from the byte stream, using the specified
		character set.
		@param length  The number of bytes from the byte stream to read.
		@param charSet The string denoting the character set to use to
					   interpret the bytes. Possible character set strings
					   include `"shift_jis"`, `"CN-GB"`, and `"iso-8859-1"`.
					   For a complete list, see <a
					   href="../../charset-codes.html">Supported Character
					   Sets</a>.
					   **Note:** If the value for the `charSet` parameter is
					   not recognized by the current system, then the
					   application uses the system's default code page as the
					   character set. For example, a value for the `charSet`
					   parameter, as in `myTest.readMultiByte(22,
					   "iso-8859-01")` that uses `01` instead of `1` might
					   work on your development machine, but not on another
					   machine. On the other machine, the application will use
					   the system's default code page.
		@return A UTF-8 encoded string.
		@throws EOFError There is insufficient data available to read.
	**/
	public function readMultiByte(length:Int, charSet:String):String {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readMultiByte(length, charSet);
	}

	/**
		Reads an object from the socket, encoded in AMF serialized format.
		@return The deserialized object
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readObject():Dynamic {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (objectEncoding == HXSF) {
			return Unserializer.run(readUTF());
		} else {
			// TODO: Add support for AMF if haxelib "format" is included
			return null;
		}
	}

	/**
		Reads a signed 16-bit integer from the socket.
		@return A value from -32768 to 32767.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readShort():Int {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readShort();
	}

	/**
		Reads an unsigned byte from the socket.
		@return A value from 0 to 255.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readUnsignedByte():Int {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}
		return __input.readUnsignedByte();
	}

	/**
		Reads an unsigned 32-bit integer from the socket.
		@return A value from 0 to 4294967295.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readUnsignedInt():Int {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readUnsignedInt();
	}

	/**
		Reads an unsigned 16-bit integer from the socket.
		@return A value from 0 to 65535.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readUnsignedShort():Int {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readUnsignedShort();
	}

	/**
		Reads a UTF-8 string from the socket. The string is assumed to be
		prefixed with an unsigned short integer that indicates the length in
		bytes.
		@return A UTF-8 string.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readUTF():String {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readUTF();
	}

	/**
		Reads the number of UTF-8 data bytes specified by the `length`
		parameter from the socket, and returns a string.
		@param length The number of bytes to read.
		@return A UTF-8 string.
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	public function readUTFBytes(length:Int):String {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readUTFBytes(length);
	}

	public function readVarUInt():Int {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readVarInt();
	}

	/**
		Writes a Boolean value to the socket. This method writes a single
		byte, with either a value of 1 (`true`) or 0 (`false`).
		@param value The value to write to the socket: 1 (`true`) or 0
					 (`false`).
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	public function writeBoolean(value:Bool):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeBoolean(value);
		__queueWrite();
	}

	/**
		Writes a byte to the socket.
		@param value The value to write to the socket. The low 8 bits of the
					 value are used; the high 24 bits are ignored.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	public function writeByte(value:Int):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeByte(value);
		__queueWrite();
	}

	/**
		Writes a sequence of bytes from the specified byte array. The write
		operation starts at the position specified by `offset`.
		If you omit the `length` parameter the default length of 0 causes the
		method to write the entire buffer starting at `offset`.
		If you also omit the `offset` parameter, the entire buffer is written.
		@param bytes  The ByteArray object to write data from.
		@param offset The zero-based offset into the `bytes` ByteArray object
					  at which data writing should begin.
		@param length The number of bytes to write. The default value of 0
					  causes the entire buffer to be written, starting at the
					  value specified by the `offset` parameter.
		@throws IOError    An I/O error occurred on the socket, or the socket
						   is not open.
		@throws RangeError If `offset` is greater than the length of the
						   ByteArray specified in `bytes` or if the amount of
						   data specified to be written by `offset` plus
						   `length` exceeds the data available.
	**/
	public function writeBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeBytes(bytes, offset, length);
		__queueWrite();
	}

	/**
		Writes an IEEE 754 double-precision floating-point number to the
		socket.
		@param value The value to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	public function writeDouble(value:Float):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeDouble(value);
		__queueWrite();
	}

	/**
		Writes an IEEE 754 single-precision floating-point number to the
		socket.
		@param value The value to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	public function writeFloat(value:Float):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeFloat(value);
		__queueWrite();
	}

	/**
		Writes a 32-bit signed integer to the socket.
		@param value The value to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	public function writeInt(value:Int):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeInt(value);
		__queueWrite();
	}

	/**
		Writes a multibyte string from the byte stream, using the specified
		character set.
		@param value   The string value to be written.
		@param charSet The string denoting the character set to use to
					   interpret the bytes. Possible character set strings
					   include `"shift_jis"`, `"CN-GB"`, and `"iso-8859-1"`.
					   For a complete list, see <a
					   href="../../charset-codes.html">Supported Character
					   Sets</a>.
	**/
	public function writeMultiByte(value:String, charSet:String):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeUTFBytes(value);
		__queueWrite();
	}

	/**
		Write an object to the socket in AMF serialized format.
		@param object The object to be serialized.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	public function writeObject(object:Dynamic):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (objectEncoding == HXSF) {
			__output.writeUTF(Serializer.run(object));
			__queueWrite();
		} else {
			// TODO: Add support for AMF if haxelib "format" is included
		}
	}

	/**
		Writes a 16-bit integer to the socket. The bytes written are as
		follows:
		```
		(v >> 8) & 0xff v & 0xff
		```
		The low 16 bits of the parameter are used; the high 16 bits are
		ignored.
		@param value The value to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	public function writeShort(value:Int):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeShort(value);
		__queueWrite();
	}

	/**
		Writes a 32-bit unsigned integer to the socket.
		@param value The value to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	public function writeUnsignedInt(value:Int):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeUnsignedInt(value);
		__queueWrite();
	}

	/**
		Writes the following data to the socket: a 16-bit unsigned integer,
		which indicates the length of the specified UTF-8 string in bytes,
		followed by the string itself.
		Before writing the string, the method calculates the number of bytes
		that are needed to represent all characters of the string.
		@param value The string to write to the socket.
		@throws IOError    An I/O error occurred on the socket, or the socket
						   is not open.
		@throws RangeError The length is larger than 65535.
	**/
	public function writeUTF(value:String):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeUTF(value);
		__queueWrite();
	}

	/**
		Writes a UTF-8 string to the socket.
		@param value The string to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	public function writeUTFBytes(value:String):Void {
		if (__socket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeUTFBytes(value);
		__queueWrite();
	}

	@:noCompletion private function __cleanSocket():Void {
		try {
			#if nodejs
			// A js.node.net.Socket has no close(). This called one anyway, and
			// the catch below swallowed the TypeError, so closing a socket on
			// Node did nothing at all: the peer was never sent a FIN and the
			// handle went on holding the event loop open. end() flushes what
			// Node still has queued, sends the FIN, and releases the handle
			// once the peer answers.
			__socket.end();
			#else
			__socket.close();
			#end
		} catch (e:Dynamic) {}

		__stopConnecting();

		if (__cbInstance != null) {
			#if !js
			@:privateAccess
			__cbInstance.deregisterSocket(this.__socket);
			#end
		}
		__cbInstance = null;
		__socket = null;
		__connected = false;
		__isDirty = false;
		flushFull = false;
		#if (js && !nodejs)
		CrossByte.current().removeEventListener(TickEvent.TICK, this_onTick);
		#elseif nodejs
		CrossByte.current().removeEventListener(TickEvent.TICK, this_onTick);
		#else
		__closed = true;
		#end
	}

	@:noCompletion private inline function __stopConnecting():Void {
		if (__isConnecting && __cbInstance != null) {
			__cbInstance.removeEventListener(TickEvent.TICK, this_onTick);
			__isConnecting = false;
		}
	}

	@:noCompletion private inline function __startConnecting():Void {
		__isConnecting = true;
		__cbInstance.addEventListener(TickEvent.TICK, this_onTick);
	}

	@:noCompletion private function __tryFlush():Void {
		flushFull = false;

		// This is the retry half of a blocked write, dispatched from the
		// registry's writable queue, so the socket may have been closed in
		// between — by the peer, by the application, or by the overflow
		// policy. There is nothing left to retry, and throwing here would
		// escape into the runtime's dispatch and take down the caller's
		// loop rather than the one connection.
		if (__socket == null) {
			return;
		}

		try {
			flush();
		} catch (e:Dynamic) {
			// Same reasoning, for the error flush() raises itself: a peer
			// that resets the connection makes this throw from inside the
			// registry drain, where an escape costs every other connection
			// in the loop rather than this one. The IO error is dispatched
			// so the owner can react; the connection is left for the read
			// side to reap, exactly as before.
			__dispatchPooledIOError(Std.string(e));
			return;
		}

		if (__onWritableDrain != null) {
			__onWritableDrain();
		}
	}

	@:noCompletion private function __retainPendingOutput(bytesWritten:Int, pendingLength:Int):Void {
		if (bytesWritten >= pendingLength) {
			__isDirty = false;
			__output.clear();
			return;
		}

		var offset = bytesWritten > 0 ? bytesWritten : 0;
		var remaining = new ByteArray();
		remaining.endian = __endian;
		remaining.writeBytes(__output, offset, pendingLength - offset);
		__output = remaining;
		__isDirty = false;
		__queueWrite();
	}

	@:noCompletion private inline function __queueWrite():Void {
		if (__cbInstance == null) {
			return;
		}
		if (__isDirty == false) {
			__isDirty = true;
			#if !js
			@:privateAccess
			__cbInstance.queueWritable(this.__socket);
			#end
		}
	}

	public inline function registryOnReadable():Void {
		this_onTick();
	}

	public inline function registryOnWritable():Void {
		// `__isDirty` means "a writable retry is queued", so it is cleared
		// as the queue dispatches. Without this a socket that blocks twice
		// in a row never re-queues — __queueWrite() would see itself as
		// already pending — and its buffered data is stranded silently.
		__isDirty = false;

		// __tryFlush rather than flush: flush() returns early while
		// `flushFull` is set, so calling it here could never recover a
		// fully blocked socket; only clearing that flag first does. That
		// is why the timer was the sole recovery path for the blocked
		// case even though the queue was already wired for the partial one.
		__tryFlush();
	}

	// Event Handlers
	@:noCompletion private function socket_onClose(_):Void {
		__dispatchPooledSimpleEvent(Event.CLOSE);
	}

	@:noCompletion private function socket_onError(e):Void {
		__dispatchPooledIOError();
	}

	@:noCompletion private function socket_onMessage(msg:Dynamic):Void {
		#if (js && !nodejs)
		if (__input.position == __input.length) {
			__input.clear();
		}

		if ((msg.data is String)) {
			__input.position = __input.length;
			var cachePosition = __input.position;
			__input.writeUTFBytes(msg.data);
			__input.position = cachePosition;
		} else {
			var newData:ByteArray = (msg.data : ArrayBuffer);
			newData.readBytes(__input, __input.length);
		}

		if (__input.bytesAvailable > 0) {
			__dispatchPooledSocketData(__input.bytesAvailable, 0);
		}
		#elseif nodejs
		if (__input.position == __input.length) {
			__input.clear();
		}

		// Node hands out Buffers backed by a shared pool, so the region has to
		// be sliced out by byteOffset and length; taking .buffer whole would
		// pick up unrelated data sitting either side of this chunk.
		var chunk:Uint8Array = cast msg;
		var region = chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength);
		var newData:ByteArray = region;
		newData.readBytes(__input, __input.length);

		if (__input.bytesAvailable > 0) {
			__dispatchPooledSocketData(__input.bytesAvailable, 0);
		}
		#end
	}

	#if nodejs
	/**
	 * The handlers every Node socket needs, whether this side dialled it or
	 * `ServerSocket` accepted it. Shared so the two cannot come to report
	 * arriving data, a failure or a close differently -- which is the whole of
	 * what a socket is from a caller's side.
	 *
	 * A connect handler is not among them: an accepted socket is connected
	 * already, and there is no second event to wait for.
	 */
	@:noCompletion private function __bindNodeSocket(node:NodeSocket):Void {
		node.setNoDelay(true);

		node.on(SocketEvent.Data, function(chunk) {
			socket_onMessage(chunk);
		});
		node.on(SocketEvent.Error, function(_) {
			socket_onError(null);
		});
		node.on(SocketEvent.Close, function(_) {
			socket_onClose(null);
		});
	}

	/**
	 * Wraps a connection Node has already accepted.
	 *
	 * `ServerSocket` reaches the same place on a native target by setting these
	 * fields itself, because there the accepted thing is a `sys.net.Socket` and
	 * has to be registered for polling. Here there is nothing to register --
	 * Node delivers the bytes -- so what is left is the state a connected
	 * socket has, and it is set here rather than there so that `connect()` and
	 * `accept` produce the same object.
	 *
	 * @param node The socket Node handed to the server's connection listener.
	 * @param cbInstance The runtime whose ticks will flush this socket's writes.
	 */
	@:allow(crossbyte.net.ServerSocket)
	@:noCompletion private static function __adoptNodeSocket(node:NodeSocket, cbInstance:CrossByte):Socket {
		var socket = new Socket();

		socket.__socket = node;
		socket.__connected = true;
		socket.__closed = false;
		socket.__timestamp = Timer.stamp();
		socket.__host = node.remoteAddress;
		socket.__port = node.remotePort;

		socket.__output = new ByteArray();
		socket.__output.endian = socket.__endian;

		socket.__input = new ByteArray();
		socket.__input.endian = socket.__endian;

		socket.__cbInstance = cbInstance;
		socket.__bindNodeSocket(node);

		cbInstance.addEventListener(TickEvent.TICK, socket.this_onTick);

		return socket;
	}
	#end

	@:noCompletion private function socket_onOpen(_):Void {
		__connected = true;
		__closed = false;
		__dispatchPooledSimpleEvent(Event.CONNECT);
	}

	@:noCompletion private function this_onTick(?event:TickEvent):Void {
		#if (js && !nodejs)
		if (__socket != null) {
			flush();
		}
		#elseif nodejs
		// Data arrives on Node through the data event, not by polling, so the
		// tick has nothing to read -- it only pushes whatever writes have been
		// queued since the last one, exactly as the browser branch does.
		if (__socket != null) {
			flush();

			// And then whoever is feeding this socket in slices. On the native
			// targets that call comes from `registryOnWritable`, which the poll
			// registry makes when the descriptor reports writable; Node has no
			// registry and no descriptor, so nothing was making it at all. A
			// streamed response therefore wrote its head and first slice and
			// then stopped forever, waiting on a drain that could not arrive --
			// so every identity response over the 256 KB streaming threshold
			// hung its connection on Node, with the client left waiting on a
			// body that was never coming.
			//
			// Once per tick rather than per write: the pump bounds itself by
			// the watermark and by a burst budget, so it writes only what the
			// peer has made room for however often it is asked.
			if (__onWritableDrain != null) {
				__onWritableDrain();
			}
		}
		#else
		if (__socket == null) {
			return;
		}

		var doConnect = false;
		var doClose = false;
		var doPeerClose = false;

		if (!connected) {
			// Asked about on both sets. A connect that fails is reported in the
			// exception set on Windows and never becomes writable, so watching
			// writability alone could not see it: a refused connection sat here
			// until the connect timeout -- twenty seconds by default, for a
			// refusal the operating system had reported in two.
			//
			// POSIX reports a failed connect as writable instead, so there the
			// connect is announced and the failure surfaces on the first read.
			// Watching the exception set costs nothing there and closes the gap
			// on Windows.
			var r = SysSocket.select([], [__socket], [__socket], 0);

			if (r.write.length > 0 && r.write[0] == __socket) {
				doConnect = true;
			} else if (r.others.length > 0 && r.others[0] == __socket) {
				// Never came up, so closeWasConnected stays false below and this
				// leaves as an ioError rather than a CLOSE. A connection that
				// failed is a different fact from one that hung up.
				doClose = true;
			} else if (Sys.time() - __timestamp > timeout / 1000) {
				doClose = true;
			}
		}

		var bLength = 0;
		var readPos:Int = 0;
		var appending:Bool = false;

		if ((connected || doConnect) && !__peerShutdown) {
			// Arrivals are appended to the existing buffer, which grows
			// geometrically and keeps its capacity. This used to allocate a
			// fresh Bytes per arrival and copy the whole unread backlog into
			// it, so the buffer was rebuilt from scratch on every event.
			__compactInput();
			readPos = __input.position;
			__input.position = __input.length;
			appending = true;

			var scratch:Bytes = __scratch();

			try {
				var l:Int;

				do {
					l = __socket.input.readBytes(scratch, 0, scratch.length);

					if (l > 0) {
						__input.writeBytes(scratch, 0, l);
						bLength += l;
					}
					// The eval gate below runs inside this try on purpose: a
					// select failure on a dying socket lands in the catches and
					// closes the connection, the same as a failed read.
				} while (l == scratch.length #if eval && __evalShouldKeepReading() #end);
			} catch (e:Eof) {
				// The peer sent FIN. That is all this says: it will send no
				// more. Whether it is still reading -- half-closed and waiting
				// for an answer -- or gone entirely is not knowable here, and
				// a write would succeed either way by reaching only the kernel
				// send buffer. So the fact is recorded and the policy decides.
				__peerShutdown = true;

				if (peerShutdownPolicy == HALF_OPEN) {
					doPeerClose = true;
				} else {
					doClose = true;
				}
			} catch (e:Error) {
				if (!__isBlockedError(e)) {
					doClose = true;
				}
			} catch (e:Dynamic) {
				doClose = true;
			}
		}

		if (appending) {
			// Restored whether the loop ended cleanly, at EOF, or on a throw:
			// leaving the write cursor in place would make the next read look
			// like consumed data to every reader below.
			__input.position = readPos;
		}

		// The lifecycle verdict is taken from the state this tick observed,
		// before anything below mutates it, so that ordering the three
		// dispatches does not change which of them fires. A close decided
		// while still connected is a peer hangup (CLOSE); one decided before
		// the connection ever came up is a failure (ioError) — the same split
		// the single if/else chain here used to make.
		// A connect that completes this tick counts as connected for the verdict
		// below: the peer sent data, so the connection came up. Without the
		// `|| doConnect` a one-shot peer -- accept, write, close -- whose data and
		// FIN arrive in the same tick the connect completes would be reported as a
		// failed connection (ioError) rather than a hangup after a clean exchange
		// (CLOSE).
		var closeWasConnected:Bool = connected || doConnect;

		// CONNECT, then any data, then CLOSE. A tick can legitimately carry
		// all three: the handshake completes, the peer's first burst is
		// already buffered, and its FIN is right behind it. The connect is
		// announced even when the close is decided in the same tick -- the
		// connection did come up, and a listener that sets up its data handling
		// on CONNECT must run before the data and the close reach it. The guard
		// here used to also require `!doClose`, which silently dropped CONNECT for
		// exactly that case and, with it, turned the close into an ioError.
		if (doConnect) {
			__connected = true;
			__stopConnecting();
			@:privateAccess
			__cbInstance.registerSocket(__socket);
			__dispatchPooledSimpleEvent(Event.CONNECT);
		}

		// Data is delivered before the close is announced. This block used to
		// run after it, which lost the last bytes of every connection whose
		// final payload arrived in the same tick as its FIN: a listener that
		// tears down on CLOSE never saw them, and one that tried to read them
		// from the CLOSE handler hit a socket already nulled by
		// __cleanSocket() and threw IOError out of the tick dispatch — taking
		// down the runtime loop rather than the one connection. Not an eval
		// problem; every target read in that order.
		if (bLength > 0) {
			__dispatchPooledSocketData(bLength, 0);
		}

		// Announced after the data for the same reason CLOSE is: the peer's
		// last bytes and its FIN routinely arrive in one tick, and a listener
		// that tears down here must have seen them first.
		if (doPeerClose && !doClose) {
			__dispatchPooledSimpleEvent(Event.PEER_CLOSE);
		}

		if (doClose) {
			__cleanSocket();
			if (closeWasConnected) {
				__dispatchPooledSimpleEvent(Event.CLOSE);
			} else {
				__dispatchPooledIOError("Connection failed");
			}
		}

		if (__socket != null) {
			try {
				flush();
			} catch (e:IOError) {
				__dispatchPooledIOError(e.message);
			}
		}
		#end
	}

	#if eval
	/**
		Whether the read loop above may safely go round again after a read
		that filled the shared read buffer.

		That loop re-reads whenever a read fills the buffer. On targets with
		real non-blocking sockets the extra read raises `Blocked` once the
		burst is exhausted; on eval `setBlocking` is a no-op (see the vendored
		sys.net.Socket), the descriptor stays blocking, and that same extra
		read parks the whole runtime thread until the peer sends more or
		closes. Any inbound burst of exactly a multiple of the read buffer size
		bytes therefore hung the interpreter. A zero-timeout select is the
		only non-blocking readability signal the eval target offers, so loop
		continuation is gated on it there — and on it alone, leaving the
		Blocked-driven exit untouched everywhere else.

		TLS is the exception, and deliberately keeps the old behaviour: a
		select on the raw descriptor reports the *socket*, not the TLS
		session. mbedtls reads whole records at a time, so plaintext already
		decrypted into its buffer is invisible to select — gating on it would
		report "nothing pending" while a complete message sat decrypted and
		unread, stranding it until the peer happened to send more. A read
		that may block is recoverable; silently withheld payload is not.
	**/
	@:noCompletion private function __evalShouldKeepReading():Bool {
		if (Std.isOfType(__socket, sys.ssl.Socket)) {
			return true;
		}

		return SysSocket.select([__socket], [], [], 0).read.length > 0;
	}
	#end

	@:noCompletion private function __dispatchPooledSimpleEvent(type:String):Void {
		if (!hasEventListener(type)) {
			return;
		}

		var pooledEvent:Event;
		var inUse:Bool;
		switch (type) {
			case Event.CONNECT:
				pooledEvent = __pooledConnectEvent;
				inUse = __pooledConnectEventInUse;
			case Event.CLOSE:
				pooledEvent = __pooledCloseEvent;
				inUse = __pooledCloseEventInUse;
			default:
				dispatchEvent(new Event(type));
				return;
		}

		if (inUse) {
			dispatchEvent(new Event(type));
			return;
		}

		if (pooledEvent == null) {
			pooledEvent = new Event(type);
			switch (type) {
				case Event.CONNECT: __pooledConnectEvent = pooledEvent;
				case Event.CLOSE: __pooledCloseEvent = pooledEvent;
				default:
			}
		} else {
			@:privateAccess {
				pooledEvent.target = null;
				pooledEvent.currentTarget = null;
			}
		}

		switch (type) {
			case Event.CONNECT: __pooledConnectEventInUse = true;
			case Event.CLOSE: __pooledCloseEventInUse = true;
			default:
		}

		try {
			dispatchEvent(pooledEvent);
		} catch (error:Dynamic) {
			switch (type) {
				case Event.CONNECT: __pooledConnectEventInUse = false;
				case Event.CLOSE: __pooledCloseEventInUse = false;
				default:
			}
			throw error;
		}

		switch (type) {
			case Event.CONNECT: __pooledConnectEventInUse = false;
			case Event.CLOSE: __pooledCloseEventInUse = false;
			default:
		}
	}

	@:noCompletion private function __dispatchPooledSocketData(bytesLoaded:UInt, bytesTotal:UInt):Void {
		if (!hasEventListener(ProgressEvent.SOCKET_DATA)) {
			return;
		}

		if (__pooledSocketDataEventInUse) {
			dispatchEvent(new ProgressEvent(ProgressEvent.SOCKET_DATA, bytesLoaded, bytesTotal));
			return;
		}

		if (__pooledSocketDataEvent == null) {
			__pooledSocketDataEvent = new ProgressEvent(ProgressEvent.SOCKET_DATA, bytesLoaded, bytesTotal);
		} else {
			__pooledSocketDataEvent.bytesLoaded = bytesLoaded;
			__pooledSocketDataEvent.bytesTotal = bytesTotal;
			@:privateAccess {
				__pooledSocketDataEvent.target = null;
				__pooledSocketDataEvent.currentTarget = null;
			}
		}

		__pooledSocketDataEventInUse = true;
		try {
			dispatchEvent(__pooledSocketDataEvent);
		} catch (error:Dynamic) {
			__pooledSocketDataEventInUse = false;
			throw error;
		}
		__pooledSocketDataEventInUse = false;
	}

	@:noCompletion private function __dispatchPooledIOError(text:String = ""):Void {
		if (!hasEventListener(IOErrorEvent.IO_ERROR)) {
			return;
		}

		if (__pooledIOErrorEventInUse) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, text));
			return;
		}

		if (__pooledIOErrorEvent == null) {
			__pooledIOErrorEvent = new IOErrorEvent(IOErrorEvent.IO_ERROR, text);
		} else {
			@:privateAccess {
				__pooledIOErrorEvent.text = text;
				__pooledIOErrorEvent.target = null;
				__pooledIOErrorEvent.currentTarget = null;
			}
		}

		__pooledIOErrorEventInUse = true;
		try {
			dispatchEvent(__pooledIOErrorEvent);
		} catch (error:Dynamic) {
			__pooledIOErrorEventInUse = false;
			throw error;
		}
		__pooledIOErrorEventInUse = false;
	}

	override public function dispatchEvent(event:Event):Bool {
		return super.dispatchEvent(event);
	}

	// Get & Set Methods
	@:noCompletion private function get_bytesAvailable():Int {
		return __input.bytesAvailable;
	}

	@:noCompletion private function get_bytesPending():Int {
		return __output.length;
	}

	@:noCompletion private function get_connected():Bool {
		return __connected;
	}

	@:noCompletion private function get_endian():Endian {
		return __endian;
	}

	@:noCompletion private function set_endian(value:Endian):Endian {
		__endian = value;

		if (__input != null)
			__input.endian = value;
		if (__output != null)
			__output.endian = value;

		return __endian;
	}

	@:noCompletion private function get_localAddress():String {
		#if nodejs
		return __socket.localAddress;
		#elseif (js && !nodejs)
		return __refuseEndpoint("localAddress");
		#else
		// Canonical, because the platforms disagree: hxcpp renders `::1` and
		// the jvm `0:0:0:0:0:0:0:1` for the same address. DatagramSocket has
		// compressed since IPv6.compress was written -- its doc names this very
		// difference -- and the TCP socket beside it never did, so an
		// application comparing what it bound against what it was told back
		// worked over UDP and failed over TCP on the same target.
		return crossbyte._internal.net.IPv6.compress(__socket.host().host.toString());
		#end
	}

	@:noCompletion private function get_localPort():Int {
		#if nodejs
		return __socket.localPort;
		#elseif (js && !nodejs)
		return __refuseEndpoint("localPort");
		#else
		return __socket.host().port;
		#end
	}

	@:noCompletion private function get_remoteAddress():String {
		#if nodejs
		return __socket.remoteAddress;
		#elseif (js && !nodejs)
		return __refuseEndpoint("remoteAddress");
		#else
		return crossbyte._internal.net.IPv6.compress(__socket.peer().host.toString());
		#end
	}

	@:noCompletion private function get_alpnProtocol():Null<String> {
		if (__socket == null) {
			return null;
		}

		#if nodejs
		// Only a TLS socket carries the field, and Node reports `false` rather
		// than null when the handshake negotiated nothing.
		var negotiated:Dynamic = (cast __socket : Dynamic).alpnProtocol;
		return Std.isOfType(negotiated, String) ? negotiated : null;
		#elseif cpp
		// A plain TCP client reaches here too; sys.ssl.Socket extends
		// sys.net.Socket, so the cast is only safe after the check.
		return Std.isOfType(__socket, sys.ssl.Socket) ? AlpnSocket.negotiated(cast __socket) : null;
		#elseif (java || jvm)
		// Asked for dynamically rather than through the type. Naming
		// JvmSslSocket here pulls its java.nio imports into the initialisation
		// macro's context, where the java package is unreachable and the build
		// fails on Buffer rather than on anything to do with ALPN. A plain
		// client socket has no such method and answers null.
		var holder:Dynamic = __socket;
		var negotiated:Dynamic = try {
			holder.getALPN();
		} catch (e:Dynamic) {
			null;
		}
		return Std.isOfType(negotiated, String) ? negotiated : null;
		#else
		return null;
		#end
	}

	@:noCompletion private function get_remotePort():Int {
		#if nodejs
		return __socket.remotePort;
		#elseif (js && !nodejs)
		return __refuseEndpoint("remotePort");
		#else
		return __socket.peer().port;
		#end
	}

	#if (js && !nodejs)
	/**
	 * All four endpoint accessors called `host()` and `peer()` on the raw
	 * socket, which a browser's WebSocket does not have -- so each threw a
	 * TypeError about a missing method rather than saying what was actually
	 * wrong.
	 *
	 * Typed as returning whatever the caller expects so one helper serves both
	 * the String and the Int accessors. It never returns.
	 */
	@:noCompletion private function __refuseEndpoint<T>(what:String):T {
		throw new IllegalOperationError("Socket." + what
			+ " is not available in a browser: the connection is a WebSocket held by the page, and a page is not told either end of it.");
	}
	#end

	/**
		Whether the TLS layer is holding bytes `select` cannot see.

		Asked dynamically rather than through the jvm socket's type: naming
		`JvmSslSocket` here pulls `java.nio` into the init-macro context and the
		build fails on "cannot access the java package while in a macro". The
		same reason `alpnProtocol` asks the way it does.
	**/
	@:noCompletion public function registryHasBufferedInput():Bool {
		#if (java || jvm)
		if (!secure || __socket == null) {
			return false;
		}

		var holder:Dynamic = __socket;
		var buffered:Dynamic = try {
			holder.hasBufferedInput();
		} catch (e:Dynamic) {
			false;
		}

		return buffered == true;
		#else
		return false;
		#end
	}

	@:noCompletion private function get_registryClosed():Bool {
		return __closed || __socket == null;
	}

	@:noCompletion private inline function __cleanupFailedConnect():Void {
		if (__socket != null) {
			try {
				#if nodejs
				// destroy() rather than the end() a clean close uses: a connect
				// that failed has nothing queued worth flushing, and there may
				// be no peer to send a FIN to.
				__socket.destroy();
				#else
				__socket.close();
				#end
			} catch (_:Dynamic) {}
		}
		__socket = null;
		__cbInstance = null;
		__connected = false;
		__isConnecting = false;
		__isDirty = false;
		flushFull = false;
		__closed = true;
	}

	@:noCompletion private inline function __isBlockedError(error:Dynamic):Bool {
		return crossbyte._internal.socket.BlockedError.isBlocked(error);
	}

	@:noCompletion private inline function get_peerShutdown():Bool {
		return __peerShutdown;
	}

	/**
		Shuts down one or both directions of the connection.

		`shutdown(false, true)` is the half-close: it sends FIN, telling the
		peer this side will write nothing further, while leaving this side able
		to read whatever the peer still has to say. It is how a great many
		hand-rolled TCP protocols mark the end of a request, and the only
		end-of-request signal available to one that does not length-prefix.

		The socket stays open either way. Closing is still `close()`.
	**/
	public function shutdown(read:Bool, write:Bool):Void {
		if (__socket == null) {
			return;
		}

		if (read) {
			// Nothing more will be read, and the read loop must stop trying:
			// on some targets a shut read direction reports Eof forever, which
			// would otherwise re-enter the policy branch every tick.
			__peerShutdown = true;
		}

		#if (js && !nodejs)
		throw new IllegalOperationError("Socket.shutdown() is not available in a browser: a WebSocket closes both directions at once, so there is no half to close.");
		#end

		try {
			#if nodejs
			// end() is the write half, and it is the half that matters: it is
			// the FIN that tells a peer no more requests are coming. Node has
			// no read half to shut -- there is no shutdown(SHUT_RD) on a
			// stream -- so pausing is the closest thing, and it at least stops
			// data arriving for a direction the caller has declared finished.
			if (write) {
				__socket.end();
			}

			if (read) {
				__socket.pause();
			}
			#else
			__socket.shutdown(read, write);
			#end
		} catch (e:Dynamic) {
			// A peer that has already gone makes this fail, and there is
			// nothing to recover: the direction being asked for is closed
			// either way. Reported as a close rather than raised, so tearing
			// down a dead connection is not itself an error path.
			close();
		}
	}
}
