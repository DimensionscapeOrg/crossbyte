package crossbyte.crypto.password;

import crossbyte.errors.IllegalOperationError;
import haxe.io.Bytes;
import utest.Assert;

/**
	Argon2id held to fixed hashes wherever it runs: natively and on PHP
	through libsodium, on Node through `crypto.argon2` (OpenSSL's). The hashes
	below were made by Node's and checked by PHP's, so a password hashed on
	any of the three verifies on the others, and `derive` gives the same tag
	on each.
**/
class Argon2idVectorsTest extends utest.Test {
	private static inline final PASSWORD:String = "correct horse battery staple";
	private static inline final SALT:String = "crossbyte-salt16";

	/** PHC string, passes, memory in bytes, the 32-byte tag in hex. **/
	private static final VECTORS:Array<{phc:String, passes:Int, memory:Int, tag:String}> = [
		{
			phc: "$argon2id$v=19$m=8,t=1,p=1$Y3Jvc3NieXRlLXNhbHQxNg$1MXUNeaCbUKWRt8/PfRm1F7Zc72gJdHAYIdNhpXh6RY",
			passes: 1,
			memory: 8192,
			tag: "d4c5d435e6826d429646df3f3df466d45ed973bda025d1c060874d8695e1e916"
		},
		{
			phc: "$argon2id$v=19$m=64,t=3,p=1$Y3Jvc3NieXRlLXNhbHQxNg$NGxVRybd0CjwowR7sURPM5otT2NIC4CVFl05GXlWhSo",
			passes: 3,
			memory: 65536,
			tag: "346c554726ddd028f0a3047bb1444f339a2d4f63480b8095165d39197956852a"
		}
	];

	/** Two lanes, which libsodium never writes but verifies. **/
	private static inline final TWO_LANES:String = "$argon2id$v=19$m=32,t=2,p=2$Y3Jvc3NieXRlLXNhbHQxNg$2N3Z9iys1Ccw3svY0j6llFsruYg3wlnZ4lcMzHe534Y";

	/** Whether Argon2id is here: always natively and on PHP, on Node from 24.7. **/
	private static function here():Bool {
		#if (cpp || php)
		return true;
		#elseif nodejs
		return Argon2id.isSupported;
		#else
		return false;
		#end
	}

	public function testItIsSupportedWhereItShouldBe():Void {
		Assert.equals(here(), Argon2id.isSupported);
		if (here()) {
			Assert.isNull(Argon2id.unsupportedReason);
		} else {
			Assert.notNull(Argon2id.unsupportedReason);
		}
	}

	public function testTheFixedHashesVerify():Void {
		if (!here()) {
			Assert.pass();
			return;
		}
		for (vector in VECTORS) {
			Assert.isTrue(Argon2id.verify(vector.phc, PASSWORD), vector.phc);
			Assert.isFalse(Argon2id.verify(vector.phc, PASSWORD + "s"));
			Assert.isFalse(Argon2id.verify(vector.phc, ""));
		}
		Assert.isTrue(Argon2id.verify(TWO_LANES, PASSWORD));
		Assert.isFalse(Argon2id.verify(TWO_LANES, "Correct horse battery staple"));
	}

	public function testDeriveMakesTheFixedTags():Void {
		if (!here()) {
			Assert.pass();
			return;
		}
		for (vector in VECTORS) {
			var tag:Bytes = Argon2id.derive(PASSWORD, Bytes.ofString(SALT), 32, vector.passes, vector.memory);
			Assert.equals(vector.tag, tag.toHex());
		}
	}

	public function testAHashMadeHereIsTheStandardForm():Void {
		if (!here()) {
			Assert.pass();
			return;
		}
		var made:String = Argon2id.hash(PASSWORD, 1, 8192);
		Assert.isTrue(StringTools.startsWith(made, "$argon2id$v=19$m=8,t=1,p=1$"), made);
		// A 16-byte salt and a 32-byte tag, base64 without padding.
		var fields:Array<String> = made.split("$");
		Assert.equals(6, fields.length);
		Assert.equals(22, fields[4].length);
		Assert.equals(43, fields[5].length);
		Assert.isTrue(Argon2id.verify(made, PASSWORD));
		Assert.isFalse(Argon2id.verify(made, PASSWORD + "!"));
		Assert.isFalse(made == Argon2id.hash(PASSWORD, 1, 8192));
	}

	public function testNeedsRehashReadsTheCosts():Void {
		if (!here()) {
			Assert.pass();
			return;
		}
		var low:String = VECTORS[0].phc;
		var higher:String = VECTORS[1].phc;
		Assert.isFalse(Argon2id.needsRehash(low, 1, 8192));
		Assert.isTrue(Argon2id.needsRehash(low, 2, 8192));
		Assert.isTrue(Argon2id.needsRehash(low, 1, 16384));
		Assert.isFalse(Argon2id.needsRehash(higher, 3, 65536));
		Assert.isTrue(Argon2id.needsRehash(higher, 1, 8192));
		Assert.isTrue(Argon2id.needsRehash("not a phc string", 1, 8192));
		Assert.isTrue(Argon2id.needsRehash(null, 1, 8192));
	}

	public function testMalformedHashesAreRefusedNotThrownFor():Void {
		if (!here()) {
			Assert.pass();
			return;
		}
		Assert.isFalse(Argon2id.verify("not a phc string", PASSWORD));
		Assert.isFalse(Argon2id.verify(null, PASSWORD));
		Assert.isFalse(Argon2id.verify(VECTORS[0].phc, null));
		Assert.isFalse(Argon2id.verify(VECTORS[0].phc + StringTools.lpad("", "A", 200), PASSWORD));
		// The tag one character short, and the salt's last character changed.
		var phc:String = VECTORS[0].phc;
		Assert.isFalse(Argon2id.verify(phc.substr(0, phc.length - 1), PASSWORD));
		Assert.isFalse(Argon2id.verify(StringTools.replace(phc, "Y3Jvc3NieXRlLXNhbHQxNg", "Y3Jvc3NieXRlLXNhbHQxNw"), PASSWORD));
	}

	/** PHP has no threads: the async forms run in the call, and their futures are done when it returns. **/
	public function testTheAsyncFormsAreDoneOnReturnOnPhp():Void {
		#if !php
		Assert.pass();
		#else
		var verified:Null<Bool> = null;
		Argon2id.verifyAsync(VECTORS[0].phc, PASSWORD).then(value -> verified = value);
		Assert.isTrue(verified);
		var made:Null<String> = null;
		Argon2id.hashAsync(PASSWORD, 1, 8192).then(value -> made = value);
		Assert.notNull(made);
		Assert.isTrue(Argon2id.verify(made, PASSWORD));
		#end
	}

	public function testEveryMemberSaysWhyWhereItIsNotSupported():Void {
		if (here()) {
			Assert.pass();
			return;
		}
		Assert.raises(() -> Argon2id.hash(PASSWORD, 1, 8192), IllegalOperationError);
		Assert.raises(() -> Argon2id.verify(VECTORS[0].phc, PASSWORD), IllegalOperationError);
		Assert.raises(() -> Argon2id.needsRehash(VECTORS[0].phc, 1, 8192), IllegalOperationError);
		Assert.raises(() -> Argon2id.derive(PASSWORD, Bytes.ofString(SALT), 32, 1, 8192), IllegalOperationError);
	}
}
