package crossbyte.utils;

/**
 * Process-wide logging with severity levels, structured fields, categories,
 * and a replaceable sink.
 *
 * Beyond the `info`, `error` and `separator` helpers:
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
 * and the fields (a line feed, a carriage return, the Unicode line
 * separators) are written as escapes, never as themselves. A request path
 * is text a client chose, and one carrying `%0A` would otherwise start a
 * line of its own, indistinguishable from the server's: a client could
 * forge an ERROR record in the access log. JSON mode escapes by
 * construction.
 *
 * **Client text belongs in a field.** The message is written unquoted; a
 * field value is quoted when it holds a space, a quote or an equals sign.
 * In the message, a path such as `/a status=500` would read to a logfmt
 * collector as a `status` field of its own. As a field value it cannot.
 *
 * **Logging and sensitive data.** A sink receives whatever a caller passes.
 * Services handling private content should log identifiers and outcomes
 * rather than payloads: field values are not redacted or size-limited.
 *
 * **A logging call never throws.** Logging is done from everywhere, error
 * handlers included, so a `sink` or `recordSink` that throws (a full disk, a
 * collector that is down) does not throw into whoever logged: the record goes
 * to standard output instead, after one line saying the sink failed, and the
 * next record is offered to the sink again. A record logged from inside a
 * sink, by it or by something it calls, goes to standard output rather than
 * into the sink a second time. Both as log4j2 and Python's `logging` do.
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

	// Set on a thread while it is inside `sink` or `recordSink`, so a record
	// logged from there goes to standard output rather than recursing. One a
	// thread: another thread's records still go to the sink meanwhile.
	#if (target.threaded && !js)
	@:noCompletion private static final __inSink:sys.thread.Tls<Bool> = new sys.thread.Tls();
	#else
	@:noCompletion private static var __inSink:Bool = false;
	#end

	// Whether the last record offered to a sink made it throw: the failure is
	// reported once, as it starts, rather than beside every record while it
	// lasts. Shared, and a race costs at most one notice too many or too few.
	@:noCompletion private static var __sinkFailing:Bool = false;

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
	 * Sets the minimum level for `category` and everything under it
	 * (`http` covers `http.access`) unless something under it has a level
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

		var urgent:Bool = (recordLevel : Int) >= (LogLevel.WARN : Int);
		if (records != null) {
			if (!__offerRecord(records, new LogRecord(recordLevel, category, message == null ? "" : message, fields, time, line))) {
				__emitDefault(line, urgent);
			}
			return;
		}

		__emit(line, urgent);
	}

	/**
		Hands `record` to `records`, the record sink, and answers whether it
		took it: `false` when it threw, which is said once as `sink` failing
		is, or when this thread is already inside a sink. Where the record goes
		then is the caller's to say. Whatever hands a record sink a record goes
		through here, so that none of them can throw into whoever logged.
	**/
	@:noCompletion private static function __offerRecord(records:LogRecord->Void, record:LogRecord):Bool {
		if (!__enterSink()) {
			return false;
		}
		try {
			records(record);
			__leaveSink();
			__sinkFailing = false;
			return true;
		} catch (error:Dynamic) {
			__leaveSink();
			__sinkThrew(error);
			return false;
		}
	}

	/**
		Marks this thread as inside a sink, and answers whether it was not
		already: `false` is a record logged from inside a sink, which goes to
		standard output instead.
	**/
	@:noCompletion private static inline function __enterSink():Bool {
		#if (target.threaded && !js)
		if (__inSink.value == true) {
			return false;
		}
		__inSink.value = true;
		#else
		if (__inSink) {
			return false;
		}
		__inSink = true;
		#end
		return true;
	}

	@:noCompletion private static inline function __leaveSink():Void {
		#if (target.threaded && !js)
		__inSink.value = false;
		#else
		__inSink = false;
		#end
	}

	/**
		Says once, as a sink starts failing, that it has: on standard output,
		formatted as any other record, so a reader of the output sees why the
		records that follow are there and not where they were sent.
	**/
	@:noCompletion private static function __sinkThrew(error:Dynamic):Void {
		if (__sinkFailing) {
			return;
		}
		__sinkFailing = true;
		var message:String = "The log sink threw, so records go to standard output until it takes one again: " + Std.string(error);
		var time:Float = timestamps ? __now() : 0.0;
		__emitDefault(json ? __formatJson(LogLevel.ERROR, null, message, null, time) : __formatText(LogLevel.ERROR, null, message, null, time), true);
	}

	#if !js
	// Whether a record has gone to stdout since it was last flushed. Set by
	// whichever thread logs and cleared before each flush, so a race costs a
	// flush a frame early or late, never a record.
	//
	// Not on Node. Sys.println there is process.stdout.write, which holds
	// nothing back, and Sys.stdout().flush() is fs.fsyncSync: refused for a
	// pipe on Linux, so a warning would throw from inside whatever reported
	// it, and a file would take a disk sync a frame.
	@:noCompletion private static var __unflushed:Bool = false;
	#end

	#if nodejs
	// Records held for one write at the end of this turn of Node's loop; see
	// __emit. Written past this many characters whatever the turn.
	@:noCompletion private static inline var HELD_LIMIT:Int = 64 * 1024;
	@:noCompletion private static var __held:String = "";
	@:noCompletion private static var __heldTurn:Bool = false;
	@:noCompletion private static var __exitHooked:Bool = false;

	@:noCompletion private static function __writeHeld():Void {
		if (__held.length > 0) {
			var text:String = __held;
			__held = "";
			js.Node.process.stdout.write(text);
		}
	}

	@:noCompletion private static function __writeHeldTurn():Void {
		__heldTurn = false;
		__writeHeld();
	}
	#end

	/**
		Flushes stdout if a record went to it since the last flush. The runtime
		calls this once a frame, and as it exits; a warning or an error is
		flushed as it is written.

		hxcpp flushes `Sys.println` only to a console: to a pipe or a file
		a flush per line is a syscall per line. Records to stdout are flushed
		here instead, once for however many a frame wrote.
	**/
	@:noCompletion public static inline function __flushStdout():Void {
		#if nodejs
		__writeHeld();
		#elseif !js
		if (__unflushed) {
			__unflushed = false;
			Sys.stdout().flush();
		}
		#end
	}

	@:noCompletion private static function __formatText(recordLevel:LogLevel, category:Null<String>, message:String, fields:Map<String, String>, time:Float):String {
		var buffer = new StringBuf();
		__textHead(buffer, recordLevel, category, time);
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

	/**
		What text mode writes before a record's message: the time when there
		is one, the level, and the category when there is one, each followed
		by a space.
	**/
	@:noCompletion private static function __textHead(buffer:StringBuf, recordLevel:LogLevel, category:Null<String>, time:Float):Void {
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
	}

	/**
		One JSON object, written straight out: `level`, `message`, then `time`
		and `category` when there are any, then the fields in the map's order.
		Built this way rather than as an anonymous object with
		`Reflect.setField` per field handed to the reflective
		`haxe.Json.stringify` (1.1 us a record where text takes 0.7), whose
		keys would come out in whatever order the target's reflection gives.
	**/
	@:noCompletion private static function __formatJson(recordLevel:LogLevel, category:Null<String>, message:String, fields:Map<String, String>, time:Float):String {
		var buffer = new StringBuf();
		__jsonHead(buffer, recordLevel, category, message, time);

		if (fields != null) {
			for (key => value in fields) {
				// Reserved keys keep their meaning; a colliding field is
				// namespaced rather than silently dropped.
				var target:String = (key == "level" || key == "message" || key == "time" || key == "category") ? "field_" + key : key;
				buffer.add(",");
				__jsonString(buffer, target);
				buffer.add(":");
				if (value == null) {
					buffer.add("null");
				} else {
					__jsonString(buffer, value);
				}
			}
		}

		buffer.add("}");
		return buffer.toString();
	}

	/**
		A JSON record up to its fields: the opening brace, `level`, `message`,
		then `time` and `category` when there are any. The caller adds the
		fields and the closing brace.
	**/
	@:noCompletion private static function __jsonHead(buffer:StringBuf, recordLevel:LogLevel, category:Null<String>, message:String, time:Float):Void {
		buffer.add('{"level":');
		__jsonString(buffer, recordLevel.toString());
		buffer.add(',"message":');
		__jsonString(buffer, message == null ? "" : message);

		if (timestamps) {
			buffer.add(',"time":');
			__jsonString(buffer, __timestamp(time));
		}
		if (category != null) {
			buffer.add(',"category":');
			__jsonString(buffer, category);
		}
	}

	/**
		`text` as a JSON string, quotes included, escaped as `haxe.Json` escapes
		it: the quote, the backslash, and every control character.
	**/
	@:noCompletion private static function __jsonString(buffer:StringBuf, text:String):Void {
		buffer.add('"');
		var start:Int = 0;
		var length:Int = text.length;
		for (i in 0...length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			if (code >= 0x20 && code != 0x22 && code != 0x5C) {
				continue;
			}
			if (i > start) {
				buffer.addSub(text, start, i - start);
			}
			start = i + 1;
			switch (code) {
				case 0x22:
					buffer.add('\\"');
				case 0x5C:
					buffer.add("\\\\");
				case 0x0A:
					buffer.add("\\n");
				case 0x0D:
					buffer.add("\\r");
				case 0x09:
					buffer.add("\\t");
				case 0x08:
					buffer.add("\\b");
				case 0x0C:
					buffer.add("\\f");
				default:
					buffer.add("\\u00");
					buffer.add(StringTools.hex(code, 2));
			}
		}
		if (start == 0) {
			buffer.add(text);
		} else if (start < length) {
			buffer.addSub(text, start, length - start);
		}
		buffer.add('"');
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
		Where a string is its UTF-8 bytes (neko's are), how many bytes at
		`i` start a character that is written as an escape, or 0.

		Read a byte at a time as characters, a C1 control's second byte and
		the separators' last two all fall in 0x80 to 0x9F, as does the second
		or third byte of hundreds of ordinary characters (the euro sign, most
		of Cyrillic). Escaping each of those and leaving the byte before it
		alone would write a broken character followed by an escape, and the
		controls this is for would go out half raw.
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
	 * formats in local time (the stamps carry no zone and read as UTC, so
	 * every record on a machine not on UTC would be off by its offset) and
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
			if (__enterSink()) {
				try {
					target(line);
					__leaveSink();
					__sinkFailing = false;
					return;
				} catch (error:Dynamic) {
					__leaveSink();
					__sinkThrew(error);
				}
			}
		}
		__emitDefault(line, urgent);
	}

	/** Writes `line` where a record goes with no sink: standard output, or the console in a browser. **/
	@:noCompletion private static function __emitDefault(line:String, urgent:Bool):Void {
		#if (js && !nodejs)
		// A browser has no stdout. The console is the equivalent sink, and a
		// log line that vanished would be worse here than anywhere else:
		// this is the thing that reports everything else going wrong.
		js.Browser.console.log(line);
		#elseif nodejs
		// One write a turn of Node's loop, not two a record: Sys.println there
		// writes the line and then its newline, and to a file each is a
		// synchronous system call (the access log's line a request would cost a
		// server 15% of its time). Held records go when the turn ends, when
		// the runtime flushes, or as the process exits; a warning or an error
		// goes at once, after them, so the order holds.
		__held += line + "\n";
		if (urgent || __held.length >= HELD_LIMIT) {
			__writeHeld();
		} else if (!__heldTurn) {
			__heldTurn = true;
			js.Node.setImmediate(__writeHeldTurn);
			if (!__exitHooked) {
				__exitHooked = true;
				js.Node.process.on("exit", __writeHeld);
			}
		}
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
