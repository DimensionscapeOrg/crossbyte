package crossbyte.db.mysql;

/** Connection settings for `MySQLConnection`. */
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
	 * whenever the server offers it. See `MySQLSSLMode`. Native client only.
	 */
	@:optional var sslMode:MySQLSSLMode;

	/**
	 * A PEM file of the certificate authorities the server's certificate must
	 * chain to, for `VERIFY_CA` and `VERIFY_IDENTITY`.
	 */
	@:optional var sslCa:String;

	/**
	 * The server's RSA public key, as PEM text. An account on
	 * `caching_sha2_password`: MySQL 8's default, that the server has not
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
}
