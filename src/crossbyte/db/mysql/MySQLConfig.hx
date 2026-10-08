package crossbyte.db.mysql;

/**
 * Connection settings for `MySQLConnection`.
 *
 * The TLS, authentication, timeout and keepalive settings are the native
 * client's (cpp). Elsewhere the target's own driver connects with its own
 * defaults, and an `sslMode` that insists on TLS fails `open()`.
 */
typedef MySQLConfig = {
	var host:String;
	@:optional var port:Int;
	var user:String;
	var password:String;
	var database:String;
	@:optional var socket:String;
	@:optional var charset:String;
	@:optional var timeZone:String;
	@:optional var sqlMode:String;

	/**
	 * How much TLS to insist on; `PREFERRED` when unset, which uses it
	 * whenever the server offers it. See `MySQLSSLMode`. Only the native
	 * client has TLS: elsewhere a mode that insists on it fails `open()`.
	 *
	 * `PREFERRED` stays the default for a server across a network too, as
	 * it is in MySQL's own clients. Insisting on TLS there (`REQUIRED`)
	 * would refuse every server that offers none, which MariaDB before 11.4
	 * does not by default, and would still not keep out a man in the middle:
	 * neither mode checks whose certificate it is, so whoever answers in the
	 * server's place can encrypt to the client as well as the server could.
	 * What it would stop is a listener reading a session to a server that
	 * has TLS, after someone in the middle hid it. `VERIFY_CA` and
	 * `VERIFY_IDENTITY`, with `sslCa`, are what keep the middle out; use
	 * `VERIFY_IDENTITY` across any network you do not trust.
	 *
	 * Whoever answers cannot crash the native client: it bounds what it
	 * reads, and refuses an answer no server sends; `MySQLConnection` says
	 * how.
	 */
	@:optional var sslMode:MySQLSSLMode;

	/**
	 * A PEM file of the certificate authorities the server's certificate must
	 * chain to, for `VERIFY_CA` and `VERIFY_IDENTITY`.
	 */
	@:optional var sslCa:String;

	/**
	 * The server's RSA public key, as PEM text. An account on
	 * `caching_sha2_password` (MySQL 8's default) that the server has not
	 * yet cached needs the password itself, once; over a connection without
	 * TLS the client sends it encrypted with this key. The server writes it to
	 * `public_key.pem` in its data directory.
	 */
	@:optional var serverPublicKey:String;

	/**
	 * Lets the client ask the server for its RSA public key when it needs one
	 * and was not given `serverPublicKey`. Off by default, as in MySQL's own
	 * clients: over a connection without TLS, whoever answers in the server's
	 * place can hand over a key of their own and read the password.
	 */
	@:optional var allowPublicKeyRetrieval:Bool;

	/**
	 * Seconds to reach the server and log in before `open()` gives up: 10 when
	 * unset, 0 for no limit. A connect to a host that drops the packets
	 * otherwise waits for the operating system (21 seconds on Windows, over
	 * two minutes on Linux).
	 *
	 * One deadline for all of it: the connect, TLS, the greeting and the
	 * login, so a server that answers a byte at a time cannot hold `open()`
	 * for as long as it goes on. NaN and negatives are refused with an
	 * `ArgumentError`.
	 *
	 * The `MySQLConnectionError` says which ran out: 2003, "Timed out after
	 * ... connecting", when no connection was made in time (the host
	 * dropped the packets, or its listener's queue was full), and 2013,
	 * "Timed out after ... waiting for the server's greeting", when one was
	 * made and the server said nothing. The system makes a connection for a
	 * listener whose queue has room before the server takes it, so a server
	 * too busy to accept reads as the second, on every system.
	 */
	@:optional var connectTimeout:Float;

	/**
	 * Seconds any one read may wait for the server once connected, or unset or
	 * 0 for no limit; NaN and negatives are refused. It bounds a statement's
	 * whole run as the client sees it,
	 * so set it above the slowest statement expected; a read that times out
	 * closes the connection, since the answer it gave up on is still coming.
	 * `MySQLConnection.cancel()` stops one statement on demand; a limit that
	 * the server enforces is `SET SESSION max_execution_time` (MySQL, SELECT
	 * only) or `max_statement_time` (MariaDB).
	 */
	@:optional var readTimeout:Float;

	/** Seconds any one write may wait, or unset or 0 for no limit; NaN and negatives are refused. **/
	@:optional var writeTimeout:Float;

	/**
	 * TCP keepalive, on unless set `false`, so a connection to a server that
	 * has vanished (a partition, a host that died without closing) is
	 * noticed instead of waited on: about two minutes with the timings
	 * below, rather than the whole of the read timeout for a query sent to
	 * such a host.
	 */
	@:optional var keepAlive:Bool;

	/** Idle seconds before the first keepalive probe: 60 when unset. **/
	@:optional var keepAliveIdle:Int;

	/** Seconds between unanswered probes: 10 when unset. **/
	@:optional var keepAliveInterval:Int;

	/**
	 * Unanswered probes before the connection is dropped: 6 when unset.
	 * Windows before 10 (1703) fixes the count at 10 and ignores this.
	 */
	@:optional var keepAliveCount:Int;
}
