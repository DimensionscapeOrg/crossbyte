package crossbyte.db.mysql;

import crossbyte.errors.SQLError;

/**
 * A MySQL failure, with the error number and SQLSTATE that say what kind it
 * was: a deadlock to retry (1213, SQLSTATE `40001`), a duplicate key to
 * report (1062, `23000`), a statement interrupted by `cancel()` (1317), a
 * connection lost or timed out (2013).
 *
 * The message is the server's and holds no SQL. It used to begin with the
 * whole statement, values included, so a duplicate-key error on a row
 * holding an API token wrote the token into whatever logged the error.
 */
class MySQLError extends SQLError {
	/**
	 * The MySQL error number: the server's, or the client's (2003 could not
	 * connect, 2006 the connection is closed, 2013 lost or timed out); `0`
	 * when there is none, as for a driver that reports only a message.
	 */
	public var code(default, null):Int;

	/**
	 * The SQLSTATE, five characters: `HY000` when the server gave no more
	 * specific class, as for every error the client raises itself.
	 */
	public var sqlState(default, null):String;

	public function new(operation:String, details:String, message:String, code:Int = 0, sqlState:String = "HY000") {
		super(operation, details, message, code, code);
		name = "MySQLError";
		this.code = code;
		this.sqlState = (sqlState == null || sqlState == "") ? "HY000" : sqlState;
	}
}
