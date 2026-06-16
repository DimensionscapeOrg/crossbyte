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

	// Derives the i-th bit position from two base hashes. `i * h2` may overflow
	// Int and wrap negative, so the result is normalized back into [0, size).
	private inline function __indexAt(h1:Int, h2:Int, i:Int):Int {
		var index:Int = (h1 + i * h2) % size;
		if (index < 0) {
			index += size;
		}
		return index;
	}
}
