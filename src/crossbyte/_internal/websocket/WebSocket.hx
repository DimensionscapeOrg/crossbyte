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
import crossbyte.Function;
import crossbyte.Timer as CBTimer;
import crossbyte.core.CrossByte;
import crossbyte.crypto.SecureRandom;
import crossbyte.events.Event;
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
 * waiting, so an idle session costs nothing. Only the phases before that,
 * a client's connect and a TLS handshake, still ride the tick, and each is
 * bounded by a deadline.
 *
 * @author Christopher Speciale
 */
class WebSocket #if !nodejs implements IPollableSocket #end {
	public static inline var CLOSED:Int = 3;
	public static inline var CLOSING:Int = 2;
	public static inline var CONNECTING:Int = 0;
	public static inline var OPEN:Int = 1;

	// Max payload size in bytes
	public static var MAX_PAYLOAD:Int = 65536;

	// Max cumulative reassembled message size across fragments, in bytes
	public static var MAX_MESSAGE_SIZE:Int = 16 * 65536;

	// Retained for compatibility; clients now generate a fresh mask per frame.
	public static var MASK_POOL_SIZE:Int = 64;

	/**
	 * The ping interval a session starts with, in milliseconds; 0 for none.
	 * See `pingInterval`, which each session carries and can change.
	 */
	public static var PING_INTERVAL:Int = 30000;

	/** The idle timeout a session starts with, in seconds; see `idleTimeout`. **/
	public static inline var DEFAULT_IDLE_TIMEOUT:Float = 60.0;

	/**
	 * How long a closing handshake is given, in seconds: for the peer to answer
	 * a close frame, and for what was queued before it to drain. Past it the
	 * connection is closed regardless.
	 */
	public static var CLOSE_TIMEOUT:Float = 5.0;

	private static inline var WS:String = "ws";
	private static inline var WSS:String = "wss";

	private static inline var CRLF:String = "\r\n";
	private static inline var CRLFCRLF:String = "\r\n\r\n";
	private static inline var GET:String = "GET";
	private static inline var HTTP:String = "HTTP";

	/**
	 * Consumed bytes tolerated at the front of `__input` while a frame is
	 * still arriving, before the unread tail is moved down. As on `Socket`:
	 * without it the consumed prefix was kept until a read happened to end
	 * on a frame boundary, which a steady stream of large messages may never
	 * do.
	 */
	private static inline var INPUT_COMPACT_THRESHOLD:Int = 64 * 1024;
	private static inline var OUTPUT_COMPACT_THRESHOLD:Int = 64 * 1024;

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
	 * message compressed on its own. Off unless set, before `connect`, or
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
	public var onclose:Function = (e:WebsocketEvent) -> {};
	public var onerror:Function = (e:WebsocketEvent) -> {};
	public var onmessage:Function = (e:WebsocketEvent) -> {};
	public var onopen:Function = (e:WebsocketEvent) -> {};

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
		// so the backlog is Node's: counting only this side's buffer read 0
		// for a peer that had stopped reading, and a server's drain() waited
		// on nothing.
		if (__socket != null) {
			buffered += __socket.writableLength;
		}
		#end
		return buffered;
	}

	// How much of the front of __pendingOutput the socket has already taken;
	// see __flushPendingOutput.
	private var __pendingSent:Int = 0;

	private static inline var CONNECT_TIMEOUT_MS:Int = 10000;

	/**
	 * How long a client waits, in milliseconds, for its connection to open
	 * and then again for the answer to its upgrade. Read on the ticks that
	 * follow construction, so it can be set straight after.
	 */
	public var connectTimeout:Int = CONNECT_TIMEOUT_MS;

	/**
	 * How often, in seconds, a session that has heard nothing from its peer
	 * pings it; zero for never. A peer answers a ping with a pong, so a quiet
	 * connection whose peer is still there stays in use, which also keeps a
	 * proxy between the two from closing it as idle.
	 */
	public var pingInterval(get, set):Float;

	/**
	 * How long, in seconds, a session hears nothing, no message, no pong, no
	 * frame at all, before it takes the peer for gone and closes with 1006;
	 * zero for never. Checked every `pingInterval`, or every quarter of this
	 * with pings off.
	 */
	public var idleTimeout(get, set):Float;

	private var __connected:Bool = false;
	private var __timestamp:Float;
	private var __timeout:Int = CONNECT_TIMEOUT_MS;

	private var __origin:String;
	private var __protocols:Array<String> = [];
	private var __secure:Bool;

	// Whether the transport is TLS, whichever side made it.
	private var __tls:Bool = false;

	// What a secure client checks the server against. Verified by default:
	// every secure client used to be built with verification off, so any
	// certificate for any host was accepted and whoever sat in the path could
	// read the session.
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
	// places in one pass, a failed write inside the frame that answers a
	// close, say, and the owner is told once.
	private var __closeReported:Bool = false;

	// A close waiting for queued output to go: what it will report.
	private var __closeWhenDrained:Bool = false;
	private var __drainedCode:Int = 1000;
	private var __drainedReason:String = null;

	// The deadline on a closing handshake, and on a client's upgrade.
	private var __closeDeadline:Int = 0;
	private var __closeDeadlineArmed:Bool = false;
	private var __upgradeDeadline:Int = 0;
	private var __upgradeDeadlineArmed:Bool = false;

	// The heartbeat: whether anything has arrived since the last beat, for
	// how long in a row nothing has, and the timer.
	private var __pingInterval:Float = -1;
	private var __idleTimeout:Float = DEFAULT_IDLE_TIMEOUT;
	private var __heard:Bool = false;
	private var __silentFor:Float = 0;
	private var __heartbeat:Int = 0;
	private var __heartbeatArmed:Bool = false;

	// Whether this session's socket is in the runtime's registry, and whether
	// a retry of its pending output is queued there.
	private var __registered:Bool = false;
	private var __writeQueued:Bool = false;

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

	private var __handshakeBuffer:String = "";

	private var __maskedPayload:ByteArray;
	private var __outgoingMessageBuffer:ByteArray;

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
		#if !nodejs
		__tickConnectListener = __onTickConnect;
		__tickSSLHandshakeListener = __onTickSSLHandshake;
		#end

		if (__isClient == null) {
			__isClient = true;
			// A client's alone: a server answers the key it is sent, and needs
			// no randomness of its own. This was drawn before the question was
			// asked, so every session a server accepted drew one too, and
			// SecureRandom refuses on eval, hl and neko, so there every
			// upgrade threw in the accept tick and the peer was reset.
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
				// for an Int differently on every target, its low 32 bits on
				// Linux native, the largest Int on Windows, an exception on the
				// jvm, nothing at all on eval, so a port past 65535 became
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

	private function __initSocket(?socket:#if nodejs NodeSocket #else FlexSocket #end):Void {
		__runtime = CrossByte.current();
		__input = new ByteArray();
		__input.endian = BIG_ENDIAN;
		__output = new ByteArray();
		__output.endian = BIG_ENDIAN;

		__pendingOutput = new ByteArray();
		__pendingOutput.endian = BIG_ENDIAN;

		__incomingMessageBuffer = new ByteArray();
		__incomingMessageBuffer.endian = BIG_ENDIAN;

		__outgoingMessageBuffer = new ByteArray();
		__outgoingMessageBuffer.endian = BIG_ENDIAN;

		__maskedPayload = new ByteArray();
		__maskedPayload.endian = BIG_ENDIAN;

		__timestamp = haxe.Timer.stamp();

		#if nodejs
		// Node's own socket, so there is no connect poll and no handshake
		// pump: it reports both as events. wss is a `tls.connect` rather than
		// a `net.connect`, and the TLS is Node's.
		if (socket == null) {
			__tls = __secure;
			__connectNode();
		} else {
			// Accepted rather than dialled: already connected, so there is no
			// connect event to wait for. __openConnection sends the upgrade
			// request only for a client, and this is not one, a server waits
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
				// Checked unless the owner said not to. This was a flat
				// `verifyCert = false`, so every secure client accepted any
				// certificate for any host. The host name set below is what the
				// certificate is then matched against, as well as the SNI name.
				__socket.verifyCert = __verifyCert;
				if (__certAuthority != null) {
					__socket.setCA(__certAuthority.__native);
				}
				__socket.setHostname(__host);
			}
			// No byte order is set on the output: frames go out as raw bytes,
			// and on jvm a socket has no output at all until it connects, so
			// setting one here threw before any client, ws:// included,
			// had even started.
			__connect();
			__runtime.addEventListener(Event.TICK, __tickConnectListener);
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
			// Node verifies unless told otherwise; what it lacked was a way
			// for the owner to say either thing, to trust a private
			// authority, or, for a development server, not to check.
			var options:Dynamic = {port: __port, host: __host, rejectUnauthorized: __verifyCert};

			// `servername` is the SNI name, and without it a host serving
			// several certificates on one address has no way to pick this
			// one's, the handshake then fails on a name mismatch that looks
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
		// that threw, a message handler meeting input it could not parse,
		// threw into Node, which ended the process and every session in it.
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
					// frame, which is ordinary, a dropped connection, a
					// killed process, and is exactly what 1006 is for.
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

		// Sliced by its own region: a Node Buffer can be a window onto a
		// larger pooled allocation, and taking .buffer whole would carry bytes
		// belonging to something else.
		var region = chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength);

		__input.position = __input.length;
		__appendBytes(__input, Bytes.ofData(region));
		__input.position = __inputPosition;
		__onData();
	}
	#end

	#if !nodejs
	/**
		Starts the connect. An address is connected to at once; a name is
		looked up off the runtime's thread first (see `Resolver`), it used to
		be looked up right here, holding every socket and timer on the runtime
		for as long as the resolver took. The tick waits for the answer as it
		waits for the connect, under the same deadline.
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
			// a connect that has already failed, and every failure used to be
			// swallowed here, leaving the tick to wait out the timeout for a
			// connection that could never come.
			if (!BlockedError.isBlocked(e)) {
				__connectFailure = Std.string(e);
				return;
			}
		}

		// Watched in the poll set, so the connect is taken up as soon as the
		// system finishes it, as crossbyte.net.Socket's is: from the tick
		// alone it waited for the next frame. For reading too, which is where
		// a refused connect is reported on Windows. The tick stays, for the
		// deadline.
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
			// No connect to ask about until the name is looked up; only the
			// deadline, which a resolver that never answers does not outlast.
			if (haxe.Timer.stamp() - __timestamp > connectTimeout / 1000) {
				__onError("Failed to connect to server: " + __host + " was not looked up within " + connectTimeout + " ms");
				__close(1006);
			}
			return;
		}

		if (!__connected && !__handshaking) {
			// Asked about the exception set too: a refused connect is
			// reported there on Windows and never becomes writable, so it sat
			// here until the deadline, ten seconds by default for a refusal
			// the system had reported at once.
			var sockets:Dynamic = FlexSocket.select(null, [__socket], [__socket], 0);

			if (sockets.write[0] == __socket) {
				__onConnect();
			} else if ((sockets.others != null && sockets.others[0] == __socket)
				|| haxe.Timer.stamp() - __timestamp > connectTimeout / 1000) {
				// The reason first, then the close, so a listener that tears
				// down on close has already been told why.
				__onError("Failed to connect to server");
				__close(1006);
			}
		}
	}

	// ---- The registry's calls ---------------------------------------------

	public var registryClosed(get, never):Bool;

	private function get_registryClosed():Bool {
		return __socket == null || readyState == CLOSED;
	}

	/**
	 * The socket is readable: read what is there.
	 *
	 * This ran from the tick for every session, every tick, whether or not
	 * anything had arrived, a receive that found nothing, and on hxcpp
	 * raised an exception to say so, per idle session per tick. The registry
	 * polls every socket at once and calls only the ones with something to
	 * read.
	 */
	public function registryOnReadable():Void {
		#if !nodejs
		// A connect or a TLS handshake still in flight is stepped rather than
		// read: each was stepped only from the tick, so a connect waited for
		// the next frame, and a handshake waited a frame per round trip.
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
	 * Only the jvm's can, see `Socket.registryHasBufferedInput`, and it is
	 * asked through its type, not dynamically, since the registry asks every
	 * TLS session on every pump.
	 */
	public function registryHasBufferedInput():Bool {
		#if (java || jvm)
		if (!__tls || __socket == null) {
			return false;
		}

		var tls = Std.downcast((__socket : sys.net.Socket), crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket);
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
		// does, where each read used to be copied into a buffer of its own
		// and then again into the input.
		__input.position = __input.length;

		while (__connected && __socket != null) {
			try {
				var nBytes:Int = __socket.input.readBytes(scratch, 0, scratch.length);
				if (nBytes <= 0) {
					break;
				}
				totalBytes += nBytes;
				__input.writeBytes(scratch, 0, nBytes);

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

				// TLS keeps the old read-until-short-read behaviour. A select
				// on the raw descriptor sees the socket, not the session:
				// mbedtls decrypts whole records into its own buffer, so
				// plaintext waiting there is invisible to select and gating
				// on it would strand a fully received message. The probe sits
				// inside the try on purpose, a select failure on a dying
				// socket lands in the catches below and closes the session,
				// the same as a failed read.
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
				// frame, which is ordinary, a closed tab, a dropped mobile
				// connection, and is reported as 1006 below, not logged as a
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
	 * Appends `bytes` to the pending buffer and tries to push it to the
	 * socket.
	 *
	 * Everything written by this session goes through here so that a
	 * partially-accepted or momentarily-full socket retains the remainder
	 * instead of losing it.
	 */
	private function __queueOutput(data:ByteArray, length:Int):Void {
		#if !nodejs
		// Nothing queued ahead of it, so it is offered to the socket straight
		// from where it was built, and only what the socket does not take is
		// copied into the pending buffer, the ordinary case, a socket with
		// room, costs no copy at all.
		if (data != null && length > 0 && __socket != null && __pendingSent >= __pendingOutput.length) {
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
			__pendingOutput.writeBytes(data, accepted, length - accepted);
			__afterPartialWrite();
			return;
		}
		#end

		if (data != null && length > 0) {
			__pendingOutput.position = __pendingOutput.length;
			__pendingOutput.writeBytes(data, 0, length);
		}

		__flushPendingOutput();
	}

	#if !nodejs
	/**
		Offers `length` bytes of `buffer` from `offset` to the socket. Answers
		how many it took, 0 when it had no room, or -1 if the write failed.

		Written until the socket will take no more, not once: a TLS socket
		takes one record a write, so a single write sent 16 KB a pass whatever
		room the kernel had.
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
	 * What the socket took is stepped over rather than cut off. Every partial
	 * write used to copy all that was still waiting into a new buffer, so a
	 * peer reading slowly behind a large backlog cost a copy of the whole
	 * backlog per write, quadratic in the backlog. The buffer is compacted
	 * only once what has gone is past the threshold and at least as large as
	 * what remains, so moving the rest down costs no more than the writes
	 * that emptied the front.
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
		// is cleared and refilled by the very next frame, `clear()` resets
		// the length and keeps the array, so handing Node a window onto it
		// would let the next frame overwrite the one still queued for sending.
		var frame:ByteArray = new ByteArray();
		frame.writeBytes(__pendingOutput, __pendingSent, pending);
		try {
			__socket.write(Buffer.hxFromBytes(frame));
		} catch (e:Dynamic) {
			__close(1006, null);
			return;
		}
		__pendingOutput.clear();
		__pendingSent = 0;

		// So a peer that is not reading shows in Node's own queue, and the
		// limit is measured there. It was measured after a return this path
		// always took, and so never.
		if (maxOutputBufferSize > 0 && __socket != null && __socket.writableLength > maxOutputBufferSize) {
			__close(1011, "output buffer limit exceeded");
		}
		#else
		var accepted:Int = __offer(__pendingOutput, __pendingSent, pending);
		if (accepted < 0) {
			__close(1006, null);
			return;
		}

		if (accepted >= pending) {
			__pendingOutput.clear();
			__pendingSent = 0;

			// A close that was waiting for this to go.
			if (__closeWhenDrained) {
				__close(__drainedCode, __drainedReason);
			}
			return;
		}

		__pendingSent += accepted;
		var remaining:Int = pending - accepted;
		if (__pendingSent >= OUTPUT_COMPACT_THRESHOLD && __pendingSent >= remaining) {
			// Allocated and swapped rather than moved within the buffer: an
			// overlapping blit has no defined behaviour across targets.
			var carried:ByteArray = new ByteArray();
			carried.endian = BIG_ENDIAN;
			carried.writeBytes(__pendingOutput, __pendingSent, remaining);
			__pendingOutput = carried;
			__pendingSent = 0;
		}
		__afterPartialWrite();
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
		if (maxOutputBufferSize > 0 && __pendingOutput.length - __pendingSent > maxOutputBufferSize) {
			__pendingOutput.clear();
			__pendingSent = 0;
			__close(1011, "output buffer limit exceeded");
			return;
		}

		__queueWritable();
	}
	#end

	private function __handleControlFrame(opcode:WebSocketOpcode, payload:ByteArray):Void {
		switch (opcode) {
			case PING:
				// A ping is answered in any state but closed: a peer waiting on
				// the close handshake may still be checking this side is there.
				__pong(payload);
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
				// is reported is the peer's code and reason either way, what
				// it said about why, which is what a browser reports too.
				__finishClose(code, reason);
		}
	}

	private function __onData():Void {
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
				// payload that may never arrive. These three checks used to sit after
				// that wait, and so ten bytes claiming a two-gigabyte length put the
				// session into a wait for a frame MAX_PAYLOAD would have refused the
				// moment it completed.
				var isControl:Bool = opCode >= WebSocketOpcode.CLOSE;
				if (isControl && (!isFinal || payloadLength > 125)) {
					__fail(1002);
					return;
				}
				if (!isControl && payloadLength > MAX_PAYLOAD) {
					__fail(1009);
					return;
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

				var maskingKey:ByteArray = new ByteArray(4);
				if (isMasked) {
					__input.readBytes(maskingKey, 0, 4);
				}

				var payload:ByteArray = new ByteArray(payloadLength);
				if (payloadLength > 0) {
					__input.readBytes(payload, 0, payloadLength);
				}
				if (isMasked) {
					__applyMask(payload, payloadLength, maskingKey);
				}

				payload.position = 0;

				if (isControl) {
					__handleControlFrame(opCode, payload);
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

				// Cap the cumulative reassembled message size across fragments.
				__incomingMessageSize += payloadLength;
				if (__incomingMessageSize > MAX_MESSAGE_SIZE) {
					__fail(1009);
					return;
				}

				__incomingMessageBuffer.position = __incomingMessageBuffer.length;
				__incomingMessageBuffer.writeBytes(payload);

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
		} else if (readyState == CONNECTING) {
			var raw:Bytes = __input;
			var start:Int = __input.position;
			var endIndex:Int = __findHeaderEnd(raw, start, __input.length);
			if (endIndex > -1) {
				// received entire header
				var headerLength:Int = endIndex - start + 4;
				var headerData:String = __handshakeBuffer + raw.getString(start, headerLength);
				__handshakeBuffer = "";
				var extraStart:Int = start + headerLength;
				var extraLength:Int = Std.int(__input.length) - extraStart;
				var extra:Bytes = extraLength > 0 ? raw.sub(extraStart, extraLength) : null;
				var lines:Array<String> = headerData.split(CRLF);
				var headers:StringMap<String>;

				if (lines[0].indexOf(GET) == 0) {
					headers = __parseHeaders(lines);
					if (!__acceptUpgrade(lines[0], headers)) {
						return;
					}
				} else if (lines[0].indexOf("HTTP") == 0) {
					headers = __parseHeaders(lines);
					if (lines[0].indexOf("101") > -1) {
						headers.set("status", "101");
					} else {
						__close(1002);
						return;
					}

					if (__validateResponseHandshake(headers)) {
						// handshake complete, is ready
						__disarmUpgradeDeadline();
						readyState = OPEN;
						__startHeartbeat();
						onopen(new WebsocketEvent(WebsocketEvent.OPEN, this));
					} else {
						__close(1002);
						return;
					}
				}

				if (readyState == OPEN) {
					// The handshake was parsed with getString, which does not
					// move the cursor, so those bytes are still sitting in the
					// buffer. They have to be dropped explicitly: anything left
					// here is parsed as the start of the first frame, and the
					// 'G' of "GET" (0x47) has RSV1 set, so the peer's first
					// real message was rejected as a protocol error.
					__input.clear();
					__inputPosition = 0;

					if (extra != null && extra.length > 0) {
						__appendBytes(__input, extra);
						__input.position = 0;
						__onData();
					}
				}
				// is it the client handshake or server response?
			} else {
				// received partial header, buffer it and wait.
				__handshakeBuffer += raw.getString(start, __input.bytesAvailable);
				__input.clear();
				__inputPosition = 0;
			}
		}
	}

	/**
	 * A server session's answer to the upgrade request it has just received:
	 * the `101`, or a refusal. Says whether the session opened.
	 *
	 * The request was parsed and thrown away, so nothing about who was asking
	 * reached anything able to act on it, and a browser offering a subprotocol
	 * heard none back and failed the connection. Now the request is kept, the
	 * owner's `onupgrade` decides on it, and the subprotocol accepted is
	 * echoed.
	 */
	private function __acceptUpgrade(requestLine:String, headers:StringMap<String>):Bool {
		if (!__validateRequestHandshake(headers)) {
			// Answered rather than dropped, so a client learns why. A version
			// this side does not speak is answered with the one it does, as
			// RFC 6455 4.4 asks.
			var version:Null<String> = headers.get("sec-websocket-version");
			__refuseUpgrade(400, version != null && version != "13" ? ["Sec-WebSocket-Version: 13"] : null);
			return false;
		}

		__noteEndpoints();
		request = new WebSocketRequest(requestLine, headers, __remoteAddress, __remotePort);

		var accepted:Bool = true;
		if (onupgrade != null) {
			try {
				accepted = onupgrade(request);
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
		onopen(new WebsocketEvent(WebsocketEvent.OPEN, this));
		return readyState == OPEN;
	}

	/**
	 * Answers an upgrade with a refusal, and closes once the answer has gone.
	 */
	private function __refuseUpgrade(status:Int, extraHeaders:Null<Array<String>>):Void {
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
	 * XORs `length` bytes of `data` in place with the four-byte `mask`.
	 *
	 * Masking and unmasking are the same operation, so both directions use
	 * this. It runs on `Bytes` rather than through `ByteArray`'s array
	 * access deliberately: that accessor calls `__resize` on every element
	 * write to bounds-check an index this loop already knows is in range,
	 * and on a server this is touched once per inbound byte. Measured on
	 * 32 MB, the old per-byte form ran at 648 MB/s and this at ~1470 MB/s.
	 *
	 * Whole 32-bit words are XORed at a time. The key is read with the same
	 * accessor as the data, so both agree on byte order and word `i` lines
	 * up with `mask[(i + j) & 3]` for every offset that is a multiple of
	 * four, which is why only the trailing bytes need the scalar loop.
	 */
	private static function __applyMask(data:Bytes, length:Int, mask:Bytes):Void {
		if (length <= 0) {
			return;
		}

		var key:Int = mask.getInt32(0);
		var wordEnd:Int = length & ~3;
		var i:Int = 0;

		while (i < wordEnd) {
			data.setInt32(i, data.getInt32(i) ^ key);
			i += 4;
		}

		while (i < length) {
			data.set(i, data.get(i) ^ mask.get(i & 0x03));
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
		// 4000-4999 is private. Accepting anything at or above 1000 let a
		// peer close with 1016, 2000 or 65535, none of which mean
		// anything, when the answer to an unknown code is 1002.
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
			__input.clear();
			__inputPosition = 0;
			return;
		}

		var consumed:Int = __input.position;
		if (consumed >= INPUT_COMPACT_THRESHOLD) {
			var remaining:Int = __input.length - consumed;
			var carried:ByteArray = new ByteArray();
			carried.endian = BIG_ENDIAN;
			carried.writeBytes(__input, consumed, remaining);
			carried.position = 0;
			__input = carried;
		}

		__inputPosition = __input.position;
	}

	private function __dispatchMessage():Void {
		var message:ByteArray = __incomingMessageBuffer;
		var isText:Bool = __incomingOpcode == WebSocketOpcode.TEXT;
		message.position = 0;
		__incomingMessageBuffer = new ByteArray();
		__incomingMessageBuffer.endian = BIG_ENDIAN;
		__incomingOpcode = -1;
		__incomingMessageSize = 0;

		// Nothing new is delivered once closing: RFC 6455 has a peer's data
		// after its close frame, or after ours, belong to no one.
		if (readyState != OPEN) {
			return;
		}

		var event = new WebsocketEvent(WebsocketEvent.MESSAGE, this, message);
		event.isText = isText;
		onmessage(event);
	}

	private function __generateResponseHandshake(headers:StringMap<String>):Bytes {
		var lines:Array<String> = [
			"HTTP/1.1 101 Switching Protocols",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Accept: " + __generateWebSocketAccept(headers.get("sec-websocket-key"))
		];

		// The subprotocol accepted, echoed. A browser that offered one and
		// heard none back failed the connection outright, so a page asking
		// for a subprotocol could never open a session here.
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

	// ---- permessage-deflate (RFC 7692) -----------------------------------

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
		server's side, this side inflates each message on its own, and
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
		window is passed over, its compressor looks back the whole 32 KB,
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
		the connection, 1009 past `MAX_MESSAGE_SIZE`, which bounds what a
		small message can inflate into, 1007 for data that is not DEFLATE,
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
			stream.uncompress(crossbyte.utils.CompressionAlgorithm.DEFLATE, MAX_MESSAGE_SIZE);
		} catch (e:Dynamic) {
			__fail(Std.string(e).indexOf("exceeded") >= 0 ? 1009 : 1007);
			return false;
		}

		stream.endian = BIG_ENDIAN;
		__incomingMessageBuffer = stream;
		__incomingCompressed = false;
		return true;
	}

	/**
		`data` compressed for a message of its own (RFC 7692 7.2.1): DEFLATE,
		then the empty block that ends a flush, less the four octets a
		receiver puts back. This compressor finishes its stream with a final
		block, so what that leaves is a single octet of the empty block's
		header, the form RFC 7692 7.2.3.4 gives for a final block.
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
			// The client speaks first: its hello goes now, where it waited
			// for the next tick to be sent at all.
			__onTickSSLHandshake(null);
		} else {
			__openConnection(__tickConnectListener);
		}
	}
	#end

	/**
	 * The transport is up, TCP, and TLS where there is one, and the
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
			// The answer is waited for as long as the connect was, measured
			// from here rather than from the connect: a TLS handshake has
			// already spent some of that. Nothing bounded it before: a peer
			// that accepted the connection and never replied, a TLS listener
			// spoken to in plain text is one, held the client in CONNECTING
			// for good.
			__timestamp = haxe.Timer.stamp();
			__timeout = connectTimeout;
			__armUpgradeDeadline();
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

	private function __armUpgradeDeadline():Void {
		__disarmUpgradeDeadline();
		if (__timeout <= 0) {
			return;
		}
		__upgradeDeadline = CBTimer.setTimeout(__timeout / 1000, function():Void {
			__upgradeDeadlineArmed = false;
			if (readyState == CONNECTING) {
				__onError("The server did not answer the WebSocket upgrade");
				__close(1006);
			}
		});
		__upgradeDeadlineArmed = true;
	}

	private function __disarmUpgradeDeadline():Void {
		if (__upgradeDeadlineArmed) {
			__upgradeDeadlineArmed = false;
			CBTimer.clear(__upgradeDeadline);
		}
	}

	/**
	 * Begins the deferred TLS handshake, deadline-guarded from the tick loop.
	 *
	 * Known limitation, wss is not usable on the eval/interp target. eval
	 * cannot make a socket non-blocking (`setBlocking` is a no-op there; see
	 * the vendored sys.net.Socket), so `handshake()` below can park the whole
	 * runtime thread waiting for the peer's next flight, and the deadline in
	 * `__onTickSSLHandshake` never fires because control never comes back to
	 * check it.
	 *
	 * The obvious mitigation does not work, and was measured rather than
	 * assumed: setting a socket timeout does reach the recv, SO_RCVTIMEO
	 * expires on schedule, but eval raises the expiry as an OCaml
	 * `Unix.Unix_error(ETIMEDOUT, "recv")` that no Haxe catch intercepts.
	 * Neither `catch (e:haxe.Exception)` nor `catch (e:Dynamic)` sees it, not
	 * even the shim's own catch around the read, and the interpreter aborts.
	 * That trades a stalled connection for an uncatchable process death, so
	 * the timeout is deliberately not set here. Run wss on cpp/hxcpp or jvm,
	 * where the descriptor really is non-blocking and this path is bounded.
	 */
	#if !nodejs
	private function __initSSLHandshake():Void {
		__timeout = 3000;
		__timestamp = haxe.Timer.stamp();
		__handshaking = true;

		__runtime.removeEventListener(Event.TICK, __tickConnectListener);
		__runtime.addEventListener(Event.TICK, __tickSSLHandshakeListener);

		// In the poll set, so each flight the peer sends steps the handshake
		// as it lands; the tick stays for the deadline, and for a flight of
		// this side's own that could not all be written at once. A client's
		// socket is there already, from its connect.
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
		// failed. Previously a non-`Blocked` error left the "retry" flag
		// clear and fell through to __openConnection(), treating a failed
		// handshake as a successful one.
		var complete:Bool = false;
		var failure:String = null;

		try {
			__socket.handshake();
			complete = true;
		} catch (e:Dynamic) {
			// Blocked only means the peer's next flight has not arrived
			// yet. Anything else is terminal. The Dynamic catch is what
			// covers the TLS layer's string form, which a typed catch here
			// used to miss, turning a mid-handshake pause into a failure.
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
		// deadline; a merely stalled peer closes once the deadline passes.
		// Either way the owner is told why before the close, a certificate
		// the client refused is the one failure here worth reading.
		var expired:Bool = haxe.Timer.stamp() - __timestamp > __timeout / 1000;
		if (failure != null || expired) {
			__handshaking = false;
			__runtime.removeEventListener(Event.TICK, __tickSSLHandshakeListener);
			__onError(failure != null ? "TLS handshake failed: " + failure : "TLS handshake timed out");
			__close(1015);
		}
	}
	#end

	private function __onError(errorMessage:String):Void {
		onerror(new WebsocketEvent(WebsocketEvent.ERROR, this, errorMessage));
	}

	private function __onMessage(data:Dynamic):Void {
		onmessage(new WebsocketEvent(WebsocketEvent.MESSAGE, this, data));
	}

	/**
	 * Closes the session the way RFC 6455 has it closed: a close frame with
	 * `code` and `reason`, then the peer's answer, then the connection.
	 *
	 * This sent a close frame with nothing in it, so a peer saw 1005, or
	 * 1000, whatever code was asked for, and closed the socket straight
	 * after queueing it, which on a native target could drop both the frame
	 * and anything still waiting to go out before it. Now the code and reason
	 * are in the frame, the connection stays up for the peer's answer, and
	 * closes once that arrives and everything queued has gone, or after
	 * `CLOSE_TIMEOUT` regardless. `onclose` reports the code and reason the
	 * peer answered with, or 1006 when it never did.
	 *
	 * A session not yet open has nobody to say anything to, and closes at
	 * once.
	 */
	public function close(?code:Int, ?reason:String):Void {
		if (__socket == null || readyState == CLOSED || readyState == CLOSING) {
			return;
		}

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
	 * gone, reporting `code` and `reason`, at once when nothing is waiting,
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
		__closeDeadline = CBTimer.setTimeout(CLOSE_TIMEOUT, function():Void {
			__closeDeadlineArmed = false;
			if (readyState == CLOSED) {
				return;
			}
			// Either the peer never answered our close, which is a
			// connection that ended without one, 1006, or it did, and what
			// was queued could not drain in time.
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
		readyState = CLOSED;

		if (__closeReported) {
			return;
		}

		__closeWhenDrained = false;
		__dialing = false;
		__handshaking = false;
		#if !nodejs
		__resolving = false;
		#end
		__disarmUpgradeDeadline();
		__stopHeartbeat();
		if (__closeDeadlineArmed) {
			__closeDeadlineArmed = false;
			CBTimer.clear(__closeDeadline);
		}

		if (__socket != null) {
			#if !nodejs
			// Out of the registry before the socket goes, as `Socket` does it.
			if (__registered) {
				__registered = false;
				if (__runtime != null) {
					@:privateAccess __runtime.deregisterSocket(__socket);
				}
			}
			#end

			// Closed whether or not the session ever opened. Only an open one
			// used to be: a TLS handshake that failed, or a connect that timed
			// out, detached its listeners and dropped the socket without
			// closing it, so every refused or stalled connection kept its
			// descriptor, and, accepted, kept its peer waiting, for as long
			// as the process ran.
			try {
				#if nodejs
				if (__connected) {
					__socket.end(null);
				} else {
					__socket.destroy();
				}
				#else
				__socket.close();
				#end
			} catch (_:Dynamic) {}
		}

		__connected = false;
		__detachTickListeners();

		__closeReported = true;
		onclose(new WebsocketEvent(WebsocketEvent.CLOSE, this, null, code, reason));

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

	// ---- Heartbeat ---------------------------------------------------------

	private function get_pingInterval():Float {
		return __pingInterval < 0 ? PING_INTERVAL / 1000 : __pingInterval;
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
	 * It was dead code before, a client started it only if a delay had been
	 * set, which nothing set, and an accepted session had the delay and never
	 * started it, so a peer that vanished without a FIN was held forever,
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
		__heartbeat = CBTimer.setInterval(period, period, __onHeartbeat);
		__heartbeatArmed = true;
	}

	private function __stopHeartbeat():Void {
		if (__heartbeatArmed) {
			__heartbeatArmed = false;
			CBTimer.clear(__heartbeat);
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
		if (__heard) {
			__silentFor = 0;
		} else {
			__silentFor += period;
		}
		__heard = false;

		if (__idleTimeout > 0 && __silentFor >= __idleTimeout) {
			Logger.debug('WebSocket peer silent for ${__silentFor}s, closing session');
			__onError('Nothing was heard from the peer for ${Math.round(__silentFor)} s; the session was closed as idle.');
			__close(1006, "idle timeout");
			return;
		}

		if (pingInterval > 0 && __silentFor > 0) {
			ping();
		}
	}

	public function sendBytes(data:ByteArray):Void {
		__prepareMessage(data, WebSocketOpcode.BINARY);
	}

	public function sendString(data:String):Void {
		__prepareMessage(Bytes.ofString(data), WebSocketOpcode.TEXT);
	}

	private function __prepareMessage(data:ByteArray, opcode:Int):Void {
		if (readyState != OPEN) {
			throw "WebSocket is not open";
		}
		data.position = 0;

		// Compressed where that was agreed and the message is worth it, and
		// sent as it is when compressing did not make it smaller, which RFC
		// 7692 leaves to each message.
		var compressed:Bool = false;
		if (__deflateSend && data.length >= compressionThreshold) {
			var deflated:ByteArray = __deflateOutgoing(data);
			if (deflated.length < data.length) {
				data = deflated;
				compressed = true;
			}
			data.position = 0;
		}

		// handles fragmentation of message into multiple frames
		if (data.length > MAX_PAYLOAD) {
			var firstFrame:Bool = true;
			while (data.position != data.length) {
				var fin:Bool;
				var fragmentOpcode:Int;
				var length:Int;

				var remaining:Int = data.length - data.position;

				if (remaining > MAX_PAYLOAD) {
					fin = false;
					length = MAX_PAYLOAD;
					fragmentOpcode = firstFrame ? opcode : WebSocketOpcode.CONTINUATION;
				} else {
					fin = true;
					length = remaining;
					fragmentOpcode = firstFrame ? opcode : WebSocketOpcode.CONTINUATION;
				}
				// RSV1 on the first frame alone.
				var marked:Bool = compressed && firstFrame;
				firstFrame = false;

				__outgoingMessageBuffer.length = length;
				__outgoingMessageBuffer.position = 0;

				data.readBytes(__outgoingMessageBuffer, 0, length);

				__sendFrame(__outgoingMessageBuffer, fragmentOpcode, fin, marked);
			}
		} else {
			__sendFrame(data, opcode, true, compressed);
		}
	}

	private static function __generateMaskBytes():ByteArray {
		return SecureRandom.getSecureRandomBytes(4);
	}

	private inline function __sendFrame(payload:ByteArray, opcode:Int, isFinal:Bool, compressed:Bool = false):Void {
		if (__socket == null) {
			return;
		}

		// Write the frame header
		var fin:Int = isFinal ? WebSocketHeaderMask.FIN : 0;
		__output.clear();
		__output.writeByte(fin | (compressed ? WebSocketHeaderMask.RSV1 : 0) | opcode);
		var length:Int = payload.length;

		if (__isClient == false) {
			__writePayloadLength(length);
			__output.writeBytes(payload);
		} else {
			__writePayloadLength(length, WebSocketHeaderMask.MASK);
			var frameMask:ByteArray = __generateMaskBytes();

			// Copy in bulk, then mask in place with the same XOR the inbound
			// path uses, rather than a per-byte writeByte through the
			// ByteArray write path.
			__maskedPayload.length = length;
			__maskedPayload.position = 0;
			if (length > 0) {
				(__maskedPayload : Bytes).blit(0, payload, 0, length);
				__applyMask(__maskedPayload, length, frameMask);
			}

			// Write the masked payload
			__output.writeBytes(frameMask);
			__output.writeBytes(__maskedPayload);
		}
		// Hand the frame to the pending buffer rather than writing it
		// directly: a momentarily full socket is a normal condition, and
		// treating it as fatal here used to drop the session outright.
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
	 * Pings the peer, which answers with a pong carrying the same payload,
	 * at most 125 bytes, and none by default. A pong counts as hearing from
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
			payload = new ByteArray();
		}
		__sendFrame(payload, WebSocketOpcode.PONG, true);
	}

	private static function __controlPayload(payload:Null<ByteArray>):ByteArray {
		if (payload == null) {
			return new ByteArray();
		}
		if (payload.length > 125) {
			throw new crossbyte.errors.ArgumentError("A ping or pong carries at most 125 bytes, and this one is " + payload.length + ".");
		}
		return payload;
	}

	@:access(crossbyte._internal.websocket)
	inline function fromAcceptedSocket(socket:#if nodejs NodeSocket #else FlexSocket #end):WebSocket {
		var acceptedSocket:WebSocket = new AcceptedWebSocket();
		acceptedSocket.__initSocket(socket);

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

@:private @:noCompletion class AcceptedWebSocket extends WebSocket {
	private function new() {
		__isClient = false;
		super(null, null, null);
	}
}

@:access(crossbyte._internal.websocket)
inline function fromAcceptedSocket(socket:#if nodejs NodeSocket #else FlexSocket #end):WebSocket {
	var acceptedSocket:WebSocket = new AcceptedWebSocket();
	acceptedSocket.__initSocket(socket);

	return acceptedSocket;
}
#end
