package crossbyte.db.sql.sqlite;

enum abstract SynchronousMode(Int) from Int to Int {
	var OFF:Int = 0;
	var NORMAL:Int = 1;
	var FULL:Int = 2;
	var EXTRA:Int = 3;

	
}
