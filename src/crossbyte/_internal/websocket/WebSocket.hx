package crossbyte._internal.websocket;

// Not built for the browser: a page reaches a ws:// endpoint through its own
// WebSocket, which crossbyte.net.Socket already uses there. Node has no
// WebSocket of its own, so it frames one here, over js.node.net.
#if !(js && !nodejs)

#if nodejs
import js.node.Buffer;
import js.node.Net;
import js.node.Tls;
import js.node.net.Socket as NodeSocket;
#else
import crossbyte._internal.net.Resolver;
import sys.net.Host;
#end
import crossbyte._internal.system.timer.TimerScheduler;
import crossbyte.core.CrossByte;
import crossbyte.crypto.SecureRandom;
import crossbyte.events.Event;
import crossbyte.events._internal.Arrivals;
import crossbyte.io.ByteArray;
import crossbyte.net.WebSocketRequest;
import crossbyte._internal.socket.BlockedError;
import crossbyte._internal.socket.IPollableSocket;
import crossbyte.utils.Logger;
import haxe.crypto.Base64;
import haxe.crypto.Sha1;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import haxe.io.Eof;
import haxe.io.Error;

/**
 * One WebSocket session, either end: RFC 6455 framing over a TCP socket.
 *
 * Driven by the runtime's socket registry once open, rather than by the
 * tick: it is read when its socket is readable and flushed when a write is
 * waiting, so an idle session costs nothing. Only the phases before that (a
 * client's connect and a TLS handshake) still ride the tick, and each is
 * bounded by a deadline.
 *
 * @author Christopher Speciale
 */
class WebSocket implements crossbyte.core._internal.PassFlush #if !nodejs implements IPollableSocket #end {
	public static inline var CLOSED:Int = 3;
	public static inline var CLOSING:Int = 2;
	public static inline var CONNECTING:Int = 0;
	public static inline var OPEN:Int = 1;

	/** The default `maxMessageSize`: 1 MiB. **/
	public static inline var DEFAULT_MAX_MESSAGE_SIZE:Int = 1024 * 1024;

	/**
		The largest frame this side sends: a message longer is sent in frames
		of this many bytes. 64 KiB, the most a CrossByte peer older than 1.0
		takes in one frame. What this side takes in one is bounded by
		`maxMessageSize` alone.
	**/
	public static inline var FRAGMENT_SIZE:Int = 64 * 1024;

	/** The ping interval a session starts with, in seconds; see `pingInterval`. **/
	public static inline var DEFAULT_PING_INTERVAL:Float = 30.0;

	/** The idle timeout a session starts with, in seconds; see `idleTimeout`. **/
	public static inline var DEFAULT_IDLE_TIMEOUT:Float = 60.0;

	/** The closing handshake's deadline a session starts with, in seconds; see `closeTimeout`. **/
	public static inline var DEFAULT_CLOSE_TIMEOUT:Float = 5.0;

	/**
		The largest message this session takes, in bytes: a frame whose
		length would take the message it belongs to past this is refused on
		its header, before anything waits for its payload, and the session
		fails with 1009 (Message Too Big); so is a compressed message that
		would inflate past it. `0` or less takes messages of any size.

		1 MiB by default. A frame may be as long as the message: a browser
		sends one of 100 KB as a single frame, and Node's `ws` sends every
		message as one, so a frame is held only to what is left of the
		message, on its header.

		Per session: one server, or a client, setting it changes it for no
		other session in the process.
	**/
	public var maxMessageSize:Int = DEFAULT_MAX_MESSAGE_SIZE;

	/**
		How long a closing handshake is given, in seconds: for the peer to
		answer a close frame, and for what was queued before it to drain.
		Past it the connection is closed regardless, as 1006 when the peer
		never answered. Five by default, per session.
	**/
	public var closeTimeout:Float = DEFAULT_CLOSE_TIMEOUT;

	private static inline var WS:String = "ws";
	private static inline var WSS:String = "wss";

	private static inline var CRLF:String = "\r\n";
	private static inline var CRLFCRLF:String = "\r\n\r\n";
	private static inline var GET:String = "GET";
	private static inline var HTTP:String = "HTTP";

	private static inline var OUTPUT_COMPACT_THRESHOLD:Int = 64 * 1024;

	// What a pass may hold before it is written anyway, and the size of a
	// frame that is written at once rather than held: either is a write
	// worth making on its own. See __queueOutput.
	private static inline var PASS_BATCH:Int = 64 * 1024;

	/** The extension named in the handshake, as RFC 7692 names it. **/
	public static inline var PERMESSAGE_DEFLATE:String = "permessage-deflate";

	/**
	 * What a session offers, or answers an offer with: each message
	 * compressed on its own, in both directions, since neither end keeps a
	 * compressor's window from one message to the next.
	 */
	private static inline var DEFLATE_PARAMETERS:String = "server_no_context_takeover; client_no_context_takeover";

	/**
	 * The smallest message sent compressed when `compressionThreshold` is
	 * not set: below about a kilobyte the DEFLATE framing costs about as much
	 * as it saves, and the time is spent for nothing.
	 */
	public static inline var DEFAULT_COMPRESSION_THRESHOLD:Int = 1024;

	public var binaryType:BinaryType = ARRAYBUFFER;
	public var bufferdAmount(default, null):Int = 0;

	/**
	 * The extensions this session agreed to in its handshake, as the
	 * `Sec-WebSocket-Extensions` it answered or was answered with; empty for
	 * none.
	 */
	public var extensions(default, null):String = "";

	/**
	 * Whether to ask for, or agree to, permessage-deflate (RFC 7692): each
	 * message compressed on its own. Off unless set, before `connect` or
	 * before a server's sessions arrive. Whether a session uses it is its
	 * peer's say too; see `compressed`.
	 */
	public var perMessageDeflate:Bool = false;

	/**
	 * Messages shorter than this many bytes are sent as they are, even where
	 * compression was agreed.
	 */
	public var compressionThreshold:Int = DEFAULT_COMPRESSION_THRESHOLD;

	/** Whether this session agreed to permessage-deflate. **/
	public var compressed(get, never):Bool;

	private inline function get_compressed():Bool {
		return __deflate;
	}

	// Agreed in the handshake; and whether the message arriving is compressed.
	private var __deflate:Bool = false;
	private var __incomingCompressed:Bool = false;

	// Whether what this side sends may go compressed: only where its peer
	// agreed to inflate each message on its own; see __takeDeflateAnswer.
	private var __deflateSend:Bool = false;
	// Asked where there is no `__owner`; null is no one, so a session with
	// an owner makes no closures for these.
	public var onclose:Null<WebsocketEvent->Void> = null;
	public var onerror:Null<WebsocketEvent->Void> = null;
	public var onmessage:Null<WebsocketEvent->Void> = null;
	public var onopen:Null<WebsocketEvent->Void> = null;

	/**
	 * A server session's say over its own upgrade, asked once the request has
	 * arrived and before the `101` is sent: `false` refuses it, with the
	 * request's `status`, and the request's `protocol` is the subprotocol
	 * accepted. Unset, every valid upgrade is accepted with the first
	 * subprotocol offered.
	 */
	public var onupgrade:WebSocketRequest->Bool = null;

	/**
	 * The subprotocol the session speaks: on a server, the one accepted; on a
	 * client, the one the server chose from those asked for. `null` for none.
	 */
	public var protocol(default, null):String;

	/** The upgrade request a server session was opened by; `null` on a client. **/
	public var request(default, null):WebSocketRequest;

	public var readyState(default, null):Int = CONNECTING;
	public var url(default, null):String;

	private var __socket:#if nodejs NodeSocket #else FlexSocket #end;
	private var __inputPosition:Int = 0;
	private var __input:ByteArray;
	private var __incomingMessageBuffer:ByteArray;
	// The buffer messages are read into, kept from one to the next (up to
	// Arrivals.KEEP) and filled again, so receiving makes no garbage; and
	// whether it is out, handed over and not yet returned, when a message
	// is read into one of its own. A listener that pumps the runtime can be
	// handed the next message inside its own call. Never kept under either
	// define.
	private var __messageKept:ByteArray = null;
	private var __messageOut:Bool = false;

	/**
		Handed each whole message directly, with no event made for it, in
		place of `onmessage` where it is set: `crossbyte.net.WebSocket`'s
		hand-off. `message` is valid only during the call; see `Arrivals`.
	**/
	@:noCompletion public var __onMessage:Null<(message:ByteArray, isText:Bool) -> Void> = null;

	/**
		The `crossbyte.net.WebSocket` this session frames for, where it has
		one: told of its opening, its messages, its errors, its close and its
		overflow by typed calls, in place of `onopen`, `__onMessage`,
		`onerror`, `onclose` and `onoverflow`, which are not asked then, so
		the session keeps no closure of the owner's for any of them and makes
		no event for each call.
	**/
	@:noCompletion public var __owner:Null<crossbyte.net.WebSocket> = null;
	private var __incomingOpcode:Int = -1;
	private var __incomingMessageSize:Int = 0;
	private var __output:ByteArray;

	/**
	 * Bytes handed to this session but not yet accepted by the socket.
	 *
	 * A non-blocking socket accepts only what fits in its send buffer, so
	 * anything beyond that must be retained and retried rather than
	 * discarded. Retried when the registry drains its writable queue, which
	 * a write that could not finish joins.
	 */
	private var __pendingOutput:ByteArray;
	#if ((cpp || jvm) && !macro)
	// The most the input and what waits to be sent have held since each last
	// emptied, and the most each held in the last burst that took it past
	// `KEEP`: the size its next such burst takes from the pool at once, as
	// `Socket`'s.
	private var __inputPeak:Int = 0;
	private var __inputHint:Int = 0;
	private var __pendingPeak:Int = 0;
	private var __pendingHint:Int = 0;
	#end

	/**
	 * Maximum bytes allowed to accumulate in `__pendingOutput`, or `0` for
	 * no limit.
	 *
	 * A peer that stops reading cannot be waited on forever: without a
	 * bound its unread frames grow until the process runs out of memory,
	 * which on a server fanning out to many sessions is one slow client
	 * taking down everything.
	 */
	public var maxOutputBufferSize:Int = 0;

	/**
	 * Asked when a write leaves more than `maxOutputBufferSize` waiting:
	 * `true` closes the session with 1011, after an error saying why, and
	 * throws away what was waiting; `false` keeps both, for an owner that
	 * says so its own way. Unset, the session closes.
	 */
	public var onoverflow:Void->Bool = null;

	// Whether the close underway throws away what is waiting rather than
	// sending it first: the output limit's, which exists to reclaim it.
	private var __discardOnClose:Bool = false;

	/**
	 * Bytes still waiting for the socket to accept them.
	 *
	 * A value that keeps climbing means the peer is not draining as fast as
	 * this side produces. Useful as a metrics gauge and as a signal to stop
	 * enqueueing.
	 */
	public var outputBufferLength(get, never):Int;

	private function get_outputBufferLength():Int {
		var buffered:Int = __pendingOutput == null ? 0 : __pendingOutput.length - __pendingSent;
		#if nodejs
		// Node takes every frame whole and queues what the kernel will not,
		// so the backlog is Node's: counting only this side's buffer would read
		// 0 for a peer that had stopped reading, and a server's drain() would
		// wait on nothing.
		if (__socket != null) {
			buffered += __socket.writableLength;
		}
		#end
		return buffered;
	}

	// How much of the front of __pendingOutput the socket has already taken;
	// see __flushPendingOutput.
	private var __pendingSent:Int = 0;

	/**
	 * What the network has taken from this session since it opened (on
	 * Node, what was handed to Node's queue, which `outputBufferLength`
	 * counts as still pending).
	 */
	public var bytesSent(default, null):Float = 0;

	/**
	 * What this session holds that is not yet handed to the system, or on
	 * Node to Node's queue: with `bytesSent`, every byte sent, each once.
	 */
	public var ownPending(get, never):Int;

	private inline function get_ownPending():Int {
		return __pendingOutput == null ? 0 : __pendingOutput.length - __pendingSent;
	}

	/**
	 * Told as sent bytes reach the system, for whoever reports progress
	 * (`crossbyte.net.WebSocket`'s OUTPUT_PROGRESS), and only while it is
	 * set: on Node it costs a write callback.
	 */
	public var onprogress:Void->Void = null;

	private static inline var CONNECT_TIMEOUT_MS:Int = 10000;

	/**
	 * How long a client waits, in milliseconds, from the start of its connect
	 * for the session to open: the name's lookup, the TCP connect, a TLS
	 * handshake and the upgrade, together. `0` waits as long as it takes.
	 * Counted from the connect's start whenever it is set, so it can be set
	 * straight after construction.
	 */
	public var connectTimeout(default, set):Int = CONNECT_TIMEOUT_MS;

	private function set_connectTimeout(value:Int):Int {
		connectTimeout = value;
		if (__isClient != false && readyState == CONNECTING && __socket != null) {
			__armOpenDeadline();
		}
		return value;
	}

	/**
	 * How often, in seconds, a session that has heard nothing from its peer
	 * pings it; zero for never. A peer answers a ping with a pong, so a quiet
	 * connection whose peer is still there stays in use, which also keeps a
	 * proxy between the two from closing it as idle.
	 */
	public var pingInterval(get, set):Float;

	/**
	 * How long, in seconds, a session hears nothing (no message, no pong, no
	 * frame at all) before it takes the peer for gone and closes with 1006;
	 * zero for never. Checked every `pingInterval`, or every quarter of this
	 * with pings off.
	 */
	public var idleTimeout(get, set):Float;

	private var __connected:Bool = false;
	// When a client's connect started, or a server's session was accepted.
	private var __timestamp:Float;

	private var __origin:String;
	// A client's, as asked for; null for none, and on every server session.
	private var __protocols:Null<Array<String>> = null;
	private var __secure:Bool;

	// Whether the transport is TLS, whichever side made it.
	private var __tls:Bool = false;

	// What a secure client checks the server against. Verified by default,
	// so a secure client does not accept any certificate for any host.
	private var __verifyCert:Bool = true;
	private var __certAuthority:crossbyte.net.Certificate;

	// A connect that failed before the first tick. Reported from that tick
	// rather than where it happened, because that is inside the constructor,
	// before the owner has attached anything to hear it.
	private var __connectFailure:String = null;

	#if !nodejs
	// Whether the host named in the URL is still being looked up.
	private var __resolving:Bool = false;
	#end

	// Whether onclose has been called. A session can be closed from several
	// places in one pass (a failed write inside the frame that answers a
	// close, say), and the owner is told once.
	private var __closeReported:Bool = false;

	// What a client's failed connect is reported by: whether the owner is
	// the one closing it, and whether the owner has been told of an error
	// yet. See __close.
	private var __ownerClosing:Bool = false;
	private var __errorReported:Bool = false;

	// A close waiting for queued output to go: what it will report.
	private var __closeWhenDrained:Bool = false;
	private var __drainedCode:Int = 1000;
	private var __drainedReason:String = null;

	// The deadline on a closing handshake, and on a client's connect.
	private var __closeDeadline:Int = 0;
	private var __closeDeadlineArmed:Bool = false;
	private var __openDeadline:Int = 0;
	private var __openDeadlineArmed:Bool = false;

	// The heartbeat: whether anything has arrived since the last beat, for
	// how long in a row nothing has, and the timer.
	private var __pingInterval:Float = -1;
	private var __idleTimeout:Float = DEFAULT_IDLE_TIMEOUT;
	private var __heard:Bool = false;
	private var __silentFor:Float = 0;
	// What had been sent or queued at the last beat, for whether the session
	// has sent anything since; see __trimWhenQuiet.
	private var __sentAtBeat:Float = 0;
	private var __heartbeat:Int = 0;
	private var __heartbeatArmed:Bool = false;

	// Whether this session's socket is in the runtime's registry, and whether
	// a retry of its pending output is queued there.
	private var __registered:Bool = false;
	private var __writeQueued:Bool = false;

	// Whether the runtime is to flush this session's output when its pass
	// ends; see __queueOutput.
	private var __passFlushQueued:Bool = false;

	// A client's connect in flight, and a TLS handshake in flight, either
	// end: what the registry's calls step while they last, rather than read.
	private var __dialing:Bool = false;
	private var __handshaking:Bool = false;

	// The ends of the connection, noted once it is open.
	private var __remoteAddress:String = "";
	private var __remotePort:Int = 0;
	private var __localAddress:String = "";
	private var __localPort:Int = 0;

	private var __path:String;
	private var __scheme:String;
	private var __host:String;
	private var __port:Int;
	private var __key:String;

	/**
		The largest opening handshake this session reads, in bytes: a server
		session's upgrade request, or a client's answer to its own, from the
		request or status line to the blank line that ends the head. Past it
		a server answers `431 Request Header Fields Too Large` and closes; a
		client gives up, with an error saying so, and closes with 1006. `0`
		or less reads one of any size.

		16 KiB by default, as Node's HTTP parser (and so the `ws` library
		on it) has it: a browser's upgrade request is a few hundred bytes
		with its cookies, a few kilobytes at most, and the server holds what
		has arrived of each one still upgrading, so this times
		`maxPendingHandshakes` is what silent peers can make it hold.
	**/
	public var maxHeaderSize:Int = DEFAULT_MAX_HEADER_SIZE;

	/** The default `maxHeaderSize`: 16 KiB, as Node's. **/
	public static inline var DEFAULT_MAX_HEADER_SIZE:Int = 16 * 1024;

	// How far the search for the end of the opening handshake's head has
	// got in __input, so each arrival is searched once rather than the
	// whole head again with every byte that arrives.
	private var __headScanned:Int = 0;

	// Whether this server session refused its upgrade: what still arrives
	// from the peer is read and dropped until the answer has gone.
	private var __refusing:Bool = false;

	private var __maskedPayload:ByteArray;
	// A control frame's payload, read in; see __onData. Made with the first.
	private var __control:ByteArray = null;

	// Kept for the parser tests, which set it directly: a pong clears it.
	private var __hasTimeoutPotential:Bool = false;

	private var __isClient:Null<Bool>;
	private var __runtime:CrossByte;
	private var __tickConnectListener:Event->Void;
	private var __tickSSLHandshakeListener:Event->Void;

	/**
	 * @param verifyCert For `wss://`: whether the server's certificate is
	 *        checked against a trusted authority and the host name.
	 * @param certAuthority For `wss://`: the authority to trust in place of
	 *        the system's store, or `null` for the system's.
	 */
	public function new(url:String, ?protocols:Array<String>, ?origin:String, verifyCert:Bool = true, ?certAuthority:crossbyte.net.Certificate) {
		if (__isClient == null) {
			__isClient = true;
			#if !nodejs
			// A client's alone, which connects from the tick; a server's
			// sessions need neither this nor the handshake's below. See
			// __initSSLHandshake.
			__tickConnectListener = __onTickConnect;
			#end
			// A client's alone: a server answers the key it is sent, and needs
			// no randomness of its own. SecureRandom refuses on eval, hl and
			// neko, so drawn for a server session it would throw in the accept
			// tick and reset the peer.
			__key = Base64.encode(SecureRandom.getSecureRandomBytes(16));
			__verifyCert = verifyCert;
			__certAuthority = certAuthority;
			this.url = url;
			// benchmark the two for the fastest regular expression
			// var regex:EReg = ~/^(\w+):\/\/([^\/:]+)(?::(\d+))?([^#]*)(?:#.*)?$/;

			// The host is a bracketed IPv6 literal or a run without colons: a
			// URL writes an IPv6 address in brackets, and without the first
			// alternative its colons read as the start of a port.
			var regex:EReg = ~/^(\w+):\/\/(\[[^\]\/]*\]|[^:\/]+)(?::(\d+))?\/?(.*)$/;

			if (regex.match(url)) {
				// the URI is well-formed
				__scheme = regex.matched(1).toLowerCase();
				__host = regex.matched(2);
				if (StringTools.startsWith(__host, "[")) {
					// Dialled, looked up and named to TLS without the brackets.
					__host = __host.substring(1, __host.length - 1);
				}
				if (__scheme == WSS) {
					__secure = true;
				} else if (__scheme == WS) {
					__secure = false;
				} else {
					throw "Uri does not include a valid Web Socket Scheme";
				}

				// Bounded as it is read. Std.parseInt answers a number too big
				// for an Int differently on every target (its low 32 bits on
				// Linux native, the largest Int on Windows, an exception on the
				// jvm, nothing at all on eval), so a port past 65535 would become
				// some other port, or the default, depending where it ran.
				var portText:Null<String> = regex.matched(3);
				if (portText == null || portText.length == 0) {
					__port = __secure ? 443 : 80;
				} else {
					var port:Int = crossbyte.utils.IntParse.decimal(portText, 65535);
					if (port < 0) {
						throw "Uri port is out of range: " + portText;
					}
					__port = port;
				}
				var path:Null<String> = regex.matched(4);
				__path = path == "" ? "/" : "/" + path;
			} else {
				throw "Uri is not a well-formed";
			}

			if (protocols != null) {
				__protocols = protocols.copy();
			}

			if (origin == null) {
				origin = "http://127.0.0.1/";
			}
			__origin = origin;
			__initSocket();
		}
	}

	private function __initSocket(?socket:#if nodejs NodeSocket #else FlexSocket #end, ?runtime:CrossByte):Void {
		__runtime = runtime != null ? runtime : CrossByte.current();
		__input = new ByteArray();
		__input.endian = BIG_ENDIAN;
		__output = new ByteArray();
		__output.endian = BIG_ENDIAN;

		__pendingOutput = new ByteArray();
		__pendingOutput.endian = BIG_ENDIAN;

		// Taken when a message's first frame arrives (see __takeMessage).
		__incomingMessageBuffer = null;

		// Made when first needed, and let go of when the session goes quiet:
		// a client's masked payload, or a text message written in place
		// (see __scratchPayload).
		__maskedPayload = null;

		__timestamp = haxe.Timer.stamp();

		#if nodejs
		// Node's own socket, so there is no connect poll and no handshake
		// pump: it reports both as events. wss is a `tls.connect` rather than
		// a `net.connect`, and the TLS is Node's.
		if (socket == null) {
			__tls = __secure;
			__connectNode();
			__armOpenDeadline();
		} else {
			// Accepted rather than dialled: already connected, so there is no
			// connect event to wait for. __openConnection sends the upgrade
			// request only for a client, and this is not one: a server waits
			// to receive one.
			__socket = socket;
			__tls = Reflect.field(socket, "encrypted") == true;
			__bindNodeTransport();
			__openConnection(null);
		}
		#else
		if (socket == null) {
			__socket = new FlexSocket(__secure);
			__tls = __secure;
			if (__secure) {
				// Checked unless the owner said not to. The host name set below
				// is what the certificate is then matched against, as well as the
				// SNI name.
				__socket.verifyCert = __verifyCert;
				if (__certAuthority != null) {
					__socket.setCA(__certAuthority.__native);
				}
				__socket.setHostname(__host);
			}
			// No byte order is set on the output: frames go out as raw bytes,
			// and on jvm a socket has no output at all until it connects, so
			// setting one here would throw before any client, ws:// included,
			// had even started.
			__connect();
			__runtime.addEventListener(Event.TICK, __tickConnectListener);
			__armOpenDeadline();
		} else {
			__socket = socket;
			__tls = __socket.isSecure;

			// An accepted TLS socket has completed TCP but not TLS. Without
			// this it would handshake implicitly on its first read, with no
			// bound, so a peer that connects and then stalls mid-handshake
			// holds the socket indefinitely. Run the same deferred,
			// timeout-guarded handshake the client path uses; the WebSocket
			// upgrade follows once TLS completes.
			if (__tls) {
				__initSSLHandshake();
			} else {
				__openConnection(null);
			}
		}
		#end
	}

	#if nodejs
	/**
	 * Opens the connection and wires the three things the framing layer needs
	 * from a transport: bytes arriving, the peer going away, and a failure.
	 *
	 * Nothing here polls, and nothing ticks: Node reports each of those as an
	 * event, and a write goes straight into Node's own queue.
	 */
	private function __connectNode():Void {
		var connected = function():Void {
			try {
				__openConnection(null);
			} catch (e:Dynamic) {
				__contain(e);
			}
		};

		if (__secure) {
			// Node verifies unless told otherwise; this lets the owner say
			// either thing: trust a private authority, or, for a development
			// server, not check.
			var options:Dynamic = {port: __port, host: __host, rejectUnauthorized: __verifyCert};

			// `servername` is the SNI name, and without it a host serving
			// several certificates on one address has no way to pick this
			// one's, and the handshake fails on a name mismatch that looks
			// like a certificate error. Only for a name, though: SNI may not
			// carry an address (RFC 6066 3), and Node checks the certificate
			// against `host` when there is none.
			if (Net.isIP(__host) == 0) {
				options.servername = __host;
			}

			if (__certAuthority != null) {
				options.ca = [__certAuthority.__pem];
			}

			var tls = Tls.connect(options, connected);
			__socket = cast tls;
		} else {
			__socket = Net.connect({port: __port, host: __host}, connected);
		}

		__bindNodeTransport();
	}

	/**
	 * The three things the framing layer needs from a transport: bytes
	 * arriving, the peer going away, and a failure. Shared by the socket this
	 * side dialled and the one a server accepted, so the two cannot come to
	 * report any of them differently.
	 */
	private function __bindNodeTransport():Void {
		// Each one contained: these run from Node's event loop, so a listener
		// that threw (a message handler meeting input it could not parse)
		// would throw into Node, which ends the process and every session in it.
		__socket.on("data", function(chunk:Buffer):Void {
			try {
				__receiveNode(chunk);
			} catch (e:Dynamic) {
				__contain(e);
			}
		});

		__socket.on("error", function(e:Dynamic):Void {
			try {
				// Reported before the close that follows it, so the reason
				// reaches the caller rather than only the fact.
				__onError("WebSocket transport failed: " + Std.string(e));
				__close(1006);
			} catch (thrown:Dynamic) {
				__contain(thrown);
			}
		});

		__socket.on("close", function(_):Void {
			try {
				if (readyState != CLOSED) {
					// 1006 rather than 1000: the peer went without a close
					// frame, which is ordinary (a dropped connection, a
					// killed process), and is exactly what 1006 is for.
					__close(1006);
				}
			} catch (e:Dynamic) {
				__contain(e);
			}
		});
	}

	/**
		A listener threw from inside one of Node's callbacks: logged, and the
		session closed with 1011, since whatever it was in the middle of
		cannot be trusted to be finished. The rest of the process carries on.
	**/
	private function __contain(error:Dynamic):Void {
		CrossByte.__socketListenerThrew(error, this, "A WebSocket listener threw, and the session it was handling was closed");

		try {
			abort(1011, "internal error");
		} catch (_:Dynamic) {}
	}

	/**
	 * Hands one arriving chunk to the framing layer.
	 *
	 * The same lines the native read loop ends with, minus the loop: there is
	 * nothing to drain, because Node has already done the draining and is
	 * calling with what it drained.
	 */
	private function __receiveNode(chunk:Buffer):Void {
		if (chunk == null || chunk.length == 0) {
			return;
		}

		__heard = true;

		// Its own region only: a Node Buffer can be a window onto a larger
		// pooled allocation, and taking .buffer whole would carry bytes
		// belonging to something else. Copied straight into the input, once.
		@:privateAccess (__input : crossbyte.io.ByteArray.ByteArrayData).__appendView(chunk);
		__input.position = __inputPosition;
		__onData();
	}
	#end

	#if !nodejs
	/**
		Starts the connect. An address is connected to at once; a name is
		looked up off the runtime's thread first (see `Resolver`), so no
		socket or timer on the runtime waits for the resolver. The tick waits
		for the answer as it waits for the connect, under the same deadline.
	**/
	private function __connect():Void {
		if (!Resolver.needsLookup(__host)) {
			__connectTo(null);
			return;
		}

		__resolving = true;
		var asked:FlexSocket = __socket;
		Resolver.resolve(__host, function(resolved:Null<Host>, failure:Null<String>):Void {
			if (__socket != asked || !__resolving) {
				return;
			}
			__resolving = false;

			if (resolved == null) {
				// Reported by the tick, as a connect that failed at once is.
				__connectFailure = __host + " did not resolve (" + failure + ")";
				return;
			}
			__connectTo(resolved);
		});
	}

	private function __connectTo(resolved:Null<Host>):Void {
		try {
			__socket.setBlocking(false);
			__socket.setFastSend(true);
			__socket.connectHost(resolved != null ? resolved : new Host(__host), __port);
		} catch (e:Dynamic) {
			// A connect in progress reports itself as a block, which is the
			// ordinary case: the tick waits for it to finish. Anything else is
			// a connect that has already failed, reported now rather than left
			// for the tick to wait out the timeout for a connection that could
			// never come.
			if (!BlockedError.isBlocked(e)) {
				__connectFailure = Std.string(e);
				return;
			}
		}

		// Watched in the poll set, so the connect is taken up as soon as the
		// system finishes it, as crossbyte.net.Socket's is, rather than at
		// the next frame. For reading too, which is where a refused connect
		// is reported on Windows. The tick stays, for the deadline.
		if (__runtime != null && __socket != null) {
			__dialing = true;
			__socket.custom = this;
			@:privateAccess __runtime.registerSocket(__socket);
			@:privateAccess __runtime.watchWritable(__socket);
			__registered = true;
		}
	}

	private function __onTickConnect(e:Event):Void {
		if (__connectFailure != null) {
			var failure:String = __connectFailure;
			__connectFailure = null;
			__onError("Failed to connect to server: " + failure);
			__close(1006);
			return;
		}

		if (__resolving) {
			// No connect to ask about until the name is looked up. A resolver
			// that never answers does not outlast the connect's deadline.
			return;
		}

		if (!__connected && !__handshaking) {
			#if (java || jvm)
			// Settled by whichever select reached it first (the runtime's
			// poll as often as the one below), and that one filed the reason
			// on the socket. NIO closes a channel whose connect failed, so a
			// select after it finds nothing, and the refusal is read from
			// here rather than waiting for the deadline.
			var settled:Null<String> = (cast __socket : sys.net.Socket).__connectFailure;
			if (settled != null) {
				__onError("Failed to connect to server: " + settled);
				__close(1006);
				return;
			}
			#end

			// Asked about the exception set too: a refused connect is
			// reported there on Windows and never becomes writable, so it
			// would sit here until the deadline.
			var sockets = FlexSocket.select(null, [__socket], [__socket], 0);

			#if cpp
			// Writable is not connected: POSIX makes a refused connect
			// writable too, so on Linux and macOS a refusal must not be
			// taken for a connection and sent its upgrade request. See
			// Socket's tick.
			if (sockets.write[0] == __socket) {
				var refused:Null<String> = crossbyte._internal.net.NativeSocketAddress.connectError(__socket);
				if (refused != null) {
					__onError("Failed to connect to server: " + refused);
					__close(1006);
					return;
				}
			}
			#end

			if (sockets.write[0] == __socket) {
				__onConnect();
			} else if (sockets.others != null && sockets.others[0] == __socket) {
				// Refused. The deadline is the connect's own, armed with it.
				//
				// The reason first, then the close, so a listener that tears
				// down on close has already been told why, and the system's
				// reason, where it gave one.
				var reason:Null<String> = null;
				#if cpp
				if (sockets.others != null && sockets.others[0] == __socket) {
					reason = crossbyte._internal.net.NativeSocketAddress.connectError(__socket);
				}
				#elseif (java || jvm)
				reason = (cast __socket : sys.net.Socket).__connectFailure;
				#end
				__onError(reason != null ? "Failed to connect to server: " + reason : "Failed to connect to server");
				__close(1006);
			}
		}
	}

	// The registry's calls.

	public var registryClosed(get, never):Bool;

	private function get_registryClosed():Bool {
		return __socket == null || readyState == CLOSED;
	}

	/**
	 * The socket is readable: read what is there.
	 *
	 * Read only when the registry reports something to read: polled from
	 * the tick, every idle session would make a receive that found nothing
	 * every tick, and on hxcpp an exception to say so. The registry polls
	 * every socket at once and calls only the ones with something to read.
	 */
	public function registryOnReadable():Void {
		#if !nodejs
		// A connect or a TLS handshake still in flight is stepped rather than
		// read, so a connect does not wait for the next frame, nor a handshake
		// a frame per round trip.
		if (__dialing) {
			__onTickConnect(null);
			return;
		}
		if (__handshaking) {
			__onTickSSLHandshake(null);
			return;
		}
		#end
		__readAvailable();
	}

	/** A write that could not finish is retried. **/
	public function registryOnWritable():Void {
		__writeQueued = false;
		#if !nodejs
		if (__dialing) {
			__onTickConnect(null);
			return;
		}
		if (__handshaking) {
			__onTickSSLHandshake(null);
			return;
		}
		#end
		__flushPendingOutput();
	}

	/**
	 * Whether the TLS layer holds decrypted bytes the kernel no longer has.
	 * Only the jvm's can (see `Socket.registryHasBufferedInput`), and it is
	 * asked through its type, not dynamically, since the registry asks every
	 * TLS session on every pump.
	 */
	#if (java || jvm)
	// The socket `__jvmTls` was cast from, and what the cast gave.
	@:noCompletion private var __jvmTlsOf:FlexSocket = null;
	@:noCompletion private var __jvmTls:crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket = null;
	#end

	public function registryHasBufferedInput():Bool {
		#if (java || jvm)
		if (!__tls || __socket == null) {
			return false;
		}

		// Cast once per socket rather than once per pump: an `instanceof`
		// and a checked cast, per TLS session, for every pass of the loop.
		if (__jvmTlsOf != __socket) {
			__jvmTlsOf = __socket;
			__jvmTls = Std.downcast((__socket : sys.net.Socket), crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket);
		}
		var tls = __jvmTls;
		if (tls == null) {
			return false;
		}
		return try {
			tls.hasBufferedInput();
		} catch (e:Dynamic) {
			false;
		}
		#else
		return false;
		#end
	}

	/**
	 * Reads everything the socket has, then hands it to the framing layer.
	 */
	private function __readAvailable():Void {
		var doClose:Bool = false;
		var totalBytes:Int = 0;
		// The shared per-thread read buffer `Socket` reads into, rather than a
		// buffer per session: nothing is dispatched between a read and the
		// append that follows it, so nothing can re-enter and find it changed.
		var scratch:Bytes = @:privateAccess crossbyte.net.Socket.__scratch();

		// Appended in place, and the cursor put back afterwards, as `Socket`
		// does, with no copy of each read into a buffer of its own first.
		__input.position = __input.length;

		while (__connected && __socket != null) {
			try {
				var nBytes:Int = __socket.input.readBytes(scratch, 0, scratch.length);
				if (nBytes <= 0) {
					break;
				}
				totalBytes += nBytes;
				__inputRoom(nBytes);
				// As Bytes, as Socket's read does: writeBytes takes a ByteArray,
				// which would have to be made around the scratch every read.
				@:privateAccess (__input : ByteArrayData).__writeRange(scratch, 0, nBytes);

				// An opening handshake already past what this side reads of
				// one is not read further: the parse refuses it next, and
				// what is in the kernel is not this session's to hold.
				if (readyState == CONNECTING && maxHeaderSize > 0 && __input.length > maxHeaderSize) {
					break;
				}

				// A pass's share, as Socket's (see READ_BUDGET there): what
				// is left stays in the kernel, which reports the socket
				// readable again next pass, so a peer sending faster than
				// this parses cannot hold the runtime here, every timer and
				// every other socket waiting on it. TLS stops here too: a
				// read takes a whole record into a buffer larger than any,
				// so mbedTLS is left holding nothing select cannot see, and
				// the jvm's engine, which can hold more, is asked about it
				// before every select.
				if (totalBytes >= @:privateAccess crossbyte.net.Socket.READ_BUDGET) {
					// And the loop is told, so the rest is read before it
					// waits rather than after.
					if (__runtime != null) {
						@:privateAccess __runtime.__noteMoreToRead();
					}
					break;
				}

				#if !eval
				// A read shorter than the buffer has drained the socket, so it
				// ends here, as Socket's does, rather than reading on until the
				// socket says it would block: a system call that reads nothing
				// on every arrival, answered with an exception hxcpp throws and
				// this catches, would be a third of an echoing server's time.
				// TLS reads on: mbedTLS holds plaintext select cannot see (see
				// below).
				if (!__tls && nBytes < scratch.length) {
					break;
				}
				#end

				#if eval
				// eval's setBlocking is a no-op (see the vendored
				// sys.net.Socket), so this drain loop cannot rely on an empty
				// read raising Blocked: with a blocking descriptor that read
				// would park the whole runtime thread until the peer sends
				// more or closes.
				//
				// A read shorter than the buffer already proves the socket is
				// drained, so it exits without asking the kernel anything.
				// Only a read that filled the buffer is ambiguous, and only
				// that case pays for a zero-timeout select.
				if (nBytes < scratch.length) {
					break;
				}

				// TLS keeps reading until a short read. A select on the raw
				// descriptor sees the socket, not the session: mbedtls decrypts
				// whole records into its own buffer, so plaintext waiting there
				// is invisible to select and gating on it would strand a fully
				// received message. The probe sits inside the try on purpose: a
				// select failure on a dying socket lands in the catches below and
				// closes the session, the same as a failed read.
				if (!__tls && FlexSocket.select([__socket], [], [], 0).read.length == 0) {
					break;
				}
				#end
			} catch (e:Error) {
				if (!BlockedError.isBlocked(e)) {
					doClose = true;
				}
				break;
			} catch (e:Eof) {
				// A clean TCP FIN. The peer went away without sending a close
				// frame, which is ordinary (a closed tab, a dropped mobile
				// connection), and is reported as 1006 below, not logged as a
				// failure.
				doClose = true;
				break;
			} catch (e:Dynamic) {
				Logger.warn('WebSocket read failed, closing session: $e');
				doClose = true;
				break;
			}
		}

		__input.position = __inputPosition;

		// Keyed on what was actually read, not on how the loop ended: a loop
		// that ended at the peer's disconnect still delivers what came before
		// it.
		if (totalBytes > 0) {
			__heard = true;
			__onData();
		}

		// Deliver before closing rather than instead of closing: the last
		// message sent before a disconnect is exactly the one worth keeping.
		if (doClose && __socket != null) {
			Logger.debug("WebSocket closed by remote host");
			__close(1006);
		}
	}

	/** Asks the registry to retry the pending output on its next pass. **/
	private inline function __queueWritable():Void {
		if (!__writeQueued && __registered && __runtime != null) {
			__writeQueued = true;
			@:privateAccess __runtime.queueWritable(__socket);
		}
	}
	#end

	/**
	 * Whether what is pending can wait for the end of the runtime's pass:
	 * it can when the runtime is already to flush it, or is asked to now.
	 * Only on the runtime's own thread, whose list of what to flush is not
	 * shared; a send from any other goes at once.
	 */
	private function __holdForPass():Bool {
		if (__passFlushQueued) {
			return true;
		}
		var runtime:CrossByte = __runtime;
		if (runtime == null || @:privateAccess runtime.__didExit) {
			return false;
		}
		var current:CrossByte = null;
		try {
			// Throws on a thread no runtime is attached to.
			current = CrossByte.current();
		} catch (_:Dynamic) {}
		if (current != runtime) {
			return false;
		}
		__passFlushQueued = true;
		runtime.__queuePassFlush(this);
		return true;
	}

	/** The runtime's call at the end of a pass: what the pass sent goes now. **/
	@:noCompletion public function __flushPass():Void {
		__passFlushQueued = false;
		__flushPendingOutput();
	}

	private function __doHandshake():Void {
		var headers:Array<String> = [
			'GET ${__path} HTTP/1.1',
			// Bracketed when it is an IPv6 literal, as RFC 3986 writes one.
			'Host: ${WebSocketHost.forUrl(__host)}:${__port}',
			'Pragma: no-cache',
			'Cache-Control: no-cache',
			'Upgrade: websocket',
			'Sec-WebSocket-Version: 13',
			'Connection: Upgrade',
			"Sec-WebSocket-Key: " + __key,
			'Origin: ${__origin}',
			'User-Agent: Mozilla/5.0'
		];

		if (__protocols != null && __protocols.length > 0) {
			headers.insert(5, 'Sec-WebSocket-Protocol: ' + __protocols.join(', '));
		}

		if (perMessageDeflate) {
			// Without context takeover either way, which a server must
			// agree to or refuse: this side inflates each message on its own.
			headers.push('Sec-WebSocket-Extensions: $PERMESSAGE_DEFLATE; $DEFLATE_PARAMETERS');
		}

		var handshakeBytes:Bytes = Bytes.ofString(headers.join(CRLF) + CRLFCRLF);

		__writeBytes(handshakeBytes);
	}

	private function __writeBytes(bytes:Bytes):Void {
		if (bytes == null || bytes.length == 0) {
			return;
		}

		__queueOutput(ByteArray.fromBytes(bytes), bytes.length);
	}

	/**
		Room in what waits to be sent for `count` more bytes, from storage the
		runtime keeps (`StoragePool`) once that reaches `KEEP`, what has been
		sent dropped from its front as it grows; natively and on the jvm. See
		`Socket.__growOutput`.
	**/
	private inline function __pendingRoom(count:Int):Void {
		#if ((cpp || jvm) && !macro)
		var data:ByteArrayData = __pendingOutput;
		var needed:Int = data.position + count;
		if (needed > @:privateAccess data.__length && needed >= KEEP && __runtime != null) {
			__growPending(count);
		}
		#end
	}

	#if ((cpp || jvm) && !macro)
	private function __growPending(count:Int):Void {
		var data:ByteArrayData = __pendingOutput;
		var sent:Int = __pendingSent;
		var waiting:Int = data.length - sent;
		var capacity:Int = @:privateAccess data.__length;
		var needed:Int = waiting + count;
		if (data.length > __pendingPeak) {
			__pendingPeak = data.length;
		}
		if (sent > 0 && needed <= capacity - (capacity >> 2)) {
			data.blit(0, data, sent, waiting);
			__pendingOutput.length = waiting;
			__pendingOutput.position = waiting;
			__pendingSent = 0;
			return;
		}
		var pool:crossbyte._internal.socket.StoragePool = @:privateAccess __runtime.__storagePool();
		var storage:Null<haxe.io.BytesData> = pool.takeFor(needed > capacity ? needed : capacity + 1, __pendingHint);
		if (storage != null) {
			pool.giveGrown(data.__adoptStorage(storage, sent));
			__pendingSent = 0;
		}
	}
	#end

	/**
		What waits to be sent has all gone: as `__emptied`, but natively and
		on the jvm storage past `KEEP` goes back to the runtime's pool, and 64
		KB of the pool's is kept for the next burst, as `Socket` does.
	**/
	private inline function __emptiedPending():Void {
		#if ((cpp || jvm) && !macro)
		__pendingHint = __hintFor(__pendingOutput, __pendingPeak, __pendingHint);
		__pendingPeak = 0;
		#end
		__emptiedToPool(__pendingOutput);
	}

	/** The input has all been read: as `__emptiedPending`. **/
	private inline function __emptiedInput():Void {
		#if ((cpp || jvm) && !macro)
		__inputHint = __hintFor(__input, __inputPeak, __inputHint);
		__inputPeak = 0;
		#end
		__emptiedToPool(__input);
	}

	#if ((cpp || jvm) && !macro)
	/**
		What a buffer about to empty held at most, `peak` before it last moved
		down, if its storage is past `KEEP` and so goes back to the pool; the
		hint it had (`last`) if not, so small traffic between bursts leaves it.
	**/
	private static inline function __hintFor(buffer:ByteArray, peak:Int, last:Int):Int {
		var data:ByteArrayData = buffer;
		if (@:privateAccess data.__length <= KEEP) {
			return last;
		}
		return data.length > peak ? data.length : peak;
	}
	#end

	/**
		As `__emptied`, but natively and on the jvm storage past `KEEP` goes
		back to the runtime's pool, and 64 KB of the pool's is kept for the
		next burst.
	**/
	private inline function __emptiedToPool(buffer:ByteArray):Void {
		#if ((cpp || jvm) && !macro)
		var data:ByteArrayData = buffer;
		if (@:privateAccess data.__length > KEEP && __runtime != null) {
			var pool:crossbyte._internal.socket.StoragePool = @:privateAccess __runtime.__storagePool();
			buffer.clear();
			pool.give(data.__adoptStorage(pool.take(KEEP), 0));
			return;
		}
		#end
		__emptied(buffer);
	}

	/**
		Room at the end of the input for `count` more bytes, as
		`Socket.__inputRoomFor` makes it: from `KEEP` up, a full input moves
		what is unread down in place if that leaves a quarter of its storage
		spare, and otherwise takes storage of the next size up from the
		runtime's pool, what is unread carried to its front; natively and on
		the jvm. The input's position is left where the next byte goes.
	**/
	private inline function __inputRoom(count:Int):Void {
		#if ((cpp || jvm) && !macro)
		var data:ByteArrayData = __input;
		if (data.length + count > @:privateAccess data.__length && data.length - __inputPosition + count >= KEEP && __runtime != null) {
			__growInput(count);
		}
		#end
	}

	#if ((cpp || jvm) && !macro)
	private function __growInput(count:Int):Void {
		var data:ByteArrayData = __input;
		// The opening handshake's head is searched by where its bytes lie, so
		// nothing is moved under it.
		var from:Int = readyState == CONNECTING ? 0 : __inputPosition;
		var unread:Int = data.length - from;
		var capacity:Int = @:privateAccess data.__length;
		var needed:Int = unread + count;
		if (data.length > __inputPeak) {
			__inputPeak = data.length;
		}
		if (from > 0 && needed <= capacity - (capacity >> 2)) {
			data.blit(0, data, from, unread);
			__input.length = unread;
		} else {
			// The next size up at least, and what it held at most in its last
			// burst, as `Socket.__growOutput` takes.
			var pool:crossbyte._internal.socket.StoragePool = @:privateAccess __runtime.__storagePool();
			var storage:Null<haxe.io.BytesData> = pool.takeFor(needed > capacity ? needed : capacity + 1, __inputHint);
			if (storage == null) {
				// Past the largest size the pool keeps: grown as it would be
				// without one.
				return;
			}
			pool.giveGrown(data.__adoptStorage(storage, from));
		}
		__input.position = __input.length;
		__inputPosition = 0;
	}

	/**
		Room in the session's own message buffer for `length` bytes in all,
		past `KEEP` from the runtime's pool, what it holds carried across; as
		`Arrivals.room` otherwise. The storage goes back once the message has
		been handed out (`__delivered`).
	**/
	private inline function __messageRoom(message:ByteArray, length:Int, last:Bool):Void {
		var data:ByteArrayData = message;
		if (length > KEEP && length > @:privateAccess data.__length && message == __messageKept && __runtime != null) {
			var pool:crossbyte._internal.socket.StoragePool = @:privateAccess __runtime.__storagePool();
			var storage:Null<haxe.io.BytesData> = pool.take(length);
			if (storage != null) {
				pool.give(data.__adoptStorage(storage, 0));
			}
		}
		Arrivals.room(message, length, last);
	}
	#end

	/**
	 * Appends `bytes` to the pending buffer, to go to the socket when the
	 * runtime's pass ends.
	 *
	 * Everything written by this session goes through here so that a
	 * partially-accepted or momentarily-full socket retains the remainder
	 * instead of losing it.
	 *
	 * What a pass sends a session goes in one write as the pass ends (every
	 * message a handler sends, a timer's, a tick's), not a write per frame,
	 * so a server relaying a chat room's messages to everyone in it makes
	 * one system call per member a pass rather than one per message.
	 * Nothing waits past the pass: the loop flushes before it polls again,
	 * and on Node a pass is a turn of its event loop. What has been held goes
	 * at once when it reaches 64 KB, and on native a frame that size goes
	 * straight from where it was built; so does everything where no pass is
	 * coming (no runtime, one that has exited, or a send from another
	 * thread than the session's runtime).
	 */
	private function __queueOutput(data:ByteArray, length:Int):Void {
		if (data != null && length > 0 && __socket != null) {
			var pending:Int = __pendingOutput.length - __pendingSent;
			#if !nodejs
			// The socket is full and the registry will say when it has room:
			// added to what waits, and not offered until then, so a peer reading
			// nothing does not cost a refused write and an exception per frame.
			if (__writeQueued && pending > 0) {
				__pendingOutput.position = __pendingOutput.length;
				__pendingRoom(length);
				__pendingOutput.writeBytes(data, 0, length);
				var waiting:Int = pending + length;
				if (maxOutputBufferSize > 0 && waiting > maxOutputBufferSize) {
					__overflow(waiting);
				}
				return;
			}
			// Nothing queued ahead of it, and too large to be worth holding, so it
			// is offered to the socket straight from where it was built, and only
			// what the socket does not take is copied into the pending buffer.
			if (pending <= 0 && length >= PASS_BATCH) {
				var accepted:Int = __offer(data, 0, length);
				if (accepted < 0) {
					__close(1006, null);
					return;
				}
				if (accepted >= length) {
					return;
				}

				__pendingOutput.clear();
				__pendingSent = 0;
				__pendingRoom(length - accepted);
				__pendingOutput.writeBytes(data, accepted, length - accepted);
				__afterPartialWrite();
				return;
			}
			#end
			__pendingOutput.position = __pendingOutput.length;
			__pendingRoom(length);
			__pendingOutput.writeBytes(data, 0, length);
			if (pending + length < PASS_BATCH && __holdForPass()) {
				return;
			}
			__flushPendingOutput();
			return;
		}

		if (data != null && length > 0) {
			__pendingOutput.position = __pendingOutput.length;
			__pendingOutput.writeBytes(data, 0, length);
		}

		__flushPendingOutput();
	}

	#if !nodejs
	/**
		Offers `length` bytes of `buffer` from `offset` to the socket. Answers
		how many it took (0 when it had no room), or -1 if the write failed.

		Written until the socket will take no more, not once: a TLS socket
		takes one record a write, so a single write would send 16 KB a pass
		whatever room the kernel had.
	**/
	private function __offer(buffer:ByteArray, offset:Int, length:Int):Int {
		var accepted:Int = 0;
		try {
			while (accepted < length) {
				var took:Int = __socket.output.writeBytes(buffer, offset + accepted, length - accepted);
				if (took <= 0) {
					break;
				}
				accepted += took;
			}
			__socket.output.flush();
		} catch (e:Dynamic) {
			// One predicate for every spelling: the typed error, the
			// debugger's Custom wrapper, and the bare string the TLS layer
			// raises before anything maps it. A block keeps whatever the
			// write had already taken.
			if (!BlockedError.isBlocked(e)) {
				return -1;
			}
		}
		if (accepted > 0) {
			bytesSent += accepted;
			if (onprogress != null) {
				onprogress();
			}
		}
		return accepted;
	}
	#end

	/**
	 * Pushes as much of the pending buffer as the socket will accept.
	 *
	 * A non-blocking socket signals "no room right now" by accepting fewer
	 * bytes than offered or by raising a blocked error. Neither is fatal
	 * and neither may discard data: the unsent remainder is kept and
	 * retried from the registry's writable queue. Only a genuine I/O failure
	 * closes the session.
	 *
	 * What the socket took is stepped over rather than cut off, so a peer
	 * reading slowly behind a large backlog does not cost a copy of the
	 * whole backlog per write. The buffer is compacted only once what has
	 * gone is past the threshold and at least as large as what remains, so
	 * moving the rest down costs no more than the writes that emptied the
	 * front.
	 */
	private function __flushPendingOutput():Void {
		var pending:Int = __pendingOutput == null ? 0 : __pendingOutput.length - __pendingSent;
		if (__socket == null || pending <= 0) {
			return;
		}

		#if nodejs
		// Node takes everything and buffers what it cannot send yet, so there
		// is no partial accept to carry over.
		//
		// Copied into a buffer of its own first. `Buffer.hxFromBytes` wraps
		// the storage it is given rather than copying it, and `__pendingOutput`
		// is cleared and refilled by the very next frame (`clear()` resets
		// the length and keeps the array), so handing Node a window onto it
		// would let the next frame overwrite the one still queued for sending.
		var frame:ByteArray = new ByteArray();
		frame.writeBytes(__pendingOutput, __pendingSent, pending);
		// A write carrying the end of the last answer to a ping tells this
		// side when it has gone, so the answer kept for a newer ping can
		// follow it; see __answerPing.
		var written:Null<Void->Void> = onprogress;
		if (__pongOwed || (__pongUntil > bytesSent && __pongUntil <= bytesSent + pending)) {
			if (__pongWritten == null) {
				__pongWritten = __onPongWritten;
			}
			written = __pongWritten;
		}
		try {
			__socket.write(Buffer.hxFromBytes(frame), null, written);
		} catch (e:Dynamic) {
			__close(1006, null);
			return;
		}
		bytesSent += pending;
		__emptiedPending();
		__pendingSent = 0;

		// So a peer that is not reading shows in Node's own queue, and the
		// limit is measured there.
		if (maxOutputBufferSize > 0 && __socket != null && __socket.writableLength > maxOutputBufferSize) {
			if (__overflow(__socket.writableLength)) {
				return;
			}
		}

		// A close that was waiting for this to go: Node has it now, and sends
		// it ahead of the end. A frame held for the turn can still be pending
		// when the closing handshake finishes.
		if (__closeWhenDrained) {
			__close(__drainedCode, __drainedReason);
		}
		#else
		var accepted:Int = __offer(__pendingOutput, __pendingSent, pending);
		if (accepted < 0) {
			__close(1006, null);
			return;
		}

		if (accepted >= pending) {
			// Emptied, and past KEEP its storage let go, so what a backlog grew
			// it to is not kept for the rest of the session.
			__emptiedPending();
			__pendingSent = 0;

			// A close that was waiting for this to go.
			if (__closeWhenDrained) {
				__close(__drainedCode, __drainedReason);
				return;
			}
			// And an answer to a ping that was waiting for the last.
			if (__pongOwed) {
				__settlePong();
			}
			return;
		}

		__pendingSent += accepted;
		var remaining:Int = pending - accepted;
		if (__pendingSent >= OUTPUT_COMPACT_THRESHOLD && __pendingSent >= remaining) {
			#if ((cpp || jvm) && !macro)
			// Moved down within the buffer: hxcpp's blit is a memmove where the
			// ranges overlap, and Java's arraycopy is defined for them, so a
			// peer reading behind a backlog makes no new buffer each time.
			var data:ByteArrayData = __pendingOutput;
			if (data.length > __pendingPeak) {
				__pendingPeak = data.length;
			}
			data.blit(0, data, __pendingSent, remaining);
			__pendingOutput.length = remaining;
			__pendingOutput.position = remaining;
			#else
			// Elsewhere copied into a new buffer: a blit whose source and
			// destination overlap is not defined on every target.
			var carried:ByteArray = new ByteArray();
			carried.endian = BIG_ENDIAN;
			carried.writeBytes(__pendingOutput, __pendingSent, remaining);
			__pendingOutput = carried;
			#end
			__pendingSent = 0;
		}
		__afterPartialWrite();
		// What the socket took may have been the last answer to a ping.
		if (accepted > 0 && __pongOwed) {
			__settlePong();
		}
		#end
	}

	#if !nodejs
	/**
	 * What is left once the socket has taken only part of what it was
	 * offered: bounded, and retried when the socket can take more.
	 */
	private function __afterPartialWrite():Void {
		// Only a peer that is not draining can push the buffer past its
		// limit, and it will not recover on its own.
		var waiting:Int = __pendingOutput.length - __pendingSent;
		if (maxOutputBufferSize > 0 && waiting > maxOutputBufferSize && __overflow(waiting)) {
			return;
		}

		__queueWritable();
	}
	#end

	/**
		`waiting` bytes are past `maxOutputBufferSize`: the owner's
		`onoverflow` says whether the session closes, and when it does the
		owner hears why first, and what was waiting is thrown away rather
		than left queued for a peer that is not reading. Answers whether it
		closed.
	**/
	private function __overflow(waiting:Int):Bool {
		var owner = __owner;
		if (owner != null) {
			if (!@:privateAccess owner.__overflowCloses()) {
				return false;
			}
		} else if (onoverflow != null && !onoverflow()) {
			return false;
		}

		__pendingOutput.clear();
		__pendingSent = 0;
		__discardOnClose = true;
		__onError('WebSocket output buffer reached $waiting bytes, exceeding the $maxOutputBufferSize byte limit; the peer is not reading.');
		__close(1011, "output buffer limit exceeded");
		return true;
	}

	// Answering pings.

	// What the socket will have taken, counted as `bytesSent` counts, once
	// the last answer to a ping has gone; 0 before the first. And the
	// payload of the newest ping since, still owed an answer, with whether
	// one is.
	private var __pongUntil:Float = 0;
	private var __pongOwed:Bool = false;
	private var __pongNext:ByteArray = null;

	/**
		Answers a ping, or, while the answer to an earlier one has not yet
		gone, keeps this one's payload to answer once it has, in place of
		any kept before it.

		RFC 6455 5.5.3 allows exactly this: a pong for only the most recent
		ping, where pings arrive faster than they can be answered. So the
		answers a session owes are never more than two (one going, one
		kept, at most 125 bytes) however many pings arrive; and the last
		ping is always the one last answered. libwebsockets answers so.

		A pong for every ping would let a peer sending pings and reading
		nothing pile them up without end (32 MB of pongs in 10 s natively,
		each written as a frame and offered to a full socket), holding every
		other session on its runtime. HTTP/2 meets the same flood with a
		budget of replies over a window (`maxControlReplies`) and closes past
		it, because it must answer every PING; WebSocket need not, so nothing
		here has to be closed or tuned.
	**/
	private function __answerPing(payload:ByteArray):Void {
		if (__pongUnsent()) {
			var next:ByteArray = __pongNext;
			if (next == null) {
				next = __pongNext = new ByteArray();
				next.endian = BIG_ENDIAN;
			}
			next.length = 0;
			if (payload.length > 0) {
				next.writeBytes(payload, 0, payload.length);
			}
			next.position = 0;
			__pongOwed = true;
			return;
		}
		__pongOwed = false;
		__sendPong(payload);
	}

	/** Sends a pong answering a ping, and notes where it ends. **/
	private function __sendPong(payload:ByteArray):Void {
		__sendFrame(payload, WebSocketOpcode.PONG, true);
		__pongUntil = bytesSent + ownPending;
	}

	/** Whether the last answer to a ping is still waiting to go. **/
	private function __pongUnsent():Bool {
		if (__pongUntil <= 0 || __socket == null) {
			return false;
		}
		#if nodejs
		// Node's queue is the backlog: what it still holds has not gone.
		return bytesSent - __socket.writableLength < __pongUntil;
		#else
		return bytesSent < __pongUntil;
		#end
	}

	/**
		The answer kept for the newest ping goes, once the one before it has:
		told when the socket takes more.
	**/
	private function __settlePong():Void {
		if (__pongOwed && readyState == OPEN && !__pongUnsent()) {
			__pongOwed = false;
			__sendPong(__pongNext);
		}
	}

	#if nodejs
	// What Node is asked to call once a write carrying an answer to a ping
	// has gone; see __flushPendingOutput. Made once.
	private var __pongWritten:Null<Void->Void> = null;

	private function __onPongWritten():Void {
		var progress = onprogress;
		if (progress != null) {
			progress();
		}
		__settlePong();
	}
	#end

	private function __handleControlFrame(opcode:WebSocketOpcode, payload:ByteArray):Void {
		switch (opcode) {
			case PING:
				// A ping is answered in any state but closed: a peer waiting on
				// the close handshake may still be checking this side is there.
				__answerPing(payload);
			case PONG:
				__hasTimeoutPotential = false;
			case CLOSE:
				var code:Int = 1000;
				var reason:String = null;
				if (payload.length == 1) {
					// A close frame carrying a body must contain at least a 2-byte code.
					__fail(1002);
					return;
				}
				if (payload.length >= 2) {
					code = (payload[0] << 8) | payload[1];
					if (!__isValidCloseCode(code)) {
						__fail(1002);
						return;
					}
					if (payload.length > 2) {
						if (!__isValidUTF8(payload, 2, payload.length - 2)) {
							__fail(1007);
							return;
						}
						payload.position = 2;
						reason = payload.readUTFBytes(payload.length - 2);
					}
				}

				if (readyState == OPEN) {
					// The peer began it. Its code goes back, as RFC 6455 5.5.1
					// asks, and the connection closes once that has gone.
					__sendFrame(payload, WebSocketOpcode.CLOSE, true);
					readyState = CLOSING;
				}

				// Either the peer began it or this is its answer to ours. What
				// is reported is the peer's code and reason either way (what
				// it said about why), which is what a browser reports too.
				__finishClose(code, reason);
		}
	}

	private function __onData():Void {
		if (__refusing) {
			// An upgrade refused: nothing the peer sends after it is anything
			// this side will act on, and it goes rather than piling up while
			// the answer drains.
			__input.clear();
			__inputPosition = 0;
			return;
		}
		if (readyState == OPEN || readyState == CLOSING) {
			while (__input.bytesAvailable > 0) {
				var frameStart:Int = __input.position;
				if (__input.bytesAvailable < 2) {
					__input.position = frameStart;
					break;
				}

				var firstByte:Int = __input.readUnsignedByte();
				var isFinal:Bool = (firstByte & 0x80) != 0;
				var opCode:Int = firstByte & 0x0F;

				var secondByte:Int = __input.readUnsignedByte();
				var isMasked:Bool = (secondByte & 0x80) != 0;
				var payloadLength:Int = secondByte & 0x7F;

				// RSV1 marks a compressed message: only where permessage-deflate
				// was agreed, and only on the first frame of a data message,
				// never a continuation, never a control frame (RFC 7692 6).
				var reserved:Int = firstByte & (WebSocketHeaderMask.RSV1 | WebSocketHeaderMask.RSV2 | WebSocketHeaderMask.RSV3);
				if (reserved != 0
					&& (reserved != WebSocketHeaderMask.RSV1
						|| !__deflate
						|| opCode == WebSocketOpcode.CONTINUATION
						|| opCode >= WebSocketOpcode.CLOSE)) {
					__fail(1002);
					return;
				}

				// A server MUST reject unmasked frames from a client (RFC 6455 5.1).
				if (__isClient == false && !isMasked) {
					__fail(1002);
					return;
				}

				if (payloadLength == 126) {
					if (__input.bytesAvailable < 2) {
						__input.position = frameStart;
						break;
					}
					payloadLength = __input.readUnsignedShort();
				} else if (payloadLength == 127) {
					if (__input.bytesAvailable < 8) {
						__input.position = frameStart;
						break;
					}
					var high:Int = __input.readUnsignedInt();
					var low:Int = __input.readUnsignedInt();
					if (high != 0 || low < 0) {
						__fail(1009);
						return;
					}
					payloadLength = low;
				}

				// A frame is refused on its header alone, before the wait below for a
				// payload that may never arrive, so ten bytes claiming a two-gigabyte
				// length cannot put the session into a wait for a frame it would
				// refuse once it completed. A data frame is held to what is left of
				// its message under maxMessageSize, so nothing waits for more than a
				// message.
				var isControl:Bool = opCode >= WebSocketOpcode.CLOSE;
				if (isControl && (!isFinal || payloadLength > 125)) {
					__fail(1002);
					return;
				}
				if (!isControl) {
					var limit:Int = maxMessageSize;
					// A continuation adds to the message under way; with none
					// under way it is refused below, as a protocol error.
					var before:Int = opCode == WebSocketOpcode.CONTINUATION && __incomingOpcode != -1 ? __incomingMessageSize : 0;
					if (limit > 0 && payloadLength > limit - before) {
						__fail(1009);
						return;
					}
				}

				if (opCode != WebSocketOpcode.CONTINUATION
					&& opCode != WebSocketOpcode.TEXT
					&& opCode != WebSocketOpcode.BINARY
					&& opCode != WebSocketOpcode.CLOSE
					&& opCode != WebSocketOpcode.PING
					&& opCode != WebSocketOpcode.PONG) {
					__fail(1002);
					return;
				}

				var maskBytes:Int = isMasked ? 4 : 0;
				if (__input.bytesAvailable < maskBytes + payloadLength) {
					__input.position = frameStart;
					break;
				}

				// The key is used where it lies in the input rather than
				// copied into a buffer made for it, one per frame.
				var keyAt:Int = __input.position;
				if (isMasked) {
					__input.position = keyAt + 4;
				}

				if (isControl) {
					// At most 125 bytes, into one buffer the session keeps for
					// them: nothing hands a control frame's payload out (a ping's
					// is copied into its answer, a close's read in the call), so a
					// peer sending a stream of pings makes no buffer for each.
					var control:ByteArray = __control;
					if (control == null) {
						control = __control = new ByteArray();
						control.endian = BIG_ENDIAN;
					}
					control.length = payloadLength;
					control.position = 0;
					if (payloadLength > 0) {
						__input.readBytes(control, 0, payloadLength);
					}
					if (isMasked) {
						__applyMask(control, payloadLength, __input, keyAt, 0);
					}
					control.position = 0;
					__handleControlFrame(opCode, control);
					__validateInputPosition();
					if (opCode == WebSocketOpcode.CLOSE || readyState == CLOSED) {
						return;
					}
					continue;
				}

				if (opCode == WebSocketOpcode.CONTINUATION) {
					if (__incomingOpcode == -1) {
						__fail(1002);
						return;
					}
				} else {
					if (__incomingOpcode != -1) {
						__fail(1002);
						return;
					}
					__incomingOpcode = opCode;
					// Start of a new message: reset the cumulative size counter.
					// Done here (not via a field initializer) so the counter is
					// always valid even when the parser is constructed without
					// running field initializers.
					__incomingMessageSize = 0;
					__incomingCompressed = reserved != 0;
				}

				// What the message has come to, held to maxMessageSize on each
				// frame's header above.
				__incomingMessageSize += payloadLength;

				// Read straight into the message the frame belongs to, unmasked
				// where it lands: a message's first frame takes the buffer it
				// is read into (__takeMessage), and each after it is appended,
				// with no ByteArray made for each frame.
				if (opCode != WebSocketOpcode.CONTINUATION) {
					__incomingMessageBuffer = __takeMessage();
				}
				var message:ByteArray = __incomingMessageBuffer;
				var at:Int = message.length;
				if (payloadLength > 0) {
					#if ((cpp || jvm) && !macro)
					__messageRoom(message, at + payloadLength, isFinal);
					#else
					Arrivals.room(message, at + payloadLength, isFinal);
					#end
					__input.readBytes(message, at, payloadLength);
					if (isMasked) {
						__applyMask(message, payloadLength, __input, keyAt, at);
					}
				}
				message.position = message.length;

				if (isFinal) {
					// Inflated whole, once the last frame is in: the size cap
					// above is on what arrived, and the inflation has a cap
					// of its own on what it may become.
					if (__incomingCompressed && !__inflateIncoming()) {
						return;
					}

					// Validate completed TEXT messages as UTF-8.
					if (__incomingOpcode == WebSocketOpcode.TEXT
						&& !__isValidUTF8(__incomingMessageBuffer, 0, __incomingMessageBuffer.length)) {
						__fail(1007);
						return;
					}
					__dispatchMessage();
					if (readyState == CLOSED) {
						return;
					}
				}

				__validateInputPosition();
			}

			// Once an arrival is parsed, not after every frame of it.
			__compactInput();
		} else if (readyState == CONNECTING) {
			var raw:Bytes = __input;
			var start:Int = __input.position;
			// Searched from where the last arrival's search stopped, less the
			// three bytes a CRLFCRLF split between arrivals can start in.
			var from:Int = __headScanned - 3;
			if (from < start) {
				from = start;
			}
			var endIndex:Int = __findHeaderEnd(raw, from, __input.length);
			var limit:Int = maxHeaderSize;
			if (endIndex < 0) {
				__headScanned = __input.length;
				// Held where it arrived, as bytes, until the head is whole,
				// rather than moved into a string copied whole with every arrival.
				if (limit > 0 && __input.length - start > limit) {
					__headTooLarge(limit);
				}
				return;
			}
			__headScanned = 0;

			// The whole head has arrived.
			var headerLength:Int = endIndex - start + 4;
			// A head that did end is held to the same limit as one still
			// arriving, as the HTTP server holds its requests.
			if (limit > 0 && headerLength > limit) {
				__headTooLarge(limit);
				return;
			}
			var headerData:String = raw.getString(start, headerLength);
			var extraStart:Int = start + headerLength;
			var extraLength:Int = Std.int(__input.length) - extraStart;
			var extra:Bytes = extraLength > 0 ? raw.sub(extraStart, extraLength) : null;
			var lines:Array<String> = headerData.split(CRLF);
			var headers:StringMap<String>;

			// Read as what the session's role expects: a request on a server,
			// an answer on a client.
			if (__isClient == false) {
				if (lines[0].indexOf(GET) != 0) {
					__refuseUpgrade(400, null);
					return;
				}
				headers = __parseHeaders(lines);
				if (!__acceptUpgrade(lines[0], headers, headerData)) {
					return;
				}
			} else {
				if (lines[0].indexOf(HTTP) != 0) {
					__onError("The server's answer to the WebSocket upgrade was not HTTP: " + lines[0]);
					__close(1006);
					return;
				}
				headers = __parseHeaders(lines);
				if (lines[0].indexOf("101") > -1) {
					headers.set("status", "101");
				} else {
					// A failed connect, as a browser reports one: the
					// answer said, then 1006 (see __close), not 1002 with
					// no error, as if an open session had broken the protocol.
					__onError("The server refused the WebSocket upgrade: " + lines[0]);
					__close(1006);
					return;
				}

				if (__validateResponseHandshake(headers)) {
					// handshake complete, is ready
					__disarmOpenDeadline();
					readyState = OPEN;
					__startHeartbeat();
					__opened();
				} else {
					__onError("The server's answer to the WebSocket upgrade was not valid: " + lines[0]);
					__close(1006);
					return;
				}
			}

			if (readyState == OPEN) {
				// The handshake was parsed with getString, which does not
				// move the cursor, so those bytes are still sitting in the
				// buffer. They have to be dropped explicitly: anything left
				// here is parsed as the start of the first frame, and the
				// 'G' of "GET" (0x47) has RSV1 set, so the peer's first
				// real message would be rejected as a protocol error.
				//
				// And the storage the head was read into goes with them, or a
				// session that opens and says nothing would keep it for good.
				__letGo(__input);
				__inputPosition = 0;

				if (extra != null && extra.length > 0) {
					__appendBytes(__input, extra);
					__input.position = 0;
					__onData();
				}
			}
		}
	}

	/**
		The opening handshake's head has run past `maxHeaderSize`: a server
		session answers 431, as the HTTP server answers a request whose head
		is too large, and a client gives up on a server that will not stop.
	**/
	private function __headTooLarge(limit:Int):Void {
		__headScanned = 0;
		if (__isClient == false) {
			__refuseUpgrade(431, null);
			return;
		}
		__input.clear();
		__inputPosition = 0;
		__onError('The server\'s answer to the WebSocket upgrade ran past $limit bytes without ending (maxHeaderSize).');
		__close(1006);
	}

	/**
	 * A server session's answer to the upgrade request it has just received:
	 * the `101`, or a refusal. Says whether the session opened.
	 *
	 * The request is kept, the owner's `onupgrade` decides on it, and the
	 * subprotocol accepted is echoed: a browser offering a subprotocol that
	 * hears none back fails the connection.
	 */
	private function __acceptUpgrade(requestLine:String, headers:StringMap<String>, ?head:String):Bool {
		if (!__validateRequestHandshake(headers)) {
			// Answered rather than dropped, so a client learns why. A version
			// this side does not speak is answered with the one it does, as
			// RFC 6455 4.4 asks.
			var version:Null<String> = headers.get("sec-websocket-version");
			__refuseUpgrade(400, version != null && version != "13" ? ["Sec-WebSocket-Version: 13"] : null);
			return false;
		}

		__noteEndpoints();
		request = new WebSocketRequest(requestLine, headers, __remoteAddress, __remotePort, head);

		var accepted:Bool = true;
		var hook = onupgrade;
		// Asked once: the hook is let go of here, rather than held for the
		// life of the session with everything it reaches.
		onupgrade = null;
		if (hook != null) {
			try {
				accepted = hook(request);
			} catch (e:Dynamic) {
				// A hook that throws refuses, as `admit` does, and as a
				// server's fault, not the client's.
				Logger.warn('WebSocket upgrade hook threw, refusing the session: $e');
				request.status = 500;
				accepted = false;
			}
		}

		if (!accepted) {
			__refuseUpgrade(request.status, null);
			return false;
		}

		protocol = request.protocol;

		// Compression, where this server allows it and the client offered it
		// on terms this side can keep. Refused, the session goes on without.
		if (perMessageDeflate) {
			var offered:Null<String> = headers.get("sec-websocket-extensions");
			if (offered != null) {
				__acceptDeflateOffer(offered);
			}
		}

		var response:Bytes = __generateResponseHandshake(headers);
		__writeBytes(response);

		readyState = OPEN;
		__startHeartbeat();
		__opened();
		// The server's connect listeners have read the request by now, if
		// they were going to: it keeps its head, and lets the parsed headers
		// go (see WebSocketRequest.__settle).
		if (request != null) {
			@:privateAccess request.__settle();
		}
		return readyState == OPEN;
	}

	/**
	 * Answers an upgrade with a refusal, and closes once the answer has gone.
	 */
	private function __refuseUpgrade(status:Int, extraHeaders:Null<Array<String>>):Void {
		// What the request left, and whatever follows it, is not read on.
		__refusing = true;
		__input.clear();
		__inputPosition = 0;
		var lines:Array<String> = ['HTTP/1.1 $status ${__statusText(status)}', "Connection: close", "Content-Length: 0"];
		if (extraHeaders != null) {
			for (line in extraHeaders) {
				lines.push(line);
			}
		}

		__writeBytes(Bytes.ofString(lines.join(CRLF) + CRLFCRLF));
		readyState = CLOSING;
		__finishClose(1002, "upgrade refused with " + status);
	}

	private static function __statusText(status:Int):String {
		return switch (status) {
			case 400: "Bad Request";
			case 401: "Unauthorized";
			case 403: "Forbidden";
			case 404: "Not Found";
			case 426: "Upgrade Required";
			case 429: "Too Many Requests";
			case 431: "Request Header Fields Too Large";
			case 500: "Internal Server Error";
			case 503: "Service Unavailable";
			default: "Refused";
		}
	}

	private function __findHeaderEnd(bytes:Bytes, start:Int, end:Int):Int {
		var last:Int = end - 3;
		var i:Int = start;
		while (i < last) {
			if (bytes.get(i) == 13 && bytes.get(i + 1) == 10 && bytes.get(i + 2) == 13 && bytes.get(i + 3) == 10) {
				return i;
			}
			i++;
		}
		return -1;
	}

	/**
	 * XORs `length` bytes of `data` from `dataAt` in place with the four-byte
	 * mask at `maskAt` in `mask`: a frame read straight into the message it
	 * belongs to is unmasked where it landed.
	 *
	 * Masking and unmasking are the same operation, so both directions use
	 * this. It runs on `Bytes` rather than through `ByteArray`'s array
	 * access deliberately: that accessor calls `__resize` on every element
	 * write to bounds-check an index this loop already knows is in range,
	 * and on a server this is touched once per inbound byte. This runs at
	 * about twice the speed of a per-byte loop through it.
	 *
	 * Whole 32-bit words are XORed at a time. The key is read with the same
	 * accessor as the data, so both agree on byte order and word `i` lines
	 * up with `mask[(i + j) & 3]` for every offset that is a multiple of
	 * four, which is why only the trailing bytes need the scalar loop.
	 * (Word `i` is counted from `dataAt`, so this holds wherever the frame
	 * starts.)
	 */
	private static function __applyMask(data:Bytes, length:Int, mask:Bytes, maskAt:Int, dataAt:Int):Void {
		if (length <= 0) {
			return;
		}

		var key:Int = mask.getInt32(maskAt);
		var wordEnd:Int = length & ~3;
		var i:Int = 0;

		while (i < wordEnd) {
			data.setInt32(dataAt + i, data.getInt32(dataAt + i) ^ key);
			i += 4;
		}

		while (i < length) {
			data.set(dataAt + i, data.get(dataAt + i) ^ mask.get(maskAt + (i & 0x03)));
			i++;
		}
	}

	private inline function __appendBytes(target:ByteArray, bytes:Bytes):Void {
		if (bytes.length > 0) {
			target.writeBytes(bytes, 0, bytes.length);
		}
	}

	private inline function __isValidCloseCode(code:Int):Bool {
		// RFC 6455 7.4. The ranges carry the rule, not just the handful of
		// holes inside them: 1000-2999 belongs to the protocol and only the
		// assigned part of it may travel, 3000-3999 is for libraries and
		// 4000-4999 is private. A peer closing with 1016, 2000 or 65535,
		// none of which mean anything, is answered 1002.
		if (code >= 3000 && code <= 4999) {
			return true;
		}
		if (code < 1000 || code > 1014) {
			return false;
		}
		// 1004 was never assigned; 1005 and 1006 are what a local close
		// reports when no code arrived, so neither may appear on the wire.
		// 1015 is the same kind of code and is already past the bound above.
		return code != 1004 && code != 1005 && code != 1006;
	}

	private function __isValidUTF8(bytes:ByteArray, offset:Int, length:Int):Bool {
		var i:Int = offset;
		var end:Int = offset + length;
		while (i < end) {
			var b0:Int = bytes[i];
			if (b0 < 0x80) {
				// 0xxxxxxx
				i++;
			} else if (b0 >= 0xC2 && b0 <= 0xDF) {
				// 110xxxxx 10xxxxxx
				if (i + 1 >= end || (bytes[i + 1] & 0xC0) != 0x80) {
					return false;
				}
				i += 2;
			} else if (b0 == 0xE0) {
				// 11100000 101xxxxx 10xxxxxx (reject overlong)
				if (i + 2 >= end) {
					return false;
				}
				var b1:Int = bytes[i + 1];
				if (b1 < 0xA0 || b1 > 0xBF || (bytes[i + 2] & 0xC0) != 0x80) {
					return false;
				}
				i += 3;
			} else if (b0 >= 0xE1 && b0 <= 0xEC) {
				// 1110xxxx 10xxxxxx 10xxxxxx
				if (i + 2 >= end || (bytes[i + 1] & 0xC0) != 0x80 || (bytes[i + 2] & 0xC0) != 0x80) {
					return false;
				}
				i += 3;
			} else if (b0 == 0xED) {
				// 11101101 100xxxxx 10xxxxxx (reject surrogates)
				if (i + 2 >= end) {
					return false;
				}
				var b1:Int = bytes[i + 1];
				if (b1 < 0x80 || b1 > 0x9F || (bytes[i + 2] & 0xC0) != 0x80) {
					return false;
				}
				i += 3;
			} else if (b0 >= 0xEE && b0 <= 0xEF) {
				// 1110xxxx 10xxxxxx 10xxxxxx
				if (i + 2 >= end || (bytes[i + 1] & 0xC0) != 0x80 || (bytes[i + 2] & 0xC0) != 0x80) {
					return false;
				}
				i += 3;
			} else if (b0 == 0xF0) {
				// 11110000 1001xxxx 10xxxxxx 10xxxxxx (reject overlong)
				if (i + 3 >= end) {
					return false;
				}
				var b1:Int = bytes[i + 1];
				if (b1 < 0x90 || b1 > 0xBF || (bytes[i + 2] & 0xC0) != 0x80 || (bytes[i + 3] & 0xC0) != 0x80) {
					return false;
				}
				i += 4;
			} else if (b0 >= 0xF1 && b0 <= 0xF3) {
				// 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
				if (i + 3 >= end
					|| (bytes[i + 1] & 0xC0) != 0x80
					|| (bytes[i + 2] & 0xC0) != 0x80
					|| (bytes[i + 3] & 0xC0) != 0x80) {
					return false;
				}
				i += 4;
			} else if (b0 == 0xF4) {
				// 11110100 1000xxxx 10xxxxxx 10xxxxxx (cap at U+10FFFF)
				if (i + 3 >= end) {
					return false;
				}
				var b1:Int = bytes[i + 1];
				if (b1 < 0x80 || b1 > 0x8F || (bytes[i + 2] & 0xC0) != 0x80 || (bytes[i + 3] & 0xC0) != 0x80) {
					return false;
				}
				i += 4;
			} else {
				// 0x80-0xBF (stray continuation), 0xC0-0xC1 (overlong), 0xF5-0xFF (out of range)
				return false;
			}
		}
		return true;
	}

	/**
	 * Settles `__input` after a frame: emptied when everything in it has been
	 * read, otherwise the read point is kept, and once what has been read
	 * past is worth moving, the unread tail is moved down, rather than the
	 * whole buffer being kept until a read happens to end on a frame
	 * boundary.
	 */
	private function __validateInputPosition():Void {
		if (__input.bytesAvailable <= 0) {
			__emptiedInput();
			__inputPosition = 0;
			return;
		}

		__inputPosition = __input.position;
	}

	// Memory a session keeps.

	/**
		The most storage a buffer keeps once it has emptied: 64 KB, what a
		pass reads of a socket into it at once and what it batches for one.
		A busy session fills and empties its buffers within that every pass,
		allocating nothing; past it a buffer has held a backlog (a burst
		read in one pass, output behind a peer that stopped reading) and
		lets the storage go as it empties, rather than keeping the largest
		it ever needed, up to the 8 MiB a server lets wait for one peer, for
		as long as the session lasts.
	**/
	private static inline var KEEP:Int = 64 * 1024;

	// What a buffer let go of is given in place of its storage: nothing is
	// ever written into a buffer of no length, so one serves every session.
	private static var __nothing:Null<Bytes> = null;

	/** Empties `buffer`, letting its storage go past `KEEP`. **/
	private static inline function __emptied(buffer:ByteArray):Void {
		buffer.clear();
		if (@:privateAccess (buffer : ByteArrayData).__length > KEEP) {
			__letGo(buffer);
		}
	}

	/** Empties `buffer` and lets its storage go, however little it is. **/
	private static function __letGo(buffer:Null<ByteArray>):Void {
		if (buffer == null) {
			return;
		}
		buffer.clear();
		var data:ByteArrayData = buffer;
		if (@:privateAccess data.__length > 0) {
			var nothing:Null<Bytes> = __nothing;
			if (nothing == null) {
				nothing = __nothing = Bytes.alloc(0);
			}
			@:privateAccess data.__setData(nothing);
		}
	}

	/**
		Lets go of every buffer a session holds between messages, once it has
		been quiet for a beat of its heartbeat: nothing heard, for what it
		reads, and nothing sent, for what it writes. An idle session then
		holds its objects and no storage, rather than what it took in and
		sent before it went quiet, up to `KEEP` a buffer and 16 KB of
		message, for as long as it lasts. A session that is busy is never
		quiet for a beat, so this costs it nothing; one that wakes allocates
		again what its first messages need.
	**/
	private function __trimWhenQuiet(heard:Bool, sent:Bool):Void {
		if (!heard) {
			if (__input != null && __input.length == 0) {
				__letGo(__input);
				__inputPosition = 0;
			}
			// Its storage, not the buffer: the owner's reused event still
			// points at the buffer, emptied, and would keep the storage too.
			if (__incomingOpcode == -1 && !__messageOut) {
				__letGo(__messageKept);
			}
			__control = null;
		}
		if (!sent && ownPending == 0) {
			__letGo(__pendingOutput);
			__pendingSent = 0;
			__letGo(__output);
			__maskedPayload = null;
			if (!__pongOwed) {
				__pongNext = null;
			}
		}
	}

	/**
	 * Moves the unread tail of `__input` down over what has been parsed, in
	 * place, once the parsed part is at least as long as the tail, so no
	 * byte is moved more often than bytes are consumed, and what is moved is
	 * at most the frame still arriving. Copying the whole unread rest of the
	 * input into a new buffer after every frame would make a burst cost the
	 * square of its length.
	 *
	 * A move within one buffer is a blit whose ends overlap, which every
	 * target copies front to back or as if through a temporary: safe moving
	 * down, which is the only way this moves.
	 */
	private function __compactInput():Void {
		var consumed:Int = __input.position;
		if (consumed <= 0) {
			return;
		}

		var remaining:Int = __input.length - consumed;
		if (remaining <= 0) {
			__emptiedInput();
			__inputPosition = 0;
			return;
		}

		if (consumed < remaining) {
			return;
		}

		#if ((cpp || jvm) && !macro)
		if (__input.length > __inputPeak) {
			__inputPeak = __input.length;
		}
		#end
		var raw:Bytes = __input;
		raw.blit(0, raw, consumed, remaining);
		__input.length = remaining;
		__input.position = 0;
		__inputPosition = 0;
	}

	private function __dispatchMessage():Void {
		var message:ByteArray = __incomingMessageBuffer;
		var isText:Bool = __incomingOpcode == WebSocketOpcode.TEXT;
		message.position = 0;
		// The next message's first frame takes a buffer of its own (see
		// __onData), so this one is let go of here.
		__incomingMessageBuffer = null;
		__incomingOpcode = -1;
		__incomingMessageSize = 0;

		var kept:Bool = message == __messageKept;

		// Nothing new is delivered once closing: RFC 6455 has a peer's data
		// after its close frame, or after ours, belong to no one.
		if (readyState != OPEN) {
			if (kept) {
				Arrivals.release(message);
			}
			return;
		}

		// The outermost call that hands the message out: once it returns the
		// message is done with, and whoever keeps it has copied it. The
		// session's own is emptied for the next; one of its own is killed
		// under the check.
		if (kept) {
			__messageOut = true;
		}
		try {
			var owner = __owner;
			var direct = __onMessage;
			if (owner != null) {
				@:privateAccess owner.__messageArrived(message, isText);
			} else if (direct != null) {
				direct(message, isText);
			} else if (onmessage != null) {
				var event = new WebsocketEvent(WebsocketEvent.MESSAGE, this, message);
				event.isText = isText;
				onmessage(event);
			}
		} catch (e:Dynamic) {
			__delivered(message, kept);
			Arrivals.rethrow(e);
		}
		__delivered(message, kept);
	}

	/**
		The buffer a message's first frame is read into: the session's own,
		emptied, unless it is out or reuse is off.
	**/
	private function __takeMessage():ByteArray {
		var message:ByteArray;
		if (Arrivals.REUSE && !__messageOut) {
			message = __messageKept;
			if (message == null) {
				message = __messageKept = new ByteArray();
			} else {
				// All a listener left on it taken back: position, length,
				// byte order and object encoding, as a ByteArray made for the
				// message has them, so one listener reading a JSON message does
				// not make every later message read as JSON.
				Arrivals.reset(message);
			}
		} else {
			message = new ByteArray();
		}
		// The frame's own fields are big-endian; the session reads the
		// message in its own byte order once it is whole.
		message.endian = BIG_ENDIAN;
		return message;
	}

	private inline function __delivered(message:ByteArray, kept:Bool):Void {
		if (kept) {
			#if ((cpp || jvm) && !macro)
			__messageToPool(message);
			#end
			Arrivals.release(message);
			__messageOut = false;
		} else {
			Arrivals.done(message);
		}
	}

	#if ((cpp || jvm) && !macro)
	/** The session's message buffer, handed out and back: its storage past `KEEP` to the runtime's pool. **/
	private inline function __messageToPool(message:ByteArray):Void {
		__letGoToPool(message);
	}

	/**
		Empties `buffer` and gives its storage past `KEEP` back to the runtime's
		pool, keeping none: for a message handed out, and a session's buffers
		as it closes.
	**/
	private function __letGoToPool(buffer:Null<ByteArray>):Void {
		if (buffer == null || __runtime == null) {
			return;
		}
		var data:ByteArrayData = buffer;
		if (@:privateAccess data.__length > KEEP) {
			var nothing:Null<Bytes> = __nothing;
			if (nothing == null) {
				nothing = __nothing = Bytes.alloc(0);
			}
			buffer.length = 0;
			buffer.position = 0;
			@:privateAccess __runtime.__storagePool().give(data.__adoptStorage(nothing.getData(), 0));
		}
	}
	#end

	private function __generateResponseHandshake(headers:StringMap<String>):Bytes {
		var lines:Array<String> = [
			"HTTP/1.1 101 Switching Protocols",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Accept: " + __generateWebSocketAccept(headers.get("sec-websocket-key"))
		];

		// The subprotocol accepted, echoed: a browser that offered one
		// and hears none back fails the connection outright.
		if (protocol != null) {
			lines.push("Sec-WebSocket-Protocol: " + protocol);
		}

		if (__deflate) {
			lines.push("Sec-WebSocket-Extensions: " + extensions);
		}

		return Bytes.ofString(lines.join(CRLF) + CRLFCRLF);
	}

	private function __generateWebSocketAccept(key:String):String {
		var magic:String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
		return Base64.encode(Sha1.make(Bytes.ofString(key + magic)));
	}

	private function __parseHeaders(lines:Array<String>):StringMap<String> {
		return __parseHeaderLines(lines);
	}

	/**
		The header lines of a head, after its first, by lower-cased name: a
		header sent more than once folded into one value. Shared with
		`WebSocketRequest`, which reads its headers again from the head a
		session keeps.
	**/
	@:noCompletion public static function __parseHeaderLines(lines:Array<String>):StringMap<String> {
		var headers:StringMap<String> = new StringMap();

		// Skip the first line, since it contains the request method or status code
		for (i in 1...lines.length) {
			var line:String = lines[i];

			// Check if this is the end of the headers
			if (line == "") {
				break;
			}

			// Split the header into name and value
			var index:Int = line.indexOf(":");
			if (index != -1) {
				var name:String = line.substring(0, index).toLowerCase();
				var value:String = StringTools.trim(line.substring(index + 1));

				// A header sent twice is both its values, folded as HTTP folds
				// them, rather than the second one alone: a client may offer its
				// subprotocols on two lines.
				var earlier:Null<String> = headers.get(name);
				if (earlier != null) {
					value = earlier + (name == "cookie" ? "; " : ", ") + value;
				}

				headers.set(name, value);
			}
		}

		return headers;
	}

	private function __validateRequestHandshake(headers:StringMap<String>):Bool {
		var upgrade:String = headers.get("upgrade");
		var connection:String = headers.get("connection");
		var key:String = headers.get("sec-websocket-key");
		var version:String = headers.get("sec-websocket-version");

		if (upgrade == null || upgrade.toLowerCase() != "websocket") {
			return false;
		}
		if (connection == null || connection.toLowerCase().indexOf("upgrade") == -1) {
			return false;
		}
		if (key == null || key.length == 0) {
			return false;
		}
		if (version != "13") {
			return false;
		}

		return true;
	}

	private function __validateResponseHandshake(headers:StringMap<String>):Bool {
		// Check if the response status code is 101
		if (headers.get("status") != "101") {
			// The server failed to switch protocols, close the connection with code 1002 (protocol error)
			return false;
		}

		// Check if the "Upgrade" header is set to "websocket"
		var upgrade:String = headers.get("upgrade");
		if (upgrade == null || upgrade.toLowerCase() != "websocket") {
			// The server does not support WebSockets, close the connection with code 1002 (protocol error)
			return false;
		}

		// Check if the "Connection" header is set to "Upgrade"
		var connection:String = headers.get("connection");
		if (connection == null || connection.toLowerCase().indexOf("upgrade") == -1) {
			// The server failed to switch protocols, close the connection with code 1002 (protocol error)
			return false;
		}

		// Check if the "Sec-WebSocket-Accept" header matches the expected value
		var expected:String = __generateWebSocketAccept(__key);
		if (headers.get("sec-websocket-accept") != expected) {
			// The server sent an invalid response, close the connection with code 1002 (protocol error)
			return false;
		}

		// A subprotocol the server chose must be one this side asked for (RFC
		// 6455 4.1); choosing none is allowed.
		var chosen:Null<String> = headers.get("sec-websocket-protocol");
		if (chosen != null && chosen != "") {
			if (__protocols == null || __protocols.indexOf(chosen) < 0) {
				return false;
			}
			protocol = chosen;
		}

		// Compression, where this side asked for it and the server agreed,
		// on terms this side can keep, or the connection fails (RFC 7692 5).
		var agreed:Null<String> = headers.get("sec-websocket-extensions");
		if (perMessageDeflate && agreed != null && StringTools.trim(agreed) != "") {
			if (!__takeDeflateAnswer(agreed)) {
				return false;
			}
		}

		return true;
	}

	// permessage-deflate (RFC 7692).

	/**
		The extensions a `Sec-WebSocket-Extensions` value lists, each with its
		parameters, in order; null when the value does not parse, or names a
		parameter twice.
	**/
	private static function __parseExtensions(value:String):Null<Array<{name:String, params:StringMap<Null<String>>}>> {
		var parsed:Array<{name:String, params:StringMap<Null<String>>}> = [];
		for (item in value.split(",")) {
			var parts:Array<String> = item.split(";");
			var name:String = StringTools.trim(parts[0]).toLowerCase();
			if (name == "") {
				return null;
			}

			var params:StringMap<Null<String>> = new StringMap();
			for (i in 1...parts.length) {
				var part:String = StringTools.trim(parts[i]);
				if (part == "") {
					return null;
				}
				var equals:Int = part.indexOf("=");
				var key:String = StringTools.trim(equals < 0 ? part : part.substr(0, equals)).toLowerCase();
				var setting:Null<String> = equals < 0 ? null : StringTools.trim(part.substr(equals + 1));
				if (setting != null && setting.length >= 2 && StringTools.startsWith(setting, "\"") && StringTools.endsWith(setting, "\"")) {
					setting = setting.substr(1, setting.length - 2);
				}
				if (key == "" || params.exists(key)) {
					return null;
				}
				params.set(key, setting);
			}
			parsed.push({name: name, params: params});
		}
		return parsed;
	}

	/** Whether `setting` is a window size RFC 7692 allows: 8 to 15 bits. **/
	private static function __isWindowBits(setting:Null<String>):Bool {
		if (setting == null) {
			return false;
		}
		var bits:Int = crossbyte.utils.IntParse.decimal(setting, 15);
		return bits >= 8;
	}

	/**
		A server's answer to this client's offer, taken if this side can keep
		it: permessage-deflate alone, without context takeover on the
		server's side (this side inflates each message on its own), and
		with nothing asked of this side's compressor but its full window.

		What this side sends goes compressed only where the server said
		`client_no_context_takeover` too. Each message compressed here ends
		its DEFLATE stream (RFC 7692 7.2.3.4): a server inflating every
		message on its own reads that like any other, but one keeping a
		single stream across messages, as it may without that parameter,
		would lose every message after the first. Without it this side sends
		uncompressed, which RFC 7692 allows of any message, and still
		inflates what arrives.
	**/
	private function __takeDeflateAnswer(value:String):Bool {
		var answered = __parseExtensions(value);
		if (answered == null || answered.length != 1 || answered[0].name != PERMESSAGE_DEFLATE) {
			return false;
		}

		var params:StringMap<Null<String>> = answered[0].params;
		if (!params.exists("server_no_context_takeover")) {
			return false;
		}
		for (key in params.keys()) {
			var setting:Null<String> = params.get(key);
			switch (key) {
				case "server_no_context_takeover", "client_no_context_takeover":
					if (setting != null) {
						return false;
					}
				case "server_max_window_bits":
					// Any window: this side keeps a whole one to inflate into.
					if (!__isWindowBits(setting)) {
						return false;
					}
				case "client_max_window_bits":
					// This side's compressor looks back the whole 32 KB.
					if (setting != "15") {
						return false;
					}
				default:
					return false;
			}
		}

		__deflate = true;
		__deflateSend = params.exists("client_no_context_takeover");
		extensions = StringTools.trim(value);
		return true;
	}

	/**
		A client's offers, in its order of preference: the first
		permessage-deflate offer this side can keep is taken, and the answer
		for it becomes `extensions`. An offer that would narrow this side's
		window is passed over (its compressor looks back the whole 32 KB),
		and so is one naming a parameter this side does not know.
	**/
	private function __acceptDeflateOffer(value:String):Bool {
		var offers = __parseExtensions(value);
		if (offers == null) {
			return false;
		}

		for (offer in offers) {
			if (offer.name != PERMESSAGE_DEFLATE) {
				continue;
			}

			var keepable:Bool = true;
			var windowAsked:Bool = false;
			for (key in offer.params.keys()) {
				var setting:Null<String> = offer.params.get(key);
				switch (key) {
					case "server_no_context_takeover", "client_no_context_takeover":
						keepable = keepable && setting == null;
					case "server_max_window_bits":
						windowAsked = true;
						keepable = keepable && setting == "15";
					case "client_max_window_bits":
						// A client that may be told to narrow its window; this
						// side inflates any, and tells it nothing.
						keepable = keepable && (setting == null || __isWindowBits(setting));
					default:
						keepable = false;
				}
			}

			if (keepable) {
				extensions = '$PERMESSAGE_DEFLATE; $DEFLATE_PARAMETERS' + (windowAsked ? "; server_max_window_bits=15" : "");
				__deflate = true;
				// The answer says server_no_context_takeover: the client
				// inflates each message on its own.
				__deflateSend = true;
				return true;
			}
		}
		return false;
	}

	/**
		A whole compressed message, inflated in place of what arrived. Fails
		the connection (1009 past `maxMessageSize`, which bounds what a
		small message can inflate into, 1007 for data that is not DEFLATE)
		and answers false.
	**/
	private function __inflateIncoming():Bool {
		// What the sender took off the end, put back (RFC 7692 7.2.2), and
		// then an empty final block: a sender flushing as zlib does never
		// finishes its stream, and the decoder here reads to a final block.
		var stream:ByteArray = new ByteArray();
		stream.writeBytes(__incomingMessageBuffer, 0, __incomingMessageBuffer.length);
		for (octet in [0x00, 0x00, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0xFF, 0xFF]) {
			stream.writeByte(octet);
		}

		try {
			stream.uncompress(crossbyte.utils.CompressionAlgorithm.DEFLATE, maxMessageSize > 0 ? maxMessageSize : 0);
		} catch (e:Dynamic) {
			__fail(Std.string(e).indexOf("exceeded") >= 0 ? 1009 : 1007);
			return false;
		}

		stream.endian = BIG_ENDIAN;
		// What arrived compressed is done with: the session's own buffer is
		// emptied, not left holding it.
		if (__incomingMessageBuffer != null && __incomingMessageBuffer == __messageKept) {
			Arrivals.release(__incomingMessageBuffer);
		}
		__incomingMessageBuffer = stream;
		__incomingCompressed = false;
		return true;
	}

	/**
		`data` compressed for a message of its own (RFC 7692 7.2.1): DEFLATE,
		then the empty block that ends a flush, less the four octets a
		receiver puts back. This compressor finishes its stream with a final
		block, so what that leaves is a single octet of the empty block's
		header: the form RFC 7692 7.2.3.4 gives for a final block.
	**/
	private static function __deflateOutgoing(data:ByteArray):ByteArray {
		var deflated:ByteArray = new ByteArray();
		if (data.length > 0) {
			deflated.writeBytes(data, 0, data.length);
		}
		deflated.compress(crossbyte.utils.CompressionAlgorithm.DEFLATE);
		deflated.position = deflated.length;
		deflated.writeByte(0x00);
		deflated.position = 0;
		return deflated;
	}

	#if !nodejs
	private function __onConnect():Void {
		// Connected: from here the socket is watched for reading only.
		__dialing = false;
		if (__registered && __runtime != null) {
			@:privateAccess __runtime.unwatchWritable(__socket);
		}

		if (__secure) {
			__initSSLHandshake();
			// The client speaks first: its hello goes now, not at the next
			// tick.
			__onTickSSLHandshake(null);
		} else {
			__openConnection(__tickConnectListener);
		}
	}
	#end

	/**
	 * The transport is up (TCP, and TLS where there is one) and the
	 * session moves from the tick to the registry: read when readable,
	 * retried when a write is waiting, and no longer visited otherwise.
	 */
	private function __openConnection(tickListener:Event->Void):Void {
		__connected = true;
		if (__runtime == null) {
			__runtime = CrossByte.current();
		}

		if (tickListener != null) {
			__runtime.removeEventListener(Event.TICK, tickListener);
		}

		#if !nodejs
		// Neither tick has anything left to step: the connect and the TLS
		// handshake are done.
		__tickConnectListener = null;
		__tickSSLHandshakeListener = null;
		__socket.custom = this;
		@:privateAccess __runtime.registerSocket(__socket);
		__registered = true;
		#end

		__noteEndpoints();

		// Only a client sends the upgrade request; a server waits to receive
		// one. This is keyed on the role rather than on whether a listener
		// was passed, because an accepted TLS session also arrives here with
		// a listener to retire, and would otherwise start talking like a
		// client.
		if (__isClient != false) {
			// The answer is waited for within what is left of the connect's
			// deadline, armed when the connect began, so a peer that accepts the
			// connection and never replies (a TLS listener spoken to in plain
			// text is one) cannot hold the client in CONNECTING for good.
			__doHandshake();
		}
	}

	/** Notes both ends of the connection, once, while the socket can say. **/
	private function __noteEndpoints():Void {
		if (__remotePort != 0 || __socket == null) {
			return;
		}

		try {
			#if nodejs
			__remoteAddress = crossbyte._internal.net.IPv6.compress(__socket.remoteAddress);
			__remotePort = __socket.remotePort;
			__localAddress = crossbyte._internal.net.IPv6.compress(__socket.localAddress);
			__localPort = __socket.localPort;
			#else
			var peer = __socket.peer();
			if (peer != null) {
				__remoteAddress = crossbyte._internal.net.IPv6.compress(peer.host.toString());
				__remotePort = peer.port;
			}
			var local = __socket.host();
			if (local != null) {
				__localAddress = crossbyte._internal.net.IPv6.compress(local.host.toString());
				__localPort = local.port;
			}
			#end
		} catch (_:Dynamic) {}
	}

	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;

	private inline function get_remoteAddress():String {
		return __remoteAddress;
	}

	private inline function get_remotePort():Int {
		return __remotePort;
	}

	private inline function get_localAddress():String {
		return __localAddress;
	}

	private inline function get_localPort():Int {
		return __localPort;
	}

	/**
	 * The protocol this session's TLS handshake agreed through ALPN, or
	 * `null`: on a plain connection, before the handshake is done, or where
	 * nothing was agreed.
	 */
	public var alpnProtocol(get, never):Null<String>;

	private function get_alpnProtocol():Null<String> {
		if (__socket == null || !__tls) {
			return null;
		}

		#if nodejs
		// Node reports `false` rather than null when nothing was agreed.
		var negotiated:Dynamic = (cast __socket : Dynamic).alpnProtocol;
		return Std.isOfType(negotiated, String) ? negotiated : null;
		#else
		return try {
			__socket.getALPN();
		} catch (_:Dynamic) {
			null;
		}
		#end
	}

	/**
	 * Arms a client's one deadline, `connectTimeout` from the start of its
	 * connect, over every step to the session opening: what is still in
	 * progress when it passes is given up on, and the owner told which.
	 */
	private function __armOpenDeadline():Void {
		__disarmOpenDeadline();
		if (connectTimeout <= 0) {
			return;
		}

		var remaining:Float = connectTimeout / 1000 - (haxe.Timer.stamp() - __timestamp);
		__openDeadline = __timers().setTimeout(remaining > 0 ? remaining : 0, function():Void {
			__openDeadlineArmed = false;
			if (readyState == CONNECTING) {
				__onError(__openFailure(), crossbyte.events.IOErrorEvent.TIMEOUT_ERROR_ID);
				__close(1006);
			}
		});
		__openDeadlineArmed = true;
	}

	/**
	 * The scheduler this session's deadlines and heartbeat run on: its own
	 * runtime's, whichever thread arms or clears one. So a close from
	 * another thread can clear the heartbeat, and on Node, where a socket's
	 * callbacks run as the application's, a child runtime's session arms and
	 * clears its heartbeat on its own timers.
	 */
	private function __timers():TimerScheduler {
		if (__runtime == null) {
			__runtime = CrossByte.current();
		}
		return @:privateAccess __runtime.__timer;
	}

	private function __disarmOpenDeadline():Void {
		if (__openDeadlineArmed) {
			__openDeadlineArmed = false;
			__timers().clear(__openDeadline);
		}
	}

	/** What a connect still not open at its deadline was waiting on. **/
	private function __openFailure():String {
		var limit:String = connectTimeout + " ms";
		#if !nodejs
		if (__resolving) {
			return "Failed to connect to server: " + __host + " was not looked up within " + limit;
		}
		if (__handshaking) {
			return "Failed to connect to server: the TLS handshake did not finish within " + limit;
		}
		#end
		if (!__connected) {
			return "Failed to connect to server: " + __host + (__secure ? " was not connected over TLS within " : " was not connected within ") + limit;
		}
		return "The server did not answer the WebSocket upgrade within " + limit;
	}

	/**
	 * Begins the deferred TLS handshake, stepped from the poll set and the
	 * tick. It has no clock of its own: a client's is its connect's
	 * deadline, from `connectTimeout`, and an accepted session's is its
	 * server's `handshakeTimeout`, over TLS and the upgrade together.
	 *
	 * Known limitation: wss is not usable on the eval/interp target. eval
	 * cannot make a socket non-blocking (`setBlocking` is a no-op there; see
	 * the vendored sys.net.Socket), so `handshake()` below can park the whole
	 * runtime thread waiting for the peer's next flight, and no deadline
	 * fires because control never comes back to check it.
	 *
	 * A socket timeout does not help. A TLS handshake's reads are made inside
	 * eval's own mbedTLS binding, which the vendored socket does not reach.
	 * SO_RCVTIMEO does expire on schedule there, but eval raises the expiry
	 * as an OCaml `Unix.Unix_error` (`ETIMEDOUT` on Windows, `EAGAIN` on
	 * Linux) that no Haxe catch intercepts, and the interpreter ends. That
	 * trades a stalled connection for an uncatchable process death, so the
	 * timeout is deliberately not set here. Run wss on cpp/hxcpp or jvm,
	 * where the descriptor really is non-blocking and this path is bounded.
	 */
	#if !nodejs
	private function __initSSLHandshake():Void {
		__handshaking = true;

		if (__tickSSLHandshakeListener == null) {
			__tickSSLHandshakeListener = __onTickSSLHandshake;
		}
		__runtime.removeEventListener(Event.TICK, __tickConnectListener);
		__runtime.addEventListener(Event.TICK, __tickSSLHandshakeListener);

		// In the poll set, so each flight the peer sends steps the handshake
		// as it lands; the tick stays for a flight of this side's own that
		// could not all be written at once. A client's socket is there
		// already, from its connect.
		if (!__registered && __socket != null) {
			__socket.custom = this;
			@:privateAccess __runtime.registerSocket(__socket);
			__registered = true;
		}
	}

	private function __onTickSSLHandshake(e:Event):Void {
		// Stepped from the tick and from the poll set alike, so one that has
		// finished either way is not stepped again.
		if (!__handshaking) {
			return;
		}

		// Three outcomes, kept distinct: completed, needs more data, or
		// failed, so a failed handshake is never treated as a successful
		// one.
		var complete:Bool = false;
		var failure:String = null;

		try {
			__socket.handshake();
			complete = true;
		} catch (e:Dynamic) {
			// Blocked only means the peer's next flight has not arrived
			// yet. Anything else is terminal. The Dynamic catch is what
			// covers the TLS layer's string form, so a mid-handshake pause
			// is not taken for a failure.
			if (!BlockedError.isBlocked(e)) {
				failure = Std.string(e);
			}
		}

		if (complete) {
			__handshaking = false;
			__openConnection(__tickSSLHandshakeListener);
			return;
		}

		// A terminal failure closes immediately instead of idling until the
		// deadline, and the owner is told why before the close: a
		// certificate the client refused is the one failure here worth
		// reading. A merely stalled peer is the deadline's.
		if (failure != null) {
			__handshaking = false;
			__runtime.removeEventListener(Event.TICK, __tickSSLHandshakeListener);
			__onError("TLS handshake failed: " + failure);
			__close(1015);
		}
	}
	#end

	private function __onError(errorMessage:String, errorID:Int = 0):Void {
		__errorReported = true;
		var owner = __owner;
		if (owner != null) {
			@:privateAccess owner.__framingFailed(errorMessage, errorID);
			return;
		}
		var listener = onerror;
		if (listener != null) {
			var event = new WebsocketEvent(WebsocketEvent.ERROR, this, null, errorMessage);
			event.errorID = errorID;
			listener(event);
		}
	}

	/** The session has opened: its owner told, or `onopen`. **/
	private function __opened():Void {
		var owner = __owner;
		if (owner != null) {
			@:privateAccess owner.socket_onOpen(null);
			return;
		}
		var listener = onopen;
		if (listener != null) {
			listener(new WebsocketEvent(WebsocketEvent.OPEN, this));
		}
	}

	/**
	 * Closes the session the way RFC 6455 has it closed: a close frame with
	 * `code` and `reason`, then the peer's answer, then the connection.
	 *
	 * The code and reason are in the frame, and the connection stays up for
	 * the peer's answer: it closes once that arrives and everything queued
	 * has gone, or after `closeTimeout` regardless. `onclose` reports the
	 * code and reason the peer answered with, or 1006 when it never did.
	 *
	 * A session not yet open has nobody to say anything to, and closes at
	 * once.
	 */
	public function close(?code:Int, ?reason:String):Void {
		if (__socket == null || readyState == CLOSED || readyState == CLOSING) {
			return;
		}

		__ownerClosing = true;
		var closing:Int = code == null ? 1000 : code;

		if (readyState != OPEN) {
			__close(closing, reason);
			return;
		}

		__sendCloseFrame(closing, reason);
		readyState = CLOSING;
		__armCloseDeadline();
	}

	/**
	 * Closes the connection now, telling the peer with a close frame if the
	 * socket will take it straight away: for a close that cannot wait on the
	 * peer. `onclose` reports `code`.
	 */
	public function abort(code:Int = 1000, ?reason:String):Void {
		if (__socket == null || readyState == CLOSED) {
			return;
		}

		__ownerClosing = true;
		if (readyState == OPEN) {
			__sendCloseFrame(code, reason);
		}

		__close(code, reason);
	}

	/**
	 * Fails the connection, as RFC 6455 7.1.7 has it done: a close frame
	 * saying why, where the session is open, and then the connection closed
	 * at once. For a peer breaking the protocol, which is owed no handshake.
	 */
	private function __fail(code:Int):Void {
		if (readyState == OPEN) {
			__sendCloseFrame(code, null);
		}
		__close(code);
	}

	/**
	 * The last step of a closing handshake: close once everything queued has
	 * gone, reporting `code` and `reason`: at once when nothing is waiting,
	 * or when the deadline passes with something still stuck.
	 */
	private function __finishClose(code:Int, ?reason:String):Void {
		if (__socket == null || __pendingOutput == null || __pendingOutput.length <= __pendingSent) {
			__close(code, reason);
			return;
		}

		__closeWhenDrained = true;
		__drainedCode = code;
		__drainedReason = reason;
		__armCloseDeadline();
	}

	private function __armCloseDeadline():Void {
		if (__closeDeadlineArmed) {
			return;
		}
		__closeDeadline = __timers().setTimeout(closeTimeout > 0 ? closeTimeout : DEFAULT_CLOSE_TIMEOUT, function():Void {
			__closeDeadlineArmed = false;
			if (readyState == CLOSED) {
				return;
			}
			// Either the peer never answered our close (a connection that
			// ended without one, 1006) or it did, and what was queued could
			// not drain in time.
			if (__closeWhenDrained) {
				__close(__drainedCode, __drainedReason);
			} else {
				__close(1006, "the peer did not answer the close");
			}
		});
		__closeDeadlineArmed = true;
	}

	/**
	 * A close frame carrying `code` and, after it, as much of `reason` as
	 * fits: a control frame holds 125 bytes, two of them the code, and a
	 * reason cut there is cut between characters rather than through one.
	 */
	private function __sendCloseFrame(code:Int, ?reason:String):Void {
		var payload:ByteArray = new ByteArray();
		payload.endian = BIG_ENDIAN;
		payload.writeShort(code);

		if (reason != null && reason.length > 0) {
			var text:Bytes = Bytes.ofString(reason);
			var length:Int = text.length;
			if (length > 123) {
				length = 123;
				// Back off any continuation bytes to the start of a character.
				while (length > 0 && (text.get(length) & 0xC0) == 0x80) {
					length--;
				}
			}
			payload.writeBytes(text, 0, length);
		}

		payload.position = 0;
		__sendFrame(payload, WebSocketOpcode.CLOSE, true);
	}

	private function __close(code:Int, ?reason:String):Void {
		var connecting:Bool = readyState == CONNECTING;
		readyState = CLOSED;

		if (__closeReported) {
			return;
		}

		// A client that never opened has failed to connect, whatever ended
		// it, and says so as a browser's WebSocket does: an error saying why,
		// then 1006, once, here, whether TLS failed, the upgrade was refused
		// or the server hung up. Its owner's own close is no failure.
		if (connecting && __isClient == true && !__ownerClosing) {
			if (!__errorReported) {
				var why:String = __connected ? "The server closed the connection before it answered the WebSocket upgrade" : "The connection failed before it opened";
				__onError(reason != null ? why + ": " + reason : why);
			}
			code = 1006;
			reason = null;
		}

		__closeWhenDrained = false;
		__dialing = false;
		__handshaking = false;
		#if !nodejs
		__resolving = false;
		#end
		__disarmOpenDeadline();
		__stopHeartbeat();
		if (__closeDeadlineArmed) {
			__closeDeadlineArmed = false;
			__timers().clear(__closeDeadline);
		}

		if (__socket != null) {
			#if nodejs
			// What the turn was holding goes before the socket ends, as it went
			// before it was held: the close frame `abort` and a protocol
			// failure send just ahead of this, and whatever was sent before it.
			// Node sends what it was given ahead of the end.
			if (__connected && !__discardOnClose && __pendingOutput != null && __pendingOutput.length > __pendingSent) {
				var held:ByteArray = new ByteArray();
				held.writeBytes(__pendingOutput, __pendingSent, __pendingOutput.length - __pendingSent);
				__pendingOutput.clear();
				__pendingSent = 0;
				try {
					__socket.write(Buffer.hxFromBytes(held), null, onprogress);
					bytesSent += held.length;
				} catch (_:Dynamic) {}
			}
			#else
			// What the pass was holding goes before the socket does, as it went
			// before it was held: the close frame `abort` and a protocol
			// failure send just ahead of this, and whatever was sent before it.
			// Once, and only what the socket takes now.
			if (__pendingOutput != null && __pendingOutput.length > __pendingSent) {
				__offer(__pendingOutput, __pendingSent, __pendingOutput.length - __pendingSent);
			}

			// Out of the registry before the socket goes, as `Socket` does it.
			if (__registered) {
				__registered = false;
				if (__runtime != null) {
					@:privateAccess __runtime.deregisterSocket(__socket);
				}
			}
			#end

			// Closed whether or not the session ever opened, so a TLS handshake
			// that failed, or a connect that timed out, does not keep its
			// descriptor (and, accepted, keep its peer waiting) for as long as
			// the process runs.
			try {
				#if nodejs
				// Ended, so what Node holds goes ahead of the FIN, unless what
				// it holds is what is being reclaimed, when it goes at once.
				if (__connected && !__discardOnClose) {
					__socket.end(null);
				} else {
					__socket.destroy();
				}
				#else
				__socket.close();
				#end
			} catch (_:Dynamic) {}

			#if ((cpp || jvm) && !macro)
			// Storage past `KEEP` back to the runtime's pool: nothing more is
			// sent, and nothing more read is handed out.
			__letGoToPool(__pendingOutput);
			__pendingSent = 0;
			__letGoToPool(__input);
			__inputPosition = 0;
			#end
		}

		__connected = false;
		__detachTickListeners();

		__closeReported = true;
		var owner = __owner;
		if (owner != null) {
			@:privateAccess owner.__framingClosed(code, reason);
		} else if (onclose != null) {
			onclose(new WebsocketEvent(WebsocketEvent.CLOSE, this, null, null, code, reason));
		}

		__socket = null;
	}

	private inline function __detachTickListeners():Void {
		#if !nodejs
		if (__runtime != null) {
			__runtime.removeEventListener(Event.TICK, __tickConnectListener);
			__runtime.removeEventListener(Event.TICK, __tickSSLHandshakeListener);
		}
		#end
	}

	// Heartbeat.

	private function get_pingInterval():Float {
		return __pingInterval < 0 ? DEFAULT_PING_INTERVAL : __pingInterval;
	}

	private function set_pingInterval(value:Float):Float {
		__pingInterval = value < 0 ? 0 : value;
		if (readyState == OPEN) {
			__startHeartbeat();
		}
		return __pingInterval;
	}

	private function get_idleTimeout():Float {
		return __idleTimeout;
	}

	private function set_idleTimeout(value:Float):Float {
		__idleTimeout = value < 0 ? 0 : value;
		if (readyState == OPEN) {
			__startHeartbeat();
		}
		return __idleTimeout;
	}

	private function __heartbeatPeriod():Float {
		var interval:Float = pingInterval;
		if (interval > 0) {
			return interval;
		}
		return __idleTimeout > 0 ? __idleTimeout / 4 : 0;
	}

	/**
	 * Starts the heartbeat, for an open session: both ends run one.
	 *
	 * Without it a peer that vanished without a FIN would be held forever,
	 * with everything sent to it piling up.
	 */
	private function __startHeartbeat():Void {
		__stopHeartbeat();

		var period:Float = __heartbeatPeriod();
		if (period <= 0 || readyState != OPEN || __runtime == null) {
			return;
		}

		__heard = false;
		__silentFor = 0;
		__sentAtBeat = bytesSent + ownPending;
		__heartbeat = __timers().setInterval(period, period, __onHeartbeat);
		__heartbeatArmed = true;
	}

	private function __stopHeartbeat():Void {
		if (__heartbeatArmed) {
			__heartbeatArmed = false;
			__timers().clear(__heartbeat);
		}
	}

	/**
	 * Once a period: a peer heard from since the last is there; one silent
	 * for `idleTimeout` is gone; one silent for less is pinged, and a peer
	 * still there answers.
	 */
	private function __onHeartbeat():Void {
		if (readyState != OPEN) {
			__stopHeartbeat();
			return;
		}

		var period:Float = __heartbeatPeriod();
		// Quiet since the last beat, either way: what it held for messages
		// goes, before the ping below asks the peer whether it is there.
		var sent:Bool = bytesSent + ownPending != __sentAtBeat;
		__trimWhenQuiet(__heard, sent);
		if (__heard) {
			__silentFor = 0;
		} else {
			__silentFor += period;
		}
		__heard = false;

		if (__idleTimeout > 0 && __silentFor >= __idleTimeout) {
			Logger.debug('WebSocket peer silent for ${__silentFor}s, closing session');
			__onError('Nothing was heard from the peer for ${Math.round(__silentFor)} s; the session was closed as idle.',
				crossbyte.events.IOErrorEvent.TIMEOUT_ERROR_ID);
			__close(1006, "idle timeout");
			return;
		}

		if (pingInterval > 0 && __silentFor > 0) {
			ping();
		}
		__sentAtBeat = bytesSent + ownPending;
	}

	public function sendBytes(data:ByteArray):Void {
		sendRange(data, 0, data.length);
	}

	/**
		Sends `length` bytes of `data` from `offset` as one binary message,
		framed from where they lie, with no copy into a ByteArray of their
		own: `crossbyte.net.WebSocket.sendBinary`'s.
	**/
	public function sendRange(data:ByteArray, offset:Int, length:Int):Void {
		__prepareMessage(data, offset, length, WebSocketOpcode.BINARY);
	}

	public function sendString(data:String):Void {
		#if (cpp || jvm)
		if (__sendTextDirect(data)) {
			return;
		}
		#end
		var bytes:ByteArray = crossbyte._internal.Utf8.bytesOf(data);
		__prepareMessage(bytes, 0, bytes.length, WebSocketOpcode.TEXT);
	}

	#if (cpp || jvm)
	/**
		Sends `data` as one uncompressed text frame without encoding it into
		a `Bytes` of its own (190 bytes natively and 520 on the jvm for a
		100-character message): its UTF-8 goes into the session's payload
		scratch instead, which `__sendFrame` frames as it does any payload.

		Natively for any string: one held a byte a character is its UTF-8 as
		it stands, and is copied whole; one held in UTF-16 (any character
		past ASCII) is encoded a character at a time. On the jvm when it is
		short: a loop over the characters there is no faster than the
		platform's encoder past a few hundred. Not when the message is to be
		compressed or is longer than a frame.

		@return Whether it went; false leaves it to the general path, which
		        sends what this does not and refuses a session not open.
	**/
	private function __sendTextDirect(data:String):Bool {
		var length:Int = data.length;
		if (readyState != OPEN || length > FRAGMENT_SIZE || (__deflateSend && length >= compressionThreshold)) {
			return false;
		}
		#if !cpp
		if (length > DIRECT_TEXT_LIMIT) {
			return false;
		}
		#end

		// __sendFrame copies a client's payload into this scratch to mask it,
		// which with the payload already here copies it onto itself.
		var payload:ByteArray = __scratchPayload();
		payload.length = 0;
		var bytes:ByteArrayData = payload;
		#if cpp
		if (!untyped __cpp__("{0}.isUTF16Encoded()", data)) {
			@:privateAccess bytes.__resize(length, 0);
			if (length > 0) {
				untyped __cpp__("memcpy((char *){0}->GetBase(), {1}.raw_ptr(), {2})", bytes.getData(), data, length);
			}
			payload.position = 0;
			__sendFrame(payload, WebSocketOpcode.TEXT, true, false);
			return true;
		}
		#end
		var written:Int = __encodeUtf8(data, payload);
		if (written > FRAGMENT_SIZE) {
			// Longer than a frame once encoded: the general path fragments it.
			return false;
		}
		payload.position = 0;
		__sendFrame(payload, WebSocketOpcode.TEXT, true, false);
		return true;
	}

	/**
		`text` as UTF-8 into `out`, from its start, which is left exactly as
		long as what was written: what `Bytes.ofString` makes, without a
		`Bytes` of its own. A surrogate pair is one character of four bytes;
		a surrogate without its other half, which no valid UTF-8 can carry,
		is U+FFFD. Answers how many bytes were written.
	**/
	private static function __encodeUtf8(text:String, into:ByteArray):Int {
		var count:Int = text.length;
		var out:ByteArrayData = into;
		// Three bytes a code unit at most: a pair of them is four.
		@:privateAccess out.__resize(count * 3, 0);
		var at:Int = 0;
		var i:Int = 0;
		while (i < count) {
			var c:Int = StringTools.fastCodeAt(text, i++);
			if (c < 0x80) {
				out.set(at++, c);
				continue;
			}
			if (c < 0x800) {
				out.set(at++, 0xC0 | (c >> 6));
				out.set(at++, 0x80 | (c & 0x3F));
				continue;
			}
			if (c >= 0xD800 && c <= 0xDFFF) {
				var low:Int = i < count ? StringTools.fastCodeAt(text, i) : 0;
				if (c <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF) {
					i++;
					var code:Int = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
					out.set(at++, 0xF0 | (code >> 18));
					out.set(at++, 0x80 | ((code >> 12) & 0x3F));
					out.set(at++, 0x80 | ((code >> 6) & 0x3F));
					out.set(at++, 0x80 | (code & 0x3F));
					continue;
				}
				c = 0xFFFD;
			} else if (c > 0xFFFF) {
				// A target whose strings hold whole code points.
				out.set(at++, 0xF0 | (c >> 18));
				out.set(at++, 0x80 | ((c >> 12) & 0x3F));
				out.set(at++, 0x80 | ((c >> 6) & 0x3F));
				out.set(at++, 0x80 | (c & 0x3F));
				continue;
			}
			out.set(at++, 0xE0 | (c >> 12));
			out.set(at++, 0x80 | ((c >> 6) & 0x3F));
			out.set(at++, 0x80 | (c & 0x3F));
		}
		into.length = at;
		return at;
	}

	#if !cpp
	/** The longest text the jvm writes into the frame itself; see __sendTextDirect. **/
	private static inline var DIRECT_TEXT_LIMIT:Int = 256;
	#end
	#end

	/**
		`length` bytes of `data` from `offset` sent as one message: compressed
		where that was agreed and the message is worth it, and sent as it is
		when compressing did not make it smaller, which RFC 7692 leaves to
		each message. Neither `data` nor its `position` is changed.
	**/
	private function __prepareMessage(data:ByteArray, offset:Int, length:Int, opcode:Int):Void {
		if (readyState != OPEN) {
			throw "WebSocket is not open";
		}

		if (__deflateSend && length >= compressionThreshold) {
			var whole:ByteArray = data;
			if (offset != 0 || length != data.length) {
				// Compressing makes buffers of its own anyway.
				whole = new ByteArray();
				whole.writeBytes(data, offset, length);
			}
			var deflated:ByteArray = __deflateOutgoing(whole);
			if (deflated.length < length) {
				__sendPayload(deflated, 0, deflated.length, opcode, true);
				return;
			}
		}

		__sendPayload(data, offset, length, opcode, false);
	}

	/**
		Sends `length` bytes of `data` from `offset` as one message, framed as
		this side frames: in frames of at most `FRAGMENT_SIZE`, RSV1 on the
		first where it is `compressed`. Each frame is made from where its
		bytes lie (read by offset, never moving `position`), so a prepared
		message's payload is sent by every session that holds it, and a
		message longer than a frame is not copied a fragment at a time into a
		buffer of its own first.
	**/
	private function __sendPayload(data:ByteArray, offset:Int, total:Int, opcode:Int, compressed:Bool):Void {
		if (total <= FRAGMENT_SIZE) {
			__sendFrameOf(data, offset, total, opcode, true, compressed);
			return;
		}

		// A message longer than a frame, in frames: the first carries the
		// opcode, and RSV1 when compressed; the rest are continuations.
		var at:Int = 0;
		while (at < total) {
			var length:Int = total - at > FRAGMENT_SIZE ? FRAGMENT_SIZE : total - at;
			var first:Bool = at == 0;
			__sendFrameOf(data, offset + at, length, first ? opcode : WebSocketOpcode.CONTINUATION, at + length >= total, compressed && first);
			at += length;
		}
	}

	// One message to many.

	/**
		Sends a prepared message: on a server, its frames as they were made,
		copied into what the pass sends this session, or, 64 KB or more with
		nothing waiting ahead of them, offered to the socket straight from
		where they lie; on a client, its payload framed and masked as every
		client's must be. The compressed form where this session agreed to
		permessage-deflate, the message holds one, and it is at least this
		session's `compressionThreshold`.
	**/
	@:noCompletion public function __sendPrepared(message:crossbyte.net.PreparedMessage):Void {
		if (readyState != OPEN) {
			throw "WebSocket is not open";
		}
		var deflated:Null<ByteArray> = @:privateAccess message.__deflated;
		var compress:Bool = __deflateSend && deflated != null && message.length >= compressionThreshold;
		var opcode:Int = message.isText ? WebSocketOpcode.TEXT : WebSocketOpcode.BINARY;
		if (__isClient == false) {
			var frames:ByteArray = compress ? @:privateAccess message.__deflatedFrames : @:privateAccess message.__frames;
			__queueOutput(frames, frames.length);
			return;
		}
		var payload:ByteArray = compress ? deflated : @:privateAccess message.__payload;
		__sendPayload(payload, 0, payload.length, opcode, compress);
	}

	/**
		`length` bytes of `payload` from `offset`, written into `out` as the
		frames a server sends them in: unmasked, `FRAGMENT_SIZE` at most each,
		RSV1 on the first where `compressed`. What `PreparedMessage` holds.
	**/
	@:noCompletion public static function __writeServerFrames(out:ByteArray, payload:ByteArray, offset:Int, length:Int, opcode:Int, compressed:Bool):Void {
		out.endian = BIG_ENDIAN;
		var at:Int = 0;
		do {
			var size:Int = length - at > FRAGMENT_SIZE ? FRAGMENT_SIZE : length - at;
			var first:Bool = at == 0;
			var last:Bool = at + size >= length;
			out.writeByte((last ? WebSocketHeaderMask.FIN : 0) | (compressed && first ? WebSocketHeaderMask.RSV1 : 0)
				| (first ? opcode : WebSocketOpcode.CONTINUATION));
			if (size > 65535) {
				out.writeByte(127);
				out.writeUnsignedInt(0);
				out.writeUnsignedInt(size);
			} else if (size > 125) {
				out.writeByte(126);
				out.writeShort(size);
			} else {
				out.writeByte(size);
			}
			if (size > 0) {
				out.writeBytes(payload, offset + at, size);
			}
			at += size;
		} while (at < length);
	}

	/** `data` compressed as a message of its own, for `PreparedMessage`. **/
	@:noCompletion public static inline function __deflateMessage(data:ByteArray):ByteArray {
		return __deflateOutgoing(data);
	}

	// Masks.

	/**
		How many random bytes a client's masks are drawn from at a time: 8 KB,
		two thousand frames' worth, as Node's `ws` keeps its pool.
	**/
	private static inline var MASK_POOL:Int = 8 * 1024;

	#if target.threaded
	// One pool a thread, so a runtime's sessions draw from theirs without a
	// lock, and no two threads ever take the same bytes.
	private static var __maskPools:sys.thread.Tls<MaskPool> = new sys.thread.Tls();
	#else
	private static var __maskPoolOnly:Null<MaskPool> = null;
	#end

	/**
		Where the next four bytes of this thread's mask pool start, refilling
		it from the platform's CSPRNG when it has run out; the pool is
		`__maskBytes()`.

		RFC 6455 5.3 asks each frame's masking key to be fresh and
		unpredictable, from a strong source of entropy. Each key here is four
		bytes the CSPRNG made, used for one frame and never again (what a key
		drawn for each frame alone is), drawn a pool at a time, as `ws` draws
		them, so a frame costs no allocation of its own.
	**/
	private static inline function __maskPool():MaskPool {
		#if target.threaded
		var pool:Null<MaskPool> = __maskPools.value;
		if (pool == null) {
			pool = new MaskPool();
			__maskPools.value = pool;
		}
		#else
		var pool:Null<MaskPool> = __maskPoolOnly;
		if (pool == null) {
			pool = __maskPoolOnly = new MaskPool();
		}
		#end
		return pool;
	}

	/**
		The session's scratch for a payload on its way into a frame: a
		client's, masked there, and a text message written in place (see
		`__sendTextDirect`). Made on first use, and let go of when the session
		goes quiet.
	**/
	private inline function __scratchPayload():ByteArray {
		var scratch:Null<ByteArray> = __maskedPayload;
		if (scratch == null) {
			scratch = __maskedPayload = new ByteArray();
			scratch.endian = BIG_ENDIAN;
		}
		return scratch;
	}

	private inline function __sendFrame(payload:ByteArray, opcode:Int, isFinal:Bool, compressed:Bool = false):Void {
		__sendFrameOf(payload, 0, payload.length, opcode, isFinal, compressed);
	}

	/** `length` bytes of `payload` from `offset`, as one frame. **/
	private function __sendFrameOf(payload:ByteArray, offset:Int, length:Int, opcode:Int, isFinal:Bool, compressed:Bool):Void {
		if (__socket == null) {
			return;
		}

		// Write the frame header
		var fin:Int = isFinal ? WebSocketHeaderMask.FIN : 0;
		__output.clear();
		__output.writeByte(fin | (compressed ? WebSocketHeaderMask.RSV1 : 0) | opcode);

		if (__isClient == false) {
			__writePayloadLength(length);
			// Every argument given: an optional one is an object on the jvm.
			(__output : ByteArrayData).__writeRange(payload, offset, length);
		} else {
			__writePayloadLength(length, WebSocketHeaderMask.MASK);
			// Four bytes of this thread's pool, used for this frame alone.
			var pool:MaskPool = __maskPool();
			var keyAt:Int = pool.take();
			var key:ByteArray = pool.bytes;

			// Copy in bulk, then mask in place with the same XOR the inbound
			// path uses, rather than a per-byte writeByte through the
			// ByteArray write path.
			var masked:ByteArray = __scratchPayload();
			masked.length = length;
			masked.position = 0;
			if (length > 0) {
				(masked : Bytes).blit(0, payload, offset, length);
				__applyMask(masked, length, key, keyAt, 0);
			}

			// Write the masked payload
			(__output : ByteArrayData).__writeRange(key, keyAt, 4);
			(__output : ByteArrayData).__writeRange(masked, 0, length);
		}
		// Hand the frame to the pending buffer rather than writing it
		// directly: a momentarily full socket is a normal condition, not a
		// reason to drop the session.
		__queueOutput(__output, __output.length);
		__output.clear();
	}

	private inline function __writePayloadLength(length:UInt, maskFlag:Int = 0x00):Void {
		if (length > 65535) {
			maskFlag |= 127;
			__output.writeByte(maskFlag);
			__output.writeUnsignedInt(0);
			__output.writeUnsignedInt(length);
		} else if (length > 125) {
			maskFlag |= 126;
			__output.writeByte(maskFlag);
			__output.writeShort(length);
		} else {
			maskFlag |= length;
			__output.writeByte(maskFlag);
		}
	}

	/**
	 * Pings the peer, which answers with a pong carrying the same payload
	 * (at most 125 bytes, and none by default). A pong counts as hearing from
	 * the peer, as anything it sends does.
	 */
	public function ping(?payload:ByteArray):Void {
		if (readyState != OPEN) {
			return;
		}
		__sendFrame(__controlPayload(payload), WebSocketOpcode.PING, true);
	}

	/**
	 * Sends a pong nobody asked for: a heartbeat in one direction, which RFC
	 * 6455 5.5.3 allows and the peer does not answer.
	 */
	public function pong(?payload:ByteArray):Void {
		if (readyState != OPEN) {
			return;
		}
		__pong(__controlPayload(payload));
	}

	private function __pong(?payload:ByteArray):Void {
		if (payload == null) {
			payload = __noPayload();
		}
		__sendFrame(payload, WebSocketOpcode.PONG, true);
	}

	// A control frame with nothing in it, as every heartbeat's ping is: one
	// empty buffer, never written to, shared by every ping. Only read
	// (framed from, by offset), so any thread may share it.
	private static var __empty:Null<ByteArray> = null;

	private static inline function __noPayload():ByteArray {
		var empty:Null<ByteArray> = __empty;
		if (empty == null) {
			empty = __empty = new ByteArray();
		}
		return empty;
	}

	private static function __controlPayload(payload:Null<ByteArray>):ByteArray {
		if (payload == null) {
			return __noPayload();
		}
		if (payload.length > 125) {
			throw new crossbyte.errors.ArgumentError("A ping or pong carries at most 125 bytes, and this one is " + payload.length + ".");
		}
		return payload;
	}

	@:access(crossbyte._internal.websocket)
	inline function fromAcceptedSocket(socket:#if nodejs NodeSocket #else FlexSocket #end, ?runtime:CrossByte):WebSocket {
		var acceptedSocket:WebSocket = new AcceptedWebSocket();
		acceptedSocket.__initSocket(socket, runtime);

		return acceptedSocket;
	}
}

enum abstract BinaryType(String) to String from String {
	var ARRAYBUFFER = "arraybuffer";
	var BLOB = "blob";
}

enum abstract WebSocketHeaderMask(Int) from Int to Int {
	public static inline var FIN:Int = 0x80;
	public static inline var RSV1:Int = 0x40;
	public static inline var RSV2:Int = 0x20;
	public static inline var RSV3:Int = 0x10;
	public static inline var MASK:Int = 0x80;
}

enum abstract WebSocketOpcode(Int) from Int to Int {
	public static inline var CONTINUATION:Int = 0x00;
	public static inline var TEXT:Int = 0x01;
	public static inline var BINARY:Int = 0x02;
	public static inline var CLOSE:Int = 0x08;
	public static inline var PING:Int = 0x09;
	public static inline var PONG:Int = 0x0A;
}

/**
	Random bytes for a client's frame masks, from the platform's CSPRNG, four
	taken for each frame and none taken twice; refilled in place
	(`SecureRandom.fill`) when used up. One a thread: see
	`WebSocket.__maskPool`.
**/
@:noCompletion class MaskPool {
	public var bytes(default, null):ByteArray = null;
	private var __at:Int = 0;

	public function new() {}

	/** Where the next four bytes start, in `bytes`. **/
	public inline function take():Int {
		if (bytes == null || __at + 4 > bytes.length) {
			__refill();
		}
		var at:Int = __at;
		__at = at + 4;
		return at;
	}

	// Refilled in place, so the masks cost nothing once the pool exists.
	private function __refill():Void {
		if (bytes == null) {
			bytes = ByteArray.fromBytes(Bytes.alloc(@:privateAccess WebSocket.MASK_POOL));
		}
		SecureRandom.fill(bytes);
		__at = 0;
	}
}

@:private @:noCompletion class AcceptedWebSocket extends WebSocket {
	private function new() {
		__isClient = false;
		super(null, null, null);
	}
}

/**
	A session for a connection a server accepted, run by `runtime`: the
	server's, which on Node is not the one current in the connection's
	callback when a child runtime runs the server.
**/
@:access(crossbyte._internal.websocket)
inline function fromAcceptedSocket(socket:#if nodejs NodeSocket #else FlexSocket #end, ?runtime:CrossByte):WebSocket {
	var acceptedSocket:WebSocket = new AcceptedWebSocket();
	acceptedSocket.__initSocket(socket, runtime);

	return acceptedSocket;
}
#end
