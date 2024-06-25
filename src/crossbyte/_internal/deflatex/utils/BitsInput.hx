package crossbyte._internal.deflatex.utils;

import haxe.io.BytesInput;

class BitsInput extends BytesInput {
	/**
	 * A queue of bits.
	 */
	public var bitVal:Int = 0;

	/**
	 * The current queue position.
	 */
	public var bitPos:Int = 0;

	/**
	 * Read a sequence of bits.
	 * @param n The number of bits
	 * @return The value
	 */
	public function readBits(n:Int) {
		var v:Int = 0;
		for (m in 0...n) {
			if (bitPos == 0) {
				bitVal = readByte();
			}
			v |= ((bitVal >>> bitPos) & 1) << m;
			bitPos = (bitPos + 1) & 7;
		}
		return v;
	}

	/**
	 * Clear the bit queue.
	 */
	public function clearBits() {
		bitVal = 0;
		bitPos = 0;
	}
}
