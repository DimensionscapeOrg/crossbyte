package crossbyte._internal.deflatex;

import haxe.ds.Vector;

/**
 * The length and distance ranges of RFC 1951 section 3.2.5. Built from
 * nothing but constants, so a class can make its own during its static
 * initialisation.
 */
class Symbols {
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
