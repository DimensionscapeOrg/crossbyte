package crossbyte.db;

/**
 * A connection that can say whether a transaction is open on it, and end
 * one. `PostgresConnection`, `MySQLConnection` and `SQLiteConnection`
 * implement it.
 *
 * `ConnectionPool` relies on it: a connection that comes back to the pool
 * with a transaction still open has that transaction rolled back before any
 * other caller can take it. Implement it on a connection type of your own
 * to get the same.
 */
interface ITransactionalConnection {
	/**
	 * Whether a transaction is open on this connection, including one a
	 * failed statement has left waiting for a rollback.
	 */
	var inTransaction(get, null):Bool;

	/**
	 * Ends the open transaction and discards its changes. Throws when it
	 * fails, which leaves the connection's state unknown.
	 */
	function rollback():Void;
}
