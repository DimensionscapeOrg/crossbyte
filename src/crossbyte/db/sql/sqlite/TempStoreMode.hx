package crossbyte.db.sql.sqlite;

import crossbyte.errors.ArgumentError;

/** SQLite temporary storage modes. */
enum abstract TempStoreMode(Int) from Int to Int {
	var DEFAULT:Int = 0;
	var FILE:Int = 1;
	var MEMORY:Int = 2;

	/**
		The mode a string names, for a value from a configuration file: a name
		in any case (`memory`), or the number SQLite's `PRAGMA temp_store`
		takes for it (`0` to `2`), spaces around it ignored.

		```haxe
		var mode:TempStoreMode = TempStoreMode.fromString("memory");
		```

		@throws ArgumentError For anything else, null included.
	**/
	public static function fromString(value:String):TempStoreMode {
		return switch (value == null ? null : StringTools.trim(value).toUpperCase()) {
			case "DEFAULT", "0": DEFAULT;
			case "FILE", "1": FILE;
			case "MEMORY", "2": MEMORY;
			default: throw new ArgumentError('Invalid SQLite temp_store mode: $value (expected DEFAULT, FILE or MEMORY)');
		}
	}
}
