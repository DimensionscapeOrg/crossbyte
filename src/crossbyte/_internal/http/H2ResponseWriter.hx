package crossbyte._internal.http;

import crossbyte._internal.http.h2.H2ErrorCode;
import crossbyte._internal.http.h2.H2ServerConnection;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArray.ByteArrayData;
import crossbyte.net.Socket;
import haxe.io.Bytes;

/**
 * Writes a decided response onto one HTTP/2 stream.
 *
 * The same `HTTPResponseHead` the HTTP/1.1 writer renders as a status line and
 * header block becomes a HEADERS frame here, which is the whole point of the
 * split: routing, static files, content negotiation and CORS produce one
 * response and neither knows nor cares which protocol carries it.
 *
 * Three differences from HTTP/1.1 are forced by the protocol rather than
 * chosen. Field names go out lowercase (§8.2.1 makes any other casing
 * malformed). Connection-management fields are dropped, because HTTP/2 does
 * its own framing and §8.2.2 makes them malformed too, notably `Connection`,
 * which the HTTP/1.1 writer always emits. And the stream has to be closed
 * explicitly, since a stream left open is a request the client still believes
 * is in flight.
 */
class H2ResponseWriter implements HTTPResponseWriter {
	public var connected(get, never):Bool;
	public var ownsConnection(get, never):Bool;
	public var bufferedBytes(get, never):Int;
	public var maxBufferedBytes(get, never):Int;
	public var onDrain(get, set):Null<Void->Void>;
	public var onAbandoned(get, set):Null<Void->Void>;

	private final __connection:H2ServerConnection;
	private final __socket:Socket;
	private final __streamId:Int;

	private var __headSent:Bool = false;
	private var __onDrain:Null<Void->Void> = null;
	private var __onAbandoned:Null<Void->Void> = null;
	private var __ended:Bool = false;

	// The connection's flush, which waits for the end of a read the
	// response is being written in the middle of; see H2ConnectionHandler.
	private final __flush:Void->Void;

	// Where sweepWith registers: the server's sweep, when a server made this.
	private final __sweepWith:Null<({}, Null<Float->Void>) -> Void>;

	public function new(connection:H2ServerConnection, socket:Socket, streamId:Int, ?flush:Void->Void,
			?sweepWith:({}, Null<Float->Void>) -> Void) {
		__connection = connection;
		__socket = socket;
		__streamId = streamId;
		__flush = flush != null ? flush : socket.flush;
		__sweepWith = sweepWith;
	}

	public function sweepWith(check:Null<Float->Void>):Bool {
		if (__sweepWith == null) {
			return false;
		}
		__sweepWith(this, check);
		return true;
	}

	// The stream as well as the connection: a stream the client has reset
	// takes nothing more, though the connection carries on.
	private inline function get_connected():Bool {
		return __socket.connected && !__connection.closed && (__ended || __connection.hasStream(__streamId));
	}

	// The frame layer owns the socket and many streams share it.
	private inline function get_ownsConnection():Bool {
		return true;
	}

	/**
	 * What is queued ahead of the peer, counting both places it can pile up.
	 *
	 * The socket's buffer is only half of it under HTTP/2: bytes the
	 * application has handed over but flow control has not released sit in the
	 * connection's per-stream queue instead. Reporting only the socket would
	 * tell the file pump there is room whenever the socket drained, and it
	 * would keep feeding a body that cannot move, turning the bounded
	 * transfer this watermark exists to guarantee into an unbounded one.
	 */
	private inline function get_bufferedBytes():Int {
		return __socket.outputBufferLength + __connection.queuedFor(__streamId);
	}

	private inline function get_maxBufferedBytes():Int {
		return __socket.maxOutputBufferSize;
	}

	private inline function get_onDrain():Null<Void->Void> {
		return __onDrain;
	}

	/**
	 * Registered with the connection rather than the socket.
	 *
	 * The socket has one drain slot and a connection can carry many streams,
	 * so writers would overwrite each other's callback and every stream but
	 * the last would stall. The connection keeps one per stream and fans the
	 * socket's drain out across them.
	 */
	private function set_onDrain(value:Null<Void->Void>):Null<Void->Void> {
		__onDrain = value;
		__connection.setWritableCallback(__streamId, value);
		return value;
	}

	private inline function get_onAbandoned():Null<Void->Void> {
		return __onAbandoned;
	}

	/** Called on a peer's reset of this stream; see HTTPResponseWriter. */
	private function set_onAbandoned(value:Null<Void->Void>):Null<Void->Void> {
		__onAbandoned = value;
		__connection.setAbandonedCallback(__streamId, value);
		return value;
	}

	/** A HEADERS frame carrying `:status 100` and leaving the stream open: an interim response (RFC 9113 8.1). */
	public function writeContinue():Void {
		if (__headSent) {
			return;
		}
		__connection.sendHeaders(__streamId, 100, [], false);
	}

	public function writeHead(head:HTTPResponseHead):Void {
		if (__headSent) {
			return;
		}
		__headSent = true;

		var fields:Array<HpackHeader> = [];
		for (header in head.headers) {
			var name:String = HttpSyntax.fieldNameForH2(HttpSyntax.sanitizeHeaderName(header.name));
			if (name.length == 0) {
				continue;
			}

			switch (name) {
				case "connection" | "keep-alive" | "proxy-connection" | "transfer-encoding" | "upgrade":
					continue;
				case _:
			}

			fields.push(new HpackHeader(name, HttpSyntax.sanitizeHeaderValue(header.value), __isCredential(name)));
		}

		// content-length is legal on a response and worth sending when known,
		// but it is not what frames the body, END_STREAM is.
		var chunked:Bool = head.chunked == true;
		if (head.contentLength != null && !chunked) {
			fields.push(new HpackHeader("content-length", Std.string(head.contentLength)));
		}

		// A head with no body ends the stream now. Anything else waits for
		// endResponse, because the body may arrive in slices, a chunked one
		// of a length nobody knows yet.
		var empty:Bool = !chunked && (head.contentLength == null || head.contentLength == 0);
		__connection.sendHeaders(__streamId, head.statusCode, fields, empty);
		__ended = empty;
	}

	/**
	 * Whether a field carries a credential, and so goes out never-indexed
	 * (RFC 7541 6.2.3) instead of into the dynamic table.
	 *
	 * Every response field was indexed, a session token in `set-cookie`
	 * included. 7.1.3: an entry's presence can be inferred from the
	 * compressed sizes of later responses an attacker can influence, and a
	 * table filling with one-off tokens evicts the entries worth keeping. The
	 * client already sends its `authorization` and `cookie` this way.
	 */
	private static inline function __isCredential(name:String):Bool {
		return switch (name) {
			case "set-cookie" | "cookie" | "authorization" | "proxy-authorization" | "www-authenticate" | "proxy-authenticate": true;
			case _: false;
		}
	}

	public function writeBody(data:ByteArray, offset:Int, length:Int):Void {
		if (__ended || length <= 0) {
			return;
		}

		// Copied, since the connection keeps what it is given until flow
		// control lets it go, and the caller may write into `data` again.
		var chunk:Bytes = Bytes.alloc(length);
		chunk.blit(0, data, offset, length);
		__connection.sendData(__streamId, chunk, false);
	}

	/**
	 * Kept as it is, not copied, when it is the whole of `data`: a body the
	 * server made for this response, or one it keeps and never changes. Every
	 * response body was copied here, and again into its DATA frame, a
	 * quarter of what a 64 KB response cost under HTTP/2.
	 */
	public function writeBodyTaken(data:ByteArray, offset:Int, length:Int):Void {
		if (__ended || length <= 0) {
			return;
		}
		if (offset != 0 || length != data.length) {
			writeBody(data, offset, length);
			return;
		}
		var whole:ByteArrayData = data;
		__connection.sendData(__streamId, whole, false);
	}

	public function flush():Void {
		__flush();
	}

	public function endResponse():Void {
		if (__ended) {
			return;
		}
		__ended = true;

		// An empty DATA with END_STREAM. Needed whenever the head went out
		// without the flag, which is every response that had a body.
		__connection.sendData(__streamId, null, true);
		__flush();
	}

	public function abort():Void {
		if (__ended) {
			return;
		}
		__ended = true;
		__connection.resetStream(__streamId, H2ErrorCode.INTERNAL_ERROR);
		__flush();
	}
}
