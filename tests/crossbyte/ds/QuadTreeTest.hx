package crossbyte.ds;

import crossbyte.ds.QuadTree.QuadTreeNode;
import crossbyte.math.Rectangle;
import utest.Assert;

class QuadTreeTest extends utest.Test {
	private var seed:Int;

	public function setup():Void {
		seed = 0x3C6EF372;
	}

	private function random(bound:Int):Int {
		seed ^= seed << 13;
		seed ^= seed >>> 17;
		seed ^= seed << 5;
		return (seed & 0x7FFFFFFF) % bound;
	}

	private static function sortedValues(nodes:Array<QuadTreeNode<Int>>):String {
		var values:Array<Int> = [for (node in nodes) node.value];
		values.sort((a, b) -> a - b);
		return values.join(",");
	}

	public function testACircleFindsExactlyWhatIsWithinItsRadius():Void {
		var tree = new QuadTree<Int>(new Rectangle(0, 0, 1000, 1000), 4);
		var points:Array<QuadTreeNode<Int>> = [];
		for (i in 0...2000) {
			var node = new QuadTreeNode<Int>(random(100000) / 100, random(100000) / 100, i);
			points.push(node);
			tree.insert(node);
		}

		var mismatches:Array<String> = [];
		for (q in 0...200) {
			var x:Float = random(1200) - 100;
			var y:Float = random(1200) - 100;
			var radius:Float = random(30000) / 100;

			var expected:Array<QuadTreeNode<Int>> = [for (p in points) if ((p.x - x) * (p.x - x) + (p.y - y) * (p.y - y) <= radius * radius) p];
			var found:Array<QuadTreeNode<Int>> = tree.queryCircle(x, y, radius);
			if (sortedValues(found) != sortedValues(expected)) {
				mismatches.push('query $q at ($x, $y) radius $radius: ${found.length}, not ${expected.length}');
			}
		}

		Assert.same([], mismatches);
	}

	public function testAPointInTheRootIsNeverRefusedByTheChildren():Void {
		// Bounds where a child's far edge, (x + w/2) + w/2, rounds an ulp short
		// of the root's x + w. The point is the last value below the root's
		// edge: inside the root, past the east child's edge, and so, if the
		// children were each asked, inside neither. One set of random bounds in
		// twenty has such a sliver at its first split alone.
		var x:Float = -860.2891528507621;
		var width:Float = 453.56597600631187;
		var sliver:Float = -406.7231768444503;
		var tree = new QuadTree<Int>(new Rectangle(x, 0, width, 100), 1);

		Assert.isTrue(sliver < x + width, "the point is inside the root");
		Assert.isTrue(sliver >= (x + width / 2) + width / 2, "and past the east child's rounded edge");

		Assert.isTrue(tree.insert(new QuadTreeNode<Int>(x + 1, 1, 1)), "the first point fills the root");
		Assert.isTrue(tree.insert(new QuadTreeNode<Int>(sliver, 1, 2)), "the sliver point was refused");
		Assert.same("1,2", sortedValues(tree.query(new Rectangle(x, 0, width, 100))));
	}

	public function testAPointExactlyOnTheRadiusIsInside():Void {
		var tree = new QuadTree<Int>(new Rectangle(0, 0, 100, 100), 4);
		tree.insert(new QuadTreeNode<Int>(30, 40, 1)); // 50 from the origin
		tree.insert(new QuadTreeNode<Int>(30, 41, 2));

		Assert.same("1", sortedValues(tree.queryCircle(0, 0, 50)));
	}

	public function testANegativeOrMissingRadiusFindsNothing():Void {
		var tree = new QuadTree<Int>(new Rectangle(0, 0, 100, 100), 4);
		tree.insert(new QuadTreeNode<Int>(10, 10, 1));

		Assert.equals(0, tree.queryCircle(10, 10, -1).length);
		Assert.equals(0, tree.queryCircle(10, 10, Math.NaN).length);
		Assert.equals(1, tree.queryCircle(10, 10, 0).length);
	}

	public function testTheArrayHandedInIsTheOneFilled():Void {
		var tree = new QuadTree<Int>(new Rectangle(0, 0, 100, 100), 4);
		tree.insert(new QuadTreeNode<Int>(10, 10, 1));
		var found:Array<QuadTreeNode<Int>> = [];

		Assert.equals(found, tree.queryCircle(10, 10, 5, found));
		Assert.equals(1, found.length);
	}

	public function testAPileOnOneSpotStaysShallowAndIsAllThere():Void {
		// A crowd on a spawn point. Every insert must land, every one must be
		// found again, and the tree must stop splitting where splitting
		// stopped helping.
		var tree = new QuadTree<Int>(new Rectangle(0, 0, 100, 100), 4);
		var landed:Int = 0;
		for (i in 0...20000) {
			if (tree.insert(new QuadTreeNode<Int>(50, 50, i))) {
				landed++;
			}
		}

		Assert.equals(20000, landed);
		Assert.equals(20000, tree.query(new Rectangle(49, 49, 2, 2)).length);
		Assert.equals(20000, tree.queryCircle(50, 50, 0.5).length);
		Assert.isTrue(deepest(tree) <= 32, 'the tree went ${deepest(tree)} levels deep');
	}

	private static function deepest(tree:QuadTree<Int>):Int {
		if (!@:privateAccess tree.divided) {
			return @:privateAccess tree.depth;
		}
		var children:Array<QuadTree<Int>> = @:privateAccess [tree.northwest, tree.northeast, tree.southwest, tree.southeast];
		var most:Int = 0;
		for (child in children) {
			var d:Int = deepest(child);
			if (d > most) {
				most = d;
			}
		}
		return most;
	}

	public function testAPointInTheSliverIsFoundByANarrowQuery():Void {
		// Filed by the midlines, a point in the sliver past a child's rounded
		// far edge was then pruned away by that edge: a query starting at the
		// point never found it.
		var x:Float = -860.2891528507621;
		var width:Float = 453.56597600631187;
		var sliver:Float = -406.7231768444503;
		var tree = new QuadTree<Int>(new Rectangle(x, 0, width, 100), 1);
		tree.insert(new QuadTreeNode<Int>(x + 1, 1, 1));
		tree.insert(new QuadTreeNode<Int>(sliver, 1, 2));
		Assert.same("2", sortedValues(tree.query(new Rectangle(sliver, 0, 1, 100))));
		Assert.same("2", sortedValues(tree.queryCircle(sliver, 1, 0)));
	}

	/**
		A tree cleared and refilled tick after tick, from the quads its clears
		kept, is the tree a new one built from the same points would be: the
		same shape, quad for quad, and the same answers to every query, as the
		points move and their crowd grows and shrinks.
	**/
	public function testARebuiltTreeIsTheTreeBuiltAnew():Void {
		var bounds = new Rectangle(0, 0, 1000, 1000);
		var kept = new QuadTree<Int>(bounds, 4);
		var wrong:Array<String> = [];
		for (tick in 0...30) {
			var count:Int = tick % 10 == 9 ? 50 : 300 + tick * 40;
			var points:Array<QuadTreeNode<Int>> = [];
			for (i in 0...count) {
				// A crowd that drifts, and a pile on one spot every few ticks.
				var x:Float = tick % 7 == 3 && i % 3 == 0 ? 500 : (random(100000) / 100 + tick * 13) % 1000;
				points.push(new QuadTreeNode<Int>(x, random(100000) / 100, i));
			}
			kept.clear();
			var fresh = new QuadTree<Int>(bounds, 4);
			for (point in points) {
				kept.insert(point);
				fresh.insert(point);
			}
			if (shape(kept) != shape(fresh)) {
				wrong.push("tick " + tick + ": another shape");
			}
			for (q in 0...20) {
				var x:Float = random(1000);
				var y:Float = random(1000);
				var range = new Rectangle(x, y, random(300), random(300));
				var radius:Float = random(200);
				if (sortedValues(kept.query(range)) != sortedValues(fresh.query(range))
					|| sortedValues(kept.queryCircle(x, y, radius)) != sortedValues(fresh.queryCircle(x, y, radius))) {
					wrong.push("tick " + tick + ": query " + q);
				}
			}
		}
		Assert.same([], wrong.slice(0, 10));

		// Cleared and left, it holds none of what it held.
		kept.clear();
		Assert.equals(0, kept.query(bounds).length);
	}

	// The tree's quads, depth first: each one's bounds, depth and points.
	private static function shape(tree:QuadTree<Int>):String {
		var parts:Array<String> = [];
		function walk(quad:QuadTree<Int>):Void {
			var bounds:Rectangle = @:privateAccess quad.boundary;
			parts.push(bounds.x + "," + bounds.y + "," + bounds.width + "," + bounds.height + "@" + @:privateAccess quad.depth + ":"
				+ sortedValues(@:privateAccess quad.nodes));
			if (@:privateAccess quad.divided) {
				walk(@:privateAccess quad.northwest);
				walk(@:privateAccess quad.northeast);
				walk(@:privateAccess quad.southwest);
				walk(@:privateAccess quad.southeast);
			}
		}
		walk(tree);
		return parts.join(" ");
	}

	/**
		Rebuilding a tree, clear and every point inserted again, allocates
		nothing natively or on the jvm once it has held as many quads as a
		rebuild needs: each clear let its quads go and the next rebuild made
		them again (61 KB a rebuild of 1,000 points on the jvm).
	**/
	public function testRebuildingATreeAllocatesNothing():Void {
		#if (cpp || jvm)
		var tree = new QuadTree<Int>(new Rectangle(0, 0, 1000, 1000), 8);
		var points:Array<QuadTreeNode<Int>> = [for (i in 0...100) new QuadTreeNode<Int>(random(100000) / 100, random(100000) / 100, i)];
		var rebuild:Void->Void = () -> {
			tree.clear();
			for (point in points) {
				tree.insert(point);
			}
		};
		for (_ in 0...2000) {
			rebuild();
		}
		var reading = crossbyte.test.AllocationMeter.measure(rebuild, 500, 3);
		Assert.equals(0.0, reading.perOperation, "a rebuild allocated " + reading);
		Assert.equals(100, tree.query(new Rectangle(0, 0, 1000, 1000)).length);
		#else
		Assert.pass();
		#end
	}

	public function testACapacityOfZeroIsAnArgumentError():Void {
		try {
			new QuadTree<Int>(new Rectangle(0, 0, 10, 10), 0);
			Assert.fail("a capacity of 0 was taken");
		} catch (e:crossbyte.errors.ArgumentError) {
			Assert.pass();
		}
	}
}
