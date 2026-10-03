package crossbyte.auth.jwt;

import crossbyte.auth.jwt._internal.Base64Url;
import haxe.crypto.Base64;
import haxe.io.Bytes;
import utest.Assert;

/**
	The base64url codec the JWT helpers share: unpadded output identical to
	`haxe.crypto.Base64.urlEncode`, decoding by range inside a longer string,
	`null` for anything that is not base64 rather than a throw, and a
	canonical decoding for signatures that accepts one spelling of their
	bytes and no other.
**/
class Base64UrlTest extends utest.Test {
	public function testEveryLengthRoundTrips():Void {
		for (length in 0...100) {
			var bytes:Bytes = Bytes.alloc(length);
			for (i in 0...length) {
				bytes.set(i, (i * 151 + length * 7) & 0xFF);
			}
			var encoded:String = Base64Url.encode(bytes);
			Assert.equals(Base64.urlEncode(bytes), encoded, 'length $length');
			Assert.equals(Base64Url.encodedLength(length), encoded.length);
			Assert.equals(length, Base64Url.decodedLength(encoded.length));

			// Decoded from inside a longer string, as a token's segment is.
			var token:String = "ab." + encoded + ".cd";
			var plain:Null<Bytes> = Base64Url.decode(token, 3, 3 + encoded.length);
			var canonical:Null<Bytes> = Base64Url.decodeCanonical(token, 3, 3 + encoded.length);
			if (plain == null || canonical == null) {
				Assert.fail('length $length did not decode');
				return;
			}
			Assert.equals(bytes.toHex(), plain.toHex());
			Assert.equals(bytes.toHex(), canonical.toHex());
		}
	}

	public function testTextIsDecodedAsUtf8AtAnySize():Void {
		// Small and large in turn: on JavaScript the bytes go through one
		// buffer, grown when a segment needs more.
		for (text in ["", "{}", '{"name":"café € \u{1F600}"}', StringTools.lpad("", "x", 3000), '{"a":1}', StringTools.lpad("", "é", 700)]) {
			var encoded:String = Base64Url.encode(haxe.io.Bytes.ofString(text));
			Assert.equals(text, Base64Url.decodeText("." + encoded + ".", 1, 1 + encoded.length));
		}
		Assert.isNull(Base64Url.decodeText("a!cd", 0, 4));
		Assert.isNull(Base64Url.decodeText("abcde", 0, 5));
		Assert.equals("M", Base64Url.decodeText("TQ==", 0, 4));
	}

	public function testWhatIsNotBase64IsNull():Void {
		for (text in ["a", "abcde", "ab!d", "ab d", "ab=d", "ébcd", "abcĀ"]) {
			Assert.isNull(Base64Url.decode(text, 0, text.length), text);
			Assert.isNull(Base64Url.decodeCanonical(text, 0, text.length), text);
		}
		Assert.isNull(Base64Url.decode("abcd", 2, 1));
		Assert.isNull(Base64Url.decode("abcd", 0, 5));
	}

	public function testTheLenientDecodingTakesWhatTheHelpersAlwaysTook():Void {
		// Standard base64's alphabet, padding, and stray low bits.
		Assert.equals(Bytes.ofHex("fbff").toHex(), Base64Url.decode("-_8", 0, 3).toHex());
		Assert.equals(Bytes.ofHex("fbff").toHex(), Base64Url.decode("+/8", 0, 3).toHex());
		Assert.equals("4d", Base64Url.decode("TQ==", 0, 4).toHex());
		Assert.equals("4d", Base64Url.decode("TR", 0, 2).toHex());
	}

	public function testTheCanonicalDecodingTakesOneSpellingOnly():Void {
		Assert.equals("4d", Base64Url.decodeCanonical("TQ", 0, 2).toHex());
		// The bits past the last byte must be zero: TR, TS ... are TQ again.
		Assert.isNull(Base64Url.decodeCanonical("TR", 0, 2));
		Assert.isNull(Base64Url.decodeCanonical("TQ==", 0, 4));
		Assert.isNull(Base64Url.decodeCanonical("+/8", 0, 3));
		Assert.equals("fbff", Base64Url.decodeCanonical("-_8", 0, 3).toHex());
		Assert.isNull(Base64Url.decodeCanonical("-_9", 0, 3));
	}
}
