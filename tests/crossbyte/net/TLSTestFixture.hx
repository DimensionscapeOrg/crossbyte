package crossbyte.net;

import crossbyte.net.Certificate;
import crossbyte.net.Key;

/**
 * Generates a throwaway self-signed certificate for TLS tests.
 *
 * The certificate is produced at test time with the `openssl` CLI and cached
 * in the system temp directory, so nothing expirable is committed to the
 * repository. Returns `null` when no usable toolchain is present, letting
 * callers skip rather than fail on machines without OpenSSL.
 */
class TLSTestFixture {
		private static var __cached:TLSFixtureData;
	private static var __attempted:Bool = false;
	private static var __named:Map<String, TLSFixtureData> = new Map();
	private static var __namedAttempted:Map<String, Bool> = new Map();

	public static function selfSigned():TLSFixtureData {
		if (__attempted) {
			return __cached;
		}
		__attempted = true;

		var directory:String = haxe.io.Path.join([__tempDirectory(), "crossbyte-tls-test"]);
		var certPath:String = haxe.io.Path.join([directory, "test-cert.pem"]);
		var keyPath:String = haxe.io.Path.join([directory, "test-key.pem"]);

		try {
			if (!sys.FileSystem.exists(directory)) {
				sys.FileSystem.createDirectory(directory);
			}

			if (!sys.FileSystem.exists(certPath) || !sys.FileSystem.exists(keyPath)) {
				var exit:Int = Sys.command("openssl", [
					"req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", keyPath, "-out", certPath
				]);
				if (exit != 0) {
					return null;
				}
			}

			__cached = {
				certificate: Certificate.fromFile(certPath),
				key: Key.fromFile(keyPath),
				certificatePath: certPath,
				keyPath: keyPath
			};
		} catch (_:Dynamic) {
			__cached = null;
		}

		return __cached;
	}

	/**
		A second self-signed certificate, for a different common name.

		Server Name Indication cannot be tested with one certificate: a server
		that always presents the same one looks identical to a server that
		selects correctly. This is the other one to tell it apart from.
	**/
	public static function selfSignedFor(commonName:String):TLSFixtureData {
		if (__namedAttempted.exists(commonName)) {
			return __named.get(commonName);
		}

		__namedAttempted.set(commonName, true);

		var directory:String = haxe.io.Path.join([__tempDirectory(), "crossbyte-tls-test"]);
		var safe:String = ~/[^A-Za-z0-9.-]/g.replace(commonName, "_");
		var certPath:String = haxe.io.Path.join([directory, "cert-" + safe + ".pem"]);
		var keyPath:String = haxe.io.Path.join([directory, "key-" + safe + ".pem"]);

		try {
			if (!sys.FileSystem.exists(directory)) {
				sys.FileSystem.createDirectory(directory);
			}

			if (!sys.FileSystem.exists(certPath) || !sys.FileSystem.exists(keyPath)) {
				var exit:Int = Sys.command("openssl", [
					"req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=" + commonName,
					"-keyout", keyPath, "-out", certPath
				]);

				if (exit != 0) {
					return null;
				}
			}

			__named.set(commonName, {
				certificate: Certificate.fromFile(certPath),
				key: Key.fromFile(keyPath),
				certificatePath: certPath,
				keyPath: keyPath
			});
		} catch (_:Dynamic) {
			__named.set(commonName, null);
		}

		return __named.get(commonName);
	}

	private static function __tempDirectory():String {
		var candidates:Array<String> = [Sys.getEnv("TEMP"), Sys.getEnv("TMP"), Sys.getEnv("TMPDIR"), "/tmp"];
		for (candidate in candidates) {
			if (candidate != null && candidate != "" && sys.FileSystem.exists(candidate)) {
				return candidate;
			}
		}
		return ".";
	}
}

typedef TLSFixtureData = {
	var certificate:Certificate;
	var key:Key;
	var certificatePath:String;
	var keyPath:String;
}
