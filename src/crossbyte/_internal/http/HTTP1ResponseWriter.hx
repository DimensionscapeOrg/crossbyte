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

	private final __socket:Socket;

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

		if (head.contentLength != null) {
			response += "Content-Length: " + head.contentLength + "\r\n";
		}

		response += "\r\n";
		__socket.writeUTFBytes(response);
	}

	public function writeBody(data:ByteArray, offset:Int, length:Int):Void {
		__socket.writeBytes(data, offset, length);
	}

	public function flush():Void {
		__socket.flush();
	}

	public function endResponse():Void {
		// Nothing to do: Content-Length or connection close already told the
		// peer where the body ends.
	}
}
