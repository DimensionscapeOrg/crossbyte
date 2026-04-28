package crossbyte.db.mysql;

/** MySQL transaction isolation levels accepted by `MySQLConnection`. */
enum abstract IsolationLevel(String) from String to String{
    var READ_UNCOMMITTED:String = "READ UNCOMMITTED";
    var READ_COMMITTED:String   = "READ COMMITTED";
    var REPEATABLE_READ:String  = "REPEATABLE READ";
    var SERIALIZABLE:String     = "SERIALIZABLE"; 
}
