package crossbyte.db.sql.sqlite;

/**
 * ...
 * @author Christopher Speciale
 */
enum abstract SQLiteMode(String) from String to SQLiteMode {
	var CREATE:String = "create";
	var READ:String = "read";
	var UPDATE:String = "update";
}
