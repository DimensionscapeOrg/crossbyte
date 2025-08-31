package crossbyte._internal.deflatex;

import haxe.Constraints.IMap;
import haxe.ds.BalancedTree;
import haxe.io.Bytes;
import haxe.Exception;
import crossbyte._internal.deflatex.utils.BitsOutput;
import crossbyte._internal.deflatex.utils.BitsInput;
import haxe.ds.Vector;

/**
 * Inflates a given stream of compressed data.
 */
class Inflater {
	private static var INSTANCE:Inflater = new Inflater();

	private static final END_OF_BLOCK:Int = 256;
	private static final LEN_ORDER:Vector<Int> = Vector.fromArrayCopy([16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]);
	private static final N_LITERALS:Int = 286;
	private static final N_DISTANCES:Int = 30;
	private static final N_LENGTHS:Int = 19;

	private var crc:CRC32;
	private var window:LZWindow;
	private var litCodes:Array<Int>;
	private var litCodeMap:IMap<Int, Array<Int>>;
	private var distCodes:Array<Int>;
	private var distCodeMap:IMap<Int, Array<Int>>;
	private var lenCodes:Array<Int>;
	private var lenCodeMap:IMap<Int, Array<Int>>;

	/**
	 * Create a new Inflater.
	 */
	public function new() {
		crc = new CRC32();
		window = new LZWindow(32768);
	}

	/**
	 * CRC value extracted from the last decompression
	 */
	public var CRC(get, never):Int;

	function get_CRC():Int {
		return crc.value;
	}

	/**
	 * Applies the inflate decompression on the supplied stream.
	 * @return Bytes with the uncompressed data
	 */
	public function decompress(stream:Bytes):Bytes {
		var input:BitsInput = new BitsInput(stream);
		var output:BitsOutput = new BitsOutput();
		while (true) {
			var bfinal:Int = input.readBits(1);
			var btype:Int = input.readBits(2);

			if (btype == 0) {
				input.clearBits();
				processUncompressedBlock(input, output);
			} else if (btype == 1) {
				loadDefaultCodes();
				processHuffmanBlock(input, output);
			} else if (btype == 2) {
				readCodes(input, output);
				processHuffmanBlock(input, output);
			} else {
				throw new Exception("Invalid block type");
			}

			if (bfinal == 1)
				break;
		}

		return output.getBytes();
	}

	private function processUncompressedBlock(input:BitsInput, output:BitsOutput) {
		var len:Int = input.readInt16();
		var nlen:Int = input.readInt16() ^ 0xffff;
		if (nlen != len) {
			throw new Exception("Invalid block length");
		}

		var b:Bytes = Bytes.alloc(len);
		input.readBytes(b, 0, len);

		crc.updateBytes(b, 0, len);
		window.addBytes(b, 0, len);

		output.writeBytes(b, 0, len);
	}

	private function loadDefaultCodes() {
		litCodes = new Array<Int>();
		for (i in 0...N_LITERALS) {
			litCodes.push(HuffmanTable.LIT.code[i]);
		}
		litCodeMap = buildCodeMap(litCodes, HuffmanTable.LIT.codeLen);

		distCodes = new Array<Int>();
		for (i in 0...N_DISTANCES) {
			distCodes.push(HuffmanTable.DIST.code[i]);
		}
		distCodeMap = buildCodeMap(distCodes, HuffmanTable.DIST.codeLen);
	}

	private function readCodes(input:BitsInput, output:BitsOutput) {
		var numUsedLiterals:Int = 257 + input.readBits(5);
		var numUsedDistances:Int = 1 + input.readBits(5);
		var numUsedLengths:Int = 4 + input.readBits(4);

		var lenCodeLen:Vector<Int> = new Vector<Int>(N_LENGTHS);
		#if !static
		for (i in 0...N_LENGTHS)
			lenCodeLen[i] = 0;
		#end
		for (i in 0...numUsedLengths) {
			lenCodeLen[LEN_ORDER[i]] = input.readBits(3);
		}

		lenCodes = buildCodes(lenCodeLen);
		lenCodeMap = buildCodeMap(lenCodes, lenCodeLen);

		// Unpack literal/distance codelengths
		var len:Int = numUsedLiterals + numUsedDistances;
		var lengths:Vector<Int> = new Vector<Int>(len);
		var i:Int = 0;
		while (i < len) {
			var sym:Int = readSymbol(input, lenCodes, lenCodeMap);
			if (sym == 16) {
				var n:Int = 3 + input.readBits(2);
				for (j in 0...n) {
					lengths[i + j] = lengths[i - 1];
				}
				i += (n - 1);
			} else if (sym == 17 || sym == 18) {
				var n:Int = 0;
				if (sym == 17) {
					n = 3 + input.readBits(3);
				} else {
					n = 11 + input.readBits(7);
				}
				for (j in 0...n) {
					lengths[i + j] = 0;
				}
				i += (n - 1);
			} else {
				lengths[i] = sym;
			}
			i++;
		}

		var litCodeLen:Vector<Int> = new Vector<Int>(N_LITERALS);
		#if !static
		for (i in 0...N_LITERALS)
			litCodeLen[i] = 0;
		#end
		for (i in 0...numUsedLiterals) {
			litCodeLen[i] = lengths[i];
		}

		litCodes = buildCodes(litCodeLen);
		litCodeMap = buildCodeMap(litCodes, litCodeLen);

		var distCodeLen:Vector<Int> = new Vector<Int>(N_DISTANCES);
		#if !static
		for (i in 0...N_DISTANCES)
			distCodeLen[i] = 0;
		#end
		for (i in 0...numUsedDistances) {
			distCodeLen[i] = lengths[numUsedLiterals + i];
		}

		distCodes = buildCodes(distCodeLen);
		distCodeMap = buildCodeMap(distCodes, distCodeLen);
	}

	private function processHuffmanBlock(input:BitsInput, output:BitsOutput) {
		while (true) {
			var litSym:Int = readSymbol(input, litCodes, litCodeMap);

			if (litSym < END_OF_BLOCK) {
				var b:Int = litSym;

				crc.updateByte(b);
				window.addByte(b);

				output.writeByte(b);
			} else if (litSym == END_OF_BLOCK) {
				break;
			} else {
				var lenSym:Int = Std.int(litSym - 257);
				var len:Int = LZPair.SYMBOLS.lenLower[lenSym] + input.readBits(LZPair.SYMBOLS.lenNBits[lenSym]);

				var distSym:Int = readSymbol(input, distCodes, distCodeMap);
				var dist:Int = LZPair.SYMBOLS.distLower[distSym] + input.readBits(LZPair.SYMBOLS.distNBits[distSym]);

				var b:Bytes = window.getBytes(dist, len);

				crc.updateAllBytes(b);
				window.addAllBytes(b);

				output.write(b);
			}
		}
	}

	private function readSymbol(input:BitsInput, codes:Array<Int>, codeMap:IMap<Int, Array<Int>>):Int {
		var code:Int = 0;
		var codeLen:Int = 0;
		var index:Int = -1;

		do {
			if (codeLen == 15) {
				throw new Exception("Couldn't find code");
			}

			code <<= 1;
			code |= input.readBits(1);
			codeLen++;

			var codeList:Array<Int> = codeMap.get(codeLen);
			if (codeList != null) {
				index = codeList.indexOf(code);
			}
		} while (index == -1);

		for (i in 0...codes.length) {
			if (codes[i] == code)
				return i;
		}

		return -1;
	}

	private function buildCodes(codeLen:Vector<Int>):Array<Int> {
		var n:Int = codeLen.length;
		var codes:Vector<Int> = new Vector<Int>(n);
		for (i in 0...n)
			codes[i] = -1;

		var lengthSet:BalancedTree<Int, Int> = new BalancedTree<Int, Int>();
		for (i in 0...n) {
			if (codeLen[i] > 0) {
				var l:Int = codeLen[i];
				lengthSet.set(l, l);
			}
		}

		var nextCode:Int = 0;
		var lastShift:Int = 0;

		for (length in lengthSet) {
			nextCode <<= (length - lastShift);
			lastShift = length;

			for (i in 0...n) {
				if (codeLen[i] == length) {
					codes[i] = nextCode++;
				}
			}
		}

		return codes.toArray();
	}

	private function buildCodeMap(codes:Array<Int>, codeLen:Vector<Int>):IMap<Int, Array<Int>> {
		var n:Int = codeLen.length;
		var codeMap:IMap<Int, Array<Int>> = new BalancedTree<Int, Array<Int>>();

		for (i in 0...n) {
			var len:Int = codeLen[i];
			if (len > 0) {
				var codeList:Array<Int> = codeMap.get(len);
				if (codeList == null) {
					codeList = new Array<Int>();
					codeMap.set(len, codeList);
				}
				var code:Int = codes[i];
				codeList.push(code);
			}
		}

		return codeMap;
	}

	/**
	 * Applies inflate decompression on the supplied bytes.
	 * @return Decompressed output
	 */
	public static function apply(stream:Bytes):Bytes {
		return INSTANCE.decompress(stream);
	}
}
