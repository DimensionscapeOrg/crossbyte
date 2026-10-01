package crossbyte.db.sql.sqlite;

/**
	How `SQLiteConnection.open()` and `openAsync()` open a database file, as
	AIR's `SQLMode`. An in-memory database is always opened as `CREATE`.

	@author Christopher Speciale
**/
enum abstract SQLiteMode(String) from String to SQLiteMode {
	/** To read and write, creating the file when it does not exist. **/
	var CREATE:String = "create";

	/**
		To read only. The file must exist, and a statement that would change
		the database fails with an `SQLError`. The limit is SQLite's
		`query_only`, set as the connection opens, hxcpp's glue opens every
		file to read and write, so a statement the connection runs itself,
		`PRAGMA query_only = 0`, can lift it.
	**/
	var READ:String = "read";

	/** To read and write. The file must exist. **/
	var UPDATE:String = "update";
}
