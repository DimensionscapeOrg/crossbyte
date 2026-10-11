package crossbyte.ds;

import crossbyte.ds.QuadTree.QuadTreeNode;
import crossbyte.math.Rectangle;
import utest.Assert;

class CollectionsTest extends utest.Test {
	/**
		A miss in a large `Map<Int, T>` costs what a hit does.

		Haxe 4.3.7's `IntMap` for the java targets never stops probing at an
		empty bucket, so every miss reads the whole table: 110us a miss at
		100,000 entries, where a hit takes nothing measurable. CrossByte puts a
		fixed copy ahead of it there (`std/java`, through `StdOverrides`).
		Timed against the hits rather than a clock limit, so a loaded machine
		slows both sides alike.
	**/
	public function testAMissInALargeIntMapCostsWhatAHitDoes():Void {
		var map = new Map<Int, Int>();
		for (i in 0...20000) {
			map.set(i * 2, i);
		}

		var found = 0;
		// Both paths once first, for a compiler that compiles as it goes.
		for (i in 0...2000) {
			if (map.exists(i * 2 + 1)) found++;
			if (map.exists(i * 2)) found++;
		}

		var start = haxe.Timer.stamp();
		for (i in 0...2000) {
			if (map.exists(i * 2 + 1)) found++;
		}
		var misses = haxe.Timer.stamp() - start;
		start = haxe.Timer.stamp();
		for (i in 0...2000) {
			if (map.exists(i * 2)) found++;
		}
		var hits = haxe.Timer.stamp() - start;

		#if (java || jvm)
		// The fixed copy is the one compiled; this does not compile otherwise.
		Assert.isTrue(@:privateAccess haxe.ds.IntMap.__stopsAtEmptyBucket);
		#end
		Assert.equals(4000, found);
		Assert.isTrue(misses < hits * 20 + 0.01,
			"2000 misses took " + Math.round(misses * 1e6) / 1000 + "ms, 2000 hits " + Math.round(hits * 1e6) / 1000 + "ms");
	}

	/** Keys removed, and some put back, answer as they should: the probe stops at an empty bucket, never at a deleted one. **/
	public function testAnIntMapAnswersForKeysRemovedAndPutBack():Void {
		var map = new Map<Int, String>();
		for (i in 0...5000) {
			map.set(i, "v" + i);
		}
		for (i in 0...5000) {
			if (i % 3 == 0) map.remove(i);
		}
		for (i in 0...5000) {
			if (i % 9 == 0) map.set(i, "again" + i);
		}

		var wrong:Array<Int> = [];
		for (i in 0...5000) {
			var expected:Null<String> = i % 9 == 0 ? "again" + i : (i % 3 == 0 ? null : "v" + i);
			if (map.get(i) != expected || map.exists(i) != (expected != null)) {
				wrong.push(i);
			}
		}
		for (i in 5000...6000) {
			if (map.exists(i)) wrong.push(i);
		}

		Assert.equals(0, wrong.length, "wrong answers for " + wrong.slice(0, 10).join(", "));
	}

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

	public function testAStackOfNegativeSizeIsRefused():Void {
		// Handed to Array.resize, a negative size ended the interpreter with an
		// error nothing catches, was ignored on the jvm, and threw JavaScript's
		// own RangeError on Node.
		try {
			new Stack<Int>(-3);
			Assert.fail("a stack of -3 was made");
		} catch (e:crossbyte.errors.ArgumentError) {
			Assert.pass();
		}
		Assert.equals(0, new Stack<Int>(0).length);
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
		A handle is not an id, and does not convert to an `Int` silently:
		otherwise `grid.set(entity.handle, x, y)` would compile where
		`entity.slot` was meant, and work until the slot's first reuse made the
		handle 1,048,576 or more, when the grid would grow five arrays of that
		length to fit it (117 MB by the third reuse). It has to be asked for.
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

	/**
		Keys can be named constants, and a key no case matches can be handled,
		rather than only literals (a table keyed on opcodes repeating their
		numbers) and "Case not found" thrown for an unmatched key.
	**/
	public function testSwitchTableTakesNamedKeysAndAFallback():Void {
		Assert.isNull(TypeCheck.errorOf(SwitchTable.make([{key: SwitchTableOpcodes.PING, handler: () -> {}}])), "a named constant was refused as a key");
		Assert.notNull(TypeCheck.errorOf(SwitchTable.make([{key: "A", handler: () -> {}}, {key: "A", handler: () -> {}}])), "a duplicate key was accepted");

		var seen:Array<String> = [];
		var custom:String = "CUSTOM";
		var dispatch = SwitchTable.make([
			{key: SwitchTableOpcodes.PING, handler: () -> seen.push("pong")},
			{key: SwitchTableOpcodes.LOGIN, handler: (name:String) -> seen.push("login " + name)},
			{key: custom, handler: () -> seen.push("custom")}
		], (key:Dynamic, args:Array<Dynamic>) -> seen.push("unknown " + key + " with " + args.length));

		dispatch(1);
		dispatch(2, "ada");
		dispatch("CUSTOM");
		dispatch(99, "x", "y");
		dispatch("nope");
		Assert.equals("pong,login ada,custom,unknown 99 with 2,unknown nope with 0", seen.join(","));

		var strict = SwitchTable.make([{key: 1, handler: () -> {}}]);
		Assert.raises(() -> strict(2));
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

	/**
		The longest held key a path starts with: the route that serves it, not
		only exact keys.
	**/
	public function testRadixTreeFindsTheLongestPrefix():Void {
		var routes = new RadixTree<String>();
		routes.insert("/", "root");
		routes.insert("/api/v1/users", "users");
		routes.insert("/api/v1/users/list", "list");
		routes.insert("/api/v2", "v2");
		routes.insert("/api/v1/rooms", "rooms");

		Assert.equals("users", routes.longestPrefix("/api/v1/users/123"));
		Assert.equals("users", routes.longestPrefix("/api/v1/users"));
		Assert.equals("list", routes.longestPrefix("/api/v1/users/list/7"));
		Assert.equals("rooms", routes.longestPrefix("/api/v1/rooms?x=1"));
		Assert.equals("root", routes.longestPrefix("/api/v1/userz"));
		Assert.equals("v2", routes.longestPrefix("/api/v2x"));
		Assert.isNull(routes.longestPrefix("api"));
		Assert.isNull(routes.longestPrefix(""));
		Assert.isNull(routes.longestPrefix(null));

		Assert.equals(13, routes.longestPrefixLength("/api/v1/users/123"));
		Assert.equals(1, routes.longestPrefixLength("/nothing"));
		Assert.equals(-1, routes.longestPrefixLength("nothing"));

		// Exact lookups are not changed by the split nodes between keys.
		Assert.equals("users", routes.search("/api/v1/users"));
		Assert.isNull(routes.search("/api/v1"));
		Assert.isNull(routes.search("/api/v1/users/"));
	}

	#if jvm
	/**
		A lookup allocates nothing: it does not build the common prefix of each
		label and the key a character at a time, nor a substring at every level,
		which would cost 7.6 KB per lookup on the jvm.
	**/
	public function testRadixTreeLookupsAllocateNothing():Void {
		var tree = new RadixTree<Int>();
		var keys = [for (i in 0...1000) '/api/v1/item$i/detail'];
		for (i in 0...keys.length) {
			tree.insert(keys[i], i);
		}
		for (key in keys) {
			tree.search(key);
		}
		var perLookup:Float = JvmAllocation.bytesBy(() -> {
			for (key in keys) {
				tree.search(key);
				tree.longestPrefixLength(key);
			}
		}) / (keys.length * 2);
		Assert.isTrue(perLookup < 1, perLookup + " bytes allocated per lookup");
		Assert.equals(500, tree.search(keys[500]));
	}
	#end

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

	/**
		`v[i]` reads and writes on every target. A class implementing
		`ArrayAccess` would not: only hxcpp honours it, so it would throw on
		eval and the jvm, and on JavaScript a write would set a property and be lost.
	**/
	public function testVectorIndexesOnEveryTarget():Void {
		var vector = new Vector<Int>();
		vector.push(10);
		vector.push(20);
		vector[1] = 25;
		Assert.equals(25, vector[1]);
		Assert.equals("10,25", vector.join(","));

		// As in ActionScript: writing at the length appends, and anything
		// further out, read or written, is out of range.
		vector[2] = 30;
		Assert.equals(3, vector.length);
		Assert.equals(30, vector[2]);
		Assert.raises(() -> vector[3], crossbyte.errors.RangeError);
		Assert.raises(() -> vector[-1], crossbyte.errors.RangeError);
		Assert.raises(() -> vector[5] = 1, crossbyte.errors.RangeError);

		var sum:Int = 0;
		for (i in 0...vector.length) {
			sum += vector[i];
		}
		Assert.equals(65, sum);
	}

	/**
		A callback is called once per element with as many of (item, index,
		vector) as it takes, not tried with two and, on a throw, with one and
		then none, which would run a callback that threw again without its
		index (three times on eval).
	**/
	public function testVectorCallbacksRunOnceWithTheArgumentsTheyTake():Void {
		var vector = new Vector<Int>();
		vector.push(1);
		vector.push(2);

		var calls:Int = 0;
		Assert.raises(() -> vector.forEach(function(x:Int, i:Int) {
			calls++;
			throw "fail";
		}));
		Assert.equals(1, calls, "a throwing callback ran " + calls + " times");

		calls = 0;
		Assert.raises(() -> vector.every(function(x:Int) {
			calls++;
			throw "fail";
		}));
		Assert.equals(1, calls, "a throwing one-argument callback ran " + calls + " times");

		var seen:Array<String> = [];
		vector.forEach(function() seen.push("none"));
		vector.forEach(function(x:Int) seen.push("item " + x));
		vector.forEach(function(x:Int, i:Int) seen.push("item " + x + " at " + i));
		vector.forEach(function(x:Int, i:Int, v:Vector<Int>) seen.push("of " + v.length));
		Assert.equals("none,none,item 1,item 2,item 1 at 0,item 2 at 1,of 2,of 2", seen.join(","));

		Assert.equals("2,3", vector.map((x:Int) -> x + 1).join(","));
		Assert.equals("1", vector.filter((x:Int, i:Int) -> i == 0).join(","));
		Assert.isTrue(vector.some((x:Int, i:Int, v:Vector<Int>) -> v[i] == 2));
	}

	/**
		A method reached through `Reflect` and given with its object as
		`thisObject`: ActionScript's `forEach(obj.method, obj)`, gets the
		arguments it takes, like any other callback. It is the one kind whose
		arity cannot be read off its type.

		The object goes with it because on JavaScript `Reflect.field` hands
		back the method unbound, so without it the method runs with no `this`.

		On the jvm such a callback is a `haxe.jvm.Closure`, which declares
		`invokeDynamic` rather than an `invoke` of its own arity, so a search
		for `invoke` finds nothing and the count has to come from the closure
		itself. Guessing it called a one-argument method with two arguments
		(`IllegalArgumentException`), and handed a three-argument one `null`
		for the vector.
	**/
	public function testVectorCallbacksReachedThroughReflectGetTheirArguments():Void {
		var vector = new Vector<Int>();
		vector.push(10);
		vector.push(20);

		var target = new VectorCallbackTarget();

		vector.forEach(Reflect.field(target, "one"), target);
		Assert.equals("one(10),one(20)", target.seen.join(","));

		target.seen = [];
		vector.forEach(Reflect.field(target, "two"), target);
		Assert.equals("two(10,0),two(20,1)", target.seen.join(","));

		target.seen = [];
		vector.forEach(Reflect.field(target, "three"), target);
		Assert.equals("three(10,0,len2),three(20,1,len2)", target.seen.join(","));

		target.seen = [];
		vector.forEach(Reflect.field(target, "none"), target);
		Assert.equals("none(),none()", target.seen.join(","));
	}

	/**
		A fixed Vector keeps its length: whatever would change it throws
		`RangeError`, as in ActionScript.
	**/
	public function testAFixedVectorKeepsItsLength():Void {
		var vector = new Vector<Int>(2, true);
		Assert.isTrue(vector.fixed);
		Assert.equals(2, vector.length);
		vector[0] = 7;
		vector[1] = 8;
		Assert.equals("7,8", vector.join(","));

		Assert.raises(() -> vector.push(5), crossbyte.errors.RangeError);
		Assert.raises(() -> vector.pop(), crossbyte.errors.RangeError);
		Assert.raises(() -> vector.shift(), crossbyte.errors.RangeError);
		Assert.raises(() -> vector.unshift(1), crossbyte.errors.RangeError);
		Assert.raises(() -> vector.insertAt(0, 1), crossbyte.errors.RangeError);
		Assert.raises(() -> vector.removeAt(0), crossbyte.errors.RangeError);
		Assert.raises(() -> vector.length = 3, crossbyte.errors.RangeError);
		Assert.raises(() -> vector[2] = 9, crossbyte.errors.RangeError);
		Assert.raises(() -> vector.splice(0, 1), crossbyte.errors.RangeError);
		Assert.equals("7,8", vector.join(","));

		// A splice that puts back as many as it takes out leaves the length.
		Assert.equals("7", vector.splice(0, 1, 70).join(","));
		Assert.equals("70,8", vector.join(","));

		vector.fixed = false;
		vector.push(9);
		Assert.equals(3, vector.length);
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

	/**
		`splice` counts a negative `startIndex` back from the end, and inserts
		what it was given at that same place, not at the index the removal
		left behind. ActionScript's `[a,b,c,d,e].splice(-2, 2, "X")` leaves
		`a,b,c,X`.
	**/
	public function testVectorSpliceCountsANegativeStartFromTheEnd():Void {
		var vector = new Vector<String>();
		for (item in ["a", "b", "c", "d", "e"]) {
			vector.push(item);
		}

		Assert.equals("d,e", vector.splice(-2, 2, "X").join(","));
		Assert.equals("a,b,c,X", vector.join(","));

		// And with more than one item, so the insertion order shows too.
		var second = new Vector<String>();
		for (item in ["a", "b", "c", "d", "e"]) {
			second.push(item);
		}

		Assert.equals("d,e", second.splice(-2, 2, "X", "Y").join(","));
		Assert.equals("a,b,c,X,Y", second.join(","));

		// A fixed Vector allows the same splice, because it puts back as many
		// as it took out, and must place them just as exactly.
		var fixed = new Vector<String>();
		for (item in ["a", "b", "c", "d", "e"]) {
			fixed.push(item);
		}
		fixed.fixed = true;

		Assert.equals("d,e", fixed.splice(-2, 2, "X", "Y").join(","));
		Assert.equals("a,b,c,X,Y", fixed.join(","));
		Assert.equals(5, fixed.length);
	}

	/**
		A length is never negative. `Array.resize` with one is
		`Invalid_argument("Array.fill")` on the interpreter, which no `catch`
		can hold, and silently drops elements on the jvm.
	**/
	public function testVectorRefusesANegativeLength():Void {
		var vector = new Vector<String>();
		for (item in ["a", "b", "c"]) {
			vector.push(item);
		}

		Assert.raises(() -> vector.length = -1, crossbyte.errors.RangeError);
		Assert.equals("a,b,c", vector.join(","));
		Assert.raises(() -> new Vector<String>(-3), crossbyte.errors.RangeError);

		// Zero is a length like any other.
		vector.length = 0;
		Assert.equals(0, vector.length);
	}

	/**
		`removeAt` takes an index in range, and refuses one outside it like
		every other indexed access on the type. It used to answer `null` for an
		index past the end, and to take one off the end for a negative one.
	**/
	public function testVectorRemoveAtRefusesAnIndexOutOfRange():Void {
		var vector = new Vector<String>();
		for (item in ["a", "b", "c"]) {
			vector.push(item);
		}

		Assert.raises(() -> vector.removeAt(3), crossbyte.errors.RangeError);
		Assert.raises(() -> vector.removeAt(9), crossbyte.errors.RangeError);
		Assert.raises(() -> vector.removeAt(-1), crossbyte.errors.RangeError);
		Assert.equals("a,b,c", vector.join(","));

		Assert.equals("b", vector.removeAt(1));
		Assert.equals("a,c", vector.join(","));
	}

	/**
		A callback that shortens the vector under the loop is not handed the
		elements that are no longer there. The loop used to take its bound once
		and read past the new end, passing `null` to a callback typed for an
		element.
	**/
	/**
		One vector, however it is reached: by code that names its element
		type, by code generic over it, and as a `Vector<Dynamic>`, which a
		`Vector<Int>` passes for without a cast. What one writes, the others
		read.

		Natively, code that names the type works on an array of that type,
		and the rest on hxcpp's dynamic array over it. Taking the typed array
		by converting the store would copy it whenever the two disagree (an
		`Array<Int>` read as an `Array<Dynamic>` is a copy natively), and a
		push through the `Vector<Dynamic>` would land in the copy and be lost.
	**/
	public function testAVectorIsOneVectorHoweverItIsReached():Void {
		// Made where its type is known, then written generically.
		var ints = new Vector<Int>();
		ints.push(1);
		pushGenerically(ints, 300);
		Assert.equals(2, ints.length);
		Assert.equals(300, ints[1]);
		ints[0] = 7;
		Assert.equals(7, readGenerically(ints, 0));
		writeGenerically(ints, 2, 500);
		Assert.equals("7,300,500", ints.join(","));
		Assert.equals(3, lengthGenerically(ints));

		// Pushed to through a Vector<Dynamic>.
		pushDynamic(ints, 400);
		Assert.equals(4, ints.length);
		Assert.equals(400, ints[3]);
		Assert.equals(400, ints.pop());
		Assert.equals(3, lengthGenerically(ints));

		// Made generically, then used where its type is known.
		var made = makeGenerically(5, 600);
		Assert.equals(600, made[1]);
		made.push(700);
		made[0] = 9;
		Assert.equals(9, readGenerically(made, 0));
		Assert.equals(700, readGenerically(made, 2));
		Assert.equals("9,600,700", made.join(","));

		// What the callback methods make is made generically too.
		var large = ints.filter((value:Int) -> value > 100);
		Assert.equals("300,500", large.join(","));
		large[1] = 501;
		large.push(3);
		Assert.equals(300 + 501 + 3, large[0] + large[1] + large[2]);
		var doubled = ints.map((value:Int) -> value * 2);
		Assert.equals(14 + 600, doubled[0] + doubled[1]);
		Assert.equals("7,300", ints.slice(0, 2).join(","));
		Assert.equals("300,500", ints.concat().slice(1).join(","));

		// A write in a callback is seen by the loop calling it, which walks
		// the vector generically.
		var seen:Array<Int> = [];
		made.forEach(function(value:Int, index:Int) {
			seen.push(value);
			if (index == 0) {
				made[1] = 42;
			}
		});
		Assert.equals("9,42,700", seen.join(","));

		// Other element types, each kept as itself natively.
		var floats = makeGenerically(1.0, 2.5);
		floats.push(0.25);
		pushGenerically(floats, 4.0);
		Assert.equals(7.75, floats[0] + floats[1] + floats[2] + floats[3]);

		var strings = makeGenerically("a", "b");
		strings.push("c");
		pushGenerically(strings, "d");
		strings[0] = "A";
		Assert.equals("A,b,c,d", strings.join(","));
		Assert.equals("d", readGenerically(strings, 3));

		var flags = new Vector<Bool>();
		flags.push(true);
		pushGenerically(flags, false);
		Assert.isTrue(flags[0]);
		Assert.isFalse(flags[1]);

		var targets = new Vector<VectorCallbackTarget>();
		var target = new VectorCallbackTarget();
		pushGenerically(targets, target);
		Assert.equals(target, targets[0]);
		Assert.equals(0, targets.indexOf(target));

		#if cpp
		// Natively a Vector<Int> holds ints, as in ActionScript: a null put
		// in through a Vector<Dynamic> reads back as 0, and the loop walking
		// the vector reads it the same way after a callback's write has
		// converted the elements under it.
		var nulled = makeGenerically(1, 2);
		pushDynamic(nulled, null);
		var walked:Array<Int> = [];
		nulled.forEach(function(value:Int, index:Int) {
			walked.push(value);
			if (index == 0) {
				nulled[1] = 42;
			}
		});
		Assert.equals("1,42,0", walked.join(","));
		Assert.equals(0, nulled[2]);
		#end
	}

	/**
		A vector held as `Dynamic` still has its methods. `Vector` inlines
		`push`, `pop` and the others where they are called, so at run time
		they are found only because its class keeps them as well.
	**/
	public function testAVectorHeldAsDynamicHasItsMethods():Void {
		var vector = new Vector<Int>();
		var held:Dynamic = vector;
		held.push(1);
		held.push(2);
		held.unshift(0);
		held.insertAt(3, 3);
		Assert.equals("0,1,2,3", held.join(","));
		Assert.equals(2, held.indexOf(2, 0));
		Assert.equals(3, held.lastIndexOf(3, 0x7fffffff));
		Assert.equals(3, held.pop());
		Assert.equals(0, held.shift());
		Assert.equals(2, held.removeAt(1));
		held.push(5);
		Assert.equals("5,1", held.reverse().join(","));
		Assert.equals("1", held.slice(1, 16777215).join(","));
		Assert.equals("5,1", vector.join(","));
	}

	/**
		`for (item in vector)` and `for (index => item in vector)` walk the
		elements in order and, as an `Array`'s loop does, reach an element
		pushed while they run and not one removed.
	**/
	public function testAVectorIsWalkedByForIn():Void {
		var vector = Vector.ofArray([1, 2, 3]);
		var seen:Array<String> = [];
		for (item in vector) {
			seen.push("" + item);
			if (item == 1) {
				vector.push(4);
			}
		}
		Assert.equals("1,2,3,4", seen.join(","));

		seen = [];
		for (index => item in vector) {
			seen.push(index + ":" + item);
		}
		Assert.equals("0:1,1:2,2:3,3:4", seen.join(","));
		Assert.equals("1,2,3,4", joinGenerically(vector));

		seen = [];
		for (item in vector) {
			seen.push("" + item);
			vector.pop();
		}
		Assert.equals("1,2", seen.join(","));
	}

	/** `Vector.ofArray` and `toArray` copy, so neither side changes the other. **/
	public function testAVectorIsMadeFromAndTurnedIntoAnArray():Void {
		var array = [1, 2, 3];
		var vector = Vector.ofArray(array);
		array.push(4);
		vector[0] = 10;
		Assert.equals("10,2,3", vector.join(","));
		Assert.equals("1,2,3,4", array.join(","));

		var back = vector.toArray();
		back.push(5);
		Assert.equals(3, vector.length);
		Assert.equals("10,2,3,5", back.join(","));
	}

	/**
		A callback written where it is passed runs in the loop itself, so a
		`return` in it ends that one call; one passed as a value is evaluated
		once, after the vector, however many elements there are.
	**/
	public function testVectorCallbacksWrittenInPlaceOrPassedAsValues():Void {
		var vector = Vector.ofArray([1, 2, 3, 4]);
		var seen:Array<Int> = [];
		vector.forEach(function(item:Int) {
			if (item % 2 == 0) {
				return;
			}
			seen.push(item);
		});
		Assert.equals("1,3", seen.join(","));

		Assert.isTrue(vector.every(function(item:Int):Bool {
			if (item > 10) {
				return false;
			}
			return true;
		}));
		Assert.isTrue(vector.some(function(item:Int, index:Int):Bool {
			for (k in 0...index) {
				if (k == 2) {
					return true;
				}
			}
			return false;
		}));

		var order:Array<String> = [];
		var made:Int = 0;
		function source():Vector<Int> {
			order.push("vector");
			return vector;
		}
		function callback():Int->Void {
			order.push("callback");
			made++;
			return item -> seen.push(item);
		}
		seen = [];
		source().forEach(callback());
		Assert.equals("vector,callback", order.join(","));
		Assert.equals(1, made);
		Assert.equals("1,2,3,4", seen.join(","));

		Assert.equals(4, countGenerically(vector));
		Assert.equals("2,4", vector.filter((item:Int, index:Int, of:Vector<Int>) -> of[index] % 2 == 0).join(","));
		Assert.equals("1:4,2:4", vector.map((item:Int, index:Int, of:Vector<Int>) -> item + ":" + of.length).slice(0, 2).join(","));
	}

	/**
		`sort` orders by the comparator however it is given, keeps equal
		elements in their order, orders numbers and strings ascending without
		one, and agrees with `Array.sort` on a thousand numbers.
	**/
	public function testVectorSortIsStableAndAgreesWithArraySort():Void {
		var vector = Vector.ofArray([5, 3, 9, 1, 7, 2, 8]);
		Assert.equals("1,2,3,5,7,8,9", vector.sort().join(","));
		Assert.equals("9,8,7,5,3,2,1", vector.sort((a, b) -> b - a).join(","));
		var ascending = function(a:Int, b:Int):Int return a - b;
		Assert.equals("1,2,3,5,7,8,9", vector.sort(ascending).join(","));
		Assert.equals("9,8,7,5,3,2,1", sortGenerically(vector, (a:Int, b:Int) -> b - a));
		Assert.equals("apple,fig,pear", Vector.ofArray(["pear", "apple", "fig"]).sort().join(","));
		Assert.equals("1.25,2,3.5", Vector.ofArray([3.5, 1.25, 2.0]).sort(null).join(","));
		var loose:Vector<Dynamic> = Vector.ofArray(([3, 1, 2] : Array<Dynamic>));
		Assert.equals("1,2,3", loose.sort().join(","));

		// Stable: by the tens only, so each ten keeps its units in order.
		var keyed = Vector.ofArray([31, 12, 33, 11, 32, 13]);
		keyed.sort(function(a:Int, b:Int):Int {
			if (Std.int(a / 10) == Std.int(b / 10)) {
				return 0;
			}
			return Std.int(a / 10) - Std.int(b / 10);
		});
		Assert.equals("12,11,13,31,33,32", keyed.join(","));
		// And by a comparator that is a value, which sorts another way.
		var byTens = function(a:Int, b:Int):Int return Std.int(a / 10) - Std.int(b / 10);
		Assert.equals("12,11,13,31,33,32", Vector.ofArray([31, 12, 33, 11, 32, 13]).sort(byTens).join(","));

		var seed:Int = 12345;
		var numbers:Array<Int> = [];
		for (i in 0...1000) {
			seed = (seed * 1103515245 + 12345) & 0x7fffffff;
			numbers.push(seed % 500);
		}
		var expected:Array<Int> = numbers.copy();
		expected.sort((a, b) -> a - b);
		var ascending = expected.join(",");
		Assert.equals(ascending, Vector.ofArray(numbers).sort((a, b) -> a - b).join(","));
		var byValue = function(a:Int, b:Int):Int return a - b;
		Assert.equals(ascending, Vector.ofArray(numbers).sort(byValue).join(","));
		Assert.equals(ascending, Vector.ofArray(numbers).sort().join(","));
		Assert.equals(ascending, sortGenerically(Vector.ofArray(numbers), byValue));
		var texts:Array<String> = [for (n in numbers) "t" + n];
		var expectedTexts:Array<String> = texts.copy();
		expectedTexts.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		Assert.equals(expectedTexts.join(","), Vector.ofArray(texts).sort().join(","));

		#if !js
		// The sort merges between copies, so a comparator that throws leaves
		// the vector as it was. JavaScript sorts with its own, in place.
		var kept = Vector.ofArray([3, 1, 2]);
		Assert.raises(() -> kept.sort((a, b) -> throw "fail"));
		Assert.equals("3,1,2", kept.join(","));
		#end
	}

	static function sortGenerically<T>(vector:Vector<T>, compare:(T, T) -> Int):String {
		return vector.sort(compare).join(",");
	}

	static function joinGenerically<T>(vector:Vector<T>):String {
		var parts:Array<String> = [];
		for (item in vector) {
			parts.push(Std.string(item));
		}
		return parts.join(",");
	}

	static function countGenerically<T>(vector:Vector<T>):Int {
		var count:Int = 0;
		vector.forEach((item:T) -> count++);
		return count;
	}

	static function pushGenerically<T>(vector:Vector<T>, value:T):Void {
		vector.push(value);
	}

	static function readGenerically<T>(vector:Vector<T>, index:Int):T {
		return vector[index];
	}

	static function writeGenerically<T>(vector:Vector<T>, index:Int, value:T):Void {
		vector[index] = value;
	}

	static function lengthGenerically<T>(vector:Vector<T>):Int {
		return vector.length;
	}

	static function makeGenerically<T>(first:T, second:T):Vector<T> {
		var vector = new Vector<T>();
		vector.push(first);
		vector.push(second);
		return vector;
	}

	static function pushDynamic(vector:Vector<Dynamic>, value:Dynamic):Void {
		vector.push(value);
	}

	public function testVectorIterationStopsWhenACallbackShortensIt():Void {
		var vector = new Vector<String>();
		for (item in ["a", "b", "c", "d"]) {
			vector.push(item);
		}

		var seen:Array<String> = [];
		vector.forEach(function(item:String) {
			seen.push(item == null ? "NULL" : item);
			vector.pop();
		});

		Assert.equals("a,b", seen.join(","));
		Assert.equals("a,b", vector.join(","));
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

	/**
		A deque walks front to back, grows through a wrapped ring without
		losing order, and can be cleared and used again.
	**/
	public function testDequeIteratesGrowsAndClears():Void {
		var deque = new Deque<Int>(4);
		// Wrap the ring before it grows: take from the front, add at the back.
		for (i in 0...3) {
			deque.push(i);
		}
		Assert.equals(0, deque.pop());
		Assert.equals(1, deque.pop());
		for (i in 3...40) {
			deque.push(i);
		}
		for (i in 0...5) {
			deque.add(-1 - i);
		}
		var walked:Array<Int> = [for (x in deque) x];
		var expected:Array<Int> = [for (i in 0...5) -5 + i].concat([for (i in 2...40) i]);
		Assert.equals(expected.join(","), walked.join(","));
		Assert.equals(expected.length, deque.size());
		Assert.equals(-5, deque.first());
		Assert.equals(39, deque.last());
		Assert.equals(39, deque.remove());

		deque.clear();
		Assert.isTrue(deque.isEmpty());
		Assert.equals(0, [for (x in deque) x].length);
		Assert.raises(() -> deque.pop());
		deque.push(7);
		deque.add(6);
		Assert.equals("6,7", [for (x in deque) x].join(","));
	}

	#if jvm
	/**
		Adding and taking allocates nothing once the ring has grown, where a
		linked list would make a node for every item added.
	**/
	public function testADequeInSteadyStateAllocatesNothing():Void {
		var deque = new Deque<String>();
		var items = [for (i in 0...64) "item " + i];
		for (item in items) {
			deque.push(item);
		}
		for (_ in 0...64) {
			deque.push(deque.pop());
		}
		var perItem:Float = JvmAllocation.bytesBy(() -> {
			for (_ in 0...10000) {
				deque.push(deque.pop());
				deque.add(deque.remove());
			}
		}) / 20000;
		Assert.isTrue(perItem < 1, perItem + " bytes allocated per item added");
		Assert.equals(64, deque.size());
	}
	#end

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

	/**
		`IndexedMap` swaps its last entry into a removed one's place too, so
		its iterator cannot be the array's, which would skip the one swapped in
		when the entry a loop is on is removed. Two keys hold the same value
		here, so the loop has to tell entries apart by key.
	**/
	public function testIndexedMapRemovingWhileIteratingVisitsEachOnce():Void {
		var map = new IndexedMap<String>();
		for (i in 0...6) {
			map.set(i, "same");
		}
		// The entry the loop is on is always first here: each removal swaps
		// the last into its place, and the loop has to visit that one next.
		var visits:Int = 0;
		for (_ in map) {
			visits++;
			map.remove(map.keys()[0]);
		}
		Assert.equals(6, visits);
		Assert.equals(0, map.length());

		var distinct = new IndexedMap<String>();
		for (i in 0...6) {
			distinct.set(i, "v" + i);
		}
		var seen:Array<String> = [];
		for (value in distinct) {
			seen.push(value);
			var key:Int = Std.parseInt(value.substr(1));
			if (key % 2 == 0) {
				distinct.remove(key);
			}
		}
		seen.sort(Reflect.compare);
		Assert.equals("v0,v1,v2,v3,v4,v5", seen.join(","));
		Assert.equals(3, distinct.length());
	}

	/**
		`PackedSlotMap` moves its last entry into a removed one's place. An
		iterator over the value array would skip the entry moved in, and a
		`forEach` that counted the entries before it began would read past the
		end once one was removed.
	**/
	public function testPackedSlotMapRemovingWhileIteratingVisitsEachOnce():Void {
		var map = new PackedSlotMap<String>(8);
		for (_ in 0...6) {
			map.insert("same");
		}
		// The entry the loop is on is always the first dense one here.
		var visits:Int = 0;
		for (_ in map) {
			visits++;
			var slot:Int = map.slotAtDense(0);
			map.remove(SlotHandle.make(slot, map.currentGen(slot)));
		}
		Assert.equals(6, visits);
		Assert.equals(0, map.length);

		var numbers = new PackedSlotMap<Int>(8);
		for (i in 0...6) {
			numbers.insert(i);
		}
		var seen:Array<Int> = [];
		numbers.forEach((handle, value) -> {
			seen.push(value);
			if (value % 2 == 0) {
				numbers.remove(handle);
			}
		});
		seen.sort((a, b) -> a - b);
		Assert.equals("0,1,2,3,4,5", seen.join(","));
		Assert.equals(3, numbers.length);
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
		next. A value iterator that counted the entries when it was made would
		read past the end and throw on every target; a pair iterator that
		re-read the count would skip the entry moved into the gap.
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
		// Without removals the order is insertion order.
		var fresh = new ListedMap<String, Int>();
		for (i in 0...4) {
			fresh.set('f$i', i);
		}
		Assert.same([0, 1, 2, 3], [for (v in fresh) v]);
	}

	/**
		The same for `DenseSet`, whose array walked directly would visit 4 of 6
		when every even element is removed.
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

		The generation field is `GEN_BITS` wide and the counter is kept inside
		it. Kept outside, on the 256th reuse of a slot the handle would carry a
		truncated generation while the slot held the untruncated one. They would
		never compare equal again: `remove` would return false for ever, the
		entry would never be freed, and the map would grow a permanent leak of
		one slot per 256 reuses. Anything with entity churn passes 256 in
		seconds.
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
		its slot, as it would with an eight-bit generation 256 reuses later; and
		the free list hands the most recently freed slot back first, so those
		256 reuses would be one entity after another in the same place.
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

		A free list handing back the slot freed last would make that churn
		reuse one slot every tick, and a handle kept to the first entity (a
		missile's target) would resolve to the 2048th newcomer 34 seconds later
		at 60 Hz. Freed slots wait behind every other free one.
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
		An entry inserted as null is held like any other. Read from its value,
		whether a slot was held would skip a null entry in forEach, keep its
		generation through clear() and let it still be written through its old
		handle afterwards.
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
		A handle made up for a slot nobody holds cannot free it, even when it
		matches the free slot's generation: remove() freeing it a second time
		would take length to -1 and hand the slot to two inserts.
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
		// The sign bit is not part of the generation: if it were, past its
		// halfway point every handle would be negative, and at the top index a
		// live handle would be the INVALID sentinel itself.
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
		// clear() counts the generation masked: unmasked, a slot at the top of
		// its range would hold a value no handle could carry, and every entry
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

	/** And the same for the packed variant, which counts the same way. **/
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
		The count bound is on unless asked off: 100,000 entries, so a map made
		with a ttl alone does not hold whatever is put in it for as long as its
		ttl, however fast that is.
	**/
	public function testAnExpiringMapIsBoundedByDefault():Void {
		var map = new ExpiringMap<Int, Int>(3600);
		var evicted:Int = 0;
		map.onExpire = (key, value) -> evicted++;

		for (i in 0...100001) {
			map.set(i, i);
		}

		Assert.equals(100000, map.maxSize);
		Assert.equals(100000, map.length, "the map held " + map.length + " entries by default");
		Assert.equals(1, evicted);
		Assert.isNull(map.get(0), "the entry closest to expiring survived the bound");

		// 0 is no limit, asked for.
		var unbounded = new ExpiringMap<Int, Int>(3600, 0);
		for (i in 0...100001) {
			unbounded.set(i, i);
		}
		Assert.equals(100001, unbounded.length);
	}

	/**
		Bounds that are not bounds are refused with an error: a negative
		`maxSize`, which would otherwise read as no limit at all; a ttl of NaN,
		which would keep every entry for good, since no time is at or past it;
		and a ttl of 0.
	**/
	public function testAnExpiringMapRefusesBoundsThatAreNotBounds():Void {
		Assert.raises(() -> new ExpiringMap<String, Int>(10, -1), crossbyte.errors.ArgumentError);
		Assert.raises(() -> new ExpiringMap<String, Int>(Math.NaN), crossbyte.errors.ArgumentError);
		Assert.raises(() -> new ExpiringMap<String, Int>(0), crossbyte.errors.ArgumentError);
		Assert.raises(() -> new ExpiringMap<String, Int>(-5), crossbyte.errors.ArgumentError);

		var map = new ExpiringMap<String, Int>(10, 0, function():Float return 0);
		map.set("a", 1);
		Assert.raises(() -> map.sweep(Math.NaN), crossbyte.errors.ArgumentError);
		Assert.equals(1, map.sweep(20.0));
	}

	/**
		`length` leaves out what has expired and not been swept, as its
		documentation says, rather than counting them until a read or a sweep
		drops them.
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
		Touching an entry costs nothing to hold. A queue position left behind
		by every `set` and `touch`, collected only once everything ahead of it
		had expired, would make memory go with the touches times the ttl rather
		than the entries: 1,000 sessions touched 20 times a second with a 120 s
		ttl would hold 2.4 million positions, 70 MB on the jvm.
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

	/**
		Every kind of node is found as `==` finds it: strings and integers by
		value, objects and enum values by identity, the rest by comparison.
	**/
	public function testWeightedGraphFindsEveryKindOfNode():Void {
		var ints = new WeightedGraph<Int>();
		ints.addEdge(1, 2, 0.5);
		ints.addEdge(1, 1000000, 2);
		ints.addEdge(-7, 1, 1);
		Assert.equals(2, ints.getNeighbors(1).length);
		Assert.notNull(ints.getNeighbors(1000000));
		Assert.equals(1, ints.getNeighbors(-7).length);
		Assert.isNull(ints.getNeighbors(3));

		var enums = new WeightedGraph<haxe.io.Error>();
		enums.addEdge(haxe.io.Error.Blocked, haxe.io.Error.Overflow, 1);
		Assert.equals(1, enums.getNeighbors(haxe.io.Error.Blocked).length);

		var floats = new WeightedGraph<Float>();
		floats.addEdge(0.5, 1.5, 3);
		floats.addNode(0.5);
		Assert.equals(1, floats.getNeighbors(0.5).length);
		Assert.notNull(floats.getNeighbors(1.5));

		var strings = new WeightedGraph<String>();
		strings.addEdge("a", "b", 1);
		Assert.equals(1, strings.getNeighbors("a" + "").length);
	}

	/**
		Building a graph costs what its nodes do, not their square: a lookup
		that was a pass over every node would make 20,000 edges in a chain take
		about ten seconds on eval.
	**/
	public function testWeightedGraphLookupIsNotAPassOverTheNodes():Void {
		var graph = new WeightedGraph<Int>();
		var started:Float = haxe.Timer.stamp();
		for (i in 0...20000) {
			graph.addEdge(i, i + 1, 1.0);
		}
		var took:Float = haxe.Timer.stamp() - started;
		Assert.equals(1, graph.getNeighbors(19999).length);
		Assert.isTrue(took < 1.0, "20,000 edges took " + took + " s");
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

private class SwitchTableOpcodes {
	public static inline var PING:Int = 1;
	public static inline var LOGIN:Int = 2;
}

/**
	A plain object whose methods `testVectorCallbacksReachedThroughReflectGetTheirArguments`
	pulls off with `Reflect.field`, one of each arity a `Vector` callback can take.
**/
private class VectorCallbackTarget {
	public var seen:Array<String> = [];

	public function new() {}

	public function none():Void {
		seen.push("none()");
	}

	public function one(item:Int):Void {
		seen.push("one(" + item + ")");
	}

	public function two(item:Int, index:Int):Void {
		seen.push("two(" + item + "," + index + ")");
	}

	public function three(item:Int, index:Int, of:Vector<Int>):Void {
		seen.push("three(" + item + "," + index + "," + (of == null ? "NULL" : "len" + of.length) + ")");
	}
}
