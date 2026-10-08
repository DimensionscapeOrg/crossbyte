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
**/
@:noCompletion
class Utf8 {
	public static inline function bytesOf(value:String):Bytes {
		#if js
		return __encode(value);
		#else
		return Bytes.ofString(value);
		#end
	}

	/**
		`len` bytes of `bytes` from `pos`, as UTF-8; `Bytes.getString` elsewhere.

		`strict` makes a malformed sequence throw on JavaScript rather than read
		as U+FFFD, for a caller that reports bytes that are not text.
	**/
	public static inline function stringOf(bytes:Bytes, pos:Int, len:Int, strict:Bool = false):String {
		#if js
		return __decode(bytes, pos, len, strict);
		#elseif hl
		return __decodeAroundNuls(bytes, pos, len);
		#else
		return bytes.getString(pos, len);
		#end
	}

	#if hl
	/**
		HashLink's `getString` decodes a NUL-terminated copy, so it too stops
		at the first NUL. UTF-8 puts no 0 byte inside a character, so the text
		between NULs is decoded on its own and each NUL put back.
	**/
	static function __decodeAroundNuls(bytes:Bytes, pos:Int, len:Int):String {
		// As getString refuses it, before anything is read.
		if (pos < 0 || len < 0 || pos + len > bytes.length) {
			throw haxe.io.Error.OutsideBounds;
		}
		var end:Int = pos + len;
		var out:StringBuf = null;
		var from:Int = pos;
		for (i in pos...end) {
			if (bytes.get(i) == 0) {
				if (out == null) {
					out = new StringBuf();
				}
				out.add(bytes.getString(from, i - from));
				out.addChar(0);
				from = i + 1;
			}
		}
		if (out == null) {
			return bytes.getString(pos, len);
		}
		out.add(bytes.getString(from, end - from));
		return out.toString();
	}
	#end

	#if js
	static var __encoder:Dynamic = null;
	static var __decoder:Dynamic = null;
	static var __strictDecoder:Dynamic = null;

	static function __encode(value:String):Bytes {
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
		return decoder.decode(view.subarray(pos, pos + len));
	}
	#end
}
