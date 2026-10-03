package crossbyte.auth.jwt._internal;

import crossbyte._internal.Utf8;
import haxe.ds.Vector;
import haxe.io.Bytes;

/**
	Base64url (RFC 4648 section 5) as JOSE writes it: no padding.

	A table each way, made once, and one loop over character codes. The JWT
	helpers built standard base64 with `haxe.crypto.Base64`, which makes a
	new `BaseCode` and its table for every call, and then swapped `+` and
	`/` with two `split`/`join`s, padded, and stripped the padding again; a
	token's verification did that three times. Decoding answers `null` for
	text that is not base64url rather than throwing, so a hostile token
	costs no exception.

	A segment is decoded from inside the token it is part of, by range, so
	the token is not split into substrings first.
**/
@:noCompletion
class Base64Url {
	@:noCompletion private static final __ALPHABET:String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

	/** The alphabet's character codes, by value. **/
	@:noCompletion private static final __ENCODE:Vector<Int> = __encodeTable();

	/**
		Each value by character code below 128, or -1. `+` and `/`, standard
		base64's spelling of 62 and 63, are in the lenient table only.
	**/
	@:noCompletion private static final __STRICT:Vector<Int> = __decodeTable(false);

	@:noCompletion private static final __LENIENT:Vector<Int> = __decodeTable(true);

	/** `bytes` as base64url, without padding. **/
	public static function encode(bytes:Bytes):String {
		var length:Int = bytes.length;
		var size:Int = encodedLength(length);
		if (size == 0) {
			return "";
		}

		#if js
		// Through the buffer decodeText uses: see there.
		var out:Bytes = __scratch;
		if (out == null || out.length < size) {
			out = __scratch = Bytes.alloc(size < 512 ? 512 : size * 2);
		}
		#else
		var out:Bytes = Bytes.alloc(size);
		#end
		var table:Vector<Int> = __ENCODE;
		var i:Int = 0;
		var o:Int = 0;

		while (length - i >= 3) {
			var n:Int = (bytes.get(i) << 16) | (bytes.get(i + 1) << 8) | bytes.get(i + 2);
			out.set(o, table[n >> 18]);
			out.set(o + 1, table[(n >> 12) & 63]);
			out.set(o + 2, table[(n >> 6) & 63]);
			out.set(o + 3, table[n & 63]);
			i += 3;
			o += 4;
		}

		switch (length - i) {
			case 1:
				var n:Int = bytes.get(i) << 16;
				out.set(o, table[n >> 18]);
				out.set(o + 1, table[(n >> 12) & 63]);
			case 2:
				var n:Int = (bytes.get(i) << 16) | (bytes.get(i + 1) << 8);
				out.set(o, table[n >> 18]);
				out.set(o + 1, table[(n >> 12) & 63]);
				out.set(o + 2, table[(n >> 6) & 63]);
			default:
		}

		return Utf8.stringOf(out, 0, size);
	}

	/** The characters `byteCount` bytes take, unpadded. **/
	public static inline function encodedLength(byteCount:Int):Int {
		return Std.int((byteCount * 4 + 2) / 3);
	}

	/**
		`text`'s characters from `start` up to `end`, decoded, or `null` when
		they are not base64.

		Lenient, as the JWT helpers have always been: standard base64's `+`
		and `/` are taken for `-` and `_`, trailing `=` padding is allowed, and
		the bits a last character carries beyond the last byte are not
		checked.
	**/
	public static function decode(text:String, start:Int, end:Int):Null<Bytes> {
		if (start < 0 || end > text.length || end < start) {
			return null;
		}
		while (end > start && StringTools.fastCodeAt(text, end - 1) == "=".code) {
			end--;
		}
		return __decode(text, start, end, __LENIENT, false);
	}

	/**
		`decode`, read as UTF-8 text: what a token's JSON segments are.

		On JavaScript the bytes go through one buffer kept for the purpose
		(JavaScript runs one thread), not a new `Bytes` per segment: an
		`ArrayBuffer` is a costly allocation there, about a third of a
		microsecond each.
	**/
	public static function decodeText(text:String, start:Int, end:Int):Null<String> {
		#if js
		if (start < 0 || end > text.length || end < start) {
			return null;
		}
		while (end > start && StringTools.fastCodeAt(text, end - 1) == "=".code) {
			end--;
		}
		var size:Int = decodedLength(end - start);
		if (size < 0) {
			return null;
		}
		var scratch:Bytes = __scratch;
		if (scratch == null || scratch.length < size) {
			scratch = __scratch = Bytes.alloc(size < 512 ? 512 : size * 2);
		}
		return __decodeInto(text, start, end, __LENIENT, false, scratch) ? Utf8.stringOf(scratch, 0, size) : null;
		#else
		var bytes:Null<Bytes> = decode(text, start, end);
		return bytes == null ? null : Utf8.stringOf(bytes, 0, bytes.length);
		#end
	}

	#if js
	@:noCompletion private static var __scratch:Null<Bytes> = null;
	#end

	/**
		`text`'s characters from `start` up to `end`, decoded, or `null` unless
		they are the one canonical base64url spelling of their bytes: the
		base64url alphabet only, no padding, and the unused low bits of a last
		partial character zero.

		For a signature, whose bytes are compared rather than its text: any
		other spelling would let one signature be written several ways.
	**/
	public static function decodeCanonical(text:String, start:Int, end:Int):Null<Bytes> {
		return __decode(text, start, end, __STRICT, true);
	}

	/** The bytes `charCount` base64url characters hold, or -1 for a count no unpadded text can have. **/
	public static inline function decodedLength(charCount:Int):Int {
		return (charCount & 3) == 1 ? -1 : (charCount >> 2) * 3 + ((charCount & 3) == 0 ? 0 : (charCount & 3) - 1);
	}

	@:noCompletion private static function __decode(text:String, start:Int, end:Int, table:Vector<Int>, canonical:Bool):Null<Bytes> {
		if (start < 0 || end > text.length || end < start) {
			return null;
		}
		var size:Int = decodedLength(end - start);
		if (size < 0) {
			return null;
		}
		var out:Bytes = Bytes.alloc(size);
		return __decodeInto(text, start, end, table, canonical, out) ? out : null;
	}

	/**
		Decodes `text` from `start` to `end`, a length `decodedLength` allows,
		into the start of `out`. False when a character is outside `table`, or
		a canonical decoding meets bits a last character should not carry.
	**/
	@:noCompletion private static function __decodeInto(text:String, start:Int, end:Int, table:Vector<Int>, canonical:Bool, out:Bytes):Bool {
		var at:Int = start;
		var o:Int = 0;
		// Every value read, OR-ed together: -1 for a character outside the
		// table makes it negative, checked once at the end.
		var bad:Int = 0;

		while (end - at >= 4) {
			var a:Int = __value(table, StringTools.fastCodeAt(text, at));
			var b:Int = __value(table, StringTools.fastCodeAt(text, at + 1));
			var c:Int = __value(table, StringTools.fastCodeAt(text, at + 2));
			var d:Int = __value(table, StringTools.fastCodeAt(text, at + 3));
			bad |= a | b | c | d;
			var n:Int = (a << 18) | (b << 12) | (c << 6) | d;
			out.set(o, (n >> 16) & 0xFF);
			out.set(o + 1, (n >> 8) & 0xFF);
			out.set(o + 2, n & 0xFF);
			at += 4;
			o += 3;
		}

		switch (end - at) {
			case 2:
				var a:Int = __value(table, StringTools.fastCodeAt(text, at));
				var b:Int = __value(table, StringTools.fastCodeAt(text, at + 1));
				bad |= a | b;
				out.set(o, ((a << 2) | (b >> 4)) & 0xFF);
				if (canonical && (b & 0x0F) != 0) {
					return false;
				}
			case 3:
				var a:Int = __value(table, StringTools.fastCodeAt(text, at));
				var b:Int = __value(table, StringTools.fastCodeAt(text, at + 1));
				var c:Int = __value(table, StringTools.fastCodeAt(text, at + 2));
				bad |= a | b | c;
				var n:Int = (a << 12) | (b << 6) | c;
				out.set(o, (n >> 10) & 0xFF);
				out.set(o + 1, (n >> 2) & 0xFF);
				if (canonical && (c & 0x03) != 0) {
					return false;
				}
			default:
		}

		return bad >= 0;
	}

	@:noCompletion private static inline function __value(table:Vector<Int>, code:Int):Int {
		return code < 128 ? table[code] : -1;
	}

	@:noCompletion private static function __encodeTable():Vector<Int> {
		var table:Vector<Int> = new Vector<Int>(64);
		for (i in 0...64) {
			table[i] = StringTools.fastCodeAt(__ALPHABET, i);
		}
		return table;
	}

	@:noCompletion private static function __decodeTable(lenient:Bool):Vector<Int> {
		var table:Vector<Int> = new Vector<Int>(128);
		for (i in 0...128) {
			table[i] = -1;
		}
		for (i in 0...64) {
			table[StringTools.fastCodeAt(__ALPHABET, i)] = i;
		}
		if (lenient) {
			table["+".code] = 62;
			table["/".code] = 63;
		}
		return table;
	}
}
