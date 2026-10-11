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
		Iterators walking the array of keys, which a removal shifts under them,
		would visit 3 of 6 when every even value is removed.
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
		of keys, whose search from the front would make removing the newest
		first the worst case: 20,000 such removals take 332 ms on the jvm and
		802 ms on Node, where a linked removal takes 3 ms on the jvm and 9 on
		eval. The bound sits between the two, fifteen times above the slowest
		target's.
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

	/**
		`for (key => value in map)` walks the pairs in insertion order, and
		follows removals as the other loops do. The iterators still fit where
		an `Iterator` is asked for, and so do the functions making them.
	**/
	public function testAKeyValueLoopWalksTheOrder():Void {
		var map = new crossbyte.ds.OrderedMap<String, Int>();
		for (i in 0...5) {
			map.set('k$i', i);
		}
		map.remove("k1");
		map.set("k1", 10);
		var walked:Array<String> = [];
		for (key => value in map) {
			walked.push(key + "=" + value);
			if (key == "k2") {
				map.remove("k3");
			}
		}
		Assert.same(["k0=0", "k2=2", "k4=4", "k1=10"], walked);

		var values:Iterator<Int> = map.iterator();
		var keys:Iterator<String> = map.keysIterator();
		var pairs:Iterator<crossbyte.ds.ListedMap.KeyValuePair<String, Int>> = map.keyValuePairs();
		var making:Void->Iterator<Int> = map.iterator;
		Assert.equals(0, values.next());
		Assert.equals("k0", keys.next());
		Assert.equals("k0", pairs.next().key);
		Assert.equals(0, making().next());
	}

	/**
		A `for` loop over the values, the keys or the pairs of an `OrderedMap`
		allocates nothing, natively and on the jvm. Each returned an
		`Iterator` structure made of two objects, which natively also made a
		closure for every `hasNext` and `next` called through it: 728 bytes a
		loop over eight entries.
	**/
	public function testALoopOverAnOrderedMapAllocatesNothing():Void {
		#if (cpp || jvm)
		var map = new crossbyte.ds.OrderedMap<String, Int>();
		for (i in 0...100) {
			map.set('k$i', i);
		}
		var sum:Int = 0;
		var loops:Array<Void->Void> = [
			() -> for (value in map) sum += value,
			() -> for (key in map.keysIterator()) sum += key.length,
			() -> for (key => value in map) sum += key.length + value
		];
		for (loop in loops) {
			for (_ in 0...20000) {
				loop();
			}
			var reading = crossbyte.test.AllocationMeter.measure(loop, 2000, 3);
			Assert.equals(0.0, reading.perOperation, "a loop allocated " + reading);
		}
		Assert.isTrue(sum > 0);
		#else
		Assert.pass();
		#end
	}

	/**
		Reading, testing and replacing a held key allocates nothing natively:
		through `haxe.IMap` a String key, or an Int one past 255, was boxed for
		every call (32 bytes a `get` of a String key). An `Int` value is held
		boxed, so setting one past 255 still boxes it, and reading it does not.
	**/
	public function testAnOrderedMapLookupAllocatesNothingNatively():Void {
		#if cpp
		var strings = new crossbyte.ds.OrderedMap<String, Int>();
		var ints = new crossbyte.ds.OrderedMap<Int, Int>();
		var named = new crossbyte.ds.OrderedMap<String, Array<Int>>();
		var keys:Array<String> = [for (i in 0...1000) 'k$i'];
		var held:Array<Int> = [1];
		for (i in 0...1000) {
			strings.set(keys[i], i);
			ints.set(i * 7, i);
			named.set(keys[i], held);
		}
		var at:Int = 0;
		var sum:Int = 0;
		var ops:Array<Void->Void> = [
			() -> sum += strings.get(keys[(at = (at + 7) % 1000)]),
			() -> if (strings.exists(keys[(at = (at + 7) % 1000)])) sum++,
			() -> named.set(keys[(at = (at + 7) % 1000)], held),
			() -> sum += ints.get((at = (at + 7) % 1000) * 7),
			() -> if (ints.exists((at = (at + 7) % 1000) * 7)) sum++
		];
		for (op in ops) {
			for (_ in 0...20000) {
				op();
			}
			var reading = crossbyte.test.AllocationMeter.measure(op, 2000, 3);
			Assert.equals(0.0, reading.perOperation, "a lookup allocated " + reading);
		}
		Assert.isTrue(sum > 0);
		#else
		Assert.pass();
		#end
	}
}
