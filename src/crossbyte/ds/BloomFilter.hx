package crossbyte.ds;

import crossbyte.utils.Hash;

/**
 * A simple Bloom Filter implementation.
 *
 * Membership is probabilistic: `contains` may return a false positive but never
 * a false negative. The `k` bit positions per item are derived from two
 * independent base hashes via the Kirsch-Mitzenmacher scheme (`h1 + i*h2`),
 * which spreads the bits across the whole array from just two hash computations
 * per call.
 *
 * @author Christopher Speciale
 */
class BloomFilter {
	private var size:Int;
	private var numHashFunctions:Int;
	private var bitArray:Array<Bool>;

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
		this.bitArray = [];
		this.bitArray.resize(size);
		for (i in 0...size)
			bitArray[i] = false;
	}

	/**
	 * Adds an item to the Bloom Filter.
	 *
	 * @param item The item to be added.
	 */
	public function add(item:String):Void {
		var h1:Int = Hash.fnv1a32String(item) & 0x7fffffff;
		var h2:Int = (Hash.fnv1a32String(item + "bloom") | 1) & 0x7fffffff;
		for (i in 0...numHashFunctions) {
			bitArray[__indexAt(h1, h2, i)] = true;
		}
	}

	/**
	 * Checks if an item is possibly in the Bloom Filter.
	 *
	 * @param item The item to be checked.
	 * @return True if the item is possibly in the set, false if definitely not.
	 */
	public function contains(item:String):Bool {
		var h1:Int = Hash.fnv1a32String(item) & 0x7fffffff;
		var h2:Int = (Hash.fnv1a32String(item + "bloom") | 1) & 0x7fffffff;
		for (i in 0...numHashFunctions) {
			if (!bitArray[__indexAt(h1, h2, i)])
				return false;
		}
		return true;
	}

	// Derives the i-th bit position from two base hashes.
	//
	// `i * h2` overflows on a target whose Int is 32 bits, and the negative
	// correction below is what puts it back in range. On JavaScript an Int is a
	// double, so it does not overflow at all and the correction never fires --
	// which means the two arrive at the same bit only when `size` divides 2^32,
	// the amount they differ by. It does for a power of two, and both of this
	// class's tests use one; at `size = 10000` the filters genuinely differ,
	// measured.
	//
	// That is not a bug while the bits cannot leave this object -- there is no
	// serialization here, and what a caller can observe (never a false
	// negative, and a spread good enough to keep false positives rare) holds on
	// both. It becomes one the moment a filter is written to a file or a wire,
	// so anything adding that has to make this arithmetic explicit first.
	private inline function __indexAt(h1:Int, h2:Int, i:Int):Int {
		var index:Int = (h1 + i * h2) % size;
		if (index < 0) {
			index += size;
		}
		return index;
	}
}
