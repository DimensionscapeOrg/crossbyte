package crossbyte.crypto;

import crossbyte.crypto._internal.HmacSha256;
import haxe.crypto.Hmac;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import utest.Assert;

/**
	`HmacSha256`, the keyed HMAC-SHA-256 HS256 verifies tokens with: the key's
	blocks hashed once, and a message read straight from a string.

	RFC 4231's vectors, and agreement with `haxe.crypto.Hmac` at every message
	length across three blocks -- where the padding and length land in the
	last block or spill into one more -- under keys shorter than, equal to and
	longer than a block. Text that is not ASCII is hashed as its UTF-8, as
	`Bytes.ofString` encodes it. Pure Haxe, so it runs on every target: an
	`Int32Array` on JavaScript, a `Vector` elsewhere.
**/
class HmacSha256Test extends utest.Test {
	public function testRfc4231Vectors():Void {
		var key1:Bytes = Bytes.alloc(20);
		key1.fill(0, 20, 0x0b);
		Assert.equals("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
			new HmacSha256(key1).mac(Bytes.ofString("Hi There")).toHex());

		Assert.equals("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
			new HmacSha256(Bytes.ofString("Jefe")).mac(Bytes.ofString("what do ya want for nothing?")).toHex());

		// A key longer than a block is hashed first.
		var long:Bytes = Bytes.alloc(131);
		long.fill(0, 131, 0xaa);
		Assert.equals("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
			new HmacSha256(long).mac(Bytes.ofString("Test Using Larger Than Block-Size Key - Hash Key First")).toHex());
		var text:String = "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.";
		Assert.equals("9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2", new HmacSha256(long).macText(text, 0, text.length).toHex());
	}

	public function testSha256():Void {
		Assert.equals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", HmacSha256.sha256(Bytes.alloc(0)).toHex());
		Assert.equals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", HmacSha256.sha256(Bytes.ofString("abc")).toHex());
		for (length in [55, 56, 63, 64, 65, 119, 120, 128, 1000]) {
			var data:Bytes = __pattern(length);
			Assert.equals(Sha256.make(data).toHex(), HmacSha256.sha256(data).toHex(), 'length $length');
		}
	}

	public function testEveryLengthAgreesWithHaxeHmac():Void {
		var alphabet:String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.";
		for (keyLength in [1, 32, 64, 65, 100]) {
			var key:Bytes = __pattern(keyLength);
			var mac:HmacSha256 = new HmacSha256(key);
			var reference:Hmac = new Hmac(SHA256);
			var buffer:StringBuf = new StringBuf();
			// The text is read from an offset into a longer string, as a
			// token's signing input is.
			buffer.add("xx");
			for (length in 0...200) {
				var text:String = buffer.toString() + "yyy";
				var expected:Bytes = reference.make(key, Bytes.ofString(text.substring(2, 2 + length)));
				var made:Bytes = mac.macText(text, 2, 2 + length);
				if (made.toHex() != expected.toHex()) {
					Assert.fail('key $keyLength, length $length: ${made.toHex()} is not ${expected.toHex()}');
					return;
				}
				Assert.isTrue(mac.verifyText(text, 2, 2 + length, expected));
				Assert.equals(expected.toHex(), mac.mac(Bytes.ofString(text.substring(2, 2 + length))).toHex());
				buffer.addChar(StringTools.fastCodeAt(alphabet, (length * 7 + keyLength) % alphabet.length));
			}
		}
	}

	public function testTextThatIsNotAsciiIsHashedAsUtf8():Void {
		var key:Bytes = Bytes.ofString("0123456789abcdef0123456789abcdef");
		var mac:HmacSha256 = new HmacSha256(key);
		for (text in ["café", "é" + StringTools.lpad("", "a", 70), StringTools.lpad("", "b", 63) + "€", "x\u{1F600}y"]) {
			var expected:Bytes = new Hmac(SHA256).make(key, Bytes.ofString(text));
			Assert.equals(expected.toHex(), mac.macText(text, 0, text.length).toHex(), text);
			Assert.isTrue(mac.verifyText(text, 0, text.length, expected), text);
		}
	}

	public function testVerifyRefusesAnythingElse():Void {
		var mac:HmacSha256 = new HmacSha256(Bytes.ofString("secret"));
		var text:String = "header.payload";
		var good:Bytes = mac.macText(text, 0, text.length);
		Assert.isTrue(mac.verifyText(text, 0, text.length, good));

		for (i in [0, 15, 31]) {
			var bad:Bytes = good.sub(0, 32);
			bad.set(i, bad.get(i) ^ 1);
			Assert.isFalse(mac.verifyText(text, 0, text.length, bad), 'byte $i changed');
		}
		Assert.isFalse(mac.verifyText(text, 0, text.length, good.sub(0, 31)));
		Assert.isFalse(mac.verifyText(text, 0, text.length, null));
		Assert.isFalse(mac.verifyText(text, 0, text.length - 1, good));
		Assert.isFalse(new HmacSha256(Bytes.ofString("other")).verifyText(text, 0, text.length, good));
	}

	static function __pattern(length:Int):Bytes {
		var bytes:Bytes = Bytes.alloc(length);
		for (i in 0...length) {
			bytes.set(i, (i * 31 + 7) & 0xFF);
		}
		return bytes;
	}
}
