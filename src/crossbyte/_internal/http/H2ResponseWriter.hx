package crossbyte._internal.http;

import crossbyte._internal.http.h2.H2ServerConnection;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte.io.ByteArray;
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
 * its own framing and §8.2.2 makes them malformed too -- notably `Connection`,
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

	private final __connection:H2ServerConnection;
	private final __socket:Socket;
	private final __streamId:Int;

	private var __headSent:Bool = false;
	private var __onDrain:Null<Void->Void> = null;
	private var __ended:Bool = false;

	public function new(connection:H2ServerConnection, socket:Socket, streamId:Int) {
		__connection = connection;
		__socket = socket;
		__streamId = streamId;
	}

	private inline function get_connected():Bool {
		return __socket.connected && !__connection.closed;
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
	 * would keep feeding a body that cannot move -- turning the bounded
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

	public function writeHead(head:HTTPResponseHead):Void {
		if (__headSent) {
			return;
		}
		__headSent = true;

		var fields:Array<HpackHeader> = [];
		for (header in head.headers) {
			var name:String = HttpSyntax.sanitizeHeaderName(header.name).toLowerCase();
			if (name.length == 0) {
				continue;
			}

			switch (name) {
				case "connection" | "keep-alive" | "proxy-connection" | "transfer-encoding" | "upgrade":
					continue;
				case _:
			}

			fields.push(new HpackHeader(name, HttpSyntax.sanitizeHeaderValue(header.value)));
		}

		// content-length is legal on a response and worth sending when known,
		// but it is not what frames the body -- END_STREAM is.
		if (head.contentLength != null) {
			fields.push(new HpackHeader("content-length", Std.string(head.contentLength)));
		}

		// A head with no body ends the stream now. Anything else waits for
		// endResponse, because the body may arrive in slices.
		var empty:Bool = head.contentLength == null || head.contentLength == 0;
		__connection.sendHeaders(__streamId, head.statusCode, fields, empty);
		__ended = empty;
	}

	public function writeBody(data:ByteArray, offset:Int, length:Int):Void {
		if (__ended || length <= 0) {
			return;
		}

		var chunk:Bytes = Bytes.alloc(length);
		chunk.blit(0, data, offset, length);
		__connection.sendData(__streamId, chunk, false);
	}

	public function flush():Void {
		__socket.flush();
	}

	public function endResponse():Void {
		if (__ended) {
			return;
		}
		__ended = true;

		// An empty DATA with END_STREAM. Needed whenever the head went out
		// without the flag, which is every response that had a body.
		__connection.sendData(__streamId, null, true);
		__socket.flush();
	}
}
