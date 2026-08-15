package crossbyte.utils;

/**
 * Severity levels understood by `Logger`, ordered from most to least
 * verbose. Assigning `Logger.level` suppresses every record below it.
 */
enum abstract LogLevel(Int) from Int to Int {
	/** Fine-grained tracing, normally disabled outside debugging. */
	var TRACE:Int = 0;

	/** Diagnostic detail useful while developing. */
	var DEBUG:Int = 1;

	/** Routine operational milestones. */
	var INFO:Int = 2;

	/** Something unexpected that the process handled and continued past. */
	var WARN:Int = 3;

	/** A failure that needs attention. */
	var ERROR:Int = 4;

	/** Emits nothing. Use to silence logging entirely. */
	var OFF:Int = 5;

	/** Returns the uppercase name of this level. */
	public function toString():String {
		return switch (this : LogLevel) {
			case TRACE: "TRACE";
			case DEBUG: "DEBUG";
			case INFO: "INFO";
			case WARN: "WARN";
			case ERROR: "ERROR";
			case OFF: "OFF";
			default: "INFO";
		}
	}

	/**
	 * Parses a level name, case-insensitively. Returns `null` for anything
	 * unrecognized so callers can distinguish a bad value from a real one.
	 */
	public static function parse(name:String):Null<LogLevel> {
		if (name == null) {
			return null;
		}

		return switch (name.toUpperCase()) {
			case "TRACE": TRACE;
			case "DEBUG": DEBUG;
			case "INFO": INFO;
			case "WARN", "WARNING": WARN;
			case "ERROR": ERROR;
			case "OFF", "NONE": OFF;
			default: null;
		}
	}
}
