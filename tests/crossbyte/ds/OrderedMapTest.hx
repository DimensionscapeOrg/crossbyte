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
}
