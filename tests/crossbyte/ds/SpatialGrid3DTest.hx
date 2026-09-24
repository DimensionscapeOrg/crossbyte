package crossbyte.ds;

import crossbyte.errors.ArgumentError;
import utest.Assert;

class SpatialGrid3DTest extends utest.Test {
	private var seed:Int;

	public function setup():Void {
		seed = 0x1B873593;
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

	private static function within(points:Array<Array<Float>>, held:Array<Bool>, x:Float, y:Float, z:Float, radius:Float):Array<Int> {
		return [
			for (id in 0...points.length)
				if (held[id] && __distanceSquared(points[id], x, y, z) <= radius * radius) id
		];
	}

	// Rectangle.contains on each axis: low faces in, high faces out.
	private static function __inBox(p:Array<Float>, x:Float, y:Float, z:Float, w:Float, h:Float, d:Float):Bool {
		return p[0] >= x && p[1] >= y && p[2] >= z && p[0] < x + w && p[1] < y + h && p[2] < z + d;
	}

	private static inline function __distanceSquared(p:Array<Float>, x:Float, y:Float, z:Float):Float {
		return (p[0] - x) * (p[0] - x) + (p[1] - y) * (p[1] - y) + (p[2] - z) * (p[2] - z);
	}

	public function testASphereFindsExactlyWhatIsWithinItsRadius():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 1000, 1000, 400, 50);
		var points:Array<Array<Float>> = [];
		var held:Array<Bool> = [];
		// Some outside the bounds on every axis, which are filed at the edge.
		for (id in 0...2000) {
			points.push([coordinate(-100, 1100), coordinate(-100, 1100), coordinate(-100, 500)]);
			held.push(true);
			grid.set(id, points[id][0], points[id][1], points[id][2]);
		}

		var mismatches:Array<String> = [];
		for (q in 0...300) {
			var x:Float = coordinate(-200, 1200);
			var y:Float = coordinate(-200, 1200);
			var z:Float = coordinate(-200, 600);
			var radius:Float = coordinate(0, 300);
			var found:Array<Int> = grid.querySphere(x, y, z, radius);
			var expected:Array<Int> = within(points, held, x, y, z, radius);
			if (sorted(found) != sorted(expected)) {
				mismatches.push('query $q at ($x, $y, $z) radius $radius: ${found.length}, not ${expected.length}');
			}
		}

		Assert.same([], mismatches);
		Assert.equals(2000, grid.length);
	}

	public function testEveryQueryStaysExactAsThingsMove():Void {
		// Small cells, ordinary ones, and one cell holding everything.
		for (cellSize in [9.0, 100.0, 1000.0]) {
			var grid = new SpatialGrid3D(0, 0, 0, 1000, 1000, 1000, cellSize);
			var points:Array<Array<Float>> = [];
			var held:Array<Bool> = [];
			for (id in 0...400) {
				points.push([coordinate(0, 1000), coordinate(0, 1000), coordinate(0, 1000)]);
				held.push(true);
				grid.set(id, points[id][0], points[id][1], points[id][2]);
			}

			var mismatches:Array<String> = [];
			for (round in 0...30) {
				for (id in 0...400) {
					var p:Array<Float> = points[id];
					switch (random(10)) {
						case 0:
							// A jump anywhere, sometimes out of bounds.
							p[0] = coordinate(-200, 1200);
							p[1] = coordinate(-200, 1200);
							p[2] = coordinate(-200, 1200);
						case 1:
							// Staying exactly where it is.
						default:
							// A small step, usually within the same cell.
							p[0] += coordinate(-3, 3);
							p[1] += coordinate(-3, 3);
							p[2] += coordinate(-3, 3);
					}
					grid.set(id, p[0], p[1], p[2]);
				}

				for (q in 0...20) {
					var x:Float = coordinate(-100, 1100);
					var y:Float = coordinate(-100, 1100);
					var z:Float = coordinate(-100, 1100);
					var radius:Float = coordinate(0, 300);
					var found:Array<Int> = grid.querySphere(x, y, z, radius);
					var expected:Array<Int> = within(points, held, x, y, z, radius);
					if (sorted(found) != sorted(expected)) {
						mismatches.push('cell $cellSize, round $round, query $q: ${found.length}, not ${expected.length}');
					}
				}
			}

			Assert.same([], mismatches);
			Assert.equals(400, grid.length);
		}
	}

	public function testABoxIncludesItsLowFacesAndNotItsHighOnes():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 1000, 1000, 1000, 40);
		var points:Array<Array<Float>> = [];
		for (id in 0...1500) {
			// Whole numbers, so plenty of points sit exactly on a face.
			points.push([random(1100) - 50, random(1100) - 50, random(1100) - 50]);
			grid.set(id, points[id][0], points[id][1], points[id][2]);
		}

		var mismatches:Array<String> = [];
		for (q in 0...300) {
			var x:Float = random(1100) - 50;
			var y:Float = random(1100) - 50;
			var z:Float = random(1100) - 50;
			var w:Float = random(300) + 1;
			var h:Float = random(300) + 1;
			var d:Float = random(300) + 1;
			var found:Array<Int> = grid.queryBox(x, y, z, w, h, d);
			var expected:Array<Int> = [for (id in 0...points.length) if (__inBox(points[id], x, y, z, w, h, d)) id];
			if (sorted(found) != sorted(expected)) {
				mismatches.push('box $q at ($x, $y, $z) size ($w, $h, $d): ${found.length}, not ${expected.length}');
			}
		}

		Assert.same([], mismatches);
	}

	public function testRemovedIdsAreNotFoundAgain():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 100, 100, 100, 50);
		for (id in 0...96) {
			// Twelve to each of the eight cells, so removals come off the
			// head, middle and tail of every list.
			var cell:Int = id % 8;
			grid.set(id, (cell & 1) * 50 + 5 + id / 10, ((cell >> 1) & 1) * 50 + 5, (cell >> 2) * 50 + 5);
		}

		var kept:Array<Int> = [];
		for (id in 0...96) {
			if (id % 3 == 0) {
				Assert.isTrue(grid.remove(id));
			} else {
				kept.push(id);
			}
		}

		Assert.equals(64, grid.length);
		Assert.equals(sorted(kept), sorted(grid.querySphere(50, 50, 50, 1000)));
		Assert.isFalse(grid.has(3));
		Assert.isTrue(grid.has(4));
		Assert.isFalse(grid.remove(3), "removing twice");
		Assert.isFalse(grid.remove(5000), "removing an id never given");
		Assert.isFalse(grid.remove(-1), "removing a negative id");
		Assert.equals(64, grid.length);
	}

	public function testSettingAnIdAgainMovesIt():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 1000, 1000, 1000, 50);
		grid.set(5, 10, 10, 10);
		grid.set(5, 10, 10, 900);

		Assert.equals(1, grid.length);
		Assert.same([], grid.querySphere(10, 10, 10, 20));
		Assert.same([5], grid.querySphere(10, 10, 900, 20));
	}

	public function testAPointExactlyOnTheRadiusIsInside():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 100, 100, 100, 10);
		grid.set(1, 2, 3, 6); // 7 from the origin: 4 + 9 + 36 = 49
		grid.set(2, 2, 3, 6.01);

		Assert.same([1], grid.querySphere(0, 0, 0, 7));
	}

	public function testAQueryThatCannotReachAnythingFindsNothing():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 100, 100, 100, 10);
		grid.set(1, 50, 50, 50);

		Assert.same([], grid.querySphere(50, 50, 50, -1));
		Assert.same([], grid.querySphere(50, 50, 50, Math.NaN));
		Assert.same([], grid.querySphere(Math.NaN, 50, 50, 10));
		Assert.same([], grid.querySphere(50, 50, Math.NaN, 10));
		Assert.same([], grid.queryBox(40, 40, 40, 20, 20, 0));
		Assert.same([], grid.queryBox(40, 40, 40, 20, -1, 20));
		Assert.same([], grid.queryBox(40, 40, Math.NaN, 20, 20, 20));
	}

	public function testPositionsOutsideTheBoundsAreStillFound():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 100, 100, 100, 10);
		grid.set(1, 50, 50, -500);
		grid.set(2, 50, 1e6, 50);
		grid.set(3, 50, 50, 50);

		Assert.same([1], grid.querySphere(50, 50, -490, 20));
		Assert.same([2], grid.querySphere(50, 1e6 - 5, 50, 10));
		Assert.same([1], grid.queryBox(0, 0, -600, 100, 100, 200));
		Assert.same([], grid.querySphere(50, 50, -1000, 5));
		Assert.equals("1,2,3", sorted(grid.querySphere(0, 0, 0, Math.POSITIVE_INFINITY)));
	}

	public function testAFoundArrayIsAddedTo():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 100, 100, 100, 10);
		grid.set(7, 50, 50, 50);
		var found:Array<Int> = [99];

		Assert.equals(found, grid.querySphere(50, 50, 50, 1, found));
		Assert.same([99, 7], found);
	}

	public function testIdsBeyondTheStartingCapacityAreMadeRoomFor():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 100, 100, 100, 10, 0);
		grid.set(10000, 20, 20, 20);
		grid.set(3, 25, 25, 25);

		Assert.isTrue(grid.has(10000));
		Assert.isFalse(grid.has(9999));
		Assert.equals("3,10000", sorted(grid.querySphere(20, 20, 20, 10)));
	}

	public function testClearTakesEverythingOut():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 100, 100, 100, 10);
		for (id in 0...50) {
			grid.set(id, id * 2, id * 2, 100 - id * 2);
		}
		grid.clear();

		Assert.equals(0, grid.length);
		Assert.same([], grid.querySphere(50, 50, 50, 1000));
		Assert.isFalse(grid.has(10));

		grid.set(10, 5, 5, 5);
		Assert.same([10], grid.querySphere(5, 5, 5, 1));
		Assert.equals(1, grid.length);
	}

	public function testWhatCannotBeFiledIsRefused():Void {
		var grid = new SpatialGrid3D(0, 0, 0, 100, 100, 100, 10);
		Assert.raises(() -> grid.set(-1, 5, 5, 5), ArgumentError);
		Assert.raises(() -> grid.set(1, Math.NaN, 5, 5), ArgumentError);
		Assert.raises(() -> grid.set(1, 5, Math.NaN, 5), ArgumentError);
		Assert.raises(() -> grid.set(1, 5, 5, Math.NaN), ArgumentError);
		Assert.equals(0, grid.length);
	}

	public function testBoundsTheGridCannotUseAreRefused():Void {
		Assert.raises(() -> new SpatialGrid3D(0, 0, 0, 100, 100, 0, 10), ArgumentError);
		Assert.raises(() -> new SpatialGrid3D(0, 0, 0, 100, -1, 100, 10), ArgumentError);
		Assert.raises(() -> new SpatialGrid3D(0, 0, 0, 100, 100, Math.POSITIVE_INFINITY, 10), ArgumentError);
		Assert.raises(() -> new SpatialGrid3D(0, 0, Math.NaN, 100, 100, 100, 10), ArgumentError);
		Assert.raises(() -> new SpatialGrid3D(0, 0, 0, 100, 100, 100, 0), ArgumentError);
		Assert.raises(() -> new SpatialGrid3D(0, 0, 0, 100, 100, 100, 10, -1), ArgumentError);
		// Three hundred and forty-three million cells: refused rather than
		// allocated, where the same extent in two dimensions would be allowed.
		Assert.raises(() -> new SpatialGrid3D(0, 0, 0, 7000, 7000, 7000, 10), ArgumentError);

		var one = new SpatialGrid3D(0, 0, 0, 10, 10, 10, 50);
		Assert.equals(1, one.columns);
		Assert.equals(1, one.rows);
		Assert.equals(1, one.layers);
	}
}
