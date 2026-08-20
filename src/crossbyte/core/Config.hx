package crossbyte.core;

import crossbyte.errors.ArgumentError;

/**
 * Layered configuration for services: typed access over values gathered
 * from a file, the environment, or code.
 *
 * Sources layer in the order applied, later values winning, so the usual
 * deployment shape works directly:
 *
 * ```haxe
 * var config = new Config()
 *     .withDefaults(["port" => "8080", "log.level" => "info"])
 *     .withFile("/etc/myservice.conf", true)
 *     .withEnvironment("MYSERVICE_");
 *
 * var port = config.getInt("port");
 * var secret = config.require("session.secret");
 * ```
 *
 * Keys are case-insensitive, and `.`, `_`, and `-` are interchangeable, so
 * `log.level`, `LOG_LEVEL`, and `Log-Level` address the same value. That
 * lets an environment variable override a file key without callers having
 * to know which spelling a given source used.
 *
 * Values are stored as strings and converted on read. A malformed value
 * throws rather than silently falling back, since a mistyped port or
 * timeout should fail at startup rather than behave unexpectedly later.
 */
class Config {
	// Numeric patterns are built per call rather than held as statics:
	// EReg carries mutable match state, so a shared instance is a data race
	// when configuration is read from worker threads.
	@:noCompletion private static inline function __integerPattern():EReg {
		return ~/^[+-]?(?:[0-9]+|0[xX][0-9a-fA-F]+)$/;
	}

	@:noCompletion private static inline function __numberPattern():EReg {
		return ~/^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/;
	}

	@:noCompletion private var __values:Map<String, String>;

	/**
	 * Creates an empty configuration, or one seeded with `values`.
	 */
	public function new(?values:Map<String, String>) {
		__values = new Map();
		if (values != null) {
			__putAll(values);
		}
	}

	/**
	 * Adds values that later sources may override. Returns `this` so
	 * sources can be chained.
	 */
	public function withDefaults(values:Map<String, String>):Config {
		if (values != null) {
			for (key => value in values) {
				if (!has(key)) {
					__put(key, value);
				}
			}
		}
		return this;
	}

	/**
	 * Applies values from another configuration, overriding existing keys.
	 */
	public function withConfig(other:Config):Config {
		if (other != null) {
			__putAll(other.__values);
		}
		return this;
	}

	/**
	 * Applies values parsed from a `key=value` file, overriding existing
	 * keys.
	 *
	 * Blank lines and lines beginning with `#` or `;` are ignored. Values
	 * may be wrapped in matching single or double quotes to preserve
	 * surrounding whitespace.
	 *
	 * @param path The file to read.
	 * @param optional When `true`, a missing file is ignored rather than
	 *        throwing. Useful for an override file that may not exist.
	 */
	public function withFile(path:String, optional:Bool = false):Config {
		#if (js && !nodejs)
		// Config.withFile reads from disk, which a browser has no access to; build the Config from values, or load the file through your own transport first.
		throw new crossbyte.errors.IllegalOperationError("Config.withFile reads from disk, which a browser has no access to; build the Config from values, or load the file through your own transport first.");
		#else
		if (path == null || path == "") {
			throw new ArgumentError("Config file path must not be empty.");
		}

		if (!sys.FileSystem.exists(path)) {
			if (optional) {
				return this;
			}
			throw new ArgumentError('Config file not found: $path');
		}

		var lineNumber:Int = 0;
		for (rawLine in sys.io.File.getContent(path).split("\n")) {
			lineNumber++;
			var line:String = StringTools.trim(rawLine);
			if (line == "" || StringTools.startsWith(line, "#") || StringTools.startsWith(line, ";")) {
				continue;
			}

			var separator:Int = line.indexOf("=");
			if (separator <= 0) {
				throw new ArgumentError('Malformed config line $lineNumber in $path: expected key=value');
			}

			__put(StringTools.trim(line.substr(0, separator)), __unquote(StringTools.trim(line.substr(separator + 1))));
		}

		return this;
		#end
	}

	/**
	 * Applies environment variables, overriding existing keys.
	 *
	 * @param prefix When set, only variables starting with it are applied,
	 *        and the prefix is stripped from the resulting key — so
	 *        `MYSERVICE_PORT` with prefix `MYSERVICE_` becomes `port`.
	 */
	public function withEnvironment(?prefix:String):Config {
		#if (js && !nodejs)
		// Config.withEnvironment reads process environment variables, which a browser does not have; supply the values directly instead.
		throw new crossbyte.errors.IllegalOperationError("Config.withEnvironment reads process environment variables, which a browser does not have; supply the values directly instead.");
		#else
		var environment = Sys.environment();
		for (name => value in environment) {
			if (prefix != null && prefix != "") {
				if (!StringTools.startsWith(name.toUpperCase(), prefix.toUpperCase())) {
					continue;
				}
				__put(name.substr(prefix.length), value);
			} else {
				__put(name, value);
			}
		}
		return this;
		#end
	}

	/**
	 * Sets a single value, overriding any existing one.
	 */
	public function set(key:String, value:String):Config {
		__put(key, value);
		return this;
	}

	/**
	 * Whether a value is present for `key`.
	 */
	public function has(key:String):Bool {
		return key != null && __values.exists(__normalize(key));
	}

	/**
	 * Returns every key present, in normalized form.
	 */
	public function keys():Array<String> {
		return [for (key in __values.keys()) key];
	}

	/**
	 * Returns the raw string for `key`, or `fallback` when absent.
	 */
	public function getString(key:String, ?fallback:String):String {
		if (!has(key)) {
			return fallback;
		}
		return __values.get(__normalize(key));
	}

	/**
	 * Returns `key` as an integer.
	 *
	 * @throws ArgumentError When the value is present but not a valid
	 *         integer.
	 */
	public function getInt(key:String, ?fallback:Int):Null<Int> {
		if (!has(key)) {
			return fallback;
		}

		var raw:String = StringTools.trim(getString(key));
		// Std.parseInt stops at the first non-digit, so "80a80" would yield
		// 80 -- a typo would silently become a different port. Require the
		// whole value to be numeric.
		if (!__integerPattern().match(raw)) {
			throw new ArgumentError('Config value for "$key" is not an integer: "$raw"');
		}

		var parsed:Null<Int> = Std.parseInt(raw);
		if (parsed == null) {
			throw new ArgumentError('Config value for "$key" is not an integer: "$raw"');
		}
		return parsed;
	}

	/**
	 * Returns `key` as a float.
	 *
	 * @throws ArgumentError When the value is present but not a valid
	 *         number.
	 */
	public function getFloat(key:String, ?fallback:Float):Null<Float> {
		if (!has(key)) {
			return fallback;
		}

		var raw:String = StringTools.trim(getString(key));
		// Same trailing-garbage hazard as getInt: "1.5abc" must not read
		// as 1.5.
		if (!__numberPattern().match(raw)) {
			throw new ArgumentError('Config value for "$key" is not a number: "$raw"');
		}
		return Std.parseFloat(raw);
	}

	/**
	 * Returns `key` as a boolean. Accepts `true`/`false`, `yes`/`no`,
	 * `on`/`off`, and `1`/`0`, case-insensitively.
	 *
	 * @throws ArgumentError When the value is present but unrecognized.
	 */
	public function getBool(key:String, ?fallback:Bool):Null<Bool> {
		if (!has(key)) {
			return fallback;
		}

		var raw:String = StringTools.trim(getString(key)).toLowerCase();
		return switch (raw) {
			case "true", "yes", "on", "1": true;
			case "false", "no", "off", "0": false;
			default: throw new ArgumentError('Config value for "$key" is not a boolean: "$raw"');
		}
	}

	/**
	 * Returns `key` as a comma-separated list. Empty entries are dropped
	 * and surrounding whitespace trimmed. Absent keys return an empty
	 * array unless `fallback` is supplied.
	 */
	public function getList(key:String, ?fallback:Array<String>):Array<String> {
		if (!has(key)) {
			return fallback == null ? [] : fallback;
		}

		var out:Array<String> = [];
		for (part in getString(key).split(",")) {
			var trimmed:String = StringTools.trim(part);
			if (trimmed != "") {
				out.push(trimmed);
			}
		}
		return out;
	}

	/**
	 * Returns `key`, failing when it is missing or empty.
	 *
	 * Use for values a service cannot start without, so misconfiguration
	 * surfaces at startup with a clear message rather than as a confusing
	 * failure later.
	 *
	 * @throws ArgumentError When the value is absent or blank.
	 */
	public function require(key:String):String {
		var value:String = getString(key);
		if (value == null || StringTools.trim(value) == "") {
			throw new ArgumentError('Required configuration value "$key" is missing.');
		}
		return value;
	}

	@:noCompletion private function __putAll(values:Map<String, String>):Void {
		for (key => value in values) {
			__put(key, value);
		}
	}

	@:noCompletion private function __put(key:String, value:String):Void {
		if (key == null) {
			return;
		}

		var normalized:String = __normalize(key);
		if (normalized == "") {
			return;
		}

		__values.set(normalized, value);
	}

	@:noCompletion private static function __normalize(key:String):String {
		var lowered:String = StringTools.trim(key).toLowerCase();
		return StringTools.replace(StringTools.replace(lowered, "_", "."), "-", ".");
	}

	@:noCompletion private static function __unquote(value:String):String {
		if (value.length >= 2) {
			var first:String = value.charAt(0);
			if ((first == '"' || first == "'") && value.charAt(value.length - 1) == first) {
				return value.substr(1, value.length - 2);
			}
		}
		return value;
	}
}
