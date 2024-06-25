package crossbyte.ds;

import haxe.crypto.Md5;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A simple Bloom Filter implementation.
 */
class BloomFilter {
	private var size:Int;
	private var bitArray:Array<Bool>;
	private var hashFunctions:Array<(String) -> Int>;

	/**
	 * Constructs a new BloomFilter.
	 *
	 * @param size The size of the bit array.
	 * @param numHashFunctions The number of hash functions to use.
	 */
	public function new(size:Int, numHashFunctions:Int) {
		this.size = size;
		this.bitArray = new Array<Bool>(size);
		for (i in 0...size)
			bitArray[i] = false;
		this.hashFunctions = [];
		for (i in 0...numHashFunctions) {
			hashFunctions.push(createHashFunction(i));
		}
	}

	/**
	 * Adds an item to the Bloom Filter.
	 *
	 * @param item The item to be added.
	 */
	public function add(item:String):Void {
		for (hashFunction in hashFunctions) {
			var index = hashFunction(item) % size;
			bitArray[index] = true;
		}
	}

	/**
	 * Checks if an item is possibly in the Bloom Filter.
	 *
	 * @param item The item to be checked.
	 * @return True if the item is possibly in the set, false if definitely not.
	 */
	public function contains(item:String):Bool {
		for (hashFunction in hashFunctions) {
			var index = hashFunction(item) % size;
			if (!bitArray[index])
				return false;
		}
		return true;
	}

	private function createHashFunction(seed:Int):(String) -> Int {
		return function(item:String):Int {
			return Math.abs(Md5.encode(item + seed).charCodeAt(0));
		}
	}
}
