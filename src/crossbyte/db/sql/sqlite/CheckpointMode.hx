package crossbyte.db.sql.sqlite;

enum abstract CheckpointMode(String) from String to String {
	var PASSIVE = "PASSIVE";
	var FULL = "FULL";
	var RESTART = "RESTART";
	var TRUNCATE = "TRUNCATE";
}
