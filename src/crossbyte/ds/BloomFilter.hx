package crossbyte.ds;

import crossbyte.errors.RangeError;
import crossbyte.utils.Hash;
import haxe.ds.Vector;
import haxe.io.Bytes;

/**
 * A simple Bloom Filter implementation.
 *
 * Membership is probabilistic: `contains` may return a false positive but never
 * a false negative. The `k` bit positions per item are derived from two
 * base hashes via the Kirsch-Mitzenmacher scheme (`h1 + i*h2`), which spreads
 * the bits across the whole array from one hash computation per call: the
 * second hash is mixed out of the first.
 *
 * The bits are packed 32 to an `Int`, in a `haxe.ds.Vector`, so a
 * 10-million-bit filter holds 1.25 MB. A string is hashed as its UTF-8 bytes,
 * decoded from its characters in place, and `add` and `contains` allocate
 * nothing.
 *
 * Items are strings, `Int`s (`addInt`, `containsInt`) or bytes (`addBytes`,
 * `containsBytes`); the three kinds share one set of bits, so an `Int` and a
 * string can collide as any two items can; a string and its UTF-8 bytes are
 * the same item. The positions are stepped through without multiplying, and
 * a string is its UTF-8 bytes on every target whatever it holds its
 * characters as, so every target sets the same bits for the same item.
 *
 * @author Christopher Speciale
 */
class BloomFilter {
	private var size:Int;
	private var numHashFunctions:Int;
	private var __words:Vector<Int>;

	/**
	 * Constructs a new BloomFilter.
	 *
	 * @param size The size of the bit array.
	 * @param numHashFunctions The number of hash functions to use.
	 */
	public function new(size:Int, numHashFunctions:Int) {
		if (size <= 0) {
			throw "BloomFilter size must be greater than zero";
		}
		if (numHashFunctions <= 0) {
			throw "BloomFilter must use at least one hash function";
		}

		this.size = size;
		this.numHashFunctions = numHashFunctions;
		this.__words = new Vector<Int>(((size - 1) >>> 5) + 1, 0);
	}

	/**
	 * Adds an item to the Bloom Filter.
	 *
	 * @param item The item to be added.
	 */
	public function add(item:String):Void {
		__set(__hashString(item));
	}

	/**
	 * Checks if an item is possibly in the Bloom Filter.
	 *
	 * @param item The item to be checked.
	 * @return True if the item is possibly in the set, false if definitely not.
	 */
	public function contains(item:String):Bool {
		return __test(__hashString(item));
	}

	/** Adds an `Int` item, a message id say, without making a string of it. **/
	public function addInt(item:Int):Void {
		__set(Hash.fmix32(item));
	}

	/** Whether an `Int` item is possibly in the filter. **/
	public function containsInt(item:Int):Bool {
		return __test(Hash.fmix32(item));
	}

	/**
		Adds the bytes `item[offset...offset + length]` as one item; a
		`length` of -1 is to the end.
		@throws RangeError For a range outside the bytes.
	**/
	public function addBytes(item:Bytes, offset:Int = 0, length:Int = -1):Void {
		__set(__hashBytes(item, offset, length));
	}

	/** Whether the bytes `item[offset...offset + length]` are possibly in the filter. **/
	public function containsBytes(item:Bytes, offset:Int = 0, length:Int = -1):Bool {
		return __test(__hashBytes(item, offset, length));
	}

	/** Forgets everything added. **/
	public function clear():Void {
		for (i in 0...__words.length) {
			__words[i] = 0;
		}
	}

	private function __set(h1:Int):Void {
		var at:Int = __first(h1);
		var step:Int = __step(h1);
		for (_ in 0...numHashFunctions) {
			__words[at >>> 5] |= 1 << (at & 31);
			at = __next(at, step);
		}
	}

	private function __test(h1:Int):Bool {
		var at:Int = __first(h1);
		var step:Int = __step(h1);
		for (_ in 0...numHashFunctions) {
			if ((__words[at >>> 5] & (1 << (at & 31))) == 0) {
				return false;
			}
			at = __next(at, step);
		}
		return true;
	}

	// The positions are h1, h1 + h2, h1 + 2 h2, ... modulo `size`, stepped
	// through by addition and kept below `size` at each step, so nothing
	// overflows on any target and no product differs between one whose Int
	// wraps at 32 bits and JavaScript's, whose does not.
	private inline function __first(h1:Int):Int {
		return (h1 & 0x7FFFFFFF) % size;
	}

	private inline function __step(h1:Int):Int {
		// The second hash, mixed out of the first; never 0, or every
		// position would be the same.
		var step:Int = (Hash.fmix32(h1 ^ 0x5BD1E995) & 0x7FFFFFFF) % size;
		return step == 0 ? 1 : step;
	}

	private inline function __next(at:Int, step:Int):Int {
		// at + step, less size once it passes it, without forming a sum that
		// could pass 2^31.
		return at >= size - step ? at - (size - step) : at + step;
	}

	// FNV-1a over the string's UTF-8 bytes, worked out from its characters in
	// place. Its characters are UTF-16 units on JavaScript, the jvm, hxcpp
	// and hl, code points on eval, and the bytes themselves on neko: hashed
	// as they came, a string past ASCII set different bits on each.
	private static function __hashString(s:String):Int {
		var hash:Int = 0x811C9DC5;
		#if (neko || !target.unicode)
		for (i in 0...s.length) {
			hash = __byte(hash, StringTools.fastCodeAt(s, i));
		}
		#else
		var length:Int = s.length;
		var i:Int = 0;
		while (i < length) {
			var code:Int = StringTools.fastCodeAt(s, i++);
			#if target.utf16
			if (code >= 0xD800 && code < 0xDC00 && i < length) {
				var low:Int = StringTools.fastCodeAt(s, i);
				if (low >= 0xDC00 && low < 0xE000) {
					code = (((code - 0xD800) << 10) | (low - 0xDC00)) + 0x10000;
					i++;
				}
			}
			#end
			if (code < 0x80) {
				hash = __byte(hash, code);
			} else if (code < 0x800) {
				hash = __byte(hash, 0xC0 | (code >> 6));
				hash = __byte(hash, 0x80 | (code & 0x3F));
			} else if (code < 0x10000) {
				hash = __byte(hash, 0xE0 | (code >> 12));
				hash = __byte(hash, 0x80 | ((code >> 6) & 0x3F));
				hash = __byte(hash, 0x80 | (code & 0x3F));
			} else {
				hash = __byte(hash, 0xF0 | (code >> 18));
				hash = __byte(hash, 0x80 | ((code >> 12) & 0x3F));
				hash = __byte(hash, 0x80 | ((code >> 6) & 0x3F));
				hash = __byte(hash, 0x80 | (code & 0x3F));
			}
		}
		#end
		return Hash.fmix32(hash);
	}

	private static inline function __byte(hash:Int, byte:Int):Int {
		return Hash.mul32(hash ^ byte, 0x01000193);
	}

	private static function __hashBytes(bytes:Bytes, offset:Int, length:Int):Int {
		// A length below zero is to the end. Unchecked, a range before the
		// bytes read past them, and one past them hashed as the empty item.
		var end:Int = length < 0 ? bytes.length : offset + length;
		if (offset < 0 || offset > bytes.length || (length >= 0 && length > bytes.length - offset) || length < -1) {
			throw new RangeError('Bytes from $offset for $length do not fit in ${bytes.length}.');
		}
		var hash:Int = 0x811C9DC5;
		for (i in offset...end) {
			hash = __byte(hash, bytes.get(i));
		}
		return Hash.fmix32(hash);
	}
}
