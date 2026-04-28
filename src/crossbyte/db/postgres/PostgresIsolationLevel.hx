package crossbyte.db.postgres;

enum abstract PostgresIsolationLevel(String) from String to String {
	var READ_UNCOMMITTED:String = "READ UNCOMMITTED";
	var READ_COMMITTED:String = "READ COMMITTED";
	var REPEATABLE_READ:String = "REPEATABLE READ";
	var SERIALIZABLE:String = "SERIALIZABLE";
}
