package crossbyte.crypto.password;

import crossbyte.crypto.SecureRandom;
import crossbyte.utils.IntParse;
import utest.Assert;

/**
 * BCrypt against hashes other implementations published, through the public API
 * only, so it runs everywhere BCrypt compiles.
 *
 * Every revision adds the key's terminating NUL, as other implementations
 * do. Without it PHP's own example hash would not verify, no hash migrated
 * from PHP, Node or Python would, and a password would match its
 * repetitions: without the NUL a key is its bytes cycled to 72, and "abc"
 * cycled is "abcabc" cycled.
 *
 * For ASCII passwords the three revisions are one algorithm, so the same
 * salt and digest are checked under `$2a$`, `$2b$` and `$2y$`.
 */
class BCryptVectorsTest extends utest.Test {
	/**
	 * The hash PHP's manual shows for `password_verify`, made by `password_hash`.
	 */
	static inline final PHP_MANUAL_HASH:String = "$2y$10$.vGA1O9wmRjrwAVXD98HNOgsNpDczlqm3Jq7KnEd1rVAGv3Fykk1a";

	/**
	 * A standard `$2b$` hash of "abc". The same salt and digest under `$2a$`
	 * verify too, since for ASCII the revisions agree.
	 */
	static inline final STANDARD_ABC:String = "$2b$04$abcdefghijklmnopqrstuuCi15uRb1eH7NAlJ/TgeJertyknQpYn2";

	public function testThePhpManualHashVerifies():Void {
		Assert.isTrue(BCrypt.verify("rasmuslerdorf", PHP_MANUAL_HASH));
		Assert.isFalse(BCrypt.verify("rasmuslerdorf2", PHP_MANUAL_HASH));
	}

	public function testJBCryptVectorsVerifyUnderEveryRevision():Void {
		// jBCrypt's TestBCrypt vectors, at the cheapest cost it publishes.
		var vectors:Array<Array<String>> = [
			["a", "$06$m0CrhHm10qJ3lXRY.5zDGO3rS2KdeeWLuGmsfGlMfOxih58VYVfxe"],
			["abc", "$06$If6bvum7DFjUnE9p2uDeDu0YHzrHM6tf.iqN8.yx.jNN1ILEf7h0i"],
			["abcdefghijklmnopqrstuvwxyz", "$06$.rCVZVOThsIa97pEDOxvGuRRgzG64bvtJ0938xuqzv18d3ZpQhstC"],
			["~!@#$%^&*()      ~!@#$%^&*()PNBFRD", "$06$fPIsBO8qRqkjj273rfaOI.HtSV9jLDpTbZn782DC6/t7qT67P6FfO"]
		];

		for (vector in vectors) {
			for (revision in ["$2a", "$2b", "$2y"]) {
				Assert.isTrue(BCrypt.verify(vector[0], revision + vector[1]), revision + ' "' + vector[0] + '"');
			}
		}
	}

	public function testOpenwallVectorsVerify():Void {
		// crypt_blowfish's own test list (the ASCII entries).
		Assert.isTrue(BCrypt.verify("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"));
		Assert.isTrue(BCrypt.verify("U*U*", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK"));
		Assert.isTrue(BCrypt.verify("U*U*U", "$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a"));
		Assert.isTrue(BCrypt.verify("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored",
			"$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui"));

		Assert.isTrue(BCrypt.verify("U*U", "$2b$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"));
		Assert.isTrue(BCrypt.verify("U*U", "$2y$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"));

		// Only the first 72 bytes count, in every implementation.
		Assert.isTrue(BCrypt.verify("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
			"$2b$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui"));

		// "ё" is UTF-8 d1 91: a $2x$ hash, made by crypt_blowfish's emulation of
		// its own sign-extension bug, which only differs for bytes of 0x80 and up.
		Assert.isTrue(BCrypt.verify("ё", "$2x$05$6bNw2HLQYeqHYyBfLMsv/OiwqTymGIGzFsA4hOTWebfehXHNprcAS"));
	}

	public function testAPasswordNoLongerMatchesItsRepetitions():Void {
		Assert.isTrue(BCrypt.verify("abc", STANDARD_ABC));
		Assert.isFalse(BCrypt.verify("abcabc", STANDARD_ABC));
		Assert.isFalse(BCrypt.verify("abcabcabcabc", STANDARD_ABC));

		// Hashes made here, where the target has a CSPRNG to salt them with.
		if (!SecureRandom.isSupported) {
			return;
		}

		var fresh:String = BCrypt.hash("abc", 4);
		Assert.isTrue(BCrypt.verify("abc", fresh));
		Assert.isFalse(BCrypt.verify("abcabc", fresh));

		var doubled:String = BCrypt.hash("passwordpassword", 4);
		Assert.isFalse(BCrypt.verify("password", doubled));
	}

	public function testNewHashesAreStandard2b():Void {
		Assert.isFalse(BCrypt.needsRehash(STANDARD_ABC, 4));

		if (!SecureRandom.isSupported) {
			return;
		}

		var fresh:String = BCrypt.hash("hunter2", 4);
		Assert.equals("$2b$04$", fresh.substr(0, 7));
		Assert.equals(60, fresh.length);
		Assert.isFalse(BCrypt.needsRehash(fresh, 4));
	}

	public function testHashesStoredByEarlierVersionsStillVerifyAndAreFlagged():Void {
		// Made by earlier CrossByte versions, with fixed salts: $2y$ with no NUL.
		var legacy:Array<Array<String>> = [
			["hunter2", "$2y$04$abcdefghijklmnopqrstuuiqVPeB7rAfCVQFsJUoJo2j6yvsFNMju"],
			["abc", "$2y$05$CCCCCCCCCCCCCCCCCCCCC./N9VzPL1A6H8IWDNBlsxsyhL7PbpEui"],
			["correct horse battery staple", "$2y$06$/OK.fbVrR/bpIqNJ5ianF.NfwBeZEBQpjgzShuiPppGZmQKJFmq4G"]
		];

		for (entry in legacy) {
			Assert.isTrue(BCrypt.verify(entry[0], entry[1]), 'stored "' + entry[0] + '" still signs in');
			Assert.isFalse(BCrypt.verify(entry[0] + "x", entry[1]));
			// Flagged whatever the cost, so rehashing on login retires it.
			Assert.isTrue(BCrypt.needsRehash(entry[1], IntParse.decimal(entry[1].substr(4, 2))));
		}

		// Only $2y$ has the fallback: CrossByte never produced any other revision,
		// so the old form of a $2b$ hash exists nowhere and is not tried.
		Assert.isFalse(BCrypt.verify("hunter2", "$2b$04$abcdefghijklmnopqrstuuiqVPeB7rAfCVQFsJUoJo2j6yvsFNMju"));
	}

	public function testNeedsRehashFlagsEveryRevisionButTheDefault():Void {
		var digest:String = "04$abcdefghijklmnopqrstuuCi15uRb1eH7NAlJ/TgeJertyknQpYn2";
		Assert.isFalse(BCrypt.needsRehash("$2b$" + digest, 4));
		Assert.isTrue(BCrypt.needsRehash("$2b$" + digest, 5));
		Assert.isTrue(BCrypt.needsRehash("$2y$" + digest, 4));
		Assert.isTrue(BCrypt.needsRehash("$2a$" + digest, 4));
		Assert.isTrue(BCrypt.needsRehash("$2x$" + digest, 4));
		Assert.isTrue(BCrypt.needsRehash(("$2b$" + digest).substr(0, 59), 4));
		Assert.isTrue(BCrypt.needsRehash("$2b$+4$abcdefghijklmnopqrstuuCi15uRb1eH7NAlJ/TgeJertyknQpYn2", 4));
	}

	public function testMalformedHashesAreRefusedWithoutThrowing():Void {
		var body:String = "abcdefghijklmnopqrstuuCi15uRb1eH7NAlJ/TgeJertyknQpYn2";
		for (bad in [
			"$2z$04$" + body, // unknown revision
			"$2b$03$" + body, // cost below 4
			"$2b$99$" + body, // cost above 31
			"$2b$+4$" + body, // not digits
			"$2b$04#" + body, // separator
			"$2b$04$abcdefghijklmnopqrstu!Ci15uRb1eH7NAlJ/TgeJertyknQpYn2", // outside the alphabet
			"$2b$04$abc", // truncated
			"", "$", "$2", "$2b$"
		]) {
			Assert.isFalse(BCrypt.verify("abc", bad), bad);
		}
		Assert.isFalse(BCrypt.verify("abc", null));
	}
}
