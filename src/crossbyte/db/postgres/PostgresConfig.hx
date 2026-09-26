package crossbyte.db.postgres;

/**
 * Connection settings for `PostgresConnection`.
 *
 * Nothing bounds a query by default: a slow statement, a lock wait or a
 * database host that vanished mid-query holds the connection, and the
 * worker using it, until the server or the operating system gives up, which
 * for a silent network partition is TCP's own keepalive, about two hours. The
 * limits below are how to bound it. `statementTimeout` covers a server that
 * is up but slow; the keepalive settings and `tcpUserTimeout` cover a server
 * that has stopped answering altogether. `PostgresConnection.cancel()` stops
 * one statement on demand.
 *
 * The timeouts and keepalive settings apply to the native driver, which
 * passes them to libpq.
 */
typedef PostgresConfig = {
	@:optional var host:String;
	@:optional var port:Int;
	@:optional var user:String;
	@:optional var password:String;
	@:optional var database:String;
	@:optional var sslMode:String;
	@:optional var connectTimeout:Int;
	@:optional var libraryPath:String;
	@:optional var libraryPaths:Array<String>;

	/**
	 * Seconds a statement may run before the server cancels it, sent as
	 * `statement_timeout` when the session starts, so it costs no round trip.
	 * Unset keeps the server's own setting; `0` turns a server-side limit off.
	 */
	@:optional var statementTimeout:Float;

	/**
	 * Seconds a connection may sit idle before TCP keepalive probes start
	 * (libpq `keepalives_idle`). The operating system's default is usually
	 * two hours, which is how long a pooled connection to a host that has gone
	 * away can look alive.
	 */
	@:optional var keepAliveIdle:Int;

	/** Seconds between unanswered keepalive probes (libpq `keepalives_interval`). */
	@:optional var keepAliveInterval:Int;

	/** Unanswered keepalive probes before the connection is dropped (libpq `keepalives_count`). */
	@:optional var keepAliveCount:Int;

	/**
	 * Seconds data sent may go unacknowledged before the connection is dropped
	 * (libpq `tcp_user_timeout`, libpq 12 or later, Linux only). Keepalives only
	 * probe a connection with nothing in flight; this covers a query sent to a
	 * host that then vanished.
	 */
	@:optional var tcpUserTimeout:Float;

	/**
	 * Further libpq connection parameters, by keyword (`application_name`,
	 * `target_session_attrs` and so on), passed to libpq as given. A keyword
	 * libpq does not know fails the connection rather than being ignored.
	 */
	@:optional var connectionParameters:Map<String, String>;
}
