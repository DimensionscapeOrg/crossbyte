package crossbyte.net;

import crossbyte.net.KeyFormFixture.KeyForm;
import utest.Assert;

/**
	A private key shows nothing of itself however it is printed.

	`Key` says it is never read back out, never logged and never converted to
	a string. On Node it held its PEM text and passphrase in two plain
	fields, and `trace(key)`, `Std.string`, `JSON.stringify` and
	`console.log` each listed both: one debugging line put a server's private
	key, and the password protecting it, in its logs.
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
