package crossbyte._internal.deflatex;

import haxe.io.Bytes;
import haxe.ds.Vector;
import haxe.Exception;
import crossbyte._internal.deflatex.utils.Math;

/**
 * Implements a Lempel-Ziv sliding window dictionary.
 */
class LZWindow {
	private static final MIN_MATCH:Int = 3;
	private static final MAX_MATCH:Int = 258;

	private var maxSize:Int;
	private var mask:Int;
	private var dict:Vector<Int>;
	private var pos:Int;
	private var size:Int;

	/**
	 * Create a new window.
	 */
	public function new(s:Int) {
		var count:Int = crossbyte._internal.deflatex.utils.Math.bitCount(s);
		if (count != 1) {
			throw new Exception("Window size must be a power of 2");
		}
		maxSize = s;
		mask = maxSize - 1;
		dict = new Vector<Int>(maxSize);
		#if !static
		for (i in 0...maxSize)
			dict[i] = 0;
		#end
		pos = 0;
		size = 0;
	}

	/**
	 * Add a byte to the window.
	 * @param b The byte to be added
	 */
	public function addByte(b:Int) {
		b &= 0xff;
		dict[pos] = b;
		pos = (pos + 1) & mask;
		if (size < maxSize)
			size++;
	}

	/**
	 * Add an array of bytes to the window.
	 * @param b The bytes to be added
	 */
	public function addAllBytes(b:Bytes) {
		addBytes(b, 0, b.length);
	}

	/**
	 * Add an array of bytes to the window.
	 * @param b The bytes to be added
	 * @param off The starting offset
	 * @param len The number of bytes
	 */
	public function addBytes(b:Bytes, off:Int, len:Int) {
		for (i in off...off + len) {
			addByte(b.get(i));
		}
	}

	/**
	 * Find a previous match for the given bytes.
	 * @param b The data array
	 * @param off The starting offset
	 * @param len The number of bytes
	 * @return A distance/length pair
	 */
	public function find(buffer:Bytes, off:Int, len:Int):LZPair {
		if (size == 0)
			return null;

		for (i in 1...size + 1) {
			var start:Int = (pos - i) & mask;
			var matchLength:Int = 0;
			var x:Int = start;
			var y:Int = off;
			while (matchLength < MAX_MATCH && y < len) {
				if (dict[x] != buffer.get(y))
					break;
				matchLength++;
				x = (x + 1) & mask;
				if (x == pos)
					x = start;
				y++;
			}
			if (matchLength >= MIN_MATCH) {
				return new LZPair(i, matchLength);
			}
		}
		return null;
	}

	/**
	 * Copy a sequence of bytes from the window.
	 * @param dist The distance to go back
	 * @param len The number of bytes to copy
	 * @return The byte sequence
	 */
	public function getBytes(dist:Int, len:Int):Bytes {
		var b:Bytes = Bytes.alloc(len);

		var start:Int = (pos - dist) & mask;
		var x:Int = start;
		for (i in 0...len) {
			b.set(i, dict[x]);
			x = (x + 1) & mask;
			if (x == pos)
				x = start;
		}

		return b;
	}
}
