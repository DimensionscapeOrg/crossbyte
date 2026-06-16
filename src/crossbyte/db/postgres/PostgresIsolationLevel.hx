package crossbyte.db.postgres;

import crossbyte.errors.ArgumentError;

/** PostgreSQL transaction isolation levels accepted by `PostgresConnection`. */
enum abstract PostgresIsolationLevel(String) to String {
	var READ_UNCOMMITTED = "READ UNCOMMITTED";
	var READ_COMMITTED = "READ COMMITTED";
	var REPEATABLE_READ = "REPEATABLE READ";
	var SERIALIZABLE = "SERIALIZABLE";

	/**
	 * Validating coercion from a raw string. Only canonical isolation levels are
	 * accepted; separators (`-`, `_`) and case are normalized so values reported
	 * by the server still map. Any other input is rejected so an
	 * attacker-controlled string can never be concatenated into a
	 * `SET ... ISOLATION LEVEL <v>` statement.
	 */
	@:from public static function ofString(value:String):PostgresIsolationLevel {
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
