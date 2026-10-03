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
