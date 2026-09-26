package crossbyte.crypto.password;

import haxe.io.Bytes;
import utest.Assert;

/**
 * crypt_blowfish's test vectors for keys a `String` cannot hold: bytes of 0x80 and
 * above that are not UTF-8, and the empty key.
 *
 * These pin the two places bcrypt revisions really differ. `$2x$` hashes were made
 * by crypt_blowfish's sign-extension bug and verify only when it is reproduced;
 * `$2a$` carries the countermeasure added with the fix, which moves a hash only
 * where the buggy and correct keys would collide. `$2b$` and `$2y$` are the
 * correct algorithm. PHP's `password_verify` uses crypt_blowfish, so these are
 * also the answers PHP gives.
 */
@:access(crossbyte.crypto.password.BCrypt)
class BCryptByteVectorsTest extends utest.Test {
	public function testSignExtensionBugAndCountermeasure():Void {
		expect([0xa3], "$2x$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e");
		expect([0xa3], "$2y$05$/OK.fbVrR/bpIqNJ5ianF.Sa7shbm4.OzKpvFnX1pQLmQW96oUlCq");
		expect([0xa3], "$2a$05$/OK.fbVrR/bpIqNJ5ianF.Sa7shbm4.OzKpvFnX1pQLmQW96oUlCq");
		expect([0xa3], "$2b$05$/OK.fbVrR/bpIqNJ5ianF.Sa7shbm4.OzKpvFnX1pQLmQW96oUlCq");

		// The collision the countermeasure exists for: under the bug "\xa3" and
		// "\xff\xff\xa3" expand to one key, and so does the correct algorithm for
		// the second. $2a$ alone moves off it.
		expect([0xff, 0xff, 0xa3], "$2x$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e");
		expect([0xff, 0xff, 0xa3], "$2y$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e");
		expect([0xff, 0xff, 0xa3], "$2b$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e");
		expect([0xff, 0xff, 0xa3], "$2a$05$/OK.fbVrR/bpIqNJ5ianF.nqd1wy.pTMdcvrRWxyiGL2eMz.2a85.");

		expect([0x31, 0xa3, 0x33, 0x34, 0x35], "$2x$05$/OK.fbVrR/bpIqNJ5ianF.o./n25XVfn6oAPaUvHe.Csk4zRfsYPi");
		expect([0xff, 0xa3, 0x33, 0x34, 0x35], "$2x$05$/OK.fbVrR/bpIqNJ5ianF.o./n25XVfn6oAPaUvHe.Csk4zRfsYPi");
		expect([0xff, 0xa3, 0x33, 0x34, 0xff, 0xff, 0xff, 0xa3, 0x33, 0x34, 0x35], "$2x$05$/OK.fbVrR/bpIqNJ5ianF.o./n25XVfn6oAPaUvHe.Csk4zRfsYPi");
		expect([0xff, 0xa3, 0x33, 0x34, 0xff, 0xff, 0xff, 0xa3, 0x33, 0x34, 0x35], "$2y$05$/OK.fbVrR/bpIqNJ5ianF.o./n25XVfn6oAPaUvHe.Csk4zRfsYPi");
		expect([0xff, 0xa3, 0x33, 0x34, 0xff, 0xff, 0xff, 0xa3, 0x33, 0x34, 0x35], "$2a$05$/OK.fbVrR/bpIqNJ5ianF.ZC1JEJ8Z4gPfpe1JOr/oyPXTWl9EFd.");
		expect([0xff, 0xa3, 0x33, 0x34, 0x35], "$2y$05$/OK.fbVrR/bpIqNJ5ianF.nRht2l/HRhr6zmCp9vYUvvsqynflf9e");
		expect([0xff, 0xa3, 0x33, 0x34, 0x35], "$2a$05$/OK.fbVrR/bpIqNJ5ianF.nRht2l/HRhr6zmCp9vYUvvsqynflf9e");

		// No high byte past a word's first: every revision agrees.
		expect([0xa3, 0x61, 0x62], "$2a$05$/OK.fbVrR/bpIqNJ5ianF.6IflQkJytoRVc1yuaNtHfiuq.FRlSIS");
		expect([0xa3, 0x61, 0x62], "$2x$05$/OK.fbVrR/bpIqNJ5ianF.6IflQkJytoRVc1yuaNtHfiuq.FRlSIS");
		expect([0xa3, 0x61, 0x62], "$2y$05$/OK.fbVrR/bpIqNJ5ianF.6IflQkJytoRVc1yuaNtHfiuq.FRlSIS");

		expect([0xd1, 0x91], "$2x$05$6bNw2HLQYeqHYyBfLMsv/OiwqTymGIGzFsA4hOTWebfehXHNprcAS");
		expect([0xd0, 0xc1, 0xd2, 0xcf, 0xcc, 0xd8], "$2x$05$6bNw2HLQYeqHYyBfLMsv/O9LIGgn8OMzuDoHfof8AQimSGfcSWxnS");
	}

	public function testLongAndPatternedKeys():Void {
		var tail:Array<Int> = [for (i in 0..."chars after 72 are ignored as usual".length) "chars after 72 are ignored as usual".charCodeAt(i)];
		expect(repeat([0xaa], 72).concat(tail), "$2a$05$/OK.fbVrR/bpIqNJ5ianF.swQOIzjOiJ9GHEPuhEkvqrUyvWhEMx6");
		expect(repeat([0xaa, 0x55], 36), "$2a$05$/OK.fbVrR/bpIqNJ5ianF.R9xrDjiycxMbQE2bp.vgqlYpW5wx2yy");
		expect(repeat([0x55, 0xaa, 0xff], 24), "$2a$05$/OK.fbVrR/bpIqNJ5ianF.9tQZzcJfm3uj2NvJ/n5xkhpqLrMpWCe");
	}

	public function testTheEmptyKey():Void {
		// Refused by the public API, but part of the published list.
		expect([], "$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy");
	}

	static function expect(key:Array<Int>, hash:String, ?pos:haxe.PosInfos):Void {
		var bytes:Bytes = Bytes.alloc(key.length);
		for (i in 0...key.length) {
			bytes.set(i, key[i]);
		}
		Assert.equals(hash, BCrypt.__crypt(bytes, hash, false), pos);
	}

	static function repeat(values:Array<Int>, times:Int):Array<Int> {
		var out:Array<Int> = [];
		for (i in 0...times) {
			for (value in values) {
				out.push(value);
			}
		}
		return out;
	}
}
