package crossbyte.rpc._internal;

import haxe.io.Bytes;

/**
	The bytes a value takes as `RPCFrame` writes it, worked out without
	writing it: what the `patchSize` and `size` functions generated for a
	structure add up, and what a budgeted map patch weighs an entry by.
	Each gives exactly what its writer writes, on every target.
**/
@:noCompletion
class RPCSizes {
	/** The bytes `putVarUInt` writes for `value`, a negative `Int` as the unsigned value it holds. **/
	public static inline function varUInt(value:Int):Int {
		// wrap32 is `value` but on PHP, where putVarUInt sends the low 32 bits.
		final v:Int = crossbyte.utils.Hash.wrap32(value);
		return v < 0 ? 5 : (v < 0x80 ? 1 : (v < 0x4000 ? 2 : (v < 0x200000 ? 3 : (v < 0x10000000 ? 4 : 5))));
	}

	/** The bytes `putVarInt` writes for `value`: zigzagged, then a varint. **/
	public static inline function varInt(value:Int):Int {
		final v:Int = crossbyte.utils.Hash.wrap32(value);
		return varUInt((v << 1) ^ (v >> 31));
	}

	/**
		The bytes `putString` writes for `value`: its UTF-8, after their count
		as a varint.

		@throws ArgumentError For `null`, as `putString` does.
	**/
	public static inline function string(value:String):Int {
		final size:Int = utf8(value);
		return varUInt(size) + size;
	}

	/**
		The bytes `putBytes` writes for `bytes`: they, after their count.

		@throws ArgumentError For `null`, as `putBytes` does.
	**/
	public static inline function bytes(bytes:Bytes):Int {
		if (bytes == null) {
			throw RPCFrame.nullValue("Bytes");
		}
		return varUInt(bytes.length) + bytes.length;
	}

	/** The bytes of `value` in UTF-8, as `putString` writes them on this target. **/
	public static function utf8(value:String):Int {
		if (value == null) {
			throw RPCFrame.nullValue("String");
		}
		#if (cpp || js)
		// What putString writes there: an unpaired surrogate as U+FFFD.
		return crossbyte._internal.Utf8.sizeOf(value);
		#elseif php
		// A string there is its UTF-8 bytes.
		return php.Global.strlen(value);
		#elseif neko
		// A string there is its UTF-8 bytes, a character each.
		return value.length;
		#else
		// UTF-16 units (code points on eval, where one past the first plane
		// is one). A surrogate that is not half of a pair goes as the
		// target's encoder writes it: the jvm's as `?`, elsewhere asked of
		// that encoder, for the one string in a great many that holds one.
		final length:Int = value.length;
		var size:Int = 0;
		var i:Int = 0;
		while (i < length) {
			final unit:Int = StringTools.fastCodeAt(value, i++);
			if (unit < 0x80) {
				size++;
			} else if (unit < 0x800) {
				size += 2;
			} else if (unit >= 0x10000) {
				size += 4;
			} else if (unit < 0xD800 || unit >= 0xE000) {
				size += 3;
			} else if (unit < 0xDC00 && i < length && StringTools.fastCodeAt(value, i) >= 0xDC00 && StringTools.fastCodeAt(value, i) < 0xE000) {
				size += 4;
				i++;
			} else {
				#if (jvm || java)
				size++;
				#else
				return crossbyte._internal.Utf8.bytesOf(value).length;
				#end
			}
		}
		return size;
		#end
	}
}
