package crossbyte.db.sql.sqlite;

import crossbyte.errors.ArgumentError;

/** SQLite journal modes accepted by `SQLiteConnection`. */
enum abstract JournalMode(String) from String to String {
	var DELETE = "DELETE";
	var TRUNCATE = "TRUNCATE";
	var PERSIST = "PERSIST";
	var MEMORY = "MEMORY";
	var WAL = "WAL";
	var OFF = "OFF";

	/**
		The mode a string names, for a value from a configuration file: the
		names in any case (`wal`), spaces around it ignored.

		```haxe
		var mode:JournalMode = JournalMode.fromString("wal");
		```

		@throws ArgumentError For anything else, null included, rather than a
		        mode the configuration did not ask for.
	**/
	public static function fromString(value:String):JournalMode {
		return switch (value == null ? null : StringTools.trim(value).toUpperCase()) {
			case "TRUNCATE": TRUNCATE;
			case "PERSIST": PERSIST;
			case "MEMORY": MEMORY;
			case "WAL": WAL;
			case "OFF": OFF;
			case "DELETE": DELETE;
			default: throw new ArgumentError('Invalid SQLite journal mode: $value (expected DELETE, TRUNCATE, PERSIST, MEMORY, WAL or OFF)');
		}
	}

	/** What SQLite answers for `PRAGMA journal_mode`, as a mode; `DELETE`, its default, for anything else. **/
	@:noCompletion private static function __ofPragma(value:String):JournalMode {
		return switch (value == null ? null : value.toUpperCase()) {
			case "TRUNCATE": TRUNCATE;
			case "PERSIST": PERSIST;
			case "MEMORY": MEMORY;
			case "WAL": WAL;
			case "OFF": OFF;
			default: DELETE;
		}
	}
}
