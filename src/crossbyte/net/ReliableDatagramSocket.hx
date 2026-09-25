package crossbyte.net;

// Not built for the browser: it is a reliability layer over UDP, which the browser does not have.
#if !(js && !nodejs)

import crossbyte.Seq32;
import crossbyte.Timer as CBTimer;
import crossbyte.crypto.SecureRandom;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.io.IDataInput;
import crossbyte.io.IDataOutput;
import crossbyte.net._internal.reliable.OutstandingFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import haxe.Serializer;
import haxe.Unserializer;
import haxe.ds.IntMap;
import haxe.ds.Vector;
#if !(js && !nodejs)
#if !nodejs
import sys.net.Host;
#end
import crossbyte._internal.net.IPv6;
#end

@:access(crossbyte.net.ReliableDatagramServerSocket)
/**
	The `ReliableDatagramSocket` class provides a session-oriented reliable transport
	on top of UDP.
	It adds handshake, retransmission, acknowledgment, ordered delivery, and optional
	stream-style buffering on top of `DatagramSocket`.
	Use `mode = DATAGRAM` to preserve reliable payload boundaries and receive
	`DatagramSocketDataEvent.DATA` events. Use `mode = STREAM` to expose the same
	reliable ordered transport through the `IDataInput` and `IDataOutput` APIs and
	receive `ProgressEvent.SOCKET_DATA` notifications instead.
	Socket mode must be selected before connecting or before a server accepts the session.
	@event connect Dispatched when the reliable handshake completes.
	@event close Dispatched when the reliable session closes.
	@event ioError Dispatched when a handshake or transport error occurs.
	@event data Dispatched in `DATAGRAM` mode when a complete reliable payload is delivered.
	@event socketData Dispatched in `STREAM` mode when additional ordered bytes are available.
**/
class ReliableDatagramSocket extends EventDispatcher implements IDataInput implements IDataOutput {
	/**
		A slot for whatever the application wants this connection to carry.

		Untouched by the framework, and it goes when the connection does.
		Without one, an application holding per-connection state -- a session,
		a player, a room membership -- keeps a `Map` beside the connection and
		has to remember to remove the entry on close. Forgetting is not
		noisy: the connection is gone, the traffic stops, and the entry stays
		until the process does.

		Typed as `Any` rather than `Dynamic` so reading it back needs an
		explicit cast, and a wrong one is a compile error rather than a field
		access on whatever happened to be there.

		```haxe
		connection.userData = new Session(player);
		var session:Session = cast connection.userData;
		```
	**/
	public var userData:Any = null;

	/**
		Indicates whether reliable UDP sessions are supported by the current target.
	**/
	public static var isSupported(default, null):Bool = DatagramSocket.isSupported;

	/**
		Indicates whether the underlying UDP transport is currently bound.
	**/
	public var bound(get, never):Bool;

	/**
		The number of readable bytes currently buffered for stream mode.
		Returns `0` while in datagram mode.
	**/
	public var bytesAvailable(get, never):UInt;

	/**
		The number of bytes queued in the local stream output buffer waiting for `flush()`.
		Returns `0` while in datagram mode.
	**/
	public var bytesPending(get, never):Int;

	/**
		Indicates whether the reliable session handshake has completed.
	**/
	public var connected(get, never):Bool;

	/**
		The byte order used by stream-mode `ByteArray` serialization.
	**/
	public var endian(get, set):Endian;

	/**
		The local IP address of the underlying UDP transport.
	**/
	public var localAddress(get, never):String;

	/**
		The local UDP port of the underlying transport.
	**/
	public var localPort(get, never):Int;

	/**
		Controls whether the socket exposes reliable payloads as discrete datagrams or
		as a buffered ordered byte stream. This property must be set before the socket
		connects or before it is accepted by a server.
	**/
	public var mode(get, set):ReliableDatagramSocketMode;

	/**
		Controls how `readObject()` and `writeObject()` serialize stream-mode objects.
	**/
	public var objectEncoding:ObjectEncoding;

	/**
		The remote IP address for this reliable session, or an empty string before a
		connection attempt begins.
	**/
	public var remoteAddress(get, never):String;

	/**
		The remote UDP port for this reliable session, or `0` before a connection attempt begins.
	**/
	public var remotePort(get, never):Int;

	/**
		The connection timeout, in milliseconds, used while establishing a reliable session.
	**/
	public var timeout(get, set):Int;

	/**
		How many bytes may wait for the window before `outputOverflowPolicy`
		decides what happens. Zero, the default, means no limit.

		What is waiting is visible as `bufferedAmount`; an application that
		watches that never reaches this.
	**/
	public var maxOutputBufferSize:Int = 0;

	/** What to do when the queue exceeds `maxOutputBufferSize`. **/
	public var outputOverflowPolicy:OutputOverflowPolicy = CLOSE;

	/**
		Bytes written and not yet put on the wire.

		Zero while the path keeps up. It grows when the congestion window has
		no room left, which is how a sender learns the peer or the path
		between cannot take data as fast as it is being produced.
	**/
	public var bufferedAmount(get, never):Int;

	@:noCompletion private function get_bufferedAmount():Int {
		return __queuedBytes;
	}

	/**
		The largest reliable message the peer may send this socket, in bytes.
		Zero means no limit.

		A reliable message larger than one frame travels as several, and is
		held here until its last one arrives -- so what a peer can make this
		side hold is whatever it declares a message to be. Past this the
		session is closed, with an `ioError` saying why, rather than the
		fragments being kept for a message with no end.
	**/
	public var maxMessageSize:Int = DEFAULT_MAX_MESSAGE_SIZE;

	/** `maxMessageSize` unless changed: eight megabytes, as `FrameCodec` takes. **/
	public static inline var DEFAULT_MAX_MESSAGE_SIZE:Int = 8 * 1024 * 1024;

	/**
		What the peer sent with its CONNECT, or `null` if no CONNECT has come
		from it.

		Every session a server accepts has one -- empty when the peer's
		`connect` passed nothing -- and it is the payload
		`ReliableDatagramServerSocket.admit` was shown, from its start, so the
		handler that takes the session can tell who it is by the same token
		the hook let it in on. A dialled session has one only when its peer
		dialled too, as two peers opening a path through NAT both do; a client
		of an ordinary server never receives a CONNECT, and reads `null`.
	**/
	public var connectPayload(default, null):ByteArray = null;

	@:noCompletion private static inline var CONNECTION_ATTEMPT_INTERVAL:Float = 3.0;
	@:noCompletion private static inline var DELIVERY_WINDOW:Int = 500;
	@:noCompletion private static inline var KEEP_ALIVE_INTERVAL:Float = 75.0;

	/**
		How often the socket looks for frames whose time is up.

		One timer for the session rather than one per frame. The old shape
		armed a repeating `CBTimer` for every packet put on the wire, so a
		sender with the window full held hundreds of live timers, and a server
		held that many times its connection count. This is the granularity of
		the retransmission clock, not the wait itself -- what a frame waits is
		its own deadline, from `__rto`.
	**/
	@:noCompletion private static inline var RETRANSMIT_TICK:Float = 0.05;

	/** The floor on a retransmission timeout, as RFC 6298 puts it. **/
	@:noCompletion private static inline var MIN_RTO:Float = 0.2;

	/** And the ceiling, so a dead path is given up on rather than waited for. **/
	@:noCompletion private static inline var MAX_RTO:Float = 10.0;

	/** What the timeout is before a single round trip has been measured. **/
	@:noCompletion private static inline var INITIAL_RTO:Float = 1.0;

	/**
		Frames in flight before a round trip has been measured.

		RFC 6928's initial window. Small enough not to be a burst, large
		enough that a short message is not paced out one packet per round
		trip.
	**/
	@:noCompletion private static inline var INITIAL_WINDOW:Int = 10;

	/** The congestion window never shrinks below this. **/
	@:noCompletion private static inline var MIN_WINDOW:Int = 2;

	@:noCompletion private var __alive:Bool = false;
	@:noCompletion private var __closed:Bool = false;
	@:noCompletion private var __connected:Bool = false;
	@:noCompletion private var __connectionAttemptHandle:Int = -1;
	// What every CONNECT this side sends carries: a copy, taken when connect
	// was called, or null for nothing.
	@:noCompletion private var __connectOut:ByteArray = null;
	@:noCompletion private var __connectionTimeoutHandle:Int = -1;
	@:noCompletion private var __endian:Endian = Endian.BIG_ENDIAN;
	// Out-of-order frames, kept whole: a fragment's `more` flag is as much a
	// part of it as its bytes.
	@:noCompletion private var __inFrameCache:IntMap<ReliableDatagramFrame>;

	// The fragments of a reliable message still arriving, and their total.
	// Joined once when the last arrives, rather than appended to a buffer
	// that grows -- and copies -- as it goes.
	@:noCompletion private var __fragments:Array<ByteArray> = [];
	@:noCompletion private var __fragmentBytes:Int = 0;

	// The newest counter delivered on each sequenced channel, -1 for none,
	// and the next to send. Made on first use: most sessions never sequence
	// anything, and 256 entries each is not worth carrying for them.
	@:noCompletion private var __sequencedIn:Vector<Int>;
	@:noCompletion private var __sequencedOut:Vector<Int>;

	// Every frame this socket sends is written here and sent from here. A
	// send has finished with its bytes before it returns, so one buffer
	// serves every frame, where encoding each into one of its own was an
	// allocation per packet and per acknowledgement.
	@:noCompletion private var __scratch:ByteArray;
	@:noCompletion private var __inFrameCacheSize:Int = 0;
	@:noCompletion private var __inSequence:Seq32 = 0;
	@:noCompletion private var __incoming:Bool = false;
	@:noCompletion private var __input:ByteArray;
	@:noCompletion private var __keepAliveHandle:Int = -1;
	@:noCompletion private var __mode:ReliableDatagramSocketMode = DATAGRAM;
	@:noCompletion private var __outFrameCache:IntMap<OutstandingFrame>;
	@:noCompletion private var __retransmitHandle:Int = -1;

	/**
		How many frames may be in flight at once.

		The send window was a constant 500 that took no notice of whether any
		of it was arriving. A reliable transport that retransmits on a fixed
		schedule into a path that is already dropping packets makes the drops
		worse, and with a window that never yields it keeps doing so -- which
		is how one slow client costs a server the bandwidth of many. This
		opens on acknowledgement and halves on loss, which is the behaviour
		every other reliable transport on the wire already agrees to.
	**/
	@:noCompletion private var __congestionWindow:Float = INITIAL_WINDOW;

	/** Where the window stops doubling and starts creeping. **/
	@:noCompletion private var __slowStartThreshold:Float = DELIVERY_WINDOW;

	/** Smoothed round trip time, and its variation. Null until one is measured. **/
	@:noCompletion private var __smoothedRtt:Float = -1;

	@:noCompletion private var __rttVariation:Float = 0;

	/** What a frame waits before it is sent again. **/
	@:noCompletion private var __rto:Float = INITIAL_RTO;

	/** Bytes sitting in `__outgoingQueue` waiting for the window to open. **/
	@:noCompletion private var __queuedBytes:Int = 0;

	/** How far `__outgoingQueue` has been drained; see `__drainQueue`. **/
	@:noCompletion private var __queueAt:Int = 0;
	@:noCompletion private var __outSequence:Seq32 = 0;
	// Frames made and not yet sent. They are the frames the retransmission
	// cache will hold, made once, carrying the `more` flag with them.
	@:noCompletion private var __outgoingQueue:Array<OutstandingFrame>;
	@:noCompletion private var __output:ByteArray;
	@:noCompletion private var __ownsTransport:Bool = true;
	@:noCompletion private var __remoteAddress:String = "";
	@:noCompletion private var __remotePort:Int = 0;
	@:noCompletion private var __remoteResponsePort:Int = 0;
	@:noCompletion private var __server:ReliableDatagramServerSocket;
	@:noCompletion private var __timeout:Int = 20000;
	@:noCompletion private var __transport:DatagramSocket;
	@:noCompletion private var __transportListenerReady:Bool = false;
	@:noCompletion private var __windowBase:Seq32 = 0;

	/**
		Creates a new `ReliableDatagramSocket`.
		If `host` and `port` are supplied, the socket attempts to open a reliable
		session immediately.
		@param host The remote host to connect to. Pass `null` to create an unconnected socket.
		@param port The remote port to connect to. Pass `0` to create an unconnected socket.
	**/
	public function new(host:String = null, port:Int = 0) {
		super();

		__inFrameCache = new IntMap();
		__inFrameCacheSize = 0;
		__outFrameCache = new IntMap();
		__outgoingQueue = [];
		__scratch = new ByteArray();
		__scratch.length = ReliableDatagramProtocol.MAX_FRAME_SIZE;
		objectEncoding = ObjectEncoding.DEFAULT;
		__input = __createBuffer();
		__output = __createBuffer();
		__transport = new DatagramSocket();
		__prepareTransportListener();
		__resetSequences();

		if (host != null || port != 0) {
			connect(host, port);
		}
	}

	/**
		Binds the underlying UDP transport before connecting.
		This is only available on client-created sockets; sockets accepted by a
		`ReliableDatagramServerSocket` inherit the server transport.
		@param localPort The local UDP port to bind to. Use `0` to allow the operating system to choose.
		@param localAddress The local address to bind to. Use `"0.0.0.0"` to bind on all IPv4 interfaces.
		@throws IllegalOperationError If this socket was accepted by a server.
	**/
	public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		if (!__ownsTransport) {
			throw new IllegalOperationError("Cannot bind a socket accepted by a server.");
		}

		__transport.bind(localPort, localAddress);
	}

	/**
		Closes the reliable session.
		If a remote endpoint is known, a close control frame is sent before local cleanup occurs.
	**/
	public function close():Void {
		if (__closed) {
			return;
		}

		if (__remoteAddress != "" && __remotePort > 0) {
			__sendControl(FIN);
		}

		__dispose(true);
	}

	/**
		Initiates a reliable UDP session to the specified remote endpoint.
		The socket automatically binds its transport to an ephemeral local port if
		you have not called `bind()` already.

		`payload` rides in every CONNECT the handshake sends, for the server's
		`admit` to decide on before it allocates anything -- a join token, a
		protocol version, a ticket. It must fit one frame. It is sent in the
		clear and repeated until the server answers, and nothing proves the
		sender's address until the handshake completes, so what it can carry
		is something the server can check, not something that must stay secret.

		@param host The remote host to connect to.
		@param port The remote UDP port to connect to.
		@param payload Sent with the CONNECT: all of it, from 0 to its length,
		       copied now, so changing it afterwards changes nothing sent.
		@throws IOError If the socket is closed or otherwise invalid.
		@throws IllegalOperationError If this socket was accepted by a server.
		@throws ArgumentError If `host` is invalid or empty.
		@throws RangeError If `port` is outside the valid UDP port range, or
		        `payload` is larger than one frame,
		        `ReliableDatagramProtocol.MAX_PAYLOAD_SIZE` bytes.
	**/
	public function connect(host:String, port:Int, ?payload:ByteArray):Void {
		if (__closed) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (!__ownsTransport) {
			throw new IllegalOperationError("Cannot connect a socket accepted by a server.");
		}

		if (host == null || host.length == 0) {
			throw new ArgumentError("One of the parameters is invalid");
		}

		if (port <= 0 || port > 65535) {
			throw new RangeError("Invalid socket port number specified.");
		}

		var outgoing:ByteArray = __connectPayloadOf(payload);

		if (!bound) {
			__transport.bind();
		}

		#if nodejs
		// No resolution step. hxnodejs resolves a name synchronously through
		// `deasync`, a native npm addon that has to be installed and built --
		// requiring it is enough to stop the program loading, whether or not a
		// name is ever passed. A numeric address needs no lookup, and a name
		// is refused for the same reason a connected DatagramSocket refuses
		// one: a session is matched against the address a reply arrives from.
		if (!IPv6.isNumericAddress(host)) {
			throw new ArgumentError("A reliable datagram session needs a numeric address on Node, not a name: the session is matched against the address replies arrive from, and resolving a name there needs a callback this call cannot wait for.");
		}

		__remoteAddress = host;
		#else
		var resolved:Host;
		try {
			resolved = new Host(host);
		} catch (_:Dynamic) {
			throw new ArgumentError("One of the parameters is invalid");
		}

		__remoteAddress = resolved.toString();
		#end
		__remotePort = port;
		__remoteResponsePort = 0;
		__incoming = false;
		__connectOut = outgoing;
		__resetSequences();
		__transport.receive();
		__beginHandshake();
	}

	/**
		A copy of a CONNECT payload, or null for none; refused rather than
		split when it is larger than the one frame a CONNECT is.
	**/
	@:noCompletion private static function __connectPayloadOf(payload:ByteArray):ByteArray {
		if (payload == null || payload.length == 0) {
			return null;
		}
		if (payload.length > ReliableDatagramProtocol.MAX_PAYLOAD_SIZE) {
			throw new RangeError('A CONNECT payload must fit one frame, ${ReliableDatagramProtocol.MAX_PAYLOAD_SIZE} bytes, and this one is ${payload.length}.');
		}
		var copy = new ByteArray();
		copy.length = payload.length;
		(copy : haxe.io.Bytes).blit(0, payload, 0, payload.length);
		return copy;
	}

	/**
		Flushes the current stream-mode output buffer by segmenting it into reliable
		payload frames and queuing them for ordered delivery.
		Has no effect when the stream output buffer is empty.
		@throws IllegalOperationError If the socket is not in `STREAM` mode.
		@throws IOError If the reliable session is not connected.
	**/
	public function flush():Void {
		__requireStreamMode();
		__requireOpenConnection();

		if (__output.length == 0) {
			return;
		}

		__queueBytes(__output, 0, __output.length);
		__output = __createBuffer();
	}

	/**
		Reads a Boolean value from the stream buffer.
		@return The next Boolean value in the buffered stream.
	**/
	public function readBoolean():Bool {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readBoolean();
	}

	/**
		Reads a signed byte from the stream buffer.
		@return The next signed byte value.
	**/
	public function readByte():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readByte();
	}

	/**
		Reads bytes from the stream buffer into another `ByteArray`.
		@param bytes The destination byte array.
		@param offset The zero-based offset into `bytes` where the copied data should begin.
		@param length The number of bytes to read. Use `0` to read all available buffered bytes.
	**/
	public function readBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__input.readBytes(bytes, offset, length);
	}

	/**
		Reads a double-precision floating-point value from the stream buffer.
		@return The next IEEE 754 double-precision value.
	**/
	public function readDouble():Float {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readDouble();
	}

	/**
		Reads a single-precision floating-point value from the stream buffer.
		@return The next IEEE 754 single-precision value.
	**/
	public function readFloat():Float {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readFloat();
	}

	/**
		Reads a signed 32-bit integer from the stream buffer.
		@return The next signed integer value.
	**/
	public function readInt():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readInt();
	}

	/**
		Reads a multibyte string from the stream buffer using the specified character set.
		@param length The number of bytes to consume from the stream buffer.
		@param charSet The character set to use when decoding the bytes.
		@return The decoded string.
	**/
	public function readMultiByte(length:UInt, charSet:String):String {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readMultiByte(length, charSet);
	}

	/**
		Reads a serialized object from the stream buffer.
		Only `ObjectEncoding.HXSF` is currently supported.
		@return The decoded object, or `null` for unsupported object encodings.
	**/
	public function readObject():Dynamic {
		__requireStreamMode();
		__requireOpenConnection();

		if (objectEncoding == HXSF) {
			return Unserializer.run(readUTF());
		}

		return null;
	}

	/**
		Reads a signed 16-bit integer from the stream buffer.
		@return The next signed short value.
	**/
	public function readShort():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readShort();
	}

	/**
		Reads an unsigned byte from the stream buffer.
		@return The next unsigned byte value.
	**/
	public function readUnsignedByte():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readUnsignedByte();
	}

	/**
		Reads an unsigned 32-bit integer from the stream buffer.
		@return The next unsigned integer value.
	**/
	public function readUnsignedInt():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readUnsignedInt();
	}

	/**
		Reads an unsigned 16-bit integer from the stream buffer.
		@return The next unsigned short value.
	**/
	public function readUnsignedShort():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readUnsignedShort();
	}

	/**
		Reads a UTF-8 string prefixed by its 16-bit byte length.
		@return The decoded UTF-8 string.
	**/
	public function readUTF():String {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readUTF();
	}

	/**
		Reads a fixed number of UTF-8 bytes from the stream buffer.
		@param length The number of UTF-8 bytes to consume.
		@return The decoded UTF-8 string.
	**/
	public function readUTFBytes(length:Int):String {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readUTFBytes(length);
	}

	/**
		Sends one message while in `DATAGRAM` mode, delivered as `delivery`
		says; see `DeliveryMode`.

		The peer receives it as one `DatagramSocketDataEvent.DATA` holding
		exactly these bytes. A `RELIABLE` message of any size is split into
		frames and put back together before it is delivered; an unreliable or
		sequenced one must fit one frame.

		@param bytes The payload bytes to send.
		@param offset The zero-based offset into `bytes` at which the payload begins.
		@param length The number of bytes to send. Use `0` to send all remaining bytes from `offset`.
		@param delivery `RELIABLE` unless given.
		@throws IllegalOperationError If the socket is not in `DATAGRAM` mode.
		@throws IOError If the reliable session is not connected.
		@throws RangeError If `offset` or `length` are out of bounds, or an
		        unreliable or sequenced message is larger than
		        `ReliableDatagramProtocol.MAX_PAYLOAD_SIZE`.
	**/
	public function send(bytes:ByteArray, offset:Int = 0, length:Int = 0, delivery:DeliveryMode = RELIABLE):Void {
		__requireDatagramMode();
		__requireOpenConnection();
		if (delivery == RELIABLE) {
			__queueBytes(bytes, offset, length);
		} else {
			__sendUnreliable(bytes, offset, length, delivery);
		}
	}

	/**
		Appends a Boolean value to the stream-mode output buffer.
		@param value The Boolean value to queue for sending.
	**/
	public function writeBoolean(value:Bool):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeBoolean(value);
	}

	/**
		Appends a byte value to the stream-mode output buffer.
		@param value The byte value to queue for sending.
	**/
	public function writeByte(value:Int):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeByte(value);
	}

	/**
		Appends bytes to the stream-mode output buffer.
		Call `flush()` to segment and send the queued bytes.
		@param bytes The source bytes to append.
		@param offset The zero-based offset into `bytes` at which reading should begin.
		@param length The number of bytes to append. Use `0` to append all remaining bytes from `offset`.
	**/
	public function writeBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeBytes(bytes, offset, length);
	}

	/**
		Appends a double-precision floating-point value to the stream-mode output buffer.
		@param value The value to queue for sending.
	**/
	public function writeDouble(value:Float):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeDouble(value);
	}

	/**
		Appends a single-precision floating-point value to the stream-mode output buffer.
		@param value The value to queue for sending.
	**/
	public function writeFloat(value:Float):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeFloat(value);
	}

	/**
		Appends a signed 32-bit integer to the stream-mode output buffer.
		@param value The value to queue for sending.
	**/
	public function writeInt(value:Int):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeInt(value);
	}

	/**
		Appends a multibyte string to the stream-mode output buffer using the specified character set.
		@param value The string to queue for sending.
		@param charSet The character set to use when encoding the string.
	**/
	public function writeMultiByte(value:String, charSet:String):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeMultiByte(value, charSet);
	}

	/**
		Serializes and appends an object to the stream-mode output buffer.
		Only `ObjectEncoding.HXSF` is currently supported.
		@param object The object to serialize and queue for sending.
	**/
	public function writeObject(object:Dynamic):Void {
		__requireStreamMode();
		__requireOpenConnection();

		if (objectEncoding == HXSF) {
			__output.writeUTF(Serializer.run(object));
		}
	}

	/**
		Appends a signed 16-bit integer to the stream-mode output buffer.
		@param value The value to queue for sending.
	**/
	public function writeShort(value:Int):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeShort(value);
	}

	/**
		Appends an unsigned 32-bit integer to the stream-mode output buffer.
		@param value The value to queue for sending.
	**/
	public function writeUnsignedInt(value:Int):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeUnsignedInt(value);
	}

	/**
		Appends a UTF-8 string prefixed with a 16-bit byte length to the stream-mode output buffer.
		@param value The string to queue for sending.
	**/
	public function writeUTF(value:String):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeUTF(value);
	}

	/**
		Appends a raw UTF-8 string to the stream-mode output buffer without a length prefix.
		@param value The string to queue for sending.
	**/
	public function writeUTFBytes(value:String):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeUTFBytes(value);
	}

	@:noCompletion private static function __createAccepted(
		transport:DatagramSocket,
		remoteAddress:String,
		remotePort:Int,
		server:ReliableDatagramServerSocket,
		mode:ReliableDatagramSocketMode,
		payload:ByteArray
	):ReliableDatagramSocket {
		var socket = new ReliableDatagramSocket();
		var temporaryTransport = socket.__transport;
		socket.__teardownTransportListener();
		if (temporaryTransport != null) {
			temporaryTransport.close();
		}
		socket.__ownsTransport = false;
		socket.__incoming = true;
		socket.connectPayload = payload;
		socket.__mode = mode;
		socket.__server = server;
		socket.__transport = transport;
		socket.__remoteAddress = remoteAddress;
		socket.__remotePort = remotePort;
		socket.__remoteResponsePort = 0;
		socket.__resetSequences();
		socket.__beginHandshake();
		return socket;
	}

	/**
	 * A session this side initiates, over a transport somebody else owns.
	 *
	 * The mirror of `__createAccepted`, and it exists because dialling out from
	 * a socket that is already bound and listening is not a thing a caller can
	 * assemble from the public API -- `connect()` always makes its own
	 * transport. A peer-to-peer mesh needs exactly that, because hole punching
	 * only works when the port a peer dials out from is the port it is
	 * reachable on, and that is one socket.
	 *
	 * `server` is kept rather than nulled, which is the difference that matters.
	 * The server's data pump routes frames to the session registered for their
	 * source endpoint, so a dialled session that is registered gets its replies
	 * through one listener and one owner. Attaching a second listener to the
	 * shared transport instead -- which is what assembling this from outside
	 * forces -- leaves both the server and the session reading the same socket,
	 * and leaves the server free to accept a duplicate session for an endpoint
	 * the dialled one already holds.
	 */
	@:noCompletion private static function __createDialed(transport:DatagramSocket, remoteAddress:String, remotePort:Int,
			server:ReliableDatagramServerSocket, mode:ReliableDatagramSocketMode, timeoutMs:Int, payload:ByteArray):ReliableDatagramSocket {
		var socket = new ReliableDatagramSocket();
		var temporaryTransport = socket.__transport;
		socket.__teardownTransportListener();

		if (temporaryTransport != null) {
			temporaryTransport.close();
		}

		// Set before the handshake begins, or the first retransmission window
		// is measured against the default rather than what the caller asked for.
		if (timeoutMs > 0) {
			socket.timeout = timeoutMs;
		}

		socket.__ownsTransport = false;
		socket.__incoming = false;
		socket.__connectOut = payload;
		socket.__mode = mode;
		socket.__server = server;
		socket.__transport = transport;
		socket.__remoteAddress = remoteAddress;
		socket.__remotePort = remotePort;
		socket.__remoteResponsePort = 0;
		socket.__resetSequences();
		socket.__beginHandshake();
		return socket;
	}

	@:noCompletion private function __acceptFrame(frame:ReliableDatagramFrame):Void {
		if (__closed || frame == null) {
			return;
		}

		__alive = true;
		if (frame.ack != null) {
			__acceptAck(frame.ack);
		}

		switch (frame.type) {
			case CONNECT:
				// Answered whichever side dialled, which is what makes hole
				// punching possible. The guard here was `__incoming`, on the
				// reading that only an accepted session answers a CONNECT --
				// true of a client and a server, and false of two peers behind
				// NAT. Those must dial each other at the same moment, because
				// each side's outbound datagram is what opens its own mapping
				// for the other; so both are outgoing, both sent CONNECT, and
				// neither would answer. Both sessions then sat retransmitting
				// until they timed out, which is a peer-to-peer connection
				// failing for no reason the peers could see.
				//
				// HANDSHAKE is the same frame an accepted session replies with,
				// so the client-and-server case is unchanged: it took this
				// branch before and takes it now.
				if (!__connected) {
					__sendControl(HANDSHAKE, __outSequence);
				}
				// The first one a dialled peer sends, kept as the server keeps
				// an accepted session's. Held only at a size the protocol can
				// send, as the server holds it.
				if (connectPayload == null && frame.payload.length <= ReliableDatagramProtocol.MAX_PAYLOAD_SIZE) {
					connectPayload = frame.payload;
				}
			case HANDSHAKE:
				__onHandshake(frame.sequence);
			case PACKET:
				__acceptPacket(frame.sequence, frame.payload, frame.more);
			case ACK:
				__acceptAck(frame.sequence);
			case FIN:
				__dispose(true);
			case UNRELIABLE:
				__acceptUnreliable(frame.payload);
			case SEQUENCED:
				__acceptSequenced(frame.sequence, frame.payload);
		}
	}

	/**
		An unreliable message, delivered as it arrives. Only on an established
		datagram session: before the handshake there is no session for it to
		belong to, and a stream has no message boundaries to give it.
	**/
	@:noCompletion private function __acceptUnreliable(payload:ByteArray):Void {
		if (!__connected || __mode != DATAGRAM) {
			return;
		}
		__dispatchPayload(payload);
	}

	/**
		A sequenced message, delivered only if it is newer than the last one
		delivered on its channel. An older one arriving late is dropped, and so
		is a duplicate, which is the same counter arriving twice.
	**/
	@:noCompletion private function __acceptSequenced(field:Seq32, payload:ByteArray):Void {
		if (!__connected || __mode != DATAGRAM) {
			return;
		}

		if (__sequencedIn == null) {
			__sequencedIn = __filled(DeliveryMode.CHANNELS, -1);
		}

		var channel:Int = ReliableDatagramProtocol.channelOf(field);
		var counter:Int = ReliableDatagramProtocol.counterOf(field);
		var newest:Int = __sequencedIn[channel];
		if (newest != -1 && !ReliableDatagramProtocol.counterIsNewer(counter, newest)) {
			return;
		}

		__sequencedIn[channel] = counter;
		__dispatchPayload(payload);
	}

	/**
		One in-order reliable frame. In a stream it is bytes; in datagram mode
		it is a message, or part of one when `more` says another follows.

		A message of one frame -- nearly every message -- is delivered as it
		came, with no copy. Fragments are held until the last and joined once.
	**/
	@:noCompletion private function __deliverReliable(payload:ByteArray, more:Bool):Void {
		if (__mode == STREAM) {
			__dispatchPayload(payload);
			return;
		}

		var limit:Int = maxMessageSize;
		if (limit > 0 && payload.length > limit - __fragmentBytes) {
			var message:String = 'A reliable message from the peer passed the $limit byte maxMessageSize before it ended; '
				+ 'the session was closed rather than hold more of it.';
			__fragments.resize(0);
			__fragmentBytes = 0;
			if (hasEventListener(IOErrorEvent.IO_ERROR)) {
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
			}
			close();
			return;
		}

		if (__fragments.length == 0 && !more) {
			__dispatchPayload(payload);
			return;
		}

		__fragments.push(payload);
		__fragmentBytes += payload.length;
		if (more) {
			return;
		}

		var whole:ByteArray = new ByteArray();
		whole.length = __fragmentBytes;
		var at:Int = 0;
		for (fragment in __fragments) {
			(whole : haxe.io.Bytes).blit(at, fragment, 0, fragment.length);
			at += fragment.length;
		}
		__fragments.resize(0);
		__fragmentBytes = 0;
		__dispatchPayload(whole);
	}

	@:noCompletion private static function __filled(size:Int, value:Int):Vector<Int> {
		var vector = new Vector<Int>(size);
		for (i in 0...size) {
			vector[i] = value;
		}
		return vector;
	}

	@:noCompletion private function __acceptAck(ackValue:Seq32):Void {
		if (ackValue <= __windowBase || __outSequence < ackValue) {
			return;
		}

		// Walked from the old acknowledgement point to the new one rather
		// than by asking every outstanding frame whether it is covered: the
		// acknowledgement is cumulative, so the frames it releases are the
		// run between the two, and that is the number of frames released
		// rather than the number still in flight.
		var now:Float = __clock();
		var sequence:Seq32 = __windowBase;

		while (sequence < ackValue) {
			var frame:Null<OutstandingFrame> = __outFrameCache.get(sequence);

			if (frame != null) {
				// Karn's algorithm: a frame that was sent more than once
				// cannot say which copy this acknowledges, so it is not a
				// round trip measurement.
				if (frame.attempts == 1) {
					__sampleRoundTrip(now - frame.sentAt);
				}

				__outFrameCache.remove(sequence);
				__openWindow();
			}

			sequence++;
		}

		__windowBase = ackValue;
		__drainQueue();
	}

	/**
		Folds one round trip measurement into the retransmission timeout.

		RFC 6298 section 2, and the reason a fixed three seconds was wrong in
		both directions: on a local path it made a lost frame wait three
		seconds for no reason, and on a path slower than that it declared loss
		that had not happened and sent the frame again, which is how a
		congested link is made worse.
	**/
	@:noCompletion private function __sampleRoundTrip(sample:Float):Void {
		if (sample <= 0) {
			return;
		}

		if (__smoothedRtt < 0) {
			__smoothedRtt = sample;
			__rttVariation = sample / 2;
		} else {
			var difference:Float = __smoothedRtt - sample;

			if (difference < 0) {
				difference = -difference;
			}

			__rttVariation = 0.75 * __rttVariation + 0.25 * difference;
			__smoothedRtt = 0.875 * __smoothedRtt + 0.125 * sample;
		}

		__setRto(__smoothedRtt + 4 * __rttVariation);
	}

	@:noCompletion private function __setRto(value:Float):Void {
		__rto = value < MIN_RTO ? MIN_RTO : (value > MAX_RTO ? MAX_RTO : value);
	}

	/**
		Opens the window by one acknowledged frame.

		Doubling per round trip while below the threshold, and one frame per
		round trip above it, which is the additive-increase half of what
		everything else on the wire does.
	**/
	@:noCompletion private function __openWindow():Void {
		if (__congestionWindow < __slowStartThreshold) {
			__congestionWindow += 1;
		} else {
			__congestionWindow += 1 / __congestionWindow;
		}

		if (__congestionWindow > DELIVERY_WINDOW) {
			__congestionWindow = DELIVERY_WINDOW;
		}
	}

	/**
		Halves the window, because something was not delivered.

		Multiplicative decrease, and the timeout doubles with it: a path that
		just failed to deliver is not one to try again on the same schedule.
	**/
	@:noCompletion private function __closeWindow():Void {
		__slowStartThreshold = __congestionWindow / 2;

		if (__slowStartThreshold < MIN_WINDOW) {
			__slowStartThreshold = MIN_WINDOW;
		}

		__congestionWindow = __slowStartThreshold;
		__setRto(__rto * 2);
	}

	@:noCompletion private function __acceptPacket(sequence:Seq32, payload:ByteArray, more:Bool = false):Void {
		if (sequence == __inSequence) {
			__inSequence++;
			__deliverReliable(payload, more);
			__drainBufferedPackets();
		} else if (__shouldBufferPacket(sequence)) {
			__cacheFrame(sequence, payload, more);
		}

		// A handler may have closed the session, or a message too large may
		// have; there is then nobody to acknowledge to, and the send would
		// fail and report an error about a socket the caller closed itself.
		if (!__closed) {
			__sendAck();
		}
	}

	@:noCompletion private function __shouldBufferPacket(sequence:Seq32):Bool {
		// Only buffer sequences that are strictly ahead of the next expected one
		// and that fall inside the delivery window. RFC-1982 wrapping comparison
		// is provided by the Seq32 ordering operators, so this stays correct at
		// the 32-bit wrap boundary.
		if (!(__inSequence < sequence) || sequence > __windowCeiling()) {
			return false;
		}

		if (__inFrameCache.exists(sequence)) {
			return false;
		}

		// Cap the out-of-order cache so a flood of high sequences cannot grow it
		// without bound. The window itself bounds the live range; this guards the
		// number of distinct buffered frames within that range.
		return __inFrameCacheCount() < DELIVERY_WINDOW;
	}

	@:noCompletion private inline function __windowCeiling():Seq32 {
		return __inSequence + DELIVERY_WINDOW;
	}

	// Every insert into the out-of-order cache runs through here, and every
	// removal decrements alongside the `remove`, so `__inFrameCacheSize` tracks
	// the map exactly. The count used to be recovered by walking `keys()`, which
	// cost an O(n) iteration plus an iterator allocation for every buffered
	// datagram.
	@:noCompletion private function __cacheFrame(sequence:Seq32, payload:ByteArray, more:Bool = false):Void {
		if (!__inFrameCache.exists(sequence)) {
			__inFrameCacheSize++;
		}

		__inFrameCache.set(sequence, new ReliableDatagramFrame(PACKET, sequence, payload, false, null, more));
	}

	@:noCompletion private inline function __inFrameCacheCount():Int {
		return __inFrameCacheSize;
	}

	@:noCompletion private function __beginHandshake():Void {
		__clearHandshakeTimers();
		__connectionTimeoutHandle = CBTimer.setTimeout(__timeout / 1000, __onConnectionFailed);

		// Only a session that dialled repeats itself. An accepted one is
		// answering a CONNECT it never asked for, from an address UDP let
		// the sender simply claim -- so retransmitting turned one spoofed
		// datagram into a handful aimed at whoever owns that address, this
		// socket paying the postage. Answering once costs the same as the
		// packet that arrived.
		//
		// Nothing is lost by waiting: the dialling side retransmits its own
		// CONNECT on this interval until it gives up, and an unconnected
		// session answers every one of them with a fresh HANDSHAKE. A lost
		// answer is recovered by the next attempt either way.
		if (!__incoming) {
			__connectionAttemptHandle = CBTimer.setInterval(CONNECTION_ATTEMPT_INTERVAL, CONNECTION_ATTEMPT_INTERVAL, __sendHandshakeAttempt);
		}

		__sendHandshakeAttempt();
	}

	@:noCompletion private function __clearHandshakeTimers():Void {
		if (__connectionAttemptHandle != -1) {
			CBTimer.clear(__connectionAttemptHandle);
			__connectionAttemptHandle = -1;
		}

		if (__connectionTimeoutHandle != -1) {
			CBTimer.clear(__connectionTimeoutHandle);
			__connectionTimeoutHandle = -1;
		}
	}

	@:noCompletion private static function __copyRange(bytes:ByteArray, offset:Int, length:Int):ByteArray {
		var copy:ByteArray = new ByteArray();
		copy.writeBytes(bytes, offset, length);
		copy.position = 0;
		return copy;
	}

	@:noCompletion private function __appendStreamPayload(payload:ByteArray):Void {
		var nextInput:ByteArray = __createBuffer();
		var remaining:UInt = __input.bytesAvailable;
		if (remaining > 0) {
			nextInput.writeBytes(__input, __input.position, remaining);
		}
		nextInput.writeBytes(payload, 0, payload.length);
		nextInput.position = 0;
		__input = nextInput;
		dispatchEvent(new ProgressEvent(ProgressEvent.SOCKET_DATA, payload.length, 0));
	}

	@:noCompletion private function __createBuffer():ByteArray {
		var buffer = new ByteArray();
		buffer.endian = __endian;
		buffer.objectEncoding = objectEncoding;
		return buffer;
	}

	@:noCompletion private function __dispatchPayload(payload:ByteArray):Void {
		payload.position = 0;
		payload.endian = __endian;
		payload.objectEncoding = objectEncoding;

		if (__mode == STREAM) {
			__appendStreamPayload(payload);
			return;
		}

		dispatchEvent(new DatagramSocketDataEvent(
			DatagramSocketDataEvent.DATA,
			__remoteAddress,
			__remotePort,
			localAddress,
			localPort,
			payload
		));
	}

	@:noCompletion private function __dispatchTimeoutError():Void {
		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "Remote connection attempt has timed out and the connection could not be completed"));
	}

	@:noCompletion private function __dispose(dispatchClose:Bool):Void {
		if (__closed) {
			return;
		}

		__closed = true;
		__clearHandshakeTimers();
		if (__keepAliveHandle != -1) {
			CBTimer.clear(__keepAliveHandle);
			__keepAliveHandle = -1;
		}

		__stopRetransmitClock();

		__outFrameCache = new IntMap();
		__inFrameCache = new IntMap();
		__inFrameCacheSize = 0;
		__fragments.resize(0);
		__fragmentBytes = 0;
		__sequencedIn = null;
		__sequencedOut = null;
		__outgoingQueue.resize(0);
		__queueAt = 0;
		__queuedBytes = 0;
		__congestionWindow = INITIAL_WINDOW;
		__slowStartThreshold = DELIVERY_WINDOW;
		__smoothedRtt = -1;
		__rttVariation = 0;
		__rto = INITIAL_RTO;
		__input = __createBuffer();
		__output = __createBuffer();

		var wasConnected:Bool = __connected;
		__connected = false;

		if (__server != null) {
			__server.__onSocketClosed(this);
		}

		if (__ownsTransport && __transport != null) {
			__teardownTransportListener();
			__transport.close();
		}

		if (dispatchClose && (wasConnected || __remoteAddress != "")) {
			dispatchEvent(new Event(Event.CLOSE));
		}
	}

	@:noCompletion private function __drainBufferedPackets():Void {
		while (!__closed && __inFrameCache.exists(__inSequence)) {
			var frame:ReliableDatagramFrame = __inFrameCache.get(__inSequence);
			__inFrameCache.remove(__inSequence);
			__inFrameCacheSize--;
			__inSequence++;
			__deliverReliable(frame.payload, frame.more);
		}
	}

	@:noCompletion private function __drainQueue():Void {
		// A cursor rather than taking the front off, which moves everything
		// still queued for each packet that leaves.
		while (__queueAt < __outgoingQueue.length && !__windowExceeded()) {
			var frame:OutstandingFrame = __outgoingQueue[__queueAt];
			__outgoingQueue[__queueAt] = null;
			__queueAt++;
			__queuedBytes -= frame.payload.length;
			__sendPacket(frame);
		}

		if (__queueAt >= __outgoingQueue.length) {
			__outgoingQueue.resize(0);
			__queueAt = 0;
			__queuedBytes = 0;
		} else if (__queueAt > 64 && __queueAt * 2 >= __outgoingQueue.length) {
			__outgoingQueue = __outgoingQueue.slice(__queueAt);
			__queueAt = 0;
		}
	}

	@:noCompletion private inline function __onConnectionFailed():Void {
		if (__connected) {
			return;
		}

		__dispatchTimeoutError();
		__dispose(true);
	}

	@:noCompletion private function __onHandshake(sequence:Seq32):Void {
		__inSequence = sequence;

		if (!__incoming) {
			__sendControl(HANDSHAKE, __outSequence);
		}

		if (__connected) {
			return;
		}

		__connected = true;
		__alive = true;
		__clearHandshakeTimers();
		__keepAliveHandle = CBTimer.setInterval(KEEP_ALIVE_INTERVAL, KEEP_ALIVE_INTERVAL, __onKeepAlive);
		dispatchEvent(new Event(Event.CONNECT));

		if (__server != null) {
			__server.__onSocketConnected(this);
		}
	}

	@:noCompletion private function __onKeepAlive():Void {
		if (!__alive) {
			__dispose(true);
			return;
		}

		__alive = false;
	}

	@:noCompletion private function __prepareTransportListener():Void {
		if (__transportListenerReady) {
			return;
		}

		__transport.addEventListener(DatagramSocketDataEvent.DATA, __onTransportData);
		__transportListenerReady = true;
	}

	@:noCompletion private function __queueBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
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

		// Every frame but the last says more follows, which is how the receiver
		// knows where the message ends and hands it over in one piece.
		var cursor:Int = offset;
		var remaining:Int = length;
		while (remaining > 0) {
			var chunkLength:Int = remaining > ReliableDatagramProtocol.MAX_PAYLOAD_SIZE ? ReliableDatagramProtocol.MAX_PAYLOAD_SIZE : remaining;
			remaining -= chunkLength;
			__queuePacket(__copyRange(bytes, cursor, chunkLength), remaining > 0);
			cursor += chunkLength;
		}
	}

	@:noCompletion private function __queuePacket(payload:ByteArray, more:Bool = false):Void {
		var frame = new OutstandingFrame(payload, 0, 0, more);
		if (__windowExceeded()) {
			__outgoingQueue.push(frame);
			__queuedBytes += payload.length;
			__enforceOutputLimit();
			return;
		}

		__sendPacket(frame);
	}

	/**
		An unreliable or sequenced message: one frame, straight onto the wire
		from the caller's own bytes -- nothing is kept, so nothing is copied.
	**/
	@:noCompletion private function __sendUnreliable(bytes:ByteArray, offset:Int, length:Int, delivery:DeliveryMode):Void {
		var totalLength:Int = bytes.length;
		if (offset < 0 || offset > totalLength) {
			throw new RangeError("The supplied index is out of bounds.");
		}
		if (length == 0) {
			length = totalLength - offset;
		}
		if (length < 0 || length > totalLength - offset) {
			throw new RangeError("The supplied index is out of bounds.");
		}
		if (length > ReliableDatagramProtocol.MAX_PAYLOAD_SIZE) {
			throw new RangeError('An unreliable message must fit one frame, ${ReliableDatagramProtocol.MAX_PAYLOAD_SIZE} bytes, and this one is $length; '
				+ 'split it, or send it RELIABLE.');
		}

		if (!delivery.isSequenced) {
			__sendFrame(UNRELIABLE, 0, bytes, offset, length, false, null, false);
			return;
		}

		if (__sequencedOut == null) {
			__sequencedOut = __filled(DeliveryMode.CHANNELS, 0);
		}
		var channel:Int = delivery.channel;
		var counter:Int = __sequencedOut[channel];
		__sequencedOut[channel] = (counter + 1) & ReliableDatagramProtocol.SEQUENCED_COUNTER_MASK;
		__sendFrame(SEQUENCED, ReliableDatagramProtocol.sequencedField(channel, counter), bytes, offset, length, false, null, false);
	}

	/**
		Applies `maxOutputBufferSize` to what is waiting for the window.

		Flow control means a write is not necessarily a send: it waits for
		room, and what waits is held. Before the window was allowed to close
		this queue could not grow, because the window never closed; now that
		it does, an application producing faster than the path will carry has
		to be told rather than have the queue grow until the process dies.
		Same bound and same two policies as `Socket`, for the same reason.
	**/
	@:noCompletion private function __enforceOutputLimit():Void {
		var limit:Int = maxOutputBufferSize;

		if (limit <= 0 || __queuedBytes <= limit) {
			return;
		}

		var message:String = 'Reliable datagram output queue reached ${__queuedBytes} bytes, exceeding the $limit byte limit; '
			+ 'the path to the peer is not carrying data as fast as it is being written.';

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

	@:noCompletion private inline function __requireDatagramMode():Void {
		if (__mode != DATAGRAM) {
			throw new IllegalOperationError("Cannot use datagram send while the socket is in stream mode.");
		}
	}

	@:noCompletion private inline function __requireOpenConnection():Void {
		if (__closed || !__connected || __transport == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}
	}

	@:noCompletion private inline function __requireStreamMode():Void {
		if (__mode != STREAM) {
			throw new IllegalOperationError("Cannot use stream I/O while the socket is in datagram mode.");
		}
	}

	@:noCompletion private function __resetSequences():Void {
		var seed:Seq32 = __randomSequenceSeed();
		__outSequence = seed;
		__windowBase = seed;
		__inSequence = 0;
	}

	@:noCompletion private function __randomSequenceSeed():Seq32 {
		try {
			var bytes:ByteArray = SecureRandom.getSecureRandomBytes(4);
			bytes.position = 0;
			var b0:Int = bytes.readUnsignedByte();
			var b1:Int = bytes.readUnsignedByte();
			var b2:Int = bytes.readUnsignedByte();
			var b3:Int = bytes.readUnsignedByte();
			return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
		} catch (_:Dynamic) {
			// Targets without a CSPRNG (e.g. eval) fall back to a full 32-bit
			// seed assembled from two non-cryptographic draws.
			var hi:Int = Std.random(0x10000);
			var lo:Int = Std.random(0x10000);
			return (hi << 16) | lo;
		}
	}

	@:noCompletion private function __sendControl(type:ReliableDatagramFrameType, ?sequence:Seq32):Void {
		if (__remoteAddress == "" || __remotePort == 0 || __transport == null) {
			return;
		}

		var controlSequence:Seq32 = sequence == null ? 0 : sequence;
		var ack:Null<Seq32> = switch (type) {
			case ACK, CONNECT:
				null;
			default:
				__currentAck();
		}
		__sendFrame(type, controlSequence, null, 0, 0, false, ack, false);
	}

	@:noCompletion private function __sendHandshakeAttempt():Void {
		if (__incoming) {
			__sendControl(HANDSHAKE, __outSequence);
			return;
		}
		if (__remoteAddress == "" || __remotePort == 0 || __transport == null) {
			return;
		}
		__sendFrame(CONNECT, 0, __connectOut, 0, __connectOut == null ? 0 : __connectOut.length, false, null, false);
	}

	@:noCompletion private function __sendPacket(frame:OutstandingFrame):Void {
		var sequence:Seq32 = __outSequence;
		var now:Float = __clock();

		frame.sentAt = now;
		frame.deadline = now + __rto;
		frame.attempts = 1;
		__outFrameCache.set(sequence, frame);
		__sendFrame(PACKET, sequence, frame.payload, 0, frame.payload.length, false, __currentAck(), frame.more);
		__outSequence++;
		__armRetransmitClock();
	}

	/** The one timer the session retransmits from, started on demand. **/
	@:noCompletion private function __armRetransmitClock():Void {
		if (__retransmitHandle != -1 || __closed) {
			return;
		}

		__retransmitHandle = CBTimer.setInterval(RETRANSMIT_TICK, RETRANSMIT_TICK, function() {
			__checkRetransmits();
		});
	}

	@:noCompletion private function __stopRetransmitClock():Void {
		if (__retransmitHandle != -1) {
			CBTimer.clear(__retransmitHandle);
			__retransmitHandle = -1;
		}
	}

	/**
		Sends again whatever has waited longer than the timeout allows.

		The oldest frame decides. Acknowledgement is cumulative, so nothing
		behind a missing frame can be released until it arrives, and sending
		the rest again would be spending bandwidth on what the receiver is
		already holding. One frame per timeout, the window halved, the
		timeout doubled -- and the frames behind it go out as the window
		reopens.
	**/
	@:noCompletion private function __checkRetransmits():Void {
		if (__closed || !__connected) {
			return;
		}

		if (!__outFrameCache.keys().hasNext()) {
			__stopRetransmitClock();
			return;
		}

		var now:Float = __clock();
		var overdue:Null<OutstandingFrame> = __overdueFrame(now);

		if (overdue == null) {
			return;
		}

		overdue.attempts++;
		overdue.sentAt = now;
		// Backed off first, so the deadline set below is the new one: RFC
		// 6298 section 5.5 doubles the timeout and then restarts the clock.
		__closeWindow();
		overdue.deadline = now + __rto;
		__sendFrame(PACKET, __windowBase, overdue.payload, 0, overdue.payload.length, true, __currentAck(), overdue.more);
	}

	/**
		The frame whose time is up, or null while none is.

		Only ever the oldest. Acknowledgement is cumulative, so nothing behind
		a missing frame can be released until it arrives, and sending the rest
		again would spend bandwidth on what the receiver is already holding.
	**/
	@:noCompletion private function __overdueFrame(now:Float):Null<OutstandingFrame> {
		var oldest:Null<OutstandingFrame> = __outFrameCache.get(__windowBase);

		if (oldest == null || now < oldest.deadline) {
			return null;
		}

		return oldest;
	}

	@:noCompletion private inline function __clock():Float {
		return haxe.Timer.stamp();
	}

	@:noCompletion private inline function __sendAck():Void {
		__sendFrame(ACK, __inSequence, null, 0, 0, false, null, false);
	}

	/** Writes a frame into the scratch buffer and sends it from there. **/
	@:noCompletion private function __sendFrame(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, offset:Int, length:Int, resend:Bool,
			ack:Null<Seq32>, more:Bool):Void {
		var written:Int = ReliableDatagramProtocol.encodeInto(__scratch, type, sequence, payload, offset, length, resend, ack, more);
		try {
			__transport.send(__scratch, 0, written, __remoteAddress, __remotePort);
		} catch (e:Dynamic) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, Std.string(e)));
			__dispose(true);
		}
	}

	@:noCompletion private inline function __currentAck():Null<Seq32> {
		return __connected ? __inSequence : null;
	}

	@:noCompletion private function __teardownTransportListener():Void {
		if (!__transportListenerReady || __transport == null) {
			return;
		}

		__transport.removeEventListener(DatagramSocketDataEvent.DATA, __onTransportData);
		__transportListenerReady = false;
	}

	@:noCompletion private function __windowExceeded():Bool {
		return (__outSequence - __windowBase) >= Std.int(__congestionWindow);
	}

	@:noCompletion private function __onTransportData(e:DatagramSocketDataEvent):Void {
		var frame = ReliableDatagramProtocol.decode(e.data);
		if (frame == null || !__matchesRemoteEndpoint(e, frame)) {
			return;
		}

		__acceptFrame(frame);
	}

	@:noCompletion private function __matchesRemoteEndpoint(e:DatagramSocketDataEvent, frame:ReliableDatagramFrame):Bool {
		if (e.srcAddress != __remoteAddress) {
			return false;
		}

		if (e.srcPort == __remotePort || (__remoteResponsePort > 0 && e.srcPort == __remoteResponsePort)) {
			return true;
		}

		if (!__incoming && !__connected && frame.type == HANDSHAKE) {
			__remoteResponsePort = e.srcPort;
			return true;
		}

		return false;
	}

	@:noCompletion private inline function get_bound():Bool {
		return __transport != null && __transport.bound;
	}

	@:noCompletion private inline function get_bytesAvailable():UInt {
		return __mode == STREAM ? __input.bytesAvailable : 0;
	}

	@:noCompletion private inline function get_bytesPending():Int {
		return __mode == STREAM ? __output.length : 0;
	}

	@:noCompletion private inline function get_connected():Bool {
		return __connected;
	}

	@:noCompletion private inline function get_endian():Endian {
		return __endian;
	}

	@:noCompletion private inline function get_localAddress():String {
		return __transport != null ? __transport.localAddress : "";
	}

	@:noCompletion private inline function get_localPort():Int {
		return __transport != null ? __transport.localPort : 0;
	}

	@:noCompletion private inline function get_mode():ReliableDatagramSocketMode {
		return __mode;
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

	@:noCompletion private function set_endian(value:Endian):Endian {
		__endian = value;
		__input.endian = value;
		__output.endian = value;
		return value;
	}

	@:noCompletion private function set_mode(value:ReliableDatagramSocketMode):ReliableDatagramSocketMode {
		if (__mode == value) {
			return value;
		}

		if (__connected || __incoming || (__remoteAddress != "" && __remotePort != 0)) {
			throw new IllegalOperationError("Socket mode must be set before connecting or accepting a session.");
		}

		if (__input.bytesAvailable > 0 || __output.length > 0) {
			throw new IllegalOperationError("Cannot change socket mode while stream buffers contain data.");
		}

		__mode = value;
		return value;
	}

	@:noCompletion private function set_timeout(value:Int):Int {
		if (value < 0) {
			throw new RangeError("Invalid socket timeout specified.");
		}

		__timeout = value;
		return value;
	}
}
#end
