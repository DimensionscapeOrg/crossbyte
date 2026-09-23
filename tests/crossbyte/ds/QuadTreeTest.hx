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
}
