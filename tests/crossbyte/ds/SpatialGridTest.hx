package crossbyte.ds;

import crossbyte.errors.ArgumentError;
import crossbyte.math.Rectangle;
import utest.Assert;

class SpatialGridTest extends utest.Test {
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
		var copy:Array<Int> = ids.copy();
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
		var grid = new SpatialGrid(0, 0, 1000, 1000, 50);
		var xs:Array<Float> = [];
		var ys:Array<Float> = [];
		var held:Array<Bool> = [];
		// A tenth of them outside the bounds, which are filed at the edge.
		for (id in 0...2000) {
			xs.push(coordinate(-100, 1100));
			ys.push(coordinate(-100, 1100));
			held.push(true);
			grid.set(id, xs[id], ys[id]);
		}

		var mismatches:Array<String> = [];
		for (q in 0...300) {
			var x:Float = coordinate(-200, 1200);
			var y:Float = coordinate(-200, 1200);
			var radius:Float = coordinate(0, 300);
			var found:Array<Int> = grid.queryCircle(x, y, radius);
			var expected:Array<Int> = within(xs, ys, held, x, y, radius);
			if (sorted(found) != sorted(expected)) {
				mismatches.push('query $q at ($x, $y) radius $radius: ${found.length}, not ${expected.length}');
			}
		}

		Assert.same([], mismatches);
		Assert.equals(2000, grid.length);
	}

	public function testEveryQueryStaysExactAsThingsMove():Void {
		// Small cells, ordinary ones, and one cell holding everything -- the
		// last is a single list that every move relinks and every unlink
		// edits, head, middle and tail.
		for (cellSize in [7.0, 100.0, 1000.0]) {
			var grid = new SpatialGrid(0, 0, 1000, 1000, cellSize);
			var xs:Array<Float> = [];
			var ys:Array<Float> = [];
			var held:Array<Bool> = [];
			for (id in 0...500) {
				xs.push(coordinate(0, 1000));
				ys.push(coordinate(0, 1000));
				held.push(true);
				grid.set(id, xs[id], ys[id]);
			}

			var mismatches:Array<String> = [];
			for (round in 0...40) {
				for (id in 0...500) {
					switch (random(10)) {
						case 0:
							// A jump anywhere, sometimes out of bounds.
							xs[id] = coordinate(-200, 1200);
							ys[id] = coordinate(-200, 1200);
						case 1:
							// Staying exactly where it is.
						default:
							// A small step, usually within the same cell.
							xs[id] += coordinate(-3, 3);
							ys[id] += coordinate(-3, 3);
					}
					grid.set(id, xs[id], ys[id]);
				}

				for (q in 0...20) {
					var x:Float = coordinate(-100, 1100);
					var y:Float = coordinate(-100, 1100);
					var radius:Float = coordinate(0, 250);
					var found:Array<Int> = grid.queryCircle(x, y, radius);
					var expected:Array<Int> = within(xs, ys, held, x, y, radius);
					if (sorted(found) != sorted(expected)) {
						mismatches.push('cell $cellSize, round $round, query $q: ${found.length}, not ${expected.length}');
					}
				}
			}

			Assert.same([], mismatches);
			Assert.equals(500, grid.length);
		}
	}

	public function testARectangleFindsWhatRectangleContainsWould():Void {
		var grid = new SpatialGrid(0, 0, 1000, 1000, 40);
		var xs:Array<Float> = [];
		var ys:Array<Float> = [];
		for (id in 0...1500) {
			// Whole numbers, so plenty of points sit exactly on an edge.
			xs.push(random(1100) - 50);
			ys.push(random(1100) - 50);
			grid.set(id, xs[id], ys[id]);
		}

		var mismatches:Array<String> = [];
		for (q in 0...300) {
			var rect = new Rectangle(random(1100) - 50, random(1100) - 50, random(300) + 1, random(300) + 1);
			var found:Array<Int> = grid.queryRect(rect.x, rect.y, rect.width, rect.height);
			var expected:Array<Int> = [for (id in 0...xs.length) if (rect.contains(xs[id], ys[id])) id];
			if (sorted(found) != sorted(expected)) {
				mismatches.push('query $q $rect: ${found.length}, not ${expected.length}');
			}
		}

		Assert.same([], mismatches);
	}

	public function testRemovedIdsAreNotFoundAgain():Void {
		var grid = new SpatialGrid(0, 0, 100, 100, 10);
		for (id in 0...90) {
			// Nine to a cell, so removals come off the head, middle and tail.
			grid.set(id, (id % 10) * 10 + 5, Std.int(id / 10) * 10 + 5);
		}

		var kept:Array<Int> = [];
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
		var grid = new SpatialGrid(0, 0, 1000, 1000, 50);
		grid.set(5, 10, 10);
		grid.set(5, 900, 900);

		Assert.equals(1, grid.length);
		Assert.same([], grid.queryCircle(10, 10, 20));
		Assert.same([5], grid.queryCircle(900, 900, 20));
	}

	public function testAPointExactlyOnTheRadiusIsInside():Void {
		var grid = new SpatialGrid(0, 0, 100, 100, 10);
		grid.set(1, 30, 40); // 50 from the origin
		grid.set(2, 30, 41);

		Assert.same([1], grid.queryCircle(0, 0, 50));
	}

	public function testAQueryThatCannotReachAnythingFindsNothing():Void {
		var grid = new SpatialGrid(0, 0, 100, 100, 10);
		grid.set(1, 50, 50);

		Assert.same([], grid.queryCircle(50, 50, -1));
		Assert.same([], grid.queryCircle(50, 50, Math.NaN));
		Assert.same([], grid.queryCircle(Math.NaN, 50, 10));
		Assert.same([], grid.queryCircle(50, Math.NaN, 10));
		Assert.same([], grid.queryRect(40, 40, 0, 20));
		Assert.same([], grid.queryRect(40, 40, 20, -1));
		Assert.same([], grid.queryRect(Math.NaN, 40, 20, 20));
	}

	public function testPositionsOutsideTheBoundsAreStillFound():Void {
		var grid = new SpatialGrid(0, 0, 100, 100, 10);
		grid.set(1, -500, -500);
		grid.set(2, 1e6, 50);
		grid.set(3, 50, 50);

		Assert.same([1], grid.queryCircle(-490, -490, 20));
		Assert.same([2], grid.queryCircle(1e6 - 5, 50, 10));
		Assert.same([1], grid.queryRect(-600, -600, 200, 200));
		// A query entirely beyond an edge still visits the edge cells, which
		// is where anything out there was filed.
		Assert.same([], grid.queryCircle(-1000, 50, 5));
		Assert.equals("1,2,3", sorted(grid.queryCircle(0, 0, Math.POSITIVE_INFINITY)));
	}

	public function testAFoundArrayIsAddedTo():Void {
		var grid = new SpatialGrid(0, 0, 100, 100, 10);
		grid.set(7, 50, 50);
		var found:Array<Int> = [99];

		Assert.equals(found, grid.queryCircle(50, 50, 1, found));
		Assert.same([99, 7], found);
	}

	public function testIdsBeyondTheStartingCapacityAreMadeRoomFor():Void {
		var grid = new SpatialGrid(0, 0, 100, 100, 10, 0);
		grid.set(10000, 20, 20);
		grid.set(3, 25, 25);

		Assert.isTrue(grid.has(10000));
		Assert.isFalse(grid.has(9999));
		Assert.equals("3,10000", sorted(grid.queryCircle(20, 20, 10)));
	}

	public function testClearTakesEverythingOut():Void {
		var grid = new SpatialGrid(0, 0, 100, 100, 10);
		for (id in 0...50) {
			grid.set(id, id * 2, id * 2);
		}
		grid.clear();

		Assert.equals(0, grid.length);
		Assert.same([], grid.queryCircle(50, 50, 1000));
		Assert.isFalse(grid.has(10));

		grid.set(10, 5, 5);
		Assert.same([10], grid.queryCircle(5, 5, 1));
		Assert.equals(1, grid.length);
	}

	public function testWhatCannotBeFiledIsRefused():Void {
		var grid = new SpatialGrid(0, 0, 100, 100, 10);
		Assert.raises(() -> grid.set(-1, 5, 5), ArgumentError);
		Assert.raises(() -> grid.set(1, Math.NaN, 5), ArgumentError);
		Assert.raises(() -> grid.set(1, 5, Math.NaN), ArgumentError);
		Assert.equals(0, grid.length);
	}

	public function testBoundsTheGridCannotUseAreRefused():Void {
		Assert.raises(() -> new SpatialGrid(0, 0, 0, 100, 10), ArgumentError);
		Assert.raises(() -> new SpatialGrid(0, 0, 100, -1, 10), ArgumentError);
		Assert.raises(() -> new SpatialGrid(0, 0, Math.POSITIVE_INFINITY, 100, 10), ArgumentError);
		Assert.raises(() -> new SpatialGrid(Math.NaN, 0, 100, 100, 10), ArgumentError);
		Assert.raises(() -> new SpatialGrid(0, 0, 100, 100, 0), ArgumentError);
		Assert.raises(() -> new SpatialGrid(0, 0, 100, 100, Math.NaN), ArgumentError);
		Assert.raises(() -> new SpatialGrid(0, 0, 100, 100, 10, -1), ArgumentError);
		// A hundred million cells: refused rather than allocated.
		Assert.raises(() -> new SpatialGrid(0, 0, 100000, 100000, 10), ArgumentError);

		// A cell larger than the bounds is one cell.
		var one = new SpatialGrid(0, 0, 10, 10, 50);
		Assert.equals(1, one.columns);
		Assert.equals(1, one.rows);
	}
}
