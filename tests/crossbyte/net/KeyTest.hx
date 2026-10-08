package crossbyte.net;

import crossbyte.net.KeyFormFixture.KeyForm;
import utest.Assert;

/**
	A private key shows nothing of itself however it is printed.

	`Key` says it is never read back out, never logged and never converted to
	a string. On Node it holds its PEM text and passphrase, and `trace(key)`,
	`Std.string`, `JSON.stringify` and `console.log` must list neither: one
	debugging line would otherwise put a server's private key, and the
	password protecting it, in its logs.
**/
class KeyTest extends utest.Test {
	#if !(js && !nodejs)
	public function testAKeyShowsNothingOfItselfWhenPrinted():Void {
		var forms = KeyFormFixture.make();
		if (forms == null) {
			// No openssl to make a key with.
			Assert.pass();
			return;
		}

		var printed:Array<{key:Key, form:KeyForm}> = [];
		for (form in forms.forms) {
			if (form.name == "rsa.pem") {
				printed.push({key: Key.fromPem(form.pem), form: form});
			}
			#if nodejs
			// Node keeps the passphrase with the key, so it is the one target
			// where printing could give it away.
			if (form.name == "rsa-pkcs8-encrypted.pem") {
				printed.push({key: Key.fromPem(form.pem, KeyFormFixture.PASSPHRASE), form: form});
			}
			#end
		}
		Assert.isTrue(printed.length > 0, "the fixture made no key to print");

		for (entry in printed) {
			var key:Key = entry.key;
			var shown:Array<String> = [Std.string(key), '$key', "" + key];
			#if nodejs
			shown.push(haxe.Json.stringify(key));
			shown.push(js.Syntax.code("JSON.stringify({0})", key));
			shown.push(js.Lib.require("util").inspect(key, {depth: 8}));
			#end

			for (text in shown) {
				__assertShowsNothing(text, entry.form);
			}
		}
	}

	/**
		Every form a key file comes in loads, with its password where it has
		one, on every target that has keys, the jvm included: not only an
		unencrypted PKCS#8, but a key encrypted, or written as PKCS#1 or SEC1,
		which is what `openssl genrsa` and `openssl ecparam -genkey` write.
		There each is checked to be the same key as the PKCS#8 one, not merely
		a key.
	**/
	public function testEveryFormOfAKeyLoads():Void {
		var forms = KeyFormFixture.make();
		if (forms == null) {
			Assert.pass();
			return;
		}

		// Every openssl writes this one; the older forms depend on which.
		var names:Array<String> = [for (form in forms.forms) form.name];
		Assert.isTrue(names.indexOf("rsa-pkcs8-encrypted.pem") >= 0, "the fixture made no encrypted key: " + names.join(", "));

		for (form in forms.forms) {
			var key:Key = null;
			try {
				key = Key.fromPem(form.pem, form.encrypted ? KeyFormFixture.PASSPHRASE : null);
			} catch (e:Dynamic) {
				Assert.fail('${form.name} did not load: $e');
				continue;
			}
			Assert.notNull(key, '${form.name} loaded as nothing');

			#if (java || jvm)
			var plain:KeyForm = KeyFormFixture.plainOf(forms, form);
			Assert.equals(__encoded(Key.fromPem(plain.pem)), __encoded(key), '${form.name} read as a different key from ${plain.name}');
			#end
		}
	}

	/**
		And an encrypted one does not load with the wrong password, or none.
		Not on Node, which decrypts a key when it is used rather than when it
		is read.
	**/
	public function testAnEncryptedKeyNeedsItsPassword():Void {
		#if nodejs
		Assert.pass();
		#else
		var forms = KeyFormFixture.make();
		if (forms == null) {
			Assert.pass();
			return;
		}

		var encrypted:Int = 0;
		for (form in forms.forms) {
			if (!form.encrypted) {
				continue;
			}
			encrypted++;
			Assert.raises(() -> Key.fromPem(form.pem, "not the passphrase"), '${form.name} loaded with the wrong password');
			Assert.raises(() -> Key.fromPem(form.pem), '${form.name} loaded with no password');
		}
		Assert.isTrue(encrypted > 0, "the fixture made no encrypted key");
		#end
	}

	#if (java || jvm)
	private static function __encoded(key:Key):String {
		return haxe.io.Bytes.ofData(@:privateAccess key.__native.native.getEncoded()).toHex();
	}
	#end

	#if nodejs
	/**
		A certificate a server presents for one name, by SNI, with a key that
		is encrypted. Node's SNI path makes the name's context with the key's
		passphrase, or every handshake asking for that name would fail, where
		the default certificate's key, given the same way, worked.
	**/
	@:timeout(15000)
	public function testAnSniKeyIsDecryptedWithItsPassphrase(async:utest.Async):Void {
		var forms = KeyFormFixture.make();
		var fallback = TLSTestFixture.selfSigned();
		var encrypted:KeyForm = null;
		if (forms != null) {
			for (form in forms.forms) {
				if (form.name == "rsa-pkcs8-encrypted.pem") {
					encrypted = form;
				}
			}
		}
		if (fallback == null || encrypted == null || forms.rsaCertificate == null) {
			Assert.pass();
			async.done();
			return;
		}

		var server = new ServerSocket(true);
		server.setCertificate(fallback.certificate, fallback.key);
		server.addSNICertificate(name -> name == KeyFormFixture.COMMON_NAME, Certificate.fromPem(forms.rsaCertificate),
			Key.fromPem(encrypted.pem, KeyFormFixture.PASSPHRASE));
		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT, function(_) {});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var presented:String = null;
			var failure:String = null;
			var client:Dynamic = null;
			client = js.node.Tls.connect(cast {
				port: server.localPort,
				host: "127.0.0.1",
				servername: KeyFormFixture.COMMON_NAME,
				rejectUnauthorized: false
			}, function() {
				var certificate:Dynamic = client.getPeerCertificate();
				presented = certificate == null || certificate.subject == null ? "" : certificate.subject.CN;
				client.destroy();
			});
			client.on("error", function(error:Dynamic) failure = Std.string(error == null ? null : error.message));

			NetPump.until(() -> presented != null || failure != null, 5.0, function(_) {
				Assert.equals(KeyFormFixture.COMMON_NAME, presented, 'the name\'s certificate was not presented: $failure');
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end

	private static function __assertShowsNothing(text:String, form:KeyForm):Void {
		// A slice of the key's own base64, from within one line of it, which
		// no printing of anything else would happen to contain.
		var lines:Array<String> = [];
		for (line in form.pem.split("-----")[2].split("\n")) {
			if (StringTools.trim(line) != "" && line.indexOf(":") < 0) {
				lines.push(StringTools.trim(line));
			}
		}
		var slice:String = lines[1].substr(8, 40);
		Assert.equals(40, slice.length, "the fixture's key has no line to take a slice of");

		Assert.isTrue(text.indexOf(slice) < 0, 'printing a ${form.name} key showed its PEM: $text');
		Assert.isTrue(text.indexOf(KeyFormFixture.PASSPHRASE) < 0, 'printing a ${form.name} key showed its passphrase: $text');
		Assert.isTrue(text.indexOf("PRIVATE KEY") < 0, 'printing a ${form.name} key showed key material: $text');
		// Shorter than any part of a key: a printing that says what it is and
		// nothing else.
		Assert.isTrue(text.length < 64, 'printing a ${form.name} key showed ${text.length} characters of it: $text');
	}
	#end
}
