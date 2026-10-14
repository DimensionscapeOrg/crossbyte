package crossbyte.utils;

/**
	One record as `Logger` emits it, whole, for a `Logger.recordSink` that
	wants more than the formatted line: to route by severity, to keep the
	fields as fields, to format for a collector of its own.
**/
final class LogRecord {
	/** Severity of the record. **/
	public final level:LogLevel;

	/** The category it was logged under, or null for the global one. **/
	public final category:Null<String>;

	/** The message as the caller gave it, before any escaping. **/
	public final message:String;

	/**
		Structured fields as the caller gave them, a map or an array, or null.
		Read them as a map is read (`fields["status"]`, `for (key => value in
		fields)`), or as one (`var map:Map<String, String> = record.fields`);
		iterated, an array gives its fields in its order.
	**/
	public final fields:Null<LogFields>;

	/** When it was logged: seconds since the Unix epoch, UTC. **/
	public final time:Float;

	/** The record formatted as `Logger` would print it, escaped and all. **/
	public final line:String;

	@:allow(crossbyte.utils.Logger)
	private function new(level:LogLevel, category:Null<String>, message:String, fields:Null<LogFields>, time:Float, line:String) {
		this.level = level;
		this.category = category;
		this.message = message;
		this.fields = fields;
		this.time = time;
		this.line = line;
	}
}
