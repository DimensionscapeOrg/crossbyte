package crossbyte._internal.deflatex;

import haxe.ds.Vector;
import haxe.Exception;

/**
 * Implements a Lempel-Ziv distance / length pair.
 */
class LZPair {
	/*
	 * Ranges for Length/distance symbols
	 * (see RFC 1951, section 3.2.5)
	 */
	public static final SYMBOLS:Symbols = new Symbols();

	/** The distance value. */
	public var dist:Int;

	/** The distance symbol. */
	public var distSymbol:Int;

	/** The distance bits. */
	public var distBits:Int;

	/** The number of distance bits. */
	public var distNumBits:Int;

	/** The length value. */
	public var len:Int;

	/** The length symbol. */
	public var lenSymbol:Int;

	/** The length bits. */
	public var lenBits:Int;

	/** The number of length bits. */
	public var lenNumBits:Int;

	/**
	 * Create a new distance / length pair.
	 * @param dist The distance value
	 * @param len The length value
	 */
	public function new(dist:Int, len:Int) {
		this.dist = dist;
		this.len = len;

		distSymbol = -1;
		lenSymbol = -1;
		for (i in 0...29) {
			if (len <= SYMBOLS.lenUpper[i]) {
				lenSymbol = 257 + i;
				lenBits = len - SYMBOLS.lenLower[i];
				lenNumBits = SYMBOLS.lenNBits[i];
				break;
			}
		}
		for (i in 0...30) {
			if (dist <= SYMBOLS.distUpper[i]) {
				distSymbol = i;
				distBits = dist - SYMBOLS.distLower[i];
				distNumBits = SYMBOLS.distNBits[i];
				break;
			}
		}

		if (distSymbol == -1 || lenSymbol == -1) {
			throw new Exception("Couldn't find distance/length symbol");
		}
	}
}

private class Symbols {
	public var lenLower:Vector<Int>;
	public var lenUpper:Vector<Int>;
	public var lenNBits:Vector<Int>;
	public var distLower:Vector<Int>;
	public var distUpper:Vector<Int>;
	public var distNBits:Vector<Int>;

	public function new() {
		lenLower = new Vector<Int>(29);
		lenUpper = new Vector<Int>(29);
		lenNBits = new Vector<Int>(29);
		for (i in 0...8) {
			lenLower[i] = 3 + i;
			lenUpper[i] = lenLower[i];
			lenNBits[i] = 0;
		}
		for (i in 8...28) {
			var j:Int = (i - 8) % 4;
			var k:Int = Std.int((i - 8) / 4);
			lenLower[i] = ((4 + j) << (k + 1)) + 3;
			lenUpper[i] = lenLower[i] + (1 << (k + 1)) - 1;
			lenNBits[i] = k + 1;
		}
		lenUpper[27]--;
		lenLower[28] = 258;
		lenUpper[28] = 258;
		lenNBits[28] = 0;

		distLower = new Vector<Int>(30);
		distUpper = new Vector<Int>(30);
		distNBits = new Vector<Int>(30);
		for (i in 0...4) {
			distLower[i] = 1 + i;
			distUpper[i] = distLower[i];
			distNBits[i] = 0;
		}
		for (i in 4...30) {
			var j:Int = (i - 4) % 2;
			var k:Int = Std.int((i - 4) / 2);
			distLower[i] = ((2 + j) << (k + 1)) + 1;
			distUpper[i] = distLower[i] + (1 << (k + 1)) - 1;
			distNBits[i] = k + 1;
		}
	}
}
