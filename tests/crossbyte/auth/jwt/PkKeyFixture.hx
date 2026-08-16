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

	/**
	 * The RSA public modulus as base64url, the form a JWK publishes as
	 * `n`, or `null` when it cannot be read.
	 *
	 * Taken from the generated key rather than invented, so a JWKS test
	 * built on it round-trips against a key mbedTLS will actually verify
	 * with. The exponent is not extracted: these keys are generated with
	 * OpenSSL's default of 65537, and a wrong exponent would fail the
	 * signature check the test ends with anyway.
	 */
	public static function rsaModulusBase64Url():Null<String> {
		if (rsa() == null) {
			return null;
		}

		var line:Null<String> = __openssl(["rsa", "-pubin", "-in", haxe.io.Path.join([__directory(), "rsa-pub.pem"]), "-noout", "-modulus"]);
		if (line == null) {
			return null;
		}

		var marker:Int = line.indexOf("Modulus=");
		if (marker < 0) {
			return null;
		}

		var hex:String = StringTools.trim(line.substr(marker + "Modulus=".length));
		hex = hex.split("\r").join("").split("\n").join("");
		if (hex.length == 0 || hex.length % 2 != 0) {
			return null;
		}

		try {
			return crossbyte.auth.jwt.JWT.base64UrlEncodeBytes(haxe.io.Bytes.ofHex(hex));
		} catch (_:Dynamic) {
			return null;
		}
	}

	/**
	 * The P-256 public point split into its affine coordinates as
	 * base64url, the form a JWK publishes as `x` and `y`.
	 */
	public static function ecCoordinatesBase64Url():Null<{x:String, y:String}> {
		if (ec() == null) {
			return null;
		}

		var text:Null<String> = __openssl(["ec", "-pubin", "-in", haxe.io.Path.join([__directory(), "ec-pub.pem"]), "-noout", "-text"]);
		if (text == null) {
			return null;
		}

		// The uncompressed point is printed as colon-separated hex between
		// the "pub:" label and the curve line that follows it.
		var start:Int = text.indexOf("pub:");
		if (start < 0) {
			return null;
		}
		var rest:String = text.substr(start + "pub:".length);
		var end:Int = rest.indexOf("ASN1 OID");
		if (end >= 0) {
			rest = rest.substr(0, end);
		}

		var hex:StringBuf = new StringBuf();
		for (i in 0...rest.length) {
			var c:String = rest.charAt(i);
			if ((c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")) {
				hex.add(c);
			}
		}

		var point:haxe.io.Bytes;
		try {
			point = haxe.io.Bytes.ofHex(hex.toString());
		} catch (_:Dynamic) {
			return null;
		}

		// 0x04 then two 32-byte coordinates.
		if (point.length != 65 || point.get(0) != 0x04) {
			return null;
		}

		return {
			x: crossbyte.auth.jwt.JWT.base64UrlEncodeBytes(point.sub(1, 32)),
			y: crossbyte.auth.jwt.JWT.base64UrlEncodeBytes(point.sub(33, 32))
		};
	}

	/** Runs `openssl` and returns its stdout, or `null` if it fails. */
	private static function __openssl(args:Array<String>):Null<String> {
		try {
			var process = new sys.io.Process("openssl", args);
			var out:String = process.stdout.readAll().toString();
			var code:Int = process.exitCode();
			process.close();
			return code == 0 ? out : null;
		} catch (_:Dynamic) {
			return null;
		}
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
