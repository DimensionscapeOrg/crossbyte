package crossbyte.db.mongodb._internal;

import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;

/**
	SASLprep (RFC 4013) for SCRAM-SHA-256 passwords, as UTF-8 bytes.

	A password of printable ASCII, nearly every password, is returned as
	it is, which is exactly what SASLprep makes of it. Otherwise the mapping
	step runs (the characters mapped to nothing are dropped, and non-ASCII
	spaces become a space) and the prohibited characters are refused.

	Two steps are not done, because they need Unicode tables this does not
	carry: NFKC normalisation, and the bidirectional-text check. So a
	password that NFKC would change, a compatibility character such as a
	full-width letter or a ligature, is used as typed, where the server,
	which prepared it when the user was created, used its normal form, and
	authentication fails. A password typed in the usual precomposed (NFC)
	form, `Zürich` included, is unaffected.
**/
class SaslPrep {
	/**
		The password prepared, as UTF-8.

		@throws ArgumentError When it holds a character SASLprep prohibits.
	**/
	public static function prepare(text:String):Bytes {
		if (text == null) {
			text = "";
		}

		var ascii:Bool = true;

		for (i in 0...text.length) {
			var c:Int = StringTools.fastCodeAt(text, i);

			if (c < 0x20 || c > 0x7E) {
				ascii = false;
				break;
			}
		}

		if (ascii) {
			return Bytes.ofString(text);
		}

		var out:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();

		for (code in __codePoints(text)) {
			if (__mapsToNothing(code)) {
				continue;
			}

			if (__isNonAsciiSpace(code)) {
				code = 0x20;
			}

			if (__prohibited(code)) {
				throw new ArgumentError('The password holds U+${StringTools.hex(code, 4)}, which SASLprep does not allow.');
			}

			__appendUtf8(out, code);
		}

		return out.getBytes();
	}

	/** The code points of `text`, whatever this target's strings are made of. **/
	@:noCompletion private static function __codePoints(text:String):Array<Int> {
		var out:Array<Int> = [];
		#if target.unicode
		var i:Int = 0;

		while (i < text.length) {
			var c:Int = StringTools.fastCodeAt(text, i++);

			if (c >= 0xD800 && c <= 0xDBFF && i < text.length) {
				var low:Int = StringTools.fastCodeAt(text, i);

				if (low >= 0xDC00 && low <= 0xDFFF) {
					c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
					i++;
				}
			}

			out.push(c);
		}
		#else
		// neko: the string is its UTF-8 bytes.
		var bytes:Bytes = Bytes.ofString(text);
		var i:Int = 0;

		while (i < bytes.length) {
			var b:Int = bytes.get(i);
			var extra:Int = b < 0x80 ? 0 : (b < 0xE0 ? 1 : (b < 0xF0 ? 2 : 3));
			var c:Int = extra == 0 ? b : (extra == 1 ? b & 0x1F : (extra == 2 ? b & 0x0F : b & 0x07));

			for (k in 1...extra + 1) {
				c = (c << 6) | (i + k < bytes.length ? bytes.get(i + k) & 0x3F : 0);
			}

			out.push(c);
			i += extra + 1;
		}
		#end
		return out;
	}

	@:noCompletion private static function __appendUtf8(out:haxe.io.BytesBuffer, c:Int):Void {
		if (c < 0x80) {
			out.addByte(c);
		} else if (c < 0x800) {
			out.addByte(0xC0 | (c >> 6));
			out.addByte(0x80 | (c & 0x3F));
		} else if (c < 0x10000) {
			out.addByte(0xE0 | (c >> 12));
			out.addByte(0x80 | ((c >> 6) & 0x3F));
			out.addByte(0x80 | (c & 0x3F));
		} else {
			out.addByte(0xF0 | (c >> 18));
			out.addByte(0x80 | ((c >> 12) & 0x3F));
			out.addByte(0x80 | ((c >> 6) & 0x3F));
			out.addByte(0x80 | (c & 0x3F));
		}
	}

	/** RFC 3454 table B.1. **/
	@:noCompletion private static function __mapsToNothing(c:Int):Bool {
		return c == 0x00AD || c == 0x034F || c == 0x1806 || (c >= 0x180B && c <= 0x180D) || (c >= 0x200B && c <= 0x200D) || c == 0x2060
			|| (c >= 0xFE00 && c <= 0xFE0F) || c == 0xFEFF;
	}

	/** RFC 3454 table C.1.2. **/
	@:noCompletion private static function __isNonAsciiSpace(c:Int):Bool {
		return c == 0x00A0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200B) || c == 0x202F || c == 0x205F || c == 0x3000;
	}

	/** RFC 4013 section 2.3: tables C.2.1 through C.9. **/
	@:noCompletion private static function __prohibited(c:Int):Bool {
		// C.2.1 and C.2.2: control characters.
		if (c < 0x20 || c == 0x7F || (c >= 0x80 && c <= 0x9F) || c == 0x06DD || c == 0x070F || c == 0x180E || c == 0x200C || c == 0x200D
			|| c == 0x2028 || c == 0x2029 || (c >= 0x2060 && c <= 0x2063) || (c >= 0x206A && c <= 0x206F) || c == 0xFEFF || (c >= 0xFFF9 && c <= 0xFFFC)
			|| (c >= 0x1D173 && c <= 0x1D17A)) {
			return true;
		}

		// C.3: private use.
		if ((c >= 0xE000 && c <= 0xF8FF) || (c >= 0xF0000 && c <= 0xFFFFD) || (c >= 0x100000 && c <= 0x10FFFD)) {
			return true;
		}

		// C.4: non-characters.
		if ((c >= 0xFDD0 && c <= 0xFDEF) || (c & 0xFFFE) == 0xFFFE) {
			return true;
		}

		// C.5 surrogates, C.6 inappropriate for plain text, C.7 for
		// canonical representation, C.8 changing display, C.9 tagging.
		return (c >= 0xD800 && c <= 0xDFFF) || (c >= 0xFFF9 && c <= 0xFFFD) || (c >= 0x2FF0 && c <= 0x2FFB) || c == 0x0340 || c == 0x0341
			|| c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) || c == 0xE0001 || (c >= 0xE0020 && c <= 0xE007F);
	}
}
