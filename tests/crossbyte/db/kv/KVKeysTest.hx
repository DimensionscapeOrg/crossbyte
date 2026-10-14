package crossbyte.db.kv;

import crossbyte.db.kv._internal.KVKeys;
import crossbyte.db.kv._internal.SortedKeys;
import haxe.io.Bytes;
import utest.Assert;

/**
	The order keys sort in and the rules a key keeps, on every target: by
	code point, as their UTF-8 bytes sort, which is what SQLite and
	PostgreSQL's "C" collation compare, whatever the target holds a string as.
**/
class KVKeysTest extends utest.Test {
	// Written as literals: each target holds one as its own text, where
	// String.fromCharCode makes a byte of anything past 127 on neko.
	static final PIECES:Array<String> = [
		"a", "b", "z", "A", "0", "/", " ", "~", "\u{7F}", "\u{80}", "\u{E9}", "\u{7FF}", "\u{800}", "\u{D7FF}", "\u{E000}", "\u{FFFD}", "\u{FFFF}",
		"\u{10000}", "\u{1F600}", "\u{1F601}", "\u{10FFFD}", "\u{1}"
	];

	public function testKeysCompareAsTheirUtf8Bytes():Void {
		var random = new Steps(20261014);
		var wrong:Array<String> = [];

		for (n in 0...2000) {
			var a:String = __random(random);
			var b:String = random.below(4) == 0 ? a + __random(random) : __random(random);
			var expected:Int = __sign(__compareBytes(Bytes.ofString(a), Bytes.ofString(b)));
			var got:Int = __sign(KVKeys.compare(a, b));

			if ((expected != got || __sign(KVKeys.compare(b, a)) != -got) && wrong.length < 5) {
				wrong.push('${haxe.io.Bytes.ofString(a).toHex()} against ${haxe.io.Bytes.ofString(b).toHex()}: $got, not $expected');
			}
		}

		Assert.same([], wrong);
		Assert.equals(0, KVKeys.compare("\u{1F600}x", "\u{1F600}x"));
		Assert.isTrue(KVKeys.compare("\u{FFFD}", "\u{1F600}") < 0, "U+FFFD before U+1F600, as UTF-8 has them");
		Assert.isTrue(KVKeys.compare("\u{E000}", "\u{10000}") < 0);
		Assert.isTrue(KVKeys.compare("ab", "abc") < 0);
		Assert.isTrue(KVKeys.compare("", "a") < 0);
	}

	public function testEveryKeyIsBelowTheEnd():Void {
		for (piece in PIECES) {
			Assert.isTrue(KVKeys.compare(piece + "\u{10FFFD}\u{10FFFD}", KVKeys.END) < 0, piece);
			Assert.isTrue(KVKeys.compare("p" + piece + "\u{10FFFD}", "p" + KVKeys.END) < 0, piece);
			// And the successor is the first key after one.
			Assert.isTrue(KVKeys.compare(piece, piece + KVKeys.SUCCESSOR) < 0);
		}
	}

	public function testAKeysSizeIsItsUtf8():Void {
		for (piece in PIECES) {
			var size:Int = Bytes.ofString(piece).length;
			KVKeys.check(piece, size, "key", false);
			Assert.raises(() -> KVKeys.check(piece + "x", size, "key", false), crossbyte.errors.ArgumentError);
		}

		KVKeys.check("", 1, "prefix", true);
		Assert.raises(() -> KVKeys.check("", 1, "key", false), crossbyte.errors.ArgumentError);
	}

	public function testSortedKeysKeepOrderAcrossRuns():Void {
		var keys = new SortedKeys();
		var random = new Steps(7);
		var held:Map<String, Bool> = new Map();

		for (n in 0...6000) {
			var key:String = "k" + random.below(4000);

			if (held.exists(key)) {
				Assert.isTrue(keys.remove(key));
				held.remove(key);
			} else {
				keys.insert(key);
				held.set(key, true);
			}
		}

		var expected:Array<String> = [for (key in held.keys()) key];
		expected.sort(KVKeys.compare);
		var cursor = keys.from("");
		var got:Array<String> = [];

		while (cursor.hasNext()) {
			got.push(cursor.next());
		}

		Assert.same(expected, got);
		Assert.equals(expected.length, keys.length);
		Assert.isFalse(keys.remove("absent"));

		var from = keys.from(expected[10]);
		Assert.isTrue(from.hasNext());
		Assert.equals(expected[10], from.next());
		Assert.isFalse(keys.from(expected[expected.length - 1] + "z").hasNext());
	}

	static function __random(random:Steps):String {
		var out:String = "";

		for (i in 0...1 + random.below(5)) {
			out += PIECES[random.below(PIECES.length)];
		}

		return out;
	}

	static function __compareBytes(a:Bytes, b:Bytes):Int {
		var shorter:Int = a.length < b.length ? a.length : b.length;

		for (i in 0...shorter) {
			if (a.get(i) != b.get(i)) {
				return a.get(i) - b.get(i);
			}
		}

		return a.length - b.length;
	}

	static inline function __sign(n:Int):Int {
		return n < 0 ? -1 : (n > 0 ? 1 : 0);
	}
}

/**
	A fixed sequence of numbers, the same on every target: small enough that
	no product passes 2^31, so PHP and JavaScript, whose Ints do not wrap as
	32 bits do, give it as every other target does.
**/
private class Steps {
	var __state:Int;

	public function new(seed:Int) {
		__state = seed % 65521;
	}

	public function below(bound:Int):Int {
		__state = (__state * 75 + 74) % 65537;
		return __state % bound;
	}
}
