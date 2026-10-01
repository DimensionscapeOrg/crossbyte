package crossbyte._internal;

import haxe.io.Bytes;

/**
	A string's UTF-8 bytes, through the platform's own encoder where Haxe's
	is slow.

	Haxe's `Bytes.ofString` for JavaScript walks the string a character at a
	time, pushing each byte onto an Array, and then copies the Array into a
	Uint8Array. A Node server answering `respond` with 64 KB of JSON spent
	more than half its working time there. `TextEncoder` is native on Node
	and in every browser, and writes the same bytes for any string that is
	valid UTF-16. An unpaired surrogate becomes U+FFFD, where Haxe's encoder
	took the next character into it, or wrote bytes UTF-8 does not allow.
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

	#if js
	static var __encoder:Dynamic = null;

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
	#end
}
