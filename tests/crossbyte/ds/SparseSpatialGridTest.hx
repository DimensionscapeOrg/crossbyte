package crossbyte.ds;

import crossbyte.errors.ArgumentError;
import crossbyte.math.Rectangle;
import utest.Assert;

/**
	`SparseSpatialGrid`: the dense grid's questions with no bounds, its cells
	hashed by their coordinates. Every query is checked against a brute-force
	answer, as `SpatialGridTest` checks the dense grid's, and the same moves
	are run through both grids where the dense one can hold them.
**/
class SparseSpatialGridTest extends utest.Test {
	private var seed:Int;

	public function setup():Void {
		seed = 0x2545F491;
	}

	private function random(bound:Int):Int {
		seed ^= seed << 13;
		seed ^= seed >>> 17;
		seed ^= seed << 5;
		return (seed & 0x7FFFFFFF) % bound;
	}

	// A coordinate in hundredths, from `low` up to but not including `high`.
	private function coordinate(low:Int, high:Int):Float {
		return low + random((high - low) * 100) / 100;
	}

	private static function sorted(ids:Array<Int>):String {
		final copy:Array<Int> = ids.copy();
		copy.sort((a, b) -> a - b);
		return copy.join(",");
	}

	private static function within(xs:Array<Float>, ys:Array<Float>, held:Array<Bool>, x:Float, y:Float, radius:Float):Array<Int> {
		return [
			for (id in 0...xs.length)
				if (held[id] && (xs[id] - x) * (xs[id] - x) + (ys[id] - y) * (ys[id] - y) <= radius * radius) id
		];
	}

	public function testACircleFindsExactlyWhatIsWithinItsRadius():Void {
		final grid = new SparseSpatialGrid(50);
		final xs:Array<Float> = [];
		final ys:Array<Float> = [];
		final held:Array<Bool> = [];
		// Either side of the origin: negative cells as many as positive.
		for (id in 0...2000) {
			xs.push(coordinate(-1100, 1100));
			ys.push(coordinate(-1100, 1100));
			held.push(true);
			grid.set(id, xs[id], ys[id]);
		}

		final mismatches:Array<String> = [];
		for (q in 0...300) {
			final x:Float = coordinate(-1200, 1200);
			final y:Float = coordinate(-1200, 1200);
			final radius:Float = coordinate(0, 300);
			final found:Array<Int> = grid.queryCircle(x, y, radius);
			final expected:Array<Int> = within(xs, ys, held, x, y, radius);
			if (sorted(found) != sorted(expected)) {
				mismatches.push('query $q at ($x, $y) radius $radius: ${found.length}, not ${expected.length}');
			}
			final ids = grid.queryCircleIds(x, y, radius, new IdList());
			if (sorted(ids.toArray()) != sorted(expected)) {
				mismatches.push('query $q into a list: ${ids.length}, not ${expected.length}');
			}
		}

		Assert.same([], mismatches);
		Assert.equals(2000, grid.length);
	}

	public function testEveryQueryStaysExactAsThingsMove():Void {
		// Small cells (many, in a table that grows and loses them as things
		// cross), ordinary ones, and one cell holding everything.
		for (cellSize in [7.0, 100.0, 5000.0]) {
			final grid = new SparseSpatialGrid(cellSize, 0);
			final xs:Array<Float> = [];
			final ys:Array<Float> = [];
			final held:Array<Bool> = [];
			for (id in 0...500) {
				xs.push(coordinate(-1000, 1000));
				ys.push(coordinate(-1000, 1000));
				held.push(true);
				grid.set(id, xs[id], ys[id]);
			}

			final mismatches:Array<String> = [];
			for (round in 0...40) {
				for (id in 0...500) {
					switch (random(12)) {
						case 0:
							// A jump anywhere.
							xs[id] = coordinate(-1200, 1200);
							ys[id] = coordinate(-1200, 1200);
						case 1:
							// Staying exactly where it is.
						case 2:
							// Gone, and back later.
							if (held[id]) {
								if (!grid.remove(id)) {
									mismatches.push('id $id was held and not removed');
								}
								held[id] = false;
								continue;
							}
						default:
							// A small step, usually within the same cell.
							xs[id] += coordinate(-3, 3);
							ys[id] += coordinate(-3, 3);
					}
					held[id] = true;
					grid.set(id, xs[id], ys[id]);
				}

				for (q in 0...20) {
					final x:Float = coordinate(-1100, 1100);
					final y:Float = coordinate(-1100, 1100);
					final radius:Float = coordinate(0, 250);
					final found:Array<Int> = grid.queryCircle(x, y, radius);
					final expected:Array<Int> = within(xs, ys, held, x, y, radius);
					if (sorted(found) != sorted(expected)) {
						mismatches.push('cell $cellSize, round $round, query $q: ${found.length}, not ${expected.length}');
					}
				}
			}

			Assert.same([], mismatches);
			Assert.equals([for (h in held) if (h) 1].length, grid.length);
		}
	}

	public function testItAnswersAsTheDenseGridDoesWithinItsBounds():Void {
		final dense = new SpatialGrid(-1000, -1000, 2000, 2000, 40);
		final sparse = new SparseSpatialGrid(40);
		for (id in 0...1500) {
			final x:Float = coordinate(-1000, 1000);
			final y:Float = coordinate(-1000, 1000);
			dense.set(id, x, y);
			sparse.set(id, x, y);
		}
		final mismatches:Array<String> = [];
		for (q in 0...300) {
			final x:Float = coordinate(-1000, 1000);
			final y:Float = coordinate(-1000, 1000);
			final r:Float = coordinate(0, 200);
			if (sorted(dense.queryCircle(x, y, r)) != sorted(sparse.queryCircle(x, y, r))) {
				mismatches.push('circle $q');
			}
			final w:Float = coordinate(1, 300);
			final h:Float = coordinate(1, 300);
			if (sorted(dense.queryRect(x, y, w, h)) != sorted(sparse.queryRect(x, y, w, h))) {
				mismatches.push('rect $q');
			}
		}
		Assert.same([], mismatches);
	}

	public function testARectangleFindsWhatRectangleContainsWould():Void {
		final grid = new SparseSpatialGrid(40);
		final xs:Array<Float> = [];
		final ys:Array<Float> = [];
		for (id in 0...1500) {
			// Whole numbers, so plenty of points sit exactly on an edge, and
			// on the edges of cells either side of zero.
			xs.push(random(1100) - 550);
			ys.push(random(1100) - 550);
			grid.set(id, xs[id], ys[id]);
		}

		final mismatches:Array<String> = [];
		for (q in 0...300) {
			final rect = new Rectangle(random(1100) - 550, random(1100) - 550, random(300) + 1, random(300) + 1);
			final found:Array<Int> = grid.queryRect(rect.x, rect.y, rect.width, rect.height);
			final expected:Array<Int> = [for (id in 0...xs.length) if (rect.contains(xs[id], ys[id])) id];
			if (sorted(found) != sorted(expected)) {
				mismatches.push('query $q $rect: ${found.length}, not ${expected.length}');
			}
			final ids = grid.queryRectIds(rect.x, rect.y, rect.width, rect.height, new IdList());
			if (sorted(ids.toArray()) != sorted(expected)) {
				mismatches.push('query $q $rect into a list: ${ids.length}, not ${expected.length}');
			}
		}

		Assert.same([], mismatches);
	}

	public function testCellsEitherSideOfZeroAreApart():Void {
		// Rounded down, not toward zero: -0.5 is in cell -1 and 0.5 in cell 0,
		// so a query of cell 0 alone does not see -0.5.
		final grid = new SparseSpatialGrid(1);
		grid.set(1, -0.5, -0.5);
		grid.set(2, 0.5, 0.5);
		grid.set(3, -0.5, 0.5);
		Assert.equals(3, grid.cellCount);
		Assert.same([2], grid.queryRect(0, 0, 1, 1));
		Assert.same([1], grid.queryRect(-1, -1, 1, 1));
		Assert.same([3], grid.queryRect(-1, 0, 1, 1));
		Assert.equals("1,2,3", sorted(grid.queryCircle(0, 0, 1)));
		// A cell's lower edges are its own; its upper edges the next cell's.
		grid.set(4, -1, -1);
		grid.set(5, 1, 1);
		Assert.equals("1,4", sorted(grid.queryRect(-1, -1, 1, 1)));
		Assert.same([5], grid.queryRect(1, 1, 1, 1));
	}

	public function testPositionsFarFromTheOriginAreFiledAndFound():Void {
		final grid = new SparseSpatialGrid(10);
		grid.set(1, 1e9, -1e9);
		grid.set(2, -3.5e12, 7e11);
		grid.set(3, 5, 5);
		// Past MAX_CELL cells: filed at the limit, and found there.
		grid.set(4, 1e300, 1e300);
		grid.set(5, Math.NEGATIVE_INFINITY, 0);
		grid.set(6, 1e301, 1e300);
		// 4 and 6 share the cell at the limit; 2 is past it on both axes.
		Assert.equals(5, grid.cellCount);
		Assert.same([1], grid.queryCircle(1e9 + 3, -1e9 - 4, 5));
		Assert.same([2], grid.queryCircle(-3.5e12, 7e11, 1));
		Assert.same([2], grid.queryRect(-3.5e12 - 1, 7e11 - 1, 2, 2));
		Assert.same([], grid.queryCircle(1e9 + 30, -1e9, 5));
		Assert.same([4], grid.queryCircle(1e300, 1e300, 1));
		Assert.same([6], grid.queryRect(1e301 - 1e290, 1e300 - 1e290, 2e290, 2e290));
		Assert.equals("1,2,3,4,5,6", sorted(grid.queryCircle(0, 0, Math.POSITIVE_INFINITY)));
		// A far-flung id is one more cell, not a structure the size of the
		// distance: the table holds at most twice the cells held.
		@:privateAccess Assert.isTrue(grid.__slotHead.length <= 16, 'a table of ${@:privateAccess grid.__slotHead.length} for 6 cells');
		// Moving one far away and back.
		grid.set(3, -1e15, 1e15);
		Assert.same([3], grid.queryCircle(-1e15, 1e15, 1));
		grid.set(3, 5, 5);
		Assert.same([3], grid.queryCircle(5, 5, 1));
		Assert.same([], grid.queryCircle(-1e15, 1e15, 1e10));
	}

	public function testAQueryOverMoreCellsThanAreHeldWalksThoseHeld():Void {
		// A view of a light-year with cells of a metre is 10^31 cells; a few
		// things held, and the query visits the few cells they are in.
		final grid = new SparseSpatialGrid(1);
		final xs:Array<Float> = [];
		final ys:Array<Float> = [];
		final held:Array<Bool> = [];
		for (id in 0...200) {
			xs.push(coordinate(-30000, 30000) * 1e5);
			ys.push(coordinate(-30000, 30000) * 1e5);
			held.push(true);
			grid.set(id, xs[id], ys[id]);
		}
		final mismatches:Array<String> = [];
		for (q in 0...100) {
			final x:Float = coordinate(-30000, 30000) * 1e5;
			final y:Float = coordinate(-30000, 30000) * 1e5;
			final radius:Float = coordinate(0, 20000) * 1e5;
			if (sorted(grid.queryCircle(x, y, radius)) != sorted(within(xs, ys, held, x, y, radius))) {
				mismatches.push('circle $q');
			}
			final w:Float = coordinate(1, 20000) * 1e5;
			final found = grid.queryRect(x, y, w, w);
			final expected = [for (id in 0...xs.length) if (xs[id] >= x && ys[id] >= y && xs[id] < x + w && ys[id] < y + w) id];
			if (sorted(found) != sorted(expected)) {
				mismatches.push('rect $q');
			}
		}
		Assert.same([], mismatches);
	}

	public function testCellsThatEmptyAreLetGoAndMadeAgain():Void {
		final grid = new SparseSpatialGrid(10);
		for (id in 0...30) {
			// Three to a cell, ten cells.
			grid.set(id, (id % 10) * 10 + 5, 5);
		}
		Assert.equals(10, grid.cellCount);
		// Emptying a cell takes it out of the table.
		Assert.isTrue(grid.remove(4));
		Assert.isTrue(grid.remove(14));
		Assert.equals(10, grid.cellCount);
		Assert.isTrue(grid.remove(24));
		Assert.equals(9, grid.cellCount);
		Assert.same([], grid.queryRect(40, 0, 10, 10));
		// Moving every id out of a cell takes it out too.
		for (id in [5, 15, 25]) {
			grid.set(id, 1000, 1000);
		}
		Assert.equals(9, grid.cellCount);
		Assert.same([], grid.queryRect(50, 0, 10, 10));
		// And a cell comes back when something does.
		grid.set(4, 45, 5);
		Assert.equals(10, grid.cellCount);
		Assert.same([4], grid.queryRect(40, 0, 10, 10));
		Assert.equals("5,15,25", sorted(grid.queryCircle(1000, 1000, 1)));
		// Many cells made and let go, in a table that keeps its runs whole:
		// what is held is still found, and nothing else.
		final big = new SparseSpatialGrid(1, 0);
		for (round in 0...20) {
			for (id in 0...300) {
				big.set(id, round * 1000 + id * 3, -id * 7);
			}
			for (id in 0...300) {
				if ((id + round) % 3 == 0) {
					big.remove(id);
				}
			}
		}
		final expected:Array<Int> = [for (id in 0...300) if ((id + 19) % 3 != 0) id];
		Assert.equals(expected.length, big.length);
		Assert.equals(expected.length, big.cellCount);
		Assert.equals(sorted(expected), sorted(big.queryRect(19000, -3000, 1000, 3001)));
		for (id in expected) {
			if (big.queryCircle(19000 + id * 3, -id * 7, 0.5).join(",") != '$id') {
				Assert.fail('id $id was not found alone at its place');
			}
		}
	}

	public function testRemovedIdsAreNotFoundAgain():Void {
		final grid = new SparseSpatialGrid(10);
		for (id in 0...90) {
			// Nine to a cell, so removals come off the head, middle and tail.
			grid.set(id, (id % 10) * 10 + 5, Std.int(id / 10) * 10 + 5);
		}

		final kept:Array<Int> = [];
		for (id in 0...90) {
			if (id % 3 == 0) {
				Assert.isTrue(grid.remove(id));
			} else {
				kept.push(id);
			}
		}

		Assert.equals(60, grid.length);
		Assert.equals(sorted(kept), sorted(grid.queryCircle(50, 50, 1000)));
		Assert.isFalse(grid.has(3));
		Assert.isTrue(grid.has(4));
		Assert.isFalse(grid.remove(3), "removing twice");
		Assert.isFalse(grid.remove(5000), "removing an id never given");
		Assert.isFalse(grid.remove(-1), "removing a negative id");
		Assert.equals(60, grid.length);
	}

	public function testSettingAnIdAgainMovesIt():Void {
		final grid = new SparseSpatialGrid(50);
		grid.set(5, 10, 10);
		grid.set(5, -900, 900);

		Assert.equals(1, grid.length);
		Assert.equals(1, grid.cellCount);
		Assert.same([], grid.queryCircle(10, 10, 20));
		Assert.same([5], grid.queryCircle(-900, 900, 20));
	}

	public function testAPointExactlyOnTheRadiusIsInside():Void {
		final grid = new SparseSpatialGrid(10);
		grid.set(1, -30, 40); // 50 from the origin
		grid.set(2, -30, 41);

		Assert.same([1], grid.queryCircle(0, 0, 50));
	}

	public function testAQueryThatCannotReachAnythingFindsNothing():Void {
		final grid = new SparseSpatialGrid(10);
		grid.set(1, 50, 50);

		Assert.same([], grid.queryCircle(50, 50, -1));
		Assert.same([], grid.queryCircle(50, 50, Math.NaN));
		Assert.same([], grid.queryCircle(Math.NaN, 50, 10));
		Assert.same([], grid.queryCircle(50, Math.NaN, 10));
		Assert.same([], grid.queryRect(40, 40, 0, 20));
		Assert.same([], grid.queryRect(40, 40, 20, -1));
		Assert.same([], grid.queryRect(Math.NaN, 40, 20, 20));
		Assert.same([], grid.queryCircle(5000, 5000, 10));
	}

	public function testAFoundArrayIsAddedTo():Void {
		final grid = new SparseSpatialGrid(10);
		grid.set(7, 50, 50);
		final found:Array<Int> = [99];

		Assert.equals(found, grid.queryCircle(50, 50, 1, found));
		Assert.same([99, 7], found);
	}

	public function testIdsBeyondTheStartingCapacityAreMadeRoomFor():Void {
		final grid = new SparseSpatialGrid(10, 0);
		grid.set(10000, 20, 20);
		grid.set(3, 25, 25);

		Assert.isTrue(grid.has(10000));
		Assert.isFalse(grid.has(9999));
		Assert.equals("3,10000", sorted(grid.queryCircle(20, 20, 10)));
	}

	public function testClearTakesEverythingOut():Void {
		final grid = new SparseSpatialGrid(10);
		for (id in 0...50) {
			grid.set(id, id * 20, -id * 20);
		}
		grid.clear();

		Assert.equals(0, grid.length);
		Assert.equals(0, grid.cellCount);
		Assert.same([], grid.queryCircle(0, 0, 10000));
		Assert.isFalse(grid.has(10));

		grid.set(10, 5, 5);
		Assert.same([10], grid.queryCircle(5, 5, 1));
		Assert.equals(1, grid.length);
		Assert.equals(1, grid.cellCount);
	}

	public function testWhatCannotBeFiledIsRefused():Void {
		final grid = new SparseSpatialGrid(10);
		Assert.raises(() -> grid.set(-1, 5, 5), ArgumentError);
		Assert.raises(() -> grid.set(1, Math.NaN, 5), ArgumentError);
		Assert.raises(() -> grid.set(1, 5, Math.NaN), ArgumentError);
		Assert.equals(0, grid.length);
		for (id in [SparseSpatialGrid.MAX_ID + 1, 0x7FFFFFFF]) {
			try {
				grid.set(id, 5, 5);
				Assert.fail('id $id was taken');
			} catch (e:ArgumentError) {}
		}
		Assert.equals(0, grid.length);
		Assert.equals(0, grid.cellCount);
	}

	public function testACellSizeTheGridCannotUseIsRefused():Void {
		Assert.raises(() -> new SparseSpatialGrid(0), ArgumentError);
		Assert.raises(() -> new SparseSpatialGrid(-1), ArgumentError);
		Assert.raises(() -> new SparseSpatialGrid(Math.NaN), ArgumentError);
		Assert.raises(() -> new SparseSpatialGrid(Math.POSITIVE_INFINITY), ArgumentError);
		Assert.raises(() -> new SparseSpatialGrid(1e-320), ArgumentError);
		Assert.raises(() -> new SparseSpatialGrid(10, -1), ArgumentError);
		// Cells larger than anything: one cell holds it all.
		final one = new SparseSpatialGrid(1e300);
		one.set(1, 0, 0);
		one.set(2, 1e10, -1e10);
		Assert.equals(2, one.cellCount);
		Assert.equals("1,2", sorted(one.queryCircle(0, 0, 1e11)));
	}

	public function testMovingAndAskingAllocateNothing():Void {
		if (!crossbyte.test.AllocationMeter.SUPPORTED) {
			Assert.pass();
			return;
		}
		final world = new SparseWorld(2000, 40);
		// Warm: a whole round of going away and coming back, so the table is
		// at its largest and every list grown.
		for (_ in 0...1100) {
			world.step();
		}
		final reading = crossbyte.test.AllocationMeter.measure(world.step, 100);
		Assert.isTrue(reading.perOperation == 0, 'a step of moves and views allocated $reading');
		Assert.isTrue(world.found > 0);
	}
}

/** Things wandering an open plane, crossing cells and going far away, and views of them. **/
private class SparseWorld {
	public var found:Int = 0;

	final grid:SparseSpatialGrid;
	// Vectors: an Array<Float> boxes on the jvm.
	final xs:haxe.ds.Vector<Float>;
	final ys:haxe.ds.Vector<Float>;
	final view = new IdList();
	final count:Int;
	var tick:Int = 0;

	public function new(count:Int, cellSize:Float) {
		this.count = count;
		grid = new SparseSpatialGrid(cellSize);
		xs = new haxe.ds.Vector<Float>(count);
		ys = new haxe.ds.Vector<Float>(count);
		for (id in 0...count) {
			xs[id] = (id * 37) % 4000 - 2000.0;
			ys[id] = (id * 91) % 4000 - 2000.0;
			grid.set(id, xs[id], ys[id]);
		}
	}

	public function step():Void {
		tick++;
		for (id in 0...count) {
			xs[id] += ((id + tick) % 7) - 3.0;
			ys[id] += ((id * 3 + tick) % 5) - 2.0;
			if ((id + tick) % 500 == 0) {
				// Off a long way, and back the next time round.
				xs[id] = xs[id] > 1e5 || xs[id] < -1e5 ? xs[id] / -1000.0 : xs[id] * -1000.0;
			}
			grid.set(id, xs[id], ys[id]);
		}
		for (o in 0...16) {
			view.clear();
			grid.queryCircleIds(xs[o * 7], ys[o * 7], 40, view);
			found += view.length;
		}
	}
}
