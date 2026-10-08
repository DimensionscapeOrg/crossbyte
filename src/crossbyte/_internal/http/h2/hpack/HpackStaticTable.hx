package crossbyte._internal.http.h2.hpack;

/**
 * The 61-entry static table from RFC 7541 Appendix A.
 *
 * Indices are 1-based on the wire, so `NAMES[0]` is index 1. Entries with an
 * empty value are name-only: index 15 refers to `accept-charset` with no
 * value, and a literal that cites it supplies its own.
 */
class HpackStaticTable {
	public static final NAMES:Array<String> = [
		":authority", ":method", ":method", ":path", ":path", ":scheme", ":scheme", ":status", ":status", ":status", ":status", ":status", ":status",
		":status", "accept-charset", "accept-encoding", "accept-language", "accept-ranges", "accept", "access-control-allow-origin", "age", "allow",
		"authorization", "cache-control", "content-disposition", "content-encoding", "content-language", "content-length", "content-location",
		"content-range", "content-type", "cookie", "date", "etag", "expect", "expires", "from", "host", "if-match", "if-modified-since", "if-none-match",
		"if-range", "if-unmodified-since", "last-modified", "link", "location", "max-forwards", "proxy-authenticate", "proxy-authorization", "range",
		"referer", "refresh", "retry-after", "server", "set-cookie", "strict-transport-security", "transfer-encoding", "user-agent", "vary", "via",
		"www-authenticate"
	];

	public static final VALUES:Array<String> = [
		"", "GET", "POST", "/", "/index.html", "http", "https", "200", "204", "206", "304", "400", "404", "500", "", "gzip, deflate", "", "", "", "", "",
		"", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
		"", "", "", ""
	];

	public static inline var LENGTH:Int = 61;

	/**
	 * Every entry as a field, `FIELDS[0]` being index 1. Built with the class,
	 * after the two lists above, so every thread sees it whole; the decoder
	 * hands these out rather than making one per reference.
	 */
	public static final FIELDS:Array<HpackHeader> = [for (i in 0...LENGTH) new HpackHeader(NAMES[i], VALUES[i])];

	// name -> first static index carrying it, and name -> value -> exact
	// index. Built once, with the class: a linear scan of 61 entries per
	// header is the kind of cost that only shows up under load.
	//
	// A map per name rather than one keyed by name and value joined with a
	// NUL: a HashLink string ends at its first NUL, so every pair of a name
	// would hash and compare as the name alone.
	private static final __byName:Map<String, Int> = __indexNames();
	private static final __byPair:Map<String, Map<String, Int>> = __indexPairs();

	private static function __indexNames():Map<String, Int> {
		var byName:Map<String, Int> = new Map();
		for (i in 0...LENGTH) {
			if (!byName.exists(NAMES[i])) {
				byName.set(NAMES[i], i + 1);
			}
		}
		return byName;
	}

	private static function __indexPairs():Map<String, Map<String, Int>> {
		var byPair:Map<String, Map<String, Int>> = new Map();
		for (i in 0...LENGTH) {
			var values:Null<Map<String, Int>> = byPair.get(NAMES[i]);
			if (values == null) {
				values = new Map();
				byPair.set(NAMES[i], values);
			}
			values.set(VALUES[i], i + 1);
		}
		return byPair;
	}

	/**
		The `:status` field for `status`: the static table's own for the seven
		it lists, a new one otherwise.
	**/
	public static function statusField(status:Int):HpackHeader {
		return switch (status) {
			case 200: FIELDS[7];
			case 204: FIELDS[8];
			case 206: FIELDS[9];
			case 304: FIELDS[10];
			case 400: FIELDS[11];
			case 404: FIELDS[12];
			case 500: FIELDS[13];
			case _: new HpackHeader(":status", Std.string(status));
		}
	}

	/** 1-based index of an exact name/value match, or `-1`. */
	public static function findPair(name:String, value:String):Int {
		var values:Null<Map<String, Int>> = __byPair.get(name);
		if (values == null) {
			return -1;
		}
		var found:Null<Int> = values.get(value);
		return found == null ? -1 : found;
	}

	/** 1-based index of the first entry with this name, or `-1`. */
	public static function findName(name:String):Int {
		var found:Null<Int> = __byName.get(name);
		return found == null ? -1 : found;
	}
}
