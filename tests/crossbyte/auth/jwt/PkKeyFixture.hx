package crossbyte.auth.jwt;

/**
 * A PEM keypair used by the asymmetric JWT tests.
 */
typedef PkKeyPair = {
	var publicPem:String;
	var privatePem:String;
}

/**
 * Generates throwaway RSA and EC keypairs for tests using the `openssl`
 * CLI, cached in the system temp directory.
 *
 * Keys are generated rather than committed so nothing expirable or
 * secret-shaped lives in the repository. Returns `null` when no toolchain
 * is available, letting callers skip instead of failing on machines
 * without OpenSSL.
 */
class PkKeyFixture {
	private static var __rsa:PkKeyPair;
	private static var __ec:PkKeyPair;
	private static var __rsaAttempted:Bool = false;
	private static var __ecAttempted:Bool = false;

	public static function rsa():PkKeyPair {
		if (__rsaAttempted) {
			return __rsa;
		}
		__rsaAttempted = true;

		var directory:String = __directory();
		var privatePath:String = haxe.io.Path.join([directory, "rsa-key.pem"]);
		var publicPath:String = haxe.io.Path.join([directory, "rsa-pub.pem"]);

		try {
			if (!sys.FileSystem.exists(privatePath) || !sys.FileSystem.exists(publicPath)) {
				if (Sys.command("openssl", ["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", privatePath]) != 0) {
					return null;
				}
				if (Sys.command("openssl", ["pkey", "-in", privatePath, "-pubout", "-out", publicPath]) != 0) {
					return null;
				}
			}

			__rsa = {publicPem: sys.io.File.getContent(publicPath), privatePem: sys.io.File.getContent(privatePath)};
		} catch (_:Dynamic) {
			__rsa = null;
		}

		return __rsa;
	}

	public static function ec():PkKeyPair {
		if (__ecAttempted) {
			return __ec;
		}
		__ecAttempted = true;

		var directory:String = __directory();
		var privatePath:String = haxe.io.Path.join([directory, "ec-key.pem"]);
		var publicPath:String = haxe.io.Path.join([directory, "ec-pub.pem"]);

		try {
			if (!sys.FileSystem.exists(privatePath) || !sys.FileSystem.exists(publicPath)) {
				if (Sys.command("openssl", ["ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", privatePath]) != 0) {
					return null;
				}
				if (Sys.command("openssl", ["ec", "-in", privatePath, "-pubout", "-out", publicPath]) != 0) {
					return null;
				}
			}

			__ec = {publicPem: sys.io.File.getContent(publicPath), privatePem: sys.io.File.getContent(privatePath)};
		} catch (_:Dynamic) {
			__ec = null;
		}

		return __ec;
	}

	private static function __directory():String {
		var base:String = ".";
		for (candidate in [Sys.getEnv("TEMP"), Sys.getEnv("TMP"), Sys.getEnv("TMPDIR"), "/tmp"]) {
			if (candidate != null && candidate != "" && sys.FileSystem.exists(candidate)) {
				base = candidate;
				break;
			}
		}

		var directory:String = haxe.io.Path.join([base, "crossbyte-pk-test"]);
		if (!sys.FileSystem.exists(directory)) {
			sys.FileSystem.createDirectory(directory);
		}
		return directory;
	}
}
