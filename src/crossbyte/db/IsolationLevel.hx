package crossbyte.db;

import crossbyte.errors.ArgumentError;

/**
	A transaction isolation level, as `MySQLConnection.isolationLevel` and
	`PostgresConnection.isolationLevel` take one. Each value is the SQL
	spelling of the level.
**/
enum abstract IsolationLevel(String) to String {
	var READ_UNCOMMITTED = "READ UNCOMMITTED";
	var READ_COMMITTED = "READ COMMITTED";
	var REPEATABLE_READ = "REPEATABLE READ";
	var SERIALIZABLE = "SERIALIZABLE";

	/**
		The level a string names. Only the four levels are accepted;
		separators (`-`, `_`) and case are normalized, so a level as a server
		reports it (MySQL's `REPEATABLE-READ`) still maps. Any other input is
		refused with an `ArgumentError`, so a string from outside can never be
		put into a `SET ... ISOLATION LEVEL <v>` statement. A `String` is not
		taken as a level without it.
	**/
	public static function ofString(value:String):IsolationLevel {
		if (value == null) {
			throw new ArgumentError("Invalid isolation level: null");
		}
		return switch (StringTools.replace(StringTools.replace(value, "-", " "), "_", " ").toUpperCase()) {
			case "READ UNCOMMITTED": READ_UNCOMMITTED;
			case "READ COMMITTED": READ_COMMITTED;
			case "REPEATABLE READ": REPEATABLE_READ;
			case "SERIALIZABLE": SERIALIZABLE;
			default: throw new ArgumentError("Invalid isolation level: " + value);
		}
	}
}
