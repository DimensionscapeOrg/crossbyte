package crossbyte.utils;

/**
	A named source of log records, whose level can be set apart from
	everything else's with `Logger.setLevel`.

	```haxe
	static final log = Logger.category("http.access");
	log.info("GET /index.html 200");

	Logger.setLevel("http.access", LogLevel.WARN); // quiet the access log only
	```

	A category's level is looked up once and kept until a level changes
	anywhere, so a record below it costs a field comparison, as a record below
	`Logger.level` always has.
**/
final class LogCategory {
	/** Dot-separated, most general first: `http` covers `http.access`. **/
	public final name:String;

	@:noCompletion private var __level:LogLevel = LogLevel.INFO;
	@:noCompletion private var __version:Int = -1;

	@:allow(crossbyte.utils.Logger)
	private function new(name:String) {
		this.name = name;
	}

	/** Whether a record at `candidate` would be emitted. **/
	public inline function isEnabled(candidate:LogLevel):Bool {
		if (__version != Logger.__levelsVersion) {
			__level = Logger.levelOf(name);
			__version = Logger.__levelsVersion;
		}
		return (candidate : Int) >= (__level : Int) && (__level : Int) < (LogLevel.OFF : Int);
	}

	public function trace(message:String, ?fields:Map<String, String>):Void {
		if (isEnabled(LogLevel.TRACE)) {
			Logger.__write(LogLevel.TRACE, name, message, fields);
		}
	}

	public function debug(message:String, ?fields:Map<String, String>):Void {
		if (isEnabled(LogLevel.DEBUG)) {
			Logger.__write(LogLevel.DEBUG, name, message, fields);
		}
	}

	public function info(message:String, ?fields:Map<String, String>):Void {
		if (isEnabled(LogLevel.INFO)) {
			Logger.__write(LogLevel.INFO, name, message, fields);
		}
	}

	public function warn(message:String, ?fields:Map<String, String>):Void {
		if (isEnabled(LogLevel.WARN)) {
			Logger.__write(LogLevel.WARN, name, message, fields);
		}
	}

	public function error(message:String, ?fields:Map<String, String>):Void {
		if (isEnabled(LogLevel.ERROR)) {
			Logger.__write(LogLevel.ERROR, name, message, fields);
		}
	}

	public function log(recordLevel:LogLevel, message:String, ?fields:Map<String, String>):Void {
		if (isEnabled(recordLevel)) {
			Logger.__write(recordLevel, name, message, fields);
		}
	}
}
