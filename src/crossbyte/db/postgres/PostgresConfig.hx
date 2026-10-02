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

	/**
	 * The libpq the native driver loads, as a path to the library or to the
	 * directory holding it, tried before anywhere else; `libraryPaths` are
	 * tried next, in order. A directory stands for `libpq.dll` on Windows,
	 * `libpq.5.dylib` and `libpq.dylib` on macOS, and `libpq.so.5` and
	 * `libpq.so` elsewhere.
	 *
	 * Then the driver looks where each system keeps it:
	 *
	 * - Windows: `php\libpq.dll` under the working directory and its parent,
	 *   `libpq.dll` beside the program, `php\libpq.dll` four directories
	 *   above it, and `libpq.dll` where Windows looks for a DLL.
	 * - macOS: `libpq.5.dylib` and `libpq.dylib` where dyld looks
	 *   (`DYLD_LIBRARY_PATH`, the working directory, `/usr/local/lib`,
	 *   `/usr/lib`), then `libpq.5.dylib` beside the program, in Homebrew's
	 *   `/opt/homebrew/opt/libpq/lib`, `/opt/homebrew/lib`,
	 *   `/usr/local/opt/libpq/lib` and `/usr/local/lib`, in Postgres.app
	 *   (`/Applications/Postgres.app/Contents/Versions/latest/lib`), in the
	 *   PostgreSQL installer's `/Library/PostgreSQL/<version>/lib` and in
	 *   MacPorts' `/opt/local/lib/postgresql<version>`, the newest first.
	 *   It looked for `libpq.so` alone, and could not load libpq on a Mac.
	 * - Linux and other systems: `libpq.so.5`, then `libpq.so`, where the
	 *   dynamic loader looks (`LD_LIBRARY_PATH`, `/etc/ld.so.cache`).
	 *
	 * A library installed anywhere else is given here. The first that loads
	 * and has the calls the driver needs is used; an open that finds none
	 * fails naming every path it tried.
	 */
	@:optional var libraryPath:String;

	/** Further places to look for libpq, after `libraryPath`; see there. */
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
