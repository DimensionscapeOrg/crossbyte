package crossbyte.db.mysql;

import crossbyte.errors.IOError;

/**
 * `MySQLConnection.open()` failing: the `IOError` it always threw, with the
 * MySQL error number and SQLSTATE of why -- 1045 for a refused login, 1049
 * for an unknown database, 2003 for a server that could not be reached,
 * 2013 for one that stopped answering, 2026 for a TLS failure.
 */
class MySQLConnectionError extends IOError {
	/** The MySQL error number, or `0` when the driver gave none. **/
	public var code(default, null):Int;

	/** The SQLSTATE, `HY000` when there is no more specific class. **/
	public var sqlState(default, null):String;

	public function new(message:String, code:Int = 0, sqlState:String = "HY000") {
		super(message);
		name = "MySQLConnectionError";
		this.code = code;
		this.sqlState = (sqlState == null || sqlState == "") ? "HY000" : sqlState;
	}
}
