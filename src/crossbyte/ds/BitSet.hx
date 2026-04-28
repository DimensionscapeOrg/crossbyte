package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A dynamic `BitSet` implementation that allows efficient storage and manipulation of boolean values using bits.
 * Automatically grows as needed when setting bits beyond the current capacity.
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
}
