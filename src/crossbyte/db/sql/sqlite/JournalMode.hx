package crossbyte.db.sql.sqlite;
enum abstract JournalMode(String) from String to String {
	var DELETE = "DELETE";
	var TRUNCATE = "TRUNCATE";
	var PERSIST = "PERSIST";
	var MEMORY = "MEMORY";
	var WAL = "WAL";
	var OFF = "OFF";

	public static function fromString(v:String):JournalMode {
		return switch (v.toUpperCase()) {
			case "TRUNCATE": TRUNCATE;
			case "PERSIST": PERSIST;
			case "MEMORY": MEMORY;
			case "WAL": WAL;
			case "OFF": OFF;
			case "DELETE": DELETE;
			default: DELETE;
		}
	}
}
