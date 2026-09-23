package crossbyte._internal.php;

#if !(js && !nodejs)
import crossbyte.Future;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;

/**
 * One FastCGI request/response exchange, in progress.
 *
 * The parsing lives here rather than in the bridge because it is the half that
 * does not care how the bytes arrived. A native build reads them from a
 * non-blocking socket on a tick; Node is handed them by an event. Both feed
 * `receive`, and neither knows anything about records.
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
		this.deadline = timeoutSeconds > 0 ? Sys.time() + timeoutSeconds : 0;
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
		return deadline > 0 && Sys.time() >= deadline;
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
	 * The split is unchanged from the blocking implementation, including its
	 * use of the whole payload as text to find the separator.
	 *
	 * A repeated field is joined rather than overwritten, by the rule
	 * `HTTPRequestContext.onHeaders` documents: `", "` between values, except
	 * `set-cookie`, which is joined with `"\n"` because a cookie carries commas
	 * of its own. PHP sends one `Set-Cookie` line per cookie, and storing each
	 * under its name kept only the last.
	 */
	private function __toResponse():PHPResponse {
		var raw:Bytes = stdout;
		var text:String = raw.toString();
		var separator:Int = text.indexOf("\r\n\r\n");
		var headers:Map<String, String> = new Map();
		var status:Int = 200;
		var body:Bytes = Bytes.alloc(0);

		if (separator < 0) {
			return {status: status, headers: headers, body: raw};
		}

		for (line in text.substr(0, separator).split("\r\n")) {
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
					var parsed = Std.parseInt(parts[0]);

					if (parsed != null) {
						status = parsed;
					}
				}
			}
		}

		body = Bytes.ofString(text.substr(separator + 4));
		return {status: status, headers: headers, body: body};
	}

	private static inline var HEADER_LENGTH:Int = 8;
	private static inline var STDOUT:Int = 6;
	private static inline var END_REQUEST:Int = 3;
}
#end
