package crossbyte.ds;

import utest.Assert;

class CollectionsTest extends utest.Test {
	public function testBloomFilterFindsAddedItems():Void {
		var filter = new BloomFilter(128, 3);

		Assert.isFalse(filter.contains("alpha"));
		filter.add("alpha");
		Assert.isTrue(filter.contains("alpha"));
	}

	public function testBitSetSupportsGrowthMutationAndLogicalLength():Void {
		var bits = new BitSet(5);

		Assert.equals(5, bits.length);
		Assert.isFalse(bits.get(0));
		Assert.isFalse(bits.get(4));
		Assert.isFalse(bits.get(99));

		bits.set(1, true);
		bits.flip(4);
		Assert.isTrue(bits.get(1));
		Assert.isTrue(bits.get(4));
		Assert.equals(2, bits.countSetBits());

		bits.clear(1);
		Assert.isFalse(bits.get(1));
		Assert.equals(1, bits.countSetBits());

		bits.set(40, true);
		Assert.isTrue(bits.get(40));
		Assert.isTrue(bits.length >= 41);

		var logical = new BitSet(5);
		logical.setAll();
		Assert.equals(5, logical.countSetBits());

		logical.length = 3;
		Assert.equals(3, logical.countSetBits());

		logical.clearAll();
		Assert.equals(0, logical.countSetBits());
	}

	public function testVectorSpliceReturnsRemovedAndKeepsInsertOrder():Void {
		var vector = new Vector<String>();
		vector.push("a");
		vector.push("b");
		vector.push("c");

		var removed = vector.splice(1, 1, "x", "y");

		Assert.equals("b", removed.join(","));
		Assert.equals("a,x,y,c", vector.join(","));
	}

	public function testVectorIterationPredicatesAndMappingWork():Void {
		var vector = new Vector<Int>();
		vector.push(1);
		vector.push(2);
		vector.push(3);

		var seen = [];
		vector.forEach((value:Int, index:Int) -> seen.push(index + ":" + value));

		Assert.equals("0:1,1:2,2:3", seen.join(","));
		Assert.isTrue(vector.every((value:Int) -> value > 0));
		Assert.isTrue(vector.some((value:Int) -> value == 2));
		Assert.isFalse(vector.some((value:Int) -> value == 99));

		var mapped = vector.map((value:Int, index:Int) -> value + index);
		var filtered = vector.filter((value:Int) -> value % 2 == 1);

		Assert.equals("1,3,5", mapped.join(","));
		Assert.equals("1,3", filtered.join(","));
	}

	public function testVectorConcatAndSortBehaveLikeArrayHelpers():Void {
		var vector = new Vector<Int>();
		vector.push(3);
		vector.push(1);

		var other = new Vector<Int>();
		other.push(4);
		var tail = new Vector<Int>();
		tail.push(2);
		tail.push(5);

		var concatenated = vector.concat(other, tail);
		Assert.equals("3,1,4,2,5", concatenated.join(","));
		Assert.equals("3,1", vector.join(","));

		vector.sort((a:Int, b:Int) -> a - b);
		Assert.equals("1,3", vector.join(","));

		concatenated.sort(null);
		Assert.equals("1,2,3,4,5", concatenated.join(","));
	}

	public function testDequeSupportsDoubleEndedAccessAndSizing():Void {
		var deque = new Deque<String>();
		deque.add("tail");
		deque.add("head");
		deque.push("last");

		Assert.isFalse(deque.isEmpty());
		Assert.equals(3, deque.size());
		Assert.equals("head", deque.first());
		Assert.equals("last", deque.last());
		Assert.equals("head", deque.pop());
		Assert.equals("last", deque.remove());
		Assert.equals("tail", deque.pop());
		Assert.isTrue(deque.isEmpty());
		Assert.raises(() -> deque.pop());
		Assert.raises(() -> deque.remove());
		Assert.raises(() -> deque.first());
		Assert.raises(() -> deque.last());
	}

	public function testPriorityQueueSupportsUpdateRemoveAndClear():Void {
		var low = {priority: 5, name: "low"};
		var mid = {priority: 3, name: "mid"};
		var high = {priority: 1, name: "high"};
		var queue = new PriorityQueue<{priority:Int, name:String}>((a, b) -> a.priority - b.priority);

		queue.enqueue(low);
		queue.enqueue(mid);
		queue.enqueue(high);

		Assert.equals("high", queue.peek().name);
		Assert.isTrue(queue.contains(mid));

		low.priority = 0;
		queue.update(low);
		Assert.equals("low", queue.peek().name);

		high.priority = 6;
		queue.enqueue(high);
		Assert.equals(3, queue.size);

		Assert.equals("low", queue.dequeue().name);
		Assert.isTrue(queue.remove(mid));
		Assert.isFalse(queue.contains(mid));
		Assert.equals(1, queue.size);

		queue.clear();
		Assert.isTrue(queue.isEmpty);
		Assert.isNull(queue.peek());
	}

	public function testOrderedMapPreservesInsertionOrderAcrossUpdatesAndReinserts():Void {
		var map = new OrderedMap<String, Int>();
		map.set("a", 1);
		map.set("b", 2);
		map.set("a", 3);

		var keys = [];
		for (key in map.keysIterator()) {
			keys.push(key);
		}
		Assert.equals("a,b", keys.join(","));

		var values = [];
		for (value in map) {
			values.push(value);
		}
		Assert.equals("3,2", values.join(","));

		Assert.equals(3, map.get("a"));
		Assert.equals(0, map.indexOf("a"));
		Assert.equals(2, map.ofIndex(1));

		Assert.isTrue(map.remove("a"));
		map.set("a", 4);

		var pairs = [];
		for (pair in map.keyValuePairs()) {
			pairs.push(pair.key + "=" + pair.value);
		}
		Assert.equals("b=2,a=4", pairs.join(","));
		Assert.equals(2, map.length());
	}

	public function testIndexedMapMaintainsDenseStorageAcrossRemoval():Void {
		var map = new IndexedMap<String>();
		map.add("ten", 10);
		map.add("twenty", 20);
		map.set(30, "thirty");

		Assert.equals(3, map.length());
		Assert.equals("ten", map.get(10));
		Assert.equals("thirty", map.get(30));
		Assert.isTrue(map.exists(20));

		Assert.isTrue(map.remove(20));
		Assert.isFalse(map.exists(20));
		Assert.equals(2, map.length());
		Assert.isFalse(map.remove(20));

		var keys = map.keys();
		keys.sort((a, b) -> a - b);
		Assert.equals("10,30", keys.join(","));

		var values = map.toArray();
		values.sort((a, b) -> Reflect.compare(a, b));
		Assert.equals("ten,thirty", values.join(","));

		map.clear();
		Assert.equals(0, map.length());
		Assert.equals(0, map.keys().length);
	}

	public function testDenseSetSupportsPackedRemovalAndLookup():Void {
		var set = new DenseSet<String>();

		Assert.isTrue(set.isEmpty);
		Assert.isTrue(set.add("a"));
		Assert.isTrue(set.add("b"));
		Assert.isFalse(set.add("a"));
		Assert.equals(2, set.length);
		Assert.isTrue(set.contains("a"));
		Assert.isTrue(set.contains("b"));
		Assert.equals(0, set.indexOf("a"));

		Assert.isTrue(set.remove("a"));
		Assert.isFalse(set.contains("a"));
		Assert.equals(1, set.length);
		Assert.equals("b", set.valueAt(0));
		Assert.isFalse(set.remove("missing"));
		Assert.isFalse(set.removeAt(-1));
		Assert.isFalse(set.removeAt(99));

		var values = set.toArray();
		Assert.equals("b", values.join(","));

		set.clear();
		Assert.isTrue(set.isEmpty);
		Assert.equals(0, set.readArray().length);
	}

	public function testListedMapSupportsSwapRemovalAndIndexedAccess():Void {
		var map = new ListedMap<String, Int>();

		Assert.isTrue(map.set("a", 1));
		Assert.isTrue(map.set("b", 2));
		Assert.isFalse(map.set("a", 3));
		Assert.equals(2, map.length);
		Assert.equals(3, map.get("a"));
		Assert.equals(3, map.valueAt(0));

		Assert.isTrue(map.remove("a"));
		Assert.isFalse(map.exists("a"));
		Assert.equals(1, map.length);
		Assert.equals(2, map.valueAt(0));
		Assert.isFalse(map.remove("missing"));

		var pairs = [];
		for (pair in map.keyValueIterator()) {
			pairs.push(pair.key + "=" + pair.value);
		}
		Assert.equals("b=2", pairs.join(","));

		map.clear();
		Assert.equals(0, map.length);
		Assert.isFalse(map.exists("b"));
	}

	public function testSlotMapInvalidatesStaleHandlesAndReusesSlots():Void {
		var map = new SlotMap<String>(2, 4, 1);
		var first = map.insert("alpha");
		var second = map.insert("beta");

		Assert.equals(2, map.length);
		Assert.equals(2, map.capacity);
		Assert.equals("alpha", map.get(first));
		Assert.equals("beta", map.get(second));

		Assert.isTrue(map.remove(first));
		Assert.isNull(map.get(first));
		Assert.isFalse(map.set(first, "stale"));

		var reused = map.insert("gamma");
		Assert.equals(first.index(), reused.index());
		Assert.notEquals(first.gen(), reused.gen());
		Assert.equals("gamma", map.get(reused));

		var seen = [];
		map.forEach((handle, value) -> seen.push(handle.index() + ":" + value));
		Assert.equals(2, seen.length);

		map.ensureCapacity(4);
		Assert.equals(4, map.capacity);

		map.clear();
		Assert.equals(0, map.length);
		Assert.isNull(map.get(second));
		Assert.isNull(map.get(reused));
	}

	public function testPackedSlotMapKeepsDenseIterationAndHonorsMaxCapacity():Void {
		var map = new PackedSlotMap<String>(2, 3, 2);
		var first = map.insert("alpha");
		var second = map.insert("beta");
		var third = map.insert("gamma");

		Assert.equals(3, map.length);
		Assert.equals(3, map.capacity);
		Assert.equals("alpha", map.get(first));
		Assert.equals("beta", map.get(second));
		Assert.equals("gamma", map.get(third));

		Assert.isTrue(map.remove(second));
		Assert.isNull(map.get(second));
		Assert.equals(2, map.length);
		Assert.equals("gamma", map.get(third));

		var iterated = [];
		for (value in map) {
			iterated.push(value);
		}
		iterated.sort((a, b) -> Reflect.compare(a, b));
		Assert.equals("alpha,gamma", iterated.join(","));

		map.ensureCapacity(99);
		Assert.equals(3, map.capacity);

		var replacement = map.insert("delta");
		Assert.equals(second.index(), replacement.index());
		Assert.notEquals(second.gen(), replacement.gen());
		Assert.equals("delta", map.get(replacement));

		map.clear();
		Assert.equals(0, map.length);
		Assert.isNull(map.get(first));
		Assert.isNull(map.get(third));
		Assert.isNull(map.get(replacement));
	}

	public function testWeightedGraphSupportsStringNodes():Void {
		var graph = new WeightedGraph<String>();
		graph.addEdge("a", "b", 2.5);

		var neighbors:Array<Dynamic> = cast graph.getNeighbors("a");
		Assert.equals(1, neighbors.length);
		Assert.equals("b", Reflect.field(neighbors[0], "to"));
		Assert.equals(2.5, Reflect.field(neighbors[0], "weight"));
		Assert.notNull(graph.getNeighbors("b"));
		Assert.isNull(graph.getNeighbors("missing"));
	}

	public function testWeightedGraphSupportsObjectNodes():Void {
		var from = {id: 1};
		var to = {id: 2};
		var graph = new WeightedGraph<Dynamic>();

		graph.addEdge(from, to, 7);

		var neighbors:Array<Dynamic> = cast graph.getNeighbors(from);
		Assert.equals(to, Reflect.field(neighbors[0], "to"));
		Assert.isNull(graph.getNeighbors({id: 1}));
	}
}
