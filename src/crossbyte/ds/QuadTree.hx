package crossbyte.ds;

import crossbyte.math.Rectangle;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * Points in a rectangle, divided where they are: a quad holds up to
 * `capacity` of them and splits into four when it is given more.
 *
 * Because it divides where the points are, it copes with uneven crowds -- a
 * thousand on one spot and a scattering elsewhere -- and suits points that
 * hold still, or queries of many sizes. It has no way to move a point:
 * things that move are put back by `clear` and inserting everything again,
 * which costs a descent per point per rebuild. For many things moving every
 * tick, queried at one radius, `SpatialGrid` moves each for a comparison.
 *
 * @param T The type of elements stored in the QuadTree.
 */
class QuadTree<T> {
	// Deep enough for any real spread of points: 32 levels down, a quad is a
	// four-billionth of the width it started at. Only points piled on one
	// spot -- a crowd on a spawn point -- ever get that far, and splitting
	// them again only moves the pile down a level, so past this a quad keeps
	// what it is given instead. Uncapped, each `capacity` of them cost one
	// more level, until the quads were too small for floating point to tell
	// apart and inserts began to fail.
	private static inline var MAX_DEPTH:Int = 32;

	private var boundary:Rectangle;
	private var capacity:Int;
	private var nodes:Array<QuadTreeNode<T>>;
	private var divided:Bool;
	private var depth:Int = 0;
	private var northeast:QuadTree<T>;
	private var northwest:QuadTree<T>;
	private var southeast:QuadTree<T>;
	private var southwest:QuadTree<T>;

	/**
	 * Constructs a new QuadTree.
	 *
	 * @param boundary The boundary of the QuadTree.
	 * @param capacity The capacity of points before subdivision.
	 */
	public function new(boundary:Rectangle, capacity:Int) {
		if (capacity <= 0) {
			throw "capacity must be > 0";
		}
		this.boundary = boundary;
		this.capacity = capacity;
		this.nodes = [];
		this.divided = false;
	}

	/**
	 * Inserts a node into the QuadTree.
	 *
	 * @param node The node to be inserted.
	 * @return True if the node was inserted, false otherwise.
	 */
	public function insert(node:QuadTreeNode<T>):Bool {
		if (!boundary.contains(node.x, node.y))
			return false;

		// Down by arithmetic. Once this quad holds the point, which child takes
		// it is which side of each midline it falls on -- the midlines being
		// the edges the children were built with. No child is asked whether
		// it contains the point, so none can refuse it. Asking them in turn
		// cost up to four containment tests a level, and it dropped points:
		// a child's far edge is `(x + w/2) + w/2`, which can round an ulp
		// short of its parent's `x + w`, and a point in that sliver was in the
		// parent and in neither child, so insert returned false.
		var quad:QuadTree<T> = this;
		while (quad.nodes.length >= quad.capacity && quad.depth < MAX_DEPTH) {
			if (!quad.divided)
				quad.subdivide();

			var east:Bool = node.x >= quad.northeast.boundary.x;
			var south:Bool = node.y >= quad.southwest.boundary.y;
			quad = south ? (east ? quad.southeast : quad.southwest) : (east ? quad.northeast : quad.northwest);
		}

		quad.nodes.push(node);
		return true;
	}

	private function subdivide():Void {
		var x = boundary.x;
		var y = boundary.y;
		var w = boundary.width / 2;
		var h = boundary.height / 2;

		northwest = new QuadTree<T>(new Rectangle(x, y, w, h), capacity);
		northeast = new QuadTree<T>(new Rectangle(x + w, y, w, h), capacity);
		southwest = new QuadTree<T>(new Rectangle(x, y + h, w, h), capacity);
		southeast = new QuadTree<T>(new Rectangle(x + w, y + h, w, h), capacity);
		northwest.depth = northeast.depth = southwest.depth = southeast.depth = depth + 1;

		divided = true;
	}

	public function query(range:Rectangle, ?found:Array<QuadTreeNode<T>>):Array<QuadTreeNode<T>> {
		if (found == null) {
			found = [];
		}

		if (!boundary.intersects(range)) {
			return found;
		}

		for (node in nodes) {
			if (range.contains(node.x, node.y)) {
				found.push(node);
			}
		}

		if (divided) {
			northwest.query(range, found);
			northeast.query(range, found);
			southwest.query(range, found);
			southeast.query(range, found);
		}

		return found;
	}

	/**
	 * Every node within `radius` of (`x`, `y`), a distance of exactly
	 * `radius` included: the shape most areas of interest are.
	 *
	 * @param found Where to add them; a new array by default. Handing the
	 *        same one back each tick, emptied, saves allocating another.
	 */
	public function queryCircle(x:Float, y:Float, radius:Float, ?found:Array<QuadTreeNode<T>>):Array<QuadTreeNode<T>> {
		if (found == null) {
			found = [];
		}
		// Negative or NaN: a circle that reaches nothing.
		if (radius >= 0) {
			__queryCircle(x, y, radius * radius, found);
		}
		return found;
	}

	private function __queryCircle(x:Float, y:Float, radiusSquared:Float, found:Array<QuadTreeNode<T>>):Void {
		// The point of this quad nearest the centre. If even that is out of
		// reach, nothing inside it can be in reach.
		var right:Float = boundary.x + boundary.width;
		var bottom:Float = boundary.y + boundary.height;
		var nearestX:Float = x < boundary.x ? boundary.x : (x > right ? right : x);
		var nearestY:Float = y < boundary.y ? boundary.y : (y > bottom ? bottom : y);
		var gapX:Float = x - nearestX;
		var gapY:Float = y - nearestY;
		if (gapX * gapX + gapY * gapY > radiusSquared) {
			return;
		}

		for (node in nodes) {
			var dx:Float = node.x - x;
			var dy:Float = node.y - y;
			if (dx * dx + dy * dy <= radiusSquared) {
				found.push(node);
			}
		}

		if (divided) {
			northwest.__queryCircle(x, y, radiusSquared, found);
			northeast.__queryCircle(x, y, radiusSquared, found);
			southwest.__queryCircle(x, y, radiusSquared, found);
			southeast.__queryCircle(x, y, radiusSquared, found);
		}
	}

	public function clear():Void {
		nodes.resize(0);

		if (divided) {
			northwest.clear();
			northeast.clear();
			southwest.clear();
			southeast.clear();
			northwest = null;
			northeast = null;
			southwest = null;
			southeast = null;
			divided = false;
		}
	}

}

/**
 * Node class to define elements in the QuadTree.
 *
 * @param T The type of value associated with the node.
 */
class QuadTreeNode<T> {
	public var x:Float;
	public var y:Float;
	public var value:T;

	public function new(x:Float, y:Float, value:T) {
		this.x = x;
		this.y = y;
		this.value = value;
	}
}
