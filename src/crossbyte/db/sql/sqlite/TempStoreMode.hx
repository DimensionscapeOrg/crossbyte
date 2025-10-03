package crossbyte.db.sql.sqlite;

enum abstract TempStoreMode(Int) from Int to Int {
	var DEFAULT:Int = 0;
	var FILE:Int = 1;
	var MEMORY:Int = 2;

	
}
