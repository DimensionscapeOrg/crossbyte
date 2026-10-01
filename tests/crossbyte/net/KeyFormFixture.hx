package crossbyte.net;

/**
	One RSA key and two EC keys, each written in every form a private key file
	comes in -- PKCS#8, PKCS#8 encrypted, and the older PKCS#1 (RSA) and SEC1
	(EC), plain and encrypted -- with a self-signed certificate for the RSA
	one, so a server can present it.

	Made at test time with the `openssl` CLI, as `TLSTestFixture` makes its
	certificates, so no key is committed; and made in a directory of its own
	that is deleted once the files are read, so none is left on disk either.
	Returns `null` when there is no `openssl` to make them. A form this
	`openssl` writes differently -- an older one writes PKCS#1 without being
	asked, LibreSSL knows no `-traditional` -- is left out rather than
	mislabelled: each is checked by its armour.
**/
class KeyFormFixture {
	/** The passphrase every encrypted form is encrypted with. **/
	public static inline var PASSPHRASE:String = "correct horse battery staple";

	/** The name the RSA key's certificate is for. **/
	public static inline var COMMON_NAME:String = "keyform.example";

	private static var __made:Null<KeyForms> = null;
	private static var __attempted:Bool = false;

	public static function make():Null<KeyForms> {
		if (__attempted) {
			return __made;
		}
		__attempted = true;

		var directory:String = haxe.io.Path.join([__tempDirectory(), "crossbyte-key-forms-" + Std.random(0x7FFFFFFF)]);
		try {
			sys.FileSystem.createDirectory(directory);
			var forms:Array<KeyForm> = [];
			var rsa:Null<String> = null;
			var certificate:Null<String> = null;

			function path(name:String):String {
				return haxe.io.Path.join([directory, name]);
			}
			function read(name:String):Null<String> {
				return sys.FileSystem.exists(path(name)) ? sys.io.File.getContent(path(name)) : null;
			}
			function run(args:Array<String>):Bool {
				return Sys.command("openssl", args) == 0;
			}
			// One form, kept only when it came out as what it is called.
			function keep(name:String, algorithm:String, encrypted:Bool, armour:String, attempts:Array<Array<String>>):Void {
				for (args in attempts) {
					if (run(args)) {
						var pem:Null<String> = read(name);
						if (pem != null && pem.indexOf(armour) >= 0 && (pem.indexOf("ENCRYPTED") >= 0) == encrypted) {
							forms.push({name: name, algorithm: algorithm, encrypted: encrypted, pem: pem});
							return;
						}
					}
				}
			}

			if (!run(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", path("rsa.pem")])) {
				return null;
			}
			rsa = read("rsa.pem");
			forms.push({name: "rsa.pem", algorithm: "RSA", encrypted: false, pem: rsa});
			keep("rsa-pkcs8-encrypted.pem", "RSA", true, "BEGIN ENCRYPTED PRIVATE KEY", [
				[
					"pkcs8", "-topk8", "-in", path("rsa.pem"), "-v2", "aes-256-cbc", "-passout", "pass:" + PASSPHRASE, "-out",
					path("rsa-pkcs8-encrypted.pem")
				]
			]);
			keep("rsa-pkcs1.pem", "RSA", false, "BEGIN RSA PRIVATE KEY", [
				["rsa", "-in", path("rsa.pem"), "-traditional", "-out", path("rsa-pkcs1.pem")],
				["rsa", "-in", path("rsa.pem"), "-out", path("rsa-pkcs1.pem")]
			]);
			keep("rsa-pkcs1-encrypted.pem", "RSA", true, "BEGIN RSA PRIVATE KEY", [
				[
					"rsa", "-in", path("rsa.pem"), "-traditional", "-aes128", "-passout", "pass:" + PASSPHRASE, "-out",
					path("rsa-pkcs1-encrypted.pem")
				],
				["rsa", "-in", path("rsa.pem"), "-aes128", "-passout", "pass:" + PASSPHRASE, "-out", path("rsa-pkcs1-encrypted.pem")]
			]);
			if (run([
				"req", "-x509", "-key", path("rsa.pem"), "-days", "1", "-subj", "/CN=" + COMMON_NAME, "-out", path("rsa-cert.pem")
			])) {
				certificate = read("rsa-cert.pem");
			}

			for (curve in ["P-256", "P-384"]) {
				var ec:String = "ec-" + curve;
				if (!run(["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:" + curve, "-out", path(ec + ".pem")])) {
					continue;
				}
				forms.push({name: ec + ".pem", algorithm: "EC", encrypted: false, pem: read(ec + ".pem")});
				keep(ec + "-pkcs8-encrypted.pem", "EC", true, "BEGIN ENCRYPTED PRIVATE KEY", [
					[
						"pkcs8", "-topk8", "-in", path(ec + ".pem"), "-v2", "aes-256-cbc", "-passout", "pass:" + PASSPHRASE, "-out",
						path(ec + "-pkcs8-encrypted.pem")
					]
				]);
				keep(ec + "-sec1.pem", "EC", false, "BEGIN EC PRIVATE KEY", [["ec", "-in", path(ec + ".pem"), "-out", path(ec + "-sec1.pem")]]);
				keep(ec + "-sec1-encrypted.pem", "EC", true, "BEGIN EC PRIVATE KEY", [
					[
						"ec", "-in", path(ec + ".pem"), "-aes128", "-passout", "pass:" + PASSPHRASE, "-out",
						path(ec + "-sec1-encrypted.pem")
					]
				]);
			}

			__made = {forms: forms, rsaCertificate: certificate};
		} catch (_:Dynamic) {
			__made = null;
		}
		__removeQuietly(directory);

		return __made;
	}

	/** The plain PKCS#8 form `form` is another writing of. **/
	public static function plainOf(forms:KeyForms, form:KeyForm):KeyForm {
		var base:String = form.name.split("-pkcs")[0].split("-sec1")[0];
		if (!StringTools.endsWith(base, ".pem")) {
			base += ".pem";
		}
		for (candidate in forms.forms) {
			if (candidate.name == base) {
				return candidate;
			}
		}
		return null;
	}

	private static function __removeQuietly(directory:String):Void {
		try {
			if (sys.FileSystem.exists(directory)) {
				for (entry in sys.FileSystem.readDirectory(directory)) {
					sys.FileSystem.deleteFile(haxe.io.Path.join([directory, entry]));
				}
				sys.FileSystem.deleteDirectory(directory);
			}
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

typedef KeyForm = {
	/** The file it was written to, which says its form: `rsa-pkcs1-encrypted.pem`. **/
	var name:String;

	/** `RSA` or `EC`. **/
	var algorithm:String;

	/** Whether it needs `KeyFormFixture.PASSPHRASE`. **/
	var encrypted:Bool;

	var pem:String;
}

typedef KeyForms = {
	var forms:Array<KeyForm>;

	/** A certificate for the RSA key, for `KeyFormFixture.COMMON_NAME`; null if `openssl` would not make one. **/
	var rsaCertificate:Null<String>;
}
