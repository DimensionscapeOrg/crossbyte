package crossbyte.db.postgres;

import crossbyte.errors.ArgumentError;

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

	/**
		The mode a string names, for a value from a configuration file: libpq's
		spelling in any case, with `_` for `-` (`VERIFY_FULL`), spaces around
		it ignored. A `String` is not taken as a mode without it.

		```haxe
		var mode:PostgresSSLMode = PostgresSSLMode.fromString("verify-full");
		```

		@throws ArgumentError For anything else, null included, rather than
		        reading a mistyped mode as a weaker one.
	**/
	public static function fromString(value:String):PostgresSSLMode {
		return switch (value == null ? null : StringTools.replace(StringTools.trim(value), "_", "-").toLowerCase()) {
			case "disable": DISABLE;
			case "allow": ALLOW;
			case "prefer": PREFER;
			case "require": REQUIRE;
			case "verify-ca": VERIFY_CA;
			case "verify-full": VERIFY_FULL;
			default: throw new ArgumentError('Invalid PostgreSQL sslmode: $value (expected disable, allow, prefer, require, verify-ca or verify-full)');
		}
	}
}
