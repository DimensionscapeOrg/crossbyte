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
import crossbyte.net._internal.RuntimeHandOff;
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
import crossbyte.errors.SecurityError;
import crossbyte.events.Event;
import crossbyte.events.EventType;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.OutputProgressEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.events.WebSocketCloseEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.events._internal.Arrivals;
import crossbyte.io.ByteArray;
import haxe.Serializer;
import haxe.Timer;
import haxe.Unserializer;
import haxe.io.Error;

/**
	A WebSocket session (RFC 6455): a client that connects to a `ws://` or
	`wss://` server, or a session a `ServerWebSocket` accepted.

	It is a `Socket`. What is written and then flushed goes as one binary
	message, and what arrives is read as a stream, or, with a listener for
	`WebSocketMessageEvent.MESSAGE`, delivered a whole message at a time.
	`sendText` and `sendBinary` send a message at once.

	Where it differs from a plain socket it follows the browser's WebSocket:

	- A connect that fails, refused, unreachable, a TLS handshake or a
	  certificate refused, an upgrade the server declined or never answered,
	  `timeout` passed, dispatches `ioError` saying why, and then `close`
	  with code 1006. `connect` is never dispatched. A plain `Socket`
	  dispatches `ioError` alone.
	- `close` is a `WebSocketCloseEvent` carrying the code and reason, and is
	  dispatched however the session ends, `close()` included.
	- There is no half-close: a session ends both ways at once, with a close
	  frame. `shutdown()` throws, and `peerShutdownPolicy` is not consulted,
	  a peer that shuts its side ends the session, as 1006.

	@event connect  Dispatched when the session has opened: the upgrade is
	                done, and messages can be sent.
	@event close    Dispatched when the session ends, as a
	                `WebSocketCloseEvent`.
	@event ioError  Dispatched when a connect fails, ahead of `close`; and
	                ahead of `close` when an open session is given up on,
	                its peer silent past `idleTimeout`, say.
	@author Christopher Speciale
**/
class WebSocket extends Socket {
	// The server half: `ServerWebSocket` accepts a connection and hands the
	// raw socket here to be framed. Its own, not the application's: it takes
	// an internal socket type, and a session made here without the server
	// accepting it has no handshake deadline.
	@:noCompletion @:allow(crossbyte.net.ServerWebSocket)
	private static function toWebSocket(socket:#if nodejs NodeSocket #else FlexSocket #end, server:ServerWebSocket):WebSocket {
		var webSocket:WebSocket = new WebSocket();

		// The server first: the session asks it about its upgrade, and the
		// settings below are its. Its runtime too: on Node this is called
		// from the server's connection callback, where `current()` is the
		// application's runtime even for a server a child runtime runs.
		webSocket.__server = server;
		var runtime:Null<CrossByte> = server != null ? @:privateAccess server.__cbInstance : null;
		webSocket.__cbInstance = runtime != null ? runtime : CrossByte.current();
		webSocket.__webSocket = crossbyte._internal.websocket.WebSocket.fromAcceptedSocket(socket, webSocket.__cbInstance);
		// Said, as a socket a secure ServerSocket accepted says it: every
		// session a secure server accepted read false.
		webSocket.secure = server != null ? server.secure : @:privateAccess webSocket.__webSocket.__tls;
		if (server != null) {
			// The server's, from the start: it was applied once the session
			// opened, and only when the server's was not 0.
			webSocket.__maxOutputBufferSize = server.maxOutputBufferSize;
			webSocket.__maxMessageSize = server.maxMessageSize;
			webSocket.__closeTimeout = server.closeTimeout;
		}
		webSocket.__webSocket.maxOutputBufferSize = webSocket.__maxOutputBufferSize;
		webSocket.__webSocket.maxMessageSize = webSocket.__maxMessageSize;
		webSocket.__webSocket.closeTimeout = webSocket.__closeTimeout;
		if (server != null) {
			webSocket.__webSocket.pingInterval = server.pingInterval;
			webSocket.__webSocket.idleTimeout = server.idleTimeout;
			// Before the upgrade request can arrive, which is what it answers.
			webSocket.__webSocket.perMessageDeflate = server.perMessageDeflate;
			webSocket.__webSocket.compressionThreshold = server.compressionThreshold;
			webSocket.__webSocket.maxHeaderSize = server.maxHeaderSize;
		}
		webSocket.__init();

		return webSocket;
	}

	private var __webSocket:crossbyte._internal.websocket.WebSocket;
	// The server that accepted this session, until it opens or ends.
	private var __server:ServerWebSocket;
	// Whether the server's `upgrade` hook turned this session down, which
	// the server does not count as a failed handshake.
	@:noCompletion private var __upgradeRefused:Bool = false;
	// Where the server keeps this session in its list of open ones, or -1
	// while it is in none. See ServerWebSocket.__tracks.
	@:noCompletion private var __serverSlot:Int = -1;
	// The server this session is counted by against its maxConnections,
	// until it closes.
	@:noCompletion private var __countedBy:ServerWebSocket = null;
	// The server that lists this session among its open ones, told as it
	// closes; see ServerWebSocket.__trackClient.
	@:noCompletion private var __trackedBy:ServerWebSocket = null;

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

		Kept as the head it arrived as once the session has opened and its
		`connect` listeners have run: its headers are read from that again
		the first time they are asked for afterwards, and kept from then on.
		The parsed headers were a third of what an idle session held.
	**/
	public var request(get, never):Null<WebSocketRequest>;

	/**
		How often, in seconds, a session that has heard nothing from its peer
		pings it; zero for never. Thirty by default, often enough that a
		proxy between the two does not close the connection as idle, or, on
		a server's sessions, the server's `pingInterval`. Can be changed at any
		time.

		The same beat lets a quiet session go of its memory: one that has
		heard nothing and sent nothing since the last beat lets go of the
		storage its buffers held for the messages before, and holds its
		objects alone, about 4 KB natively, where it kept the largest each
		buffer had needed, some 95 KB after one 16 KB message each way. With
		this and `idleTimeout` both zero there is no beat, and it keeps them.
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
		The largest message this session takes, in bytes: a frame that would
		take its message past this is refused on its header, before anything
		waits for its payload, and the session fails with 1009 (Message Too
		Big), dispatching `close`; so is a compressed message that would
		inflate past it. `0` or less takes messages of any size.

		1 MiB by default, or on a server's sessions the server's
		`maxMessageSize`. Each session has its own, and changing it holds
		from the next frame. It was process-wide, with a limit on each frame
		of 64 KiB besides that refused a browser's message of more than that,
		a browser sends one of 100 KB as one frame, however large a
		message was allowed.

		What a peer can make a session hold while a message arrives is about
		this much: set it to the largest message the application takes.
	**/
	public var maxMessageSize(get, set):Int;

	@:noCompletion private var __maxMessageSize:Int = InternalWS.DEFAULT_MAX_MESSAGE_SIZE;

	/**
		How long a closing handshake is given, in seconds, `closeWith()`'s,
		or one the peer began: for the peer to answer the close frame, and
		for what was sent before it to drain. Past it the connection is
		closed regardless, as 1006 if the peer never answered. Five by
		default, or the server's `closeTimeout`. 0 is refused rather than
		read as no deadline: a closing handshake that waited for good would
		hold a peer that never answers its close frame.

		@throws ArgumentError When not a number above 0.
	**/
	public var closeTimeout(get, set):Float;

	@:noCompletion private var __closeTimeout:Float = InternalWS.DEFAULT_CLOSE_TIMEOUT;

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
		Bytes of unsent frame data allowed to accumulate for this session, or
		`0` for no limit. Past it `outputOverflowPolicy` decides, as on a
		`Socket`: `CLOSE`, the default, dispatches `ioError` and closes the
		session with 1011, throwing away what was waiting; `THROW` throws an
		`IOError` from the send that left it past the limit, and keeps the
		session.

		A peer that stops reading, a slept phone, a half-open connection,
		leaves everything sent to it buffered with nothing to reclaim it.
		Frames are never dropped to stay under the limit.

		A session a `ServerWebSocket` accepted starts with the server's
		`maxOutputBufferSize`, 8 MiB unless changed; a client starts with
		`0`, as a browser's WebSocket has no limit on its `bufferedAmount`:
		what a client holds is only what its own application sent, which it
		can watch in `outputBufferLength`, where a server holds what it sends
		every peer, the slowest included. Answers to the peer's pings never
		pile up here whatever the limit: a session owes at most one, the
		newest ping's (RFC 6455 5.5.3), while the last has not gone.

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

	/**
		Closes the session at once: a close frame with 1000 if the socket
		takes it straight away, and the connection gone. `closeWith` is the
		close that waits for the peer's answer.

		It may be called from any thread, as `Socket.close()` may: from one
		that is not the session's runtime's, it is handed to the runtime and
		happens there after this returns. It threw part way through there,
		the close frame sent, the connection left open, the heartbeat left
		running and `close` never dispatched, since the session's timers
		were taken from the calling thread.

		@throws IOError The session is not open.
	**/
	override public function close():Void {
		if (__webSocket != null) {
			var runtime:Null<CrossByte> = __runtime();
			if (RuntimeHandOff.offThread(runtime)) {
				var session = __webSocket;
				if (runtime.post(function():Void {
					if (__webSocket == session) {
						__cleanSocket();
					}
				})) {
					return;
				}
			}
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
	 * It may be called from any thread, as `close()` may: from one that is
	 * not the session's runtime's, the close is handed to the runtime and
	 * begins there after this returns. It threw there, from the timer that
	 * bounds the peer's answer, which was taken from the calling thread.
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

		var session = __webSocket;
		var runtime:Null<CrossByte> = __runtime();
		if (RuntimeHandOff.offThread(runtime) && runtime.post(function():Void {
			if (__webSocket == session) {
				session.close(code, reason);
			}
		})) {
			return;
		}

		session.close(code, reason);
	}

	/**
		Sends `text` as one text message: a browser receives it as a string.

		Everything written and flushed goes as a binary message, which a
		browser hands its page as a `Blob` or an `ArrayBuffer`, the wrong
		shape for the JSON most pages expect.

		@throws IOError if the session is not open, or, under the `THROW`
			`outputOverflowPolicy`, if more than `maxOutputBufferSize` is
			left waiting; the message is sent all the same.
	**/
	public function sendText(text:String):Void {
		__requireOpen();
		__webSocket.sendString(text == null ? "" : text);
		__checkOutputLimit();
	}

	/**
		Sends `length` bytes of `bytes` from `offset` as one binary message, at
		once rather than when the socket is next flushed. A `length` of 0 sends
		everything from `offset`.

		@throws IOError if the session is not open, or, under the `THROW`
			`outputOverflowPolicy`, if more than `maxOutputBufferSize` is
			left waiting; the message is sent all the same.
		@throws RangeError If the range falls outside `bytes`.
		@throws ArgumentError If `bytes` is `null`.
	**/
	public function sendBinary(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		__requireOpen();
		__checkRange(bytes, offset, length);

		if (length == 0) {
			length = bytes.length - offset;
		}

		var message:ByteArray = new ByteArray();
		message.writeBytes(bytes, offset, length);
		__webSocket.sendBytes(message);
		__checkOutputLimit();
	}

	/**
		`THROW`'s half of `outputOverflowPolicy`, after a send: anything the
		pass is holding is offered to the socket at once, as a `Socket`'s
		flush offers its buffer before it measures, and if more than
		`maxOutputBufferSize` is still waiting an `IOError` is thrown and the
		session kept. `CLOSE`'s half is the session's own, at the write that
		left it past the limit; see `__overflowCloses`.

		Both were missing: whatever the policy, the session closed with 1011
		and said nothing.
	**/
	@:noCompletion private inline function __checkOutputLimit():Void {
		if (__maxOutputBufferSize > 0 && outputOverflowPolicy == OutputOverflowPolicy.THROW) {
			__throwPastOutputLimit();
		}
	}

	@:noCompletion private function __throwPastOutputLimit():Void {
		var session = __webSocket;
		if (session == null || session.outputBufferLength <= __maxOutputBufferSize) {
			return;
		}

		@:privateAccess session.__flushPendingOutput();
		var waiting:Int = session.outputBufferLength;
		if (waiting > __maxOutputBufferSize) {
			throw new IOError('WebSocket output buffer reached $waiting bytes, exceeding the $__maxOutputBufferSize byte limit; the peer is not reading.');
		}
	}

	/** Whether the session closes when its output passes the limit. **/
	@:noCompletion private function __overflowCloses():Bool {
		return outputOverflowPolicy != OutputOverflowPolicy.THROW;
	}

	/**
		Not for a `WebSocket`: a session ends both ways at once, with a close
		frame, `closeWith()` or `close()`, and RFC 6455 has no half-close
		for `shutdown(false, true)` to stand for. `peerShutdownPolicy` is not
		consulted either: a peer that shuts its side ends the session, as 1006.

		@throws IllegalOperationError Always. It returned, having done
			nothing.
	**/
	override public function shutdown(read:Bool, write:Bool):Void {
		throw new IllegalOperationError("A WebSocket has no half-close: a session ends both ways at once, with closeWith() or close().");
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
		return __pingInterval >= 0 ? __pingInterval : InternalWS.DEFAULT_PING_INTERVAL;
	}

	@:noCompletion private function get_maxMessageSize():Int {
		return __webSocket != null ? __webSocket.maxMessageSize : __maxMessageSize;
	}

	@:noCompletion private function set_maxMessageSize(value:Int):Int {
		__maxMessageSize = value;
		if (__webSocket != null) {
			__webSocket.maxMessageSize = value;
		}
		return value;
	}

	@:noCompletion private function get_closeTimeout():Float {
		return __webSocket != null ? __webSocket.closeTimeout : __closeTimeout;
	}

	@:noCompletion private function set_closeTimeout(value:Float):Float {
		if (!(value > 0)) {
			throw new ArgumentError('closeTimeout must be a number of seconds above 0, and was $value.');
		}
		__closeTimeout = value;
		if (__webSocket != null) {
			__webSocket.closeTimeout = value;
		}
		return value;
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

	/**
		Connects to the WebSocket server at `host` and `port`: `ws://`, or
		`wss://` when `secure` is set. `host` may carry a path, as in
		`"example.com/chat"`, and may be an IPv6 literal.

		`timeout` bounds the whole of it, from this call to `connect`: the
		host's lookup, the TCP connect, a `wss://` TLS handshake and the
		upgrade together. `0` waits for as long as it takes.

		@throws SecurityError The port is outside 0-65535.
		@throws IOError The host is not one a URL can name.
	**/
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
		// `timeout` bounds the connection and the upgrade after it, as one
		// deadline from here; see connect's doc. The session used a fixed ten
		// seconds of its own and never waited on the upgrade at all.
		__webSocket.connectTimeout = timeout;
		__webSocket.maxOutputBufferSize = __maxOutputBufferSize;
		__webSocket.maxMessageSize = __maxMessageSize;
		__webSocket.closeTimeout = __closeTimeout;
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

		@throws IOError if the session is closing or closed, or, under the
			`THROW` `outputOverflowPolicy`, if more than `maxOutputBufferSize`
			is left waiting; the message is sent all the same.
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
			__checkOutputLimit();
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
		Reads `length` bytes and decodes them as UTF-8.
		@param length  The number of bytes from the byte stream to read.
		@param charSet Accepted for source compatibility and **ignored**. No
					   character set conversion happens: the bytes are decoded
					   as UTF-8, exactly as `readUTFBytes` would. Passing
					   "shift-jis" does not decode Shift-JIS. Transcode the
					   bytes yourself if you need another encoding.
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
		Reads an object from the socket, in whichever format `objectEncoding`
		names, as a `ByteArray` reads one: `HXSF` unless it was changed. An
		encoding this build cannot do throws.
		@return The deserialized object
		@throws EOFError There is insufficient data available to read.
		@throws IOError  An I/O error occurred on the socket, or the socket is
						 not open.
	**/
	override public function readObject():Dynamic {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		// As a ByteArray reads one, in every encoding a ByteArray can, JSON
		// always, AMF with -lib format, and one this build cannot do throws.
		// Only HXSF was read: anything else read null, and said nothing.
		__input.objectEncoding = objectEncoding;
		return __input.readObject();
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
		@throws ArgumentError If `bytes` is `null`.
	**/
	override public function writeBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__checkRange(bytes, offset, length);
		__output.writeBytes(bytes, offset, length);
	}

	/**
		Refuses a range outside `bytes`, as `DatagramSocket.send` does: a
		`ByteArray` copy takes whatever part of a range falls inside its
		source and drops the rest, so a message cut short went without a word.
	**/
	@:noCompletion private static inline function __checkRange(bytes:ByteArray, offset:Int, length:Int):Void {
		// One branch on the way through, since every message sent passes
		// here. Against what is left after `offset` rather than
		// `offset + length`, which overflows for a large length and wraps
		// negative.
		if (bytes == null || offset < 0 || length < 0 || offset > bytes.length || length > bytes.length - offset) {
			__refuseRange(bytes);
		}
	}

	@:noCompletion private static function __refuseRange(bytes:ByteArray):Void {
		if (bytes == null) {
			throw new ArgumentError("One of the parameters is invalid");
		}
		throw new RangeError("The supplied index is out of bounds.");
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
		Writes a string as UTF-8.
		@param value   The string value to be written.
		@param charSet Accepted for source compatibility and **ignored**. The
					   string is encoded as UTF-8, exactly as `writeUTFBytes`
					   would. Transcode the bytes yourself if you need another
					   encoding.
	**/
	override public function writeMultiByte(value:String, charSet:String):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__output.writeUTFBytes(value);
	}

	/**
		Writes an object to the socket, in whichever format `objectEncoding`
		names, as a `ByteArray` writes one: `HXSF` unless it was changed. An
		encoding this build cannot do throws.
		@param object The object to be serialized.
		@throws IOError An I/O error occurred on the socket, or the socket is
						not open.
	**/
	override public function writeObject(object:Dynamic):Void {
		if (__webSocket == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		// As a ByteArray writes one; see readObject. Anything but HXSF wrote
		// nothing, and said nothing.
		__output.objectEncoding = objectEncoding;
		__output.writeObject(object);
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
		var code:Int = 0;
		var reason:String = null;
		var closed:WebsocketEvent = Std.downcast(event, WebsocketEvent);
		if (closed != null) {
			code = closed.code;
			reason = closed.reason;
		}
		__framingClosed(code, reason);
	}

	/** The session underneath has closed, with `code` and `reason`. **/
	@:noCompletion private function __framingClosed(code:Int, reason:Null<String>):Void {
		__connected = false;
		__webSocket = null;

		// Its place among the server's sessions, for the next.
		if (__countedBy != null) {
			var counted:ServerWebSocket = __countedBy;
			__countedBy = null;
			@:privateAccess counted.__releaseSession();
		}
		// And off the server's list of open sessions, before anything that
		// listens for the close below runs, as it was when the server heard
		// of it through a close listener of its own added first.
		if (__trackedBy != null) {
			var tracker:ServerWebSocket = __trackedBy;
			__trackedBy = null;
			@:privateAccess tracker.__sessionClosed(this);
		}

		// Ended before it opened: its server stops waiting on it, and counts
		// it if it failed to arrive.
		if (__server != null) {
			var server:ServerWebSocket = __server;
			__server = null;
			@:privateAccess server.__upgradeEnded(this);
		}

		// The session underneath knows why it ended; this used to drop that
		// on the floor and dispatch a bare Event.CLOSE, so an application
		// could not tell a peer disconnecting from a peer being dropped for
		// a protocol violation. Dispatched under the Event.CLOSE type, so
		// listeners that only care *that* it closed are unaffected.
		dispatchEvent(new WebSocketCloseEvent(Event.CLOSE, code, reason));
	}

	@:noCompletion override private function socket_onError(e):Void {
		var failed:WebsocketEvent = Std.downcast(e, WebsocketEvent);
		__framingFailed(failed != null ? failed.text : null, failed != null ? failed.errorID : 0);
	}

	/** The session underneath has failed, saying `text`. **/
	@:noCompletion private function __framingFailed(text:Null<String>, errorID:Int):Void {
		// An IOErrorEvent carrying what went wrong. This dispatched a bare
		// Event of the ioError type, so a listener typed for IOErrorEvent got
		// something else, and a refused certificate or a connect that failed
		// arrived with no account of which it was.
		//
		// A deadline that passed says so with its id, which a NetConnection
		// over this socket reports as Reason.Timeout.
		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, text == null ? "" : text, errorID));
	}

	@:noCompletion override private function socket_onMessage(msg:Dynamic):Void {
		var message:WebsocketEvent = msg;
		__messageArrived(message.message, message.isText);
	}

	// The MESSAGE event this session hands its messages out in, made with the
	// first and filled again for each after it (see Arrivals), and whether
	// it is out: a listener that pumps the runtime can be handed the next
	// message inside its own call, which gets an event of its own. Never
	// kept under either define.
	@:noCompletion private var __messageEvent:WebSocketMessageEvent = null;
	@:noCompletion private var __messageEventOut:Bool = false;

	/**
		One whole message from the session, handed over directly
		(`__onMessage`), with no event made between the two layers: valid
		only during this call, which is the outermost to hand it out here.
	**/
	@:noCompletion private function __messageArrived(newData:ByteArray, isText:Bool):Void {
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
			var pooled:Bool = Arrivals.REUSE && !__messageEventOut;
			var event:WebSocketMessageEvent;
			if (pooled) {
				event = __messageEvent;
				if (event == null) {
					event = __messageEvent = new WebSocketMessageEvent(WebSocketMessageEvent.MESSAGE, newData, isText);
				} else {
					event.__refill(newData, isText);
				}
				__messageEventOut = true;
			} else {
				event = new WebSocketMessageEvent(WebSocketMessageEvent.MESSAGE, newData, isText);
			}
			try {
				dispatchEvent(event);
			} catch (e:Dynamic) {
				__messageDispatched(event, pooled);
				Arrivals.rethrow(e);
			}
			__messageDispatched(event, pooled);
			return;
		}

		// What has been read goes, as on a plain socket, rather than being
		// kept until a reader happens to take everything.
		__compactInput();

		var arrived:Int = newData.length;
		newData.readBytes(__input, __input.length);

		// What has just arrived, as a plain socket reports it on every target;
		// this reported everything unread, so a reader that had left one
		// message in the stream was told the next was both together. In the
		// event a plain socket hands out too, filled again for each.
		if (arrived > 0) {
			__dispatchPooledSocketData(arrived, 0);
		}
	}

	@:noCompletion private inline function __messageDispatched(event:WebSocketMessageEvent, pooled:Bool):Void {
		if (pooled) {
			event.__release();
			__messageEventOut = false;
		} else {
			Arrivals.doneWith(event);
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
			// Let go of first, so a listener closing the session at once is
			// not taken for an upgrade that failed.
			var server:ServerWebSocket = __server;
			__server = null;
			server.dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, this));
		}
	}

	private function __init():Void {
		__output = new ByteArray();
		__output.endian = __endian;

		__input = new ByteArray();
		__input.endian = __endian;

		__webSocket.binaryType = "arraybuffer";
		// The session tells this of its opening, its messages, its errors,
		// its close and its overflow by typed calls, with no event between
		// the layers. It was given a closure for each, six a session, kept
		// for as long as it lasted.
		__webSocket.__owner = this;
		__syncProgressHook();

		// A server's session asks its server about its upgrade, through
		// the hook as it stands when the request arrives, not as it stood
		// when the connection did.
		if (__server != null) {
			var server:ServerWebSocket = __server;
			__webSocket.onupgrade = function(request:WebSocketRequest):Bool {
				// Refused unless the hook says otherwise: one that throws
				// refuses too.
				__upgradeRefused = true;
				// A place among the server's open sessions first: at
				// maxConnections the upgrade is answered 503, and the hook is
				// not asked about a session that could not open.
				if (!@:privateAccess server.__claimSession()) {
					@:privateAccess server.__refusedConnections++;
					request.status = 503;
					return false;
				}
				var accepted:Bool = false;
				try {
					accepted = server.upgrade(request);
				} catch (e:Dynamic) {
					@:privateAccess server.__releaseSession();
					#if cpp
					cpp.Lib.rethrow(e);
					#else
					throw e;
					#end
				}
				if (accepted) {
					// Let go of as the session closes.
					__countedBy = server;
				} else {
					@:privateAccess server.__releaseSession();
				}
				__upgradeRefused = !accepted;
				return accepted;
			};
		}
	}

	override public function addEventListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		super.addEventListener(type, listener, priority);
		if (type == OutputProgressEvent.OUTPUT_PROGRESS) {
			__syncProgressHook();
		}
	}

	override public function removeEventListener<T>(type:EventType<T>, listener:T->Void):Void {
		super.removeEventListener(type, listener);
		if (type == OutputProgressEvent.OUTPUT_PROGRESS) {
			__syncProgressHook();
		}
	}

	/**
		Asks the session to report bytes reaching the system while anyone
		listens for OUTPUT_PROGRESS, and not otherwise: on Node each report
		is a callback on a write.
	**/
	@:noCompletion private function __syncProgressHook():Void {
		if (__webSocket != null) {
			__webSocket.onprogress = hasEventListener(OutputProgressEvent.OUTPUT_PROGRESS) ? __noteProgress : null;
		}
	}

	// Sent and still held are the session's, which frames and sends.
	@:noCompletion override private function __sentTotal():Float {
		return __webSocket == null ? super.__sentTotal() : __webSocket.bytesSent;
	}

	@:noCompletion override private function __unsentOwn():Int {
		return __webSocket == null ? super.__unsentOwn() : __webSocket.ownPending;
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

	// The session's: a WebSocket's TLS is its session's, and the socket the
	// base class would ask is never set.
	@:noCompletion override private function get_alpnProtocol():Null<String> {
		return __webSocket == null ? null : __webSocket.alpnProtocol;
	}

	@:noCompletion override private inline function get_registryClosed():Bool {
		return __closed || __webSocket == null;
	}
}
#end
