package crossbyte.net;

// Not built for the browser: this frames WebSocket over a raw TCP socket, and
// in a browser crossbyte.net.Socket already speaks WebSocket natively, so
// connecting to a ws:// or wss:// URL with it is the browser equivalent. Node
// has no WebSocket of its own, so it frames one here like a native target.
#if !(js && !nodejs)

#if nodejs
import js.node.net.Socket as NodeSocket;
#else
import crossbyte._internal.websocket.FlexSocket;
#end
import crossbyte._internal.websocket.WebSocket as InternalWS;
import crossbyte._internal.websocket.WebsocketEvent;
import crossbyte.core.CrossByte;
import crossbyte.errors.IOError;
import crossbyte.errors.SecurityError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.events.WebSocketCloseEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.io.ByteArray;
import haxe.Serializer;
import haxe.Timer;
import haxe.Unserializer;
import haxe.io.Error;

/**
 * ...
 * @author Christopher Speciale
 */
class WebSocket extends Socket {
	// The server half: `ServerWebSocket` accepts a connection and hands the
	// raw socket here to be framed.
	public static function toWebSocket(socket:#if nodejs NodeSocket #else FlexSocket #end, server:ServerWebSocket):WebSocket {
		var webSocket:WebSocket = new WebSocket();

		// The server first: the session asks it about its upgrade, and the
		// settings below are its.
		webSocket.__server = server;
		webSocket.__cbInstance = CrossByte.current();
		webSocket.__webSocket = crossbyte._internal.websocket.WebSocket.fromAcceptedSocket(socket);
		webSocket.__webSocket.maxOutputBufferSize = webSocket.__maxOutputBufferSize;
		if (server != null) {
			webSocket.__webSocket.pingInterval = server.pingInterval;
			webSocket.__webSocket.idleTimeout = server.idleTimeout;
			// Before the upgrade request can arrive, which is what it answers.
			webSocket.__webSocket.perMessageDeflate = server.perMessageDeflate;
			webSocket.__webSocket.compressionThreshold = server.compressionThreshold;
		}
		webSocket.__init();

		return webSocket;
	}

	private var __webSocket:crossbyte._internal.websocket.WebSocket;
	private var __server:ServerWebSocket;

	/**
		The subprotocols a client asks for, most preferred first. Set before
		`connect()`. The server chooses one of them, or none, and `protocol`
		says which.
	**/
	public var protocols:Array<String> = null;

	/**
		The subprotocol this session speaks, or `null` for none: on a client,
		the one the server chose from `protocols`; on a session a server
		accepted, the one it accepted, see `ServerWebSocket.upgrade`.
	**/
	public var protocol(get, never):Null<String>;

	/**
		The upgrade request a server's session was opened by: its path and
		query, headers, cookies, `Origin` and the subprotocols offered. `null`
		on a client.
	**/
	public var request(get, never):Null<WebSocketRequest>;

	/**
		How often, in seconds, a session that has heard nothing from its peer
		pings it; zero for never. Thirty by default, often enough that a
		proxy between the two does not close the connection as idle, or, on
		a server's sessions, the server's `pingInterval`. Can be changed at any
		time.
	**/
	public var pingInterval(get, set):Float;

	/**
		How long, in seconds, a session hears nothing from its peer, no
		message, no pong, before it takes the peer for gone, dispatching
		`ioError` and then `close` with 1006. Sixty by default, or the server's
		`idleTimeout`; zero for never.

		There was none. A peer that vanished without closing, a phone gone
		out of range, a machine switched off, was held for good, and
		everything written to it piled up.
	**/
	public var idleTimeout(get, set):Float;

	// What a pingInterval or idleTimeout assigned before `connect()` is kept
	// in until there is a session to hand it to.
	@:noCompletion private var __pingInterval:Float = -1;
	@:noCompletion private var __idleTimeout:Float = -1;

	/**
		Whether `connect()` asks the server for permessage-deflate (RFC 7692):
		each message of `compressionThreshold` bytes or more sent compressed,
		and compressed messages accepted. Off by default; read when
		`connect()` is called. The server may decline, and the session then
		goes on without, see `compressed`. A session a `ServerWebSocket`
		accepted takes the server's setting instead.

		Each message is compressed on its own, in both directions: a message
		costs a compressor's setup, and saves most on the larger, repetitive
		ones, an 18 KB JSON snapshot goes as about 3 KB. A server that
		agrees but does not also say `client_no_context_takeover` may inflate
		this side's messages as one stream, which a message compressed on its
		own ends; this side then sends uncompressed, and still inflates what
		the server compresses.
	**/
	public var perMessageDeflate:Bool = false;

	/**
		Messages shorter than this many bytes go uncompressed even where
		compression was agreed: below about a kilobyte the framing costs about
		what it saves. Read when `connect()` is called.
	**/
	public var compressionThreshold:Int = InternalWS.DEFAULT_COMPRESSION_THRESHOLD;

	/**
		Whether this session agreed to permessage-deflate with its peer. False
		until the session opens.
	**/
	public var compressed(get, never):Bool;

	@:noCompletion private function get_compressed():Bool {
		return __webSocket != null && __webSocket.compressed;
	}

	// `verifyCert` and `certAuthority`, which a `wss://` client reads, are
	// Socket's: a secure Socket checks its server the same way.

	/**
		Bytes of unsent frame data allowed to accumulate for this session
		before it is closed with 1011, or `0` for no limit.

		A peer that stops reading, a slept phone, a half-open connection,
		leaves everything sent to it buffered with nothing to reclaim it.
		Frames are never dropped to stay under the limit; the session is
		closed once it is clear the peer is not draining.

		Overrides `Socket.maxOutputBufferSize` to bound the session's frame
		buffer instead of the base socket's. A WebSocket writes through its
		framing layer rather than the inherited output buffer, so a limit
		left on the base would never be reached.
	**/
	@:noCompletion override private function get_maxOutputBufferSize():Int {
		return __webSocket == null ? __maxOutputBufferSize : __webSocket.maxOutputBufferSize;
	}

	@:noCompletion override private function set_maxOutputBufferSize(value:Int):Int {
		// Retained on the base too, so a limit assigned before the session
		// exists is applied once it does.
		__maxOutputBufferSize = value;

		if (__webSocket != null) {
			__webSocket.maxOutputBufferSize = value;
		}

		return value;
	}

	/**
		Bytes of framed data still waiting for the socket to accept them.

		Reports the session's frame buffer rather than the base socket's,
		for the same reason `maxOutputBufferSize` does: a WebSocket writes
		through its framing layer, so the inherited buffer stays empty.
	**/
	@:noCompletion override private function get_outputBufferLength():Int {
		return __webSocket == null ? super.get_outputBufferLength() : __webSocket.outputBufferLength;
	}

	public function new() {
		super();
	}

	override public function close():Void {
		if (__webSocket != null) {
			__cleanSocket();
		} else {
			throw new IOError("Operation attempted on invalid socket.");
		}
	}

	/**
	 * Closes the session with a WebSocket close frame carrying `code` and
	 * `reason`, rather than severing the connection.
	 *
	 * This is what lets the peer distinguish an orderly shutdown from a
	 * network failure and reconnect sensibly. Used by
	 * `ServerWebSocket.drain()`, which sends 1001 ("going away").
	 *
	 * The session stays up for the peer's answer, anything written before
	 * this still goes out first, and closes once that arrives, or after a
	 * few seconds regardless. The `close` event then reports the code and
	 * reason the peer answered with, usually the ones sent, or 1006 if it
	 * never answered.
	 *
	 * This used to send a close frame with nothing in it, so the peer saw
	 * 1005 or 1000 whatever the code, and closed at once, which on a native
	 * target could drop both the frame and whatever was queued before it.
	 *
	 * @param code WebSocket close code: 1000 (normal), 1001 (going away), a
	 *        code 1002-1014 names, or one of the ranges left to libraries,
	 *        3000-3999, and to applications, 4000-4999.
	 * @param reason Optional human-readable reason; at most 123 bytes of it
	 *        are sent.
	 * @throws ArgumentError if `code` is not one that may be sent.
	 */
	public function closeWith(code:Int = 1000, ?reason:String):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (!__isSendableCloseCode(code)) {
			throw new crossbyte.errors.ArgumentError('$code is not a close code that may be sent; use 1000, 1001, 1002-1014 (but 1004-1006), or 3000-4999.');
		}

		__webSocket.close(code, reason);
	}

	/**
		Sends `text` as one text message: a browser receives it as a string.

		Everything written and flushed goes as a binary message, which a
		browser hands its page as a `Blob` or an `ArrayBuffer`, the wrong
		shape for the JSON most pages expect.

		@throws IOError if the session is not open.
	**/
	public function sendText(text:String):Void {
		__requireOpen();
		__webSocket.sendString(text == null ? "" : text);
	}

	/**
		Sends `length` bytes of `bytes` from `offset` as one binary message, at
		once rather than when the socket is next flushed. A `length` of 0 sends
		everything from `offset`.

		@throws IOError if the session is not open.
	**/
	public function sendBinary(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		__requireOpen();

		if (length == 0) {
			length = bytes.length - offset;
		}

		var message:ByteArray = new ByteArray();
		message.writeBytes(bytes, offset, length);
		__webSocket.sendBytes(message);
	}

	/**
		Pings the peer, which answers with a pong; either counts as hearing
		from it. `data`, at most 125 bytes, travels in the ping and back. The
		session does this itself every `pingInterval` when nothing has come in.
	**/
	public function ping(?data:ByteArray):Void {
		__requireOpen();
		__webSocket.ping(data);
	}

	/**
		Sends a pong the peer did not ask for: a heartbeat in one direction,
		which RFC 6455 allows and which is not answered.
	**/
	public function pong(?data:ByteArray):Void {
		__requireOpen();
		__webSocket.pong(data);
	}

	@:noCompletion private function __requireOpen():Void {
		if (__webSocket == null || __webSocket.readyState != InternalWS.OPEN) {
			throw new IOError("The WebSocket session is not open.");
		}
	}

	@:noCompletion private static function __isSendableCloseCode(code:Int):Bool {
		if (code >= 3000 && code <= 4999) {
			return true;
		}
		return code >= 1000 && code <= 1014 && code != 1004 && code != 1005 && code != 1006;
	}

	@:noCompletion private function get_protocol():Null<String> {
		return __webSocket == null ? null : __webSocket.protocol;
	}

	@:noCompletion private function get_request():Null<WebSocketRequest> {
		return __webSocket == null ? null : __webSocket.request;
	}

	@:noCompletion private function get_pingInterval():Float {
		if (__webSocket != null) {
			return __webSocket.pingInterval;
		}
		return __pingInterval >= 0 ? __pingInterval : InternalWS.PING_INTERVAL / 1000;
	}

	@:noCompletion private function set_pingInterval(value:Float):Float {
		__pingInterval = value < 0 ? 0 : value;
		if (__webSocket != null) {
			__webSocket.pingInterval = __pingInterval;
		}
		return __pingInterval;
	}

	@:noCompletion private function get_idleTimeout():Float {
		if (__webSocket != null) {
			return __webSocket.idleTimeout;
		}
		return __idleTimeout >= 0 ? __idleTimeout : InternalWS.DEFAULT_IDLE_TIMEOUT;
	}

	@:noCompletion private function set_idleTimeout(value:Float):Float {
		__idleTimeout = value < 0 ? 0 : value;
		if (__webSocket != null) {
			__webSocket.idleTimeout = __idleTimeout;
		}
		return __idleTimeout;
	}

	override public function connect(host:String, port:Int):Void {
		if (__webSocket != null) {
			close();
		}

		if (port < 0 || port > 65535) {
			throw new SecurityError("Invalid socket port number specified.");
		}

		__timestamp = Timer.stamp();

		__host = host;
		__port = port;
		__connected = false;

		__output = new ByteArray();
		__output.endian = __endian;

		__input = new ByteArray();
		__input.endian = __endian;

		var schema = secure ? "wss" : "ws";
		// An IPv6 literal, bracketed or bare, as well as a name or an IPv4
		// address: the pattern this used took only the last two, and refused
		// `::1` as an invalid host before a socket existed.
		var target = crossbyte._internal.websocket.WebSocketHost.split(__host);
		if (target == null) {
			throw new IOError("Invalid host");
		}
		var __webHost = target.host;
		var __webPath = target.path;

		// The host alone, for remoteAddress: what was passed may carry a path.
		__host = __webHost;
		__cbInstance = CrossByte.current();

		__webSocket = new crossbyte._internal.websocket.WebSocket(schema + "://" + crossbyte._internal.websocket.WebSocketHost.forUrl(__webHost) + ":"
			+ port + "/" + __webPath, protocols, null, verifyCert, certAuthority);
		// `timeout` bounds the connection and the upgrade after it, as it
		// bounds a plain socket's connect. The session used a fixed ten
		// seconds of its own and never waited on the upgrade at all.
		__webSocket.connectTimeout = timeout;
		__webSocket.maxOutputBufferSize = __maxOutputBufferSize;
		// Before the upgrade request goes, which is where it is asked for.
		__webSocket.perMessageDeflate = perMessageDeflate;
		__webSocket.compressionThreshold = compressionThreshold;
		if (__pingInterval >= 0) {
			__webSocket.pingInterval = __pingInterval;
		}
		if (__idleTimeout >= 0) {
			__webSocket.idleTimeout = __idleTimeout;
		}
		__init();
	}

	/**
		Sends what has been written as one binary message.

		Written while the session is still connecting, it waits and goes once
		the session opens, where it threw; see `sendText` for a text message.

		@throws IOError if the session is closing or closed.
	**/
	override public function flush():Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (__output.length > 0) {
			var state:Int = __webSocket.readyState;

			if (state == InternalWS.CONNECTING) {
				// Sent from socket_onOpen.
				return;
			}

			if (state != InternalWS.OPEN) {
				throw new IOError("The WebSocket session is closing; nothing more can be sent.");
			}

			__webSocket.sendBytes(__output);
			__output.clear();
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
	override public function readBoolean():Bool {
		if (__webSocket == null) {
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
	override public function readByte():Int {
		if (__webSocket == null) {
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
	override public function readBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		if (__webSocket == null) {
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
	override public function readDouble():Float {
		if (__webSocket == null) {
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
	override public function readFloat():Float {
		if (__webSocket == null) {
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
	override public function readInt():Int {
		if (__webSocket == null) {
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
	override public function readMultiByte(length:Int, charSet:String):String {
		if (__webSocket == null) {
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
	override public function readObject():Dynamic {
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
	override public function readShort():Int {
		if (__webSocket == null) {
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
	override public function readUnsignedByte():Int {
		if (__webSocket == null) {
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
	override public function readUnsignedInt():Int {
		if (__webSocket == null) {
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
	override public function readUnsignedShort():Int {
		if (__webSocket == null) {
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
	override public function readUTF():String {
		if (__webSocket == null) {
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
	override public function readUTFBytes(length:Int):String {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		return __input.readUTFBytes(length);
	}

	/**
		Writes a Boolean value to the socket. This method writes a single
		byte, with either a value of 1 (`true`) or 0 (`false`).
		@param value The value to write to the socket: 1 (`true`) or 0
					 (`false`).
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	override function writeBoolean(value:Bool):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeBoolean(value);
	}

	/**
		Writes a byte to the socket.
		@param value The value to write to the socket. The low 8 bits of the
					 value are used; the high 24 bits are ignored.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	override public function writeByte(value:Int):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeByte(value);
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
	override public function writeBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeBytes(bytes, offset, length);
	}

	/**
		Writes an IEEE 754 double-precision floating-point number to the
		socket.
		@param value The value to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	override public function writeDouble(value:Float):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeDouble(value);
	}

	/**
		Writes an IEEE 754 single-precision floating-point number to the
		socket.
		@param value The value to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	override public function writeFloat(value:Float):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeFloat(value);
	}

	/**
		Writes a 32-bit signed integer to the socket.
		@param value The value to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	override public function writeInt(value:Int):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeInt(value);
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
	override public function writeMultiByte(value:String, charSet:String):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeUTFBytes(value);
	}

	/**
		Write an object to the socket in AMF serialized format.
		@param object The object to be serialized.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	override public function writeObject(object:Dynamic):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (objectEncoding == HXSF) {
			__output.writeUTF(Serializer.run(object));
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
	override public function writeShort(value:Int):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeShort(value);
	}

	/**
		Writes a 32-bit unsigned integer to the socket.
		@param value The value to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	override public function writeUnsignedInt(value:Int):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeUnsignedInt(value);
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
	override public function writeUTF(value:String):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeUTF(value);
	}

	/**
		Writes a UTF-8 string to the socket.
		@param value The string to write to the socket.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	override public function writeUTFBytes(value:String):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeUTFBytes(value);
	}

	@:noCompletion override private function __cleanSocket():Void {
		// At once, as closing a socket is: a close frame if the socket takes
		// it straight away, and the connection gone. closeWith is the one that
		// waits for the peer.
		try {
			__webSocket.abort(1000);
		} catch (e:Dynamic) {}

		__webSocket = null;
		__connected = false;
	}

	@:noCompletion override private function socket_onClose(event):Void {
		__connected = false;
		__webSocket = null;

		// The session underneath knows why it ended; this used to drop that
		// on the floor and dispatch a bare Event.CLOSE, so an application
		// could not tell a peer disconnecting from a peer being dropped for
		// a protocol violation. Dispatched under the Event.CLOSE type, so
		// listeners that only care *that* it closed are unaffected.
		var code:Int = 0;
		var reason:String = null;

		var closed:WebsocketEvent = Std.downcast(event, WebsocketEvent);
		if (closed != null) {
			code = (closed.code == null) ? 0 : closed.code;
			reason = closed.reason;
		}

		dispatchEvent(new WebSocketCloseEvent(Event.CLOSE, code, reason));
	}

	@:noCompletion override private function socket_onError(e):Void {
		// An IOErrorEvent carrying what went wrong. This dispatched a bare
		// Event of the ioError type, so a listener typed for IOErrorEvent got
		// something else, and a refused certificate or a connect that failed
		// arrived with no account of which it was.
		var text:String = "";
		var failed:WebsocketEvent = Std.downcast(e, WebsocketEvent);
		if (failed != null && failed.data != null) {
			text = Std.string(failed.data);
		}

		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, text));
	}

	@:noCompletion override private function socket_onMessage(msg:Dynamic):Void {
		var message:WebsocketEvent = msg;
		var newData:ByteArray = message.data;

		// One message, whole, to whoever asked for messages, and then not
		// into the stream as well, which nobody would be reading and which
		// would only grow. Every message used to go into the stream, so where
		// one ended and the next began was lost.
		if (hasEventListener(WebSocketMessageEvent.MESSAGE)) {
			newData.position = 0;
			// In this socket's byte order, as its stream is read. The buffer
			// the frame parser filled is big-endian, for the frame's own
			// fields, and a message used to arrive so whatever `endian` said.
			newData.endian = endian;
			dispatchEvent(new WebSocketMessageEvent(WebSocketMessageEvent.MESSAGE, newData, message.isText));
			return;
		}

		// What has been read goes, as on a plain socket, rather than being
		// kept until a reader happens to take everything.
		__compactInput();

		newData.readBytes(__input, __input.length);

		if (__input.bytesAvailable > 0) {
			dispatchEvent(new ProgressEvent(ProgressEvent.SOCKET_DATA, __input.bytesAvailable, 0));
		}
	}

	@:noCompletion override private function socket_onOpen(_):Void {
		__connected = true;
		__closed = false;

		// Both ends, noted while the session can still say: an accepted one
		// reported no address at all.
		if (__webSocket != null) {
			if (__webSocket.remoteAddress != "") {
				__host = __webSocket.remoteAddress;
				__port = __webSocket.remotePort;
			}
			__localHost = __webSocket.localAddress;
			__localPortNumber = __webSocket.localPort;
		}

		// Whatever was written and flushed while connecting goes first, as a
		// message of its own, ahead of anything the handlers below send.
		if (__output != null && __output.length > 0) {
			flush();
		}

		dispatchEvent(new Event(Event.CONNECT));

		// An accepted session tells its server it is ready once the upgrade has
		// completed, rather than when the TCP connection arrived, which is
		// what makes the server's CONNECT mean "ready to send" and not merely
		// "attached".
		if (__server != null) {
			__server.dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, this));
			__server = null;
		}
	}

	private function __init():Void {
		__output = new ByteArray();
		__output.endian = __endian;

		__input = new ByteArray();
		__input.endian = __endian;

		__webSocket.binaryType = "arraybuffer";
		__webSocket.onopen = socket_onOpen;
		__webSocket.onmessage = socket_onMessage;
		__webSocket.onclose = socket_onClose;
		__webSocket.onerror = socket_onError;

		// A server's session asks its server about its upgrade, through
		// the hook as it stands when the request arrives, not as it stood
		// when the connection did.
		if (__server != null) {
			var server:ServerWebSocket = __server;
			__webSocket.onupgrade = function(request:WebSocketRequest):Bool {
				return server.upgrade(request);
			};
		}
	}

	@:noCompletion private var __localHost:String = "";
	@:noCompletion private var __localPortNumber:Int = 0;

	@:noCompletion override private function get_localAddress():String {
		if (__localHost == "" && __webSocket != null) {
			return __webSocket.localAddress;
		}
		return __localHost;
	}

	@:noCompletion override private function get_localPort():Int {
		if (__localPortNumber == 0 && __webSocket != null) {
			return __webSocket.localPort;
		}
		return __localPortNumber;
	}

	@:noCompletion override private function get_remoteAddress():String {
		if ((__host == null || __host == "") && __webSocket != null) {
			return __webSocket.remoteAddress;
		}
		return __host;
	}

	@:noCompletion override private function get_remotePort():Int {
		if (__port == 0 && __webSocket != null) {
			return __webSocket.remotePort;
		}
		return __port;
	}

	@:noCompletion override private inline function get_registryClosed():Bool {
		return __closed || __webSocket == null;
	}
}
#end
