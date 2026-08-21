package crossbyte.net;

#if (!java && !jvm)
import crossbyte.net.Certificate;
import crossbyte.net.Key;
#end

/**
 * Generates a throwaway self-signed certificate for TLS tests.
 *
 * The certificate is produced at test time with the `openssl` CLI and cached
 * in the system temp directory, so nothing expirable is committed to the
 * repository. Returns `null` when no usable toolchain is present, letting
 * callers skip rather than fail on machines without OpenSSL.
 */
class TLSTestFixture {
	#if (!java && !jvm)
	private static var __cached:TLSFixtureData;
	private static var __attempted:Bool = false;

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

	private static function __tempDirectory():String {
		var candidates:Array<String> = [Sys.getEnv("TEMP"), Sys.getEnv("TMP"), Sys.getEnv("TMPDIR"), "/tmp"];
		for (candidate in candidates) {
			if (candidate != null && candidate != "" && sys.FileSystem.exists(candidate)) {
				return candidate;
			}
		}
		return ".";
	}
	#end
}

#if (!java && !jvm)
typedef TLSFixtureData = {
	var certificate:Certificate;
	var key:Key;
	var certificatePath:String;
	var keyPath:String;
}
#end
