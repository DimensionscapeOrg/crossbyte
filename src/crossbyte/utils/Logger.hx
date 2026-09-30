package crossbyte.utils;

/**
 * Process-wide logging with severity levels, structured fields, categories,
 * and a replaceable sink.
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
 * **Categories.** Records can be logged under a dot-separated category,
 * whose level is set apart from the global one:
 *
 * ```haxe
 * static final access = Logger.category("http.access");
 * access.info("GET / 200");
 * Logger.setLevel("http.access", LogLevel.WARN);
 * ```
 *
 * **One record, one line.** In text mode control characters in the message
 * and the fields, a line feed, a carriage return, the Unicode line
 * separators, are written as escapes, never as themselves. A request path
 * is text a client chose, and one carrying `%0A` used to start a line of its
 * own, indistinguishable from the server's: a client could forge an ERROR
 * record in the access log. JSON mode escapes by construction.
 *
 * **Logging and sensitive data.** A sink receives whatever a caller passes.
 * Services handling private content should log identifiers and outcomes
 * rather than payloads: field values are not redacted or size-limited.
 */
class Logger {
	/**
	 * Minimum severity that will be emitted. Records below this level are
	 * discarded before formatting, so suppressed logging costs almost
	 * nothing. A category given a level of its own with `setLevel` is not
	 * governed by this.
	 */
	public static var level(default, set):LogLevel = LogLevel.INFO;

	/**
	 * When `true`, each record is emitted as a single-line JSON object
	 * instead of a human-readable line.
	 */
	public static var json:Bool = false;

	/**
	 * When `true`, records carry an ISO-8601 UTC timestamp to the
	 * millisecond, as `2026-09-25T09:00:00.123Z`.
	 *
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
	 * Destination for whole records, when the line is not enough: the
	 * record's level, category, fields and time come with it, so a sink can
	 * route errors elsewhere or keep fields as fields. Takes precedence over
	 * `sink`, and receives every record the level lets through;
	 * `separator()` is not a record and still goes to `sink` or stdout.
	 */
	public static var recordSink:LogRecord->Void = null;

	// Levels set per category, and a count bumped whenever any level changes,
	// which LogCategory compares against to know its cached level is stale.
	@:noCompletion private static var __categoryLevels:Map<String, LogLevel> = new Map();
	@:noCompletion private static var __categoryCount:Int = 0;
	@:allow(crossbyte.utils.LogCategory)
	@:noCompletion private static var __levelsVersion:Int = 0;

	@:noCompletion private static function set_level(value:LogLevel):LogLevel {
		level = value;
		__levelsVersion++;
		return value;
	}

	/**
	 * Returns `true` when a record at `candidate` would be emitted. Use to
	 * skip building an expensive message.
	 */
	public static inline function isEnabled(candidate:LogLevel):Bool {
		return (candidate : Int) >= (level : Int) && (level : Int) < (LogLevel.OFF : Int);
	}

	/**
	 * Returns `true` when a record at `candidate` in `category` would be
	 * emitted. A null category is the global one.
	 */
	public static function isEnabledFor(category:Null<String>, candidate:LogLevel):Bool {
		if (category == null || __categoryCount == 0) {
			return isEnabled(candidate);
		}
		var effective:LogLevel = levelOf(category);
		return (candidate : Int) >= (effective : Int) && (effective : Int) < (LogLevel.OFF : Int);
	}

	/**
	 * Sets the minimum level for `category` and everything under it,
	 * `http` covers `http.access`, unless something under it has a level
	 * of its own. `null` clears the category's level, so it follows the one
	 * above it again.
	 */
	public static function setLevel(category:String, categoryLevel:Null<LogLevel>):Void {
		if (category == null) {
			return;
		}
		if (categoryLevel == null) {
			__categoryLevels.remove(category);
		} else {
			__categoryLevels.set(category, categoryLevel);
		}
		__categoryCount = Lambda.count(__categoryLevels);
		__levelsVersion++;
	}

	/**
	 * The level in effect for `category`: its own if it has one, else the
	 * nearest enclosing category's, else `Logger.level`.
	 */
	public static function levelOf(category:Null<String>):LogLevel {
		if (category == null || __categoryCount == 0) {
			return level;
		}

		var name:String = category;
		while (true) {
			var own:Null<LogLevel> = __categoryLevels.get(name);
			if (own != null) {
				return own;
			}
			var dot:Int = name.lastIndexOf(".");
			if (dot < 0) {
				return level;
			}
			name = name.substr(0, dot);
		}
	}

	/**
	 * A logger for one category; see `LogCategory`. Keep it in a static
	 * rather than asking each time: it caches its level.
	 */
	public static function category(name:String):LogCategory {
		return new LogCategory(name);
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
	 * @param category Optional category, whose level applies instead of the
	 *        global one.
	 */
	public static function log(recordLevel:LogLevel, message:String, ?fields:Map<String, String>, ?category:String):Void {
		if (!isEnabledFor(category, recordLevel)) {
			return;
		}

		__write(recordLevel, category, message, fields);
	}

	/** Emits a horizontal rule, bypassing level filtering. */
	public static function separator():Void {
		__emit("-------------------------------------");
	}

	// Formats and emits a record that has already passed its level.
	@:allow(crossbyte.utils.LogCategory)
	@:noCompletion private static function __write(recordLevel:LogLevel, category:Null<String>, message:String, fields:Null<Map<String, String>>):Void {
		var records:LogRecord->Void = recordSink;
		var time:Float = (timestamps || records != null) ? __now() : 0.0;
		var line:String = json ? __formatJson(recordLevel, category, message, fields, time) : __formatText(recordLevel, category, message, fields, time);

		if (records != null) {
			records(new LogRecord(recordLevel, category, message == null ? "" : message, fields, time, line));
			return;
		}

		__emit(line, (recordLevel : Int) >= (LogLevel.WARN : Int));
	}

	#if !(js && !nodejs)
	// Whether a record has gone to stdout since it was last flushed. Set by
	// whichever thread logs and cleared before each flush, so a race costs a
	// flush a frame early or late, never a record.
	@:noCompletion private static var __unflushed:Bool = false;
	#end

	/**
		Flushes stdout if a record went to it since the last flush. The runtime
		calls this once a frame, and as it exits; a warning or an error is
		flushed as it is written.

		hxcpp flushes `Sys.println` only to a console now: to a pipe or a file
		a flush per line is a syscall per line. Records to stdout are flushed
		here instead, once for however many a frame wrote.
	**/
	@:noCompletion public static inline function __flushStdout():Void {
		#if !(js && !nodejs)
		if (__unflushed) {
			__unflushed = false;
			Sys.stdout().flush();
		}
		#end
	}

	@:noCompletion private static function __formatText(recordLevel:LogLevel, category:Null<String>, message:String, fields:Map<String, String>, time:Float):String {
		var buffer = new StringBuf();

		if (timestamps) {
			buffer.add(__timestamp(time));
			buffer.add(" ");
		}

		buffer.add("[");
		buffer.add(recordLevel.toString());
		buffer.add("] ");
		if (category != null) {
			buffer.add("[");
			buffer.add(__escape(category, false));
			buffer.add("] ");
		}
		buffer.add(message == null ? "" : __escape(message, false));

		if (fields != null) {
			for (key => value in fields) {
				buffer.add(" ");
				buffer.add(__escape(key, false));
				buffer.add("=");
				buffer.add(__quoteIfNeeded(value));
			}
		}

		return buffer.toString();
	}

	@:noCompletion private static function __formatJson(recordLevel:LogLevel, category:Null<String>, message:String, fields:Map<String, String>, time:Float):String {
		var record:Dynamic = {level: recordLevel.toString(), message: message == null ? "" : message};

		if (timestamps) {
			Reflect.setField(record, "time", __timestamp(time));
		}
		if (category != null) {
			Reflect.setField(record, "category", category);
		}

		if (fields != null) {
			for (key => value in fields) {
				// Reserved keys keep their meaning; a colliding field is
				// namespaced rather than silently dropped.
				var target:String = (key == "level" || key == "message" || key == "time" || key == "category") ? "field_" + key : key;
				Reflect.setField(record, target, value);
			}
		}

		return haxe.Json.stringify(record);
	}

	@:noCompletion private static function __quoteIfNeeded(value:String):String {
		if (value == null || value == "") {
			return '""';
		}
		if (value.indexOf(" ") < 0 && value.indexOf('"') < 0 && value.indexOf("=") < 0 && !__needsEscape(value)) {
			return value;
		}
		return '"' + __escape(value, true) + '"';
	}

	// Whether `text` holds a character that must never reach the output as
	// itself: C0 and C1 controls, DEL, and the Unicode line and paragraph
	// separators, which some viewers break lines on.
	@:noCompletion private static function __needsEscape(text:String):Bool {
		#if target.unicode
		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			if (code < 0x20 || (code >= 0x7F && code <= 0x9F) || code == 0x2028 || code == 0x2029) {
				return true;
			}
		}
		return false;
		#else
		var i:Int = 0;
		while (i < text.length) {
			if (__escapedWidth(text, i) > 0) {
				return true;
			}
			i++;
		}
		return false;
		#end
	}

	#if !target.unicode
	/**
		Where a string is its UTF-8 bytes, neko's are, how many bytes at
		`i` start a character that is written as an escape, or 0.

		Read a byte at a time as characters, a C1 control's second byte and
		the separators' last two all fall in 0x80 to 0x9F, as does the second
		or third byte of hundreds of ordinary characters, the euro sign, most
		of Cyrillic. Every one of those was escaped and the byte before it left
		alone, which wrote a broken character followed by an escape; the
		controls this is for went out half raw.
	**/
	@:noCompletion private static function __escapedWidth(text:String, i:Int):Int {
		var code:Int = StringTools.fastCodeAt(text, i);
		if (code < 0x20 || code == 0x7F) {
			return 1;
		}
		if (code == 0xC2 && i + 1 < text.length) {
			var next:Int = StringTools.fastCodeAt(text, i + 1);
			return next >= 0x80 && next <= 0x9F ? 2 : 0;
		}
		if (code == 0xE2 && i + 2 < text.length && StringTools.fastCodeAt(text, i + 1) == 0x80) {
			var last:Int = StringTools.fastCodeAt(text, i + 2);
			return last == 0xA8 || last == 0xA9 ? 3 : 0;
		}
		return 0;
	}
	#end

	/**
	 * `text` with every character `__needsEscape` looks for written as an
	 * escape. In a quoted field value `"` and `\` are escaped too, so the
	 * value reads back exactly; elsewhere a backslash is left alone, which
	 * keeps a Windows path readable and cannot start a line.
	 */
	@:noCompletion private static function __escape(text:String, quoted:Bool):String {
		if (!quoted && !__needsEscape(text)) {
			return text;
		}

		var buffer = new StringBuf();
		#if target.unicode
		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			switch (code) {
				case 0x0A:
					buffer.add("\\n");
				case 0x0D:
					buffer.add("\\r");
				case 0x09:
					buffer.add("\\t");
				case 0x22 if (quoted):
					buffer.add('\\"');
				case 0x5C if (quoted):
					buffer.add("\\\\");
				default:
					if (code < 0x20 || (code >= 0x7F && code <= 0x9F)) {
						buffer.add("\\x");
						buffer.add(StringTools.hex(code, 2));
					} else if (code == 0x2028 || code == 0x2029) {
						buffer.add("\\u");
						buffer.add(StringTools.hex(code, 4));
					} else {
						buffer.addChar(code);
					}
			}
		}
		#else
		// Bytes, and each character the other branch escapes recognised by
		// its UTF-8 bytes; every other byte goes out as it came.
		var i:Int = 0;
		while (i < text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			var width:Int = __escapedWidth(text, i);
			if (code == 0x0A) {
				buffer.add("\\n");
			} else if (code == 0x0D) {
				buffer.add("\\r");
			} else if (code == 0x09) {
				buffer.add("\\t");
			} else if (quoted && code == 0x22) {
				buffer.add('\\"');
			} else if (quoted && code == 0x5C) {
				buffer.add("\\\\");
			} else if (width == 1) {
				buffer.add("\\x");
				buffer.add(StringTools.hex(code, 2));
			} else if (width == 2) {
				buffer.add("\\x");
				buffer.add(StringTools.hex(StringTools.fastCodeAt(text, i + 1), 2));
			} else if (width == 3) {
				buffer.add("\\u");
				buffer.add(StringTools.fastCodeAt(text, i + 2) == 0xA8 ? "2028" : "2029");
			} else {
				buffer.addChar(code);
			}
			i += width > 1 ? width : 1;
		}
		#end
		return buffer.toString();
	}

	// A record's wall-clock time, in seconds since the epoch.
	@:noCompletion private static function __now():Float {
		#if (js && !nodejs)
		return Date.now().getTime() / 1000;
		#else
		return Sys.time(); // time of day: a log record is stamped with when it happened
		#end
	}

	/**
	 * `time` as ISO-8601 in UTC with milliseconds: `2026-09-25T09:00:00.123Z`.
	 *
	 * Computed from the epoch seconds rather than through `Date`, which
	 * formats in local time, the stamps carried no zone and read as UTC,
	 * so every record on a machine not on UTC was off by its offset, and
	 * whose resolution differs by target.
	 */
	@:noCompletion private static function __timestamp(time:Float):String {
		// Rounded, not truncated: seconds as a double rarely hold a whole
		// millisecond exactly, and .999 would otherwise read as .998.
		var totalMs:Float = Math.fround(time * 1000);
		var days:Float = Math.ffloor(totalMs / 86400000);
		var msOfDay:Int = Std.int(totalMs - days * 86400000);

		// Howard Hinnant's days-to-civil, exact for any date a clock gives.
		var z:Float = days + 719468;
		var era:Float = Math.ffloor(z / 146097);
		var doe:Int = Std.int(z - era * 146097);
		var yoe:Int = Std.int((doe - Std.int(doe / 1460) + Std.int(doe / 36524) - Std.int(doe / 146096)) / 365);
		var doy:Int = doe - (365 * yoe + Std.int(yoe / 4) - Std.int(yoe / 100));
		var mp:Int = Std.int((5 * doy + 2) / 153);
		var day:Int = doy - Std.int((153 * mp + 2) / 5) + 1;
		var month:Int = mp < 10 ? mp + 3 : mp - 9;
		var year:Int = Std.int(yoe + era * 400) + (month <= 2 ? 1 : 0);

		var hours:Int = Std.int(msOfDay / 3600000);
		var minutes:Int = Std.int((msOfDay % 3600000) / 60000);
		var seconds:Int = Std.int((msOfDay % 60000) / 1000);
		var millis:Int = msOfDay % 1000;

		return StringTools.lpad(Std.string(year), "0", 4) + "-" + __two(month) + "-" + __two(day) + "T" + __two(hours) + ":" + __two(minutes) + ":"
			+ __two(seconds) + "." + StringTools.lpad(Std.string(millis), "0", 3) + "Z";
	}

	@:noCompletion private static inline function __two(value:Int):String {
		return value < 10 ? "0" + value : Std.string(value);
	}

	@:noCompletion private static function __emit(line:String, urgent:Bool = false):Void {
		var target = sink;
		if (target != null) {
			target(line);
			return;
		}

		#if (js && !nodejs)
		// A browser has no stdout. The console is the equivalent sink, and a
		// log line that vanished would be worse here than anywhere else,
		// this is the thing that reports everything else going wrong.
		js.Browser.console.log(line);
		#else
		Sys.println(line);
		if (urgent) {
			// A warning or an error is often the last thing a process says.
			__unflushed = false;
			Sys.stdout().flush();
		} else {
			__unflushed = true;
		}
		#end
	}
}
