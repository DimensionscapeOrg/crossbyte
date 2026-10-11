package crossbyte._internal;

import haxe.io.Bytes;

/**
	UTF-8 to and from strings, through the platform's own encoder and decoder
	where Haxe's are slow.

	Haxe's `Bytes.ofString` for JavaScript walks the string a character at a
	time, pushing each byte onto an Array, and then copies the Array into a
	Uint8Array, which is slow for a large string. `TextEncoder` is native on
	Node and in every browser, and writes the same bytes for any string that
	is valid UTF-16. An unpaired surrogate becomes U+FFFD, where Haxe's
	encoder takes the next character into it, or writes bytes UTF-8 does not
	allow.

	Its `getString` adds to a string a character at a time, and stops at the
	first NUL byte, which no other target does. `TextDecoder` reads every
	byte, NUL included; it keeps a leading byte order mark as U+FEFF, as the
	other targets do, and reads a malformed sequence as U+FFFD.

	Elsewhere the platform's own are used where they are right, and the
	difference made up where they are not. An unpaired surrogate is written
	as U+FFFD natively, where hxcpp's encoder threw on one. On HashLink one
	at the end of a string is too: there its encoder ran past the end and
	crashed the process. One elsewhere in a string HashLink writes as bytes
	UTF-8 does not allow (it does not crash), as the jvm writes `?`; finding
	those would cost every string written a pass over it. A malformed
	sequence reads as U+FFFD on HashLink and eval too:
	HashLink's decoder dropped everything from the first bad byte, and eval
	kept the bytes as they were, which the next operation on the string then
	aborted the process over. Natively hxcpp decodes leniently (a stray
	continuation byte takes the next byte with it, an overlong form is
	accepted), and the jvm writes an unpaired surrogate as `?`: neither
	crashes, and neither is checked for, as that would cost every string.
**/
@:noCompletion
class Utf8 {
	public static inline function bytesOf(value:String):Bytes {
		#if js
		return __encode(value);
		#elseif cpp
		return Bytes.ofString(wellFormed(value));
		#elseif hl
		return Bytes.ofString(__endsWhole(value) ? value : wellFormed(value));
		#else
		return Bytes.ofString(value);
		#end
	}

	#if hl
	// Whether the last unit is anything but the high half of a pair, which
	// HashLink's encoder runs past the end of the string looking for the low
	// half of: one comparison, and the only one of these that crashes.
	static inline function __endsWhole(value:String):Bool {
		var length:Int = value.length;
		if (length == 0) {
			return true;
		}
		var last:Int = StringTools.fastCodeAt(value, length - 1);
		return last < 0xD800 || last >= 0xDC00;
	}
	#end

	#if (hl || cpp)
	/**
		`value` with each surrogate that is not half of a pair replaced by
		U+FFFD, as `TextEncoder` writes it: `value` itself when it has none,
		which is nearly always, found in one pass over it. Natively a string
		held a byte a character holds no surrogate, and is not looked at.
	**/
	public static function wellFormed(value:String):String {
		#if cpp
		if (!untyped __cpp__("{0}.isUTF16Encoded()", value)) {
			return value;
		}
		#end
		var length:Int = value.length;
		var i:Int = 0;
		while (i < length) {
			var unit:Int = StringTools.fastCodeAt(value, i);
			if (unit >= 0xD800 && unit < 0xE000) {
				if (unit < 0xDC00 && i + 1 < length) {
					var low:Int = StringTools.fastCodeAt(value, i + 1);
					if (low >= 0xDC00 && low < 0xE000) {
						i += 2;
						continue;
					}
				}
				return __replaceLoneSurrogates(value, i);
			}
			i++;
		}
		return value;
	}

	static function __replaceLoneSurrogates(value:String, from:Int):String {
		var out:StringBuf = new StringBuf();
		out.addSub(value, 0, from);
		var length:Int = value.length;
		var i:Int = from;
		while (i < length) {
			var unit:Int = StringTools.fastCodeAt(value, i);
			if (unit >= 0xD800 && unit < 0xE000) {
				if (unit < 0xDC00 && i + 1 < length) {
					var low:Int = StringTools.fastCodeAt(value, i + 1);
					if (low >= 0xDC00 && low < 0xE000) {
						out.addSub(value, i, 2);
						i += 2;
						continue;
					}
				}
				out.addChar(0xFFFD);
			} else {
				out.addChar(unit);
			}
			i++;
		}
		return out.toString();
	}
	#end

	/**
		`len` bytes of `bytes` from `pos`, as UTF-8; `Bytes.getString` elsewhere.

		`strict` makes a malformed sequence throw on JavaScript rather than read
		as U+FFFD, for a caller that reports bytes that are not text.
	**/
	public static inline function stringOf(bytes:Bytes, pos:Int, len:Int, strict:Bool = false):String {
		#if js
		return __decode(bytes, pos, len, strict);
		#elseif hl
		return __decodeHl(bytes, pos, len, strict);
		#elseif eval
		return __decodeChecked(bytes, pos, len, strict);
		#else
		return bytes.getString(pos, len);
		#end
	}

	#if hl
	/**
		UTF-8 to a string in one pass, ASCII four bytes at a time, straight
		into the string's own storage. HashLink's `getString` copies the
		bytes, measures them and decodes them in two more passes; it stops at
		a NUL and drops everything from a malformed byte on. This reads a NUL
		as a character, a malformed sequence as U+FFFD, and is faster than
		`getString` was even for ASCII (205 ns rather than 246 for 12 bytes,
		1,053 rather than 1,197 for 200, under the JIT).
	**/
	static function __decodeHl(bytes:Bytes, pos:Int, len:Int, strict:Bool):String {
		// As getString refuses it, before anything is read.
		if (pos < 0 || len < 0 || len > bytes.length - pos) {
			throw haxe.io.Error.OutsideBounds;
		}
		var data:hl.Bytes = @:privateAccess bytes.b;
		// No more UTF-16 units than bytes: a four-byte sequence is two.
		var out:hl.Bytes = new hl.Bytes((len + 1) << 1);
		var units:Int = 0;
		var i:Int = pos;
		var end:Int = pos + len;
		while (i < end) {
			while (i <= end - 4) {
				var word:Int = data.getI32(i);
				if ((word & 0x80808080) != 0) {
					break;
				}
				out.setI32(units << 1, (word & 0xFF) | ((word & 0xFF00) << 8));
				out.setI32((units << 1) + 4, ((word >>> 16) & 0xFF) | ((word >>> 8) & 0xFF0000));
				units += 4;
				i += 4;
			}
			if (i >= end) {
				break;
			}
			var lead:Int = data[i];
			if (lead < 0x80) {
				out.setUI16(units << 1, lead);
				units++;
				i++;
				continue;
			}
			var need:Int = 0;
			var code:Int = 0;
			var low:Int = 0x80;
			var high:Int = 0xBF;
			if (lead >= 0xC2 && lead <= 0xDF) {
				need = 1;
				code = lead & 0x1F;
			} else if (lead >= 0xE0 && lead <= 0xEF) {
				need = 2;
				code = lead & 0x0F;
				if (lead == 0xE0) {
					low = 0xA0;
				} else if (lead == 0xED) {
					high = 0x9F;
				}
			} else if (lead >= 0xF0 && lead <= 0xF4) {
				need = 3;
				code = lead & 0x07;
				if (lead == 0xF0) {
					low = 0x90;
				} else if (lead == 0xF4) {
					high = 0x8F;
				}
			}
			var next:Int = i + 1;
			var whole:Bool = need > 0;
			for (_ in 0...need) {
				if (next >= end) {
					whole = false;
					break;
				}
				var byte:Int = data[next];
				if (byte < low || byte > high) {
					whole = false;
					break;
				}
				low = 0x80;
				high = 0xBF;
				code = (code << 6) | (byte & 0x3F);
				next++;
			}
			if (!whole) {
				if (strict) {
					throw "The bytes are not UTF-8: a malformed sequence at " + (i - pos) + ".";
				}
				code = 0xFFFD;
			}
			if (code >= 0x10000) {
				code -= 0x10000;
				out.setUI16(units << 1, 0xD800 | (code >> 10));
				out.setUI16((units + 1) << 1, 0xDC00 | (code & 0x3FF));
				units += 2;
			} else {
				out.setUI16(units << 1, code);
				units++;
			}
			i = next;
		}
		out.setUI16(units << 1, 0);
		return @:privateAccess String.__alloc__(out, units);
	}
	#end

	#if eval
	/**
		The platform's `getString` for well-formed UTF-8 with no NUL in it,
		which is nearly all of it, found in one pass; the rest decoded here.
		HashLink's `getString` stops at a NUL and drops everything from a bad
		byte on, and eval's keeps a bad byte as it is, which the next
		operation on the string aborts the process over.
	**/
	static function __decodeChecked(bytes:Bytes, pos:Int, len:Int, strict:Bool):String {
		// As getString refuses it, before anything is read.
		if (pos < 0 || len < 0 || len > bytes.length - pos) {
			throw haxe.io.Error.OutsideBounds;
		}
		if (__plain(bytes, pos, pos + len)) {
			return bytes.getString(pos, len);
		}
		return __decodeReplacing(bytes, pos, len, strict);
	}

	/**
		Whether `[pos, end)` is well-formed UTF-8 with no NUL: the bounds of
		each byte after a lead are Unicode's table 3-7, which leave out
		overlong forms, surrogates and anything past U+10FFFF.
	**/
	static function __plain(bytes:Bytes, pos:Int, end:Int):Bool {
		var i:Int = pos;
		while (i < end) {
			var lead:Int = bytes.get(i);
			if (lead < 0x80) {
				if (lead == 0) {
					return false;
				}
				i++;
				continue;
			}
			var need:Int;
			var low:Int = 0x80;
			var high:Int = 0xBF;
			if (lead >= 0xC2 && lead <= 0xDF) {
				need = 1;
			} else if (lead >= 0xE0 && lead <= 0xEF) {
				need = 2;
				if (lead == 0xE0) {
					low = 0xA0;
				} else if (lead == 0xED) {
					high = 0x9F;
				}
			} else if (lead >= 0xF0 && lead <= 0xF4) {
				need = 3;
				if (lead == 0xF0) {
					low = 0x90;
				} else if (lead == 0xF4) {
					high = 0x8F;
				}
			} else {
				return false;
			}
			if (need > end - i - 1) {
				return false;
			}
			for (k in 1...need + 1) {
				var next:Int = bytes.get(i + k);
				if (next < low || next > high) {
					return false;
				}
				low = 0x80;
				high = 0xBF;
			}
			i += need + 1;
		}
		return true;
	}

	/**
		UTF-8 decoded as the Encoding Standard decodes it: each maximal
		subpart of a malformed sequence is one U+FFFD (or, `strict`, an
		error), and a NUL is a character like any other.
	**/
	static function __decodeReplacing(bytes:Bytes, pos:Int, len:Int, strict:Bool):String {
		var out:StringBuf = new StringBuf();
		var i:Int = pos;
		var end:Int = pos + len;
		while (i < end) {
			var lead:Int = bytes.get(i);
			if (lead < 0x80) {
				out.addChar(lead);
				i++;
				continue;
			}
			var need:Int = 0;
			var code:Int = 0;
			var low:Int = 0x80;
			var high:Int = 0xBF;
			if (lead >= 0xC2 && lead <= 0xDF) {
				need = 1;
				code = lead & 0x1F;
			} else if (lead >= 0xE0 && lead <= 0xEF) {
				need = 2;
				code = lead & 0x0F;
				if (lead == 0xE0) {
					low = 0xA0;
				} else if (lead == 0xED) {
					high = 0x9F;
				}
			} else if (lead >= 0xF0 && lead <= 0xF4) {
				need = 3;
				code = lead & 0x07;
				if (lead == 0xF0) {
					low = 0x90;
				} else if (lead == 0xF4) {
					high = 0x8F;
				}
			}
			var next:Int = i + 1;
			var whole:Bool = need > 0;
			for (_ in 0...need) {
				if (next >= end) {
					whole = false;
					break;
				}
				var byte:Int = bytes.get(next);
				if (byte < low || byte > high) {
					whole = false;
					break;
				}
				low = 0x80;
				high = 0xBF;
				code = (code << 6) | (byte & 0x3F);
				next++;
			}
			if (whole) {
				out.addChar(code);
			} else if (strict) {
				throw "The bytes are not UTF-8: a malformed sequence at " + (i - pos) + ".";
			} else {
				out.addChar(0xFFFD);
			}
			i = next;
		}
		return out.toString();
	}
	#end


	#if js
	static var __encoder:Dynamic = null;
	static var __decoder:Dynamic = null;
	static var __strictDecoder:Dynamic = null;

	static function __encode(value:String):Bytes {
		// A short string here: TextEncoder costs a call into the platform and
		// a buffer of its own however short the text, several times what a
		// string of a few dozen characters takes. Written as TextEncoder
		// writes it, an unpaired surrogate as U+FFFD.
		var length:Int = value.length;
		if (length <= SHORT) {
			var size:Int = 0;
			var i:Int = 0;
			while (i < length) {
				var unit:Int = StringTools.fastCodeAt(value, i++);
				if (unit < 0x80) {
					size++;
				} else if (unit < 0x800) {
					size += 2;
				} else if (unit >= 0xD800 && unit < 0xDC00 && i < length && StringTools.fastCodeAt(value, i) >= 0xDC00 && StringTools.fastCodeAt(value, i) < 0xE000) {
					size += 4;
					i++;
				} else {
					size += 3;
				}
			}
			var bytes:Bytes = Bytes.alloc(size);
			var at:Int = 0;
			i = 0;
			while (i < length) {
				var code:Int = StringTools.fastCodeAt(value, i++);
				if (code < 0x80) {
					bytes.set(at++, code);
					continue;
				}
				if (code >= 0xD800 && code < 0xE000) {
					var low:Int = i < length ? StringTools.fastCodeAt(value, i) : 0;
					if (code < 0xDC00 && low >= 0xDC00 && low < 0xE000) {
						code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
						i++;
					} else {
						code = 0xFFFD;
					}
				}
				if (code < 0x800) {
					bytes.set(at++, 0xC0 | (code >> 6));
				} else if (code < 0x10000) {
					bytes.set(at++, 0xE0 | (code >> 12));
					bytes.set(at++, 0x80 | ((code >> 6) & 0x3F));
				} else {
					bytes.set(at++, 0xF0 | (code >> 18));
					bytes.set(at++, 0x80 | ((code >> 12) & 0x3F));
					bytes.set(at++, 0x80 | ((code >> 6) & 0x3F));
				}
				bytes.set(at++, 0x80 | (code & 0x3F));
			}
			return bytes;
		}
		if (__encoder == null) {
			__encoder = js.Syntax.code("new TextEncoder()");
		}
		var view:js.lib.Uint8Array = __encoder.encode(value);
		// Its own buffer, exactly its length, is what TextEncoder makes, and
		// Bytes takes a whole buffer; anything else is copied into one.
		var buffer:js.lib.ArrayBuffer = view.byteOffset == 0 && view.buffer.byteLength == view.length ? view.buffer : view.slice().buffer;
		return Bytes.ofData(buffer);
	}

	static function __decode(bytes:Bytes, pos:Int, len:Int, strict:Bool):String {
		// As getString refuses it.
		if (pos < 0 || len < 0 || pos + len > bytes.length) {
			throw haxe.io.Error.OutsideBounds;
		}
		var decoder:Dynamic;
		if (strict) {
			if (__strictDecoder == null) {
				__strictDecoder = js.Syntax.code("new TextDecoder('utf-8', {ignoreBOM: true, fatal: true})");
			}
			decoder = __strictDecoder;
		} else {
			if (__decoder == null) {
				__decoder = js.Syntax.code("new TextDecoder('utf-8', {ignoreBOM: true})");
			}
			decoder = __decoder;
		}
		// A view of the bytes' own view, wherever that sits in its buffer.
		var view:js.lib.Uint8Array = @:privateAccess bytes.b;
		// Every length by the platform's decoder: a loop building the string
		// here beat it only in isolation, and lost to it in a ByteArray read.
		return decoder.decode(view.subarray(pos, pos + len));
	}


	// Below this many characters text is encoded here rather than by the
	// platform's encoder, which costs a call into the platform and a buffer
	// of its own however short the text.
	static inline var SHORT:Int = 64;
	#end
}
