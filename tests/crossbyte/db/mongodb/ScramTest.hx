package crossbyte.db.mongodb;

import crossbyte.db.mongodb._internal.SaslPrep;
import crossbyte.db.mongodb._internal.Scram;
import crossbyte.db.mongodb._internal.ScramDigest;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import haxe.io.Bytes;
import utest.Assert;

/**
	SCRAM-SHA-1 and SCRAM-SHA-256 against published vectors, on every target.

	The hashes are written here rather than taken from `haxe.crypto`, so that
	PBKDF2 runs from midstates without allocating; that makes the RFC vectors
	the only thing standing between this and a login that never works. Every
	expected value below was also checked with Python's hashlib.
**/
class ScramTest extends utest.Test {
	public function testPbkdf2MatchesRfc6070AndItsSha256Counterparts():Void {
		var sha1 = new ScramDigest(false);
		var sha256 = new ScramDigest(true);
		var password:Bytes = Bytes.ofString("password");
		var salt:Bytes = Bytes.ofString("salt");

		Assert.equals("0c60c80f961f0e71f3a9b524af6012062fe037a6", sha1.pbkdf2(password, salt, 1).toHex());
		Assert.equals("ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957", sha1.pbkdf2(password, salt, 2).toHex());
		Assert.equals("4b007901b765489abead49d926f721d065a429c1", sha1.pbkdf2(password, salt, 4096).toHex());
		Assert.equals("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", sha256.pbkdf2(password, salt, 1).toHex());
		Assert.equals("ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43", sha256.pbkdf2(password, salt, 2).toHex());
		Assert.equals("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a", sha256.pbkdf2(password, salt, 4096).toHex());

		// A salt past one block, which the first round hashes in two.
		var longPassword:Bytes = Bytes.ofString("passwordPASSWORDpassword");
		var longSalt:Bytes = Bytes.ofString("saltSALTsaltSALTsaltSALTsaltSALTsalt");
		Assert.equals("3d2eec4fe41c849b80c8d83662c0e44a8b291a96", sha1.pbkdf2(longPassword, longSalt, 4096).toHex());
		Assert.equals("348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1", sha256.pbkdf2(longPassword, longSalt, 4096).toHex());
	}

	public function testHashesAndHmacsAcrossBlockBoundaries():Void {
		var sha1 = new ScramDigest(false);
		var sha256 = new ScramDigest(true);

		Assert.equals("da39a3ee5e6b4b0d3255bfef95601890afd80709", sha1.hash(Bytes.alloc(0)).toHex());

		var a55:Bytes = Bytes.alloc(55);
		a55.fill(0, 55, "a".code);
		var a56:Bytes = Bytes.alloc(56);
		a56.fill(0, 56, "a".code);
		var a64:Bytes = Bytes.alloc(64);
		a64.fill(0, 64, "a".code);
		// 55 bytes is the most one block holds with its padding; 56 needs two.
		Assert.equals("9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318", sha256.hash(a55).toHex());
		Assert.equals("b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a", sha256.hash(a56).toHex());
		Assert.equals("ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb", sha256.hash(a64).toHex());

		var long:Bytes = Bytes.alloc(768);

		for (i in 0...768) {
			long.set(i, i & 0xFF);
		}

		Assert.equals("f3a25aa93aa2fbba28d79260535bbd6a5eb0fc1c24a8b0f04e12b484c1dfe363", sha256.hash(long).toHex());
		Assert.equals("ac2a264c8ec1f4232a40854e8239bc3a697ab1d2", sha1.hash(long).toHex());

		// RFC 4231 case 6: a key longer than a block is hashed first.
		var key:Bytes = Bytes.alloc(131);
		key.fill(0, 131, 0xAA);
		var message:Bytes = Bytes.ofString("Test Using Larger Than Block-Size Key - Hash Key First");
		Assert.equals("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", sha256.hmac(key, message).toHex());
		Assert.equals("90d0dace1c1bdc957339307803160335bde6df2b", sha1.hmac(key, message).toHex());
	}

	public function testTheRfc7677ExchangeForScramSha256():Void {
		var scram = new Scram(Scram.SHA256, "user", "pencil", "rOprNGfwEbeRWgbNEkqO");
		Assert.equals("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", scram.clientFirst().toString());

		var finalMessage:String = scram.clientFinal(Bytes.ofString("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
			.toString();
		Assert.equals("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", finalMessage);

		scram.verifyServer(Bytes.ofString("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
		Assert.pass();
	}

	public function testMongoDbsScramSha1HashesThePasswordFirst():Void {
		// MongoDB's variant: the password is MD5("user:mongo:pencil"), in hex,
		// and is not SASLprepped. The vector is the one in MongoDB's
		// authentication specification.
		var scram = new Scram(Scram.SHA1, "user", "pencil", "fyko+d2lbbFgONRv9qkxdawL");
		scram.clientFirst();
		var finalMessage:String = scram.clientFinal(Bytes.ofString("r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,s=rQ9ZY3MntBeuP3E1TDVC4w==,i=10000"))
			.toString();
		Assert.equals("c=biws,r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,p=MC2T8BvbmWRckDw8oWl5IVghwCY=", finalMessage);
		scram.verifyServer(Bytes.ofString("v=UMWeI25JD1yNYZRMpZ4VHvhZ9e0="));
		Assert.pass();
	}

	public function testAServerThatCannotSignIsRefused():Void {
		var scram = new Scram(Scram.SHA256, "user", "pencil", "rOprNGfwEbeRWgbNEkqO");
		scram.clientFirst();
		scram.clientFinal(Bytes.ofString("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"));

		// A man in the middle answering "done" without the user's keys.
		Assert.raises(() -> scram.verifyServer(Bytes.ofString("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")), IOError);
		Assert.raises(() -> scram.verifyServer(Bytes.ofString("e=other-error")), IOError);
	}

	public function testAServerFirstMessageThatWouldWeakenTheExchangeIsRefused():Void {
		// Its nonce must extend the client's, and it may not ask for fewer
		// than 4096 rounds, which would weaken the stored hash's protection.
		var cases:Array<String> = [
			"r=someoneElsesNonce,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
			"r=abc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
			"r=abcdef,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4095",
			"r=abcdef,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=lots",
			"r=abcdef,i=4096",
			"m=ext,r=abcdef,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
		];

		for (serverFirst in cases) {
			var scram = new Scram(Scram.SHA256, "user", "pencil", "abc");
			scram.clientFirst();
			Assert.raises(() -> scram.clientFinal(Bytes.ofString(serverFirst)), IOError, serverFirst);
		}
	}

	public function testNamesAreEscapedAndPasswordsPrepared():Void {
		Assert.equals("a=3Db=2Cc", Scram.escapeName("a=b,c"));
		Assert.equals("n,,n=a=3Db=2Cc,r=xyz", new Scram(Scram.SHA256, "a=b,c", "p", "xyz").clientFirst().toString());

		Assert.equals("pencil", SaslPrep.prepare("pencil").toString());
		// A no-break space is a space; a soft hyphen is nothing.
		Assert.equals("I X", SaslPrep.prepare("I ­X").toString());
		Assert.equals(Bytes.ofString("Zürich").toHex(), SaslPrep.prepare("Zürich").toHex());
		Assert.raises(() -> SaslPrep.prepare("bell\u0007"), ArgumentError);
		Assert.raises(() -> SaslPrep.prepare("private"), ArgumentError);
	}
}
