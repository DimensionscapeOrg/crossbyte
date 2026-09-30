package crossbyte.net;

/**
	A small public-key infrastructure for TLS tests: a root, an intermediate
	under it, and certificates issued by each.

	`TLSTestFixture` makes one self-signed certificate at a time, which is
	enough to prove a handshake and nothing about chains, and a chain is
	what every certificate from a public authority is. A server given the
	`fullchain.pem` such an authority issues has to present the intermediate
	too, and a client given a bundle of authorities has to trust every one of
	them; neither can be shown with a certificate that is its own issuer.

	Made with the `openssl` CLI, fresh each day and valid for a week, in a
	directory of its own that is renamed into place, so two test processes
	starting together cannot mix one's keys with the other's certificates.
	Returns `null` when there is no `openssl` to make it with.
**/
class TLSChainFixture {
	private static var __cached:TLSChainData;
	private static var __attempted:Bool = false;

	public static function get():Null<TLSChainData> {
		if (__attempted) {
			return __cached;
		}
		__attempted = true;

		var root:String = haxe.io.Path.join([__tempDirectory(), "crossbyte-tls-test"]);
		// time of day: the directory is named for the calendar day it was made
		// on, which is what decides when a new one is due.
		var day:String = DateTools.format(Date.now(), "%Y%m%d");
		var directory:String = haxe.io.Path.join([root, "chain-" + day]);

		try {
			if (!sys.FileSystem.exists(root)) {
				sys.FileSystem.createDirectory(root);
			}

			if (!sys.FileSystem.exists(haxe.io.Path.join([directory, "complete"]))) {
				var staging:String = directory + "-" + Std.random(0x7FFFFFFF);
				sys.FileSystem.createDirectory(staging);

				if (!__make(staging)) {
					__removeQuietly(staging);
					return null;
				}

				try {
					sys.FileSystem.rename(staging, directory);
				} catch (_:Dynamic) {
					// Another process got there first; its set is as good.
					__removeQuietly(staging);
				}

				var stale:EReg = ~/^chain-[0-9]{8}$/;
				for (entry in sys.FileSystem.readDirectory(root)) {
					if (stale.match(entry) && entry != "chain-" + day) {
						__removeQuietly(haxe.io.Path.join([root, entry]));
					}
				}
			}

			function path(name:String):String {
				return haxe.io.Path.join([directory, name]);
			}

			__cached = {
				directory: directory,
				root: Certificate.fromFile(path("root.pem")),
				fullChain: Certificate.fromFile(path("fullchain.pem")),
				leafKey: Key.fromFile(path("leaf.key")),
				direct: Certificate.fromFile(path("direct.pem")),
				directKey: Key.fromFile(path("direct.key")),
				client: Certificate.fromFile(path("client.pem")),
				clientKey: Key.fromFile(path("client.key")),
				bundle: Certificate.fromFile(path("bundle.pem")),
				other: Certificate.fromFile(path("other.pem"))
			};
		} catch (_:Dynamic) {
			__cached = null;
		}

		return __cached;
	}

	/** Every file, or false at the first command that fails. **/
	private static function __make(at:String):Bool {
		function path(name:String):String {
			return haxe.io.Path.join([at, name]);
		}

		function openssl(args:Array<String>):Bool {
			return Sys.command("openssl", args) == 0;
		}

		// Line breaks as escapes: a break typed inside the literal takes the
		// checkout's line ending, which differs between Windows and CI.
		sys.io.File.saveContent(path("int.ext"), "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n");
		sys.io.File.saveContent(path("leaf.ext"),
			"subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n");
		sys.io.File.saveContent(path("client.ext"), "basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\n");

		var made:Bool = openssl([
			"req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "7", "-subj", "/CN=CrossByte Test Root",
			"-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
			"-keyout", path("root.key"), "-out", path("root.pem")
		])
			&& openssl([
				"req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=CrossByte Test Intermediate", "-keyout", path("int.key"), "-out",
				path("int.csr")
			])
			&& openssl([
				"x509", "-req", "-in", path("int.csr"), "-CA", path("root.pem"), "-CAkey", path("root.key"), "-CAcreateserial", "-days", "7",
				"-extfile", path("int.ext"), "-out", path("int.pem")
			])
			// A server certificate issued by the intermediate: what an
			// authority hands out, and what needs its chain presented.
			&& openssl([
				"req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost", "-keyout", path("leaf.key"), "-out", path("leaf.csr")
			])
			&& openssl([
				"x509", "-req", "-in", path("leaf.csr"), "-CA", path("int.pem"), "-CAkey", path("int.key"), "-CAcreateserial", "-days", "7",
				"-extfile", path("leaf.ext"), "-out", path("leaf.pem")
			])
			// One issued by the root itself, so trusting a bundle can be
			// tested apart from presenting a chain.
			&& openssl([
				"req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost", "-keyout", path("direct.key"), "-out", path("direct.csr")
			])
			&& openssl([
				"x509", "-req", "-in", path("direct.csr"), "-CA", path("root.pem"), "-CAkey", path("root.key"), "-CAcreateserial", "-days",
				"7", "-extfile", path("leaf.ext"), "-out", path("direct.pem")
			])
			&& openssl([
				"req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=crossbyte-test-client", "-keyout", path("client.key"), "-out",
				path("client.csr")
			])
			&& openssl([
				"x509", "-req", "-in", path("client.csr"), "-CA", path("root.pem"), "-CAkey", path("root.key"), "-CAcreateserial", "-days",
				"7", "-extfile", path("client.ext"), "-out", path("client.pem")
			])
			// An authority nothing here is issued by, listed first in the
			// bundle: a reader that keeps only the first entry trusts it alone.
			&& openssl([
				"req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "7", "-subj", "/CN=CrossByte Test Other CA", "-addext",
				"basicConstraints=critical,CA:TRUE", "-keyout", path("other.key"), "-out", path("other.pem")
			]);

		if (!made) {
			return false;
		}

		sys.io.File.saveContent(path("fullchain.pem"), sys.io.File.getContent(path("leaf.pem")) + sys.io.File.getContent(path("int.pem")));
		sys.io.File.saveContent(path("bundle.pem"), sys.io.File.getContent(path("other.pem")) + sys.io.File.getContent(path("root.pem")));
		sys.io.File.saveContent(path("complete"), "");
		return true;
	}

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

typedef TLSChainData = {
	var directory:String;

	/** The root authority, self-signed. **/
	var root:Certificate;

	/** A `localhost` certificate issued by the intermediate, then the intermediate. **/
	var fullChain:Certificate;

	var leafKey:Key;

	/** A `localhost` certificate issued by the root. **/
	var direct:Certificate;

	var directKey:Key;

	/** A client certificate issued by the root. **/
	var client:Certificate;

	var clientKey:Key;

	/** An unrelated authority, then the root. **/
	var bundle:Certificate;

	var other:Certificate;
}
