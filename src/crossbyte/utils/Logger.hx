package crossbyte.utils;

/**
 * Process-wide logging with severity levels, structured fields, and a
 * replaceable sink.
 *
 * The original `info`/`error`/`separator` helpers keep their exact
 * behavior, so existing code needs no changes. Beyond them:
 *
 * ```haxe
 * Logger.level = DEBUG;
 * Logger.info("request served", ["status" => "200", "ms" => "12"]);
 * ```
 *
 * Structured fields are appended as `key=value` pairs, which stay readable
 * in a terminal and parse cleanly with `logfmt`-style tooling. Set
 * `Logger.json = true` to emit one JSON object per record for ingestion by
 * a log collector.
 *
 * **Logging and sensitive data.** A sink receives whatever a caller passes.
 * Services handling private content should log identifiers and outcomes
 * rather than payloads: field values are not redacted, escaped for
 * anything but the chosen output format, or size-limited.
 */
class Logger {
	/**
	 * Minimum severity that will be emitted. Records below this level are
	 * discarded before formatting, so suppressed logging costs almost
	 * nothing.
	 */
	public static var level:LogLevel = LogLevel.INFO;

	/**
	 * When `true`, each record is emitted as a single-line JSON object
	 * instead of a human-readable line.
	 */
	public static var json:Bool = false;

	/**
	 * When `true`, records carry an ISO-8601-style UTC timestamp.
	 * Off by default: many supervisors (systemd, Docker, Windows services)
	 * add their own, and duplicate stamps make output harder to read.
	 */
	public static var timestamps:Bool = false;

	/**
	 * Destination for formatted records. Replace to route logging into a
	 * file, a ring buffer, or a collector. `null` restores stdout.
	 */
	public static var sink:String->Void = null;

	/**
	 * Returns `true` when a record at `candidate` would be emitted. Use to
	 * skip building an expensive message.
	 */
	public static inline function isEnabled(candidate:LogLevel):Bool {
		return (candidate : Int) >= (level : Int) && (level : Int) < (LogLevel.OFF : Int);
	}

	/** Logs at `TRACE`. */
	public static function trace(message:String, ?fields:Map<String, String>):Void {
		log(LogLevel.TRACE, message, fields);
	}

	/** Logs at `DEBUG`. */
	public static function debug(message:String, ?fields:Map<String, String>):Void {
		log(LogLevel.DEBUG, message, fields);
	}

	/** Logs at `INFO`. */
	public static function info(message:String, ?fields:Map<String, String>):Void {
		log(LogLevel.INFO, message, fields);
	}

	/** Logs at `WARN`. */
	public static function warn(message:String, ?fields:Map<String, String>):Void {
		log(LogLevel.WARN, message, fields);
	}

	/** Logs at `ERROR`. */
	public static function error(message:String, ?fields:Map<String, String>):Void {
		log(LogLevel.ERROR, message, fields);
	}

	/**
	 * Logs at an explicit level.
	 *
	 * @param recordLevel Severity of this record.
	 * @param message The human-readable message.
	 * @param fields Optional structured key-value pairs.
	 */
	public static function log(recordLevel:LogLevel, message:String, ?fields:Map<String, String>):Void {
		if (!isEnabled(recordLevel)) {
			return;
		}

		__emit(json ? __formatJson(recordLevel, message, fields) : __formatText(recordLevel, message, fields));
	}

	/** Emits a horizontal rule, bypassing level filtering. */
	public static function separator():Void {
		__emit("-------------------------------------");
	}

	@:noCompletion private static function __formatText(recordLevel:LogLevel, message:String, fields:Map<String, String>):String {
		var buffer = new StringBuf();

		if (timestamps) {
			buffer.add(__timestamp());
			buffer.add(" ");
		}

		buffer.add("[");
		buffer.add(recordLevel.toString());
		buffer.add("] ");
		buffer.add(message == null ? "" : message);

		if (fields != null) {
			for (key => value in fields) {
				buffer.add(" ");
				buffer.add(key);
				buffer.add("=");
				buffer.add(__quoteIfNeeded(value));
			}
		}

		return buffer.toString();
	}

	@:noCompletion private static function __formatJson(recordLevel:LogLevel, message:String, fields:Map<String, String>):String {
		var record:Dynamic = {level: recordLevel.toString(), message: message == null ? "" : message};

		if (timestamps) {
			Reflect.setField(record, "time", __timestamp());
		}

		if (fields != null) {
			for (key => value in fields) {
				// Reserved keys keep their meaning; a colliding field is
				// namespaced rather than silently dropped.
				var target:String = (key == "level" || key == "message" || key == "time") ? "field_" + key : key;
				Reflect.setField(record, target, value);
			}
		}

		return haxe.Json.stringify(record);
	}

	@:noCompletion private static function __quoteIfNeeded(value:String):String {
		if (value == null) {
			return '""';
		}
		if (value == "") {
			return '""';
		}
		if (value.indexOf(" ") < 0 && value.indexOf('"') < 0 && value.indexOf("=") < 0) {
			return value;
		}
		return '"' + StringTools.replace(value, '"', '\\"') + '"';
	}

	@:noCompletion private static function __timestamp():String {
		var now = Date.now();
		return DateTools.format(now, "%Y-%m-%dT%H:%M:%S");
	}

	@:noCompletion private static function __emit(line:String):Void {
		var target = sink;
		if (target != null) {
			target(line);
			return;
		}

		Sys.println(line);
	}
}
