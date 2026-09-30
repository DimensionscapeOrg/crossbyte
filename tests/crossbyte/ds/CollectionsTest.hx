package crossbyte.ds;

import crossbyte.ds.QuadTree.QuadTreeNode;
import crossbyte.math.Rectangle;
import utest.Assert;

class CollectionsTest extends utest.Test {
	public function testBloomFilterFindsAddedItems():Void {
		var filter = new BloomFilter(128, 3);

		Assert.isFalse(filter.contains("alpha"));
		filter.add("alpha");
		Assert.isTrue(filter.contains("alpha"));
	}

	public function testBloomFilterRejectsInvalidConstruction():Void {
		Assert.raises(() -> new BloomFilter(0, 3));
		Assert.raises(() -> new BloomFilter(16, 0));
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

	public function testArray2DReportsEmptyWidthAndClonesIndependently():Void {
		var empty = new Array2D<Int>();
		Assert.isTrue(empty.isEmpty());
		Assert.equals(0, empty.getWidth());
		Assert.equals(0, empty.getHeight());

		var grid = new Array2D<Int>(2, 3, 1);
		grid.set(1, 2, 9);

		Assert.equals(1, grid.get(0, 0));
		Assert.equals(9, grid.get(1, 2));
		Assert.equals("1,1,1,1,1,9", grid.toFlatArray().join(","));

		var clone = grid.clone();
		clone.set(0, 0, 7);
		Assert.equals(1, grid.get(0, 0));
		Assert.equals(7, clone.get(0, 0));
	}

	public function testStackSupportsLifoIterationAndClearing():Void {
		var stack = new Stack<String>(1);
		Assert.isTrue(stack.isEmpty);
		Assert.isNull(stack.pop());

		stack.push("a");
		stack.push("b");
		stack.push("c");

		Assert.equals(3, stack.length);
		Assert.equals("c", stack.last());

		var forward = [];
		stack.forEach(value -> forward.push(value));
		Assert.equals("a,b,c", forward.join(","));

		var reverse = [];
		stack.forEachReverse(value -> reverse.push(value));
		Assert.equals("c,b,a", reverse.join(","));

		var iterated = [];
		for (value in stack) {
			iterated.push(value);
		}
		Assert.equals("c,b,a", iterated.join(","));

		Assert.equals("c", stack.pop());
		stack.clear();
		Assert.isTrue(stack.isEmpty);
		Assert.isNull(stack.last());
	}

	public function testBitmapDataRoundTripsPixelsBoundsAndSerialization():Void {
		var bitmap = new BitmapData(2, 2, true, 0x11223344);
		Assert.equals(0x11223344, bitmap.getPixel32(0, 0));

		bitmap.setPixel32(1, 0, 0xAABBCCDD);
		Assert.equals(0xAABBCCDD, bitmap.getPixel32(1, 0));
		Assert.equals(0xBBCCDD, bitmap.getPixel(1, 0));

		bitmap.setPixel(1, 0, 0x102030);
		Assert.equals(0xAA102030, bitmap.getPixel32(1, 0));

		var opaque = new BitmapData(1, 1, false, 0x00112233);
		Assert.equals(0xFF112233, opaque.getPixel32(0, 0));
		opaque.setPixel32(0, 0, 0x00123456);
		Assert.equals(0xFF123456, opaque.getPixel32(0, 0));

		var bytes = bitmap.toByteArray();
		var restored = BitmapData.fromByteArray(2, 2, bytes, true);
		Assert.equals(bitmap.getPixel32(0, 0), restored.getPixel32(0, 0));
		Assert.equals(bitmap.getPixel32(1, 0), restored.getPixel32(1, 0));

		var bounds = bitmap.getColorBoundsRect(0xFFFFFFFF, 0xAABBCCDD);
		Assert.isTrue(bounds.isEmpty());

		bitmap.fillRect(new Rectangle(0, 1, 2, 1), 0x55667788);
		Assert.equals(0x55667788, bitmap.getPixel32(0, 1));

		var clone = bitmap.clone();
		clone.setPixel32(0, 0, 0x01020304);
		Assert.equals(0x11223344, bitmap.getPixel32(0, 0));
		Assert.equals(0x01020304, clone.getPixel32(0, 0));
	}

	public function testBitmapDataCopyPixelsAndDispose():Void {
		var source = new BitmapData(2, 2, true, 0x00000000);
		source.setPixel32(0, 0, 0xFF000001);
		source.setPixel32(1, 0, 0xFF000002);
		source.setPixel32(0, 1, 0xFF000003);
		source.setPixel32(1, 1, 0xFF000004);

		var dest = new BitmapData(2, 2, true, 0x00000000);
		dest.copyPixels(source, new Rectangle(1, 0, 1, 2), new crossbyte.math.Point(0, 0));
		Assert.equals(0xFF000002, dest.getPixel32(0, 0));
		Assert.equals(0xFF000004, dest.getPixel32(0, 1));

		dest.dispose();
		Assert.raises(() -> dest.getPixel32(0, 0));
	}

	public function testSlotHandleEncodesIndexAndGeneration():Void {
		var handle = SlotHandle.make(12345, 37);

		Assert.equals(12345, handle.index());
		Assert.equals(37, handle.gen());
		Assert.equals(-1, SlotHandle.INVALID.toInt());
	}

	/**
		A handle is not an id. It converted to an `Int` silently, so
		`grid.set(entity.handle, x, y)` compiled where `entity.slot` was meant,
		and worked until the slot's first reuse made the handle 1,048,576 or
		more, when the grid grew five arrays of that length to fit it -- 117
		MB by the third reuse. Now it has to be asked for.
	**/
	public function testAHandleIsNotAnIdOfItsOwnAccord():Void {
		var map = new SlotMap<String>(4);
		var grid = new SpatialGrid(0, 0, 100, 100, 10);
		var interest = new InterestSet();
		var handle:SlotHandle = map.insert("entity");

		Assert.notNull(TypeCheck.errorOf(grid.set(handle, 1, 1)), "a handle was taken as a grid id");
		Assert.notNull(TypeCheck.errorOf(interest.add(handle)), "a handle was taken as an interest id");
		Assert.notNull(TypeCheck.errorOf({
			var id:Int = handle;
		}), "a handle became an Int by assignment");

		// Asked for, both ways.
		grid.set(handle.index(), 1, 1);
		Assert.isTrue(grid.has(handle.index()));
		var written:Int = handle.toInt();
		var read:SlotHandle = written;
		Assert.equals("entity", map.get(read));
		Assert.isTrue(read == handle);
	}

	public function testSwitchTableDispatchesMixedKeysAndArguments():Void {
		var seen = [];
		var total = 0;
		var dispatch = SwitchTable.make([
			{key: "PING", handler: () -> seen.push("pong")},
			{key: "ADD", handler: (value:Int) -> total += value},
			{key: 7, handler: (left:Int, right:Int) -> seen.push((left + right) + "")}
		]);

		dispatch("PING");
		dispatch("ADD", 4);
		dispatch("ADD", 6);
		dispatch(7, 2, 5);

		Assert.equals(10, total);
		Assert.equals("pong,7", seen.join(","));
		Assert.raises(() -> dispatch("MISSING"));
	}

	public function testRadixTreeSupportsExactKeysPrefixesAndUpdates():Void {
		var tree = new RadixTree<Int>();

		tree.insert("carpet", 1);
		tree.insert("car", 2);
		tree.insert("cart", 3);
		tree.insert("cat", 4);
		tree.insert("dog", 5);
		tree.insert("car", 9);
		tree.insert("", 99);
		tree.insert(null, 100);

		Assert.equals(9, tree.search("car"));
		Assert.equals(1, tree.search("carpet"));
		Assert.equals(3, tree.search("cart"));
		Assert.equals(4, tree.search("cat"));
		Assert.equals(5, tree.search("dog"));
		Assert.isNull(tree.search("ca"));
		Assert.isNull(tree.search("care"));
		Assert.isNull(tree.search(""));
		Assert.isNull(tree.search(null));
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

	/**
		Removing the entry a loop is on visits the one swapped into its place
		next. The value iterator counted the entries when it was made, so it
		read past the end and threw on every target; the pair iterator
		re-read the count and skipped the entry moved into the gap.
	**/
	public function testListedMapRemovingWhileIteratingVisitsEachOnce():Void {
		var map = new ListedMap<String, Int>();
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
		seen.sort((a, b) -> a - b);
		Assert.same([0, 1, 2, 3, 4, 5], seen);
		Assert.equals(3, map.length);

		for (i in 0...6) {
			map.set('k$i', i);
		}
		var pairs:Array<Int> = [];
		for (pair in map.keyValueIterator()) {
			pairs.push(pair.value);
			if (pair.value % 2 == 1) {
				map.remove(pair.key);
			}
		}
		pairs.sort((a, b) -> a - b);
		Assert.same([0, 1, 2, 3, 4, 5], pairs);
		Assert.equals(3, map.length);
		// Without removals the order is insertion order, as before.
		var fresh = new ListedMap<String, Int>();
		for (i in 0...4) {
			fresh.set('f$i', i);
		}
		Assert.same([0, 1, 2, 3], [for (v in fresh) v]);
	}

	/**
		The same for `DenseSet`, which walked its array directly: removing
		every even element visited 4 of 6.
	**/
	public function testDenseSetRemovingWhileIteratingVisitsEachOnce():Void {
		var set = new DenseSet<Int>();
		for (i in 0...6) {
			set.add(i);
		}
		var seen:Array<Int> = [];
		for (x in set) {
			seen.push(x);
			if (x % 2 == 0) {
				set.remove(x);
			}
		}
		seen.sort((a, b) -> a - b);
		Assert.same([0, 1, 2, 3, 4, 5], seen);
		var left = set.toArray();
		left.sort((a, b) -> a - b);
		Assert.same([1, 3, 5], left);

		// Removing everything, one at a time, from inside the loop.
		var all = new DenseSet<String>();
		for (i in 0...50) {
			all.add("s" + i);
		}
		var visited:Int = 0;
		for (x in all) {
			visited++;
			all.remove(x);
		}
		Assert.equals(50, visited);
		Assert.isTrue(all.isEmpty);
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

	/**
		A slot survives being reused more times than its generation can count.

		The generation field is `GEN_BITS` wide and the counter was not kept
		inside it, so on the 256th reuse of a slot the handle carried a
		truncated generation while the slot held the untruncated one. They
		never compared equal again: `remove` returned false for ever, the
		entry was never freed, and the map grew a permanent leak of one slot
		per 256 reuses. Anything with entity churn passes 256 in seconds --
		the soak harness reached it in twenty and kept climbing.
	**/
	public function testASlotSurvivesMoreReusesThanItsGenerationCanCount():Void {
		var map = new SlotMap<String>(4);
		var reuses:Int = 4 * (1 << SlotHandle.GEN_BITS);
		var refused:Int = 0;

		for (_ in 0...reuses) {
			if (!map.remove(map.insert("e"))) {
				refused++;
			}
		}

		Assert.equals(0, refused, "remove() refused a live handle " + refused + " times in " + reuses + " reuses");
		Assert.equals(0, map.length, "the map kept " + map.length + " entries after " + reuses + " balanced pairs");
	}

	/**
		A handle kept after its entry died does not come to name whatever took
		its slot. With an eight-bit generation it did, 256 reuses later -- and
		the free list hands the most recently freed slot back first, so those
		256 reuses are one entity after another in the same place.
	**/
	public function testAStaleHandleStaysStaleThroughManyReuses():Void {
		var entities = new SlotMap<String>(16);
		var packed = new PackedSlotMap<String>(16);
		var victim = entities.insert("goblin");
		var packedVictim = packed.insert("goblin");
		entities.remove(victim);
		packed.remove(packedVictim);

		var aliasedAt:Int = -1;
		var packedAliasedAt:Int = -1;
		for (i in 0...2000) {
			var spawned = entities.insert("projectile " + i);
			if (aliasedAt < 0 && entities.get(victim) != null) {
				aliasedAt = i;
			}
			entities.remove(spawned);

			var packedSpawned = packed.insert("projectile " + i);
			if (packedAliasedAt < 0 && packed.get(packedVictim) != null) {
				packedAliasedAt = i;
			}
			packed.remove(packedSpawned);
		}

		Assert.equals(-1, aliasedAt, "a dead entity's handle resolved to a new one after " + aliasedAt + " reuses");
		Assert.equals(-1, packedAliasedAt, "a dead entity's handle resolved to a new one after " + packedAliasedAt + " reuses");
	}

	/**
		One entity despawned and another spawned every tick does not bring a
		slot's generation round in 2048 ticks.

		The free list handed back the slot freed last, so that churn reused
		one slot every tick, and a handle kept to the first entity -- a
		missile's target -- resolved to the 2048th newcomer 34 seconds later at
		60 Hz. Freed slots now wait behind every other free one.
	**/
	public function testAChurnedSlotWaitsBehindTheOtherFreeOnes():Void {
		var entities = new SlotMap<String>(16);
		var packed = new PackedSlotMap<String>(16);
		for (i in 0...8) {
			entities.insert("resident " + i);
			packed.insert("resident " + i);
		}
		var victim = entities.insert("goblin");
		var packedVictim = packed.insert("goblin");
		entities.remove(victim);
		packed.remove(packedVictim);

		var aliasedAt:Int = -1;
		var packedAliasedAt:Int = -1;
		var spawned = entities.insert("tick 0");
		var packedSpawned = packed.insert("tick 0");
		for (tick in 1...6000) {
			entities.remove(spawned);
			spawned = entities.insert("tick " + tick);
			if (aliasedAt < 0 && entities.get(victim) != null) {
				aliasedAt = tick;
			}
			packed.remove(packedSpawned);
			packedSpawned = packed.insert("tick " + tick);
			if (packedAliasedAt < 0 && packed.get(packedVictim) != null) {
				packedAliasedAt = tick;
			}
		}

		Assert.equals(-1, aliasedAt, "a dead entity's handle resolved to a newcomer at tick " + aliasedAt);
		Assert.equals(-1, packedAliasedAt, "a dead entity's handle resolved to a newcomer at tick " + packedAliasedAt);
		Assert.equals(9, entities.length);
		Assert.equals(9, packed.length);
	}

	/**
		An entry inserted as null is held like any other. Whether a slot was
		held was read from its value, so a null entry was skipped by forEach,
		kept its generation through clear() and could still be written
		through its old handle afterwards.
	**/
	public function testANullEntryIsHeldLikeAnyOther():Void {
		var map = new SlotMap<String>(4);
		var handle = map.insert(null);
		Assert.equals(1, map.length);

		var visits:Int = 0;
		map.forEach((h, v) -> {
			visits++;
			Assert.isTrue(h == handle);
			Assert.isNull(v);
		});
		Assert.equals(1, visits, "forEach skipped a held null entry");

		map.clear();
		Assert.equals(0, map.length);
		Assert.isFalse(map.set(handle, "written after clear"), "a handle survived clear()");
		Assert.isNull(map.get(handle));
		Assert.isFalse(map.remove(handle));
	}

	/**
		A handle made up for a slot nobody holds cannot free it. It matched the
		free slot's generation, so remove() freed it a second time: length went
		to -1 and the slot was handed to two inserts.
	**/
	public function testAHandleToAFreeSlotFreesNothing():Void {
		var map = new SlotMap<String>(4);
		Assert.isFalse(map.remove(SlotHandle.make(2, 0)), "a slot nobody held was removed");
		Assert.isFalse(map.set(SlotHandle.make(1, 0), "stray"), "a slot nobody held was written");
		Assert.equals(0, map.length);

		var handles = [for (i in 0...4) map.insert("e" + i)];
		var slots = new Map<Int, Bool>();
		for (h in handles) {
			Assert.isFalse(slots.exists(h.index()), "slot " + h.index() + " was handed out twice");
			slots.set(h.index(), true);
		}
		for (i in 0...4) {
			Assert.equals("e" + i, map.get(handles[i]));
		}

		var packed = new PackedSlotMap<String>(4);
		Assert.isFalse(packed.remove(SlotHandle.make(2, 0)));
		Assert.equals(0, packed.length);
	}

	/** Growth and clear keep every slot reachable, in the order they queue. **/
	public function testSlotsQueueInOrderThroughGrowthAndClear():Void {
		var map = new SlotMap<Int>(2, null, 3);
		var first = [for (i in 0...7) map.insert(i)];
		Assert.equals(8, map.capacity);
		Assert.equals("0,1,2,3,4,5,6", [for (h in first) h.index()].join(","));
		map.remove(first[3]);
		map.remove(first[1]);
		// The slot never used goes first, then the freed ones in the order freed.
		Assert.equals("7,3,1", [for (_ in 0...3) map.insert(0).index()].join(","));

		map.clear();
		Assert.equals("0,1,2,3,4,5,6,7", [for (_ in 0...8) map.insert(1).index()].join(","));
		var grown = map.insert(2);
		Assert.equals(8, grown.index());
		Assert.equals(11, map.capacity);
		Assert.equals(9, map.length);
	}

	public function testAHandleIsNeverNegative():Void {
		// The sign bit was part of the generation, so past its halfway point
		// every handle was negative, and at the top index a live handle was
		// the INVALID sentinel itself.
		var map = new SlotMap<String>(4);
		var negative = 0;
		for (_ in 0...(1 << SlotHandle.GEN_BITS)) {
			var handle = map.insert("e");
			if (handle.toInt() < 0) {
				negative++;
			}
			map.remove(handle);
		}
		Assert.equals(0, negative);
		Assert.isTrue(SlotHandle.make(SlotHandle.INDEX_MASK, SlotHandle.GEN_MASK).toInt() != SlotHandle.INVALID.toInt());
	}

	public function testClearKeepsTheGenerationInRange():Void {
		// clear() counted the generation without masking it, so a slot at the
		// top of its range held a value no handle could carry, and every entry
		// put there afterwards could not be read back.
		var map = new SlotMap<String>(4);
		for (_ in 0...SlotHandle.GEN_MASK) {
			map.remove(map.insert("churn"));
		}
		map.insert("live");
		map.clear();

		var lost = 0;
		for (round in 0...3) {
			var handles = [for (i in 0...4) map.insert("round " + round + " " + i)];
			for (handle in handles) {
				if (map.get(handle) == null) {
					lost++;
				}
			}
			for (handle in handles) {
				map.remove(handle);
			}
		}
		Assert.equals(0, lost, "entries inserted after clear() could not be read back");
		Assert.equals(0, map.length);
	}

	/** And the same for the packed variant, which counted the same way. **/
	public function testAPackedSlotSurvivesMoreReusesThanItsGenerationCanCount():Void {
		var map = new PackedSlotMap<String>(4);
		var reuses:Int = 4 * (1 << SlotHandle.GEN_BITS);
		var refused:Int = 0;

		for (_ in 0...reuses) {
			if (!map.remove(map.insert("e"))) {
				refused++;
			}
		}

		Assert.equals(0, refused, "remove() refused a live handle " + refused + " times in " + reuses + " reuses");
		Assert.equals(0, map.length, "the map kept " + map.length + " entries after " + reuses + " balanced pairs");
	}

	/** An entry stops being there once its time has passed. **/
	public function testAnExpiringEntryIsGoneWhenItsTimeHasPassed():Void {
		var now:Float = 1000;
		var map = new ExpiringMap<String, Int>(10, 0, function():Float return now);

		map.set("a", 1);
		Assert.equals(1, map.get("a"));

		now = 1009.9;
		Assert.equals(1, map.get("a"), "it went early");

		now = 1010;
		Assert.isNull(map.get("a"), "it was still there once its time had passed");
		Assert.equals(0, map.length, "it read as gone but was still counted");
	}

	/** Touching one starts its life over; reading one does not. **/
	public function testTouchingExtendsAnEntryAndReadingDoesNot():Void {
		var now:Float = 0;
		var map = new ExpiringMap<String, Int>(10, 0, function():Float return now);
		map.set("a", 1);

		now = 9;
		map.get("a");
		now = 11;
		Assert.isNull(map.get("a"), "reading an entry extended it");

		now = 20;
		map.set("b", 2);
		now = 29;
		Assert.isTrue(map.touch("b"));
		now = 38;
		Assert.equals(2, map.get("b"), "touching an entry did not extend it");
	}

	/**
		Sweeping costs what expired, not what is held.

		A sweep that walked everything would be a pass over the whole map on
		every tick, which is the cost this is meant to avoid.
	**/
	public function testSweepingDropsOnlyWhatExpired():Void {
		var now:Float = 0;
		var map = new ExpiringMap<String, Int>(10, 0, function():Float return now);
		var expired:Array<String> = [];
		map.onExpire = (key, _) -> expired.push(key);

		for (i in 0...5) {
			now = i;
			map.set("k" + i, i);
		}

		now = 12;
		Assert.equals(3, map.sweep(), "k0, k1 and k2 were due and did not go");
		Assert.equals(2, map.length);
		Assert.equals("k0,k1,k2", expired.join(","));
	}

	/**
		Time is not a bound on its own.

		Whoever fills the map can fill it faster than it drains, so it is
		bounded by count as well and drops whatever is closest to expiring.
	**/
	public function testAnExpiringMapIsBoundedByCountAsWellAsTime():Void {
		var now:Float = 0;
		var map = new ExpiringMap<String, Int>(3600, 4, function():Float return now);

		for (i in 0...40) {
			now = i;
			map.set("k" + i, i);
		}

		Assert.equals(4, map.length, "the map held " + map.length + " against a bound of 4");
		Assert.isNull(map.get("k0"), "the oldest entry survived the bound");
		Assert.equals(39, map.get("k39"), "the newest entry was the one dropped");
	}

	/**
		`length` leaves out what has expired and not been swept, as its
		documentation says. It counted them until a read or a sweep dropped
		them.
	**/
	public function testLengthLeavesOutWhatHasExpiredUnswept():Void {
		var now:Float = 0;
		var map = new ExpiringMap<String, Int>(10, 0, function():Float return now);
		map.set("a", 1);
		now = 5;
		map.set("b", 2);
		Assert.equals(2, map.length);

		now = 12;
		Assert.equals(1, map.length, "an expired, unswept entry was counted");
		now = 20;
		Assert.equals(0, map.length);
		Assert.equals(2, map.sweep());
		Assert.equals(0, map.length);
	}

	/**
		An entry touched goes to the back of the line: a sweep takes what is
		due and stops, and `maxSize` evicts what is closest to expiring, even
		when an idle entry sat ahead of a busy one for a long time.
	**/
	public function testTouchedEntriesExpireInTheOrderTheirDeadlinesFall():Void {
		var now:Float = 0;
		var map = new ExpiringMap<String, Int>(10, 3, function():Float return now);
		var expired:Array<String> = [];
		map.onExpire = (key, _) -> expired.push(key);

		map.set("idle", 0);
		now = 1;
		map.set("a", 1);
		now = 2;
		map.set("b", 2);
		// "a" is used for a long while; "idle" never is.
		var t:Float = 2;
		while (t < 9) {
			t += 0.25;
			now = t;
			map.touch("a");
		}
		Assert.equals(1, map.sweep(10.5), "only the idle entry was due");
		Assert.equals("idle", expired.join(","));
		Assert.equals("b,a", [for (k in map.keys()) k].join(","));

		now = 11;
		map.set("c", 3);
		map.set("d", 4);
		// Over the bound of 3: "b" was the one closest to expiring.
		Assert.equals("idle,b", expired.join(","));
		Assert.equals("a,c,d", [for (k in map.keys()) k].join(","));

		map.set("a", 10);
		Assert.equals("c,d,a", [for (k in map.keys()) k].join(","));
		Assert.equals(10, map.get("a"));
		Assert.isTrue(map.remove("c"));
		Assert.isFalse(map.remove("c"));
		Assert.equals("d,a", [for (k in map.keys()) k].join(","));
		map.clear();
		Assert.equals(0, map.length);
		Assert.equals(0, map.sweep(1000));
	}

	#if jvm
	/**
		Touching an entry costs nothing to hold. Every `set` and `touch` left
		a queue position behind, collected only once everything ahead of it
		had expired, so memory went with the touches times the ttl rather
		than the entries: 1,000 sessions touched 20 times a second with a
		120 s ttl held 2.4 million positions, 70 MB on the jvm.
	**/
	public function testTouchingAnEntryAllocatesNothing():Void {
		var now:Float = 0;
		var map = new ExpiringMap<String, Int>(120, 50000, function():Float return now);
		var keys = [for (i in 0...1000) "tok" + i];
		map.set("idle", 0);
		for (k in keys) {
			map.set(k, 1);
		}
		for (k in keys) {
			map.touch(k);
		}
		var perTouch:Float = JvmAllocation.bytesBy(() -> {
			for (step in 0...20) {
				now += 0.05;
				for (k in keys) {
					map.touch(k);
				}
			}
		}) / 20000;
		Assert.isTrue(perTouch < 1, perTouch + " bytes allocated per touch");
		Assert.equals(1001, map.length);
	}
	#end

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

	public function testQuadTreeQueriesPointsAcrossSubdivisions():Void {
		var tree = new QuadTree<String>(new Rectangle(0, 0, 100, 100), 1);
		var a = new QuadTreeNode<String>(10, 10, "nw");
		var b = new QuadTreeNode<String>(75, 10, "ne");
		var c = new QuadTreeNode<String>(10, 75, "sw");
		var d = new QuadTreeNode<String>(75, 75, "se");

		Assert.isTrue(tree.insert(a));
		Assert.isTrue(tree.insert(b));
		Assert.isTrue(tree.insert(c));
		Assert.isTrue(tree.insert(d));
		Assert.isFalse(tree.insert(new QuadTreeNode<String>(150, 150, "outside")));

		var topHalf = tree.query(new Rectangle(0, 0, 100, 50));
		var topValues = [for (node in topHalf) node.value];
		topValues.sort((left, right) -> Reflect.compare(left, right));
		Assert.equals("ne,nw", topValues.join(","));

		var bottomRight = tree.query(new Rectangle(50, 50, 50, 50));
		Assert.equals(1, bottomRight.length);
		Assert.equals("se", bottomRight[0].value);

		tree.clear();
		Assert.equals(0, tree.query(new Rectangle(0, 0, 100, 100)).length);
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

	public function testWeightedGraphMaintainsDirectedNeighborsAndExplicitNodes():Void {
		var graph = new WeightedGraph<String>();
		graph.addNode("start");
		graph.addNode("start");
		graph.addEdge("start", "mid", 1.5);
		graph.addEdge("start", "end", 2.5);

		var startNeighbors:Array<Dynamic> = cast graph.getNeighbors("start");
		Assert.equals(2, startNeighbors.length);
		Assert.equals("mid", Reflect.field(startNeighbors[0], "to"));
		Assert.equals(1.5, Reflect.field(startNeighbors[0], "weight"));
		Assert.equals("end", Reflect.field(startNeighbors[1], "to"));
		Assert.equals(2.5, Reflect.field(startNeighbors[1], "weight"));

		Assert.notNull(graph.getNeighbors("mid"));
		Assert.equals(0, graph.getNeighbors("mid").length);
		Assert.equals(0, graph.getNeighbors("end").length);
	}
}
