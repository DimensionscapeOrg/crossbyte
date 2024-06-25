package crossbyte.ds;

import math.Rectangle;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A simple QuadTree implementation in Haxe.
 *
 * @param T The type of elements stored in the QuadTree.
 */
class QuadTree<T> {
	private var boundary:Rectangle;
	private var capacity:Int;
	private var nodes:Array<Node<T>>;
	private var divided:Bool;
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
	public function insert(node:Node<T>):Bool {
		if (!boundary.contains(node.x, node.y))
			return false;

		if (nodes.length < capacity) {
			nodes.push(node);
			return true;
		}

		if (!divided)
			subdivide();

		return northeast.insert(node) || northwest.insert(node) || southeast.insert(node) || southwest.insert(node);
	}

	private function subdivide():Void {
		var x = boundary.x;
		var y = boundary.y;
		var w = boundary.width / 2;
		var h = boundary.height / 2;

		northeast = new QuadTree<T>(new Rectangle(x + w, y - h, w, h), capacity);
		northwest = new QuadTree<T>(new Rectangle(x - w, y - h, w, h), capacity);
		southeast = new QuadTree<T>(new Rectangle(x + w, y + h, w, h), capacity);
		southwest = new QuadTree<T>(new Rectangle(x - w, y + h, w, h), capacity);

		divided = true;
	}

	/**
	 * Node class to define elements in the QuadTree.
	 *
	 * @param T The type of value associated with the node.
	 */
	class Node<T> {
		public var x:Float;
		public var y:Float;
		public var value:T;

		public function new(x:Float, y:Float, value:T) {
			this.x = x;
			this.y = y;
			this.value = value;
		}
	}
}
