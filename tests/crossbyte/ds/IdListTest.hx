package crossbyte.ds;

import utest.Assert;

/**
	The interest loop (a grid query per observer, its ids added to the
	observer's `InterestSet`, a commit) allocates nothing per id per tick
	on the jvm and Node, where `Array<Int>`s would cost 2.2 MB a tick for
	1,000 views of 50: every one boxes ids above 127 on the jvm, and every
	one emptied with `resize(0)` gives V8 its store back. The lists are
	vectors with counts, and a query can fill an `IdList`.

	The allocation cases are measured on the jvm, whose per-thread allocation
	counter is exact. Elsewhere the same code runs for its answers.
**/
class IdListTest extends utest.Test {
	public function testAListKeepsItsIdsAndItsStorage():Void {
		var list = new IdList(2);
		for (i in 0...100) {
			list.push(1000 + i);
		}
		Assert.equals(100, list.length);
		Assert.equals(1000, list.get(0));
		Assert.equals(1099, list.get(99));
		Assert.raises(() -> list.get(100));
		Assert.raises(() -> list.get(-1));

		var sum:Int = 0;
		for (id in list) {
			sum += id;
		}
		Assert.equals(100 * 1000 + 4950, sum);
		Assert.equals(100, list.toArray().length);

		var storage = @:privateAccess list.__ids;
		list.clear();
		Assert.equals(0, list.length);
		for (_ in list) {
			Assert.fail("an emptied list had an id");
		}
		list.push(-7);
		Assert.equals(-7, list.get(0));
		Assert.isTrue(storage == @:privateAccess list.__ids, "emptying the list gave its storage away");
	}

	/** An id query answers exactly what the array query answers. **/
	public function testIdQueriesFindWhatArrayQueriesFind():Void {
		var seed:Int = 99;
		function next():Float {
			seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
			return seed / 2147483648.0;
		}
		var grid = new SpatialGrid(-500, -500, 1000, 1000, 50);
		var grid3 = new SpatialGrid3D(-500, -500, -500, 1000, 1000, 1000, 100);
		for (id in 0...2000) {
			grid.set(id * 3, next() * 1200 - 600, next() * 1200 - 600);
			grid3.set(id * 3, next() * 1200 - 600, next() * 1200 - 600, next() * 1200 - 600);
		}

		var list = new IdList();
		var mismatches:Array<String> = [];
		for (q in 0...200) {
			var x:Float = next() * 1200 - 600;
			var y:Float = next() * 1200 - 600;
			var z:Float = next() * 1200 - 600;
			var r:Float = next() * 120;

			list.clear();
			if (!__same(grid.queryCircle(x, y, r), grid.queryCircleIds(x, y, r, list))) {
				mismatches.push('circle $q');
			}
			list.clear();
			if (!__same(grid.queryRect(x, y, r, r * 0.5), grid.queryRectIds(x, y, r, r * 0.5, list))) {
				mismatches.push('rect $q');
			}
			list.clear();
			if (!__same(grid3.querySphere(x, y, z, r), grid3.querySphereIds(x, y, z, r, list))) {
				mismatches.push('sphere $q');
			}
			list.clear();
			if (!__same(grid3.queryBox(x, y, z, r, r * 0.5, r * 2), grid3.queryBoxIds(x, y, z, r, r * 0.5, r * 2, list))) {
				mismatches.push('box $q');
			}
		}
		Assert.same([], mismatches);

		// Nothing is found, and nothing is cleared, for a shape that reaches
		// nothing.
		list.clear();
		list.push(1);
		grid.queryCircleIds(0, 0, -1, list);
		grid.queryCircleIds(Math.NaN, 0, 10, list);
		grid.queryRectIds(0, 0, 0, 10, list);
		Assert.equals(1, list.length);
	}

	/** Adding a list is adding each id, duplicates included. **/
	public function testAddAllIsAddingEach():Void {
		var one = new InterestSet();
		var each = new InterestSet();
		var list = new IdList();
		for (id in [5, 900, 5, 70000, 3]) {
			list.push(id);
			each.add(id);
		}
		one.addAll(list);
		var enteredOne:Array<Int> = [];
		var enteredEach:Array<Int> = [];
		one.commit(id -> enteredOne.push(id));
		each.commit(id -> enteredEach.push(id));
		Assert.equals("5,900,70000,3", enteredOne.join(","));
		Assert.equals(enteredEach.join(","), enteredOne.join(","));
		Assert.equals(4, one.length);
	}

	#if jvm
	/**
		A round of an observer's interest (ids added, then committed)
		allocates nothing once the set has grown to it: no id above 127 is
		boxed as it goes into the round's list, and no word of its bits is
		boxed as it changes.
	**/
	public function testAnInterestRoundAllocatesNothingOnceGrown():Void {
		var set = new InterestSet(8192);
		// Half the view changes each round, so ids enter and leave. Written
		// out in each loop: a local function called with an Int would box
		// it on the jvm and be counted.
		for (r in 0...200) {
			var first:Int = (r & 1) == 0 ? 5000 : 5025;
			for (id in first...first + 50) {
				set.add(id);
			}
			set.commit();
		}
		var perRound:Float = JvmAllocation.bytesBy(() -> {
			for (r in 0...200) {
				var first:Int = (r & 1) == 0 ? 5000 : 5025;
				for (id in first...first + 50) {
					set.add(id);
				}
				set.commit();
			}
		}) / 200;
		Assert.isTrue(perRound < 16, perRound + " bytes allocated per round");
		Assert.equals(50, set.length);
	}

	/** And the query that feeds it, into an `IdList`. **/
	public function testAQueryIntoAListAllocatesNothingOnceGrown():Void {
		var grid = new SpatialGrid(0, 0, 1000, 1000, 100, 8192);
		for (i in 0...400) {
			grid.set(5000 + i, (i % 20) * 10.0 + 0.5, Std.int(i / 20) * 10.0 + 0.5);
		}
		var set = new InterestSet(8192);
		var list = new IdList();
		for (t in 0...200) {
			list.clear();
			grid.queryCircleIds(50 + (t & 7) * 5.0, 50, 60, list);
			set.addAll(list);
			set.commit();
		}
		var perTick:Float = JvmAllocation.bytesBy(() -> {
			for (t in 0...200) {
				list.clear();
				grid.queryCircleIds(50 + (t & 7) * 5.0, 50, 60, list);
				set.addAll(list);
				set.commit();
			}
		}) / 200;
		Assert.isTrue(perTick < 16, perTick + " bytes allocated per tick");
		Assert.isTrue(set.length > 50, "the query found " + set.length);
	}

	#end

	private static function __same(array:Array<Int>, list:IdList):Bool {
		if (array.length != list.length) {
			return false;
		}
		var fromList:Array<Int> = list.toArray();
		var sortedArray:Array<Int> = array.copy();
		sortedArray.sort((a, b) -> a - b);
		fromList.sort((a, b) -> a - b);
		return sortedArray.join(",") == fromList.join(",");
	}
}
