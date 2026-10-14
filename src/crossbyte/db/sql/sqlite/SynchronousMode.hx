package crossbyte.db.sql.sqlite;

import crossbyte.errors.ArgumentError;

/** SQLite synchronous durability modes. */
enum abstract SynchronousMode(Int) from Int to Int {
	var OFF:Int = 0;
	var NORMAL:Int = 1;
	var FULL:Int = 2;
	var EXTRA:Int = 3;

	/**
		The mode a string names, for a value from a configuration file: a name
		in any case (`normal`), or the number SQLite's `PRAGMA synchronous`
		takes for it (`0` to `3`), spaces around it ignored.

		```haxe
		var mode:SynchronousMode = SynchronousMode.fromString("normal");
		```

		@throws ArgumentError For anything else, null included, rather than a
		        mode the configuration did not ask for.
	**/
	public static function fromString(value:String):SynchronousMode {
		return switch (value == null ? null : StringTools.trim(value).toUpperCase()) {
			case "OFF", "0": OFF;
			case "NORMAL", "1": NORMAL;
			case "FULL", "2": FULL;
			case "EXTRA", "3": EXTRA;
			default: throw new ArgumentError('Invalid SQLite synchronous mode: $value (expected OFF, NORMAL, FULL or EXTRA)');
		}
	}
}
