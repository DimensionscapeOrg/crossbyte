package crossbyte._internal.http;

import crossbyte._internal.http.headers.Connection;
import crossbyte.io.ByteArray;
import crossbyte.net.Socket;

/**
 * Writes a response as HTTP/1.1 onto a socket.
 *
 * The behaviour extracted verbatim from `HTTPRequestHandler`, including the
 * header order it emitted, which is load-bearing in a way that is easy to miss:
 * the tests assert against whole response strings, and a reordered header block
 * is a diff in every one of them.
 */
class HTTP1ResponseWriter implements HTTPResponseWriter {
	public var connected(get, never):Bool;
	public var ownsConnection(get, never):Bool;
	public var bufferedBytes(get, never):Int;
	public var maxBufferedBytes(get, never):Int;
	public var onDrain(get, set):Null<Void->Void>;
	public var onAbandoned(get, set):Null<Void->Void>;

	private final __socket:Socket;
	private var __onAbandoned:Null<Void->Void> = null;
	// Set by a head that promised chunked framing, until endResponse.
	private var __chunked:Bool = false;

	public function new(socket:Socket) {
		__socket = socket;
	}

	private inline function get_connected():Bool {
		return __socket.connected;
	}

	// One response per connection at a time, and the Connection header is how
	// its fate is announced, so the response decides.
	private inline function get_ownsConnection():Bool {
		return false;
	}

	private inline function get_bufferedBytes():Int {
		return __socket.outputBufferLength;
	}

	private inline function get_maxBufferedBytes():Int {
		return __socket.maxOutputBufferSize;
	}

	private inline function get_onDrain():Null<Void->Void> {
		return @:privateAccess __socket.__onWritableDrain;
	}

	private inline function set_onDrain(value:Null<Void->Void>):Null<Void->Void> {
		return @:privateAccess __socket.__onWritableDrain = value;
	}

	// Kept but never called: see HTTPResponseWriter.onAbandoned.
	private inline function get_onAbandoned():Null<Void->Void> {
		return __onAbandoned;
	}

	private inline function set_onAbandoned(value:Null<Void->Void>):Null<Void->Void> {
		return __onAbandoned = value;
	}

	public function writeHead(head:HTTPResponseHead):Void {
		var response:String = "HTTP/1.1 " + head.statusCode + " " + head.statusMessage + "\r\n";
		response += "Connection: " + (head.keepAlive ? Connection.KEEP_ALIVE : Connection.CLOSE) + "\r\n";

		for (header in head.headers) {
			var safeName:String = HttpSyntax.sanitizeHeaderName(header.name);
			if (safeName.length == 0) {
				continue;
			}
			response += safeName + ": " + HttpSyntax.sanitizeHeaderValue(header.value) + "\r\n";
		}

		__chunked = head.chunked == true;
		if (__chunked) {
			response += "Transfer-Encoding: chunked\r\n";
		} else if (head.contentLength != null) {
			response += "Content-Length: " + head.contentLength + "\r\n";
		}

		response += "\r\n";
		__socket.writeUTFBytes(response);
	}

	public function writeBody(data:ByteArray, offset:Int, length:Int):Void {
		if (!__chunked) {
			__socket.writeBytes(data, offset, length);
			return;
		}
		if (length <= 0) {
			// A zero-length chunk would be the last one.
			return;
		}

		__socket.writeUTFBytes(StringTools.hex(length) + "\r\n");
		__socket.writeBytes(data, offset, length);
		__socket.writeUTFBytes("\r\n");
	}

	public function flush():Void {
		__socket.flush();
	}

	public function endResponse():Void {
		// Content-Length or connection close already told the peer where a
		// body ends, except a chunked one, whose end is the last chunk.
		if (__chunked) {
			__chunked = false;
			__socket.writeUTFBytes("0\r\n\r\n");
		}
	}

	public function abort():Void {
		__chunked = false;
		if (__socket.connected) {
			__socket.close();
		}
	}
}
