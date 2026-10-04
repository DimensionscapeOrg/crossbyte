package crossbyte.db.postgres._internal;

import crossbyte.db.postgres.PostgresConfig;
import crossbyte.errors.ArgumentError;

/**
 * Builds the libpq connection string a `PostgresConfig` describes.
 *
 * Built here rather than in the native bridge so that a setting is one line in
 * this file instead of another argument on a native signature, and so what
 * reaches libpq can be checked on every target without a server or a libpq.
 *
 * Values are single-quoted with backslash and quote escaped, which is libpq's
 * own rule, so a password holding either cannot end its value early and start
 * another keyword.
 */
class PostgresConnInfo {
	public static function build(cfg:PostgresConfig):String {
		if (cfg == null) {
			throw new ArgumentError("PostgresConnInfo.build requires a config.");
		}

		var out:StringBuf = new StringBuf();

		__add(out, "host", cfg.host != null ? cfg.host : "127.0.0.1");

		var port:Int = cfg.port != null ? cfg.port : 5432;

		if (port > 0) {
			__add(out, "port", Std.string(port));
		}

		__add(out, "user", cfg.user);
		__add(out, "password", cfg.password);
		__add(out, "dbname", cfg.database != null ? cfg.database : "postgres");
		__add(out, "sslmode", cfg.sslMode);

		var connectTimeout:Int = cfg.connectTimeout != null ? cfg.connectTimeout : 5;

		if (connectTimeout > 0) {
			__add(out, "connect_timeout", Std.string(connectTimeout));
		}

		var extra:Map<String, String> = cfg.connectionParameters;

		// Keepalive is on with MySQL's timings unless turned off: libpq
		// turns it on by default but leaves the timings to the system, two
		// hours before the first probe on Linux and Windows, which is how long
		// a connection to a host gone silent looked alive, and held the
		// worker waiting on it. A keyword the caller passes itself in
		// connectionParameters is theirs.
		if (cfg.keepAlive == false) {
			__addDefault(out, extra, "keepalives", "0");
		} else {
			__addCount(out, extra, "keepalives_idle", "keepAliveIdle", cfg.keepAliveIdle, DEFAULT_KEEPALIVE_IDLE);
			__addCount(out, extra, "keepalives_interval", "keepAliveInterval", cfg.keepAliveInterval, DEFAULT_KEEPALIVE_INTERVAL);
			__addCount(out, extra, "keepalives_count", "keepAliveCount", cfg.keepAliveCount, DEFAULT_KEEPALIVE_COUNT);
		}

		if (cfg.tcpUserTimeout != null) {
			__add(out, "tcp_user_timeout", __millis("tcpUserTimeout", cfg.tcpUserTimeout));
		}

		var options:Array<String> = [];

		if (extra != null && extra.get("options") != null && extra.get("options") != "") {
			options.push(extra.get("options"));
		}

		// Through `options`, which the server applies as the session starts,
		// rather than a SET after connecting: no round trip, and no window in
		// which the connection is open and unbounded.
		if (cfg.statementTimeout != null) {
			options.push("-c statement_timeout=" + __millis("statementTimeout", cfg.statementTimeout));
		}

		if (options.length > 0) {
			__add(out, "options", options.join(" "));
		}

		if (extra != null) {
			// Sorted, so the same config produces the same string on every
			// target whatever order its map iterates in.
			var keys:Array<String> = [for (key in extra.keys()) key];
			keys.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));

			for (key in keys) {
				if (key == "options") {
					continue;
				}

				if (!~/^[a-z_]+$/.match(key)) {
					// A keyword is spliced in unquoted, so anything else in it,
					// a space, an equals sign, would write keywords of its
					// own into the string.
					throw new ArgumentError('Invalid libpq connection parameter "$key": expected a keyword such as application_name.');
				}

				__add(out, key, extra.get(key));
			}
		}

		return StringTools.trim(out.toString());
	}

	/** Quotes a value by libpq's rules. **/
	public static function quote(value:String):String {
		var out:StringBuf = new StringBuf();
		out.addChar("'".code);

		for (i in 0...value.length) {
			var code:Int = StringTools.fastCodeAt(value, i);

			if (code == "'".code || code == "\\".code) {
				out.addChar("\\".code);
			}

			out.addChar(code);
		}

		out.addChar("'".code);
		return out.toString();
	}

	@:noCompletion private static function __add(out:StringBuf, keyword:String, value:String):Void {
		if (value == null || value == "") {
			return;
		}

		out.add(keyword);
		out.addChar("=".code);
		out.add(quote(value));
		out.addChar(" ".code);
	}

	/** Idle seconds before the first keepalive probe, unless set. **/
	public static inline var DEFAULT_KEEPALIVE_IDLE:Int = 60;

	/** Seconds between unanswered probes, unless set. **/
	public static inline var DEFAULT_KEEPALIVE_INTERVAL:Int = 10;

	/** Unanswered probes before the connection is dropped, unless set. **/
	public static inline var DEFAULT_KEEPALIVE_COUNT:Int = 6;

	/**
		A count setting: its value, or `fallback` when unset, left out
		altogether when the caller names the keyword in `extra`.
	**/
	@:noCompletion private static function __addCount(out:StringBuf, extra:Map<String, String>, keyword:String, setting:String, value:Null<Int>,
			fallback:Int):Void {
		if (value != null && value < 0) {
			throw new ArgumentError('PostgresConfig.$setting must not be negative.');
		}

		if (value == null && extra != null && extra.exists(keyword)) {
			return;
		}

		__add(out, keyword, Std.string(value == null ? fallback : value));
	}

	/** `keyword` = `value`, unless the caller names the keyword in `extra`. **/
	@:noCompletion private static function __addDefault(out:StringBuf, extra:Map<String, String>, keyword:String, value:String):Void {
		if (extra != null && extra.exists(keyword)) {
			return;
		}

		__add(out, keyword, value);
	}

	/**
	 * Seconds as whole milliseconds, rounded up so a small limit never rounds
	 * down to zero, which for `statement_timeout` would mean no limit at all,
	 * and clamped where an Int runs out, about 24 days.
	 */
	@:noCompletion private static function __millis(setting:String, seconds:Float):String {
		if (Math.isNaN(seconds) || seconds < 0) {
			throw new ArgumentError('PostgresConfig.$setting must be a non-negative number of seconds.');
		}

		// Less a sliver first, because the product is not exact: 1.1 seconds is
		// 1100.0000000000002 milliseconds, which would round up to 1101.
		var millis:Float = Math.fceil(seconds * 1000.0 - 0.000001);

		if (millis < 0) {
			millis = 0;
		}

		if (millis > 2147483647.0) {
			millis = 2147483647.0;
		}

		return Std.string(Std.int(millis));
	}
}
