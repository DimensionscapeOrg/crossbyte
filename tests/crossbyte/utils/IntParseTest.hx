package crossbyte.utils;

import utest.Assert;

/**
 * `IntParse` gives one answer on every target, where `Std.parseInt` gives
 * four: past 32 bits it truncates on Linux and macOS native, clamps on
 * Windows native, throws on the jvm and returns a wider-than-Int number on
 * JavaScript. Each oversized case below would read as a real length through
 * `Std.parseInt` on at least one of them.
 */
class IntParseTest extends utest.Test {
	public function testDecimalReadsPlainDigits():Void {
		Assert.equals(0, IntParse.decimal("0"));
		Assert.equals(42, IntParse.decimal("42"));
		Assert.equals(7, IntParse.decimal("007"));
		Assert.equals(42, IntParse.decimal("0000000000000000042"));
		Assert.equals(2147483647, IntParse.decimal("2147483647"));
	}

	public function testDecimalRefusesWhatDoesNotFit():Void {
		// 4294967296 is 0 on Linux native through Std.parseInt, and 4294967396
		// is 100: a Content-Length that reads as a small one.
		Assert.equals(-1, IntParse.decimal("2147483648"));
		Assert.equals(-1, IntParse.decimal("4294967295"));
		Assert.equals(-1, IntParse.decimal("4294967296"));
		Assert.equals(-1, IntParse.decimal("4294967396"));
		Assert.equals(-1, IntParse.decimal("99999999999"));
		Assert.equals(-1, IntParse.decimal("18446744073709551716"));
	}

	public function testDecimalRefusesAnythingButDigits():Void {
		Assert.equals(-1, IntParse.decimal(null));
		Assert.equals(-1, IntParse.decimal(""));
		Assert.equals(-1, IntParse.decimal("-1"));
		Assert.equals(-1, IntParse.decimal("+1"));
		Assert.equals(-1, IntParse.decimal(" 1"));
		Assert.equals(-1, IntParse.decimal("1 "));
		Assert.equals(-1, IntParse.decimal("1a"));
		Assert.equals(-1, IntParse.decimal("0x10"));
		Assert.equals(-1, IntParse.decimal("1.5"));
		Assert.equals(-1, IntParse.decimal("１"));
	}

	public function testDecimalHonoursTheBound():Void {
		Assert.equals(1048576, IntParse.decimal("1048576", 1048576));
		Assert.equals(-1, IntParse.decimal("1048577", 1048576));
		Assert.equals(-1, IntParse.decimal("10485760", 1048576));
		Assert.equals(0, IntParse.decimal("0", 0));
		Assert.equals(-1, IntParse.decimal("1", 0));
		Assert.equals(9, IntParse.decimal("9", 9));
		Assert.equals(-1, IntParse.decimal("10", 9));
		Assert.equals(-1, IntParse.decimal("0", -1));
	}

	public function testHexReadsEitherCase():Void {
		Assert.equals(0, IntParse.hex("0"));
		Assert.equals(255, IntParse.hex("ff"));
		Assert.equals(255, IntParse.hex("FF"));
		Assert.equals(0xABCDEF, IntParse.hex("aBcDeF"));
		Assert.equals(255, IntParse.hex("00000000000ff"));
		Assert.equals(0x7FFFFFFF, IntParse.hex("7fffffff"));
	}

	public function testHexRefusesWhatDoesNotFit():Void {
		// FFFFFFFF is -1 on eval and cpp through Std.parseInt("0x" + h), a
		// throw on the jvm, and 4294967295 on Node.
		Assert.equals(-1, IntParse.hex("80000000"));
		Assert.equals(-1, IntParse.hex("FFFFFFFF"));
		Assert.equals(-1, IntParse.hex("100000000"));
		Assert.equals(-1, IntParse.hex("FFFFFFFFFF"));
		Assert.equals(268435455, IntParse.hex("FFFFFFF", 0xFFFFFFF));
		Assert.equals(-1, IntParse.hex("10000000", 0xFFFFFFF));
	}

	public function testHexRefusesAnythingButHexDigits():Void {
		Assert.equals(-1, IntParse.hex(null));
		Assert.equals(-1, IntParse.hex(""));
		Assert.equals(-1, IntParse.hex("0x1f"));
		Assert.equals(-1, IntParse.hex("g"));
		Assert.equals(-1, IntParse.hex("-1"));
		Assert.equals(-1, IntParse.hex("1f;ext"));
		Assert.equals(-1, IntParse.hex("1f "));
	}
}
