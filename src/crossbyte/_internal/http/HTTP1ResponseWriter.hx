package crossbyte._internal.http;

import crossbyte._internal.http.headers.Connection;
import crossbyte.io.ByteArray;
import crossbyte.net.Socket;

/**
 * Writes a response as HTTP/1.1 onto a socket.
 *
 * The header order is load-bearing in a way that is easy to miss: the tests
 * assert against whole response strings, and a reordered header block is a
 * diff in every one of them.
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

	// Where sweepWith registers: the server's sweep, when a server made this.
	private final __sweepWith:Null<({}, Null<Float->Void>) -> Void>;

	public function new(socket:Socket, ?sweepWith:({}, Null<Float->Void>) -> Void) {
		__socket = socket;
		__sweepWith = sweepWith;
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

	public function sweepWith(check:Null<Float->Void>):Bool {
		if (__sweepWith == null) {
			return false;
		}
		__sweepWith(this, check);
		return true;
	}

	public function writeContinue():Void {
		__socket.writeUTFBytes("HTTP/1.1 100 Continue\r\n\r\n");
	}

	private static final KEEP_ALIVE_LINE:String = "\r\nConnection: " + Connection.KEEP_ALIVE + "\r\n";
	private static final CLOSE_LINE:String = "\r\nConnection: " + Connection.CLOSE + "\r\n";

	public function writeHead(head:HTTPResponseHead):Void {
		// Put together in bytes the thread keeps and handed to the socket in
		// one write, which copies them: joined into a string and that string
		// encoded into bytes of its own, a head was most of what a response
		// allocated.
		var text:ByteArray = HeadBytes.take();
		text.writeUTFBytes("HTTP/1.1 ");
		__writeDecimal(text, head.statusCode);
		text.writeUTFBytes(" ");
		text.writeUTFBytes(head.statusMessage);
		text.writeUTFBytes(head.keepAlive ? KEEP_ALIVE_LINE : CLOSE_LINE);

		for (header in head.headers) {
			var safeName:String = HttpSyntax.sanitizeHeaderName(header.name);
			if (safeName.length == 0) {
				continue;
			}
			text.writeUTFBytes(safeName);
			text.writeUTFBytes(": ");
			text.writeUTFBytes(HttpSyntax.sanitizeHeaderValue(header.value));
			text.writeUTFBytes("\r\n");
		}

		__chunked = head.chunked;
		if (__chunked) {
			text.writeUTFBytes("Transfer-Encoding: chunked\r\n");
		} else if (head.contentLength != null) {
			text.writeUTFBytes("Content-Length: ");
			__writeDecimal(text, head.contentLength);
			text.writeUTFBytes("\r\n");
		}

		text.writeUTFBytes("\r\n");
		__writeTaken(text);
	}

	/** `text` written to the socket, and given back to the thread whatever the write does. **/
	private function __writeTaken(text:ByteArray):Void {
		try {
			__socket.writeBytes(text, 0, text.length);
		} catch (error:Dynamic) {
			HeadBytes.give(text);
			throw error;
		}
		HeadBytes.give(text);
	}

	/** `value`, not negative, in decimal digits, with no string made of it. **/
	private static function __writeDecimal(out:ByteArray, value:Int):Void {
		var unit:Int = 1;
		while (unit <= Std.int(value / 10)) {
			unit *= 10;
		}
		while (unit > 0) {
			var digit:Int = Std.int(value / unit);
			out.writeByte(48 + digit);
			value -= digit * unit;
			unit = Std.int(unit / 10);
		}
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

		var size:ByteArray = HeadBytes.take();
		__writeHex(size, length);
		size.writeUTFBytes("\r\n");
		__writeTaken(size);
		__socket.writeBytes(data, offset, length);
		__socket.writeUTFBytes("\r\n");
	}

	/** A chunk's size, not negative, in upper-case hexadecimal digits, as `StringTools.hex` writes it. **/
	private static function __writeHex(out:ByteArray, value:Int):Void {
		var shift:Int = 28;
		while (shift > 0 && ((value >>> shift) & 0xF) == 0) {
			shift -= 4;
		}
		while (shift >= 0) {
			var digit:Int = (value >>> shift) & 0xF;
			out.writeByte(digit < 10 ? 48 + digit : 55 + digit);
			shift -= 4;
		}
	}

	// The socket copies what it is given into its own buffer either way.
	public function writeBodyTaken(data:ByteArray, offset:Int, length:Int):Void {
		writeBody(data, offset, length);
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

/**
	The bytes a head, or a chunk's size line, is put together in before the
	socket copies them, kept a thread at a time: nothing that writes a head
	begins another before it is written. One taken while another is out is
	made anew, and one grown past 16 KB is not kept.
**/
private class HeadBytes {
	static inline var KEEP:Int = 16 * 1024;

	#if target.threaded
	static final __spare:sys.thread.Tls<ByteArray> = new sys.thread.Tls();
	#else
	static var __spareOnly:Null<ByteArray> = null;
	#end

	public static function take():ByteArray {
		#if target.threaded
		var spare:Null<ByteArray> = __spare.value;
		__spare.value = null;
		#else
		var spare:Null<ByteArray> = __spareOnly;
		__spareOnly = null;
		#end
		if (spare == null) {
			return new ByteArray();
		}
		spare.length = 0;
		spare.position = 0;
		return spare;
	}

	public static function give(bytes:ByteArray):Void {
		if (@:privateAccess (bytes : crossbyte.io.ByteArray.ByteArrayData).__length > KEEP) {
			return;
		}
		#if target.threaded
		__spare.value = bytes;
		#else
		__spareOnly = bytes;
		#end
	}
}
