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

	/**
		A self-signed certificate a client can be told to trust, naming
		`names` -- `localhost` and `127.0.0.1` unless others are asked for.

		`selfSigned` is made to last a day and then kept on disk for good, so
		the copy a test finds there has usually expired. A server presenting it
		does not mind; a client verifying it refuses it for the expiry, which
		would let a test of verification pass for the wrong reason. So this one
		is made fresh each day, is valid for a week, and names what the tests
		actually connect to.

		An address is written twice, as a DNS name and as an IP entry: mbedTLS
		compares the connect name as text against the DNS names, where the JDK
		and Node look an address up among the IP entries.

		Made in a directory of its own and then renamed into place, so two test
		processes starting together cannot pair one's key with the other's
		certificate. Returns `null` when there is no `openssl` to make one.
	**/
	public static function trusted(?names:Array<String>):TLSFixtureData {
		if (names == null || names.length == 0) {
			names = ["localhost", "127.0.0.1"];
		}

		var key:String = names.join(",");
		if (__trustedAttempted.exists(key)) {
			return __trusted.get(key);
		}
		__trustedAttempted.set(key, true);

		var root:String = haxe.io.Path.join([__tempDirectory(), "crossbyte-tls-test"]);
		var safe:String = ~/[^A-Za-z0-9.-]/g.replace(key, "_");
		// time of day: the directory is named for the calendar day it was made
		// on, which is what decides when a new one is due.
		var day:String = DateTools.format(Date.now(), "%Y%m%d");
		var directory:String = haxe.io.Path.join([root, "trusted-" + safe + "-" + day]);
		var certPath:String = haxe.io.Path.join([directory, "cert.pem"]);
		var keyPath:String = haxe.io.Path.join([directory, "key.pem"]);

		try {
			if (!sys.FileSystem.exists(root)) {
				sys.FileSystem.createDirectory(root);
			}

			if (!sys.FileSystem.exists(certPath) || !sys.FileSystem.exists(keyPath)) {
				var staging:String = directory + "-" + Std.random(0x7FFFFFFF);
				sys.FileSystem.createDirectory(staging);

				var altNames:Array<String> = [];
				for (name in names) {
					// An IPv6 address only as an IP entry: it is no DNS name,
					// and nothing compares it as one.
					if (name.indexOf(":") >= 0) {
						altNames.push("IP:" + name);
						continue;
					}
					altNames.push("DNS:" + name);
					if (~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.match(name)) {
						altNames.push("IP:" + name);
					}
				}

				var exit:Int = Sys.command("openssl", [
					"req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "7", "-subj", "/CN=" + names[0],
					"-addext", "subjectAltName=" + altNames.join(","),
					"-keyout", haxe.io.Path.join([staging, "key.pem"]), "-out", haxe.io.Path.join([staging, "cert.pem"])
				]);

				if (exit != 0) {
					__removeQuietly(staging);
					return null;
				}

				try {
					sys.FileSystem.rename(staging, directory);
				} catch (_:Dynamic) {
					// Another process got there first; its pair is as good.
					__removeQuietly(staging);
				}

				// Earlier days' pairs for the same names. Only whole-day
				// directories: a staging directory carries a random suffix and
				// may belong to a process still writing it.
				var stale:EReg = new EReg("^trusted-" + ~/\./g.replace(safe, "\\.") + "-[0-9]{8}$", "");
				for (entry in sys.FileSystem.readDirectory(root)) {
					if (stale.match(entry) && entry != "trusted-" + safe + "-" + day) {
						__removeQuietly(haxe.io.Path.join([root, entry]));
					}
				}
			}

			__trusted.set(key, {
				certificate: Certificate.fromFile(certPath),
				key: Key.fromFile(keyPath),
				certificatePath: certPath,
				keyPath: keyPath
			});
		} catch (_:Dynamic) {
			__trusted.set(key, null);
		}

		return __trusted.get(key);
	}

	private static var __trusted:Map<String, TLSFixtureData> = new Map();
	private static var __trustedAttempted:Map<String, Bool> = new Map();

	private static function __removeQuietly(directory:String):Void {
		try {
			for (entry in sys.FileSystem.readDirectory(directory)) {
				sys.FileSystem.deleteFile(haxe.io.Path.join([directory, entry]));
			}
			sys.FileSystem.deleteDirectory(directory);
		} catch (_:Dynamic) {}
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
