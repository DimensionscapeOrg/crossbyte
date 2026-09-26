package crossbyte._internal.php;

#if !(js && !nodejs)
import crossbyte.Future;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;

/**
 * One FastCGI request/response exchange, in progress.
 *
 * The parsing lives here rather than in the bridge because it is the half that
 * does not care how the bytes arrived. A native build reads them from its
 * socket when the runtime's poll set reports them; Node is handed them by an
 * event. Both feed `receive`, and neither knows anything about records.
 *
 * That split is also what makes the two implementations testable as one thing.
 * The old bridge read and parsed in a single blocking loop, so the parser could
 * only be exercised by standing up a real php-fpm.
 */
class PHPExchange {
	/** Resolved with the response, or rejected with why not. Exactly once. */
	public final future:Future<PHPResponse> = new Future<PHPResponse>();

	/** When this gives up, or `0` for never. */
	public final deadline:Float;

	/** `true` once the future has been settled and the socket is finished with. */
	public var settled(default, null):Bool = false;

	private final timeoutSeconds:Float;

	// Bytes that have arrived and not yet formed a whole record. FastCGI has no
	// framing above the record header, so a partial record is normal and has to
	// be carried until the rest of it turns up -- which the blocking reader
	// never had to think about, because it simply asked for more.
	private var pending:ByteArray = new ByteArray();

	// FCGI_STDOUT content, accumulated across records.
	private var stdout:ByteArray = new ByteArray();

	private var finished:Bool = false;

	public function new(timeoutSeconds:Float) {
		this.timeoutSeconds = timeoutSeconds;
		this.deadline = timeoutSeconds > 0 ? haxe.Timer.stamp() + timeoutSeconds : 0;
	}

	/**
	 * Feeds arriving bytes in, and returns `true` once `END_REQUEST` has landed
	 * and the response is ready.
	 */
	public function receive(chunk:Bytes, length:Int):Bool {
		if (finished || length <= 0) {
			return finished;
		}

		pending.position = pending.length;
		pending.writeBytes(ByteArray.fromBytes(chunk), 0, length);

		__parse();
		return finished;
	}

	/** The parsed response. Only meaningful once `receive` has returned true. */
	public function response():PHPResponse {
		return __toResponse();
	}

	/** Whether the clock has run out on this exchange. */
	public function expired():Bool {
		return deadline > 0 && haxe.Timer.stamp() >= deadline;
	}

	public function succeed():Void {
		if (settled) {
			return;
		}

		settled = true;
		@:privateAccess future.__resolve(__toResponse());
	}

	/**
	 * Fails the exchange, optionally carrying the thing that went wrong.
	 *
	 * The `cause` is what lets a caller tell a timeout from a refused
	 * connection without reading the message. `HTTPRequestHandler` answers
	 * `504` for one and `502` for the other, and it decided that by searching
	 * the message for "did not respond within" -- so rewording a `PHPTimeout`
	 * would have silently changed a status code.
	 */
	public function fail(message:String, ?cause:Dynamic):Void {
		if (settled) {
			return;
		}

		settled = true;
		@:privateAccess future.__fail(message, cause);
	}

	public function timeOut(phase:String):Void {
		var expiry = new PHPTimeout(timeoutSeconds, phase);
		fail(expiry.toString(), expiry);
	}

	/**
	 * Consumes whole records from the front of `pending`, leaving any partial
	 * one for the next arrival.
	 */
	private function __parse():Void {
		var offset:Int = 0;

		while (pending.length - offset >= HEADER_LENGTH) {
			pending.position = offset + 1;
			var type:Int = pending.readUnsignedByte();

			pending.position = offset + 4;
			var contentLength:Int = (pending.readUnsignedByte() << 8) | pending.readUnsignedByte();
			var padding:Int = pending.readUnsignedByte();
			var record:Int = HEADER_LENGTH + contentLength + padding;

			// The whole record or none of it. Reading a header and then waiting
			// for its content mid-parse is what the blocking loop did, and it
			// is exactly what an event-driven reader cannot do.
			if (pending.length - offset < record) {
				break;
			}

			if (type == STDOUT && contentLength > 0) {
				stdout.position = stdout.length;
				pending.position = offset + HEADER_LENGTH;
				pending.readBytes(stdout, stdout.length, contentLength);
			} else if (type == END_REQUEST) {
				finished = true;
				offset += record;
				break;
			}

			// FCGI_STDERR is read and dropped, which is what the blocking
			// implementation did with the logging commented out. Kept the same
			// here deliberately: changing it belongs with a decision about
			// where a backend's diagnostics should go, not with a rewrite of
			// how bytes arrive.
			offset += record;
		}

		if (offset > 0) {
			__consume(offset);
		}
	}

	private function __consume(count:Int):Void {
		if (count >= pending.length) {
			pending.clear();
			return;
		}

		var rest = new ByteArray();
		rest.writeBytes(pending, count, pending.length - count);
		pending = rest;
	}

	/**
	 * Splits the CGI header block from the body.
	 *
	 * On the bytes. Only the header block is text; the body is whatever the
	 * script sent -- an image, a PDF, a zip, gzip output, a Latin-1 page -- and
	 * is handed on untouched. The whole payload used to be decoded as UTF-8 to
	 * find the separator and the body re-encoded from the string, which
	 * mangled every byte sequence that was not valid UTF-8, truncated the body
	 * at its first NUL on Node, and threw from inside the tick on eval.
	 *
	 * A repeated field is joined rather than overwritten, by the rule
	 * `HTTPRequestContext.onHeaders` documents: `", "` between values, except
	 * `set-cookie`, which is joined with `"\n"` because a cookie carries commas
	 * of its own. PHP sends one `Set-Cookie` line per cookie, and storing each
	 * under its name kept only the last.
	 */
	private function __toResponse():PHPResponse {
		var raw:Bytes = stdout;
		var total:Int = stdout.length;
		var separator:Int = __headerEnd(raw, total);
		var headers:Map<String, String> = new Map();
		var status:Int = 200;

		if (separator < 0) {
			return {status: status, headers: headers, body: raw};
		}

		for (line in __headerText(raw, separator).split("\r\n")) {
			var colon:Int = line.indexOf(":");

			if (colon <= 0) {
				continue;
			}

			var name:String = line.substr(0, colon).toLowerCase();
			var value:String = StringTools.trim(line.substr(colon + 1));

			if (headers.exists(name)) {
				var joiner:String = name == "set-cookie" ? "\n" : ", ";
				headers.set(name, headers.get(name) + joiner + value);
			} else {
				headers.set(name, value);
			}

			if (name == "status") {
				var parts:Array<String> = value.split(" ");

				if (parts.length > 0) {
					// Three digits or nothing: the backend is a peer, and
					// Std.parseInt reads an overlong number differently on
					// every target.
					var parsed:Int = crossbyte.utils.IntParse.decimal(parts[0], 999);

					if (parsed >= 100) {
						status = parsed;
					}
				}
			}
		}

		var bodyStart:Int = separator + 4;
		return {status: status, headers: headers, body: raw.sub(bodyStart, total - bodyStart)};
	}

	/** Where the blank line ending the header block starts, or `-1`. **/
	private static function __headerEnd(data:Bytes, length:Int):Int {
		var last:Int = length - 4;
		var i:Int = 0;

		while (i <= last) {
			if (data.get(i + 3) != 10) {
				// Not the end of a CRLF CRLF anywhere this could start, so skip
				// ahead by as much as that rules out.
				i += data.get(i + 3) == 13 ? 1 : 4;
				continue;
			}

			if (data.get(i) == 13 && data.get(i + 1) == 10 && data.get(i + 2) == 13) {
				return i;
			}

			i++;
		}

		return -1;
	}

	/**
	 * The header block as text: UTF-8 where it is valid UTF-8, which is how a
	 * script writes a non-ASCII filename into Content-Disposition, and a byte
	 * per character otherwise, which cannot fail. Decoding invalid UTF-8
	 * throws on eval, and a backend should not be able to throw from inside
	 * the tick.
	 */
	private static function __headerText(data:Bytes, length:Int):String {
		if (__isUtf8(data, length)) {
			return data.getString(0, length);
		}

		var out = new StringBuf();

		for (i in 0...length) {
			out.addChar(data.get(i));
		}

		return out.toString();
	}

	private static function __isUtf8(data:Bytes, length:Int):Bool {
		var i:Int = 0;

		while (i < length) {
			var c:Int = data.get(i);

			if (c < 0x80) {
				i++;
				continue;
			}

			var extra:Int;
			var min:Int;

			if (c >= 0xC2 && c <= 0xDF) {
				extra = 1;
				min = 0x80;
			} else if (c >= 0xE0 && c <= 0xEF) {
				extra = 2;
				min = 0x800;
			} else if (c >= 0xF0 && c <= 0xF4) {
				extra = 3;
				min = 0x10000;
			} else {
				return false;
			}

			if (i + extra >= length) {
				return false;
			}

			var code:Int = c & (0x3F >> extra);

			for (k in 1...extra + 1) {
				var next:Int = data.get(i + k);

				if ((next & 0xC0) != 0x80) {
					return false;
				}

				code = (code << 6) | (next & 0x3F);
			}

			// Overlong forms, surrogates and past U+10FFFF.
			if (code < min || (code >= 0xD800 && code <= 0xDFFF) || code > 0x10FFFF) {
				return false;
			}

			i += extra + 1;
		}

		return true;
	}

	private static inline var HEADER_LENGTH:Int = 8;
	private static inline var STDOUT:Int = 6;
	private static inline var END_REQUEST:Int = 3;
}
#end
