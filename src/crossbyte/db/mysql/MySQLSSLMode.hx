package crossbyte.db.mysql;

import crossbyte.errors.ArgumentError;

/**
 * How much TLS a MySQL connection insists on: the modes of libmysqlclient's
 * `--ssl-mode`, and what they mean there.
 *
 * - `DISABLED`: never.
 * - `PREFERRED`, the default: when the server offers it, without checking
 *   whose certificate it is. That protects the session, and the password
 *   `caching_sha2_password` sends in full authentication, against anyone
 *   listening, not against anyone in the middle. MySQL generates a
 *   self-signed certificate by default, which nothing could verify. It is
 *   the default for a remote server too; `MySQLConfig.sslMode` says why.
 * - `REQUIRED`: as `PREFERRED`, and fails against a server without TLS.
 * - `VERIFY_CA`: as `REQUIRED`, and the certificate must chain to one in
 *   `MySQLConfig.sslCa`.
 * - `VERIFY_IDENTITY`: as `VERIFY_CA`, and must name the host connected to.
 *
 * TLS applies to the native client. Elsewhere the target's own driver makes
 * the connection without it, so `REQUIRED` and the `VERIFY` modes fail
 * `open()` there, with error 2026, before anything is sent.
 */
enum abstract MySQLSSLMode(String) to String {
	var DISABLED = "DISABLED";
	var PREFERRED = "PREFERRED";
	var REQUIRED = "REQUIRED";
	var VERIFY_CA = "VERIFY_CA";
	var VERIFY_IDENTITY = "VERIFY_IDENTITY";

	/**
		Accepts the names in any case, with `-` for `_` (`verify-identity`), so
		a value from a configuration file maps. Anything else is refused rather
		than read as a weaker mode.
	**/
	@:from public static function ofString(value:String):MySQLSSLMode {
		if (value == null) {
			throw new ArgumentError("Invalid MySQL sslMode: null");
		}

		return switch (StringTools.replace(StringTools.trim(value), "-", "_").toUpperCase()) {
			case "DISABLED": DISABLED;
			case "PREFERRED": PREFERRED;
			case "REQUIRED": REQUIRED;
			case "VERIFY_CA": VERIFY_CA;
			case "VERIFY_IDENTITY": VERIFY_IDENTITY;
			default: throw new ArgumentError("Invalid MySQL sslMode: " + value);
		}
	}

	/** The native client's number for the mode. **/
	@:noCompletion public function toCode():Int {
		return switch (cast this : MySQLSSLMode) {
			case DISABLED: 0;
			case PREFERRED: 1;
			case REQUIRED: 2;
			case VERIFY_CA: 3;
			case VERIFY_IDENTITY: 4;
		}
	}
}
