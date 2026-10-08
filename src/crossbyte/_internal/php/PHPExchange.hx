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
 * That split is also what makes the two implementations testable as one
 * thing: the parser can be exercised without standing up a real php-fpm.
 */
class PHPExchange {
	/**
		Bytes a response may take by default (its CGI header block and body
		together, as the script writes them) before the exchange fails: 8
		MB. `HTTPServerConfig.phpMaxResponseSize` sets it.
	**/
	public static inline var DEFAULT_MAX_RESPONSE_SIZE:Int = 8 * 1024 * 1024;

	/**
		Bytes the CGI header block may take, up to the blank line ending it:
		64 KB, the limit the server holds a request's header block to.
	**/
	public static inline var MAX_HEADER_BYTES:Int = 64 * 1024;

	/** Lines the CGI header block may hold, `Status` among them. **/
	public static inline var MAX_HEADER_FIELDS:Int = 100;

	/** Resolved with the response, or rejected with why not. Exactly once. */
	public final future:Future<PHPResponse> = new Future<PHPResponse>();

	/** When this gives up, or `0` for never. */
	public final deadline:Float;

	/** `true` once the future has been settled and the socket is finished with. */
	public var settled(default, null):Bool = false;

	private final timeoutSeconds:Float;

	/** The most bytes the response may take; `0` or less for no limit. */
	private final maxResponseSize:Int;

	// Bytes that have arrived and not yet formed a whole record. FastCGI has no
	// framing above the record header, so a partial record is normal and has to
	// be carried until the rest of it turns up.
	private var pending:ByteArray = new ByteArray();

	// FCGI_STDOUT content, accumulated across records.
	private var stdout:ByteArray = new ByteArray();

	// Where the blank line ending the header block starts in `stdout`, once
	// it has arrived, and how far the search for it has looked.
	private var headerEnd:Int = -1;
	private var searchedTo:Int = 0;

	private var finished:Bool = false;

	public function new(timeoutSeconds:Float, maxResponseSize:Int = DEFAULT_MAX_RESPONSE_SIZE) {
		this.timeoutSeconds = timeoutSeconds;
		this.maxResponseSize = maxResponseSize;
		this.deadline = timeoutSeconds > 0 ? haxe.Timer.stamp() + timeoutSeconds : 0;
	}

	/**
	 * Feeds arriving bytes in, and returns `true` once `END_REQUEST` has landed
	 * and the response is ready.
	 *
	 * A response past `maxResponseSize`, or whose header block runs past
	 * `MAX_HEADER_BYTES` or `MAX_HEADER_FIELDS`, fails the exchange here, as it
	 * arrives: this then returns false with `settled` set, and the caller lets
	 * the connection go. Without these bounds a script, or a backend not
	 * running PHP at all, could choose how much of the server's memory it
	 * took.
	 */
	public function receive(chunk:Bytes, length:Int):Bool {
		if (finished || settled || length <= 0) {
			return finished;
		}

		pending.position = pending.length;
		pending.writeBytes(ByteArray.fromBytes(chunk), 0, length);

		__parse();
		return finished && !settled;
	}

	/** Seconds left before the deadline, or `0` when there is none. A deadline passed is a sliver, never `0`. */
	public function remaining():Float {
		if (deadline <= 0) {
			return 0;
		}
		var left:Float = deadline - haxe.Timer.stamp();
		return left > 0.001 ? left : 0.001;
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
	 * `504` for one and `502` for the other, and rewording a `PHPTimeout`
	 * must not silently change a status code.
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

			// The whole record or none of it: an event-driven reader cannot read
			// a header and then wait for its content mid-parse.
			if (pending.length - offset < record) {
				break;
			}

			if (type == STDOUT && contentLength > 0) {
				if (maxResponseSize > 0 && stdout.length + contentLength > maxResponseSize) {
					fail("PHP response exceeded " + maxResponseSize + " bytes");
					return;
				}
				stdout.position = stdout.length;
				pending.position = offset + HEADER_LENGTH;
				pending.readBytes(stdout, stdout.length, contentLength);
				if (headerEnd < 0 && !__findHeaderEnd()) {
					return;
				}
			} else if (type == END_REQUEST) {
				finished = true;
				offset += record;
				break;
			}

			// FCGI_STDERR is read and dropped. Changing that belongs with a
			// decision about where a backend's diagnostics should go.
			offset += record;
		}

		if (offset > 0) {
			__consume(offset);
		}
	}

	/**
		Looks for the end of the header block in what has arrived since the
		last look, and holds the block to its limits: answers false, having
		failed the exchange, for one past them. A look covers each byte once,
		so a header block arriving a record at a time costs what it would
		whole.
	**/
	private function __findHeaderEnd():Bool {
		var raw:Bytes = stdout;
		var from:Int = searchedTo > 3 ? searchedTo - 3 : 0;
		var found:Int = __headerEnd(raw, stdout.length, from);
		if (found < 0) {
			searchedTo = stdout.length;
			if (stdout.length > MAX_HEADER_BYTES) {
				fail("PHP response header block exceeded " + MAX_HEADER_BYTES + " bytes");
				return false;
			}
			return true;
		}
		headerEnd = found;
		if (found > MAX_HEADER_BYTES) {
			fail("PHP response header block exceeded " + MAX_HEADER_BYTES + " bytes");
			return false;
		}
		// Its lines: one more than the line breaks inside it.
		var lines:Int = 1;
		for (i in 0...found) {
			if (raw.get(i) == 10) {
				lines++;
			}
		}
		if (lines > MAX_HEADER_FIELDS) {
			fail("PHP response header block had " + lines + " lines, more than the " + MAX_HEADER_FIELDS + " allowed");
			return false;
		}
		return true;
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
	 * script sent (an image, a PDF, a zip, gzip output, a Latin-1 page) and
	 * is handed on untouched. Decoding it as UTF-8 would mangle every byte
	 * sequence that is not valid UTF-8, truncate the body at its first NUL
	 * on Node, and throw from inside the tick on eval.
	 *
	 * A repeated field is joined rather than overwritten, by the rule
	 * `HTTPRequestContext.onHeaders` documents: `", "` between values, except
	 * `set-cookie`, which is joined with `"\n"` because a cookie carries commas
	 * of its own. PHP sends one `Set-Cookie` line per cookie, and every one
	 * is kept.
	 *
	 * The repeats of a field are gathered and joined once, at the end:
	 * adding each to the whole value so far is quadratic in the repeats,
	 * and 40,000 lines of one field would hold the runtime for seconds.
	 */
	private function __toResponse():PHPResponse {
		var raw:Bytes = stdout;
		var total:Int = stdout.length;
		var separator:Int = headerEnd >= 0 ? headerEnd : __headerEnd(raw, total, 0);
		var headers:Map<String, String> = new Map();
		var repeats:Null<Map<String, Array<String>>> = null;
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

			var first:Null<String> = headers.get(name);
			if (first == null) {
				headers.set(name, value);
			} else {
				if (repeats == null) {
					repeats = new Map();
				}
				var values:Null<Array<String>> = repeats.get(name);
				if (values == null) {
					values = [first];
					repeats.set(name, values);
				}
				values.push(value);
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

		if (repeats != null) {
			for (name => values in repeats) {
				headers.set(name, values.join(name == "set-cookie" ? "\n" : ", "));
			}
		}

		var bodyStart:Int = separator + 4;
		return {status: status, headers: headers, body: raw.sub(bodyStart, total - bodyStart)};
	}

	/** Where the blank line ending the header block starts, looking from `from`, or `-1`. **/
	private static function __headerEnd(data:Bytes, length:Int, from:Int):Int {
		var last:Int = length - 4;
		var i:Int = from;

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
