package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A dynamic `BitSet` implementation that allows efficient storage and manipulation of boolean values using bits.
 * Automatically grows as needed when setting bits beyond the current capacity.
 *
 * The set bits can be visited in order without testing every index:
 * `for (i in bits)` for convenience, or `nextSetBit` for a loop that
 * allocates nothing, which is the one to use every tick.
 *
 * ```haxe
 * var i:Int = bits.nextSetBit(0);
 * while (i >= 0) {
 * 	visit(i);
 * 	i = bits.nextSetBit(i + 1);
 * }
 * ```
 *
 * `and`, `or`, `xor` and `andNot` combine two sets a word at a time. With
 * entity slots as bit indices, what came into view since the last tick is
 * `now.clone()` with `andNot(before)` applied, and what left it is the same
 * the other way round.
 */
class BitSet {
	private var __bits:Array<Int>;
	private var __size:Int;

	/**
	 * The length of the `BitSet`, representing the total number of bits it can handle.
	 * This property can be used to get or set the size of the `BitSet`.
	 */
	public var length(get, set):Int;

	private function get_length():Int {
		return __size;
	}

	private function set_length(value:Int):Int {
		if (value < 0) {
			throw "Index out of bounds";
		}
		__ensureCapacity(value);
		__size = value;
		__trimToSize();
		return __size;
	}

	/**
	 * Creates a new `BitSet` with an initial capacity.
	 *
	 * @param size The initial number of bits that the `BitSet` can handle.
	 */
	public function new(size:UInt = 32) {
		this.__size = size;
		this.__bits = new Array<Int>();
		this.__bits.resize(Math.ceil(size / 32));
		for (i in 0...__bits.length) {
			__bits[i] = 0;
		}
	}

	private inline function __ensureCapacity(bitIndex:Int):Void {
		if (bitIndex >= __size) {
			var newSize:Int = Std.int(Math.max(__size * 2, bitIndex + 1));
			var newBits:Array<Int> = new Array<Int>();
			newBits.resize(Math.ceil(newSize / 32));
			for (i in 0...__bits.length) {
				newBits[i] = __bits[i];
			}
			for (i in __bits.length...newBits.length) {
				newBits[i] = 0;
			}
			__bits = newBits;
			__size = newSize;
		}
	}

	private inline function __checkBounds(index:Int):Void {
		if (index < 0)
			throw "Index out of bounds";
	}

	private inline function __wordCountForSize(size:Int):Int {
		return Std.int(Math.ceil(size / 32));
	}

	private inline function __lastWordMask():Int {
		var bitsInLastWord:Int = __size & 31;
		if (bitsInLastWord == 0) {
			return -1;
		}

		return (1 << bitsInLastWord) - 1;
	}

	private function __trimToSize():Void {
		var words:Int = __wordCountForSize(__size);
		if (__bits.length > words) {
			__bits.resize(words);
		}

		if (words > 0) {
			__bits[words - 1] &= __lastWordMask();
		}
	}

	/**
	 * Sets or clears the bit at the specified index.
	 *
	 * @param index The index of the bit to set or clear.
	 * @param value `true` to set the bit, `false` to clear it.
	 */
	public inline function set(index:Int, value:Bool):Void {
		__checkBounds(index);
		__ensureCapacity(index);
		var bitIndex:Int = index >> 5; // Divide by 32
		var bitOffset:Int = index & 31; // Modulus 32
		if (value) {
			__bits[bitIndex] |= (1 << bitOffset); // Set bit
		} else {
			__bits[bitIndex] &= ~(1 << bitOffset); // Clear bit
		}
	}

	/**
	 * Retrieves the boolean value of the bit at the specified index.
	 *
	 * @param index The index of the bit to retrieve.
	 * @return `true` if the bit is set, `false` otherwise.
	 */
	public inline function get(index:Int):Bool {
		__checkBounds(index);
		if (index >= __size)
		{
			return false;
		}
			
		var bitIndex = index >> 5;
		var bitOffset = index & 31;
		return (__bits[bitIndex] & (1 << bitOffset)) != 0;
	}

	/**
	 * Clears the bit at the specified index.
	 *
	 * @param index The index of the bit to clear.
	 */
	public inline function clear(index:Int):Void {
		__checkBounds(index);
		if (index >= __size){
			return;
		}
			
		var bitIndex:Int = index >> 5;
		var bitOffset:Int = index & 31;
		__bits[bitIndex] &= ~(1 << bitOffset); // Clear bit
	}

	/**
	 * Clears all bits in the `BitSet`.
	 */
	public function clearAll():Void {
		for (i in 0...__bits.length) {
			__bits[i] = 0;
		}
	}

	/**
	 * Sets all bits in the `BitSet` to `true`.
	 */
	public function setAll():Void {
		var words:Int = __wordCountForSize(__size);
		for (i in 0...words) {
			__bits[i] = -1; // Set all bits to 1
		}
		if (words > 0) {
			__bits[words - 1] &= __lastWordMask();
		}
	}

	/**
	 * Toggles the bit at the specified index.
	 *
	 * @param index The index of the bit to toggle.
	 */
	public inline function flip(index:Int):Void {
		__checkBounds(index);
		__ensureCapacity(index);
		var bitIndex:Int = index >> 5;
		var bitOffset:Int = index & 31;
		__bits[bitIndex] ^= (1 << bitOffset); // Flip bit
	}

	private static inline function bitCount(value:Int):Int {
		var count:Int = 0;
		var v:Int = value;
		while (v != 0) {
			count++;
			v &= v - 1; // Clear the lowest set bit
		}
		return count;
	}

	/**
	 * Counts the number of bits that are set to `true`.
	 *
	 * @return The number of set bits in the `BitSet`.
	 */
	public function countSetBits():Int {
		var count:Int = 0;
		var words:Int = __wordCountForSize(__size);
		for (i in 0...words) {
			var word:Int = __bits[i];
			if (i == words - 1) {
				word &= __lastWordMask();
			}
			count += bitCount(word);
		}
		return count;
	}

	/**
	 * Finds the first set bit at or after `from`.
	 *
	 * @param from The index to start looking at.
	 * @return The index of that bit, or `-1` if no bit from there on is set.
	 */
	public function nextSetBit(from:Int):Int {
		__checkBounds(from);
		if (from >= __size) {
			return -1;
		}

		var words:Int = __wordCountForSize(__size);
		var wordIndex:Int = from >> 5;
		// The bits below `from` in its own word are masked away first.
		var word:Int = __bits[wordIndex] & (-1 << (from & 31));

		while (true) {
			if (word != 0) {
				var index:Int = (wordIndex << 5) + __trailingZeros(word);
				return index < __size ? index : -1;
			}
			wordIndex++;
			if (wordIndex >= words) {
				return -1;
			}
			word = __bits[wordIndex];
		}
	}

	/**
	 * Finds the first clear bit at or after `from`. Every bit past `length`
	 * reads as clear, so this always finds one: with every bit from `from`
	 * set, the answer is `length`.
	 *
	 * @param from The index to start looking at.
	 * @return The index of that bit.
	 */
	public function nextClearBit(from:Int):Int {
		__checkBounds(from);
		if (from >= __size) {
			return from;
		}

		var words:Int = __wordCountForSize(__size);
		var wordIndex:Int = from >> 5;
		var word:Int = ~__bits[wordIndex] & (-1 << (from & 31));

		while (true) {
			if (word != 0) {
				// Bits past the end are held clear, so the first of them is
				// found here when everything before it is set.
				return (wordIndex << 5) + __trailingZeros(word);
			}
			wordIndex++;
			if (wordIndex >= words) {
				return __size;
			}
			word = ~__bits[wordIndex];
		}
	}

	/**
	 * Iterates the indices of the set bits, lowest first, so that
	 * `for (i in bits)` visits exactly those.
	 *
	 * The iteration reads the set as it goes rather than a copy of it.
	 */
	public inline function iterator():BitSetIterator {
		return new BitSetIterator(this);
	}

	/**
	 * Whether no bit is set.
	 */
	public function isEmpty():Bool {
		for (i in 0...__wordCountForSize(__size)) {
			if (__bits[i] != 0) {
				return false;
			}
		}
		return true;
	}

	/**
	 * A separate set with the same length and the same bits.
	 */
	public function clone():BitSet {
		var copy:BitSet = new BitSet(__size);
		for (i in 0...__wordCountForSize(__size)) {
			copy.__bits[i] = __bits[i];
		}
		return copy;
	}

	/**
	 * Keeps only the bits that are also set in `other`. The length does not
	 * change; bits past the end of `other` are cleared.
	 */
	public function and(other:BitSet):Void {
		var words:Int = __wordCountForSize(__size);
		var otherWords:Int = __wordCountForSize(other.__size);
		for (i in 0...words) {
			__bits[i] = i < otherWords ? __bits[i] & other.__bits[i] : 0;
		}
	}

	/**
	 * Sets every bit that is set in `other`, growing to its length if it is
	 * the longer.
	 */
	public function or(other:BitSet):Void {
		if (other.__size > __size) {
			length = other.__size;
		}
		for (i in 0...__wordCountForSize(other.__size)) {
			__bits[i] |= other.__bits[i];
		}
	}

	/**
	 * Flips every bit that is set in `other`, growing to its length if it is
	 * the longer. What is left set is what differs between the two.
	 */
	public function xor(other:BitSet):Void {
		if (other.__size > __size) {
			length = other.__size;
		}
		for (i in 0...__wordCountForSize(other.__size)) {
			__bits[i] ^= other.__bits[i];
		}
	}

	/**
	 * Clears every bit that is set in `other`. The length does not change.
	 */
	public function andNot(other:BitSet):Void {
		var words:Int = __wordCountForSize(__size);
		var otherWords:Int = __wordCountForSize(other.__size);
		for (i in 0...(words < otherWords ? words : otherWords)) {
			__bits[i] &= ~other.__bits[i];
		}
	}

	// Index of the lowest set bit of a non-zero word, found by halving:
	// shifts and masks only, which every target agrees on. The usual de
	// Bruijn multiply needs a 32-bit product, and a JavaScript double
	// rounds that one away.
	private static inline function __trailingZeros(word:Int):Int {
		var n:Int = 0;
		if ((word & 0xFFFF) == 0) {
			n += 16;
			word = word >>> 16;
		}
		if ((word & 0xFF) == 0) {
			n += 8;
			word = word >>> 8;
		}
		if ((word & 0xF) == 0) {
			n += 4;
			word = word >>> 4;
		}
		if ((word & 0x3) == 0) {
			n += 2;
			word = word >>> 2;
		}
		if ((word & 0x1) == 0) {
			n += 1;
		}
		return n;
	}
}

/**
 * Walks the set bits of a `BitSet`, lowest first. Made by
 * `BitSet.iterator()`; a `for` loop over the set is the usual way to use one.
 */
class BitSetIterator {
	private var __set:BitSet;
	private var __next:Int;

	public inline function new(set:BitSet) {
		__set = set;
		__next = set.nextSetBit(0);
	}

	public inline function hasNext():Bool {
		return __next >= 0;
	}

	public inline function next():Int {
		var current:Int = __next;
		__next = __set.nextSetBit(current + 1);
		return current;
	}
}
