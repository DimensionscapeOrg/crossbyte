package crossbyte._internal.deflatex.utils;

import haxe.io.BytesOutput;

class BitsOutput extends BytesOutput {
	/**
	 * A queue of bits.
	 */
	public var bitVal:Int = 0;

	/**
	 * The current queue position.
	 */
	public var bitPos:Int = 0;

	/**
	 * Write the given bit sequence.
	 * @param v The value
	 * @param n The number of bits
	 */
	public function writeBits(v:Int, n:Int) {
		for (m in 0...n) {
			bitVal |= ((v >>> m) & 1) << bitPos;
			bitPos++;
			if (bitPos > 7) {
				writeByte(bitVal);
				bitVal = 0;
				bitPos = 0;
			}
		}
	}

	/**
	 * Write the reverse of the given bit sequence.
	 * @param v The value
	 * @param n The number of bits
	 */
	public function writeBitsR(v:Int, n:Int) {
		var m:Int = n - 1;
		while (m >= 0) {
			bitVal |= ((v >>> m) & 1) << bitPos;
			bitPos++;
			if (bitPos > 7) {
				writeByte(bitVal);
				bitVal = 0;
				bitPos = 0;
			}
			m--;
		}
	}

	/**
	 * Flush the bit queue.
	 */
	public function flushBits() {
		if (bitPos > 0) {
			writeBits(0xff, 8 - bitPos);
		}
	}
}
