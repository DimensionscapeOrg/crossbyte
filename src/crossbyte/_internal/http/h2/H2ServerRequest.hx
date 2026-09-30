package crossbyte._internal.http.h2;

import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte.utils.IntParse;
import haxe.io.Bytes;

/**
 * A request decoded from a client's header block.
 *
 * Pseudo-header validation lives here rather than in the connection because
 * every rule in RFC 9113 §8.3.1 is about one message: a request carries
 * exactly one `:method`, `:scheme` and `:path`, never a `:status`, and no
 * pseudo-header may follow a regular field. A message breaking any of them is
 * *malformed*, which §8.1.1 makes a stream error -- the connection is fine and
 * other streams keep running.
 */
class H2ServerRequest {
	public final streamId:Int;
	public final method:String;
	public final scheme:String;
	public final authority:String;
	public final path:String;

	/** Regular fields, lowercased, in the order they arrived. */
	public final headers:Array<HpackHeader>;

	/** Request body, empty when there was none. */
	public var body:Bytes;

	/**
	 * Set when the body grew past `H2ServerConnection.maxRequestBodySize`
	 * before it ended. The request is delivered then, with no body, so it can
	 * be answered `413` rather than buffered further.
	 */
	public var tooLarge:Bool = false;

	/**
	 * Set when the request's header section decoded past the limit, so only
	 * its pseudo-header fields are here and it is to be answered `431`. See
	 * `withHeadersTooLarge`.
	 */
	public var headersTooLarge:Bool = false;

	/**
	 * A request whose header section went past the limit: what arrived of its
	 * pseudo-header fields, the rest left out as not all there, and
	 * `headersTooLarge` set. Nothing here is validated, since nothing about it
	 * is served but the refusal.
	 */
	public static function withHeadersTooLarge(streamId:Int, decoded:Array<HpackHeader>):H2ServerRequest {
		var method:String = "GET";
		var scheme:String = "http";
		var authority:String = "";
		var path:String = "/";
		for (field in decoded) {
			switch (field.name) {
				case ":method":
					method = field.value;
				case ":scheme":
					scheme = field.value;
				case ":authority":
					authority = field.value;
				case ":path":
					path = field.value;
				case _:
			}
		}

		var request:H2ServerRequest = new H2ServerRequest(streamId, method, scheme, authority, path, [], Bytes.alloc(0));
		request.headersTooLarge = true;
		return request;
	}

	public function new(streamId:Int, method:String, scheme:String, authority:String, path:String, headers:Array<HpackHeader>, body:Bytes) {
		this.streamId = streamId;
		this.method = method;
		this.scheme = scheme;
		this.authority = authority;
		this.path = path;
		this.headers = headers;
		this.body = body;
	}

	public function header(name:String):Null<String> {
		for (field in headers) {
			if (field.name == name) {
				return field.value;
			}
		}
		return null;
	}

	/**
	 * Builds a request from a decoded header block, or throws `H2StreamError`
	 * when the message is malformed.
	 *
	 * @param partial The body stopped short of its end, so `content-length`
	 *        cannot be held to it.
	 */
	public static function fromHeaders(streamId:Int, decoded:Array<HpackHeader>, body:Bytes, partial:Bool = false):H2ServerRequest {
		var method:String = null;
		var scheme:String = null;
		var authority:String = null;
		var path:String = null;
		var regular:Array<HpackHeader> = [];
		var seenRegular:Bool = false;

		for (field in decoded) {
			var name:String = field.name;

			if (name.length == 0) {
				throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, "Header field with an empty name");
			}

			// §8.2.1: no CR, LF or NUL in a value, no whitespace at its ends,
			// and nothing in a name but visible, lowercase ASCII. HPACK
			// carries any byte, so a line break reached the request middleware
			// sees. An uppercase name is malformed rather than merely unusual:
			// normalising it would let two spellings of one header disagree
			// about which a router matched.
			var problem:Null<String> = H2FieldRules.violation(name, field.value);
			if (problem != null) {
				throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, problem);
			}

			if (name.charAt(0) == ":") {
				if (seenRegular) {
					// §8.3: pseudo-headers come first. Allowing a late one
					// would let a request smuggle a second :path past anything
					// that scanned only the leading block.
					throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, 'Pseudo-header $name appeared after a regular field');
				}

				switch (name) {
					case ":method":
						method = __once(streamId, name, method, field.value);
					case ":scheme":
						scheme = __once(streamId, name, scheme, field.value);
					case ":authority":
						authority = __once(streamId, name, authority, field.value);
					case ":path":
						path = __once(streamId, name, path, field.value);
					case _:
						// §8.3 makes an unrecognised pseudo-header malformed --
						// including :status, which belongs to a response.
						throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, 'Unexpected pseudo-header $name on a request');
				}
				continue;
			}

			seenRegular = true;

			switch (name) {
				case "connection" | "keep-alive" | "proxy-connection" | "transfer-encoding" | "upgrade":
					// §8.2.2: HTTP/2 has its own framing, so these are
					// malformed rather than merely redundant.
					throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, 'Connection-specific header field "$name" is not allowed');
				case "te":
					// §8.2.2 carves out exactly one permitted value.
					if (field.value != "trailers") {
						throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, 'te may only be "trailers", got "${field.value}"');
					}
				case "content-length":
					// §8.1.1: a request whose content-length differs from the
					// DATA it carried is malformed. END_STREAM frames the body
					// here, but the field still reaches middleware and PHP,
					// which would otherwise be told a length the body does not
					// have. Read through IntParse, so a value no Int can hold is
					// not mistaken for a small one, as Std.parseInt does on
					// Linux native.
					var declared:Int = IntParse.decimal(field.value);
					var received:Int = body == null ? 0 : body.length;
					if (declared < 0 || (!partial && declared != received)) {
						throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR,
							'content-length "${field.value}" does not match the $received bytes of DATA received');
					}
				case _:
			}

			regular.push(field);
		}

		if (method == null) {
			throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, "Request is missing :method");
		}

		// CONNECT omits :scheme and :path by design (§8.5) and is not
		// something this server accepts, so it is refused by name rather than
		// falling through the checks below with two nulls.
		if (method == "CONNECT") {
			throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, "CONNECT is not supported");
		}

		if (scheme == null) {
			throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, "Request is missing :scheme");
		}
		if (path == null || path.length == 0) {
			throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, "Request is missing a non-empty :path");
		}

		return new H2ServerRequest(streamId, method, scheme, authority == null ? "" : authority, path, regular, body == null ? Bytes.alloc(0) : body);
	}

	private static function __once(streamId:Int, name:String, current:String, value:String):String {
		if (current != null) {
			throw new H2StreamError(streamId, H2ErrorCode.PROTOCOL_ERROR, 'Duplicate pseudo-header $name');
		}
		return value;
	}
}
