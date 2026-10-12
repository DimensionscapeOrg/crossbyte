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
	as U+FFFD natively, where hxcpp's encoder threw on one. On HashLink a
	ByteArray writes text from the string's own units (encodeUnits), and
	one is U+FFFD there too. Through `bytesOf` one at the end of a string is
	(HashLink's encoder ran past the end and crashed the process), but one
	elsewhere HashLink's encoder takes the character after it into it;
	finding those would cost every string a pass. A malformed sequence
	reads as U+FFFD on HashLink and eval too:
	HashLink's decoder dropped everything from the first bad byte, and eval
	kept the bytes as they were, which the next operation on the string then
	aborted the process over. Natively hxcpp decodes leniently (a stray
	continuation byte takes the next byte with it, an overlong form is
	accepted), and the jvm writes an unpaired surrogate as `?`: neither
	crashes, and neither is checked for, as that would cost every string.
**/
@:noCompletion
@:cppFileCode("
// UTF-8 from UTF-16, as TextEncoder writes it (an unpaired surrogate as
// U+FFFD). With RUNS, four units are taken at a time as one word while
// they are ASCII, tried only after an ASCII unit so text of another script
// does not pay for the test: 200 characters of mostly ASCII sized and
// written in 222 ns rather than 330. A short string pays for the loop's
// extra shape, and takes the plain one. A word is taken apart low half
// first, as on every little-endian machine hxcpp builds for.
template <bool RUNS> static inline int cbUtf8Size(const char16_t *units, int count) {
	int total = 0;
	int i = 0;
	bool ascii = true;
	while (i < count) {
		if (RUNS && ascii && i + 4 <= count) {
			unsigned long long four;
			memcpy(&four, units + i, 8);
			if ((four & 0xFF80FF80FF80FF80ULL) == 0) {
				total += 4;
				i += 4;
				continue;
			}
		}
		unsigned int unit = units[i++];
		ascii = unit < 0x80;
		if (ascii) {
			total += 1;
		} else if (unit < 0x800) {
			total += 2;
		} else if (unit >= 0xD800 && unit < 0xDC00 && i < count && units[i] >= 0xDC00 && units[i] < 0xE000) {
			total += 4;
			i++;
		} else {
			total += 3;
		}
	}
	return total;
}

template <bool RUNS> static inline void cbUtf8Encode(const char16_t *units, int count, unsigned char *out) {
	int i = 0;
	bool ascii = true;
	while (i < count) {
		if (RUNS && ascii && i + 4 <= count) {
			unsigned long long four;
			memcpy(&four, units + i, 8);
			if ((four & 0xFF80FF80FF80FF80ULL) == 0) {
				out[0] = (unsigned char)four;
				out[1] = (unsigned char)(four >> 16);
				out[2] = (unsigned char)(four >> 32);
				out[3] = (unsigned char)(four >> 48);
				out += 4;
				i += 4;
				continue;
			}
		}
		unsigned int code = units[i++];
		ascii = code < 0x80;
		if (ascii) {
			*out++ = (unsigned char)code;
			continue;
		}
		if (code >= 0xD800 && code < 0xE000) {
			unsigned int low = i < count ? units[i] : 0;
			if (code < 0xDC00 && low >= 0xDC00 && low < 0xE000) {
				code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
				i++;
			} else {
				code = 0xFFFD;
			}
		}
		if (code < 0x800) {
			*out++ = (unsigned char)(0xC0 | (code >> 6));
		} else if (code < 0x10000) {
			*out++ = (unsigned char)(0xE0 | (code >> 12));
			*out++ = (unsigned char)(0x80 | ((code >> 6) & 0x3F));
		} else {
			*out++ = (unsigned char)(0xF0 | (code >> 18));
			*out++ = (unsigned char)(0x80 | ((code >> 12) & 0x3F));
			*out++ = (unsigned char)(0x80 | ((code >> 6) & 0x3F));
		}
		*out++ = (unsigned char)(0x80 | (code & 0x3F));
	}
}
")
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
	/**
		How many bytes the UTF-16 `units` of a string, `count` of them, take
		in UTF-8 from unit `from` on, as TextEncoder writes it: an unpaired
		surrogate as U+FFFD, three bytes.
	**/
	public static function sizeOfUnits(units:hl.Bytes, count:Int, from:Int):Int {
		var size:Int = 0;
		var i:Int = from;
		while (i < count) {
			var unit:Int = units.getUI16(i << 1);
			i++;
			if (unit < 0x80) {
				size++;
			} else if (unit < 0x800) {
				size += 2;
			} else if (unit >= 0xD800 && unit < 0xDC00 && i < count && units.getUI16(i << 1) >= 0xDC00 && units.getUI16(i << 1) < 0xE000) {
				size += 4;
				i++;
			} else {
				size += 3;
			}
		}
		return size;
	}

	/**
		The UTF-16 `units` of a string, `count` of them, from unit `from` on,
		written in UTF-8 into `out` at `at`, which has room for them there (see
		sizeOfUnits), as TextEncoder writes them: an unpaired surrogate as
		U+FFFD, where HashLink's encoder took the character after it into it.
		Where they end.
	**/
	public static function encodeUnits(units:hl.Bytes, count:Int, from:Int, out:hl.Bytes, at:Int):Int {
		var i:Int = from;
		while (i < count) {
			var code:Int = units.getUI16(i << 1);
			i++;
			if (code < 0x80) {
				out[at++] = code;
				continue;
			}
			if (code >= 0xD800 && code < 0xE000) {
				var low:Int = i < count ? units.getUI16(i << 1) : 0;
				if (code < 0xDC00 && low >= 0xDC00 && low < 0xE000) {
					code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
					i++;
				} else {
					code = 0xFFFD;
				}
			}
			if (code < 0x800) {
				out[at++] = 0xC0 | (code >> 6);
			} else if (code < 0x10000) {
				out[at++] = 0xE0 | (code >> 12);
				out[at++] = 0x80 | ((code >> 6) & 0x3F);
			} else {
				out[at++] = 0xF0 | (code >> 18);
				out[at++] = 0x80 | ((code >> 12) & 0x3F);
				out[at++] = 0x80 | ((code >> 6) & 0x3F);
			}
			out[at++] = 0x80 | (code & 0x3F);
		}
		return at;
	}

	// Whether HashLink's encoder stops where the string does. It takes every
	// surrogate, high or low, with the unit after it, whatever that is, so it
	// runs past the end of a string whose last unit it reaches as the first
	// of two, and crashes the process (an access violation, and the heap
	// left broken): the last of a run of surrogates at the end an odd number
	// long, a lone low half included, since the first of such a run is always
	// reached as the first of two. Mostly one comparison: the last unit is
	// not a surrogate.
	static inline function __endsWhole(value:String):Bool {
		var length:Int = value.length;
		var i:Int = length;
		while (i > 0) {
			var unit:Int = StringTools.fastCodeAt(value, i - 1);
			if (unit < 0xD800 || unit >= 0xE000) {
				break;
			}
			i--;
		}
		return ((length - i) & 1) == 0;
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


	#if (js || cpp)
	/**
		The number of bytes `value` is in UTF-8, as TextEncoder writes it: an
		unpaired surrogate as U+FFFD, three bytes.
	**/
	public static function sizeOf(value:String):Int {
		#if cpp
		// Over the string's own UTF-16 in C++: through `fastCodeAt` each
		// unit was a call that checked its bounds and how the string is held.
		// A string held a byte a character is ASCII, a byte a unit.
		if (!(untyped __cpp__("{0}.isUTF16Encoded()", value))) {
			return value.length;
		}
		var bytes:Int = 0;
		untyped __cpp__("{0} = {1}.length >= 32 ? cbUtf8Size<true>({1}.raw_wptr(), {1}.length) : cbUtf8Size<false>({1}.raw_wptr(), {1}.length)", bytes, value);
		return bytes;
		#else
		var length:Int = value.length;
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
		return size;
		#end
	}

	#end

	#if cpp
	/**
		`value`, `size` bytes in UTF-8 (see sizeOf), written at `at` in
		`data`, which has room for them there, as TextEncoder writes it: an
		unpaired surrogate as U+FFFD. Natively a string held as UTF-16 went
		through `wellFormed`, then `Bytes.ofString`, which made a buffer of
		it, and then was copied in: written straight into the buffer, in C++
		over the string's own units, eleven accented characters take 25 ns
		rather than 78, and 200 mostly ASCII 222 rather than 832.
	**/
	public static function encodeNative(value:String, data:haxe.io.BytesData, at:Int):Void {
		// A string held a byte a character is ASCII, its own UTF-8.
		if (!(untyped __cpp__("{0}.isUTF16Encoded()", value))) {
			untyped __cpp__("memcpy((char *){0}->GetBase() + {1}, {2}.raw_ptr(), {2}.length)", data, at, value);
			return;
		}
		// In C++ over the string's own UTF-16, written through a pointer
		// (see cbUtf8Encode): nothing here allocates, so nothing moves under
		// either.
		untyped __cpp__("if ({0}.length >= 32) cbUtf8Encode<true>({0}.raw_wptr(), {0}.length, (unsigned char *){1}->GetBase() + {2}); else cbUtf8Encode<false>({0}.raw_wptr(), {0}.length, (unsigned char *){1}->GetBase() + {2})", value, data, at);
	}
	#end

	#if (js || hl)
	/** At most this many bytes a UTF-16 unit takes in UTF-8. **/
	public static inline var MAX_BYTES_PER_UNIT:Int = 3;
	#end

	#if js
	static var __encoder:Dynamic = null;
	static var __decoder:Dynamic = null;
	static var __strictDecoder:Dynamic = null;

	static function __encode(value:String):Bytes {
		// A short string here: TextEncoder costs a call into the platform and
		// a buffer of its own however short the text, several times what a
		// string of a few dozen characters takes.
		if (value.length <= SHORT) {
			var bytes:Bytes = Bytes.alloc(sizeOf(value));
			__loop(value, @:privateAccess bytes.b, 0);
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
	/**
		`value` in UTF-8 into `view` from `at` up to `end`, as much as fits
		without half a character: the bytes written, and in `read` the UTF-16
		units of `value` they hold, so a writer short of room can grow and
		write the rest. As TextEncoder writes it, an unpaired surrogate as
		U+FFFD.

		Up to DIRECT units with room for all of them, by a loop; past that by
		TextEncoder.encodeInto, straight into the view. That costs a call and a
		view, about 75 ns on Node, and little a character after, where a loop
		costs 4 to 7 ns a character, and `encode` makes a buffer for every
		string (about 830 ns for 200 characters, against 92).
	**/
	public static function writeView(value:String, view:js.lib.Uint8Array, at:Int, end:Int):Int {
		var length:Int = value.length;
		if (length <= DIRECT && end - at >= length * 3) {
			read = length;
			return __loop(value, view, at) - at;
		}
		if (__encoder == null) {
			__encoder = js.Syntax.code("new TextEncoder()");
		}
		var result:Dynamic = __encoder.encodeInto(value, view.subarray(at, end > at ? end : at));
		read = result.read;
		return result.written;
	}

	/** The UTF-16 units of the string the last `writeView` wrote. **/
	public static var read:Int = 0;

	/**
		Up to this many units `writeView` writes by a loop, which below it
		beats TextEncoder.encodeInto's fixed cost (on Node 60 ns against 77
		for twelve characters, even at sixteen).
	**/
	public static inline var DIRECT:Int = 16;

	// `value`, which fits, into `view` from `at`: where it ends.
	static function __loop(value:String, view:js.lib.Uint8Array, at:Int):Int {
		var length:Int = value.length;
		var i:Int = 0;
		while (i < length) {
			var code:Int = StringTools.fastCodeAt(value, i++);
			if (code < 0x80) {
				view[at++] = code;
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
				view[at++] = 0xC0 | (code >> 6);
			} else if (code < 0x10000) {
				view[at++] = 0xE0 | (code >> 12);
				view[at++] = 0x80 | ((code >> 6) & 0x3F);
			} else {
				view[at++] = 0xF0 | (code >> 18);
				view[at++] = 0x80 | ((code >> 12) & 0x3F);
				view[at++] = 0x80 | ((code >> 6) & 0x3F);
			}
			view[at++] = 0x80 | (code & 0x3F);
		}
		return at;
	}

	/**
		Up to this many characters `bytesOf` sizes and encodes a string itself
		rather than through TextEncoder, which makes a buffer of its own
		whose cost is more than theirs up to that length.
	**/
	public static inline var SHORT:Int = 64;
	#end
}
