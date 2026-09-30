package crossbyte.ds;

import utest.Assert;

class OrderedMapTest extends utest.Test {
	public function testIteratorPreservesInsertionOrderAndValues():Void {
		var map = new crossbyte.ds.OrderedMap<String, Int>();
		map.set("a", 1);
		map.set("b", 2);
		map.set("c", 3);

		var values = [];
		for (v in map.iterator()) {
			values.push(v);
		}
		Assert.same([1, 2, 3], values);
	}

	public function testKeyValuePairsPreservesInsertionOrderAndValues():Void {
		var map = new crossbyte.ds.OrderedMap<String, Int>();
		map.set("x", 10);
		map.set("y", 20);
		map.set("z", 30);

		var keys = [];
		var vals = [];
		var pairs = map.keyValuePairs();
		while (pairs.hasNext()) {
			var pair = pairs.next();
			keys.push(pair.key);
			vals.push(pair.value);
		}
		Assert.same(["x", "y", "z"], keys);
		Assert.same([10, 20, 30], vals);
	}

	public function testRepeatedIterationYieldsSameSequence():Void {
		var map = new crossbyte.ds.OrderedMap<String, Int>();
		map.set("a", 1);
		map.set("b", 2);

		var first = [];
		for (v in map.iterator()) {
			first.push(v);
		}
		var second = [];
		for (v in map.iterator()) {
			second.push(v);
		}
		Assert.same([1, 2], first);
		Assert.same([1, 2], second);
	}

	public function testMutationThenReIterate():Void {
		var map = new crossbyte.ds.OrderedMap<String, Int>();
		map.set("a", 1);
		map.set("b", 2);
		map.set("c", 3);

		// Update an existing key (must keep its original position and new value).
		map.set("b", 99);
		// Append a new key.
		map.set("d", 4);
		// Remove a middle key.
		map.remove("a");

		var keys = [];
		var vals = [];
		var pairs = map.keyValuePairs();
		while (pairs.hasNext()) {
			var pair = pairs.next();
			keys.push(pair.key);
			vals.push(pair.value);
		}
		Assert.same(["b", "c", "d"], keys);
		Assert.same([99, 3, 4], vals);

		var iterValues = [];
		for (v in map.iterator()) {
			iterValues.push(v);
		}
		Assert.same([99, 3, 4], iterValues);
	}

	public function testEmptyMapIterators():Void {
		var map = new crossbyte.ds.OrderedMap<String, Int>();
		Assert.isFalse(map.iterator().hasNext());
		Assert.isFalse(map.keyValuePairs().hasNext());
	}

	/**
		Removing entries while iterating visits every entry once, in order.
		The iterators walked the array of keys, which a removal shifted under
		them: removing every even value visited 3 of 6.
	**/
	public function testRemovingWhileIteratingVisitsEveryEntryOnce():Void {
		var map = new crossbyte.ds.OrderedMap<String, Int>();
		for (i in 0...6) {
			map.set('k$i', i);
		}
		var seen:Array<Int> = [];
		for (v in map) {
			seen.push(v);
			if (v % 2 == 0) {
				map.remove('k$v');
			}
		}
		Assert.same([0, 1, 2, 3, 4, 5], seen);
		Assert.same(["k1", "k3", "k5"], [for (k in map.keysIterator()) k]);
		Assert.equals(3, map.length());

		// An entry removed before the loop reaches it is not visited, and the
		// loop goes on past it.
		var keys:Array<String> = [];
		for (pair in map.keyValuePairs()) {
			keys.push(pair.key);
			if (pair.key == "k1") {
				map.remove("k3");
			}
		}
		Assert.same(["k1", "k5"], keys);

		// Clearing inside a loop ends it.
		for (i in 0...4) {
			map.set('c$i', i);
		}
		var visited:Int = 0;
		for (_ in map) {
			visited++;
			map.clear();
		}
		Assert.equals(1, visited);
		Assert.equals(0, map.length());
		Assert.isFalse(map.iterator().hasNext());
	}

	/** Positions count along the order, removals included. **/
	public function testPositionsFollowTheOrder():Void {
		var map = new crossbyte.ds.OrderedMap<String, Int>();
		for (i in 0...5) {
			map.set('k$i', i * 10);
		}
		map.remove("k1");
		Assert.equals(20, map.ofIndex(1));
		Assert.equals(40, map.ofIndex(3));
		Assert.isNull(map.ofIndex(4));
		Assert.isNull(map.ofIndex(-1));
		Assert.equals(2, map.indexOf("k3"));
		Assert.equals(-1, map.indexOf("k1"));
		Assert.equals(-1, map.indexOf("k0", 1));
		Assert.equals(3, map.indexOf("k4", -1));
		map.set("k1", 5);
		Assert.equals(4, map.indexOf("k1"));
		Assert.same([0, 20, 30, 40, 5], [for (v in map) v]);
	}

	/**
		`remove` unlinks an entry rather than searching and shifting an array
		of keys, whose search from the front made removing the newest first
		the worst case: 20,000 removals took 332 ms on the jvm and 802 ms on
		Node, where a linked removal takes 3 ms on the jvm and 9 on eval. The
		bound sits between the two, fifteen times above the slowest target's.
	**/
	public function testRemovingIsNotAPassOverTheKeys():Void {
		var map = new crossbyte.ds.OrderedMap<String, Int>();
		var n:Int = 20000;
		var keys:Array<String> = [for (i in 0...n) 'k$i'];
		for (i in 0...n) {
			map.set(keys[i], i);
		}
		var started:Float = haxe.Timer.stamp();
		for (i in 0...n) {
			map.remove(keys[n - 1 - i]);
		}
		var took:Float = haxe.Timer.stamp() - started;
		Assert.equals(0, map.length());
		Assert.isTrue(took < 0.15, n + " removals took " + took + " s");
	}
}
