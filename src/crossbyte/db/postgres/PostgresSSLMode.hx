package crossbyte.db.postgres;

/**
	How much TLS a PostgreSQL connection insists on: libpq's `sslmode`, each
	value spelt as libpq takes it.

	- `DISABLE`: never.
	- `ALLOW`: without TLS first, and with it if the server refuses that.
	- `PREFER`, libpq's default when `PostgresConfig.sslMode` is unset: with
	  TLS when the server offers it, without checking whose certificate it
	  is. That protects the session against anyone listening, not against
	  anyone in the middle.
	- `REQUIRE`: as `PREFER`, and fails against a server without TLS. With a
	  root certificate given (`sslrootcert` in
	  `PostgresConfig.connectionParameters`), it checks the chain as
	  `VERIFY_CA` does.
	- `VERIFY_CA`: TLS, and the server's certificate must chain to the root
	  certificate given (`sslrootcert`, or libpq's default file).
	- `VERIFY_FULL`: as `VERIFY_CA`, and the certificate must name the host
	  connected to.
**/
enum abstract PostgresSSLMode(String) to String {
	var DISABLE = "disable";
	var ALLOW = "allow";
	var PREFER = "prefer";
	var REQUIRE = "require";
	var VERIFY_CA = "verify-ca";
	var VERIFY_FULL = "verify-full";
}
