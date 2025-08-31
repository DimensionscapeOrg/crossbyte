package crossbyte._internal.deflatex;

import haxe.ds.Vector;

/**
 * Implements a Huffman code table.
 */
class HuffmanTable {
	/** An array of codes. */
	public var code:Vector<Int>;

	/** An array of codelengths. */
	public var codeLen:Vector<Int>;

	/**
	 * Create a new Huffman table.
	 * @param numSymbols The total number of symbols
	 */
	public function new(numSymbols:Int) {
		code = new Vector<Int>(numSymbols);
		codeLen = new Vector<Int>(numSymbols);
		#if !static
		for (i in 0...numSymbols) {
			code[i] = 0;
			codeLen[i] = 0;
		}
		#end
	}

	/**
	 * Pack the given codelength arrays.
	 * @param litCodeLen The literal codelengths
	 * @param distCodeLen The distance codelengths
	 * @return The packed codelengths
	 */
	public static function packCodeLengths(litCodeLen:Vector<Int>, distCodeLen:Vector<Int>):Array<Int> {
		var lengths:Array<Int> = new Array<Int>();
		pack(lengths, litCodeLen);
		pack(lengths, distCodeLen);
		return lengths;
	}

	private static function pack(lengths:Array<Int>, codeLen:Vector<Int>) {
		var n:Int = codeLen.length;

		var last:Int = codeLen[0];
		var runLength:Int = 1;
		for (i in 1...n + 1) {
			if (i < n && codeLen[i] == last) {
				runLength++;
			} else {
				lengths.push(last);
				runLength--;
				if (last == 0) {
					var j:Int = 138;
					while (j >= 11) {
						if ((runLength - j) >= 0) {
							lengths.push(18);
							lengths.push(j - 11);
							runLength -= j;
						} else {
							j--;
						}
					}
					while (j >= 3) {
						if ((runLength - j) >= 0) {
							lengths.push(17);
							lengths.push(j - 3);
							runLength -= j;
						} else {
							j--;
						}
					}
				} else {
					var j:Int = 6;
					while (j >= 3) {
						if ((runLength - j) >= 0) {
							lengths.push(16);
							lengths.push(j - 3);
							runLength -= j;
						} else {
							j--;
						}
					}
				}
				while (runLength > 0) {
					lengths.push(last);
					runLength--;
				}
				if (i < n) {
					last = codeLen[i];
					runLength = 1;
				}
			}
		}
	}

	/*
	 * Default Huffman code tables (see RFC 1951, section 3.2.6)
	 * Fixed literal codes
	 */
	public static var LIT(default, null):HuffmanTable = createLIT();

	private static function createLIT():HuffmanTable {
		var lit:HuffmanTable = new HuffmanTable(286);
		var nextCode:Int = 0;
		for (i in 256...280) {
			lit.code[i] = nextCode++;
			lit.codeLen[i] = 7;
		}
		nextCode <<= 1;
		for (i in 0...144) {
			lit.code[i] = nextCode++;
			lit.codeLen[i] = 8;
		}
		for (i in 280...286) {
			lit.code[i] = nextCode++;
			lit.codeLen[i] = 8;
		}
		nextCode += 2;
		nextCode <<= 1;
		for (i in 144...256) {
			lit.code[i] = nextCode++;
			lit.codeLen[i] = 9;
		}
		return lit;
	}

	/*
	 * Default Huffman code tables (see RFC 1951, section 3.2.6)
	 * Fixed distance codes
	 */
	public static var DIST(default, null):HuffmanTable = createDIST();

	private static function createDIST():HuffmanTable {
		var dist:HuffmanTable = new HuffmanTable(30);
		for (i in 0...30) {
			dist.code[i] = i;
			dist.codeLen[i] = 5;
		}
		return dist;
	}
}
