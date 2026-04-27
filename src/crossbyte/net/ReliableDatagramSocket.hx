package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.Timer as CBTimer;
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
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import haxe.Serializer;
import haxe.Unserializer;
import haxe.ds.IntMap;
import sys.net.Host;

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

	@:noCompletion private static inline var CONNECTION_ATTEMPT_INTERVAL:Float = 3.0;
	@:noCompletion private static inline var DELIVERY_WINDOW:Int = 500;
	@:noCompletion private static inline var KEEP_ALIVE_INTERVAL:Float = 75.0;
	@:noCompletion private static inline var RETRANSMIT_INTERVAL:Float = 3.0;

	@:noCompletion private var __alive:Bool = false;
	@:noCompletion private var __closed:Bool = false;
	@:noCompletion private var __connected:Bool = false;
	@:noCompletion private var __connectionAttemptHandle:Int = -1;
	@:noCompletion private var __connectionTimeoutHandle:Int = -1;
	@:noCompletion private var __endian:Endian = Endian.BIG_ENDIAN;
	@:noCompletion private var __inFrameCache:IntMap<ByteArray>;
	@:noCompletion private var __inSequence:Seq32 = 0;
	@:noCompletion private var __incoming:Bool = false;
	@:noCompletion private var __input:ByteArray;
	@:noCompletion private var __keepAliveHandle:Int = -1;
	@:noCompletion private var __mode:ReliableDatagramSocketMode = DATAGRAM;
	@:noCompletion private var __outFrameCache:IntMap<ByteArray>;
	@:noCompletion private var __outFrameTimerCache:IntMap<Int>;
	@:noCompletion private var __outSequence:Seq32 = 0;
	@:noCompletion private var __outgoingQueue:Array<ByteArray>;
	@:noCompletion private var __output:ByteArray;
	@:noCompletion private var __ownsTransport:Bool = true;
	@:noCompletion private var __remoteAddress:String = "";
	@:noCompletion private var __remotePort:Int = 0;
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
		__outFrameCache = new IntMap();
		__outFrameTimerCache = new IntMap();
		__outgoingQueue = [];
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
		@param host The remote host to connect to.
		@param port The remote UDP port to connect to.
		@throws IOError If the socket is closed or otherwise invalid.
		@throws IllegalOperationError If this socket was accepted by a server.
		@throws ArgumentError If `host` is invalid or empty.
		@throws RangeError If `port` is outside the valid UDP port range.
	**/
	public function connect(host:String, port:Int):Void {
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

		if (!bound) {
			__transport.bind();
		}

		var resolved:Host;
		try {
			resolved = new Host(host);
		} catch (_:Dynamic) {
			throw new ArgumentError("One of the parameters is invalid");
		}

		__remoteAddress = resolved.toString();
		__remotePort = port;
		__incoming = false;
		__resetSequences();
		__transport.receive();
		__beginHandshake();
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
		Sends a reliable payload while in `DATAGRAM` mode.
		Larger payloads are segmented internally and reassembled on the remote side as
		ordered reliable messages.
		@param bytes The payload bytes to send.
		@param offset The zero-based offset into `bytes` at which the payload begins.
		@param length The number of bytes to send. Use `0` to send all remaining bytes from `offset`.
		@throws IllegalOperationError If the socket is not in `DATAGRAM` mode.
		@throws IOError If the reliable session is not connected.
		@throws RangeError If `offset` or `length` are out of bounds.
	**/
	public function send(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		__requireDatagramMode();
		__requireOpenConnection();
		__queueBytes(bytes, offset, length);
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
		mode:ReliableDatagramSocketMode
	):ReliableDatagramSocket {
		var socket = new ReliableDatagramSocket();
		var temporaryTransport = socket.__transport;
		socket.__teardownTransportListener();
		if (temporaryTransport != null) {
			temporaryTransport.close();
		}
		socket.__ownsTransport = false;
		socket.__incoming = true;
		socket.__mode = mode;
		socket.__server = server;
		socket.__transport = transport;
		socket.__remoteAddress = remoteAddress;
		socket.__remotePort = remotePort;
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
			case HANDSHAKE:
				__onHandshake(frame.sequence);
			case PACKET:
				__acceptPacket(frame.sequence, frame.payload);
			case ACK:
				__acceptAck(frame.sequence);
			case FIN:
				__dispose(true);
		}
	}

	@:noCompletion private function __acceptAck(ackValue:Seq32):Void {
		if (ackValue <= __windowBase || __outSequence < ackValue) {
			return;
		}

		var released:Array<Int> = [];
		for (sequence in __outFrameCache.keys()) {
			var pending:Seq32 = sequence;
			if (pending < ackValue) {
				released.push(sequence);
			}
		}

		for (sequence in released) {
			__outFrameCache.remove(sequence);
			var timerHandle:Null<Int> = __outFrameTimerCache.get(sequence);
			if (timerHandle != null) {
				CBTimer.clear(timerHandle);
				__outFrameTimerCache.remove(sequence);
			}
		}

		__windowBase = ackValue;
		__drainQueue();
	}

	@:noCompletion private function __acceptPacket(sequence:Seq32, payload:ByteArray):Void {
		if (sequence == __inSequence) {
			__dispatchPayload(payload);
			__inSequence++;
			__drainBufferedPackets();
		} else if (__inSequence < sequence && !__inFrameCache.exists(sequence)) {
			__inFrameCache.set(sequence, payload);
		}

		__sendAck();
	}

	@:noCompletion private function __beginHandshake():Void {
		__clearHandshakeTimers();
		__connectionTimeoutHandle = CBTimer.setTimeout(__timeout / 1000, __onConnectionFailed);
		__connectionAttemptHandle = CBTimer.setInterval(CONNECTION_ATTEMPT_INTERVAL, CONNECTION_ATTEMPT_INTERVAL, __sendHandshakeAttempt);
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

		for (sequence in __outFrameTimerCache.keys()) {
			CBTimer.clear(__outFrameTimerCache.get(sequence));
		}

		__outFrameTimerCache = new IntMap();
		__outFrameCache = new IntMap();
		__inFrameCache = new IntMap();
		__outgoingQueue.resize(0);
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
		while (__inFrameCache.exists(__inSequence)) {
			var payload:ByteArray = __inFrameCache.get(__inSequence);
			__inFrameCache.remove(__inSequence);
			__dispatchPayload(payload);
			__inSequence++;
		}
	}

	@:noCompletion private function __drainQueue():Void {
		while (__outgoingQueue.length > 0 && !__windowExceeded()) {
			__sendPacket(__outgoingQueue.shift());
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

		if (length < 0 || offset + length > totalLength) {
			throw new RangeError("The supplied index is out of bounds.");
		}

		var cursor:Int = offset;
		var remaining:Int = length;
		while (remaining > 0) {
			var chunkLength:Int = remaining > ReliableDatagramProtocol.MAX_PAYLOAD_SIZE ? ReliableDatagramProtocol.MAX_PAYLOAD_SIZE : remaining;
			__queuePacket(__copyRange(bytes, cursor, chunkLength));
			cursor += chunkLength;
			remaining -= chunkLength;
		}
	}

	@:noCompletion private function __queuePacket(payload:ByteArray):Void {
		if (__windowExceeded()) {
			__outgoingQueue.push(payload);
			return;
		}

		__sendPacket(payload);
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

	@:noCompletion private inline function __resetSequences():Void {
		var seed:Seq32 = Std.random(Seq32.MAX_INT_32);
		__outSequence = seed;
		__windowBase = seed;
		__inSequence = 0;
	}

	@:noCompletion private function __retransmitPacket(sequence:Seq32):Void {
		var payload:ByteArray = __outFrameCache.get(sequence);
		if (payload != null) {
			__sendRaw(ReliableDatagramProtocol.encode(PACKET, sequence, payload, true, __currentAck()));
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
		__sendRaw(ReliableDatagramProtocol.encode(type, controlSequence, null, false, ack));
	}

	@:noCompletion private function __sendHandshakeAttempt():Void {
		__sendControl(__incoming ? HANDSHAKE : CONNECT, __incoming ? __outSequence : 0);
	}

	@:noCompletion private function __sendPacket(payload:ByteArray):Void {
		var sequence:Seq32 = __outSequence;
		__outFrameCache.set(sequence, payload);
		__sendRaw(ReliableDatagramProtocol.encode(PACKET, sequence, payload, false, __currentAck()));
		__outFrameTimerCache.set(sequence, CBTimer.setInterval(RETRANSMIT_INTERVAL, RETRANSMIT_INTERVAL, function() {
			__retransmitPacket(sequence);
		}));
		__outSequence++;
	}

	@:noCompletion private inline function __sendAck():Void {
		__sendRaw(ReliableDatagramProtocol.encode(ACK, __inSequence));
	}

	@:noCompletion private inline function __currentAck():Null<Seq32> {
		return __connected ? __inSequence : null;
	}

	@:noCompletion private inline function __sendRaw(frame:ByteArray):Void {
		frame.position = 0;
		try {
			__transport.send(frame, 0, frame.length, __remoteAddress, __remotePort);
		} catch (e:Dynamic) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, Std.string(e)));
			__dispose(true);
		}
	}

	@:noCompletion private function __teardownTransportListener():Void {
		if (!__transportListenerReady || __transport == null) {
			return;
		}

		__transport.removeEventListener(DatagramSocketDataEvent.DATA, __onTransportData);
		__transportListenerReady = false;
	}

	@:noCompletion private function __windowExceeded():Bool {
		return (__outSequence - __windowBase) > DELIVERY_WINDOW;
	}

	@:noCompletion private function __onTransportData(e:DatagramSocketDataEvent):Void {
		if (e.srcAddress != __remoteAddress || e.srcPort != __remotePort) {
			return;
		}

		__acceptFrame(ReliableDatagramProtocol.decode(e.data));
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
